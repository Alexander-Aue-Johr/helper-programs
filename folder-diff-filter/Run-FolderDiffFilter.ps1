[CmdletBinding()]
param(
    [string]$InitialFolder = (Get-Location).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms

$scriptPath = Join-Path $PSScriptRoot 'Filter-FolderDiff.py'

function Show-LauncherError {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    [System.Windows.Forms.MessageBox]::Show(
        $Message,
        'Folder Diff Filter - Error',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
}

if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    Show-LauncherError -Message ("Python helper not found:`r`n{0}" -f $scriptPath)
    exit 1
}

$pythonCommand = $null
$pythonPrefixArgs = @()

$py = Get-Command 'py.exe' -ErrorAction SilentlyContinue
if ($py -ne $null) {
    $pythonCommand = $py.Source
    $pythonPrefixArgs = @('-3')
}
else {
    $python = Get-Command 'python.exe' -ErrorAction SilentlyContinue
    if ($python -ne $null) {
        $pythonCommand = $python.Source
    }
}

if ($null -eq $pythonCommand) {
    Show-LauncherError -Message 'Python 3 was not found on PATH.'
    exit 1
}

try {
    $captured = @(
        & $pythonCommand @pythonPrefixArgs $scriptPath --initial-folder $InitialFolder 2>&1 |
            ForEach-Object { $_.ToString() }
    )
    $exitCode = $LASTEXITCODE
}
catch {
    Show-LauncherError -Message $_.Exception.ToString()
    exit 1
}

if ($exitCode -ne 0) {
    $details = ($captured -join "`r`n").Trim()

    if ([string]::IsNullOrWhiteSpace($details)) {
        $details = "Python exited with code $exitCode but produced no error text."
    }

    Show-LauncherError -Message (
        "The Folder Diff Filter could not start or terminated with an error.`r`n`r`n" +
        $details
    )
    exit $exitCode
}

exit 0
