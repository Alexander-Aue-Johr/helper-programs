[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$installScripts = @(
    Get-ChildItem -LiteralPath $PSScriptRoot -Directory |
        ForEach-Object {
            $candidate = Join-Path $_.FullName 'Install-ContextMenu.ps1'
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                Get-Item -LiteralPath $candidate
            }
        } |
        Sort-Object -Property DirectoryName
)

if ($installScripts.Count -eq 0) {
    throw "No helper install scripts found below: $PSScriptRoot"
}

foreach ($installScript in $installScripts) {
    Write-Host ("Installing context menu: {0}" -f $installScript.Directory.Name)
    & $installScript.FullName
}

Write-Host 'All context-menu helpers installed for the current user.'