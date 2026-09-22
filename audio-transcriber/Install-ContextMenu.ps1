[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$launcher = Join-Path $PSScriptRoot 'Run-AudioTranscriber.ps1'
$powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) {
    throw "Audio transcriber launcher not found: $launcher"
}

$targets = @(
    @{
        KeyPath = 'HKCU:\Software\Classes\SystemFileAssociations\.m4a\shell\LocalAudioTranscriber'
        Label   = 'Transcribe locally with Whisper...'
    },
    @{
        KeyPath = 'HKCU:\Software\Classes\SystemFileAssociations\.zip\shell\LocalAudioTranscriber'
        Label   = 'Transcribe audio from ZIP locally...'
    }
)

foreach ($target in $targets) {
    $commandKey = Join-Path $target.KeyPath 'command'
    New-Item -Path $commandKey -Force | Out-Null
    Set-Item -Path $target.KeyPath -Value $target.Label
    New-ItemProperty -Path $target.KeyPath -Name 'Icon' -PropertyType String -Value "$powershellExe,0" -Force | Out-Null

    $command = (
        "`"$powershellExe`" -NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -STA " +
        "-File `"$launcher`" -InputPath `"%1`""
    )
    Set-Item -Path $commandKey -Value $command
}

Write-Host 'Audio transcriber context menu installed for the current user.'
Write-Host 'Right-click an .m4a file or a ZIP containing M4A audio.'
Write-Host 'First use creates .venv and installs dependencies. The dialog waits for Start conversion; the Whisper model is prepared only when needed.'
Write-Host 'On Windows 11 this entry may appear under "Show more options".'
