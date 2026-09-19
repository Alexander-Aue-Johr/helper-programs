[CmdletBinding()]
param(
    [string]$TargetFolder = (Get-Location).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

trap {
    $errorText = $_.Exception.Message
    try {
        $loadingWindowVariable = Get-Variable -Scope Script -Name LoadingWindow -ErrorAction SilentlyContinue
        if ($loadingWindowVariable -ne $null -and $loadingWindowVariable.Value -ne $null) {
            $loadingWindowVariable.Value.Close()
        }
    }
    catch {
        # Ignore cleanup errors while reporting the original failure.
    }
    try {
        Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
        [System.Windows.MessageBox]::Show($errorText, 'Source Context Exporter - Error', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
    }
    catch {
        Write-Error $errorText
    }
    exit 1
}

if (-not (Test-Path -LiteralPath $TargetFolder -PathType Container)) {
    throw "Folder not found:`r`n$TargetFolder"
}

$resolvedTargetFolder = Resolve-Path -LiteralPath $TargetFolder
$providerPathProperty = $resolvedTargetFolder.PSObject.Properties['ProviderPath']
if (
    $providerPathProperty -ne $null -and
    -not [string]::IsNullOrWhiteSpace([string]$providerPathProperty.Value)
) {
    $TargetFolder = [string]$providerPathProperty.Value
}
else {
    $TargetFolder = [string]$resolvedTargetFolder.Path
}

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
    $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $argumentList = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-STA',
        '-File', ('"' + $PSCommandPath + '"'),
        '-TargetFolder', ('"' + $TargetFolder + '"')
    )
    Start-Process -FilePath $powershellExe -ArgumentList $argumentList | Out-Null
    exit 0
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml

$jsonStreamingHelperPath = Join-Path $PSScriptRoot 'JsonStreamingHelper.cs'
if (-not (Test-Path -LiteralPath $jsonStreamingHelperPath -PathType Leaf)) {
    throw "JSON streaming helper not found: $jsonStreamingHelperPath"
}
Add-Type -Path $jsonStreamingHelperPath

$script:NoExtensionKey = '<no-extension>'
$script:AllFileNodes = New-Object System.Collections.ArrayList
$script:AllDirectoryNodes = New-Object System.Collections.ArrayList
$script:ExtensionToFiles = @{}
$script:ExtensionToDirectories = @{}
$script:ExtensionEnabled = @{}
$script:ShowFiles = $false
$script:SuppressEvents = $false
$script:ProjectTree = $null
$script:TextExtensionsPanel = $null
$script:NonTextExtensionsPanel = $null
$script:StatusText = $null
$script:OkButton = $null
$script:ExportButton = $null
$script:ToggleFilesButton = $null
$script:RootNode = $null
$script:MutedBrush = $null
$script:TextBrush = $null
$script:ErrorBrush = $null
$script:Fence = -join (1..8 | ForEach-Object { [char]96 })
$script:LoadingWindow = $null
$script:LoadingStatusText = $null
$script:LoadingDetailText = $null
$script:ScannedItemCount = 0
$script:LastLoadingUpdate = [DateTime]::MinValue
$script:IgnoredFolderNames = $null
$script:IgnoredDirectoryCount = 0
$script:GlobalJsonRules = New-Object System.Collections.ArrayList
$script:GlobalJsonRemoveEmptyArrays = $false
$script:JsonPageSize = 200
$script:ProjectSelectionModelVersion = 6

$script:LanguageByExtension = @{
    '.ps1' = 'powershell'; '.psm1' = 'powershell'; '.psd1' = 'powershell'
    '.py' = 'python'; '.pyw' = 'python'; '.ipynb' = 'json'
    '.rs' = 'rust'; '.toml' = 'toml'
    '.js' = 'javascript'; '.jsx' = 'jsx'; '.mjs' = 'javascript'; '.cjs' = 'javascript'
    '.ts' = 'typescript'; '.tsx' = 'tsx'
    '.json' = 'json'; '.jsonc' = 'jsonc'
    '.md' = 'markdown'; '.markdown' = 'markdown'
    '.yml' = 'yaml'; '.yaml' = 'yaml'
    '.html' = 'html'; '.htm' = 'html'; '.css' = 'css'; '.scss' = 'scss'; '.sass' = 'sass'; '.less' = 'less'
    '.xml' = 'xml'; '.xaml' = 'xml'; '.svg' = 'xml'
    '.csproj' = 'xml'; '.fsproj' = 'xml'; '.vbproj' = 'xml'; '.props' = 'xml'; '.targets' = 'xml'; '.config' = 'xml'; '.resx' = 'xml'; '.nuspec' = 'xml'; '.plist' = 'xml'
    '.cs' = 'csharp'; '.fs' = 'fsharp'; '.vb' = 'vbnet'
    '.java' = 'java'; '.kt' = 'kotlin'; '.kts' = 'kotlin'; '.scala' = 'scala'
    '.c' = 'c'; '.h' = 'c'; '.cpp' = 'cpp'; '.cc' = 'cpp'; '.cxx' = 'cpp'; '.hpp' = 'cpp'; '.hh' = 'cpp'
    '.go' = 'go'; '.php' = 'php'; '.rb' = 'ruby'; '.swift' = 'swift'; '.dart' = 'dart'
    '.sh' = 'bash'; '.bash' = 'bash'; '.zsh' = 'zsh'; '.fish' = 'fish'; '.bat' = 'batch'; '.cmd' = 'batch'
    '.sql' = 'sql'; '.r' = 'r'; '.jl' = 'julia'; '.lua' = 'lua'; '.pl' = 'perl'
    '.ini' = 'ini'; '.cfg' = 'ini'; '.conf' = 'conf'; '.properties' = 'properties'; '.gradle' = 'gradle'
    '.vue' = 'vue'; '.svelte' = 'svelte'; '.astro' = 'astro'; '.graphql' = 'graphql'; '.gql' = 'graphql'
    '.sln' = 'text'; '.slnx' = 'xml'; '.cmake' = 'cmake'; '.proto' = 'protobuf'; '.pem' = 'text'
    '.tex' = 'latex'; '.bib' = 'bibtex'; '.rst' = 'rst'; '.adoc' = 'asciidoc'; '.lock' = 'text'
    '.txt' = 'text'; '.csv' = 'csv'; '.tsv' = 'tsv'; '.log' = 'text'
}

$script:NonTextExtensions = @{
    # Images and graphics
    '.png' = $true; '.jpg' = $true; '.jpeg' = $true; '.gif' = $true; '.webp' = $true; '.bmp' = $true; '.tif' = $true; '.tiff' = $true; '.ico' = $true
    '.heic' = $true; '.heif' = $true; '.avif' = $true; '.raw' = $true; '.dng' = $true; '.cr2' = $true; '.cr3' = $true; '.nef' = $true; '.arw' = $true

    # Audio
    '.mp3' = $true; '.m4a' = $true; '.m4b' = $true; '.aac' = $true; '.wav' = $true; '.flac' = $true; '.ogg' = $true; '.oga' = $true
    '.opus' = $true; '.wma' = $true; '.aif' = $true; '.aiff' = $true; '.mid' = $true; '.midi' = $true

    # Video
    '.mp4' = $true; '.m4v' = $true; '.mov' = $true; '.avi' = $true; '.mkv' = $true; '.webm' = $true; '.wmv' = $true; '.flv' = $true
    '.mpeg' = $true; '.mpg' = $true; '.3gp' = $true; '.3g2' = $true

    # Archives, packages and disk/container images
    '.zip' = $true; '.7z' = $true; '.rar' = $true; '.tar' = $true; '.gz' = $true; '.bz2' = $true; '.xz' = $true; '.zst' = $true
    '.cab' = $true; '.iso' = $true; '.dmg' = $true; '.vhd' = $true; '.vhdx' = $true; '.nupkg' = $true; '.snupkg' = $true
    '.apk' = $true; '.aab' = $true; '.ipa' = $true

    # Executables, libraries and compiled/object formats
    '.exe' = $true; '.dll' = $true; '.pdb' = $true; '.so' = $true; '.dylib' = $true; '.lib' = $true; '.a' = $true; '.o' = $true; '.obj' = $true
    '.class' = $true; '.jar' = $true; '.war' = $true; '.ear' = $true; '.wasm' = $true; '.pyc' = $true; '.pyo' = $true
    '.msi' = $true; '.msp' = $true; '.msix' = $true; '.appx' = $true; '.appxbundle' = $true

    # Fonts
    '.woff' = $true; '.woff2' = $true; '.ttf' = $true; '.otf' = $true; '.eot' = $true

    # Databases and opaque binary data
    '.db' = $true; '.sqlite' = $true; '.sqlite3' = $true; '.mdb' = $true; '.accdb' = $true; '.bin' = $true; '.dat' = $true
    '.pak' = $true; '.cache' = $true; '.parquet' = $true; '.feather' = $true; '.avro' = $true; '.orc' = $true
    '.npy' = $true; '.npz' = $true; '.pkl' = $true; '.pickle' = $true; '.h5' = $true; '.hdf5' = $true; '.mat' = $true; '.rdata' = $true; '.rds' = $true
    '.pcap' = $true; '.pcapng' = $true; '.cer' = $true; '.der' = $true; '.pfx' = $true; '.p12' = $true; '.keystore' = $true

    # Office, publishing and design formats that are containers/binary documents
    '.pdf' = $true; '.doc' = $true; '.docx' = $true; '.xls' = $true; '.xlsx' = $true; '.xlsm' = $true; '.ppt' = $true; '.pptx' = $true
    '.odt' = $true; '.ods' = $true; '.odp' = $true; '.epub' = $true; '.psd' = $true; '.ai' = $true; '.sketch' = $true
    '.blend' = $true; '.fbx' = $true; '.glb' = $true; '.3ds' = $true; '.dwg' = $true
}

function New-Brush {
    param([Parameter(Mandatory = $true)][string]$Hex)
    $converter = New-Object System.Windows.Media.BrushConverter
    return $converter.ConvertFromString($Hex)
}

function Invoke-WpfEvents {
    $dispatcher = [System.Windows.Threading.Dispatcher]::CurrentDispatcher
    $frame = New-Object System.Windows.Threading.DispatcherFrame
    [void]$dispatcher.BeginInvoke(
        [System.Windows.Threading.DispatcherPriority]::Background,
        [System.Windows.Threading.DispatcherOperationCallback]{
            param($dispatcherFrame)
            $dispatcherFrame.Continue = $false
            return $null
        },
        $frame
    )
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
}

function Show-LoadingWindow {
    param(
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $true)][string]$Detail
    )

    if ($script:LoadingWindow -ne $null) { return }

    $loadingXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Source Context Exporter"
        Width="560" Height="190" MinWidth="520" MinHeight="180"
        WindowStartupLocation="CenterScreen"
        Background="#F7F8FC"
        FontFamily="Segoe UI"
        ResizeMode="NoResize"
        ShowActivated="True"
        ShowInTaskbar="True"
        Topmost="True">
    <Border Margin="14" Background="White" CornerRadius="8" Padding="16" BorderBrush="#EAECF0" BorderThickness="1">
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto" />
                <RowDefinition Height="Auto" />
                <RowDefinition Height="Auto" />
                <RowDefinition Height="Auto" />
            </Grid.RowDefinitions>
            <TextBlock Grid.Row="0" Text="Source Context Exporter" FontSize="20" FontWeight="SemiBold" Foreground="#111827" />
            <TextBlock Name="LoadingStatusText" Grid.Row="1" Margin="0,10,0,0" TextWrapping="Wrap" Foreground="#344054" />
            <ProgressBar Grid.Row="2" Height="14" Margin="0,14,0,0" IsIndeterminate="True" />
            <TextBlock Name="LoadingDetailText" Grid.Row="3" Margin="0,12,0,0" TextWrapping="Wrap" Foreground="#667085" FontSize="12" MaxHeight="48" />
        </Grid>
    </Border>
</Window>
"@

    [xml]$loadingXamlXml = $loadingXaml
    $reader = New-Object System.Xml.XmlNodeReader $loadingXamlXml
    $script:LoadingWindow = [Windows.Markup.XamlReader]::Load($reader)
    $script:LoadingStatusText = $script:LoadingWindow.FindName('LoadingStatusText')
    $script:LoadingDetailText = $script:LoadingWindow.FindName('LoadingDetailText')
    $script:LoadingStatusText.Text = $Status
    $script:LoadingDetailText.Text = $Detail
    $script:LoadingWindow.Show()
    [void]$script:LoadingWindow.Activate()
    Invoke-WpfEvents
}

function Update-LoadingWindow {
    param(
        [Parameter(Mandatory = $true)][string]$Status,
        [string]$Detail = '',
        [switch]$Force
    )

    if ($script:LoadingWindow -eq $null) { return }

    $now = Get-Date
    if (-not $Force -and (($now - $script:LastLoadingUpdate).TotalMilliseconds -lt 100)) {
        return
    }

    $script:LastLoadingUpdate = $now
    $script:LoadingStatusText.Text = $Status
    $script:LoadingDetailText.Text = $Detail
    Invoke-WpfEvents
}

function Close-LoadingWindow {
    if ($script:LoadingWindow -eq $null) { return }
    $script:LoadingWindow.Close()
    $script:LoadingWindow = $null
    $script:LoadingStatusText = $null
    $script:LoadingDetailText = $null
    Invoke-WpfEvents
}

function Update-ScanProgress {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$Force
    )

    $script:ScannedItemCount++
    Update-LoadingWindow -Status 'Scanning folder tree...' -Detail (('{0} items scanned' -f $script:ScannedItemCount) + "`r`n" + $Path) -Force:$Force
}

function New-StringSet {
    return ,(New-Object 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase))
}

function Read-ExporterConfiguration {
    $script:IgnoredFolderNames = New-StringSet
    $configPath = Join-Path $PSScriptRoot 'source-context-exporter.config.json'

    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        return
    }

    try {
        $config = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
    }
    catch {
        throw ("Configuration could not be read:`r`n{0}`r`n{1}" -f $configPath, $_.Exception.Message)
    }

    if ($config -eq $null) {
        return
    }

    $ignoredNamesProperty = $config.PSObject.Properties['ignoredFolderNames']
    if ($ignoredNamesProperty -eq $null) {
        return
    }

    foreach ($name in @($ignoredNamesProperty.Value)) {
        if ($name -eq $null) { continue }

        $folderName = ([string]$name).Trim()
        if ([string]::IsNullOrWhiteSpace($folderName)) { continue }
        if ($folderName.Contains('\') -or $folderName.Contains('/')) {
            throw ("Ignored folder names must not contain path separators: {0}" -f $folderName)
        }

        [void]$script:IgnoredFolderNames.Add($folderName)
    }
}

function Test-FolderIgnored {
    param([Parameter(Mandatory = $true)][System.IO.DirectoryInfo]$DirectoryInfo)

    if ($script:IgnoredFolderNames -eq $null) { return $false }
    return $script:IgnoredFolderNames.Contains($DirectoryInfo.Name)
}

function Test-IsNonTextExtension {
    param([Parameter(Mandatory = $true)][string]$Extension)

    if ($script:NonTextExtensions.ContainsKey($Extension)) {
        return $true
    }

    if ($script:LanguageByExtension.ContainsKey($Extension)) {
        return $false
    }

    if ($Extension -eq $script:NoExtensionKey) {
        return $false
    }

    # Unknown extensions are intentionally metadata-only. This is safer than
    # assuming an unfamiliar format is text and feeding arbitrary bytes to ReadAllLines.
    return $true
}

function Test-FileSupportsTextContent {
    param([Parameter(Mandatory = $true)][object]$FileNode)

    if ($script:NonTextExtensions.ContainsKey($FileNode.Extension)) {
        return $false
    }

    if ($script:LanguageByExtension.ContainsKey($FileNode.Extension)) {
        return $true
    }

    if ($FileNode.Extension -ne $script:NoExtensionKey) {
        return $false
    }

    $lowerName = $FileNode.Name.ToLowerInvariant()
    switch -Regex ($lowerName) {
        '^dockerfile$' { return $true }
        '^makefile$' { return $true }
        '^cmakelists\.txt$' { return $true }
        '^\.gitignore$' { return $true }
        '^\.gitattributes$' { return $true }
        '^\.gitmodules$' { return $true }
        '^\.dockerignore$' { return $true }
        '^\.editorconfig$' { return $true }
        '^\.env(\..*)?$' { return $true }
    }

    return $false
}

function Test-FileTypeEnabled {
    param([Parameter(Mandatory = $true)][object]$FileNode)

    if (-not $script:ExtensionEnabled.ContainsKey($FileNode.Extension)) {
        return $true
    }

    return [bool]$script:ExtensionEnabled[$FileNode.Extension]
}

function Get-DefaultExtensionEnabled {
    param([Parameter(Mandatory = $true)][string]$Extension)
    if (Test-IsNonTextExtension -Extension $Extension) {
        return $false
    }
    return $true
}

function Format-ExtensionLabel {
    param([Parameter(Mandatory = $true)][string]$Extension)
    if ($Extension -eq $script:NoExtensionKey) {
        return '(no extension)'
    }
    return $Extension
}

function Format-Size {
    param([Parameter(Mandatory = $true)][Int64]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N1} KB' -f ($Bytes / 1KB)) }
    return ('{0} B' -f $Bytes)
}

