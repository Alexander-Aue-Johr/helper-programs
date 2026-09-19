[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$removerScript = Join-Path $PSScriptRoot 'Remove-CSharpCommentLines.ps1'
$powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

if (-not (Test-Path -LiteralPath $removerScript -PathType Leaf)) {
    throw "Comment remover script not found: $removerScript"
}

$targets = @(
    @{
        KeyPath      = 'HKCU:\Software\Classes\Directory\Background\shell\RemoveCSharpCommentLines'
        CommandValue = "`"$powershellExe`" -NoExit -NoProfile -ExecutionPolicy Bypass -File `"$removerScript`" -TargetFolder `"%V`""
    },
    @{
        KeyPath      = 'HKCU:\Software\Classes\Directory\shell\RemoveCSharpCommentLines'
        CommandValue = "`"$powershellExe`" -NoExit -NoProfile -ExecutionPolicy Bypass -File `"$removerScript`" -TargetFolder `"%1`""
    }
)

foreach ($target in $targets) {
    $commandKeyPath = Join-Path $target.KeyPath 'command'

    New-Item -Path $commandKeyPath -Force | Out-Null
    Set-Item -Path $target.KeyPath -Value 'Remove standalone C# comment lines'
    New-ItemProperty -Path $target.KeyPath -Name 'Icon' -PropertyType String -Value "$powershellExe,0" -Force | Out-Null
    Set-Item -Path $commandKeyPath -Value $target.CommandValue
}

Write-Host 'Context menu installed for the current user.'
Write-Host 'Right-click a folder or the background inside a folder and choose: Remove standalone C# comment lines'
Write-Host 'On Windows 11 this entry may appear under "Show more options".'
