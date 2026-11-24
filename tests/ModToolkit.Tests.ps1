# Pester 5 tests. Everything runs against a mock game folder under $TestDrive; no real game is touched.
# Run: Invoke-Pester -Path tests

Describe 'Config' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\ModToolkit\ModToolkit.psd1') -Force
        . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    }
    BeforeEach {
        $t = New-TestGame (New-TestRoot $TestDrive)
    }

    It 'reads the sample layout and normalises the areas' {
        $cfg = Get-ModToolkitConfig -Path $t.Config
        $cfg.Name | Should -Be 'Mock Game'
        $cfg.GameDir | Should -Be $t.Game
        $cfg.Areas['scripts'] | Should -Be 'mods\scripts'
        $cfg.Areas.Count | Should -Be 2
        $cfg.VersionFile | Should -Be 'bin\game.exe'
    }

    It 'expands environment variables in paths' {
        $env:MODTOOLKIT_TEST_ROOT = $t.Root
        $doc = Get-Content -LiteralPath $t.Config -Raw | ConvertFrom-Json
        $doc.gameDir = '%MODTOOLKIT_TEST_ROOT%\Game'
        [System.IO.File]::WriteAllText($t.Config, ($doc | ConvertTo-Json -Depth 4))
        (Get-ModToolkitConfig -Path $t.Config).GameDir | Should -Be $t.Game
    }

    It 'rejects an area that leaves the game folder' {
        $doc = Get-Content -LiteralPath $t.Config -Raw | ConvertFrom-Json
        $doc.areas.scripts = '..\elsewhere'
        [System.IO.File]::WriteAllText($t.Config, ($doc | ConvertTo-Json -Depth 4))
        { Get-ModToolkitConfig -Path $t.Config } | Should -Throw -ExpectedMessage '*relative to the game folder*'
    }

    It 'rejects a backup folder inside the game folder' {
        $doc = Get-Content -LiteralPath $t.Config -Raw | ConvertFrom-Json
        $doc.backupDir = Join-Path $t.Game 'backup'
        [System.IO.File]::WriteAllText($t.Config, ($doc | ConvertTo-Json -Depth 4))
        { Get-ModToolkitConfig -Path $t.Config } | Should -Throw -ExpectedMessage '*must not be inside the game folder*'
    }

    It 'rejects a game folder that does not exist' {
        $doc = Get-Content -LiteralPath $t.Config -Raw | ConvertFrom-Json
        $doc.gameDir = Join-Path $t.Root 'missing'
        [System.IO.File]::WriteAllText($t.Config, ($doc | ConvertTo-Json -Depth 4))
        { Get-ModToolkitConfig -Path $t.Config } | Should -Throw -ExpectedMessage '*game folder not found*'
    }
}

