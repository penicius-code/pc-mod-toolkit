# Helpers for the tests: build a small mock game folder in a temporary place. No real game is touched.

function New-TestFile {
    param([string]$Path, [string]$Text = 'x')
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    [System.IO.File]::WriteAllText($Path, $Text)
}

function Get-TestText {
    param([string]$Path)
    [System.IO.File]::ReadAllText($Path)
}

function New-TestRoot {
    param([string]$Base)
    $root = Join-Path $Base ([guid]::NewGuid().ToString('N').Substring(0, 8))
    [void](New-Item -ItemType Directory -Path $root -Force)
    $root
}

# A mock game: two mod areas, one root settings file, a "version file", and content the config does not select.
function New-TestGame {
    param([string]$Root, [string[]]$ProcessNames = @())
    $game = Join-Path $Root 'Game'
    $backup = Join-Path $Root 'Backup'
    New-TestFile (Join-Path $game 'bin\game.exe') 'build-1'
    New-TestFile (Join-Path $game 'mods\scripts\a.lua') 'print("a")'
    New-TestFile (Join-Path $game 'mods\scripts\sub\b.lua') 'print("b")'
    New-TestFile (Join-Path $game 'bin\plugins\p.ini') 'key=1'
    New-TestFile (Join-Path $game 'settings.ini') 'volume=5'
    New-TestFile (Join-Path $game 'data\big.pak') 'stock game content'
    $config = Join-Path $Root 'game.json'
    $doc = [ordered]@{
        name         = 'Mock Game'
        gameDir      = $game
        backupDir    = $backup
        processNames = @($ProcessNames)
        versionFile  = 'bin\game.exe'
        areas        = [ordered]@{ scripts = 'mods\scripts'; plugins = 'bin\plugins' }
        rootFiles    = @('*.ini')
    }
    [System.IO.File]::WriteAllText($config, ($doc | ConvertTo-Json -Depth 4))
    [pscustomobject]@{ Root = $Root; Game = $game; Backup = $backup; Config = $config }
}
