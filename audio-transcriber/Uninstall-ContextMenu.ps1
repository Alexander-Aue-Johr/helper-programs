[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$keys = @(
    'HKCU:\Software\Classes\SystemFileAssociations\.m4a\shell\LocalAudioTranscriber',
    'HKCU:\Software\Classes\SystemFileAssociations\.zip\shell\LocalAudioTranscriber'
)

foreach ($key in $keys) {
    if (Test-Path -LiteralPath $key) {
        Remove-Item -LiteralPath $key -Recurse -Force
    }
}

Write-Host 'Audio transcriber context menu removed for the current user.'
