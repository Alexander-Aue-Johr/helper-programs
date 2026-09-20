[CmdletBinding()]
param([string]$InitialFolder = (Get-Location).Path)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
$scriptPath = Join-Path $PSScriptRoot 'IdenticalFileCleaner.py'
if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) { throw "Python helper not found: $scriptPath" }
$py = Get-Command 'py.exe' -ErrorAction SilentlyContinue
if ($py) { & $py.Source -3 $scriptPath --initial-folder $InitialFolder; exit $LASTEXITCODE }
$python = Get-Command 'python.exe' -ErrorAction SilentlyContinue
if ($python) { & $python.Source $scriptPath --initial-folder $InitialFolder; exit $LASTEXITCODE }
[System.Windows.Forms.MessageBox]::Show('Python 3 was not found on PATH.','Identical File Cleaner',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
exit 1
