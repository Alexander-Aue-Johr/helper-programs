[CmdletBinding()]
param([string]$InitialFolder = (Get-Location).Path,[string]$TargetFolder = '')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not [string]::IsNullOrWhiteSpace($TargetFolder)) { $InitialFolder = $TargetFolder }
& (Join-Path $PSScriptRoot 'Run-IdenticalFileCleaner.ps1') -InitialFolder $InitialFolder
exit $LASTEXITCODE
