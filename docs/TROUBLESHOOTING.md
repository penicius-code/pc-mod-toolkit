# Troubleshooting

Symptoms are listed as the module reports them. No step here involves switching off security software.

| Symptom | Cause | What to do |
|---|---|---|
| `<name> is running. Close it first. Nothing was changed.` | A process from `processNames` (or `-ProcessName`) is running. Files in use cannot be replaced reliably. | Close the game, then run the command again. |
| `... is not the file the backup was made with (game updated?)` | The file named in `versionFile` has a different SHA-256 than at backup time. Usually the store client updated the game. | Check whether your mods support the new game version. `Restore-GameMods -WhatIf -Force` shows what a restore would change. Restore with `-Force` only if the mods fit the new version; otherwise update the mods and take a new backup. |
| `The backup does not match its manifest (n missing, m changed)` | Files in the backup folder were changed, deleted or damaged after the backup was written. | `Test-GameBackup` lists them under `Missing` and `Changed`. If the game folder is still good, run `Backup-GameMods` again to refresh the backup. If nobody touched the files, check the backup drive. |
| `A file of set '<set>' does not match its SHA256SUMS.txt` | A file inside the kit's `sets\<set>` folder was changed after the set was saved. | Nothing was changed in the game. Save the set again from the original files with `New-FileSet`, under a new name. |
| `Copied files differ from the set` or `Restored files differ from the manifest` | A file changed between copy and check: another program wrote to it, or the drive returned bad data. | The message names the folder that holds the previous files. Close programs that work in the game folder (mod manager, cloud sync, the game) and repeat. If it happens again, check the drive. |
| `'<name>' is already installed here` | An install record for that name exists in `<gameDir>\_modtoolkit\`. | Run `Uninstall-ModPackage` first, then install the new version. `Get-InstalledModPackage` shows what is recorded. |
| After `Uninstall-ModPackage`, some files of the mod are still there | They were changed after the install (settings you edited), so their hash no longer matches the record. They are listed under `KeptModified`. | Keep them if you want your settings for the next install. To remove them too, uninstall with `-Force`; they are moved to `_modtoolkit\_removed\`. |
| `Access to the path is denied` when a folder is removed | The folder is marked read-only. Folders that were copied through a cloud-synced location can carry that attribute. | The module clears the attribute on folders it removes itself. For other folders: `attrib -r "<folder>" /s /d`. |
| `Move-FolderToDrive` fails at once with a rename error | A program has a file in that folder open. The rename is the first step, so this shows before anything is copied. | Close the program (also a terminal or Explorer window standing in that folder) and run it again. The folder is unchanged. |
| A program refuses a path that goes through a junction | Some tools require a real directory. Seen with the Windows Performance Recorder, which rejected a capture folder reached through a junction ("Invalid temporary trace directory"). | Give that program the real path on the other drive, or move the folder back with `Restore-MovedFolder`. |
| The mod manager reports "external changes" after a restore | Mod managers keep their own list of deployed files and notice that files changed outside of them. | Decide in the manager's dialog which version to keep. To keep the restored state, keep the files that are on disk. |
| `Backup-GameMods` copies nothing although a file was edited | The edit kept the file size, and the modification time is within 2 seconds of the backed-up copy. | `Test-GameBackup -Live` compares hashes and lists the file under `Changed`. Delete that file from `<backupDir>\files\` and back up again. |
| The module does not load: "running scripts is disabled on this system" | PowerShell's execution policy, or the files still carry the "downloaded from the internet" mark. | In the module folder run `Get-ChildItem -Recurse` piped to `Unblock-File`, then `Set-ExecutionPolicy -Scope Process RemoteSigned` in that window. |

## Where to look

- The log file (`logFile` in the config, or `Set-ModToolkitLog -Path`) has one line per change and names the folder that holds the previous files.
- `<backupDir>\replaced\<time>\` holds what a restore replaced.
- `<kit>\swapped_out\<time>_before_<set>\` holds what a switch moved out.
- `<gameDir>\_modtoolkit\<name>\install.json` lists every file an install copied, with its hash.