Describe 'Backup-GameMods and Test-GameBackup' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\ModToolkit\ModToolkit.psd1') -Force
        . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    }
    BeforeEach {
        $t = New-TestGame (New-TestRoot $TestDrive)
    }

    It 'copies the selected files only and writes a manifest that verifies' {
        $r = Backup-GameMods -Config $t.Config
        $r.Applied | Should -BeTrue
        $r.Copied | Should -Be 4
        (Test-Path -LiteralPath (Join-Path $t.Backup 'files\mods\scripts\sub\b.lua')) | Should -BeTrue
        (Test-Path -LiteralPath (Join-Path $t.Backup 'files\settings.ini')) | Should -BeTrue
        (Test-Path -LiteralPath (Join-Path $t.Backup 'files\data\big.pak')) | Should -BeFalse
        (Test-Path -LiteralPath (Join-Path $t.Backup 'files\bin\game.exe')) | Should -BeFalse
        @(Get-Content -LiteralPath (Join-Path $t.Backup 'manifest.sha256.txt')).Count | Should -Be 4
        $v = Test-GameBackup -Config $t.Config
        $v.Ok | Should -BeTrue
        $v.Files | Should -Be 4
    }

    It 'changes nothing with -WhatIf and reports what it would copy' {
        $r = Backup-GameMods -Config $t.Config -WhatIf
        $r.Applied | Should -BeFalse
        $r.Copied | Should -Be 4
        (Test-Path -LiteralPath $t.Backup) | Should -BeFalse
    }

    It 'copies only new or changed files on the next run' {
        [void](Backup-GameMods -Config $t.Config)
        (Backup-GameMods -Config $t.Config).Copied | Should -Be 0
        New-TestFile (Join-Path $t.Game 'mods\scripts\a.lua') 'print("a, changed and longer")'
        New-TestFile (Join-Path $t.Game 'mods\scripts\c.lua') 'print("c")'
        $r = Backup-GameMods -Config $t.Config
        $r.Copied | Should -Be 2
        $r.Unchanged | Should -Be 3
        (Test-GameBackup -Config $t.Config).Files | Should -Be 5
    }

    It 'keeps files that left the game folder unless -Mirror is given' {
        [void](Backup-GameMods -Config $t.Config)
        Remove-Item -LiteralPath (Join-Path $t.Game 'mods\scripts\sub\b.lua')
        (Backup-GameMods -Config $t.Config).Removed | Should -Be 0
        (Test-Path -LiteralPath (Join-Path $t.Backup 'files\mods\scripts\sub\b.lua')) | Should -BeTrue
        (Backup-GameMods -Config $t.Config -Mirror).Removed | Should -Be 1
        (Test-Path -LiteralPath (Join-Path $t.Backup 'files\mods\scripts\sub\b.lua')) | Should -BeFalse
        (Test-GameBackup -Config $t.Config).Files | Should -Be 3
    }

    It 'finds damage in the backup' {
        [void](Backup-GameMods -Config $t.Config)
        New-TestFile (Join-Path $t.Backup 'files\settings.ini') 'volume=9'
        Remove-Item -LiteralPath (Join-Path $t.Backup 'files\bin\plugins\p.ini')
        $v = Test-GameBackup -Config $t.Config
        $v.Ok | Should -BeFalse
        ($v.Changed -join ',') | Should -Be 'settings.ini'
        ($v.Missing -join ',') | Should -Be 'bin\plugins\p.ini'
    }

    It 'reports what changed in the game folder since the backup with -Live' {
        [void](Backup-GameMods -Config $t.Config)
        New-TestFile (Join-Path $t.Game 'settings.ini') 'volume=11'
        Remove-Item -LiteralPath (Join-Path $t.Game 'mods\scripts\a.lua')
        New-TestFile (Join-Path $t.Game 'mods\scripts\new.lua') 'print("new")'
        $v = Test-GameBackup -Config $t.Config -Live
        ($v.Changed -join ',') | Should -Be 'settings.ini'
        ($v.Missing -join ',') | Should -Be 'mods\scripts\a.lua'
        ($v.Extra -join ',') | Should -Be 'mods\scripts\new.lua'
    }

    It 'refuses to run while the game process is running' {
        $me = (Get-Process -Id $PID).ProcessName
        $busy = New-TestGame (New-TestRoot $TestDrive) -ProcessNames @($me)
        { Backup-GameMods -Config $busy.Config } | Should -Throw -ExpectedMessage '*is running*'
        (Test-Path -LiteralPath $busy.Backup) | Should -BeFalse
    }
}

