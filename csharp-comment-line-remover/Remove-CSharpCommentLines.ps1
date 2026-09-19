[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$TargetFolder = (Get-Location).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Only remove complete lines whose first non-whitespace characters are //.
# Inline // sequences are deliberately left untouched, for example URLs and code comments.
$commentLinePattern = '(?m)^[^\S\r\n]*//[^\r\n]*(?:\r\n|\n|\r|$)'

function Read-TextFilePreservingEncoding {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $strictUtf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList $false, $true
    $reader = $null

    try {
        $reader = New-Object System.IO.StreamReader -ArgumentList $Path, $strictUtf8NoBom, $true
        $text = $reader.ReadToEnd()
        $encoding = $reader.CurrentEncoding

        return [pscustomobject]@{
            Text     = $text
            Encoding = $encoding
        }
    }
    catch [System.Text.DecoderFallbackException] {
        # Fall back to the active Windows ANSI code page for legacy C# files
        # that are neither BOM-marked Unicode nor valid UTF-8.
        if ($reader -ne $null) {
            $reader.Dispose()
            $reader = $null
        }

        $reader = New-Object System.IO.StreamReader -ArgumentList $Path, ([System.Text.Encoding]::Default), $true
        $text = $reader.ReadToEnd()
        $encoding = $reader.CurrentEncoding

        return [pscustomobject]@{
            Text     = $text
            Encoding = $encoding
        }
    }
    finally {
        if ($reader -ne $null) {
            $reader.Dispose()
        }
    }
}

function Remove-CSharpCommentLinesFromFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $fileData = Read-TextFilePreservingEncoding -Path $Path
    $matches = [System.Text.RegularExpressions.Regex]::Matches(
        $fileData.Text,
        $commentLinePattern
    )

    if ($matches.Count -eq 0) {
        return [pscustomobject]@{
            Path         = $Path
            Status       = 'Unchanged'
            RemovedLines = 0
            Message      = $null
        }
    }

    $newText = [System.Text.RegularExpressions.Regex]::Replace(
        $fileData.Text,
        $commentLinePattern,
        ''
    )

    if ($PSCmdlet.ShouldProcess($Path, ("Remove {0} standalone C# comment line(s)" -f $matches.Count))) {
        [System.IO.File]::WriteAllText($Path, $newText, $fileData.Encoding)
        $status = 'Updated'
    }
    else {
        $status = 'WouldUpdate'
    }

    return [pscustomobject]@{
        Path         = $Path
        Status       = $status
        RemovedLines = $matches.Count
        Message      = $null
    }
}

if (-not (Test-Path -LiteralPath $TargetFolder -PathType Container)) {
    throw "Folder not found:`r`n$TargetFolder"
}

Write-Host ("Target folder: {0}" -f $TargetFolder)
Write-Host 'Rule: remove only lines matching ^whitespace*//. Inline // remains untouched.'

$files = @(
    Get-ChildItem -LiteralPath $TargetFolder -Filter '*.cs' -File -Recurse -ErrorAction Stop
)

if ($files.Count -eq 0) {
    Write-Host 'No C# files found.'
    exit 0
}

$results = foreach ($file in $files) {
    try {
        $result = Remove-CSharpCommentLinesFromFile -Path $file.FullName
        if ($result.Status -eq 'Updated') {
            Write-Host ("Updated: {0} ({1} comment line(s) removed)" -f $file.FullName, $result.RemovedLines)
        }
        elseif ($result.Status -eq 'WouldUpdate') {
            Write-Host ("Would update: {0} ({1} comment line(s))" -f $file.FullName, $result.RemovedLines)
        }
        $result
    }
    catch {
        Write-Warning ("{0}: {1}" -f $file.FullName, $_.Exception.Message)
        [pscustomobject]@{
            Path         = $file.FullName
            Status       = 'Failed'
            RemovedLines = 0
            Message      = $_.Exception.Message
        }
    }
}

$updated = @($results | Where-Object Status -eq 'Updated')
$wouldUpdate = @($results | Where-Object Status -eq 'WouldUpdate')
$failed = @($results | Where-Object Status -eq 'Failed')
$removedLineCount = ($results | Measure-Object -Property RemovedLines -Sum).Sum
if ($null -eq $removedLineCount) {
    $removedLineCount = 0
}

Write-Host ''
Write-Host ("C# files scanned: {0}" -f $files.Count)
if ($WhatIfPreference) {
    Write-Host ("Files that would change: {0}" -f $wouldUpdate.Count)
    Write-Host ("Comment lines that would be removed: {0}" -f $removedLineCount)
}
else {
    Write-Host ("Files changed: {0}" -f $updated.Count)
    Write-Host ("Comment lines removed: {0}" -f $removedLineCount)
}
Write-Host ("Failed: {0}" -f $failed.Count)

if ($failed.Count -gt 0) {
    exit 1
}
