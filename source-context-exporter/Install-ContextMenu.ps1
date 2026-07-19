[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$exportScript = Join-Path $PSScriptRoot 'Export-SourceContext.ps1'
$powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$iconPath = Join-Path $PSScriptRoot 'SourceContext.ico'

if (-not (Test-Path -LiteralPath $exportScript -PathType Leaf)) {
    throw "Exporter script not found: $exportScript"
}

$iconValue = if (Test-Path -LiteralPath $iconPath -PathType Leaf) { $iconPath } else { "$powershellExe,0" }

$targets = @(
    @{
        KeyPath      = 'HKCU:\Software\Classes\Directory\Background\shell\ExportSourceContext'
        CommandValue = "`"$powershellExe`" -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$exportScript`" -TargetFolder `"%V`""
    },
    @{
        KeyPath      = 'HKCU:\Software\Classes\Directory\shell\ExportSourceContext'
        CommandValue = "`"$powershellExe`" -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$exportScript`" -TargetFolder `"%1`""
    }
)

foreach ($target in $targets) {
    $commandKeyPath = Join-Path $target.KeyPath 'command'

    New-Item -Path $commandKeyPath -Force | Out-Null
    Set-Item -Path $target.KeyPath -Value 'Export source context...'
    New-ItemProperty -Path $target.KeyPath -Name 'Icon' -PropertyType String -Value $iconValue -Force | Out-Null
    Set-Item -Path $commandKeyPath -Value $target.CommandValue
}

Write-Host 'Context menu installed for the current user.'
Write-Host 'Right-click a folder or the background inside a folder and choose: Export source context...'
Write-Host 'On Windows 11 this entry may appear under "Show more options".'
