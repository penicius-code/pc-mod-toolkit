# pc-mod-toolkit

A PowerShell module that installs, backs up, verifies, switches and rolls back the files of a modded PC game. Single-player games only.
Version 0.1.0 | Windows 10/11, Windows PowerShell 5.1 or PowerShell 7 | Status: 36 tests pass on a mock game folder in both PowerShell versions; backup and verify also run against a real game folder (see Status)

> Unofficial tool, not affiliated with any game publisher or mod platform. No game files, no mods and no vendor files are included. It only moves and copies files you already have.

## The problem

A modded game folder is fragile. A game update, a mod manager, or one wrong copy can break a setup that took days to build, and it is rarely clear afterwards which files changed. I had a separate backup, restore and switch script for each game, each with my own paths written into it.

## What I built

One module, `ModToolkit`, with a small JSON file per game instead of hard-coded paths. It changes: files inside the game folder you name, and files inside the backup or kit folder you name. Nothing else.

| Task | Command | Undo |
|---|---|---|
| Back up the mod areas of a game, with a SHA-256 manifest | `Backup-GameMods` | the backup is a copy; delete it |
| Check the backup, or see what changed in the game since | `Test-GameBackup`, `Test-GameBackup -Live` | read-only |
| Put the backup back | `Restore-GameMods` | replaced files are kept in `replaced\<time>` |
| Install one mod package with a record | `Install-ModPackage` | `Uninstall-ModPackage` |
| List installed packages and whether their files are intact | `Get-InstalledModPackage` | read-only |
| Save a group of files as a named set | `New-FileSet` | delete the set folder |
| Switch the game between saved sets | `Switch-FileSet -To <set>` | `Switch-FileSet -Undo` |
| Show which set is active | `Get-FileSetStatus` | read-only |
| Move a large folder to another drive, leave a junction | `Move-FolderToDrive` | `Restore-MovedFolder` |
| Write every change to a log file | `Set-ModToolkitLog` | |

## How it works

Four rules hold for every command that changes files:

- **Dry run first.** Each one supports `-WhatIf`: it prints what it would do, with file counts, and changes nothing.
- **Nothing is deleted.** A file that would be overwritten or removed is moved to a dated folder first. The one exception is `Uninstall-ModPackage`, which deletes the files it installed itself, and only while their hash still matches the install record.
- **Check before, check after.** A set or backup is compared with its SHA-256 list before the game folder is touched. Every copied file is hashed again afterwards.
- **Not while the game runs.** If a process named in the config is running, the command stops before it changes anything.

Other details:

- `Restore-GameMods` compares the game's version file (usually the executable) with the one recorded at backup time. If the game was updated in between, it stops; `-Force` overrides.
- `Install-ModPackage` writes its record before it copies, so an interrupted install can still be removed cleanly.
- `Uninstall-ModPackage` leaves a file in place if you changed it after the install (a settings file, for example) and tells you. `-Force` moves it aside instead.
- `Move-FolderToDrive` renames the folder first. That fails at once if a program still has a file in it open, before a single byte is copied. The original is removed only after file count and total size match.
- Links (junctions) inside a mod area are not followed.

```text
ModToolkit/ModToolkit.psm1   the module (13 commands)
ModToolkit/ModToolkit.psd1   module manifest
config.sample.json           one game: folder, backup folder, mod areas, process name
examples/                    a filled-in config for Cyberpunk 2077
tests/                       Pester tests and the mock game folder they build
tools/fetch_verified.py      download a GitHub release file and check it against the published SHA-256
tools/pe_resources.py        list and compare the resources inside DLL files (read-only)
docs/TROUBLESHOOTING.md      symptoms, causes, what to do
```

## Requirements

| Requirement | Version | Notes |
|---|---|---|
| Windows | 10 or 11 | `robocopy` and junctions are used by the move commands |
| PowerShell | Windows PowerShell 5.1 or PowerShell 7 | 5.1 is built into Windows |
| Pester (to run the tests) | 5.x | |
| Python (for `tools/` only) | 3.11 | standard library only |

## Install

1. Download or clone this repository to any folder.
2. Open PowerShell and load the module:
   ```powershell
   Import-Module .\ModToolkit\ModToolkit.psd1
   ```
3. If PowerShell refuses to load it: files from a downloaded ZIP are marked as coming from the internet. In the folder, run `Get-ChildItem -Recurse | Unblock-File`, then `Set-ExecutionPolicy -Scope Process RemoteSigned` (this applies to that window only).

## Quick start

Copy `config.sample.json`, name it after your game and fill it in:

```json
{
  "name": "Example Game",
  "gameDir": "%ProgramFiles(x86)%\\Steam\\steamapps\\common\\Example Game",
  "backupDir": "%USERPROFILE%\\Backups\\Example Game",
  "processNames": ["ExampleGame"],
  "versionFile": "bin\\ExampleGame.exe",
  "areas": { "scripts": "mods\\scripts", "plugins": "bin\\plugins" },
  "rootFiles": ["*.ini"],
  "logFile": "%LOCALAPPDATA%\\ModToolkit\\example-game.log"
}
```

`areas` are the folders inside the game folder that hold mods. `rootFiles` are file name patterns for files directly in the game folder. Only these are backed up and restored.

