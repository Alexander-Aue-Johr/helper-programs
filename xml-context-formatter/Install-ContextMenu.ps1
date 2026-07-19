[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$formatterScript = Join-Path $PSScriptRoot 'Format-XmlFiles.ps1'
$powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

if (-not (Test-Path -LiteralPath $formatterScript -PathType Leaf)) {
    throw "Formatter script not found: $formatterScript"
}

$targets = @(
    @{
        KeyPath      = 'HKCU:\Software\Classes\Directory\Background\shell\FormatXmlFiles'
        CommandValue = "`"$powershellExe`" -NoExit -NoProfile -ExecutionPolicy Bypass -File `"$formatterScript`" -TargetFolder `"%V`" -Recurse"
    },
    @{
        KeyPath      = 'HKCU:\Software\Classes\Directory\shell\FormatXmlFiles'
        CommandValue = "`"$powershellExe`" -NoExit -NoProfile -ExecutionPolicy Bypass -File `"$formatterScript`" -TargetFolder `"%1`" -Recurse"
    }
)

foreach ($target in $targets) {
    $commandKeyPath = Join-Path $target.KeyPath 'command'

    New-Item -Path $commandKeyPath -Force | Out-Null
    Set-Item -Path $target.KeyPath -Value 'Format XML files in this folder'
    New-ItemProperty -Path $target.KeyPath -Name 'Icon' -PropertyType String -Value "$powershellExe,0" -Force | Out-Null
    Set-Item -Path $commandKeyPath -Value $target.CommandValue
}

Write-Host 'Context menu installed for the current user.'
Write-Host 'Explorer will open PowerShell and print each XML file as it is formatted.'
