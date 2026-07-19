[CmdletBinding()]
param(
    [string]$TargetFolder = (Get-Location).Path,

    [switch]$Recurse,

    # Retained for compatibility with older context-menu registrations.
    [switch]$ShowSummary
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Format-XmlFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    Write-Host ("Formatting: {0}" -f $Path)

    try {
        $xmlDocument = New-Object System.Xml.XmlDocument
        $xmlDocument.PreserveWhitespace = $false
        $xmlDocument.Load($Path)
        $xmlDocument.Save($Path)

        [pscustomobject]@{
            Path    = $Path
            Status  = 'Formatted'
            Message = $null
        }
    }
    catch {
        [pscustomobject]@{
            Path    = $Path
            Status  = 'Failed'
            Message = $_.Exception.Message
        }
    }
}

if (-not (Test-Path -LiteralPath $TargetFolder -PathType Container)) {
    throw "Folder not found:`r`n$TargetFolder"
}

Write-Host ("Target folder: {0}" -f $TargetFolder)
Write-Host ("Recursive search: {0}" -f $Recurse.IsPresent)

$files = if ($Recurse) {
    Get-ChildItem -LiteralPath $TargetFolder -Filter '*.xml' -File -Recurse
}
else {
    Get-ChildItem -LiteralPath $TargetFolder -Filter '*.xml' -File
}

if (-not $files) {
    Write-Host "No XML files found in:`r`n$TargetFolder"
    exit 0
}

$results = foreach ($file in $files) {
    Format-XmlFile -Path $file.FullName
}

$formatted = @($results | Where-Object Status -eq 'Formatted')
$failed = @($results | Where-Object Status -eq 'Failed')

Write-Host ("Formatted XML files: {0}" -f $formatted.Count)
Write-Host ("Failed: {0}" -f $failed.Count)

foreach ($failure in $failed) {
    Write-Warning ("{0}: {1}" -f $failure.Path, $failure.Message)
}

if ($failed.Count -gt 0) {
    exit 1
}