Describe 'Restore-GameMods' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\ModToolkit\ModToolkit.psd1') -Force
        . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    }
    BeforeEach {
        $t = New-TestGame (New-TestRoot $TestDrive)
        [void](Backup-GameMods -Config $t.Config)
        # after the backup: one file changed, one deleted, one added
        New-TestFile (Join-Path $t.Game 'mods\scripts\a.lua') 'print("broken edit")'
        Remove-Item -LiteralPath (Join-Path $t.Game 'bin\plugins\p.ini')
        New-TestFile (Join-Path $t.Game 'mods\scripts\added.lua') 'print("added")'
    }

    It 'puts back changed and missing files and keeps the replaced file' {
        $r = Restore-GameMods -Config $t.Config
        $r.Restored | Should -Be 2
        $r.Unchanged | Should -Be 2
        Get-TestText (Join-Path $t.Game 'mods\scripts\a.lua') | Should -Be 'print("a")'
        Get-TestText (Join-Path $t.Game 'bin\plugins\p.ini') | Should -Be 'key=1'
        Get-TestText (Join-Path $r.ParkedIn 'mods\scripts\a.lua') | Should -Be 'print("broken edit")'
        (Test-Path -LiteralPath (Join-Path $t.Game 'mods\scripts\added.lua')) | Should -BeTrue
        (Test-GameBackup -Config $t.Config -Live).Ok | Should -BeTrue
    }

    It 'moves added files out with -RemoveAdded instead of deleting them' {
        $r = Restore-GameMods -Config $t.Config -RemoveAdded
        $r.Added | Should -Be 1
        (Test-Path -LiteralPath (Join-Path $t.Game 'mods\scripts\added.lua')) | Should -BeFalse
        Get-TestText (Join-Path $r.ParkedIn 'mods\scripts\added.lua') | Should -Be 'print("added")'
        (Test-GameBackup -Config $t.Config -Live).Extra.Count | Should -Be 0
    }

    It 'changes nothing with -WhatIf' {
        $r = Restore-GameMods -Config $t.Config -RemoveAdded -WhatIf
        $r.Applied | Should -BeFalse
        $r.Restored | Should -Be 2
        Get-TestText (Join-Path $t.Game 'mods\scripts\a.lua') | Should -Be 'print("broken edit")'
        (Test-Path -LiteralPath (Join-Path $t.Game 'bin\plugins\p.ini')) | Should -BeFalse
        (Test-Path -LiteralPath (Join-Path $t.Backup 'replaced')) | Should -BeFalse
    }

    It 'restores one area only with -Only' {
        $r = Restore-GameMods -Config $t.Config -Only plugins
        $r.Restored | Should -Be 1
        Get-TestText (Join-Path $t.Game 'bin\plugins\p.ini') | Should -Be 'key=1'
        Get-TestText (Join-Path $t.Game 'mods\scripts\a.lua') | Should -Be 'print("broken edit")'
    }

    It 'rejects an unknown area name' {
        { Restore-GameMods -Config $t.Config -Only nothere } | Should -Throw -ExpectedMessage '*Unknown area*'
    }

    It 'stops when the game was updated since the backup, unless -Force is given' {
        New-TestFile (Join-Path $t.Game 'bin\game.exe') 'build-2'
        { Restore-GameMods -Config $t.Config } | Should -Throw -ExpectedMessage '*Nothing was restored*'
        Get-TestText (Join-Path $t.Game 'mods\scripts\a.lua') | Should -Be 'print("broken edit")'
        (Restore-GameMods -Config $t.Config -Force).Restored | Should -Be 2
    }

    It 'stops when the backup itself is damaged' {
        New-TestFile (Join-Path $t.Backup 'files\settings.ini') 'tampered'
        { Restore-GameMods -Config $t.Config } | Should -Throw -ExpectedMessage '*does not match its manifest*'
        Get-TestText (Join-Path $t.Game 'mods\scripts\a.lua') | Should -Be 'print("broken edit")'
    }
}

