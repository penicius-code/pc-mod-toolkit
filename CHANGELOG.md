# Changelog

## 0.1.0 - 2026-11-24
First version. A generalised rewrite of the per-game backup, restore, switch and move scripts.

### Added
- `Backup-GameMods`, `Test-GameBackup`, `Restore-GameMods`: backup of configured mod areas with a SHA-256 manifest, verification of the backup or of the live game folder, restore that keeps every replaced file and stops if the game was updated since the backup.
- `Install-ModPackage`, `Uninstall-ModPackage`, `Get-InstalledModPackage`: install one mod package with a record, remove exactly those files again, put replaced files back.
- `New-FileSet`, `Switch-FileSet`, `Get-FileSetStatus`: saved sets of files with checksums, switch between them, undo the last switch.
- `Move-FolderToDrive`, `Restore-MovedFolder`: move a folder to another drive with a junction at the old path, and back.
- `Set-ModToolkitLog` and the `logFile` config entry.
- `-WhatIf` on every command that changes files.
- 36 Pester tests on a mock game folder; CI on Windows PowerShell 5.1 and PowerShell 7.
- `tools/fetch_verified.py`, `tools/pe_resources.py`.
