[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$keys = @(
    'HKCU:\Software\Classes\Directory\Background\shell\RemoveCSharpCommentLines',
    'HKCU:\Software\Classes\Directory\shell\RemoveCSharpCommentLines'
)

foreach ($key in $keys) {
    if (Test-Path -LiteralPath $key) {
        Remove-Item -LiteralPath $key -Recurse -Force
    }
}

Write-Host 'Context menu removed for the current user.'