function Get-AlternateWslUncPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $normalized = $Path.Replace('/', '\')

    if ($normalized -match '^\\\\wsl\.localhost\\([^\\]+)(\\.*)?$') {
        $distribution = $Matches[1]
        $rest = $(if ($null -eq $Matches[2]) { '' } else { $Matches[2] })
        return ('\\wsl$\' + $distribution + $rest)
    }

    if ($normalized -match '^\\\\wsl\$\\([^\\]+)(\\.*)?$') {
        $distribution = $Matches[1]
        $rest = $(if ($null -eq $Matches[2]) { '' } else { $Matches[2] })
        return ('\\wsl.localhost\' + $distribution + $rest)
    }

    return $null
}

function ConvertTo-ComparableFileSystemPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $normalized = $Path.Replace('/', '\').TrimEnd('\')

    if ($normalized -match '^\\\\wsl\.localhost\\([^\\]+)(\\.*)?$') {
        $distribution = $Matches[1]
        $rest = $(if ($null -eq $Matches[2]) { '' } else { $Matches[2] })
        return ('\\wsl$\' + $distribution + $rest)
    }

    return $normalized
}

function Get-RelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$BasePath,
        [Parameter(Mandatory = $true)][string]$FullPath
    )

    $baseComparable = ConvertTo-ComparableFileSystemPath -Path $BasePath
    $targetComparable = ConvertTo-ComparableFileSystemPath -Path $FullPath

    if ([string]::Equals(
        $baseComparable,
        $targetComparable,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        return '.'
    }

    $prefix = $baseComparable + '\'
    if ($targetComparable.StartsWith(
        $prefix,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        return $targetComparable.Substring($prefix.Length).Replace('\', '/')
    }

    try {
        $baseFull = [System.IO.Path]::GetFullPath($BasePath)
        if (-not $baseFull.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
            $baseFull += [System.IO.Path]::DirectorySeparatorChar
        }

        $targetFull = [System.IO.Path]::GetFullPath($FullPath)
        $baseUri = New-Object System.Uri -ArgumentList $baseFull
        $targetUri = New-Object System.Uri -ArgumentList $targetFull
        $relative = [System.Uri]::UnescapeDataString(
            $baseUri.MakeRelativeUri($targetUri).ToString()
        )
        return $relative.Replace('\', '/')
    }
    catch {
        throw (
            "Could not calculate a relative path.`r`n" +
            "Base: $BasePath`r`n" +
            "Target: $FullPath`r`n" +
            $_.Exception.Message
        )
    }
}

function Get-CompatibleDirectoryListing {
    param([Parameter(Mandatory = $true)][string]$Path)

    $candidates = New-Object System.Collections.ArrayList
    [void]$candidates.Add($Path)

    $alternate = Get-AlternateWslUncPath -Path $Path
    if (
        -not [string]::IsNullOrWhiteSpace($alternate) -and
        -not [string]::Equals(
            $alternate,
            $Path,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    ) {
        [void]$candidates.Add($alternate)
    }

    $errors = New-Object System.Collections.ArrayList

    foreach ($candidate in $candidates) {
        try {
            $items = @(
                Get-ChildItem -LiteralPath $candidate -Force -ErrorAction Stop |
                    Sort-Object -Property @{ Expression = { $_.PSIsContainer }; Descending = $true }, Name
            )

            return [pscustomobject]@{
                Path  = [string]$candidate
                Items = $items
            }
        }
        catch {
            [void]$errors.Add(
                ('{0}: {1}' -f $candidate, $_.Exception.Message)
            )
        }
    }

    throw (
        "Could not enumerate directory through any compatible Windows path:`r`n" +
        ($errors -join "`r`n")
    )
}

function Add-DirectoryScanNote {
    param(
        [Parameter(Mandatory = $true)][object]$DirectoryNode,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ([string]::IsNullOrWhiteSpace([string]$DirectoryNode.ScanError)) {
        $DirectoryNode.ScanError = $Message
        return
    }

    $existingLines = @(([string]$DirectoryNode.ScanError) -split "`r?`n")
    if ($existingLines.Count -lt 8) {
        $DirectoryNode.ScanError += "`r`n" + $Message
    }
    elseif (-not ([string]$DirectoryNode.ScanError).EndsWith('Additional child errors omitted.')) {
        $DirectoryNode.ScanError += "`r`nAdditional child errors omitted."
    }
}

function Add-ExtensionIndex {
    param(
        [Parameter(Mandatory = $true)][string]$Extension,
        [Parameter(Mandatory = $true)][object]$FileNode
    )

    if (-not $script:ExtensionToFiles.ContainsKey($Extension)) {
        $script:ExtensionToFiles[$Extension] = New-Object System.Collections.ArrayList
    }
    [void]$script:ExtensionToFiles[$Extension].Add($FileNode)

    if (-not $script:ExtensionEnabled.ContainsKey($Extension)) {
        $script:ExtensionEnabled[$Extension] = Get-DefaultExtensionEnabled -Extension $Extension
    }

    # Lazy index: only directories that have actually been enumerated exist here.
    if ($FileNode.Parent -ne $null) {
        if (-not $script:ExtensionToDirectories.ContainsKey($Extension)) {
            $script:ExtensionToDirectories[$Extension] = New-StringSet
        }
        [void]$script:ExtensionToDirectories[$Extension].Add($FileNode.Parent.FullPath)
    }
}

function Add-CountDelta {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Table,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][int]$Delta
    )

    if ($Delta -eq 0) { return }

    $current = 0
    if ($Table.ContainsKey($Key)) {
        $current = [int]$Table[$Key]
    }

    $next = $current + $Delta
    if ($next -le 0) {
        [void]$Table.Remove($Key)
    }
    else {
        $Table[$Key] = $next
    }
}

function Merge-CountTable {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Target,
        [Parameter(Mandatory = $true)][hashtable]$Source,
        [int]$Multiplier = 1
    )

    if ($Multiplier -eq 0) { return }

    foreach ($key in $Source.Keys) {
        Add-CountDelta -Table $Target -Key ([string]$key) -Delta ([int]$Source[$key] * $Multiplier)
    }
}

function New-FileNode {
    param(
        [Parameter(Mandatory = $true)][System.IO.FileInfo]$FileInfo,
        [Parameter(Mandatory = $true)][object]$Parent
    )

    $extension = $FileInfo.Extension
    if ([string]::IsNullOrWhiteSpace($extension)) {
        $extension = $script:NoExtensionKey
    }
    else {
        $extension = $extension.ToLowerInvariant()
    }

    $set = New-StringSet
    [void]$set.Add($extension)

    $node = [pscustomobject]@{
        Name           = $FileInfo.Name
        FullPath       = $FileInfo.FullName
        RelPath        = (Get-RelativePath -BasePath $TargetFolder -FullPath $FileInfo.FullName)
        IsDirectory    = $false
        Extension      = $extension
        Parent         = $Parent
        Children       = (New-Object System.Collections.ArrayList)
        Included       = $true
        SelectionState = $true
        TotalFiles     = 1
        SizeBytes      = [Int64]$FileInfo.Length
        ExtensionSet   = $set
        UiItem         = $null
        CheckBox       = $null
        ScanError      = $null
        IsReparsePoint = $false
        EntryOverride  = $null
        ContentOverride = $null
        EffectiveEntry = $true
        EffectiveContent = $true
        SubtreeOverrideCount = 0
        SelectionSummaryCache = @{}
        JsonLocalRules = (New-Object System.Collections.ArrayList)
        JsonRemoveEmptyArrays = $false
    }

    [void]$script:AllFileNodes.Add($node)
    Add-ExtensionIndex -Extension $extension -FileNode $node
    return $node
}

function New-DirectoryNode {
    param(
        [Parameter(Mandatory = $true)][string]$FullPath,
        [object]$Parent = $null,
        [System.IO.DirectoryInfo]$DirectoryInfo = $null
    )

    $directoryInfo = $DirectoryInfo
    if ($null -eq $directoryInfo) {
        $directoryInfo = Get-Item -LiteralPath $FullPath -Force
    }
    $name = $directoryInfo.Name
    if ([string]::IsNullOrWhiteSpace($name)) {
        $name = $directoryInfo.FullName
    }

    $isReparsePoint = (($directoryInfo.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)

    $node = [pscustomobject]@{
        Name           = $name
        FullPath       = $directoryInfo.FullName
        RelPath        = $(if ($Parent -eq $null) { '.' } else { Get-RelativePath -BasePath $TargetFolder -FullPath $directoryInfo.FullName })
        IsDirectory    = $true
        Extension      = $null
        Parent         = $Parent
        Children       = (New-Object System.Collections.ArrayList)
        Included       = $true
        SelectionState = $true

        # Lazy subtree metadata. Counts are exact only when SubtreeFullyScanned is true.
        TotalFiles     = 0
        SizeBytes      = [Int64]0
        ExtensionSet   = (New-StringSet)
        ChildrenLoaded = $false
        SubtreeFullyScanned = $false
        UiChildrenMaterialized = $false

        UiItem         = $null
        CheckBox       = $null
        ScanError      = $null
        IsReparsePoint = $isReparsePoint
        EntryOverride  = $(if ($Parent -eq $null) { $false } else { $null })
        ChildrenOverride = $(if ($Parent -eq $null) { $false } else { $null })
        RecursiveContentOverride = $(if ($Parent -eq $null) { $false } else { $null })
        EffectiveEntry = $true
        EffectiveChildren = $true
        EffectiveContent = $true
        SubtreeDirectoryCount = 1
        SubtreeFileCountByExtension = @{}
        SubtreeTextFileCountByExtension = @{}
        SubtreeOverrideCount = $(if ($Parent -eq $null) { 3 } else { 0 })
        OverrideChildren = @{}
        SelectionSummaryCache = @{}
    }

    if ($isReparsePoint -and $Parent -ne $null) {
        $node.ScanError = 'Reparse point/junction is treated as a leaf and is not followed recursively.'
        $node.ChildrenLoaded = $true
        $node.SubtreeFullyScanned = $true
    }

    [void]$script:AllDirectoryNodes.Add($node)
    return $node
}

function Rebuild-KnownAggregateMetadataForDirectory {
    param([Parameter(Mandatory = $true)][object]$Node)

    if (-not $Node.IsDirectory) { return }

    $Node.TotalFiles = 0
    $Node.SizeBytes = [Int64]0
    $Node.SubtreeDirectoryCount = 1
    $Node.SubtreeFileCountByExtension = @{}
    $Node.SubtreeTextFileCountByExtension = @{}
    $Node.ExtensionSet = New-StringSet

    $fullyScanned = [bool]$Node.ChildrenLoaded

    foreach ($child in $Node.Children) {
        $Node.SizeBytes += [Int64]$child.SizeBytes

        if ($child.IsDirectory) {
            $Node.TotalFiles += [int]$child.TotalFiles
            $Node.SubtreeDirectoryCount += [int]$child.SubtreeDirectoryCount
            Merge-CountTable -Target $Node.SubtreeFileCountByExtension -Source $child.SubtreeFileCountByExtension
            Merge-CountTable -Target $Node.SubtreeTextFileCountByExtension -Source $child.SubtreeTextFileCountByExtension

            foreach ($extension in $child.ExtensionSet) {
                [void]$Node.ExtensionSet.Add($extension)
            }

            if (-not [bool]$child.SubtreeFullyScanned) {
                $fullyScanned = $false
            }
        }
        else {
            $Node.TotalFiles++
            Add-CountDelta -Table $Node.SubtreeFileCountByExtension -Key $child.Extension -Delta 1
            if (Test-FileSupportsTextContent -FileNode $child) {
                Add-CountDelta -Table $Node.SubtreeTextFileCountByExtension -Key $child.Extension -Delta 1
            }
            [void]$Node.ExtensionSet.Add($child.Extension)
        }
    }

    $Node.SubtreeFullyScanned = ([bool]$Node.ChildrenLoaded -and $fullyScanned)
}

function Rebuild-KnownAggregateMetadataUpward {
    param([Parameter(Mandatory = $true)][object]$DirectoryNode)

    $current = $DirectoryNode
    while ($current -ne $null) {
        if ($current.IsDirectory) {
            Rebuild-KnownAggregateMetadataForDirectory -Node $current
            $current.SelectionSummaryCache.Clear()
        }
        $current = $current.Parent
    }
}

function Ensure-DirectoryChildrenLoaded {
    param(
        [Parameter(Mandatory = $true)][object]$DirectoryNode,
        [switch]$Quiet,
        [switch]$SkipAggregateRebuild
    )

    if (-not $DirectoryNode.IsDirectory) { return }
    if ([bool]$DirectoryNode.ChildrenLoaded) { return }

    if ($DirectoryNode.IsReparsePoint) {
        $DirectoryNode.ChildrenLoaded = $true
        $DirectoryNode.SubtreeFullyScanned = $true
        return
    }

    if (-not $Quiet) {
        if ($script:StatusText -ne $null) {
            $script:StatusText.Text = ('Loading folder: {0}' -f $DirectoryNode.RelPath)
        }
        [System.Windows.Input.Mouse]::OverrideCursor = [System.Windows.Input.Cursors]::Wait
        Invoke-WpfEvents
    }

    try {
        $listing = Get-CompatibleDirectoryListing -Path $DirectoryNode.FullPath

        if (-not [string]::Equals(
            [string]$listing.Path,
            [string]$DirectoryNode.FullPath,
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
            $DirectoryNode.FullPath = [string]$listing.Path
        }

        foreach ($item in @($listing.Items)) {
            try {
                if ($item.PSIsContainer) {
                    if (Test-FolderIgnored -DirectoryInfo $item) {
                        $script:IgnoredDirectoryCount++
                        continue
                    }

                    $child = New-DirectoryNode `
                        -FullPath $item.FullName `
                        -Parent $DirectoryNode `
                        -DirectoryInfo $item
                }
                else {
                    $child = New-FileNode -FileInfo $item -Parent $DirectoryNode
                }

                [void]$DirectoryNode.Children.Add($child)
            }
            catch {
                Add-DirectoryScanNote `
                    -DirectoryNode $DirectoryNode `
                    -Message ('{0}: {1}' -f $item.Name, $_.Exception.Message)
            }
        }

        $DirectoryNode.ChildrenLoaded = $true
    }
    catch {
        $DirectoryNode.ScanError = $_.Exception.Message
        $DirectoryNode.ChildrenLoaded = $true

        if ($DirectoryNode.Parent -eq $null) {
            throw
        }
    }
    finally {
        if (-not $SkipAggregateRebuild) {
            Rebuild-KnownAggregateMetadataUpward -DirectoryNode $DirectoryNode
        }

        if (-not $Quiet) {
            [System.Windows.Input.Mouse]::OverrideCursor = $null
        }
    }
}

function Show-RecursiveStructureScanWindow {
    param([Parameter(Mandatory = $true)][object]$DirectoryNode)

    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Scanning selected structure"
        Width="620" Height="245" MinWidth="560" MinHeight="230"
        WindowStartupLocation="CenterOwner"
        Background="#F7F8FC"
        FontFamily="Segoe UI"
        ResizeMode="NoResize"
        ShowInTaskbar="False">
    <Border Margin="14" Background="White" CornerRadius="10" Padding="14" BorderBrush="#EAECF0" BorderThickness="1">
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto" />
                <RowDefinition Height="Auto" />
                <RowDefinition Height="Auto" />
                <RowDefinition Height="Auto" />
                <RowDefinition Height="Auto" />
            </Grid.RowDefinitions>

            <TextBlock Grid.Row="0" Text="Scanning directory structure..." FontSize="18" FontWeight="SemiBold" Foreground="#111827" />
            <TextBlock Name="ScanStatusText" Grid.Row="1" Margin="0,10,0,0" Foreground="#344054" TextWrapping="Wrap" />
            <ProgressBar Name="ScanProgressBar" Grid.Row="2" Height="16" Margin="0,12,0,0" Minimum="0" Maximum="100" />
            <TextBlock Name="ScanDetailText" Grid.Row="3" Margin="0,10,0,0" Foreground="#667085" FontSize="12" TextWrapping="Wrap" MaxHeight="54" />
            <Button Name="CancelScanButton" Grid.Row="4" Content="Cancel" Width="110" Padding="12,6" Margin="0,12,0,0" HorizontalAlignment="Right" />
        </Grid>
    </Border>
</Window>
"@

    [xml]$xamlXml = $xaml
    $reader = New-Object System.Xml.XmlNodeReader $xamlXml
    $window = [Windows.Markup.XamlReader]::Load($reader)

    if ($script:Window -ne $null) {
        $window.Owner = $script:Window
    }

    $statusText = $window.FindName('ScanStatusText')
    $progressBar = $window.FindName('ScanProgressBar')
    $detailText = $window.FindName('ScanDetailText')
    $cancelButton = $window.FindName('CancelScanButton')

    $state = [pscustomobject]@{
        Window                = $window
        StatusText            = $statusText
        ProgressBar           = $progressBar
        DetailText            = $detailText
        CancelButton          = $cancelButton
        CancelRequested       = $false
        Completed             = $false
        ProcessedDirectories  = 0
        DiscoveredDirectories = 1
        DiscoveredFiles       = 0
        LastUiUpdate          = [DateTime]::MinValue
        OwnerWindow           = $script:Window
        OwnerWasEnabled       = $(if ($script:Window -ne $null) { [bool]$script:Window.IsEnabled } else { $false })
    }

    $window.Tag = $state
    $cancelButton.Tag = $state

    $cancelButton.Add_Click({
        param($sender, $eventArgs)
        $scanState = $sender.Tag
        $scanState.CancelRequested = $true
        $sender.IsEnabled = $false
        $sender.Content = 'Canceling...'
    })

    $window.Add_Closing({
        param($sender, $eventArgs)
        $scanState = $sender.Tag
        if (-not $scanState.Completed) {
            $scanState.CancelRequested = $true
            $eventArgs.Cancel = $true
            $scanState.CancelButton.IsEnabled = $false
            $scanState.CancelButton.Content = 'Canceling...'
        }
    })

    $statusText.Text = 'Preparing scan...'
    $detailText.Text = $DirectoryNode.RelPath
    $progressBar.Value = 0

    $window.Show()
    if ($script:Window -ne $null) {
        $script:Window.IsEnabled = $false
    }
    [void]$window.Activate()
    Invoke-WpfEvents
    return $state
}

function Update-RecursiveStructureScanWindow {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [string]$CurrentPath = '',
        [switch]$Force
    )

    $now = Get-Date
    if (-not $Force -and (($now - $State.LastUiUpdate).TotalMilliseconds -lt 60)) {
        return
    }

    $State.LastUiUpdate = $now

    $discovered = [Math]::Max(1, [int]$State.DiscoveredDirectories)
    $processed = [int]$State.ProcessedDirectories
    $State.ProgressBar.Value = [Math]::Min(100.0, (100.0 * $processed / $discovered))
    $State.StatusText.Text = (
        '{0} of {1} currently discovered folders processed | {2} files found' -f
        $processed,
        $discovered,
        [int]$State.DiscoveredFiles
    )

    if (-not [string]::IsNullOrWhiteSpace($CurrentPath)) {
        $State.DetailText.Text = $CurrentPath
    }

    Invoke-WpfEvents
}

function Close-RecursiveStructureScanWindow {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][bool]$Completed
    )

    $State.Completed = $true
    if ($Completed) {
        $State.ProgressBar.Value = 100
    }

    Invoke-WpfEvents
    $State.Window.Close()

    if ($State.OwnerWindow -ne $null) {
        $State.OwnerWindow.IsEnabled = [bool]$State.OwnerWasEnabled
        [void]$State.OwnerWindow.Activate()
    }
}

function Invoke-RecursiveStructureScan {
    param([Parameter(Mandatory = $true)][object]$DirectoryNode)

    if (-not $DirectoryNode.IsDirectory) {
        throw 'Recursive structure scan requires a directory node.'
    }

    if ([bool]$DirectoryNode.SubtreeFullyScanned) {
        return [pscustomobject]@{
            Completed            = $true
            ProcessedDirectories = 0
            DiscoveredFiles      = 0
        }
    }

    $progress = Show-RecursiveStructureScanWindow -DirectoryNode $DirectoryNode
    $stack = New-Object System.Collections.Stack
    $stack.Push($DirectoryNode)

    $visited = New-Object System.Collections.ArrayList
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)

    try {
        while ($stack.Count -gt 0) {
            if ([bool]$progress.CancelRequested) {
                break
            }

            $directory = $stack.Pop()
            if (-not $seen.Add([string]$directory.FullPath)) {
                continue
            }

            Ensure-DirectoryChildrenLoaded `
                -DirectoryNode $directory `
                -Quiet `
                -SkipAggregateRebuild

            [void]$visited.Add($directory)
            $progress.ProcessedDirectories++

            $directFileCount = 0
            $childDirectories = New-Object System.Collections.ArrayList

            foreach ($child in $directory.Children) {
                if ($child.IsDirectory) {
                    if (-not $child.IsReparsePoint) {
                        [void]$childDirectories.Add($child)
                    }
                }
                else {
                    $directFileCount++
                }
            }

            $progress.DiscoveredFiles += $directFileCount

            for ($i = $childDirectories.Count - 1; $i -ge 0; $i--) {
                $stack.Push($childDirectories[$i])
            }

            $progress.DiscoveredDirectories = $progress.ProcessedDirectories + $stack.Count

            Update-RecursiveStructureScanWindow `
                -State $progress `
                -CurrentPath $directory.RelPath
        }

        for ($i = $visited.Count - 1; $i -ge 0; $i--) {
            $visited[$i].SelectionSummaryCache.Clear()
            Rebuild-KnownAggregateMetadataForDirectory -Node $visited[$i]
        }

        if ($DirectoryNode.Parent -ne $null) {
            Rebuild-KnownAggregateMetadataUpward -DirectoryNode $DirectoryNode.Parent
        }
        else {
            $DirectoryNode.SelectionSummaryCache.Clear()
        }

        $completed = (-not [bool]$progress.CancelRequested -and $stack.Count -eq 0)
        Update-RecursiveStructureScanWindow -State $progress -CurrentPath $DirectoryNode.RelPath -Force
        Close-RecursiveStructureScanWindow -State $progress -Completed $completed

        return [pscustomobject]@{
            Completed            = $completed
            ProcessedDirectories = [int]$progress.ProcessedDirectories
            DiscoveredFiles      = [int]$progress.DiscoveredFiles
        }
    }
    catch {
        try {
            $progress.Completed = $true
            $progress.Window.Close()
            if ($progress.OwnerWindow -ne $null) {
                $progress.OwnerWindow.IsEnabled = [bool]$progress.OwnerWasEnabled
                [void]$progress.OwnerWindow.Activate()
            }
        }
        catch {
        }
        throw
    }
}

function Index-DirectoryExtensions {
    param([Parameter(Mandatory = $true)][object]$Node)
    # Compatibility no-op. Extension indexes are populated as files are discovered.
}

function Ensure-ExportSelectionScannedRecursive {
    param(
        [Parameter(Mandatory = $true)][object]$Node,
        [Parameter(Mandatory = $true)][bool]$ParentStructure,
        [Parameter(Mandatory = $true)][bool]$ParentContent
    )

    Set-EffectiveExportState `
        -Node $Node `
        -ParentStructure $ParentStructure `
        -ParentContent $ParentContent

    if (-not $Node.IsDirectory) { return }

    if ([bool]$Node.EffectiveChildren) {
        Ensure-DirectoryChildrenLoaded -DirectoryNode $Node -Quiet

        foreach ($child in $Node.Children) {
            Ensure-ExportSelectionScannedRecursive `
                -Node $child `
                -ParentStructure ([bool]$Node.EffectiveChildren) `
                -ParentContent ([bool]$Node.EffectiveContent)
        }

        Rebuild-KnownAggregateMetadataForDirectory -Node $Node
        return
    }

    # If S=false, an unvisited descendant cannot contain a user override.
    # Only already-known override branches can still affect the export.
    foreach ($child in @($Node.OverrideChildren.Values)) {
        Ensure-ExportSelectionScannedRecursive `
            -Node $child `
            -ParentStructure ([bool]$Node.EffectiveChildren) `
            -ParentContent ([bool]$Node.EffectiveContent)
    }

    Rebuild-KnownAggregateMetadataForDirectory -Node $Node
}

function Ensure-ExportSelectionScanned {
    [System.Windows.Input.Mouse]::OverrideCursor = [System.Windows.Input.Cursors]::Wait
    try {
        if ($script:StatusText -ne $null) {
            $script:StatusText.Text = 'Scanning selected project branches for export...'
        }
        Invoke-WpfEvents

        Ensure-ExportSelectionScannedRecursive `
            -Node $script:RootNode `
            -ParentStructure $true `
            -ParentContent $true

        Rebuild-KnownAggregateMetadataUpward -DirectoryNode $script:RootNode
    }
    finally {
        [System.Windows.Input.Mouse]::OverrideCursor = $null
    }
}

function Resolve-ExportOverride {
    param(
        [AllowNull()][object]$OverrideValue,
        [Parameter(Mandatory = $true)][bool]$InheritedValue
    )

    if ($null -eq $OverrideValue) {
        return $InheritedValue
    }

    return [bool]$OverrideValue
}

function Set-EffectiveExportState {
    param(
        [Parameter(Mandatory = $true)][object]$Node,
        [Parameter(Mandatory = $true)][bool]$ParentStructure,
        [Parameter(Mandatory = $true)][bool]$ParentContent
    )

    if ($Node.IsDirectory) {
        $Node.EffectiveEntry = Resolve-ExportOverride -OverrideValue $Node.EntryOverride -InheritedValue $ParentStructure
        $Node.EffectiveChildren = Resolve-ExportOverride -OverrideValue $Node.ChildrenOverride -InheritedValue $ParentStructure
        $Node.EffectiveContent = Resolve-ExportOverride -OverrideValue $Node.RecursiveContentOverride -InheritedValue $ParentContent
        return
    }

    $Node.EffectiveEntry = Resolve-ExportOverride -OverrideValue $Node.EntryOverride -InheritedValue $ParentStructure
    $Node.EffectiveContent = Resolve-ExportOverride -OverrideValue $Node.ContentOverride -InheritedValue $ParentContent
}

function Get-ParentExportInheritance {
    param([Parameter(Mandatory = $true)][object]$Node)

    $ancestors = New-Object System.Collections.ArrayList
    $current = $Node.Parent
    while ($current -ne $null) {
        [void]$ancestors.Add($current)
        $current = $current.Parent
    }

    $parentStructure = $true
    $parentContent = $true

    for ($i = $ancestors.Count - 1; $i -ge 0; $i--) {
        $ancestor = $ancestors[$i]
        Set-EffectiveExportState `
            -Node $ancestor `
            -ParentStructure $parentStructure `
            -ParentContent $parentContent

        $parentStructure = [bool]$ancestor.EffectiveChildren
        $parentContent = [bool]$ancestor.EffectiveContent
    }

    return [pscustomobject]@{
        Structure = $parentStructure
        Content   = $parentContent
    }
}

function Clear-ExportSummaryCachesUpward {
    param([Parameter(Mandatory = $true)][object]$Node)

    $current = $Node
    while ($current -ne $null) {
        $current.SelectionSummaryCache.Clear()
        $current = $current.Parent
    }
}

function Update-OverridePresenceMetadata {
    param(
        [Parameter(Mandatory = $true)][object]$Node,
        [Parameter(Mandatory = $true)][int]$Delta
    )

    if ($Delta -eq 0) { return }

    $current = $Node
    while ($current -ne $null) {
        $oldCount = [int]$current.SubtreeOverrideCount
        $newCount = $oldCount + $Delta
        if ($newCount -lt 0) {
            throw "Internal selection override count became negative for $($current.FullPath)."
        }

        $current.SubtreeOverrideCount = $newCount
        $parent = $current.Parent

        if ($parent -ne $null) {
            if ($oldCount -eq 0 -and $newCount -gt 0) {
                $parent.OverrideChildren[$current.FullPath] = $current
            }
            elseif ($oldCount -gt 0 -and $newCount -eq 0) {
                [void]$parent.OverrideChildren.Remove($current.FullPath)
            }
        }

        $current = $parent
    }
}

function Set-ExportOverrideValue {
    param(
        [Parameter(Mandatory = $true)][object]$Node,
        [Parameter(Mandatory = $true)][string]$OverrideProperty,
        [AllowNull()][object]$Value,
        [switch]$Clear
    )

    $property = $Node.PSObject.Properties[$OverrideProperty]
    if ($null -eq $property) {
        throw "Selection override property not found: $OverrideProperty"
    }

    $oldValue = $property.Value
    $oldPresent = ($null -ne $oldValue)
    $newValue = $(if ($Clear) { $null } else { [bool]$Value })
    $newPresent = ($null -ne $newValue)

    $property.Value = $newValue

    if ($oldPresent -ne $newPresent) {
        Update-OverridePresenceMetadata `
            -Node $Node `
            -Delta $(if ($newPresent) { 1 } else { -1 })
    }

    Clear-ExportSummaryCachesUpward -Node $Node
}

function New-ExportSummary {
    return [pscustomobject]@{
        DirectoryEntryCount = 0
        FileEntryCounts      = @{}
        FileContentCounts    = @{}
    }
}

function Add-ExportSummary {
    param(
        [Parameter(Mandatory = $true)][object]$Target,
        [Parameter(Mandatory = $true)][object]$Source,
        [int]$Multiplier = 1
    )

    if ($Multiplier -eq 0) { return }

    $Target.DirectoryEntryCount += ([int]$Source.DirectoryEntryCount * $Multiplier)
    Merge-CountTable -Target $Target.FileEntryCounts -Source $Source.FileEntryCounts -Multiplier $Multiplier
    Merge-CountTable -Target $Target.FileContentCounts -Source $Source.FileContentCounts -Multiplier $Multiplier
}

function Add-BaselineChildContribution {
    param(
        [Parameter(Mandatory = $true)][object]$Summary,
        [Parameter(Mandatory = $true)][object]$Child,
        [Parameter(Mandatory = $true)][bool]$ParentStructure,
        [Parameter(Mandatory = $true)][bool]$ParentContent,
        [int]$Multiplier = 1
    )

    if (-not $ParentStructure -or $Multiplier -eq 0) {
        return
    }

    if ($Child.IsDirectory) {
        $Summary.DirectoryEntryCount += ([int]$Child.SubtreeDirectoryCount * $Multiplier)
        Merge-CountTable -Target $Summary.FileEntryCounts -Source $Child.SubtreeFileCountByExtension -Multiplier $Multiplier

        if ($ParentContent) {
            Merge-CountTable -Target $Summary.FileContentCounts -Source $Child.SubtreeTextFileCountByExtension -Multiplier $Multiplier
        }
        return
    }

    Add-CountDelta -Table $Summary.FileEntryCounts -Key $Child.Extension -Delta $Multiplier

    if ($ParentContent -and (Test-FileSupportsTextContent -FileNode $Child)) {
        Add-CountDelta -Table $Summary.FileContentCounts -Key $Child.Extension -Delta $Multiplier
    }
}

function Get-ExportSubtreeSummary {
    param(
        [Parameter(Mandatory = $true)][object]$Node,
        [Parameter(Mandatory = $true)][bool]$ParentStructure,
        [Parameter(Mandatory = $true)][bool]$ParentContent
    )

    $cacheKey = ('s{0}c{1}' -f $(if ($ParentStructure) { 1 } else { 0 }), $(if ($ParentContent) { 1 } else { 0 }))
    if ($Node.SelectionSummaryCache.ContainsKey($cacheKey)) {
        return $Node.SelectionSummaryCache[$cacheKey]
    }

    Set-EffectiveExportState `
        -Node $Node `
        -ParentStructure $ParentStructure `
        -ParentContent $ParentContent

    $summary = New-ExportSummary

    if (-not $Node.IsDirectory) {
        if ([bool]$Node.EffectiveEntry) {
            Add-CountDelta -Table $summary.FileEntryCounts -Key $Node.Extension -Delta 1

            if (
                [bool]$Node.EffectiveContent -and
                (Test-FileSupportsTextContent -FileNode $Node)
            ) {
                Add-CountDelta -Table $summary.FileContentCounts -Key $Node.Extension -Delta 1
            }
        }

        $Node.SelectionSummaryCache[$cacheKey] = $summary
        return $summary
    }

    if ([bool]$Node.EffectiveEntry) {
        $summary.DirectoryEntryCount = 1
    }

    # Start with the no-override baseline for every descendant. This is O(number
    # of extensions), not O(number of descendants).
    if ([bool]$Node.EffectiveChildren) {
        $summary.DirectoryEntryCount += ([int]$Node.SubtreeDirectoryCount - 1)
        Merge-CountTable -Target $summary.FileEntryCounts -Source $Node.SubtreeFileCountByExtension

        if ([bool]$Node.EffectiveContent) {
            Merge-CountTable -Target $summary.FileContentCounts -Source $Node.SubtreeTextFileCountByExtension
        }
    }

    # Only branches that actually contain explicit overrides can differ from the
    # baseline. Replace those branch contributions with their exact summaries.
    foreach ($child in @($Node.OverrideChildren.Values)) {
        Add-BaselineChildContribution `
            -Summary $summary `
            -Child $child `
            -ParentStructure ([bool]$Node.EffectiveChildren) `
            -ParentContent ([bool]$Node.EffectiveContent) `
            -Multiplier -1

        $childSummary = Get-ExportSubtreeSummary `
            -Node $child `
            -ParentStructure ([bool]$Node.EffectiveChildren) `
            -ParentContent ([bool]$Node.EffectiveContent)

        Add-ExportSummary -Target $summary -Source $childSummary
    }

    $Node.SelectionSummaryCache[$cacheKey] = $summary
    return $summary
}

function Add-SelectedExportNodesRecursive {
    param(
        [Parameter(Mandatory = $true)][object]$Node,
        [Parameter(Mandatory = $true)][bool]$ParentStructure,
        [Parameter(Mandatory = $true)][bool]$ParentContent,
        [Parameter(Mandatory = $true)][System.Collections.IList]$List
    )

    Set-EffectiveExportState `
        -Node $Node `
        -ParentStructure $ParentStructure `
        -ParentContent $ParentContent

    if (-not $Node.IsDirectory) {
        if (Test-FileSelectedForExport -FileNode $Node) {
            [void]$List.Add($Node)
        }
        return
    }

    if ([bool]$Node.EffectiveEntry) {
        [void]$List.Add($Node)
    }

    # If structure is disabled and no descendant has an override, the entire
    # branch is provably absent from the export and can be skipped wholesale.
    if (-not [bool]$Node.EffectiveChildren -and $Node.OverrideChildren.Count -eq 0) {
        return
    }

    foreach ($child in $Node.Children) {
        if (
            [bool]$Node.EffectiveChildren -or
            [int]$child.SubtreeOverrideCount -gt 0
        ) {
            Add-SelectedExportNodesRecursive `
                -Node $child `
                -ParentStructure ([bool]$Node.EffectiveChildren) `
                -ParentContent ([bool]$Node.EffectiveContent) `
                -List $List
        }
    }
}

function Test-FileSelectedByTree {
    param([Parameter(Mandatory = $true)][object]$FileNode)

    if ($FileNode.IsDirectory) { return $false }
    return [bool]$FileNode.EffectiveEntry
}

function Test-FileSelectedForExport {
    param([Parameter(Mandatory = $true)][object]$FileNode)

    if (-not (Test-FileSelectedByTree -FileNode $FileNode)) { return $false }
    return (Test-FileTypeEnabled -FileNode $FileNode)
}

function Test-FileContentSelectedForExport {
    param([Parameter(Mandatory = $true)][object]$FileNode)

    if (-not (Test-FileSelectedForExport -FileNode $FileNode)) { return $false }
    if (-not [bool]$FileNode.EffectiveContent) { return $false }
    return (Test-FileSupportsTextContent -FileNode $FileNode)
}

function Get-SelectedFiles {
    return @(
        (Get-SelectedExportNodes) |
            Where-Object { -not $_.IsDirectory }
    )
}

function Get-SelectedDirectories {
    return @(
        (Get-SelectedExportNodes) |
            Where-Object { $_.IsDirectory }
    )
}

function Get-SelectedExportNodes {
    # Exact enumeration is deferred until the user actually exports/copies.
    Ensure-ExportSelectionScanned

    $list = New-Object System.Collections.ArrayList

    Add-SelectedExportNodesRecursive `
        -Node $script:RootNode `
        -ParentStructure $true `
        -ParentContent $true `
        -List $list

    return @(
        $list |
            Sort-Object -Property RelPath, @{ Expression = { $_.IsDirectory }; Descending = $true }
    )
}

function Get-LanguageForNode {
    param([Parameter(Mandatory = $true)][object]$FileNode)

    $lowerName = $FileNode.Name.ToLowerInvariant()
    switch -Regex ($lowerName) {
        '^dockerfile$' { return 'dockerfile' }
        '^makefile$' { return 'makefile' }
        '^cmakelists\.txt$' { return 'cmake' }
        '^\.gitignore$' { return 'gitignore' }
        '^\.dockerignore$' { return 'dockerignore' }
        '^\.env(\..*)?$' { return 'dotenv' }
    }

    $extension = $FileNode.Extension
    if ($script:LanguageByExtension.ContainsKey($extension)) {
        return $script:LanguageByExtension[$extension]
    }
    if ($extension -eq $script:NoExtensionKey) {
        return 'text'
    }
    return $extension.TrimStart('.')
}

function Get-FileTypeDescription {
    param([Parameter(Mandatory = $true)][object]$FileNode)

    switch ($FileNode.Extension) {
        '.cs' { return 'C# source file' }
        '.fs' { return 'F# source file' }
        '.vb' { return 'Visual Basic source file' }
        '.py' { return 'Python source file' }
        '.js' { return 'JavaScript source file' }
        '.ts' { return 'TypeScript source file' }
        '.tsx' { return 'TypeScript/TSX source file' }
        '.jsx' { return 'JavaScript/JSX source file' }
        '.java' { return 'Java source file' }
        '.kt' { return 'Kotlin source file' }
        '.cpp' { return 'C++ source file' }
        '.c' { return 'C source file' }
        '.h' { return 'C/C++ header file' }
        '.json' { return 'JSON document' }
        '.jsonc' { return 'JSON-with-comments document' }
        '.xml' { return 'XML document' }
        '.html' { return 'HTML document' }
        '.css' { return 'CSS stylesheet' }
        '.md' { return 'Markdown document' }
        '.m4a' { return 'M4A audio file' }
        '.mp3' { return 'MP3 audio file' }
        '.wav' { return 'WAV audio file' }
        '.flac' { return 'FLAC audio file' }
        '.mp4' { return 'MP4 media file' }
        '.mkv' { return 'Matroska video file' }
        '.png' { return 'PNG image' }
        '.jpg' { return 'JPEG image' }
        '.jpeg' { return 'JPEG image' }
        '.pdf' { return 'PDF document' }
        '.docx' { return 'Word document' }
        '.xlsx' { return 'Excel workbook' }
        '.pptx' { return 'PowerPoint presentation' }
    }

    if (Test-FileSupportsTextContent -FileNode $FileNode) {
        $language = Get-LanguageForNode -FileNode $FileNode
        if ($FileNode.Extension -eq $script:NoExtensionKey) {
            return ('text file ({0})' -f $language)
        }
        return ('text file ({0}, {1})' -f (Format-ExtensionLabel -Extension $FileNode.Extension), $language)
    }

    if ($FileNode.Extension -eq $script:NoExtensionKey) {
        return 'non-text or unknown extensionless file'
    }

    return ('non-text or unknown file ({0})' -f (Format-ExtensionLabel -Extension $FileNode.Extension))
}

function Append-LineSafe {
    param(
        [Parameter(Mandatory = $true)][System.Text.StringBuilder]$StringBuilder,
        [string]$Text = ''
    )
    [void]$StringBuilder.AppendLine($Text)
}

function New-SourceContextMarkdown {
    param(
        [Parameter(Mandatory = $true)][object[]]$Nodes,
        [Parameter(Mandatory = $true)][bool]$IncludeLineNumbers
    )

    $directoryNodes = @($Nodes | Where-Object { $_.IsDirectory })
    $fileNodes = @($Nodes | Where-Object { -not $_.IsDirectory })
    $contentFileCount = 0
    foreach ($file in $fileNodes) {
        if (Test-FileContentSelectedForExport -FileNode $file) {
            $contentFileCount++
        }
    }

    $sb = New-Object System.Text.StringBuilder
    Append-LineSafe -StringBuilder $sb -Text '# Source Code Context'
    Append-LineSafe -StringBuilder $sb
    Append-LineSafe -StringBuilder $sb -Text ('Root: `{0}`' -f $TargetFolder)
    Append-LineSafe -StringBuilder $sb -Text ('Generated: {0:yyyy-MM-dd HH:mm:ss}' -f (Get-Date))
    Append-LineSafe -StringBuilder $sb -Text ('Entries: {0} ({1} directories, {2} files)' -f $Nodes.Count, $directoryNodes.Count, $fileNodes.Count)
    Append-LineSafe -StringBuilder $sb -Text ('Files with content: {0}' -f $contentFileCount)
    Append-LineSafe -StringBuilder $sb -Text ('Line numbers: {0}' -f $(if ($IncludeLineNumbers) { 'yes' } else { 'no' }))
    Append-LineSafe -StringBuilder $sb
    Append-LineSafe -StringBuilder $sb -Text 'This text contains selected project structure and, where enabled, selected file contents for LLM review.'
    Append-LineSafe -StringBuilder $sb -Text 'Paths are relative to the export directory. Metadata-only file entries never cause their file contents to be read.'
    Append-LineSafe -StringBuilder $sb
    Append-LineSafe -StringBuilder $sb -Text '## Selected Structure'

    foreach ($node in $Nodes) {
        if ($node.IsDirectory) {
            $displayPath = $(if ($node.RelPath -eq '.') { './' } else { $node.RelPath.TrimEnd('/') + '/' })

            if ([bool]$node.SubtreeFullyScanned) {
                $directoryDetail = ('{0} files below' -f $node.TotalFiles)
            }
            elseif ([bool]$node.ChildrenLoaded) {
                $directoryDetail = ('{0} files discovered so far; deeper subtree not fully scanned' -f $node.TotalFiles)
            }
            else {
                $directoryDetail = 'subtree not scanned'
            }

            Append-LineSafe -StringBuilder $sb -Text ('- [dir] `{0}` - {1}' -f $displayPath, $directoryDetail)
            continue
        }

        $contentState = $(if (Test-FileContentSelectedForExport -FileNode $node) { 'content included' } else { 'metadata only' })
        Append-LineSafe -StringBuilder $sb -Text ('- [file] `{0}` - {1} - {2}' -f $node.RelPath, (Get-FileTypeDescription -FileNode $node), $contentState)
    }

    Append-LineSafe -StringBuilder $sb
    Append-LineSafe -StringBuilder $sb -Text '---'

    foreach ($file in $fileNodes) {
        Append-LineSafe -StringBuilder $sb
        Append-LineSafe -StringBuilder $sb -Text ('## File: `{0}`' -f $file.RelPath)
        Append-LineSafe -StringBuilder $sb
        Append-LineSafe -StringBuilder $sb -Text ('- File name: `{0}`' -f $file.Name)
        Append-LineSafe -StringBuilder $sb -Text ('- File path: `{0}`' -f $file.RelPath)
        Append-LineSafe -StringBuilder $sb -Text ('- File type: {0}' -f (Get-FileTypeDescription -FileNode $file))

        $includeContent = Test-FileContentSelectedForExport -FileNode $file
        Append-LineSafe -StringBuilder $sb -Text ('- Content: {0}' -f $(if ($includeContent) { 'included' } else { 'not included' }))
        Append-LineSafe -StringBuilder $sb

        if (-not $includeContent) {
            continue
        }

        $language = Get-LanguageForNode -FileNode $file
        Append-LineSafe -StringBuilder $sb -Text ($script:Fence + $language)

        try {
            $jsonHandled = $false
            if ($file.Extension -eq '.json') {
                $jsonHandled = [bool](Append-FilteredJsonToMarkdown -StringBuilder $sb -FileNode $file -IncludeLineNumbers $IncludeLineNumbers)
                if (-not $jsonHandled) {
                    Append-FileLinesToMarkdown -StringBuilder $sb -Path $file.FullPath -IncludeLineNumbers $IncludeLineNumbers
                    $jsonHandled = $true
                }
            }

            if (-not $jsonHandled) {
                $lines = [System.IO.File]::ReadAllLines($file.FullPath)
                if ($IncludeLineNumbers) {
                    $width = [Math]::Max(1, $lines.Length.ToString().Length)
                    for ($i = 0; $i -lt $lines.Length; $i++) {
                        $lineNo = ($i + 1).ToString().PadLeft($width)
                        Append-LineSafe -StringBuilder $sb -Text ($lineNo + ' | ' + $lines[$i])
                    }
                }
                else {
                    foreach ($line in $lines) {
                        Append-LineSafe -StringBuilder $sb -Text $line
                    }
                }
            }
        }
        catch {
            Append-LineSafe -StringBuilder $sb -Text ('[File could not be read: {0}]' -f $_.Exception.Message)
        }

        Append-LineSafe -StringBuilder $sb -Text $script:Fence
        Append-LineSafe -StringBuilder $sb
    }

    return $sb.ToString()
}

function Set-ClipboardTextReliable {
    param([Parameter(Mandatory = $true)][string]$Text)

    $lastError = $null
    for ($attempt = 1; $attempt -le 6; $attempt++) {
        try {
            [System.Windows.Clipboard]::SetText($Text)
            return $true
        }
        catch {
            $lastError = $_
            Start-Sleep -Milliseconds 150
        }
    }

    try {
        Set-Clipboard -Value $Text
        return $true
    }
    catch {
        if ($lastError -ne $null) {
            throw $lastError
        }
        throw
    }
}

function Copy-SelectedContextToClipboard {
    param([Parameter(Mandatory = $true)][bool]$IncludeLineNumbers)

    $selectedNodes = @(Get-SelectedExportNodes)
    if ($selectedNodes.Count -eq 0) {
        [System.Windows.MessageBox]::Show($script:Window, 'No project entry is selected for copy.', 'Source Context Exporter', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
        return $false
    }

    $markdown = New-SourceContextMarkdown -Nodes $selectedNodes -IncludeLineNumbers $IncludeLineNumbers
    [void](Set-ClipboardTextReliable -Text $markdown)

    [System.Windows.MessageBox]::Show($script:Window, ('Copied {0} selected project entries to the clipboard.' -f $selectedNodes.Count), 'Source Context Exporter', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
    return $true
}

function Collect-ExpandedPaths {
    param(
        [Parameter(Mandatory = $true)][object]$Node,
        [Parameter(Mandatory = $true)][hashtable]$Expanded
    )

    if ($Node.UiItem -eq $null) { return }

    if ($Node.UiItem.IsExpanded) {
        $Expanded[$Node.FullPath] = $true
    }

    if (
        -not $Node.IsDirectory -or
        -not [bool]$Node.UiChildrenMaterialized
    ) {
        return
    }

    foreach ($child in $Node.Children) {
        if ($child.IsDirectory -and $child.UiItem -ne $null) {
            Collect-ExpandedPaths -Node $child -Expanded $Expanded
        }
    }
}

function Restore-ExpandedPaths {
    param(
        [Parameter(Mandatory = $true)][object]$Node,
        [Parameter(Mandatory = $true)][hashtable]$Expanded
    )

    if ($Node.UiItem -eq $null) { return }

    $shouldExpand = (
        $Node.Parent -eq $null -or
        $Expanded.ContainsKey($Node.FullPath)
    )

    if (-not $shouldExpand) { return }

    if ($Node.IsDirectory -and -not [bool]$Node.UiChildrenMaterialized) {
        Populate-ProjectTreeItemChildren -Item $Node.UiItem -Node $Node
    }

    $Node.UiItem.IsExpanded = $true

    if (-not $Node.IsDirectory) { return }

    foreach ($child in $Node.Children) {
        if (
            $child.IsDirectory -and
            $child.UiItem -ne $null -and
            $Expanded.ContainsKey($child.FullPath)
        ) {
            Restore-ExpandedPaths -Node $child -Expanded $Expanded
        }
    }
}

function Append-FileLinesToMarkdown {
    param(
        [Parameter(Mandatory = $true)][System.Text.StringBuilder]$StringBuilder,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][bool]$IncludeLineNumbers
    )

    if ($IncludeLineNumbers) {
        $lineCount = 0
        foreach ($line in [System.IO.File]::ReadLines($Path)) {
            $lineCount++
        }

        $width = [Math]::Max(1, $lineCount.ToString().Length)
        $lineNumber = 0
        foreach ($line in [System.IO.File]::ReadLines($Path)) {
            $lineNumber++
            Append-LineSafe -StringBuilder $StringBuilder -Text ($lineNumber.ToString().PadLeft($width) + ' | ' + $line)
        }
    }
    else {
        foreach ($line in [System.IO.File]::ReadLines($Path)) {
            Append-LineSafe -StringBuilder $StringBuilder -Text $line
        }
    }
}

function Get-ActiveJsonRules {
    param([Parameter(Mandatory = $true)][object]$FileNode)

    $rules = New-Object System.Collections.ArrayList

    foreach ($rule in $script:GlobalJsonRules) {
        if ($rule.Enabled) {
            [void]$rules.Add($rule)
        }
    }

    foreach ($rule in $FileNode.JsonLocalRules) {
        if ($rule.Enabled) {
            [void]$rules.Add($rule)
        }
    }

    return @($rules)
}

function Get-EffectiveJsonRemoveEmptyArrays {
    param([Parameter(Mandatory = $true)][object]$FileNode)

    return ([bool]$script:GlobalJsonRemoveEmptyArrays -or [bool]$FileNode.JsonRemoveEmptyArrays)
}

function Append-FilteredJsonToMarkdown {
    param(
        [Parameter(Mandatory = $true)][System.Text.StringBuilder]$StringBuilder,
        [Parameter(Mandatory = $true)][object]$FileNode,
        [Parameter(Mandatory = $true)][bool]$IncludeLineNumbers
    )

    $rules = [SourceContext.JsonFilterRule[]]@(Get-ActiveJsonRules -FileNode $FileNode)
    $removeEmptyArrays = Get-EffectiveJsonRemoveEmptyArrays -FileNode $FileNode

    if ($rules.Count -eq 0 -and -not $removeEmptyArrays) {
        return $false
    }

    $tempPath = [System.IO.Path]::GetTempFileName()
    try {
        [SourceContext.JsonStreamingHelper]::WriteFilteredFile(
            $FileNode.FullPath,
            $tempPath,
            $rules,
            $removeEmptyArrays
        )
        Append-FileLinesToMarkdown -StringBuilder $StringBuilder -Path $tempPath -IncludeLineNumbers $IncludeLineNumbers
    }
    finally {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
    }

    return $true
}

function New-JsonFieldCondition {
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][bool]$MatchValue,
        [string]$ValueType = $null,
        [string]$ValueText = $null,
        [string]$ValueHash = $null
    )

    $condition = New-Object SourceContext.JsonFieldCondition
    $condition.Key = $Key
    $condition.MatchValue = $MatchValue
    $condition.ValueType = $ValueType
    $condition.ValueText = $ValueText
    $condition.ValueHash = $ValueHash
    return $condition
}

function New-JsonRule {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Local', 'Global')][string]$Scope,
        [Parameter(Mandatory = $true)][ValidateSet('Include', 'Exclude')][string]$Action,
        [Parameter(Mandatory = $true)][ValidateSet('Exact', 'Structural', 'Anywhere')][string]$PathMode,
        [AllowEmptyString()][string]$Selector = '',
        [string]$NodeName = $null,
        [SourceContext.JsonFieldCondition[]]$Conditions = @()
    )

    $rule = New-Object SourceContext.JsonFilterRule
    $rule.Id = [Guid]::NewGuid().ToString('N')
    $rule.Scope = $Scope
    $rule.Action = $Action
    $rule.PathMode = $PathMode
    $rule.Selector = $Selector
    $rule.NodeName = $NodeName
    $rule.Conditions = $Conditions
    $rule.Enabled = $true
    return $rule
}

function ConvertTo-JsonRuleSignaturePart {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) {
        return '-1:'
    }

    return ('{0}:{1}' -f $Value.Length, $Value)
}

function Get-JsonRuleSignature {
    param([Parameter(Mandatory = $true)][SourceContext.JsonFilterRule]$Rule)

    $parts = New-Object System.Collections.ArrayList
    [void]$parts.Add((ConvertTo-JsonRuleSignaturePart -Value $Rule.PathMode))
    [void]$parts.Add((ConvertTo-JsonRuleSignaturePart -Value $Rule.Selector))
    [void]$parts.Add((ConvertTo-JsonRuleSignaturePart -Value $Rule.NodeName))

    $conditions = @($Rule.Conditions | Sort-Object -Property Key, MatchValue, ValueType, ValueText, ValueHash)
    foreach ($condition in $conditions) {
        [void]$parts.Add((ConvertTo-JsonRuleSignaturePart -Value $condition.Key))
        [void]$parts.Add($(if ($condition.MatchValue) { 'V' } else { 'K' }))
        [void]$parts.Add((ConvertTo-JsonRuleSignaturePart -Value $condition.ValueType))
        [void]$parts.Add((ConvertTo-JsonRuleSignaturePart -Value $condition.ValueText))
        [void]$parts.Add((ConvertTo-JsonRuleSignaturePart -Value $condition.ValueHash))
    }

    return ($parts -join '|')
}

function Add-OrReplaceJsonRule {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IList]$Collection,
        [Parameter(Mandatory = $true)][SourceContext.JsonFilterRule]$Rule
    )

    $signature = Get-JsonRuleSignature -Rule $Rule
    for ($i = $Collection.Count - 1; $i -ge 0; $i--) {
        $existing = $Collection[$i]
        if ((Get-JsonRuleSignature -Rule $existing) -eq $signature) {
            $Collection.RemoveAt($i)
        }
    }

    [void]$Collection.Add($Rule)
    return $Rule
}

function Remove-JsonRuleById {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IList]$Collection,
        [Parameter(Mandatory = $true)][string]$Id
    )

    for ($i = $Collection.Count - 1; $i -ge 0; $i--) {
        if ($Collection[$i].Id -eq $Id) {
            $Collection.RemoveAt($i)
        }
    }
}

function Remove-LocalExactPathJsonRule {
    param(
        [Parameter(Mandatory = $true)][object]$FileNode,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Selector
    )

    for ($i = $FileNode.JsonLocalRules.Count - 1; $i -ge 0; $i--) {
        $rule = $FileNode.JsonLocalRules[$i]
        if (
            $rule.PathMode -eq 'Exact' -and
            [string]::IsNullOrEmpty($rule.NodeName) -and
            @($rule.Conditions).Count -eq 0 -and
            [string]::Equals([string]$rule.Selector, $Selector, [System.StringComparison]::Ordinal)
        ) {
            $FileNode.JsonLocalRules.RemoveAt($i)
        }
    }
}

function Format-JsonSelectorForDisplay {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Selector)

    if ([string]::IsNullOrEmpty($Selector)) {
        return '$'
    }
    return $Selector
}

function Format-JsonConditionForDisplay {
    param([Parameter(Mandatory = $true)][SourceContext.JsonFieldCondition]$Condition)

    if (-not $Condition.MatchValue) {
        return ('has key "{0}"' -f $Condition.Key)
    }

    $valueText = [string]$Condition.ValueText
    if ($Condition.ValueType -eq 'string') {
        $valueText = '"' + $valueText.Replace('"', '\"') + '"'
    }

    if ($valueText.Length -gt 80) {
        $valueText = $valueText.Substring(0, 80) + '...'
    }

    return ('{0} = {1}' -f $Condition.Key, $valueText)
}

function Get-JsonRuleDescription {
    param([Parameter(Mandatory = $true)][SourceContext.JsonFilterRule]$Rule)

    $actionText = $Rule.Action.ToUpperInvariant()
    $scopeText = $Rule.Scope.ToLowerInvariant()

    if ($Rule.PathMode -eq 'Exact') {
        return ('{0} [{1}] exact path {2}' -f $actionText, $scopeText, (Format-JsonSelectorForDisplay -Selector $Rule.Selector))
    }

    $conditionParts = New-Object System.Collections.ArrayList

    if (-not [string]::IsNullOrEmpty($Rule.NodeName)) {
        [void]$conditionParts.Add(('node name "{0}"' -f $Rule.NodeName))
    }

    foreach ($condition in @($Rule.Conditions)) {
        [void]$conditionParts.Add((Format-JsonConditionForDisplay -Condition $condition))
    }

    if ($Rule.PathMode -eq 'Structural') {
        $base = ('{0} [{1}] structural path {2}' -f $actionText, $scopeText, (Format-JsonSelectorForDisplay -Selector $Rule.Selector))
        if ($conditionParts.Count -gt 0) {
            $base += ' where ' + ($conditionParts -join ', ')
        }
        return $base
    }

    $description = ('{0} [{1}] anywhere' -f $actionText, $scopeText)
    if ($conditionParts.Count -gt 0) {
        $description += ' where ' + ($conditionParts -join ', ')
    }
    return $description
}

function Get-JsonRuleCollectionForScope {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][ValidateSet('Local', 'Global')][string]$Scope
    )

    if ($Scope -eq 'Local') {
        return $State.FileNode.JsonLocalRules
    }
    return $script:GlobalJsonRules
}

function Update-JsonVisibleNodeStates {
    param([Parameter(Mandatory = $true)][object]$State)

    $rules = [SourceContext.JsonFilterRule[]]@(Get-ActiveJsonRules -FileNode $State.FileNode)

    function Update-JsonVisibleNodeStateRecursive {
        param(
            [Parameter(Mandatory = $true)][System.Windows.Controls.TreeViewItem]$Item,
            [Parameter(Mandatory = $true)][bool]$ParentIncluded
        )

        $data = $Item.Tag
        $effective = $ParentIncluded

        if ($data -ne $null -and $data.Kind -eq 'JsonNode') {
            try {
                $effective = [SourceContext.JsonStreamingHelper]::EvaluateNodeIncluded(
                    $data.State.FileNode.FullPath,
                    $data.Info,
                    $rules,
                    $ParentIncluded
                )
            }
            catch {
                $effective = $ParentIncluded
            }

            $data.ParentEffectiveIncluded = $ParentIncluded
            $data.EffectiveIncluded = $effective
            $data.CheckBox.IsChecked = $effective
        }

        foreach ($child in $Item.Items) {
            if ($child -is [System.Windows.Controls.TreeViewItem]) {
                $childData = $child.Tag
                if ($childData -ne $null -and $childData.Kind -eq 'JsonNode') {
                    Update-JsonVisibleNodeStateRecursive -Item $child -ParentIncluded $effective
                }
            }
        }
    }

    foreach ($rootItem in $State.Tree.Items) {
        if ($rootItem -is [System.Windows.Controls.TreeViewItem]) {
            Update-JsonVisibleNodeStateRecursive -Item $rootItem -ParentIncluded $true
        }
    }
}

function Update-JsonPreview {
    param([Parameter(Mandatory = $true)][object]$State)

    if ($State.PreviewTextBox -eq $null) {
        return
    }

    $nodeData = $State.SelectedNodeData
    if ($null -eq $nodeData -or $nodeData.Kind -ne 'JsonNode') {
        $State.PreviewTextBox.Text = 'Select a JSON node to preview the filtered result.'
        if ($State.PreviewStatusText -ne $null) {
            $State.PreviewStatusText.Text = ''
        }
        return
    }

    $rules = [SourceContext.JsonFilterRule[]]@(Get-ActiveJsonRules -FileNode $State.FileNode)
    $removeEmptyArrays = Get-EffectiveJsonRemoveEmptyArrays -FileNode $State.FileNode
    $tempPath = [System.IO.Path]::GetTempFileName()

    try {
        $preview = [SourceContext.JsonStreamingHelper]::WriteFilteredSubtreePreview(
            $State.FileNode.FullPath,
            $tempPath,
            $nodeData.Info,
            $rules,
            $removeEmptyArrays,
            [bool]$nodeData.ParentEffectiveIncluded,
            [Int64]262144
        )

        if (-not $preview.Kept) {
            $State.PreviewTextBox.Text = '[This node is excluded by the active rules.]'
            if ($State.PreviewStatusText -ne $null) {
                $State.PreviewStatusText.Text = 'Excluded'
            }
            return
        }

        $text = [System.IO.File]::ReadAllText($tempPath)
        if ($preview.Truncated) {
            $text += "`r`n`r`n[Preview truncated after 256 KB.]"
        }

        $State.PreviewTextBox.Text = $text
        if ($State.PreviewStatusText -ne $null) {
            $State.PreviewStatusText.Text = $(if ($preview.Truncated) { 'Preview truncated at 256 KB' } else { 'Filtered preview' })
        }
    }
    catch {
        $State.PreviewTextBox.Text = ('[Preview could not be generated: {0}]' -f $_.Exception.Message)
        if ($State.PreviewStatusText -ne $null) {
            $State.PreviewStatusText.Text = 'Preview error'
        }
    }
    finally {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
    }
}

function New-JsonRuleRow {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][SourceContext.JsonFilterRule]$Rule,
        [Parameter(Mandatory = $true)][System.Collections.IList]$Collection
    )

    $grid = New-Object System.Windows.Controls.Grid
    $grid.Margin = New-Object System.Windows.Thickness -ArgumentList 0, 0, 0, 6

    $column0 = New-Object System.Windows.Controls.ColumnDefinition
    $column0.Width = [System.Windows.GridLength]::Auto
    $column1 = New-Object System.Windows.Controls.ColumnDefinition
    $column1.Width = New-Object System.Windows.GridLength -ArgumentList 1, ([System.Windows.GridUnitType]::Star)
    $column2 = New-Object System.Windows.Controls.ColumnDefinition
    $column2.Width = [System.Windows.GridLength]::Auto
    [void]$grid.ColumnDefinitions.Add($column0)
    [void]$grid.ColumnDefinitions.Add($column1)
    [void]$grid.ColumnDefinitions.Add($column2)

    $enabledCheckBox = New-Object System.Windows.Controls.CheckBox
    $enabledCheckBox.IsChecked = [bool]$Rule.Enabled
    $enabledCheckBox.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $enabledCheckBox.Margin = New-Object System.Windows.Thickness -ArgumentList 0, 0, 8, 0
    $enabledCheckBox.ToolTip = 'Enable or disable this rule without deleting it.'
    $enabledCheckBox.Tag = [pscustomobject]@{
        State = $State
        Rule  = $Rule
    }
    [System.Windows.Controls.Grid]::SetColumn($enabledCheckBox, 0)
    $enabledCheckBox.Add_Click({
        param($sender, $eventArgs)
        $tag = $sender.Tag
        $tag.Rule.Enabled = ($sender.IsChecked -eq $true)
        Update-JsonVisibleNodeStates -State $tag.State
        Update-JsonPreview -State $tag.State
    })

    $text = New-Object System.Windows.Controls.TextBlock
    $text.Text = Get-JsonRuleDescription -Rule $Rule
    $text.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $text.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $text.ToolTip = 'Priority is deterministic: a rule on the current node overrides inherited state; local rules outrank global rules, then exact path, structural path, and anywhere rules; stronger field conditions win next; Include wins an exact tie.'
    [System.Windows.Controls.Grid]::SetColumn($text, 1)

    $removeButton = New-Object System.Windows.Controls.Button
    $removeButton.Content = 'Remove'
    $removeButton.Padding = New-Object System.Windows.Thickness -ArgumentList 8, 2, 8, 2
    $removeButton.Margin = New-Object System.Windows.Thickness -ArgumentList 8, 0, 0, 0
    $removeButton.Tag = [pscustomobject]@{
        State      = $State
        Collection = $Collection
        RuleId     = $Rule.Id
    }
    [System.Windows.Controls.Grid]::SetColumn($removeButton, 2)
    $removeButton.Add_Click({
        param($sender, $eventArgs)
        $tag = $sender.Tag
        Remove-JsonRuleById -Collection $tag.Collection -Id $tag.RuleId
        Update-JsonRulePanels -State $tag.State
        Update-JsonVisibleNodeStates -State $tag.State
        Update-JsonPreview -State $tag.State
    })

    [void]$grid.Children.Add($enabledCheckBox)
    [void]$grid.Children.Add($text)
    [void]$grid.Children.Add($removeButton)
    return $grid
}

function Update-JsonRulePanels {
    param([Parameter(Mandatory = $true)][object]$State)

    $State.LocalRulesPanel.Children.Clear()
    $State.GlobalRulesPanel.Children.Clear()

    if ($State.FileNode.JsonLocalRules.Count -eq 0) {
        Add-EmptyExtensionPanelText -Panel $State.LocalRulesPanel -Text 'No local JSON rules.'
    }
    else {
        foreach ($rule in $State.FileNode.JsonLocalRules) {
            [void]$State.LocalRulesPanel.Children.Add(
                (New-JsonRuleRow -State $State -Rule $rule -Collection $State.FileNode.JsonLocalRules)
            )
        }
    }

    if ($script:GlobalJsonRules.Count -eq 0) {
        Add-EmptyExtensionPanelText -Panel $State.GlobalRulesPanel -Text 'No global JSON rules.'
    }
    else {
        foreach ($rule in $script:GlobalJsonRules) {
            [void]$State.GlobalRulesPanel.Children.Add(
                (New-JsonRuleRow -State $State -Rule $rule -Collection $script:GlobalJsonRules)
            )
        }
    }

    if ($State.LocalRemoveEmptyArraysCheckBox -ne $null) {
        $State.LocalRemoveEmptyArraysCheckBox.IsChecked = [bool]$State.FileNode.JsonRemoveEmptyArrays
    }
    if ($State.GlobalRemoveEmptyArraysCheckBox -ne $null) {
        $State.GlobalRemoveEmptyArraysCheckBox.IsChecked = [bool]$script:GlobalJsonRemoveEmptyArrays
    }
}

function Get-JsonParentObjectInfo {
    param([Parameter(Mandatory = $true)][object]$NodeData)

    $info = $NodeData.Info
    if ($info.ParentNodeType -ne 'object' -or $info.ParentStartOffset -lt 0) {
        return $null
    }

    $parent = New-Object SourceContext.JsonNodeInfo
    $parent.Name = $(if ([string]::IsNullOrEmpty($info.ParentKeyName)) { '(parent object)' } else { $info.ParentKeyName })
    $parent.KeyName = $info.ParentKeyName
    $parent.ExactPointer = $(if ($null -eq $info.ParentExactPointer) { '' } else { $info.ParentExactPointer })
    $parent.StructuralPointer = $(if ($null -eq $info.ParentStructuralPointer) { '' } else { $info.ParentStructuralPointer })
    $parent.StartOffset = [Int64]$info.ParentStartOffset
    $parent.EndOffset = -1
    $parent.NodeType = 'object'
    $parent.HasChildren = $true
    $parent.Preview = '{...}'
    $parent.ParentStartOffset = -1
    return $parent
}

function Get-JsonObjectRuleTargetInfo {
    param([Parameter(Mandatory = $true)][object]$NodeData)

    if ($NodeData.Info.NodeType -eq 'object') {
        return $NodeData.Info
    }

    return Get-JsonParentObjectInfo -NodeData $NodeData
}

function New-JsonFieldRuleEditorRow {
    param(
        [Parameter(Mandatory = $true)][object]$Field,
        [string]$PreselectKey = $null
    )

    $grid = New-Object System.Windows.Controls.Grid
    $grid.Margin = New-Object System.Windows.Thickness -ArgumentList 0, 0, 0, 5

    $c0 = New-Object System.Windows.Controls.ColumnDefinition
    $c0.Width = [System.Windows.GridLength]::Auto
    $c1 = New-Object System.Windows.Controls.ColumnDefinition
    $c1.Width = New-Object System.Windows.GridLength -ArgumentList 220
    $c2 = New-Object System.Windows.Controls.ColumnDefinition
    $c2.Width = New-Object System.Windows.GridLength -ArgumentList 140
    $c3 = New-Object System.Windows.Controls.ColumnDefinition
    $c3.Width = New-Object System.Windows.GridLength -ArgumentList 1, ([System.Windows.GridUnitType]::Star)
    [void]$grid.ColumnDefinitions.Add($c0)
    [void]$grid.ColumnDefinitions.Add($c1)
    [void]$grid.ColumnDefinitions.Add($c2)
    [void]$grid.ColumnDefinitions.Add($c3)

    $use = New-Object System.Windows.Controls.CheckBox
    $use.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $use.Margin = New-Object System.Windows.Thickness -ArgumentList 0, 0, 8, 0
    [System.Windows.Controls.Grid]::SetColumn($use, 0)

    $keyText = New-Object System.Windows.Controls.TextBlock
    $keyText.Text = $Field.Key
    $keyText.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $keyText.TextWrapping = [System.Windows.TextWrapping]::Wrap
    [System.Windows.Controls.Grid]::SetColumn($keyText, 1)

    $mode = New-Object System.Windows.Controls.ComboBox
    $mode.Margin = New-Object System.Windows.Thickness -ArgumentList 6, 0, 6, 0
    [void]$mode.Items.Add('Key exists')
    if ($Field.CanMatchValue) {
        [void]$mode.Items.Add('Key + value')
    }
    $mode.SelectedIndex = 0
    [System.Windows.Controls.Grid]::SetColumn($mode, 2)

    $preview = New-Object System.Windows.Controls.TextBlock
    $preview.Text = ('{0} | {1}' -f $Field.NodeType, $Field.Preview)
    $preview.Foreground = $script:MutedBrush
    $preview.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $preview.TextWrapping = [System.Windows.TextWrapping]::Wrap
    [System.Windows.Controls.Grid]::SetColumn($preview, 3)

    if (-not [string]::IsNullOrEmpty($PreselectKey) -and [string]::Equals($Field.Key, $PreselectKey, [System.StringComparison]::Ordinal)) {
        $use.IsChecked = $true
        if ($Field.CanMatchValue -and $mode.Items.Count -gt 1) {
            $mode.SelectedIndex = 1
        }
    }

    [void]$grid.Children.Add($use)
    [void]$grid.Children.Add($keyText)
    [void]$grid.Children.Add($mode)
    [void]$grid.Children.Add($preview)

    return [pscustomobject]@{
        Grid        = $grid
        Field       = $Field
        UseCheckBox = $use
        ModeCombo   = $mode
    }
}

function Show-JsonRuleEditor {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][object]$NodeData,
        [Parameter(Mandatory = $true)][ValidateSet('Local', 'Global')][string]$Scope
    )

    $objectTarget = Get-JsonObjectRuleTargetInfo -NodeData $NodeData
    $preselectKey = $null
    if (
        $NodeData.Info.ParentNodeType -eq 'object' -and
        -not [string]::IsNullOrEmpty($NodeData.Info.KeyName)
    ) {
        $preselectKey = $NodeData.Info.KeyName
    }

    $ruleEditorXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Create JSON rule"
        Width="860" Height="720" MinWidth="720" MinHeight="560"
        WindowStartupLocation="CenterOwner"
        Background="#F7F8FC"
        FontFamily="Segoe UI"
        ResizeMode="CanResizeWithGrip">
    <Grid Margin="14">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto" />
            <RowDefinition Height="Auto" />
            <RowDefinition Height="Auto" />
            <RowDefinition Height="*" />
            <RowDefinition Height="Auto" />
        </Grid.RowDefinitions>

        <Border Grid.Row="0" Background="White" CornerRadius="10" Padding="12" Margin="0,0,0,10" BorderBrush="#EAECF0" BorderThickness="1">
            <StackPanel>
                <TextBlock Name="RuleEditorTitleText" FontSize="19" FontWeight="SemiBold" Foreground="#111827" />
                <TextBlock Name="RuleEditorPathText" Margin="0,5,0,0" Foreground="#475467" TextWrapping="Wrap" />
            </StackPanel>
        </Border>

        <Grid Grid.Row="1" Margin="0,0,0,10">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto" />
                <ColumnDefinition Width="180" />
                <ColumnDefinition Width="20" />
                <ColumnDefinition Width="Auto" />
                <ColumnDefinition Width="*" />
            </Grid.ColumnDefinitions>

            <TextBlock Grid.Column="0" Text="Action:" VerticalAlignment="Center" Margin="0,0,8,0" />
            <ComboBox Name="RuleActionCombo" Grid.Column="1" MinHeight="28" />
            <TextBlock Grid.Column="3" Text="Match:" VerticalAlignment="Center" Margin="0,0,8,0" />
            <ComboBox Name="RuleMatchCombo" Grid.Column="4" MinHeight="28" />
        </Grid>

        <Border Grid.Row="2" Background="White" CornerRadius="8" Padding="10" Margin="0,0,0,10" BorderBrush="#EAECF0" BorderThickness="1">
            <StackPanel>
                <CheckBox Name="RequireNodeNameCheckBox" Margin="0,0,0,5" />
                <TextBlock Name="ObjectTargetText" Foreground="#667085" TextWrapping="Wrap" />
            </StackPanel>
        </Border>

        <GroupBox Grid.Row="3" Header="Object field conditions" Background="White" BorderBrush="#EAECF0" Padding="8" Margin="0,0,0,10">
            <DockPanel>
                <TextBlock Name="FieldHelpText" DockPanel.Dock="Top" Margin="0,0,0,8" Foreground="#667085" TextWrapping="Wrap"
                           Text="For object rules, select fields to require. 'Key exists' ignores the current value; 'Key + value' compares the concrete scalar value. Conditions are combined with AND." />
                <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                    <StackPanel Name="RuleFieldsPanel" />
                </ScrollViewer>
            </DockPanel>
        </GroupBox>

        <Grid Grid.Row="4">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*" />
                <ColumnDefinition Width="Auto" />
                <ColumnDefinition Width="Auto" />
            </Grid.ColumnDefinitions>
            <TextBlock Name="RuleValidationText" Grid.Column="0" Foreground="#B42318" VerticalAlignment="Center" TextWrapping="Wrap" Margin="0,0,12,0" />
            <Button Name="CancelRuleButton" Grid.Column="1" Content="Cancel" MinWidth="100" Padding="12,7" Margin="0,0,8,0" IsCancel="True" />
            <Button Name="CreateRuleButton" Grid.Column="2" Content="Create rule" MinWidth="120" Padding="12,7" IsDefault="True" />
        </Grid>
    </Grid>
</Window>
"@

    [xml]$ruleEditorXml = $ruleEditorXaml
    $reader = New-Object System.Xml.XmlNodeReader $ruleEditorXml
    $window = [Windows.Markup.XamlReader]::Load($reader)
    $window.Owner = $State.Window

    $titleText = $window.FindName('RuleEditorTitleText')
    $pathText = $window.FindName('RuleEditorPathText')
    $actionCombo = $window.FindName('RuleActionCombo')
    $matchCombo = $window.FindName('RuleMatchCombo')
    $requireNodeName = $window.FindName('RequireNodeNameCheckBox')
    $objectTargetText = $window.FindName('ObjectTargetText')
    $fieldsPanel = $window.FindName('RuleFieldsPanel')
    $fieldHelpText = $window.FindName('FieldHelpText')
    $validationText = $window.FindName('RuleValidationText')
    $cancelButton = $window.FindName('CancelRuleButton')
    $createButton = $window.FindName('CreateRuleButton')

    $titleText.Text = ('Create {0} JSON rule' -f $Scope.ToLowerInvariant())
    $pathText.Text = ('Selected node: {0} | exact: {1} | structural: {2}' -f $NodeData.Info.Name, (Format-JsonSelectorForDisplay -Selector $NodeData.Info.ExactPointer), (Format-JsonSelectorForDisplay -Selector $NodeData.Info.StructuralPointer))

    [void]$actionCombo.Items.Add('Exclude')
    [void]$actionCombo.Items.Add('Include')
    $actionCombo.SelectedIndex = 0

    [void]$matchCombo.Items.Add('Exact path of selected node')
    [void]$matchCombo.Items.Add('Structural path of selected node (array indexes = *)')

    $fieldRows = New-Object System.Collections.ArrayList
    $fieldListTruncated = $false

    if ($objectTarget -ne $null) {
        [void]$matchCombo.Items.Add('Object at structural position + field conditions')
        [void]$matchCombo.Items.Add('Matching object anywhere + field conditions')

        $requireNodeName.IsEnabled = (-not [string]::IsNullOrEmpty($objectTarget.KeyName))
        if ($requireNodeName.IsEnabled) {
            $requireNodeName.Content = ('Require node name "{0}"' -f $objectTarget.KeyName)
            $requireNodeName.IsChecked = $true
        }
        else {
            $requireNodeName.Content = 'Object has no property name at this position (for example, it may be an array item).'
            $requireNodeName.IsChecked = $false
        }

        $objectTargetText.Text = ('Object matcher target: {0}' -f (Format-JsonSelectorForDisplay -Selector $objectTarget.ExactPointer))

        try {
            $fieldList = [SourceContext.JsonStreamingHelper]::GetObjectFields($State.FileNode.FullPath, [Int64]$objectTarget.StartOffset, 250)
            $fieldListTruncated = [bool]$fieldList.Truncated
            foreach ($field in $fieldList.Fields) {
                $row = New-JsonFieldRuleEditorRow -Field $field -PreselectKey $preselectKey
                [void]$fieldRows.Add($row)
                [void]$fieldsPanel.Children.Add($row.Grid)
            }

            if ($fieldList.Truncated) {
                $note = New-Object System.Windows.Controls.TextBlock
                $note.Text = 'Only the first 250 immediate fields are shown to keep this dialog responsive.'
                $note.Foreground = $script:MutedBrush
                $note.Margin = New-Object System.Windows.Thickness -ArgumentList 0, 5, 0, 0
                [void]$fieldsPanel.Children.Add($note)
            }
        }
        catch {
            $note = New-Object System.Windows.Controls.TextBlock
            $note.Text = ('Object fields could not be loaded: {0}' -f $_.Exception.Message)
            $note.Foreground = $script:ErrorBrush
            $note.TextWrapping = [System.Windows.TextWrapping]::Wrap
            [void]$fieldsPanel.Children.Add($note)
        }
    }
    else {
        $requireNodeName.Content = 'Content matching is available for object nodes or fields whose parent is an object.'
        $requireNodeName.IsEnabled = $false
        $objectTargetText.Text = 'No object target is available for this node.'
        $fieldHelpText.Text = 'Select an object node, or a field directly inside an object, to create structure/value rules.'
    }

    $matchCombo.SelectedIndex = 1

    $editorState = [pscustomobject]@{
        ParentState          = $State
        NodeData             = $NodeData
        Scope                = $Scope
        ObjectTarget         = $objectTarget
        ActionCombo          = $actionCombo
        MatchCombo           = $matchCombo
        RequireNodeName      = $requireNodeName
        FieldRows            = $fieldRows
        ValidationText       = $validationText
        Window               = $window
        FieldListTruncated   = $fieldListTruncated
    }
    $window.Tag = $editorState

    $matchCombo.Tag = $editorState
    $matchCombo.Add_SelectionChanged({
        param($sender, $eventArgs)
        $editor = $sender.Tag
        $objectMode = ($sender.SelectedIndex -ge 2)

        $editor.RequireNodeName.IsEnabled = (
            $objectMode -and
            $editor.ObjectTarget -ne $null -and
            -not [string]::IsNullOrEmpty($editor.ObjectTarget.KeyName)
        )

        foreach ($row in $editor.FieldRows) {
            $row.UseCheckBox.IsEnabled = $objectMode
            $row.ModeCombo.IsEnabled = $objectMode
        }
    })

    $cancelButton.Tag = $window
    $cancelButton.Add_Click({
        param($sender, $eventArgs)
        $sender.Tag.Close()
    })

    $createButton.Tag = $editorState
    $createButton.Add_Click({
        param($sender, $eventArgs)
        $editor = $sender.Tag
        $editor.ValidationText.Text = ''

        $action = [string]$editor.ActionCombo.SelectedItem
        $modeIndex = $editor.MatchCombo.SelectedIndex
        $pathMode = $null
        $selector = ''
        $nodeName = $null
        $conditions = New-Object System.Collections.ArrayList

        if ($modeIndex -eq 0) {
            $pathMode = 'Exact'
            $selector = [string]$editor.NodeData.Info.ExactPointer
        }
        elseif ($modeIndex -eq 1) {
            $pathMode = 'Structural'
            $selector = [string]$editor.NodeData.Info.StructuralPointer
        }
        elseif ($modeIndex -eq 2 -or $modeIndex -eq 3) {
            if ($editor.ObjectTarget -eq $null) {
                $editor.ValidationText.Text = 'This node does not provide an object that can be matched by fields.'
                return
            }

            if ($modeIndex -eq 2) {
                $pathMode = 'Structural'
                $selector = [string]$editor.ObjectTarget.StructuralPointer
            }
            else {
                $pathMode = 'Anywhere'
                $selector = ''
            }

            if (
                $editor.RequireNodeName.IsChecked -eq $true -and
                -not [string]::IsNullOrEmpty($editor.ObjectTarget.KeyName)
            ) {
                $nodeName = [string]$editor.ObjectTarget.KeyName
            }

            foreach ($row in $editor.FieldRows) {
                if ($row.UseCheckBox.IsChecked -ne $true) {
                    continue
                }

                $matchValue = ($row.ModeCombo.SelectedIndex -eq 1)
                if ($matchValue -and -not $row.Field.CanMatchValue) {
                    $editor.ValidationText.Text = ('Field "{0}" is not a scalar JSON value, so only key existence can be matched.' -f $row.Field.Key)
                    return
                }

                $condition = New-JsonFieldCondition `
                    -Key ([string]$row.Field.Key) `
                    -MatchValue $matchValue `
                    -ValueType $(if ($matchValue) { [string]$row.Field.ValueType } else { $null }) `
                    -ValueText $(if ($matchValue) { [string]$row.Field.ValueText } else { $null }) `
                    -ValueHash $(if ($matchValue) { [string]$row.Field.ValueHash } else { $null })
                [void]$conditions.Add($condition)
            }

            if ($pathMode -eq 'Anywhere' -and [string]::IsNullOrEmpty($nodeName) -and $conditions.Count -eq 0) {
                $editor.ValidationText.Text = 'An anywhere rule needs a node-name constraint, at least one field condition, or both.'
                return
            }
        }
        else {
            $editor.ValidationText.Text = 'Please choose a rule matching mode.'
            return
        }

        $rule = New-JsonRule `
            -Scope $editor.Scope `
            -Action $action `
            -PathMode $pathMode `
            -Selector $selector `
            -NodeName $nodeName `
            -Conditions ([SourceContext.JsonFieldCondition[]]@($conditions))

        $collection = Get-JsonRuleCollectionForScope -State $editor.ParentState -Scope $editor.Scope
        [void](Add-OrReplaceJsonRule -Collection $collection -Rule $rule)

        Update-JsonRulePanels -State $editor.ParentState
        Update-JsonVisibleNodeStates -State $editor.ParentState
        Update-JsonPreview -State $editor.ParentState
        $editor.Window.Close()
    })

    # Ensure the initial enabled state of field controls matches the selected path mode.
    foreach ($row in $fieldRows) {
        $row.UseCheckBox.IsEnabled = $false
        $row.ModeCombo.IsEnabled = $false
    }
    $requireNodeName.IsEnabled = $false

    [void]$window.ShowDialog()
}

function New-JsonRuleIconButton {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][object]$NodeData,
        [Parameter(Mandatory = $true)][ValidateSet('Local', 'Global')][string]$Scope
    )

    $button = New-Object System.Windows.Controls.Button
    $button.Background = [System.Windows.Media.Brushes]::Transparent
    $button.BorderThickness = New-Object System.Windows.Thickness -ArgumentList 0
    $button.Padding = New-Object System.Windows.Thickness -ArgumentList 3, 0, 3, 0
    $button.Margin = New-Object System.Windows.Thickness -ArgumentList 4, 0, 0, 0
    $button.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $button.Cursor = [System.Windows.Input.Cursors]::Hand
    $button.FontSize = 13

    if ($Scope -eq 'Global') {
        $button.Content = [System.Char]::ConvertFromUtf32(0x1F310)
        $button.ToolTip = 'Create a global Include/Exclude rule from this node.'
    }
    else {
        $button.Content = [char]0x25C9
        $button.ToolTip = 'Create a local Include/Exclude rule for this JSON file from this node.'
    }

    $button.Tag = [pscustomobject]@{
        State    = $State
        NodeData = $NodeData
        Scope    = $Scope
    }
    $button.Add_Click({
        param($sender, $eventArgs)
        $tag = $sender.Tag
        Show-JsonRuleEditor -State $tag.State -NodeData $tag.NodeData -Scope $tag.Scope
    })

    return $button
}

function New-JsonNodeHeader {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][object]$NodeData
    )

    $info = $NodeData.Info
    $panel = New-Object System.Windows.Controls.StackPanel
    $panel.Orientation = [System.Windows.Controls.Orientation]::Horizontal

    $checkBox = New-Object System.Windows.Controls.CheckBox
    $checkBox.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $checkBox.Margin = New-Object System.Windows.Thickness -ArgumentList 0, 0, 7, 0
    $checkBox.IsChecked = $true
    $checkBox.ToolTip = 'Toggle the effective export state of this exact node. If an ancestor or broader rule disagrees, an exact local Include/Exclude exception is created automatically.'
    $checkBox.Tag = $NodeData

    $name = New-Object System.Windows.Controls.TextBlock
    $name.Text = $info.Name
    $name.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $name.FontWeight = $(if ($info.HasChildren) { [System.Windows.FontWeights]::SemiBold } else { [System.Windows.FontWeights]::Normal })
    $name.Foreground = $script:TextBrush

    $meta = New-Object System.Windows.Controls.TextBlock
    $meta.Margin = New-Object System.Windows.Thickness -ArgumentList 8, 0, 0, 0
    $meta.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $meta.Foreground = $script:MutedBrush
    $preview = [string]$info.Preview
    if ($preview.Length -gt 100) {
        $preview = $preview.Substring(0, 100) + '...'
    }
    if ([string]::IsNullOrWhiteSpace($preview)) {
        $meta.Text = $info.NodeType
    }
    else {
        $meta.Text = ('{0} | {1}' -f $info.NodeType, $preview)
    }

    [void]$panel.Children.Add($checkBox)
    [void]$panel.Children.Add($name)
    [void]$panel.Children.Add($meta)

    $NodeData.CheckBox = $checkBox
    [void]$panel.Children.Add((New-JsonRuleIconButton -State $State -NodeData $NodeData -Scope 'Local'))
    [void]$panel.Children.Add((New-JsonRuleIconButton -State $State -NodeData $NodeData -Scope 'Global'))

    $checkBox.Add_Click({
        param($sender, $eventArgs)
        $nodeData = $sender.Tag
        $desired = ($sender.IsChecked -eq $true)

        Remove-LocalExactPathJsonRule -FileNode $nodeData.State.FileNode -Selector $nodeData.Info.ExactPointer

        $rulesWithoutExact = [SourceContext.JsonFilterRule[]]@(Get-ActiveJsonRules -FileNode $nodeData.State.FileNode)
        $current = [SourceContext.JsonStreamingHelper]::EvaluateNodeIncluded(
            $nodeData.State.FileNode.FullPath,
            $nodeData.Info,
            $rulesWithoutExact,
            [bool]$nodeData.ParentEffectiveIncluded
        )

        if ($current -ne $desired) {
            $action = $(if ($desired) { 'Include' } else { 'Exclude' })
            $rule = New-JsonRule `
                -Scope 'Local' `
                -Action $action `
                -PathMode 'Exact' `
                -Selector ([string]$nodeData.Info.ExactPointer) `
                -Conditions ([SourceContext.JsonFieldCondition[]]@())
            [void](Add-OrReplaceJsonRule -Collection $nodeData.State.FileNode.JsonLocalRules -Rule $rule)
        }

        Update-JsonRulePanels -State $nodeData.State
        Update-JsonVisibleNodeStates -State $nodeData.State
        Update-JsonPreview -State $nodeData.State
    })

    return $panel
}

function New-JsonTreeItem {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][object]$Info,
        [switch]$IsRoot
    )

    $item = New-Object System.Windows.Controls.TreeViewItem
    $item.Margin = New-Object System.Windows.Thickness -ArgumentList 0, 1, 0, 1

    $data = [pscustomobject]@{
        Kind                    = 'JsonNode'
        State                   = $State
        Info                    = $Info
        CheckBox                = $null
        IsRoot                  = $IsRoot.IsPresent
        ChildrenLoaded          = $false
        NextOffset              = [Int64]-1
        NextIndex               = 0
        ParentEffectiveIncluded = $true
        EffectiveIncluded       = $true
    }

    $item.Tag = $data
    $item.Header = New-JsonNodeHeader -State $State -NodeData $data

    $contextMenu = New-Object System.Windows.Controls.ContextMenu

    $localRuleItem = New-Object System.Windows.Controls.MenuItem
    $localRuleItem.Header = 'Create local rule...'
    $localRuleItem.Tag = $data
    $localRuleItem.Add_Click({
        param($sender, $eventArgs)
        Show-JsonRuleEditor -State $sender.Tag.State -NodeData $sender.Tag -Scope 'Local'
    })

    $globalRuleItem = New-Object System.Windows.Controls.MenuItem
    $globalRuleItem.Header = 'Create global rule...'
    $globalRuleItem.Tag = $data
    $globalRuleItem.Add_Click({
        param($sender, $eventArgs)
        Show-JsonRuleEditor -State $sender.Tag.State -NodeData $sender.Tag -Scope 'Global'
    })

    [void]$contextMenu.Items.Add($localRuleItem)
    [void]$contextMenu.Items.Add($globalRuleItem)
    $item.ContextMenu = $contextMenu

    if ($Info.HasChildren) {
        [void]$item.Items.Add('Loading...')
        $item.Add_Expanded({
            param($sender, $eventArgs)
            $nodeData = $sender.Tag
            if ($nodeData -eq $null -or $nodeData.Kind -ne 'JsonNode' -or $nodeData.ChildrenLoaded) {
                return
            }

            $sender.Items.Clear()
            Add-JsonChildPage -ParentItem $sender -NodeData $nodeData
            $nodeData.ChildrenLoaded = $true
            Update-JsonVisibleNodeStates -State $nodeData.State
        })
    }

    return $item
}

function Add-JsonLoadMoreItem {
    param(
        [Parameter(Mandatory = $true)][System.Windows.Controls.TreeViewItem]$ParentItem,
        [Parameter(Mandatory = $true)][object]$NodeData
    )

    $moreItem = New-Object System.Windows.Controls.TreeViewItem
    $moreItem.IsExpanded = $false

    $button = New-Object System.Windows.Controls.Button
    $button.Content = ('Load next {0} nodes...' -f $script:JsonPageSize)
    $button.Padding = New-Object System.Windows.Thickness -ArgumentList 10, 4, 10, 4
    $button.Margin = New-Object System.Windows.Thickness -ArgumentList 4, 3, 4, 3

    $tag = [pscustomobject]@{
        ParentItem = $ParentItem
        MoreItem   = $moreItem
        NodeData   = $NodeData
    }
    $moreItem.Tag = [pscustomobject]@{ Kind = 'JsonMore' }
    $button.Tag = $tag
    $button.Add_Click({
        param($sender, $eventArgs)
        $loadData = $sender.Tag
        [void]$loadData.ParentItem.Items.Remove($loadData.MoreItem)
        Add-JsonChildPage -ParentItem $loadData.ParentItem -NodeData $loadData.NodeData
        Update-JsonVisibleNodeStates -State $loadData.NodeData.State
    })

    $moreItem.Header = $button
    [void]$ParentItem.Items.Add($moreItem)
}

function Add-JsonChildPage {
    param(
        [Parameter(Mandatory = $true)][System.Windows.Controls.TreeViewItem]$ParentItem,
        [Parameter(Mandatory = $true)][object]$NodeData
    )

    $state = $NodeData.State
    try {
        $page = [SourceContext.JsonStreamingHelper]::GetChildrenPage(
            $state.FileNode.FullPath,
            [Int64]$NodeData.Info.StartOffset,
            [string]$NodeData.Info.NodeType,
            [string]$NodeData.Info.ExactPointer,
            [string]$NodeData.Info.StructuralPointer,
            [string]$NodeData.Info.KeyName,
            [Int64]$NodeData.NextOffset,
            [int]$NodeData.NextIndex,
            [int]$script:JsonPageSize
        )

        foreach ($childInfo in $page.Children) {
            [void]$ParentItem.Items.Add((New-JsonTreeItem -State $state -Info $childInfo))
        }

        $NodeData.NextOffset = [Int64]$page.NextOffset
        $NodeData.NextIndex = [int]$page.NextIndex

        if ($page.HasMore) {
            Add-JsonLoadMoreItem -ParentItem $ParentItem -NodeData $NodeData
        }
    }
    catch {
        $errorItem = New-Object System.Windows.Controls.TreeViewItem
        $errorText = New-Object System.Windows.Controls.TextBlock
        $errorText.Text = ('Could not load JSON children: {0}' -f $_.Exception.Message)
        $errorText.Foreground = $script:ErrorBrush
        $errorText.TextWrapping = [System.Windows.TextWrapping]::Wrap
        $errorItem.Header = $errorText
        $errorItem.Tag = [pscustomobject]@{ Kind = 'JsonError' }
        [void]$ParentItem.Items.Add($errorItem)
    }
}

function Show-JsonConfigurationDialog {
    param([Parameter(Mandatory = $true)][object]$FileNode)

    if ($FileNode.Extension -ne '.json') {
        return
    }

    $jsonDialogXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Configure JSON export"
        Width="1320" Height="860" MinWidth="980" MinHeight="680"
        WindowStartupLocation="CenterOwner"
        Background="#F7F8FC"
        FontFamily="Segoe UI"
        ResizeMode="CanResizeWithGrip">
    <Grid Margin="14">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto" />
            <RowDefinition Height="*" />
            <RowDefinition Height="250" />
            <RowDefinition Height="Auto" />
        </Grid.RowDefinitions>

        <Border Grid.Row="0" Background="White" CornerRadius="10" Padding="12" Margin="0,0,0,10" BorderBrush="#EAECF0" BorderThickness="1">
            <StackPanel>
                <TextBlock Text="JSON export configuration" FontSize="20" FontWeight="SemiBold" Foreground="#111827" />
                <TextBlock Name="JsonFilePathText" Margin="0,5,0,0" Foreground="#344054" TextWrapping="Wrap" />
                <TextBlock Text="Children are loaded lazily in pages. The small symbols beside each node create local or global rules. Checkboxes create exact local Include/Exclude exceptions. Content rules can match objects by node name, required keys, and optional concrete scalar values." Margin="0,5,0,0" Foreground="#667085" TextWrapping="Wrap" />
            </StackPanel>
        </Border>

        <Grid Grid.Row="1" Margin="0,0,0,10">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="3*" />
                <ColumnDefinition Width="6" />
                <ColumnDefinition Width="2*" />
            </Grid.ColumnDefinitions>

            <GroupBox Grid.Column="0" Header="JSON structure" Background="White" BorderBrush="#EAECF0" Padding="8">
                <TreeView Name="JsonTree" BorderThickness="0" Background="White" ScrollViewer.HorizontalScrollBarVisibility="Auto" ScrollViewer.VerticalScrollBarVisibility="Auto" ScrollViewer.CanContentScroll="True" VirtualizingStackPanel.IsVirtualizing="True" VirtualizingStackPanel.VirtualizationMode="Recycling" />
            </GroupBox>

            <GridSplitter Grid.Column="1" HorizontalAlignment="Stretch" VerticalAlignment="Stretch" ResizeDirection="Columns" ResizeBehavior="PreviousAndNext" />

            <GroupBox Grid.Column="2" Header="Filtered preview" Background="White" BorderBrush="#EAECF0" Padding="8">
                <DockPanel>
                    <TextBlock Name="PreviewStatusText" DockPanel.Dock="Top" Foreground="#667085" Margin="0,0,0,6" />
                    <TextBox Name="JsonPreviewTextBox" IsReadOnly="True" AcceptsReturn="True" AcceptsTab="True" TextWrapping="NoWrap" FontFamily="Consolas" FontSize="12"
                             VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" />
                </DockPanel>
            </GroupBox>
        </Grid>

        <Grid Grid.Row="2" Margin="0,0,0,10">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*" />
                <ColumnDefinition Width="*" />
            </Grid.ColumnDefinitions>

            <GroupBox Grid.Column="0" Header="Local rules for this JSON file" Background="White" BorderBrush="#EAECF0" Padding="8" Margin="0,0,5,0">
                <DockPanel>
                    <CheckBox Name="LocalRemoveEmptyArraysCheckBox" DockPanel.Dock="Top" Content="Remove properties whose filtered value is an empty array" Margin="0,0,0,8" />
                    <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                        <StackPanel Name="LocalJsonRulesPanel" />
                    </ScrollViewer>
                </DockPanel>
            </GroupBox>

            <GroupBox Grid.Column="1" Header="Global rules for all JSON files in this source-context session" Background="White" BorderBrush="#EAECF0" Padding="8" Margin="5,0,0,0">
                <DockPanel>
                    <CheckBox Name="GlobalRemoveEmptyArraysCheckBox" DockPanel.Dock="Top" Content="Remove properties whose filtered value is an empty array" Margin="0,0,0,8" />
                    <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                        <StackPanel Name="GlobalJsonRulesPanel" />
                    </ScrollViewer>
                </DockPanel>
            </GroupBox>
        </Grid>

        <Grid Grid.Row="3">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*" />
                <ColumnDefinition Width="Auto" />
            </Grid.ColumnDefinitions>
            <TextBlock Grid.Column="0" Text="Priority: a direct rule at a descendant overrides inherited state. For rules matching the same node: Local > Global, Exact > Structural > Anywhere, then more value/field constraints, then node-name constraint, then Include on a complete tie. Rule creation order is irrelevant." Foreground="#667085" VerticalAlignment="Center" TextWrapping="Wrap" Margin="0,0,12,0" />
            <Button Name="CloseJsonDialogButton" Grid.Column="1" Content="Close" MinWidth="110" Padding="12,7" IsDefault="True" />
        </Grid>
    </Grid>
</Window>
"@

    [xml]$jsonDialogXml = $jsonDialogXaml
    $reader = New-Object System.Xml.XmlNodeReader $jsonDialogXml
    $window = [Windows.Markup.XamlReader]::Load($reader)
    $window.Owner = $script:Window

    $tree = $window.FindName('JsonTree')
    $localRulesPanel = $window.FindName('LocalJsonRulesPanel')
    $globalRulesPanel = $window.FindName('GlobalJsonRulesPanel')
    $filePathText = $window.FindName('JsonFilePathText')
    $previewTextBox = $window.FindName('JsonPreviewTextBox')
    $previewStatusText = $window.FindName('PreviewStatusText')
    $localRemoveEmptyArraysCheckBox = $window.FindName('LocalRemoveEmptyArraysCheckBox')
    $globalRemoveEmptyArraysCheckBox = $window.FindName('GlobalRemoveEmptyArraysCheckBox')
    $closeButton = $window.FindName('CloseJsonDialogButton')

    $filePathText.Text = $FileNode.RelPath

    $state = [pscustomobject]@{
        Window                         = $window
        Tree                           = $tree
        LocalRulesPanel                = $localRulesPanel
        GlobalRulesPanel               = $globalRulesPanel
        FileNode                       = $FileNode
        PreviewTextBox                 = $previewTextBox
        PreviewStatusText              = $previewStatusText
        LocalRemoveEmptyArraysCheckBox = $localRemoveEmptyArraysCheckBox
        GlobalRemoveEmptyArraysCheckBox = $globalRemoveEmptyArraysCheckBox
        SelectedNodeData               = $null
    }

    $window.Tag = $state
    $tree.Tag = $state

    $tree.Add_SelectedItemChanged({
        param($sender, $eventArgs)
        $dialogState = $sender.Tag
        $item = $sender.SelectedItem
        if ($item -is [System.Windows.Controls.TreeViewItem]) {
            $data = $item.Tag
            if ($data -ne $null -and $data.Kind -eq 'JsonNode') {
                $dialogState.SelectedNodeData = $data
                Update-JsonPreview -State $dialogState
            }
        }
    })

    $localRemoveEmptyArraysCheckBox.Tag = $state
    $localRemoveEmptyArraysCheckBox.Add_Click({
        param($sender, $eventArgs)
        $dialogState = $sender.Tag
        $dialogState.FileNode.JsonRemoveEmptyArrays = ($sender.IsChecked -eq $true)
        Update-JsonPreview -State $dialogState
    })

    $globalRemoveEmptyArraysCheckBox.Tag = $state
    $globalRemoveEmptyArraysCheckBox.Add_Click({
        param($sender, $eventArgs)
        $dialogState = $sender.Tag
        $script:GlobalJsonRemoveEmptyArrays = ($sender.IsChecked -eq $true)
        Update-JsonPreview -State $dialogState
    })

    $closeButton.Tag = $window
    $closeButton.Add_Click({
        param($sender, $eventArgs)
        $sender.Tag.Close()
    })

    try {
        $rootInfo = [SourceContext.JsonStreamingHelper]::GetRootInfo($FileNode.FullPath)
        $rootItem = New-JsonTreeItem -State $state -Info $rootInfo -IsRoot
        [void]$tree.Items.Add($rootItem)
        $rootItem.IsExpanded = $true
        $state.SelectedNodeData = $rootItem.Tag
        $rootItem.IsSelected = $true
    }
    catch {
        [System.Windows.MessageBox]::Show(
            $window,
            ('The JSON structure could not be opened:`r`n{0}' -f $_.Exception.Message),
            'JSON configuration error',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error
        ) | Out-Null
    }

    Update-JsonRulePanels -State $state
    Update-JsonVisibleNodeStates -State $state
    Update-JsonPreview -State $state
    [void]$window.ShowDialog()
}

function Refresh-VisibleProjectSubtreeHeadersRecursive {
    param(
        [Parameter(Mandatory = $true)][object]$Node,
        [Parameter(Mandatory = $true)][bool]$ParentStructure,
        [Parameter(Mandatory = $true)][bool]$ParentContent
    )

    if ($Node.UiItem -eq $null) { return }

    Set-EffectiveExportState `
        -Node $Node `
        -ParentStructure $ParentStructure `
        -ParentContent $ParentContent

    $Node.UiItem.Header = New-HeaderStack -Node $Node

    if (-not $Node.IsDirectory -or -not $Node.UiItem.IsExpanded) {
        return
    }

    foreach ($child in $Node.Children) {
        if ($child.UiItem -ne $null) {
            Refresh-VisibleProjectSubtreeHeadersRecursive `
                -Node $child `
                -ParentStructure ([bool]$Node.EffectiveChildren) `
                -ParentContent ([bool]$Node.EffectiveContent)
        }
    }
}

function Refresh-VisibleProjectSubtreeHeaders {
    param([Parameter(Mandatory = $true)][object]$Node)

    $inheritance = Get-ParentExportInheritance -Node $Node
    Refresh-VisibleProjectSubtreeHeadersRecursive `
        -Node $Node `
        -ParentStructure ([bool]$inheritance.Structure) `
        -ParentContent ([bool]$inheritance.Content)
}

function Refresh-SelectionAfterOverrideChange {
    param([Parameter(Mandatory = $true)][object]$Node)

    $script:SuppressEvents = $true
    try {
        Refresh-VisibleProjectSubtreeHeaders -Node $Node
    }
    finally {
        $script:SuppressEvents = $false
    }

    Update-ExtensionPanels
    Update-Status
}

function Refresh-ExtensionAvailabilityUi {
    param([Parameter(Mandatory = $true)][string]$Extension)

    $script:SuppressEvents = $true
    try {
        if ($script:ExtensionToFiles.ContainsKey($Extension)) {
            foreach ($fileNode in $script:ExtensionToFiles[$Extension]) {
                if ($fileNode.UiItem -ne $null -and $fileNode.UiItem.IsVisible) {
                    $inheritance = Get-ParentExportInheritance -Node $fileNode
                    Set-EffectiveExportState `
                        -Node $fileNode `
                        -ParentStructure ([bool]$inheritance.Structure) `
                        -ParentContent ([bool]$inheritance.Content)
                    $fileNode.UiItem.Header = New-HeaderStack -Node $fileNode
                }
            }
        }
    }
    finally {
        $script:SuppressEvents = $false
    }

    Update-ExtensionPanels
    Update-Status
}

function New-ExportSelectionCheckBox {
    param(
        [Parameter(Mandatory = $true)][object]$Node,
        [Parameter(Mandatory = $true)][string]$OverrideProperty,
        [Parameter(Mandatory = $true)][string]$EffectiveProperty,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$Description,
        [string]$DisabledReason = $null
    )

    $checkBox = New-Object System.Windows.Controls.CheckBox
    $checkBox.Content = $Label
    $checkBox.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $checkBox.Margin = New-Object System.Windows.Thickness -ArgumentList 0, 0, 6, 0
    $checkBox.Padding = New-Object System.Windows.Thickness -ArgumentList 1, 0, 1, 0

    $overrideValue = $Node.PSObject.Properties[$OverrideProperty].Value
    $isInherited = ($null -eq $overrideValue)
    $effectiveValue = [bool]$Node.PSObject.Properties[$EffectiveProperty].Value

    $checkBox.IsChecked = $effectiveValue
    $checkBox.Opacity = $(if ($isInherited) { 0.70 } else { 1.0 })

    $stateText = $(if ($isInherited) {
        'Inherited: ' + $(if ($effectiveValue) { 'enabled' } else { 'disabled' })
    }
    else {
        'Explicit override: ' + $(if ($effectiveValue) { 'enabled' } else { 'disabled' })
    })

    $extraDescription = ''
    if ($OverrideProperty -eq 'ChildrenOverride') {
        $extraDescription = "`r`nEnabling S immediately scans this complete subtree. The scan can be canceled; if canceled, S stays disabled."
    }

    $checkBox.ToolTip = (
        $Description + $extraDescription + "`r`n" +
        $stateText + "`r`n" +
        'Click to create/change an override. Right-click and choose "Use inherited value" to clear an override.'
    )

    $tag = [pscustomobject]@{
        Node              = $Node
        OverrideProperty  = $OverrideProperty
        EffectiveProperty = $EffectiveProperty
    }
    $checkBox.Tag = $tag

    $checkBox.Add_Click({
        param($sender, $eventArgs)
        if ($script:SuppressEvents) { return }

        $selection = $sender.Tag
        $desired = ($sender.IsChecked -eq $true)

        if (
            $selection.OverrideProperty -eq 'ChildrenOverride' -and
            $desired -and
            -not [bool]$selection.Node.SubtreeFullyScanned
        ) {
            $scan = Invoke-RecursiveStructureScan -DirectoryNode $selection.Node
            if (-not [bool]$scan.Completed) {
                Refresh-SelectionAfterOverrideChange -Node $selection.Node
                return
            }
        }

        Set-ExportOverrideValue `
            -Node $selection.Node `
            -OverrideProperty $selection.OverrideProperty `
            -Value $desired

        Refresh-SelectionAfterOverrideChange -Node $selection.Node
    })

    $contextMenu = New-Object System.Windows.Controls.ContextMenu
    $inheritItem = New-Object System.Windows.Controls.MenuItem
    $inheritItem.Header = 'Use inherited value'
    $inheritItem.IsEnabled = ($Node.Parent -ne $null -and -not $isInherited)
    $inheritItem.Tag = $tag
    $inheritItem.Add_Click({
        param($sender, $eventArgs)
        $selection = $sender.Tag

        if ($selection.OverrideProperty -eq 'ChildrenOverride') {
            $inheritance = Get-ParentExportInheritance -Node $selection.Node
            if (
                [bool]$inheritance.Structure -and
                -not [bool]$selection.Node.SubtreeFullyScanned
            ) {
                $scan = Invoke-RecursiveStructureScan -DirectoryNode $selection.Node
                if (-not [bool]$scan.Completed) {
                    Refresh-SelectionAfterOverrideChange -Node $selection.Node
                    return
                }
            }
        }

        Set-ExportOverrideValue `
            -Node $selection.Node `
            -OverrideProperty $selection.OverrideProperty `
            -Clear

        Refresh-SelectionAfterOverrideChange -Node $selection.Node
    })
    [void]$contextMenu.Items.Add($inheritItem)
    $checkBox.ContextMenu = $contextMenu

    if (-not [string]::IsNullOrWhiteSpace($DisabledReason)) {
        $checkBox.IsEnabled = $false
        $checkBox.IsChecked = $false
        $checkBox.Opacity = 0.45
        $checkBox.ToolTip = ($DisabledReason + "`r`nThe underlying inherited/override state is preserved and will reappear if this option becomes available again.")
    }

    return $checkBox
}

function New-HeaderStack {
    param([Parameter(Mandatory = $true)][object]$Node)

    $panel = New-Object System.Windows.Controls.StackPanel
    $panel.Orientation = [System.Windows.Controls.Orientation]::Horizontal

    $entryDisabledReason = $null
    if (-not $Node.IsDirectory -and -not (Test-FileTypeEnabled -FileNode $Node)) {
        $entryDisabledReason = 'Enable this file type below before this file entry can be exported.'
    }

    $entryCheckBox = New-ExportSelectionCheckBox `
        -Node $Node `
        -OverrideProperty 'EntryOverride' `
        -EffectiveProperty 'EffectiveEntry' `
        -Label 'E' `
        -Description $(if ($Node.IsDirectory) { 'E = include this directory entry itself.' } else { 'E = include this file entry and its metadata.' }) `
        -DisabledReason $entryDisabledReason

    [void]$panel.Children.Add($entryCheckBox)

    if ($Node.IsDirectory) {
        $structureCheckBox = New-ExportSelectionCheckBox `
            -Node $Node `
            -OverrideProperty 'ChildrenOverride' `
            -EffectiveProperty 'EffectiveChildren' `
            -Label 'S' `
            -Description 'S = include descendant directory/file entries by default. Child overrides still take precedence.'

        $contentCheckBox = New-ExportSelectionCheckBox `
            -Node $Node `
            -OverrideProperty 'RecursiveContentOverride' `
            -EffectiveProperty 'EffectiveContent' `
            -Label 'C' `
            -Description 'C = include supported descendant file contents recursively by default. Child/file overrides still take precedence.'

        [void]$panel.Children.Add($structureCheckBox)
        [void]$panel.Children.Add($contentCheckBox)
    }
    else {
        $contentDisabledReason = $null
        if (-not (Test-FileTypeEnabled -FileNode $Node)) {
            $contentDisabledReason = 'Enable this file type below before its content can be exported.'
        }
        elseif (-not (Test-FileSupportsTextContent -FileNode $Node)) {
            $contentDisabledReason = 'This is a non-text or unknown file type. Only metadata can be exported; its bytes are never read as text.'
        }
        elseif (-not [bool]$Node.EffectiveEntry) {
            $contentDisabledReason = 'Enable the file entry (E) before file content can be exported.'
        }

        $contentCheckBox = New-ExportSelectionCheckBox `
            -Node $Node `
            -OverrideProperty 'ContentOverride' `
            -EffectiveProperty 'EffectiveContent' `
            -Label 'C' `
            -Description 'C = include the file content in addition to its metadata.' `
            -DisabledReason $contentDisabledReason

        [void]$panel.Children.Add($contentCheckBox)
    }

    $icon = New-Object System.Windows.Controls.TextBlock
    $icon.Margin = New-Object System.Windows.Thickness -ArgumentList 2, 0, 5, 0
    $icon.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    if ($Node.IsDirectory) {
        if ($Node.Parent -eq $null) { $icon.Text = '[root]' } else { $icon.Text = '[dir]' }
    }
    else {
        $icon.Text = '[file]'
    }

    $nameBlock = New-Object System.Windows.Controls.TextBlock
    $nameBlock.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $nameBlock.Foreground = $script:TextBrush
    if ($Node.IsDirectory) {
        $nameBlock.FontWeight = [System.Windows.FontWeights]::SemiBold
    }
    if ($Node.Parent -eq $null) {
        $nameBlock.Text = ('{0}  (Root)' -f $Node.Name)
    }
    else {
        $nameBlock.Text = $Node.Name
    }

    $metaBlock = New-Object System.Windows.Controls.TextBlock
    $metaBlock.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $metaBlock.Margin = New-Object System.Windows.Thickness -ArgumentList 8, 0, 0, 0
    $metaBlock.Foreground = $script:MutedBrush

    if ($Node.IsDirectory) {
        if ([bool]$Node.SubtreeFullyScanned) {
            $metaText = ('{0} files | {1} extensions' -f $Node.TotalFiles, $Node.ExtensionSet.Count)
        }
        elseif ([bool]$Node.ChildrenLoaded) {
            $metaText = ('{0} files discovered | deeper folders lazy' -f $Node.TotalFiles)
        }
        else {
            $metaText = 'not scanned yet'
        }

        if ($Node.ScanError) {
            $metaText += ' | scan note'
            $metaBlock.Foreground = $script:ErrorBrush
            $metaBlock.ToolTip = $Node.ScanError
        }
        $metaBlock.Text = $metaText
    }
    else {
        $metaBlock.Text = ('{0} | {1}' -f (Get-FileTypeDescription -FileNode $Node), (Format-Size -Bytes $Node.SizeBytes))
    }

    [void]$panel.Children.Add($icon)
    [void]$panel.Children.Add($nameBlock)
    [void]$panel.Children.Add($metaBlock)

    if (-not $Node.IsDirectory -and $Node.Extension -eq '.json') {
        $jsonConfigureButton = New-Object System.Windows.Controls.Button
        $jsonConfigureButton.Content = 'Configure JSON...'
        $jsonConfigureButton.Margin = New-Object System.Windows.Thickness -ArgumentList 10, 0, 0, 0
        $jsonConfigureButton.Padding = New-Object System.Windows.Thickness -ArgumentList 8, 2, 8, 2
        $jsonConfigureButton.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        $jsonConfigureButton.ToolTip = 'Configure JSON Include/Exclude, path, structure, value, and cleanup rules for this file.'
        $jsonConfigureButton.Tag = $Node
        $jsonConfigureButton.IsEnabled = (Test-FileTypeEnabled -FileNode $Node)
        $jsonConfigureButton.Add_Click({
            param($sender, $eventArgs)
            Show-JsonConfigurationDialog -FileNode $sender.Tag
        })
        [void]$panel.Children.Add($jsonConfigureButton)
    }

    $Node.CheckBox = $entryCheckBox
    return $panel
}

function Add-UnloadedDirectoryPlaceholder {
    param(
        [Parameter(Mandatory = $true)][System.Windows.Controls.TreeViewItem]$Item,
        [Parameter(Mandatory = $true)][object]$Node
    )

    if (-not $Node.IsDirectory) { return }

    $Item.Items.Clear()

    if ([bool]$Node.ChildrenLoaded -and $Node.Children.Count -eq 0) {
        $Node.UiChildrenMaterialized = $true
        return
    }

    $placeholder = New-Object System.Windows.Controls.TreeViewItem
    $placeholder.Header = 'Expand to load...'
    $placeholder.IsEnabled = $false
    $placeholder.Tag = [pscustomobject]@{ Kind = 'ProjectLazyPlaceholder' }
    [void]$Item.Items.Add($placeholder)
}

function Populate-ProjectTreeItemChildren {
    param(
        [Parameter(Mandatory = $true)][System.Windows.Controls.TreeViewItem]$Item,
        [Parameter(Mandatory = $true)][object]$Node
    )

    if (-not $Node.IsDirectory) { return }

    Ensure-DirectoryChildrenLoaded -DirectoryNode $Node

    $inheritance = Get-ParentExportInheritance -Node $Node
    Set-EffectiveExportState `
        -Node $Node `
        -ParentStructure ([bool]$inheritance.Structure) `
        -ParentContent ([bool]$inheritance.Content)

    $Item.Items.Clear()

    foreach ($child in $Node.Children) {
        if ($child.IsDirectory -or $script:ShowFiles) {
            [void]$Item.Items.Add(
                (New-TreeViewItemForNode `
                    -Node $child `
                    -ParentStructure ([bool]$Node.EffectiveChildren) `
                    -ParentContent ([bool]$Node.EffectiveContent))
            )
        }
    }

    $Node.UiChildrenMaterialized = $true
}

function New-TreeViewItemForNode {
    param(
        [Parameter(Mandatory = $true)][object]$Node,
        [Parameter(Mandatory = $true)][bool]$ParentStructure,
        [Parameter(Mandatory = $true)][bool]$ParentContent
    )

    Set-EffectiveExportState `
        -Node $Node `
        -ParentStructure $ParentStructure `
        -ParentContent $ParentContent

    $item = New-Object System.Windows.Controls.TreeViewItem
    $item.Header = New-HeaderStack -Node $Node
    $item.Tag = $Node
    $item.Margin = New-Object System.Windows.Thickness -ArgumentList 0, 1, 0, 1
    $Node.UiItem = $item

    if ($Node.IsDirectory) {
        $Node.UiChildrenMaterialized = $false
        Add-UnloadedDirectoryPlaceholder -Item $item -Node $Node

        $item.Add_Expanded({
            param($sender, $eventArgs)
            if ($script:SuppressEvents) { return }
            if ($eventArgs.OriginalSource -ne $sender) { return }

            $node = $sender.Tag
            if ($node -eq $null -or -not $node.IsDirectory) { return }

            $script:SuppressEvents = $true
            try {
                if (-not [bool]$node.UiChildrenMaterialized) {
                    Populate-ProjectTreeItemChildren -Item $sender -Node $node
                }

                Refresh-VisibleProjectSubtreeHeaders -Node $node
            }
            finally {
                $script:SuppressEvents = $false
            }

            Update-ExtensionPanels
            Update-Status
        })
    }

    return $item
}

function Update-Status {
    $summary = Get-ExportSubtreeSummary `
        -Node $script:RootNode `
        -ParentStructure $true `
        -ParentContent $true

    $selectedDirectoryCount = [int]$summary.DirectoryEntryCount
    $selectedFileCount = 0
    $contentCount = 0
    $activeExtensionCount = 0

    foreach ($extension in $script:ExtensionToFiles.Keys) {
        $enabled = (
            -not $script:ExtensionEnabled.ContainsKey($extension) -or
            [bool]$script:ExtensionEnabled[$extension]
        )

        if (-not $enabled) {
            continue
        }

        $entryCount = 0
        if ($summary.FileEntryCounts.ContainsKey($extension)) {
            $entryCount = [int]$summary.FileEntryCounts[$extension]
        }

        if ($entryCount -gt 0) {
            $selectedFileCount += $entryCount
            $activeExtensionCount++
        }

        if ($summary.FileContentCounts.ContainsKey($extension)) {
            $contentCount += [int]$summary.FileContentCounts[$extension]
        }
    }

    $selectedEntryCount = $selectedDirectoryCount + $selectedFileCount

    if ($script:StatusText -ne $null) {
        $scanSuffix = $(if ([bool]$script:RootNode.SubtreeFullyScanned) {
            ''
        }
        else {
            ' | counts cover discovered folders only; full selected branches are scanned on export'
        })

        $script:StatusText.Text = (
            ('{0} discovered entries selected ({1} directories, {2} files) | {3} discovered file contents included | {4} enabled discovered file types' -f
                $selectedEntryCount,
                $selectedDirectoryCount,
                $selectedFileCount,
                $contentCount,
                $activeExtensionCount) +
            $scanSuffix
        )
    }

    $hasSelectedEntries = ($selectedEntryCount -gt 0)

    if ($script:OkButton -ne $null) {
        $script:OkButton.IsEnabled = $hasSelectedEntries
    }

    if ($script:ExportButton -ne $null) {
        $script:ExportButton.IsEnabled = $hasSelectedEntries
    }
}

function Add-EmptyExtensionPanelText {
    param(
        [Parameter(Mandatory = $true)][object]$Panel,
        [Parameter(Mandatory = $true)][string]$Text
    )

    $emptyText = New-Object System.Windows.Controls.TextBlock
    $emptyText.Text = $Text
    $emptyText.Foreground = $script:MutedBrush
    [void]$Panel.Children.Add($emptyText)
}

function Add-ExtensionOption {
    param(
        [Parameter(Mandatory = $true)][object]$Panel,
        [Parameter(Mandatory = $true)][string]$Extension,
        [Parameter(Mandatory = $true)][int]$Count,
        [Parameter(Mandatory = $true)][bool]$IsNonText
    )

    if (-not $script:ExtensionEnabled.ContainsKey($Extension)) {
        $script:ExtensionEnabled[$Extension] = Get-DefaultExtensionEnabled -Extension $Extension
    }

    $checkBox = New-Object System.Windows.Controls.CheckBox
    $checkBox.Margin = New-Object System.Windows.Thickness -ArgumentList 0, 0, 14, 8
    $checkBox.Padding = New-Object System.Windows.Thickness -ArgumentList 6, 2, 6, 2
    $checkBox.Tag = $Extension
    $checkBox.IsChecked = [bool]$script:ExtensionEnabled[$Extension]
    $checkBox.Content = ('{0} ({1})' -f (Format-ExtensionLabel -Extension $Extension), $Count)

    $dirCount = 0
    if ($script:ExtensionToDirectories.ContainsKey($Extension)) {
        $dirCount = $script:ExtensionToDirectories[$Extension].Count
    }

    if ($IsNonText) {
        $checkBox.ToolTip = ('{0} non-text or unknown files in the selected structure. When enabled, their file entries can be exported as metadata only; their bytes are never read as text. The currently loaded folders contain this type in {1} directly scanned folders.' -f $Count, $dirCount)
    }
    else {
        $checkBox.ToolTip = ('{0} text files in the selected structure. When enabled, their entries are available and each file/content checkbox decides whether metadata only or content is exported. The full scan found this extension in {1} folders.' -f $Count, $dirCount)
    }

    $checkBox.Add_Click({
        param($sender, $eventArgs)
        if ($script:SuppressEvents) { return }
        $extensionKey = [string]$sender.Tag
        $script:ExtensionEnabled[$extensionKey] = ($sender.IsChecked -eq $true)
        Refresh-ExtensionAvailabilityUi -Extension $extensionKey
    })

    [void]$Panel.Children.Add($checkBox)
}

function Update-ExtensionPanels {
    if ($script:TextExtensionsPanel -eq $null -or $script:NonTextExtensionsPanel -eq $null) { return }

    $summary = Get-ExportSubtreeSummary `
        -Node $script:RootNode `
        -ParentStructure $true `
        -ParentContent $true

    $script:TextExtensionsPanel.Children.Clear()
    $script:NonTextExtensionsPanel.Children.Clear()
    $textCounts = @{}
    $nonTextCounts = @{}

    foreach ($extension in $summary.FileEntryCounts.Keys) {
        $count = [int]$summary.FileEntryCounts[$extension]
        if ($count -le 0) { continue }

        if (Test-IsNonTextExtension -Extension $extension) {
            $nonTextCounts[$extension] = $count
        }
        else {
            $textCounts[$extension] = $count
        }
    }

    if ($textCounts.Count -eq 0) {
        Add-EmptyExtensionPanelText -Panel $script:TextExtensionsPanel -Text 'No text file types have been discovered in the loaded folders yet.'
    }
    else {
        foreach ($extension in ($textCounts.Keys | Sort-Object)) {
            Add-ExtensionOption -Panel $script:TextExtensionsPanel -Extension $extension -Count $textCounts[$extension] -IsNonText $false
        }
    }

    if ($nonTextCounts.Count -eq 0) {
        Add-EmptyExtensionPanelText -Panel $script:NonTextExtensionsPanel -Text 'No non-text or unknown file types have been discovered in the loaded folders yet.'
    }
    else {
        foreach ($extension in ($nonTextCounts.Keys | Sort-Object)) {
            Add-ExtensionOption -Panel $script:NonTextExtensionsPanel -Extension $extension -Count $nonTextCounts[$extension] -IsNonText $true
        }
    }
}

function Refresh-TreeView {
    param([switch]$PreserveExpansion)

    if ($script:ProjectTree -eq $null -or $script:RootNode -eq $null) { return }

    $expanded = @{}
    if ($PreserveExpansion) {
        Collect-ExpandedPaths -Node $script:RootNode -Expanded $expanded
    }

    $script:SuppressEvents = $true
    try {
        $script:ProjectTree.Items.Clear()
        $rootItem = New-TreeViewItemForNode `
            -Node $script:RootNode `
            -ParentStructure $true `
            -ParentContent $true

        [void]$script:ProjectTree.Items.Add($rootItem)

        # Root is the one level that was already enumerated at startup.
        Populate-ProjectTreeItemChildren -Item $rootItem -Node $script:RootNode
        $rootItem.IsExpanded = $true

        Restore-ExpandedPaths -Node $script:RootNode -Expanded $expanded
    }
    finally {
        $script:SuppressEvents = $false
    }

    Update-ExtensionPanels
    Update-Status
}

$script:MutedBrush = New-Brush '#667085'
$script:TextBrush = New-Brush '#1F2937'
$script:ErrorBrush = New-Brush '#B42318'

Read-ExporterConfiguration

Show-LoadingWindow -Status 'Opening Source Context Exporter...' -Detail $TargetFolder
try {
    Update-LoadingWindow -Status 'Reading top-level folder...' -Detail ("{0}`r`nIgnored folder names loaded: {1}" -f $TargetFolder, $script:IgnoredFolderNames.Count) -Force

    $script:RootNode = New-DirectoryNode -FullPath $TargetFolder -Parent $null

    # Exactly one filesystem level is read at startup.
    Ensure-DirectoryChildrenLoaded -DirectoryNode $script:RootNode -Quiet

    $topFiles = @($script:RootNode.Children | Where-Object { -not $_.IsDirectory }).Count
    $topDirectories = @($script:RootNode.Children | Where-Object { $_.IsDirectory }).Count
    Update-LoadingWindow -Status 'Building dialog...' -Detail ('{0} top-level files and {1} top-level folders discovered' -f $topFiles, $topDirectories) -Force
}
catch {
    Close-LoadingWindow
    throw
}

$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Source Context Exporter"
        Width="1040" Height="860" MinWidth="820" MinHeight="700"
        WindowStartupLocation="CenterScreen"
        Background="#F7F8FC"
        FontFamily="Segoe UI"
        ResizeMode="CanResizeWithGrip">
    <Grid Margin="14">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto" />
            <RowDefinition Height="*" />
            <RowDefinition Height="220" />
            <RowDefinition Height="Auto" />
            <RowDefinition Height="Auto" />
        </Grid.RowDefinitions>

        <Border Grid.Row="0" Background="White" CornerRadius="12" Padding="14" Margin="0,0,0,10" BorderBrush="#EAECF0" BorderThickness="1">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*" />
                    <ColumnDefinition Width="Auto" />
                </Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0">
                    <TextBlock Text="Source Context Exporter" FontSize="22" FontWeight="SemiBold" Foreground="#111827" />
                    <TextBlock Name="RootPathText" Margin="0,5,0,0" Foreground="#344054" TextWrapping="Wrap" />
                    <TextBlock Text="Startup reads only the root folder and its immediate children. Deeper folders are enumerated when expanded, or when their selected structure is needed for export. Windows, UNC and WSL paths are supported. File contents are read only during export." Margin="0,4,0,0" Foreground="#667085" TextWrapping="Wrap" />
                </StackPanel>
                <StackPanel Grid.Column="1" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="16,0,0,0">
                    <Button Name="ToggleFilesButton" Content="Show files" MinWidth="138" Padding="12,7" />
                </StackPanel>
            </Grid>
        </Border>

        <GroupBox Grid.Row="1" Header="Folder tree" Background="White" BorderBrush="#EAECF0" Padding="8" Margin="0,0,0,10">
            <DockPanel>
                <TextBlock DockPanel.Dock="Top"
                           Text="Selection columns: E = include this entry, S = include descendant structure, C = include file contents. All start disabled. Enabling S on a folder immediately scans that complete subtree; child S values inherit it unless a local override exists. Faded checkboxes inherit their value; right-click to return an override to inheritance."
                           Foreground="#667085" Margin="0,0,0,8" TextWrapping="Wrap" />
                <TreeView Name="ProjectTree" BorderThickness="0" Background="White" ScrollViewer.HorizontalScrollBarVisibility="Auto" ScrollViewer.VerticalScrollBarVisibility="Auto" />
            </DockPanel>
        </GroupBox>

        <Grid Grid.Row="2" Margin="0,0,0,10">
            <Grid.RowDefinitions>
                <RowDefinition Height="*" />
                <RowDefinition Height="*" />
            </Grid.RowDefinitions>

            <GroupBox Grid.Row="0" Header="Text file types discovered so far (checked = available for entry/content export)" Background="White" BorderBrush="#EAECF0" Padding="10" Margin="0,0,0,5">
                <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                    <WrapPanel Name="TextExtensionsPanel" />
                </ScrollViewer>
            </GroupBox>

            <GroupBox Grid.Row="1" Header="Non-text or unknown file types discovered so far (checked = allow metadata entry export)" Background="White" BorderBrush="#EAECF0" Padding="10" Margin="0,5,0,0">
                <DockPanel>
                    <TextBlock DockPanel.Dock="Top" Text="Unchecked types are unavailable for export. Checked non-text/unknown types can contribute file metadata only; their bytes are never read as text." Foreground="#667085" Margin="0,0,0,8" TextWrapping="Wrap" />
                    <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                        <WrapPanel Name="NonTextExtensionsPanel" />
                    </ScrollViewer>
                </DockPanel>
            </GroupBox>
        </Grid>

        <Border Grid.Row="3" Background="White" CornerRadius="12" Padding="12" Margin="0,0,0,10" BorderBrush="#EAECF0" BorderThickness="1">
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto" />
                    <RowDefinition Height="Auto" />
                </Grid.RowDefinitions>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto" />
                    <ColumnDefinition Width="*" />
                    <ColumnDefinition Width="Auto" />
                </Grid.ColumnDefinitions>

                <CheckBox Name="LineNumbersCheckBox" Grid.Row="0" Grid.Column="0" Grid.ColumnSpan="3" Content="Show line numbers in export" IsChecked="True" Margin="0,0,0,10" />

                <TextBlock Grid.Row="1" Grid.Column="0" Text="Output file:" VerticalAlignment="Center" Margin="0,0,10,0" Foreground="#344054" />
                <TextBox Name="OutputPathTextBox" Grid.Row="1" Grid.Column="1" MinHeight="28" VerticalContentAlignment="Center" />
                <Button Name="BrowseButton" Grid.Row="1" Grid.Column="2" Content="Browse..." Padding="12,5" Margin="8,0,0,0" />
            </Grid>
        </Border>

        <Grid Grid.Row="4">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*" />
                <ColumnDefinition Width="Auto" />
            </Grid.ColumnDefinitions>
            <TextBlock Name="StatusText" Grid.Column="0" VerticalAlignment="Center" Foreground="#475467" TextWrapping="Wrap" />
            <StackPanel Grid.Column="1" Orientation="Horizontal" HorizontalAlignment="Right">
                <Button Name="CancelButton" Content="Cancel" MinWidth="110" Padding="12,7" Margin="0,0,8,0" IsCancel="True" />
                <Button Name="ExportButton" Content="Datei exportieren" MinWidth="140" Padding="12,7" Margin="0,0,8,0" />
                <Button Name="OkButton" Content="In Zwischenablage kopieren" MinWidth="190" Padding="12,7" IsDefault="True" Background="#2563EB" Foreground="White" FontWeight="SemiBold" />
            </StackPanel>
        </Grid>
    </Grid>
</Window>
"@

[xml]$xamlXml = $xaml
$reader = New-Object System.Xml.XmlNodeReader $xamlXml
$script:Window = [Windows.Markup.XamlReader]::Load($reader)

$iconPath = Join-Path $PSScriptRoot 'SourceContext.ico'
if (Test-Path -LiteralPath $iconPath -PathType Leaf) {
    try {
        $iconUri = New-Object System.Uri -ArgumentList $iconPath
        $script:Window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create($iconUri)
    }
    catch {
        # Icon is optional; ignore invalid icon files.
    }
}

$script:ProjectTree = $script:Window.FindName('ProjectTree')
$script:TextExtensionsPanel = $script:Window.FindName('TextExtensionsPanel')
$script:NonTextExtensionsPanel = $script:Window.FindName('NonTextExtensionsPanel')
$script:StatusText = $script:Window.FindName('StatusText')
$script:OkButton = $script:Window.FindName('OkButton')
$script:ExportButton = $script:Window.FindName('ExportButton')
$script:ToggleFilesButton = $script:Window.FindName('ToggleFilesButton')
$rootPathText = $script:Window.FindName('RootPathText')
$outputPathTextBox = $script:Window.FindName('OutputPathTextBox')
$lineNumbersCheckBox = $script:Window.FindName('LineNumbersCheckBox')
$browseButton = $script:Window.FindName('BrowseButton')
$cancelButton = $script:Window.FindName('CancelButton')

$rootPathText.Text = $TargetFolder
$defaultOutputName = 'source-context-{0}.md' -f (Get-Date -Format 'yyyyMMdd-HHmmss')
$outputPathTextBox.Text = Join-Path $TargetFolder $defaultOutputName

$script:ToggleFilesButton.Add_Click({
    param($sender, $eventArgs)
    $script:ShowFiles = -not $script:ShowFiles
    if ($script:ShowFiles) {
        $sender.Content = 'Hide files'
    }
    else {
        $sender.Content = 'Show files'
    }
    Refresh-TreeView -PreserveExpansion
})

$browseButton.Add_Click({
    param($sender, $eventArgs)
    $dialog = New-Object Microsoft.Win32.SaveFileDialog
    $dialog.Title = 'Save source context file'
    $dialog.Filter = 'Markdown (*.md)|*.md|Text file (*.txt)|*.txt|All files (*.*)|*.*'
    $dialog.FileName = [System.IO.Path]::GetFileName($outputPathTextBox.Text)
    $initialDirectory = [System.IO.Path]::GetDirectoryName($outputPathTextBox.Text)
    if (-not [string]::IsNullOrWhiteSpace($initialDirectory) -and (Test-Path -LiteralPath $initialDirectory -PathType Container)) {
        $dialog.InitialDirectory = $initialDirectory
    }
    if ($dialog.ShowDialog($script:Window) -eq $true) {
        $outputPathTextBox.Text = $dialog.FileName
    }
})

$cancelButton.Add_Click({
    param($sender, $eventArgs)
    $script:Window.Close()
})

$copyToClipboardHandler = {
    param($sender, $eventArgs)

    try {
        $includeLineNumbers = ($lineNumbersCheckBox.IsChecked -eq $true)
        [void](Copy-SelectedContextToClipboard -IncludeLineNumbers $includeLineNumbers)
    }
    catch {
        [System.Windows.MessageBox]::Show($script:Window, $_.Exception.Message, 'Copy failed', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
    }
}

$script:OkButton.Add_Click($copyToClipboardHandler)

$script:ExportButton.Add_Click({
    param($sender, $eventArgs)

    try {
        $selectedNodes = @(Get-SelectedExportNodes)
        if ($selectedNodes.Count -eq 0) {
            [System.Windows.MessageBox]::Show($script:Window, 'No project entry is selected for export.', 'Source Context Exporter', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
            return
        }

        $outputPath = $outputPathTextBox.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($outputPath)) {
            [System.Windows.MessageBox]::Show($script:Window, 'Please enter an output file.', 'Source Context Exporter', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
            return
        }

        $outputDirectory = [System.IO.Path]::GetDirectoryName($outputPath)
        if (-not [string]::IsNullOrWhiteSpace($outputDirectory) -and -not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
            [void](New-Item -Path $outputDirectory -ItemType Directory -Force)
        }

        $includeLineNumbers = ($lineNumbersCheckBox.IsChecked -eq $true)
        $markdown = New-SourceContextMarkdown -Nodes $selectedNodes -IncludeLineNumbers $includeLineNumbers
        $utf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList $false
        [System.IO.File]::WriteAllText($outputPath, $markdown, $utf8NoBom)

        $clipboardStatus = 'and copied to the clipboard'
        try {
            [void](Set-ClipboardTextReliable -Text $markdown)
        }
        catch {
            $clipboardStatus = 'saved; clipboard could not be set: ' + $_.Exception.Message
        }

        $message = ('Export complete: {0} project entries were written to`r`n{1}`r`n{2}.' -f $selectedNodes.Count, $outputPath, $clipboardStatus)
        [System.Windows.MessageBox]::Show($script:Window, $message, 'Source Context Exporter', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
        $script:Window.DialogResult = $true
        $script:Window.Close()
    }
    catch {
        [System.Windows.MessageBox]::Show($script:Window, $_.Exception.Message, 'Export failed', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
    }
})

Refresh-TreeView
Close-LoadingWindow
$script:Window.Add_ContentRendered({
    [void]$script:Window.Activate()
})
[void]$script:Window.ShowDialog()