Describe 'Install-ModPackage and Uninstall-ModPackage' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\ModToolkit\ModToolkit.psd1') -Force
        . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    }
    BeforeEach {
        $t = New-TestGame (New-TestRoot $TestDrive)
        $pkg = Join-Path $t.Root 'package'
        New-TestFile (Join-Path $pkg 'mods\scripts\mymod\init.lua') 'print("my mod")'
        New-TestFile (Join-Path $pkg 'mods\scripts\mymod\config.json') '{"enabled":true}'
        New-TestFile (Join-Path $pkg 'bin\plugins\p.ini') 'key=2'
    }

    It 'installs the package, records it and removes it again without leftovers' {
        $r = Install-ModPackage -PackagePath $pkg -GameDir $t.Game -Name my-mod
        $r.Files | Should -Be 3
        $r.Replaced | Should -Be 1
        Get-TestText (Join-Path $t.Game 'mods\scripts\mymod\init.lua') | Should -Be 'print("my mod")'
        Get-TestText (Join-Path $t.Game 'bin\plugins\p.ini') | Should -Be 'key=2'
        $list = @(Get-InstalledModPackage -GameDir $t.Game)
        $list.Count | Should -Be 1
        $list[0].Name | Should -Be 'my-mod'
        $list[0].Changed | Should -Be 0

        $u = Uninstall-ModPackage -GameDir $t.Game -Name my-mod
        $u.Removed | Should -Be 3
        $u.Restored | Should -Be 1
        Get-TestText (Join-Path $t.Game 'bin\plugins\p.ini') | Should -Be 'key=1'
        (Test-Path -LiteralPath (Join-Path $t.Game 'mods\scripts\mymod')) | Should -BeFalse
        (Test-Path -LiteralPath (Join-Path $t.Game '_modtoolkit')) | Should -BeFalse
        (Test-Path -LiteralPath (Join-Path $t.Game 'mods\scripts\a.lua')) | Should -BeTrue
    }

    It 'changes nothing with -WhatIf' {
        $r = Install-ModPackage -PackagePath $pkg -GameDir $t.Game -Name my-mod -WhatIf
        $r.Applied | Should -BeFalse
        (Test-Path -LiteralPath (Join-Path $t.Game 'mods\scripts\mymod')) | Should -BeFalse
        (Test-Path -LiteralPath (Join-Path $t.Game '_modtoolkit')) | Should -BeFalse
        Get-TestText (Join-Path $t.Game 'bin\plugins\p.ini') | Should -Be 'key=1'
    }

    It 'refuses a second install under the same name' {
        [void](Install-ModPackage -PackagePath $pkg -GameDir $t.Game -Name my-mod)
        { Install-ModPackage -PackagePath $pkg -GameDir $t.Game -Name my-mod } | Should -Throw -ExpectedMessage '*already installed*'
    }

    It 'leaves a file the user changed in place on uninstall and reports it' {
        [void](Install-ModPackage -PackagePath $pkg -GameDir $t.Game -Name my-mod)
        New-TestFile (Join-Path $t.Game 'mods\scripts\mymod\config.json') '{"enabled":false}'
        @(Get-InstalledModPackage -GameDir $t.Game)[0].Changed | Should -Be 1
        $u = Uninstall-ModPackage -GameDir $t.Game -Name my-mod
        $u.Removed | Should -Be 2
        ($u.KeptModified -join ',') | Should -Be 'mods\scripts\mymod\config.json'
        Get-TestText (Join-Path $t.Game 'mods\scripts\mymod\config.json') | Should -Be '{"enabled":false}'
        (Test-Path -LiteralPath (Join-Path $t.Game 'mods\scripts\mymod\init.lua')) | Should -BeFalse
    }

    It 'moves a changed file aside on uninstall with -Force' {
        [void](Install-ModPackage -PackagePath $pkg -GameDir $t.Game -Name my-mod)
        New-TestFile (Join-Path $t.Game 'mods\scripts\mymod\config.json') '{"enabled":false}'
        $u = Uninstall-ModPackage -GameDir $t.Game -Name my-mod -Force
        $u.Modified | Should -Be 1
        (Test-Path -LiteralPath (Join-Path $t.Game 'mods\scripts\mymod')) | Should -BeFalse
        $aside = @(Get-ChildItem -LiteralPath (Join-Path $t.Game '_modtoolkit\_removed') -Recurse -File)
        $aside.Count | Should -Be 1
        Get-TestText $aside[0].FullName | Should -Be '{"enabled":false}'
    }

    It 'rejects an uninstall of something that is not installed' {
        { Uninstall-ModPackage -GameDir $t.Game -Name other } | Should -Throw -ExpectedMessage '*is not installed*'
    }
}

