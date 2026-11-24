@{
    RootModule        = 'ModToolkit.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'a04398a5-639a-4e02-9773-092a6578d748'
    Author            = 'penicius-code'
    Copyright         = '(c) 2026 penicius-code. MIT licence.'
    Description       = 'Install, back up, verify, switch and roll back files of a modded PC game. Every change supports -WhatIf and is checked with SHA-256.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Set-ModToolkitLog', 'Get-ModToolkitConfig',
        'Backup-GameMods', 'Test-GameBackup', 'Restore-GameMods',
        'Install-ModPackage', 'Uninstall-ModPackage', 'Get-InstalledModPackage',
        'New-FileSet', 'Get-FileSetStatus', 'Switch-FileSet',
        'Move-FolderToDrive', 'Restore-MovedFolder'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
