[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms

$runner = Join-Path $PSScriptRoot 'run.py'
$venvPython = Join-Path $PSScriptRoot '.venv\Scripts\python.exe'
$venvPythonw = Join-Path $PSScriptRoot '.venv\Scripts\pythonw.exe'
$runtime = Join-Path $PSScriptRoot '.runtime'
$logPath = Join-Path $runtime 'context-bootstrap.log'

function Show-LauncherError {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    [System.Windows.Forms.MessageBox]::Show(
        $Message,
        'Audio Transcriber - Error',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
}

function Get-LastLogLines {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [int]$Count = 24
    )

    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            return ((Get-Content -LiteralPath $Path -Tail $Count -ErrorAction Stop) -join "`r`n")
        }
    }
    catch {
    }
    return ''
}

try {
    if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) {
        throw "Audio transcriber bootstrap not found: $runner"
    }

    if (-not (Test-Path -LiteralPath $InputPath -PathType Leaf)) {
        throw "Input file not found: $InputPath"
    }

    $resolvedInput = (Resolve-Path -LiteralPath $InputPath).Path
    $extension = [System.IO.Path]::GetExtension($resolvedInput).ToLowerInvariant()
    if ($extension -notin @('.m4a', '.zip')) {
        throw "Only .m4a files and .zip archives are supported: $resolvedInput"
    }

    New-Item -ItemType Directory -Path $runtime -Force | Out-Null
    @(
        ('[{0:yyyy-MM-dd HH:mm:ss}] Explorer launch' -f (Get-Date)),
        ('Input: {0}' -f $resolvedInput),
        ('Helper: {0}' -f $PSScriptRoot)
    ) | Set-Content -LiteralPath $logPath -Encoding UTF8

    $pythonCommand = $null
    $pythonPrefixArgs = @()

    # Prefer a system Python so a broken .venv can be rebuilt.
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
        elseif (Test-Path -LiteralPath $venvPython -PathType Leaf) {
            $pythonCommand = $venvPython
        }
    }

    if ($null -eq $pythonCommand) {
        throw (
            "Python 3 was not found. Install Python 3 (including the 'venv' module), " +
            "then use this context-menu entry again."
        )
    }

    Write-Host ''
    Write-Host 'Audio Transcriber'
    Write-Host 'Preparing the local Python environment. On the first start this can install packages.'
    Write-Host 'The Whisper model is prepared only after Start conversion is pressed.'
    Write-Host ''
    Write-Host ("Input: {0}" -f $resolvedInput)
    Write-Host ("Bootstrap log: {0}" -f $logPath)
    Write-Host ''

    $oldUtf8 = $env:PYTHONUTF8
    $oldIoEncoding = $env:PYTHONIOENCODING
    $env:PYTHONUTF8 = '1'
    $env:PYTHONIOENCODING = 'utf-8'
    try {
        & $pythonCommand @pythonPrefixArgs $runner bootstrap 2>&1 |
            ForEach-Object {
                $line = $_.ToString()
                Write-Host $line
                Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
            }
        $bootstrapExitCode = $LASTEXITCODE
    }
    finally {
        $env:PYTHONUTF8 = $oldUtf8
        $env:PYTHONIOENCODING = $oldIoEncoding
    }

    if ($bootstrapExitCode -ne 0) {
        $tail = Get-LastLogLines -Path $logPath
        throw (
            "Automatic environment bootstrap failed with exit code $bootstrapExitCode.`r`n`r`n" +
            $tail + "`r`n`r`nFull log:`r`n" + $logPath
        )
    }

    if (-not (Test-Path -LiteralPath $venvPython -PathType Leaf)) {
        throw "Environment bootstrap reported success, but .venv Python is missing: $venvPython"
    }

    $guiPython = $(if (Test-Path -LiteralPath $venvPythonw -PathType Leaf) {
        $venvPythonw
    }
    else {
        $venvPython
    })

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $guiPython
    $startInfo.Arguments = ('"{0}" gui' -f $runner)
    $startInfo.WorkingDirectory = $PSScriptRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.EnvironmentVariables['AUDIO_TRANSCRIBER_INPUT'] = $resolvedInput
    $startInfo.EnvironmentVariables['AUDIO_TRANSCRIBER_CONTEXT_LAUNCH'] = '1'
    $startInfo.EnvironmentVariables['PYTHONUTF8'] = '1'
    $startInfo.EnvironmentVariables['PYTHONIOENCODING'] = 'utf-8'

    $process = [System.Diagnostics.Process]::Start($startInfo)
    if ($null -eq $process) {
        throw 'The prepared transcription GUI process could not be started.'
    }

    Add-Content -LiteralPath $logPath -Value (
        '[{0:yyyy-MM-dd HH:mm:ss}] Environment ready; GUI PID {1} opened and is waiting for user input.' -f
        (Get-Date),
        $process.Id
    ) -Encoding UTF8

    Write-Host ''
    Write-Host 'Environment ready. Opening transcription dialog...'
    exit 0
}
catch {
    $message = $_.Exception.Message
    try {
        New-Item -ItemType Directory -Path $runtime -Force | Out-Null
        Add-Content -LiteralPath $logPath -Value (
            '[{0:yyyy-MM-dd HH:mm:ss}] ERROR: {1}' -f (Get-Date), $message
        ) -Encoding UTF8
    }
    catch {
    }

    Show-LauncherError -Message (
        $message + "`r`n`r`n" +
        "Bootstrap log:`r`n" + $logPath
    )
    exit 1
}