Describe 'File sets' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\ModToolkit\ModToolkit.psd1') -Force
        . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    }
    BeforeEach {
        $t = New-TestGame (New-TestRoot $TestDrive)
        $kit = Join-Path $t.Root 'kit'
        # the game ships its own loader.dll; set "a" and set "b" each bring their own files
        New-TestFile (Join-Path $t.Game 'loader.dll') 'stock loader'
        New-TestFile (Join-Path $t.Root 'src-a\loader.dll') 'loader A'
        New-TestFile (Join-Path $t.Root 'src-a\addon\a.ini') 'mode=a'
        New-TestFile (Join-Path $t.Root 'src-b\loader.dll') 'loader B'
        New-TestFile (Join-Path $t.Root 'src-b\extra.dll') 'extra B'
        [void](New-FileSet -KitDir $kit -Name a -From (Join-Path $t.Root 'src-a'))
        [void](New-FileSet -KitDir $kit -Name b -From (Join-Path $t.Root 'src-b'))
    }

    It 'saves sets with checksums and a managed list' {
        (Test-Path -LiteralPath (Join-Path $kit 'sets\a\SHA256SUMS.txt')) | Should -BeTrue
        $k = Get-Content -LiteralPath (Join-Path $kit 'kit.json') -Raw | ConvertFrom-Json
        (@($k.managed) -join ',') | Should -Be 'addon,extra.dll,loader.dll'
        $s = Get-FileSetStatus -KitDir $kit -GameDir $t.Game
        ($s.Sets -join ',') | Should -Be 'a,b'
        $s.Active | Should -BeNullOrEmpty
    }

    It 'switches between sets, keeps what it moved out and leaves other files alone' {
        $r = Switch-FileSet -KitDir $kit -GameDir $t.Game -To a
        $r.MovedOut | Should -Be 1
        $r.Copied | Should -Be 2
        Get-TestText (Join-Path $t.Game 'loader.dll') | Should -Be 'loader A'
        Get-TestText (Join-Path $r.SwappedOutTo 'loader.dll') | Should -Be 'stock loader'
        (Get-FileSetStatus -KitDir $kit -GameDir $t.Game).Active | Should -Be 'a'

        $r2 = Switch-FileSet -KitDir $kit -GameDir $t.Game -To b
        $r2.MovedOut | Should -Be 2
        Get-TestText (Join-Path $t.Game 'loader.dll') | Should -Be 'loader B'
        (Test-Path -LiteralPath (Join-Path $t.Game 'addon')) | Should -BeFalse
        (Test-Path -LiteralPath (Join-Path $t.Game 'extra.dll')) | Should -BeTrue
        (Get-FileSetStatus -KitDir $kit -GameDir $t.Game).Active | Should -Be 'b'
        Get-TestText (Join-Path $t.Game 'settings.ini') | Should -Be 'volume=5'
        Get-TestText (Join-Path $t.Game 'mods\scripts\a.lua') | Should -Be 'print("a")'
    }

    It 'undoes the last switch' {
        [void](Switch-FileSet -KitDir $kit -GameDir $t.Game -To a)
        $u = Switch-FileSet -KitDir $kit -GameDir $t.Game -Undo
        $u.Applied | Should -BeTrue
        Get-TestText (Join-Path $t.Game 'loader.dll') | Should -Be 'stock loader'
        (Test-Path -LiteralPath (Join-Path $t.Game 'addon')) | Should -BeFalse
        (Get-FileSetStatus -KitDir $kit -GameDir $t.Game).Active | Should -BeNullOrEmpty
    }

    It 'changes nothing with -WhatIf' {
        $r = Switch-FileSet -KitDir $kit -GameDir $t.Game -To a -WhatIf
        $r.Applied | Should -BeFalse
        Get-TestText (Join-Path $t.Game 'loader.dll') | Should -Be 'stock loader'
        (Test-Path -LiteralPath (Join-Path $kit 'swapped_out')) | Should -BeFalse
    }

    It 'refuses a set whose files no longer match their checksums' {
        New-TestFile (Join-Path $kit 'sets\a\loader.dll') 'tampered'
        { Switch-FileSet -KitDir $kit -GameDir $t.Game -To a } | Should -Throw -ExpectedMessage '*does not match its SHA256SUMS*'
        Get-TestText (Join-Path $t.Game 'loader.dll') | Should -Be 'stock loader'
    }

    It 'rejects an unknown set and an undo with nothing to undo' {
        { Switch-FileSet -KitDir $kit -GameDir $t.Game -To zzz } | Should -Throw -ExpectedMessage '*Unknown set*'
        { Switch-FileSet -KitDir $kit -GameDir $t.Game -Undo } | Should -Throw -ExpectedMessage '*Nothing to undo*'
    }
}