```powershell
Backup-GameMods -Config .\my-game.json -WhatIf     # shows the numbers, copies nothing
Backup-GameMods -Config .\my-game.json             # copies new or changed files, writes the manifest
Test-GameBackup -Config .\my-game.json             # is the backup intact?
Test-GameBackup -Config .\my-game.json -Live       # what changed in the game folder since the backup?
Restore-GameMods -Config .\my-game.json -WhatIf    # what a restore would change
Restore-GameMods -Config .\my-game.json            # put it back
```

Install one mod whose download is laid out like the game folder (for example the `package\` folder of my mod repositories):

```powershell
$game = "${env:ProgramFiles(x86)}\Steam\steamapps\common\Example Game"
Install-ModPackage -PackagePath .\some-mod\package -GameDir $game -Name some-mod -WhatIf
Install-ModPackage -PackagePath .\some-mod\package -GameDir $game -Name some-mod
Uninstall-ModPackage -GameDir $game -Name some-mod
```

Keep two versions of a group of files and switch between them:

```powershell
New-FileSet -KitDir .\kit -Name old -From .\files-old      # folders laid out like the game folder
New-FileSet -KitDir .\kit -Name new -From .\files-new
Switch-FileSet -KitDir .\kit -GameDir $game -To new
Get-FileSetStatus -KitDir .\kit -GameDir $game
Switch-FileSet -KitDir .\kit -GameDir $game -Undo
```

Every command has built-in help: `Get-Help Restore-GameMods -Full`.

## Uninstall / roll back

The module installs nothing on the PC. Delete the folder to remove it. What it leaves behind is listed here so it can be found:

| Created by | Where |
|---|---|
| `Backup-GameMods` | `<backupDir>\files\`, `manifest.sha256.txt`, `backup.json` |
| `Restore-GameMods` | `<backupDir>\replaced\<time>\` (the files it replaced) |
| `Install-ModPackage` | `<gameDir>\_modtoolkit\<name>\` (removed again by the uninstall) |
| `Switch-FileSet` | `<kit>\swapped_out\<time>_before_<set>\` |
| `Set-ModToolkitLog` or `logFile` | the log file you named |

## Status

| What | Result |
|---|---|
| Tests | 36 tests in `tests/ModToolkit.Tests.ps1`, all on a mock game folder in a temporary place. They cover every command, including the dry runs, the refusals (game running, damaged backup, updated game, unknown set) and the undo paths. |
| Real game folder, 2026-11-24 | `Backup-GameMods`, `Test-GameBackup` and `Test-GameBackup -Live` on two script areas of a modded Cyberpunk 2077 install: 7,819 files, 102.7 MB, backup in 50 s, all hashes matched, second run copied 0 files. `Restore-GameMods -WhatIf` reported 0 files to restore. |
| Not yet run on a real game folder | `Restore-GameMods` (without `-WhatIf`), `Install-ModPackage`, `Uninstall-ModPackage`, `Switch-FileSet`, `Move-FolderToDrive`. They are covered by the tests only. |

The module is a generalised rewrite of scripts I used per game (see Engineering notes). Those scripts were used on real installs; this rewrite is new, so treat it as version 0.1 and start with `-WhatIf`.

## Known limits

- A changed file is recognised by a different size or a modification time more than 2 seconds apart. An edit that keeps both is not copied by `Backup-GameMods` (but `Test-GameBackup -Live` finds it, because that compares hashes).
- Every backup run hashes all files in the backup again. That is slow for areas that hold files of several gigabytes.
- Paths longer than 260 characters are not handled specially.
- `Switch-FileSet` works on top-level entries of the game folder: if a set contains `addon\a.ini`, the whole `addon` folder is managed and moved out on a switch.
- Mod managers that keep their own list of deployed files (Vortex, Mod Organizer) are not informed. After a restore they may report "external changes".

## Engineering notes

**Where it comes from.** Scripts that I wrote and used per game: a backup/restore pair with a hash manifest, a restore that compares the game build before it copies, a "swap kit" that switches a group of files in the game folder between saved versions, and a script that moves a folder to another drive and leaves a junction. Each had my folders written into it and each solved the same problems slightly differently.

**What was kept from them, because it had proved itself:**

- The swap kit never deleted anything; it moved the current files to a dated folder and verified the new ones by hash. After a failed switch the previous files were still there to move back, so this became the rule for every command here.
- The restore script compared the game executable with the one recorded at backup time, because files backed up from one game build may not fit the next one.
- The move script renamed the folder before copying. A rename fails immediately when a file is open, which is a better moment to fail than after a long copy.
- Folder removal clears the read-only attribute first. Folders that passed through a cloud-synced location can carry it, and removal then fails with "Access to the path is denied".

**What changed in the rewrite.** Paths moved into a config file. Every changing command got `-WhatIf`. The restore now keeps the files it replaces (the old script overwrote them). `Switch-FileSet` got `-Undo`. Copying inside the backup and restore commands is done in PowerShell instead of `robocopy`, so the tests can check exact file counts.

**How it was checked.** The tests build a small game folder, run each command and compare file contents, not just exit codes. Each refusal is tested by provoking it: a set file is altered, the "executable" is replaced, the config names the test's own process as the game. Then one read-only run against a real install (numbers under Status).

**Rollback.** Described per command in the table at the top. The log file names the folder that holds the previous files for every change.

## Changelog

See [CHANGELOG.md](CHANGELOG.md). Latest: 0.1.0 (2026-11-24): first version.

## Credits and licence

Tests run with Pester. Nothing third-party is included.

MIT, see [LICENSE](LICENSE). Game names belong to their owners.

Built with AI assistance (Claude); designed, tested and maintained by me.
