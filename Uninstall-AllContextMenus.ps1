[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$uninstallScripts = @(
    Get-ChildItem -LiteralPath $PSScriptRoot -Directory |
        ForEach-Object {
            $candidate = Join-Path $_.FullName 'Uninstall-ContextMenu.ps1'
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                Get-Item -LiteralPath $candidate
            }
        } |
        Sort-Object -Property DirectoryName
)

if ($uninstallScripts.Count -eq 0) {
    throw "No helper uninstall scripts found below: $PSScriptRoot"
}

foreach ($uninstallScript in $uninstallScripts) {
    Write-Host ("Removing context menu: {0}" -f $uninstallScript.Directory.Name)
    & $uninstallScript.FullName
}

Write-Host 'All context-menu helpers removed for the current user.'