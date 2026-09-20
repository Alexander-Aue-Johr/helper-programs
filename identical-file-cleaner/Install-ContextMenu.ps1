[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$launcher = Join-Path $PSScriptRoot 'Run-IdenticalFileCleaner.ps1'
$powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$targets = @(
 @{KeyPath='HKCU:\Software\Classes\Directory\Background\shell\IdenticalFileCleaner'; CommandValue="`"$powershellExe`" -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$launcher`" -InitialFolder `"%V`""},
 @{KeyPath='HKCU:\Software\Classes\Directory\shell\IdenticalFileCleaner'; CommandValue="`"$powershellExe`" -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$launcher`" -InitialFolder `"%1`""}
)
foreach ($target in $targets) {
 $commandKey = Join-Path $target.KeyPath 'command'
 New-Item -Path $commandKey -Force | Out-Null
 Set-Item -Path $target.KeyPath -Value 'Find and remove identical files in two folders...'
 New-ItemProperty -Path $target.KeyPath -Name 'Icon' -PropertyType String -Value "$powershellExe,0" -Force | Out-Null
 Set-Item -Path $commandKey -Value $target.CommandValue
}
Write-Host 'Context menu installed for the current user.'
