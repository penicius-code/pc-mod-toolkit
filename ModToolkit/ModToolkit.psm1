#Requires -Version 5.1
# ModToolkit: install, back up, verify, switch and roll back files of a modded PC game.
# Works in Windows PowerShell 5.1 and PowerShell 7. Every command that changes files supports -WhatIf,
# moves files aside instead of deleting them, and checks SHA-256 hashes after copying.

Set-StrictMode -Version 2.0
$script:LogFile = $null

# ------------------------------------------------------------------ helpers (not exported)

function Write-TkLog {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} {1,-5} {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Verbose $line
    if ($script:LogFile) { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 }
}

function Get-TkProp {
    param($Object, [string]$Name, $Default = $null)
    if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { return $Object.PSObject.Properties[$Name].Value }
    return $Default
}

function Get-TkSha256 {
    param([string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $fs = [System.IO.File]::OpenRead($Path)
    try { ([System.BitConverter]::ToString($sha.ComputeHash($fs))).Replace('-', '').ToLowerInvariant() }
    finally { $fs.Dispose(); $sha.Dispose() }
}

# Relative paths of all files below $Root. Junctions and other links are not followed.
function Get-TkFiles {
    param([string]$Root)
    if (-not [System.IO.Directory]::Exists($Root)) { return }
    $full = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    $out = New-Object 'System.Collections.Generic.List[string]'
    $stack = New-Object System.Collections.Stack
    $stack.Push($full)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        foreach ($f in [System.IO.Directory]::GetFiles($dir)) { $out.Add($f.Substring($full.Length + 1)) }
        foreach ($d in [System.IO.Directory]::GetDirectories($dir)) {
            $attr = [System.IO.File]::GetAttributes($d)
            if (($attr -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) { $stack.Push($d) }
        }
    }
    $out | Sort-Object
}

function New-TkDirectory {
    param([string]$Path)
    if ($Path -and -not [System.IO.Directory]::Exists($Path)) { [void][System.IO.Directory]::CreateDirectory($Path) }
}

function Copy-TkFile {
    param([string]$Source, [string]$Destination)
    New-TkDirectory (Split-Path -Parent $Destination)
    if ([System.IO.File]::Exists($Destination)) { [System.IO.File]::SetAttributes($Destination, 'Normal') }
    [System.IO.File]::Copy($Source, $Destination, $true)
}

function Move-TkFile {
    param([string]$Source, [string]$Destination)
    New-TkDirectory (Split-Path -Parent $Destination)
    [System.IO.File]::Move($Source, $Destination)
}

function Remove-TkFile {
    param([string]$Path)
    if ([System.IO.File]::Exists($Path)) {
        [System.IO.File]::SetAttributes($Path, 'Normal')
        [System.IO.File]::Delete($Path)
    }
}

# Removes $Path and then its parents while they are empty, stopping at (and never removing) $StopAt.
function Remove-TkEmptyParents {
    param([string]$Path, [string]$StopAt)
    $stop = [System.IO.Path]::GetFullPath($StopAt).TrimEnd('\')
    $dir = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    while ($dir.Length -gt $stop.Length -and $dir.StartsWith($stop + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        if (-not [System.IO.Directory]::Exists($dir)) { $dir = Split-Path -Parent $dir; continue }
        if (@([System.IO.Directory]::GetFileSystemEntries($dir)).Count -gt 0) { break }
        # A folder synced by a cloud client can be read-only; clear that before removing it.
        [System.IO.File]::SetAttributes($dir, [System.IO.FileAttributes]::Directory)
        [System.IO.Directory]::Delete($dir)
        $dir = Split-Path -Parent $dir
    }
}

function Remove-TkEmptyTree {
    param([string]$Root)
    if (-not [System.IO.Directory]::Exists($Root)) { return }
    $dirs = @([System.IO.Directory]::GetDirectories($Root, '*', [System.IO.SearchOption]::AllDirectories) | Sort-Object { $_.Length } -Descending)
    foreach ($d in $dirs) {
        if (@([System.IO.Directory]::GetFileSystemEntries($d)).Count -eq 0) { [System.IO.Directory]::Delete($d) }
    }
    if (@([System.IO.Directory]::GetFileSystemEntries($Root)).Count -eq 0) { [System.IO.Directory]::Delete($Root) }
}

function Assert-TkNotRunning {
    param([string[]]$ProcessName)
    foreach ($p in @($ProcessName)) {
        if ($p -and (Get-Process -Name $p -ErrorAction SilentlyContinue)) { throw "$p is running. Close it first. Nothing was changed." }
    }
}

# A new, not yet existing folder "<Parent>\<timestamp>[_<Suffix>]".
function New-TkStampDir {
    param([string]$Parent, [string]$Suffix = '')
    $base = Get-Date -Format 'yyyyMMdd-HHmmss'
    if ($Suffix) { $base = "${base}_$Suffix" }
    $path = Join-Path $Parent $base
    $n = 1
    while (Test-Path -LiteralPath $path) { $n++; $path = Join-Path $Parent "$base-$n" }
    New-TkDirectory $path
    $path
}

function Write-TkLines {
    param([string]$Path, [string[]]$Lines)
    New-TkDirectory (Split-Path -Parent $Path)
    [System.IO.File]::WriteAllLines($Path, [string[]]@($Lines), (New-Object System.Text.UTF8Encoding($false)))
}

function Test-TkRelativePath {
    param([string]$Path)
    if (-not $Path -or [System.IO.Path]::IsPathRooted($Path)) { return $false }
    foreach ($part in ($Path -split '[\\/]')) { if ($part -eq '..' -or $part -eq '.' -or $part -eq '') { return $false } }
    $true
}

function Resolve-TkConfig {
    param($Config)
    if ($Config -is [string]) { return Get-ModToolkitConfig -Path $Config }
    if ($null -eq $Config -or -not $Config.PSObject.Properties['GameDir']) { throw 'Config must be a path to a config file or the object returned by Get-ModToolkitConfig.' }
    $Config
}

# Relative paths (from the game folder) of every file the config selects: all files of the areas plus the root-file patterns.
function Get-TkSelection {
    param($Cfg, [string[]]$Area)
    $list = New-Object 'System.Collections.Generic.List[string]'
    $names = @($Cfg.Areas.Keys)
    if ($Area) { $names = @($Area) }
    foreach ($a in $names) {
        $rel = $Cfg.Areas[$a]
        foreach ($f in @(Get-TkFiles (Join-Path $Cfg.GameDir $rel))) { $list.Add((Join-Path $rel $f)) }
    }
    if (-not $Area) {
        foreach ($pat in @($Cfg.RootFiles)) {
            foreach ($f in @(Get-ChildItem -LiteralPath $Cfg.GameDir -File -Filter $pat -Force -ErrorAction SilentlyContinue)) { $list.Add($f.Name) }
        }
    }
    $list | Sort-Object -Unique
}

function Read-TkManifest {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Manifest not found: $Path" }
    $map = [ordered]@{}
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        if ($line -match '^([0-9a-f]{64})  (.+)$') { $map[$Matches[2]] = $Matches[1] }
    }
    $map
}

function Read-TkSums {
    param([string]$Path)
    $map = @{}
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        if ($line -match '^([0-9a-fA-F]{64}) [ *]\./(.+)$') { $map[$Matches[2].Replace('/', '\')] = $Matches[1].ToLowerInvariant() }
    }
    $map
}

function Read-TkKit {
    param([string]$KitDir)
    $file = Join-Path $KitDir 'kit.json'
    if (-not (Test-Path -LiteralPath $file)) { throw "Not a kit folder (kit.json missing): $KitDir" }
    $raw = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
    [pscustomobject]@{
        Managed      = @(Get-TkProp $raw 'managed' @())
        ProcessNames = @(Get-TkProp $raw 'processNames' @())
    }
}

function Get-TkKitSets {
    param([string]$KitDir)
    $dir = Join-Path $KitDir 'sets'
    if (-not (Test-Path -LiteralPath $dir)) { return }
    Get-ChildItem -LiteralPath $dir -Directory | Sort-Object Name | ForEach-Object { $_.Name }
}

# ------------------------------------------------------------------ log and config

function Set-ModToolkitLog {
    <#
    .SYNOPSIS
        Turns the log file on (with -Path) or off (without).
    .DESCRIPTION
        While a log file is set, every change made by this module is appended to it with a time stamp.
        Dry runs (-WhatIf) are not logged.
    #>
    [CmdletBinding()]
    param([string]$Path)
    if ($Path) {
        $full = [System.IO.Path]::GetFullPath($Path)
        New-TkDirectory (Split-Path -Parent $full)
        $script:LogFile = $full
    } else {
        $script:LogFile = $null
    }
}

function Get-ModToolkitConfig {
    <#
    .SYNOPSIS
        Reads and checks a game config file (see config.sample.json).
    .DESCRIPTION
        Environment variables such as %LOCALAPPDATA% are expanded in gameDir, backupDir and logFile.
        If the config has a logFile, logging is switched on.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Config file not found: $Path" }
    $raw = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $expand = { param($s) if ($s) { [System.Environment]::ExpandEnvironmentVariables([string]$s) } else { $null } }
    $gameDir = & $expand (Get-TkProp $raw 'gameDir')
    $backupDir = & $expand (Get-TkProp $raw 'backupDir')
    if (-not $gameDir) { throw "Config: 'gameDir' is missing." }
    if (-not $backupDir) { throw "Config: 'backupDir' is missing." }
    $gameDir = [System.IO.Path]::GetFullPath($gameDir).TrimEnd('\')
    $backupDir = [System.IO.Path]::GetFullPath($backupDir).TrimEnd('\')
    if (-not [System.IO.Directory]::Exists($gameDir)) { throw "Config: game folder not found: $gameDir" }
    if (($backupDir + '\').StartsWith($gameDir + '\', [System.StringComparison]::OrdinalIgnoreCase)) { throw "Config: 'backupDir' must not be inside the game folder." }

    $areas = [ordered]@{}
    $rawAreas = Get-TkProp $raw 'areas'
    if ($rawAreas) {
        foreach ($p in $rawAreas.PSObject.Properties) {
            $rel = ([string]$p.Value).Replace('/', '\').Trim('\')
            if (-not (Test-TkRelativePath $rel)) { throw "Config: area '$($p.Name)' must be a path relative to the game folder, without '..': $($p.Value)" }
            $areas[$p.Name] = $rel
        }
    }
    $rootFiles = @(Get-TkProp $raw 'rootFiles' @())
    foreach ($pat in $rootFiles) { if ($pat -match '[\\/]') { throw "Config: 'rootFiles' takes file name patterns only, no folders: $pat" } }
    if ($areas.Count -eq 0 -and $rootFiles.Count -eq 0) { throw "Config: give at least one entry in 'areas' or 'rootFiles'." }

    $versionFile = Get-TkProp $raw 'versionFile'
    if ($versionFile -and -not (Test-TkRelativePath ([string]$versionFile).Replace('/', '\'))) { throw "Config: 'versionFile' must be relative to the game folder." }

    $logFile = & $expand (Get-TkProp $raw 'logFile')
    if ($logFile) { Set-ModToolkitLog -Path $logFile }

    [pscustomobject]@{
        Name         = [string](Get-TkProp $raw 'name' (Split-Path -Leaf $gameDir))
        GameDir      = $gameDir
        BackupDir    = $backupDir
        ProcessNames = @(Get-TkProp $raw 'processNames' @())
        VersionFile  = $versionFile
        Areas        = $areas
        RootFiles    = $rootFiles
        LogFile      = $logFile
    }
}

# ------------------------------------------------------------------ backup, verify, restore

function Backup-GameMods {
    <#
    .SYNOPSIS
        Copies the mod areas of a game folder into the backup folder and writes a SHA-256 manifest.
    .DESCRIPTION
        Running it again refreshes the backup: only new or changed files are copied. Files that have left the
        game folder stay in the backup unless -Mirror is given. Use -WhatIf to see the numbers without copying.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory = $true)]$Config, [switch]$Mirror)
    $cfg = Resolve-TkConfig $Config
    Assert-TkNotRunning $cfg.ProcessNames
    $filesDir = Join-Path $cfg.BackupDir 'files'
    $source = @(Get-TkSelection $cfg)
    $copy = New-Object 'System.Collections.Generic.List[string]'
    [long]$bytes = 0
    foreach ($rel in $source) {
        $s = New-Object System.IO.FileInfo (Join-Path $cfg.GameDir $rel)
        $d = New-Object System.IO.FileInfo (Join-Path $filesDir $rel)
        # 2 seconds of tolerance: FAT and exFAT drives store times in 2-second steps.
        if (-not $d.Exists -or $d.Length -ne $s.Length -or [math]::Abs(($d.LastWriteTimeUtc - $s.LastWriteTimeUtc).TotalSeconds) -gt 2) {
            $copy.Add($rel); $bytes += $s.Length
        }
    }
    $stale = @()
    if ($Mirror) {
        $keep = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($rel in $source) { [void]$keep.Add($rel) }
        $stale = @(Get-TkFiles $filesDir | Where-Object { -not $keep.Contains($_) })
    }
    $what = 'Copy {0} new or changed files ({1:N1} MB)' -f $copy.Count, ($bytes / 1MB)
    if ($Mirror) { $what += ", remove $($stale.Count) backup files that are no longer in the game folder" }
    $applied = $false
    if ($PSCmdlet.ShouldProcess($cfg.BackupDir, $what)) {
        $applied = $true
        foreach ($rel in $copy) { Copy-TkFile (Join-Path $cfg.GameDir $rel) (Join-Path $filesDir $rel) }
        foreach ($rel in $stale) { Remove-TkFile (Join-Path $filesDir $rel) }
        if ($stale.Count) { Remove-TkEmptyTree $filesDir; New-TkDirectory $filesDir }
        $all = @(Get-TkFiles $filesDir)
        $lines = @(foreach ($rel in $all) { '{0}  {1}' -f (Get-TkSha256 (Join-Path $filesDir $rel)), $rel })
        Write-TkLines (Join-Path $cfg.BackupDir 'manifest.sha256.txt') $lines
        $versionHash = $null
        if ($cfg.VersionFile -and (Test-Path -LiteralPath (Join-Path $cfg.GameDir $cfg.VersionFile))) {
            $versionHash = Get-TkSha256 (Join-Path $cfg.GameDir $cfg.VersionFile)
        }
        $info = [ordered]@{
            name          = $cfg.Name
            created       = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            gameDir       = $cfg.GameDir
            versionFile   = $cfg.VersionFile
            versionSha256 = $versionHash
            files         = $all.Count
        }
        Write-TkLines (Join-Path $cfg.BackupDir 'backup.json') @(($info | ConvertTo-Json))
        Write-TkLog ("Backup of '{0}': {1} copied, {2} removed, {3} files in {4}" -f $cfg.Name, $copy.Count, $stale.Count, $all.Count, $cfg.BackupDir)
    }
    [pscustomobject]@{
        BackupDir = $cfg.BackupDir
        Copied    = $copy.Count
        Removed   = $stale.Count
        Unchanged = $source.Count - $copy.Count
        Selected  = $source.Count
        Applied   = $applied
    }
}

function Test-GameBackup {
    <#
    .SYNOPSIS
        Compares the backup (or, with -Live, the game folder) with the backup's SHA-256 manifest.
    .DESCRIPTION
        Without -Live it answers "is the backup intact?". With -Live it answers "what changed in the game
        folder since the backup?". Read-only.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Config, [switch]$Live)
    $cfg = Resolve-TkConfig $Config
    $manifest = Read-TkManifest (Join-Path $cfg.BackupDir 'manifest.sha256.txt')
    if ($Live) { $root = $cfg.GameDir; $present = @(Get-TkSelection $cfg) }
    else { $root = Join-Path $cfg.BackupDir 'files'; $present = @(Get-TkFiles $root) }
    $missing = New-Object 'System.Collections.Generic.List[string]'
    $changed = New-Object 'System.Collections.Generic.List[string]'
    foreach ($rel in $manifest.Keys) {
        $p = Join-Path $root $rel
        if (-not [System.IO.File]::Exists($p)) { $missing.Add($rel) }
        elseif ((Get-TkSha256 $p) -ne $manifest[$rel]) { $changed.Add($rel) }
    }
    $known = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($rel in $manifest.Keys) { [void]$known.Add($rel) }
    $extra = @($present | Where-Object { -not $known.Contains($_) })
    [pscustomobject]@{
        Target  = $root
        Files   = $manifest.Count
        Missing = @($missing)
        Changed = @($changed)
        Extra   = $extra
        Ok      = ($missing.Count -eq 0 -and $changed.Count -eq 0)
    }
}

function Restore-GameMods {
    <#
    .SYNOPSIS
        Puts the backed-up files back into the game folder and verifies them.
    .DESCRIPTION
        Only files that are missing or different are written. A file that gets replaced is first moved to
        <backupDir>\replaced\<time stamp>\, so nothing is deleted. With -RemoveAdded, files that were added
        to the areas after the backup are moved there too. The restore stops if the backup does not match its
        manifest, or if the game's version file differs from the one at backup time (override: -Force).
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory = $true)]$Config, [string[]]$Only, [switch]$RemoveAdded, [switch]$Force)
    $cfg = Resolve-TkConfig $Config
    Assert-TkNotRunning $cfg.ProcessNames
    foreach ($a in @($Only)) { if ($a -and -not $cfg.Areas.Contains($a)) { throw "Unknown area '$a'. Areas: $(@($cfg.Areas.Keys) -join ', ')" } }
    $filesDir = Join-Path $cfg.BackupDir 'files'
    $manifest = Read-TkManifest (Join-Path $cfg.BackupDir 'manifest.sha256.txt')
    $check = Test-GameBackup -Config $cfg
    if (-not $check.Ok) { throw "The backup does not match its manifest ($($check.Missing.Count) missing, $($check.Changed.Count) changed). Nothing was restored." }

    $infoFile = Join-Path $cfg.BackupDir 'backup.json'
    if ($cfg.VersionFile -and (Test-Path -LiteralPath $infoFile)) {
        $info = Get-Content -LiteralPath $infoFile -Raw | ConvertFrom-Json
        $want = Get-TkProp $info 'versionSha256'
        $liveVersion = Join-Path $cfg.GameDir $cfg.VersionFile
        if ($want -and (Test-Path -LiteralPath $liveVersion) -and (Get-TkSha256 $liveVersion) -ne $want -and -not $Force) {
            throw "$($cfg.VersionFile) is not the file the backup was made with (game updated?). Files from the backup may not fit. Nothing was restored. Use -Force to restore anyway."
        }
    }

    $roots = @()
    if ($Only) { $roots = @($Only | ForEach-Object { $cfg.Areas[$_] + '\' }) }
    $inScope = {
        param($rel)
        if ($roots.Count -eq 0) { return $true }
        foreach ($r in $roots) { if ($rel.StartsWith($r, [System.StringComparison]::OrdinalIgnoreCase)) { return $true } }
        $false
    }
    $restore = New-Object 'System.Collections.Generic.List[string]'
    $unchanged = 0
    foreach ($rel in $manifest.Keys) {
        if (-not (& $inScope $rel)) { continue }
        $live = Join-Path $cfg.GameDir $rel
        if ([System.IO.File]::Exists($live) -and (Get-TkSha256 $live) -eq $manifest[$rel]) { $unchanged++ } else { $restore.Add($rel) }
    }
    $added = @()
    if ($RemoveAdded) {
        if ($Only) { $liveSel = @(Get-TkSelection $cfg -Area $Only) } else { $liveSel = @(Get-TkSelection $cfg) }
        $added = @($liveSel | Where-Object { -not $manifest.Contains($_) })
    }
    $what = "Restore $($restore.Count) files from the backup"
    if ($RemoveAdded) { $what += ", move $($added.Count) added files out of the game folder" }
    $applied = $false
    $parkDir = $null
    $parked = 0
    if ($PSCmdlet.ShouldProcess($cfg.GameDir, $what)) {
        $applied = $true
        foreach ($rel in $restore) {
            $live = Join-Path $cfg.GameDir $rel
            if ([System.IO.File]::Exists($live)) {
                if (-not $parkDir) { $parkDir = New-TkStampDir (Join-Path $cfg.BackupDir 'replaced') }
                Move-TkFile $live (Join-Path $parkDir $rel); $parked++
            }
            Copy-TkFile (Join-Path $filesDir $rel) $live
        }
        foreach ($rel in $added) {
            if (-not $parkDir) { $parkDir = New-TkStampDir (Join-Path $cfg.BackupDir 'replaced') }
            Move-TkFile (Join-Path $cfg.GameDir $rel) (Join-Path $parkDir $rel); $parked++
        }
        $bad = @($restore | Where-Object { (Get-TkSha256 (Join-Path $cfg.GameDir $_)) -ne $manifest[$_] })
        if ($bad.Count) { throw "Restored files differ from the manifest: $($bad -join ', '). The previous files are in $parkDir" }
        Write-TkLog ("Restore of '{0}': {1} restored, {2} moved to {3}" -f $cfg.Name, $restore.Count, $parked, $parkDir)
    }
    [pscustomobject]@{
        GameDir   = $cfg.GameDir
        Restored  = $restore.Count
        Added     = $added.Count
        Unchanged = $unchanged
        ParkedIn  = $parkDir
        Applied   = $applied
    }
}

# ------------------------------------------------------------------ install and uninstall one mod package

function Get-TkStateDir { param([string]$GameDir, [string]$Name) Join-Path (Join-Path $GameDir '_modtoolkit') $Name }

function Install-ModPackage {
    <#
    .SYNOPSIS
        Copies a mod package (a folder laid out like the game folder) into the game folder, with a record for a clean uninstall.
    .DESCRIPTION
        Every file of the package is copied to the same relative path in the game folder. A file that already
        exists there is first moved to <GameDir>\_modtoolkit\<Name>\replaced\ and comes back on uninstall.
        The list of installed files and their SHA-256 hashes is kept in <GameDir>\_modtoolkit\<Name>\install.json.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$PackagePath,
        [Parameter(Mandatory = $true)][string]$GameDir,
        [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*$')][string]$Name,
        [string[]]$ProcessName
    )
    if (-not [System.IO.Directory]::Exists($PackagePath)) { throw "Package folder not found: $PackagePath" }
    if (-not [System.IO.Directory]::Exists($GameDir)) { throw "Game folder not found: $GameDir" }
    $pkg = [System.IO.Path]::GetFullPath($PackagePath).TrimEnd('\')
    $game = [System.IO.Path]::GetFullPath($GameDir).TrimEnd('\')
    Assert-TkNotRunning $ProcessName
    $state = Get-TkStateDir $game $Name
    $record = Join-Path $state 'install.json'
    if (Test-Path -LiteralPath $record) { throw "'$Name' is already installed here. Run Uninstall-ModPackage first. Nothing was changed." }
    $files = @(Get-TkFiles $pkg)
    if ($files.Count -eq 0) { throw "The package folder is empty: $pkg" }
    $existing = @($files | Where-Object { [System.IO.File]::Exists((Join-Path $game $_)) })
    $entries = @(foreach ($rel in $files) {
        [pscustomobject]@{ path = $rel; sha256 = (Get-TkSha256 (Join-Path $pkg $rel)); replaced = ($existing -contains $rel) }
    })
    $applied = $false
    if ($PSCmdlet.ShouldProcess($game, "Install '$Name': copy $($files.Count) files, keep $($existing.Count) existing files for uninstall")) {
        $applied = $true
        # The record is written first, so an interrupted install can still be removed with Uninstall-ModPackage.
        $doc = [ordered]@{ name = $Name; installed = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); files = $entries }
        Write-TkLines $record @(($doc | ConvertTo-Json -Depth 4))
        foreach ($e in $entries) {
            $dest = Join-Path $game $e.path
            if ($e.replaced) { Move-TkFile $dest (Join-Path (Join-Path $state 'replaced') $e.path) }
            Copy-TkFile (Join-Path $pkg $e.path) $dest
            if ((Get-TkSha256 $dest) -ne $e.sha256) { throw "Copied file differs from the package: $($e.path). Run Uninstall-ModPackage -Name $Name to undo." }
        }
        Write-TkLog ("Installed '{0}' into {1}: {2} files, {3} existing files kept for uninstall" -f $Name, $game, $files.Count, $existing.Count)
    }
    [pscustomobject]@{ Name = $Name; GameDir = $game; Files = $files.Count; Replaced = $existing.Count; Applied = $applied }
}

function Uninstall-ModPackage {
    <#
    .SYNOPSIS
        Removes exactly the files Install-ModPackage copied and puts back the files it had replaced.
    .DESCRIPTION
        A file that was changed since the install (for example a settings file you edited) is left in place and
        reported. With -Force it is moved to <GameDir>\_modtoolkit\_removed\ instead. Folders that become empty
        are removed.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$GameDir,
        [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*$')][string]$Name,
        [string[]]$ProcessName,
        [switch]$Force
    )
    $game = [System.IO.Path]::GetFullPath($GameDir).TrimEnd('\')
    $state = Get-TkStateDir $game $Name
    $record = Join-Path $state 'install.json'
    if (-not (Test-Path -LiteralPath $record)) { throw "'$Name' is not installed in $game (no install record)." }
    Assert-TkNotRunning $ProcessName
    $doc = Get-Content -LiteralPath $record -Raw | ConvertFrom-Json
    $remove = New-Object 'System.Collections.Generic.List[object]'
    $modified = New-Object 'System.Collections.Generic.List[object]'
    foreach ($e in @($doc.files)) {
        $dest = Join-Path $game $e.path
        if (-not [System.IO.File]::Exists($dest)) { continue }
        if ((Get-TkSha256 $dest) -eq $e.sha256) { $remove.Add($e) } else { $modified.Add($e) }
    }
    $restoreList = @(@($doc.files) | Where-Object { $_.replaced })
    $what = "Uninstall '$Name': remove $($remove.Count) files, put back $($restoreList.Count) replaced files"
    if ($modified.Count) { if ($Force) { $what += ", move $($modified.Count) changed files aside" } else { $what += ", leave $($modified.Count) changed files in place" } }
    $applied = $false
    $kept = @()
    $restored = 0
    if ($PSCmdlet.ShouldProcess($game, $what)) {
        $applied = $true
        foreach ($e in $remove) { Remove-TkFile (Join-Path $game $e.path) }
        if ($Force -and $modified.Count) {
            $aside = New-TkStampDir (Join-Path (Join-Path $game '_modtoolkit') '_removed') $Name
            foreach ($e in $modified) { Move-TkFile (Join-Path $game $e.path) (Join-Path $aside $e.path) }
        } else {
            $kept = @($modified | ForEach-Object { $_.path })
        }
        foreach ($e in $restoreList) {
            $saved = Join-Path (Join-Path $state 'replaced') $e.path
            $dest = Join-Path $game $e.path
            if ([System.IO.File]::Exists($saved) -and -not [System.IO.File]::Exists($dest)) { Move-TkFile $saved $dest; $restored++ }
        }
        foreach ($e in @($doc.files)) { Remove-TkEmptyParents (Split-Path -Parent (Join-Path $game $e.path)) $game }
        Remove-TkFile $record
        Remove-TkEmptyTree $state
        Remove-TkEmptyParents (Join-Path $game '_modtoolkit') $game
        Write-TkLog ("Uninstalled '{0}' from {1}: {2} removed, {3} put back, {4} changed files left" -f $Name, $game, $remove.Count, $restored, $kept.Count)
    }
    [pscustomobject]@{ Name = $Name; GameDir = $game; Removed = $remove.Count; Restored = $restored; Modified = $modified.Count; KeptModified = $kept; Applied = $applied }
}

function Get-InstalledModPackage {
    <#
    .SYNOPSIS
        Lists the packages installed with Install-ModPackage in a game folder and whether their files are still intact.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$GameDir)
    $game = [System.IO.Path]::GetFullPath($GameDir).TrimEnd('\')
    $root = Join-Path $game '_modtoolkit'
    if (-not (Test-Path -LiteralPath $root)) { return }
    foreach ($dir in @(Get-ChildItem -LiteralPath $root -Directory | Sort-Object Name)) {
        $record = Join-Path $dir.FullName 'install.json'
        if (-not (Test-Path -LiteralPath $record)) { continue }
        $doc = Get-Content -LiteralPath $record -Raw | ConvertFrom-Json
        $missing = 0; $changed = 0
        foreach ($e in @($doc.files)) {
            $p = Join-Path $game $e.path
            if (-not [System.IO.File]::Exists($p)) { $missing++ } elseif ((Get-TkSha256 $p) -ne $e.sha256) { $changed++ }
        }
        [pscustomobject]@{ Name = $doc.name; Installed = $doc.installed; Files = @($doc.files).Count; Missing = $missing; Changed = $changed }
    }
}

# ------------------------------------------------------------------ file sets (switch a group of files in and out)

function New-FileSet {
    <#
    .SYNOPSIS
        Saves a group of files as a named set in a kit folder, with a SHA256SUMS.txt.
    .DESCRIPTION
        -From is a folder laid out like the game folder that holds only the files of this set (your own copies).
        Every top-level name in it is added to the kit's "managed" list: these are the entries Switch-FileSet
        moves out of the game folder before it copies a set in.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$KitDir,
        [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*$')][string]$Name,
        [Parameter(Mandatory = $true)][string]$From,
        [string[]]$ProcessName
    )
    if (-not [System.IO.Directory]::Exists($From)) { throw "Folder not found: $From" }
    $src = [System.IO.Path]::GetFullPath($From).TrimEnd('\')
    $kit = [System.IO.Path]::GetFullPath($KitDir).TrimEnd('\')
    $setDir = Join-Path (Join-Path $kit 'sets') $Name
    if (Test-Path -LiteralPath $setDir) { throw "Set '$Name' exists already in $kit." }
    $files = @(Get-TkFiles $src)
    if ($files.Count -eq 0) { throw "No files in $src" }
    $applied = $false
    if ($PSCmdlet.ShouldProcess($kit, "Save $($files.Count) files as set '$Name'")) {
        $applied = $true
        $lines = @(foreach ($rel in $files) {
            Copy-TkFile (Join-Path $src $rel) (Join-Path $setDir $rel)
            '{0} *./{1}' -f (Get-TkSha256 (Join-Path $setDir $rel)), $rel.Replace('\', '/')
        })
        Write-TkLines (Join-Path $setDir 'SHA256SUMS.txt') $lines
        $kitFile = Join-Path $kit 'kit.json'
        $managed = @(); $procs = @($ProcessName | Where-Object { $_ })
        if (Test-Path -LiteralPath $kitFile) { $k = Read-TkKit $kit; $managed = @($k.Managed); if (-not $procs.Count) { $procs = @($k.ProcessNames) } }
        $top = @($files | ForEach-Object { ($_ -split '\\')[0] })
        $managed = @(@($managed) + $top | Sort-Object -Unique)
        Write-TkLines $kitFile @(([ordered]@{ managed = $managed; processNames = $procs } | ConvertTo-Json))
        Write-TkLog "Saved set '$Name' ($($files.Count) files) in $kit"
    }
    [pscustomobject]@{ KitDir = $kit; Name = $Name; Files = $files.Count; Applied = $applied }
}

function Get-FileSetStatus {
    <#
    .SYNOPSIS
        Shows which saved set, if any, is in the game folder right now. Read-only.
    .DESCRIPTION
        A set is "active" when every file of it is in the game folder with the same SHA-256 hash and no other
        managed entry is present.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$KitDir, [Parameter(Mandatory = $true)][string]$GameDir)
    $kit = [System.IO.Path]::GetFullPath($KitDir).TrimEnd('\')
    $game = [System.IO.Path]::GetFullPath($GameDir).TrimEnd('\')
    $k = Read-TkKit $kit
    $present = @($k.Managed | Where-Object { Test-Path -LiteralPath (Join-Path $game $_) })
    $active = $null
    $sets = @(Get-TkKitSets $kit)
    foreach ($s in $sets) {
        $setDir = Join-Path (Join-Path $kit 'sets') $s
        $want = Read-TkSums (Join-Path $setDir 'SHA256SUMS.txt')
        $top = @($want.Keys | ForEach-Object { ($_ -split '\\')[0] } | Sort-Object -Unique)
        if ((@($top) -join '|') -ne (@($present | Sort-Object) -join '|')) { continue }
        $same = $true
        foreach ($rel in $want.Keys) {
            $p = Join-Path $game $rel
            if (-not [System.IO.File]::Exists($p) -or (Get-TkSha256 $p) -ne $want[$rel]) { $same = $false; break }
        }
        if ($same) { $active = $s; break }
    }
    [pscustomobject]@{ Sets = $sets; Active = $active; ManagedPresent = $present }
}

function Switch-FileSet {
    <#
    .SYNOPSIS
        Switches the game folder to a saved set of files, or undoes the last switch.
    .DESCRIPTION
        Nothing is deleted. Every managed entry found in the game folder is moved to
        <KitDir>\swapped_out\<time stamp>_before_<set>\, then the chosen set is copied in and every copied file
        is compared with the set's SHA256SUMS.txt. The set itself is checked against its SHA256SUMS.txt before
        anything is touched. -Undo moves the current entries out the same way and puts the entries of the most
        recent swapped_out folder back.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'To')]
    param(
        [Parameter(Mandatory = $true)][string]$KitDir,
        [Parameter(Mandatory = $true)][string]$GameDir,
        [Parameter(Mandatory = $true, ParameterSetName = 'To')][string]$To,
        [Parameter(Mandatory = $true, ParameterSetName = 'Undo')][switch]$Undo
    )
    $kit = [System.IO.Path]::GetFullPath($KitDir).TrimEnd('\')
    $game = [System.IO.Path]::GetFullPath($GameDir).TrimEnd('\')
    if (-not [System.IO.Directory]::Exists($game)) { throw "Game folder not found: $game" }
    $k = Read-TkKit $kit
    Assert-TkNotRunning $k.ProcessNames
    $outRoot = Join-Path $kit 'swapped_out'
    $present = @($k.Managed | Where-Object { Test-Path -LiteralPath (Join-Path $game $_) })

    if ($Undo) {
        $last = $null
        if (Test-Path -LiteralPath $outRoot) { $last = Get-ChildItem -LiteralPath $outRoot -Directory | Sort-Object CreationTimeUtc, Name | Select-Object -Last 1 }
        if (-not $last) { throw "Nothing to undo: $outRoot is empty." }
        $back = @(Get-ChildItem -LiteralPath $last.FullName -Force)
        $applied = $false
        if ($PSCmdlet.ShouldProcess($game, "Undo the last switch: move $($present.Count) entries out, put $($back.Count) entries back from $($last.Name)")) {
            $applied = $true
            $out = New-TkStampDir $outRoot 'before_undo'
            foreach ($name in $present) { Move-Item -LiteralPath (Join-Path $game $name) -Destination (Join-Path $out $name) }
            foreach ($item in $back) { Move-Item -LiteralPath $item.FullName -Destination (Join-Path $game $item.Name) }
            Remove-TkEmptyTree $last.FullName
            Write-TkLog "Undid the last switch in $game (restored from $($last.Name), previous entries in $out)"
        }
        return [pscustomobject]@{ GameDir = $game; Set = $null; Undone = $last.Name; MovedOut = $present.Count; Copied = 0; Applied = $applied }
    }

    $sets = @(Get-TkKitSets $kit)
    if ($sets -notcontains $To) { throw "Unknown set '$To'. Sets: $($sets -join ', ')" }
    $setDir = Join-Path (Join-Path $kit 'sets') $To
    $sums = Join-Path $setDir 'SHA256SUMS.txt'
    if (-not (Test-Path -LiteralPath $sums)) { throw "SHA256SUMS.txt is missing in set '$To'." }
    $want = Read-TkSums $sums
    foreach ($rel in $want.Keys) {
        $p = Join-Path $setDir $rel
        if (-not [System.IO.File]::Exists($p) -or (Get-TkSha256 $p) -ne $want[$rel]) { throw "A file of set '$To' does not match its SHA256SUMS.txt: $rel. Nothing was changed." }
    }
    $applied = $false
    $out = $null
    if ($PSCmdlet.ShouldProcess($game, "Switch to set '$To': move $($present.Count) managed entries out, copy $($want.Count) files in")) {
        $applied = $true
        $out = New-TkStampDir $outRoot "before_$To"
        foreach ($name in $present) { Move-Item -LiteralPath (Join-Path $game $name) -Destination (Join-Path $out $name) }
        foreach ($rel in ($want.Keys | Sort-Object)) { Copy-TkFile (Join-Path $setDir $rel) (Join-Path $game $rel) }
        $bad = @($want.Keys | Where-Object { (Get-TkSha256 (Join-Path $game $_)) -ne $want[$_] })
        if ($bad.Count) { throw "Copied files differ from the set: $($bad -join ', '). The previous files are in $out" }
        Write-TkLog "Switched $game to set '$To' ($($want.Count) files, all hashes match); previous entries in $out"
    }
    [pscustomobject]@{ GameDir = $game; Set = $To; Undone = $null; MovedOut = $present.Count; Copied = $want.Count; SwappedOutTo = $out; Applied = $applied }
}

# ------------------------------------------------------------------ move a folder to another drive, leave a junction

function Get-TkTreeStat {
    param([string]$Path)
    $files = @(Get-TkFiles $Path)
    [long]$bytes = 0
    foreach ($f in $files) { $bytes += (New-Object System.IO.FileInfo (Join-Path $Path $f)).Length }
    [pscustomobject]@{ Count = $files.Count; Bytes = $bytes }
}

function Move-FolderToDrive {
    <#
    .SYNOPSIS
        Moves a folder to another place (usually another drive) and leaves a directory junction at the old path.
    .DESCRIPTION
        Programs and scripts keep working with the old path. The folder is renamed first (this fails while a
        program has a file in it open, before anything is copied), then copied, then file count and total size
        are compared, and only then is the original removed. If any step fails, the original folder is put back.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Destination)
    $src = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $dst = [System.IO.Path]::GetFullPath($Destination).TrimEnd('\')
    $item = Get-Item -LiteralPath $src -Force
    if (-not $item.PSIsContainer) { throw "Not a folder: $src" }
    if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { throw "Already a link, nothing to move: $src" }
    if (Test-Path -LiteralPath $dst) { throw "Destination exists already: $dst" }
    if (($dst + '\').StartsWith($src + '\', [System.StringComparison]::OrdinalIgnoreCase)) { throw 'Destination must not be inside the folder that is moved.' }
    $applied = $false
    $stat = Get-TkTreeStat $src
    if ($PSCmdlet.ShouldProcess($src, ("Move {0} files ({1:N1} MB) to {2} and leave a junction" -f $stat.Count, ($stat.Bytes / 1MB), $dst))) {
        $applied = $true
        $tmp = "$src.__moving"
        Rename-Item -LiteralPath $src -NewName (Split-Path -Leaf $tmp)
        try {
            New-TkDirectory (Split-Path -Parent $dst)
            & robocopy $tmp $dst /E /COPY:DAT /DCOPY:DAT /R:1 /W:1 /NFL /NDL /NP /NJH /NJS | Out-Null
            if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE)" }
            $after = Get-TkTreeStat $dst
            if ($after.Count -ne $stat.Count -or $after.Bytes -ne $stat.Bytes) { throw "Copy does not match: $($stat.Count) files / $($stat.Bytes) bytes before, $($after.Count) / $($after.Bytes) after" }
            New-Item -ItemType Junction -Path $src -Target $dst | Out-Null
        } catch {
            if (-not (Test-Path -LiteralPath $src)) { Rename-Item -LiteralPath $tmp -NewName (Split-Path -Leaf $src) }
            throw "Move failed, the original folder is back in place: $_"
        }
        & cmd /c rmdir /s /q "`"$tmp`""
        if (Test-Path -LiteralPath $tmp) { Write-Warning "The copy is complete, but the old folder could not be removed completely: $tmp" }
        Write-TkLog ("Moved {0} to {1} ({2} files), junction left at the old path" -f $src, $dst, $stat.Count)
    }
    [pscustomobject]@{ Path = $src; Destination = $dst; Files = $stat.Count; Bytes = $stat.Bytes; Applied = $applied }
}

function Restore-MovedFolder {
    <#
    .SYNOPSIS
        Undoes Move-FolderToDrive: removes the junction and moves the folder back to its old path.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory = $true)][string]$Path)
    $src = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $item = Get-Item -LiteralPath $src -Force
    if (-not ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { throw "Not a junction: $src" }
    $target = [string](@($item.Target)[0])
    if (-not $target -or -not [System.IO.Directory]::Exists($target)) { throw "The junction's target was not found: $target" }
    $stat = Get-TkTreeStat $target
    $applied = $false
    if ($PSCmdlet.ShouldProcess($src, ("Move {0} files ({1:N1} MB) back from {2} and remove the junction" -f $stat.Count, ($stat.Bytes / 1MB), $target))) {
        $applied = $true
        [System.IO.Directory]::Delete($src, $false)   # removes the junction only, never the target's content
        if (Test-Path -LiteralPath $src) { throw "The junction could not be removed: $src" }
        & robocopy $target $src /E /COPY:DAT /DCOPY:DAT /R:1 /W:1 /NFL /NDL /NP /NJH /NJS | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE). The files are still in $target" }
        $after = Get-TkTreeStat $src
        if ($after.Count -ne $stat.Count -or $after.Bytes -ne $stat.Bytes) { throw "Copy does not match. The files are still in $target" }
        & cmd /c rmdir /s /q "`"$target`""
        Write-TkLog ("Moved {0} back from {1} ({2} files)" -f $src, $target, $stat.Count)
    }
    [pscustomobject]@{ Path = $src; From = $target; Files = $stat.Count; Applied = $applied }
}

Export-ModuleMember -Function Set-ModToolkitLog, Get-ModToolkitConfig, Backup-GameMods, Test-GameBackup, Restore-GameMods,
    Install-ModPackage, Uninstall-ModPackage, Get-InstalledModPackage, New-FileSet, Get-FileSetStatus, Switch-FileSet,
    Move-FolderToDrive, Restore-MovedFolder