Describe 'Move-FolderToDrive and Restore-MovedFolder' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\ModToolkit\ModToolkit.psd1') -Force
        . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    }
    BeforeEach {
        $root = New-TestRoot $TestDrive
        $src = Join-Path $root 'here\Big Folder'
        $dst = Join-Path $root 'other drive\Big Folder'
        New-TestFile (Join-Path $src 'one.bin') '1111'
        New-TestFile (Join-Path $src 'deep\two.bin') '22'
    }

    It 'moves the folder, leaves a junction and the old path keeps working' {
        $r = Move-FolderToDrive -Path $src -Destination $dst
        $r.Files | Should -Be 2
        Get-TestText (Join-Path $dst 'deep\two.bin') | Should -Be '22'
        Get-TestText (Join-Path $src 'one.bin') | Should -Be '1111'
        [bool]((Get-Item -LiteralPath $src -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) | Should -BeTrue
        (Test-Path -LiteralPath "$src.__moving") | Should -BeFalse
        [System.IO.Directory]::Delete($src, $false)   # remove the junction again so the temporary folder cleans up
    }

    It 'moves it back and removes the junction' {
        [void](Move-FolderToDrive -Path $src -Destination $dst)
        $r = Restore-MovedFolder -Path $src
        $r.Files | Should -Be 2
        [bool]((Get-Item -LiteralPath $src -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) | Should -BeFalse
        Get-TestText (Join-Path $src 'deep\two.bin') | Should -Be '22'
        (Test-Path -LiteralPath $dst) | Should -BeFalse
    }

    It 'changes nothing with -WhatIf' {
        $r = Move-FolderToDrive -Path $src -Destination $dst -WhatIf
        $r.Applied | Should -BeFalse
        (Test-Path -LiteralPath $dst) | Should -BeFalse
        [bool]((Get-Item -LiteralPath $src -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) | Should -BeFalse
    }

    It 'refuses when the destination exists already' {
        New-TestFile (Join-Path $dst 'old.bin') 'old'
        { Move-FolderToDrive -Path $src -Destination $dst } | Should -Throw -ExpectedMessage '*Destination exists already*'
        Get-TestText (Join-Path $src 'one.bin') | Should -Be '1111'
    }
}

Describe 'Log file' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\ModToolkit\ModToolkit.psd1') -Force
        . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    }
    AfterAll {
        Set-ModToolkitLog
    }

    It 'records real changes and skips dry runs' {
        $t = New-TestGame (New-TestRoot $TestDrive)
        $log = Join-Path $t.Root 'logs\toolkit.log'
        Set-ModToolkitLog -Path $log
        [void](Backup-GameMods -Config $t.Config -WhatIf)
        (Test-Path -LiteralPath $log) | Should -BeFalse
        [void](Backup-GameMods -Config $t.Config)
        $lines = @(Get-Content -LiteralPath $log)
        $lines.Count | Should -Be 1
        ($lines[0] -like '*Backup of ''Mock Game''*4 copied*') | Should -BeTrue
    }
}
