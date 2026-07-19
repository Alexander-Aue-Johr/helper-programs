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

$TargetFolder = (Resolve-Path -LiteralPath $TargetFolder).Path

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

$script:NoExtensionKey = '<no-extension>'
$script:AllFileNodes = New-Object System.Collections.ArrayList
$script:AllDirectoryNodes = New-Object System.Collections.ArrayList
$script:ExtensionToFiles = @{}
$script:ExtensionToDirectories = @{}
$script:ExtensionEnabled = @{}
$script:ShowFiles = $false
$script:SuppressEvents = $false
$script:ProjectTree = $null
$script:ExtensionsPanel = $null
$script:StatusText = $null
$script:OkButton = $null
$script:ExportButton = $null
$script:CopyButton = $null
$script:CopyTopButton = $null
$script:CopyInlineButton = $null
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
    '.cs' = 'csharp'; '.fs' = 'fsharp'; '.vb' = 'vbnet'
    '.java' = 'java'; '.kt' = 'kotlin'; '.kts' = 'kotlin'; '.scala' = 'scala'
    '.c' = 'c'; '.h' = 'c'; '.cpp' = 'cpp'; '.cc' = 'cpp'; '.cxx' = 'cpp'; '.hpp' = 'cpp'; '.hh' = 'cpp'
    '.go' = 'go'; '.php' = 'php'; '.rb' = 'ruby'; '.swift' = 'swift'; '.dart' = 'dart'
    '.sh' = 'bash'; '.bash' = 'bash'; '.zsh' = 'zsh'; '.fish' = 'fish'; '.bat' = 'batch'; '.cmd' = 'batch'
    '.sql' = 'sql'; '.r' = 'r'; '.jl' = 'julia'; '.lua' = 'lua'; '.pl' = 'perl'
    '.ini' = 'ini'; '.cfg' = 'ini'; '.conf' = 'conf'; '.properties' = 'properties'; '.gradle' = 'gradle'
    '.txt' = 'text'; '.csv' = 'csv'; '.tsv' = 'tsv'; '.log' = 'text'
}

$script:DefaultOffExtensions = @{
    '.png' = $true; '.jpg' = $true; '.jpeg' = $true; '.gif' = $true; '.webp' = $true; '.bmp' = $true; '.tif' = $true; '.tiff' = $true; '.ico' = $true
    '.pdf' = $true; '.zip' = $true; '.7z' = $true; '.rar' = $true; '.tar' = $true; '.gz' = $true; '.bz2' = $true; '.xz' = $true
    '.exe' = $true; '.dll' = $true; '.pdb' = $true; '.so' = $true; '.dylib' = $true; '.lib' = $true; '.a' = $true; '.o' = $true; '.obj' = $true
    '.class' = $true; '.jar' = $true; '.war' = $true; '.ear' = $true; '.wasm' = $true
    '.mp3' = $true; '.wav' = $true; '.flac' = $true; '.mp4' = $true; '.mov' = $true; '.avi' = $true; '.mkv' = $true
    '.woff' = $true; '.woff2' = $true; '.ttf' = $true; '.otf' = $true
    '.db' = $true; '.sqlite' = $true; '.sqlite3' = $true; '.bin' = $true; '.dat' = $true
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

function Get-DefaultExtensionEnabled {
    param([Parameter(Mandatory = $true)][string]$Extension)
    if ($script:DefaultOffExtensions.ContainsKey($Extension)) {
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

function Get-RelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$BasePath,
        [Parameter(Mandatory = $true)][string]$FullPath
    )

    $baseFull = [System.IO.Path]::GetFullPath($BasePath)
    if (-not $baseFull.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $baseFull += [System.IO.Path]::DirectorySeparatorChar
    }

    $targetFull = [System.IO.Path]::GetFullPath($FullPath)
    $baseUri = New-Object System.Uri -ArgumentList $baseFull
    $targetUri = New-Object System.Uri -ArgumentList $targetFull
    $relative = [System.Uri]::UnescapeDataString($baseUri.MakeRelativeUri($targetUri).ToString())
    return $relative.Replace('/', '\').Replace('\', '/')
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
}

function New-FileNode {
    param(
        [Parameter(Mandatory = $true)][System.IO.FileInfo]$FileInfo,
        [Parameter(Mandatory = $true)][object]$Parent
    )

    Update-ScanProgress -Path $FileInfo.FullName
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
    }

    [void]$script:AllFileNodes.Add($node)
    Add-ExtensionIndex -Extension $extension -FileNode $node
    return $node
}

function New-DirectoryNode {
    param(
        [Parameter(Mandatory = $true)][string]$FullPath,
        [object]$Parent = $null
    )

    $directoryInfo = Get-Item -LiteralPath $FullPath -Force
    Update-ScanProgress -Path $directoryInfo.FullName -Force:($Parent -eq $null)
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
        TotalFiles     = 0
        SizeBytes      = [Int64]0
        ExtensionSet   = (New-StringSet)
        UiItem         = $null
        CheckBox       = $null
        ScanError      = $null
        IsReparsePoint = $isReparsePoint
    }

    [void]$script:AllDirectoryNodes.Add($node)

    if ($isReparsePoint -and $Parent -ne $null) {
        $node.ScanError = 'Reparse point/junction was not followed recursively.'
        return $node
    }

    try {
        $items = @(Get-ChildItem -LiteralPath $directoryInfo.FullName -Force -ErrorAction Stop | Sort-Object -Property @{ Expression = { $_.PSIsContainer }; Descending = $true }, Name)
        foreach ($item in $items) {
            if ($item.PSIsContainer) {
                if (Test-FolderIgnored -DirectoryInfo $item) {
                    $script:IgnoredDirectoryCount++
                    Update-ScanProgress -Path ("Ignored folder: {0}" -f $item.FullName)
                    continue
                }

                $child = New-DirectoryNode -FullPath $item.FullName -Parent $node
            }
            else {
                $child = New-FileNode -FileInfo $item -Parent $node
            }

            [void]$node.Children.Add($child)
            $node.TotalFiles += $child.TotalFiles
            $node.SizeBytes += $child.SizeBytes
            foreach ($extension in $child.ExtensionSet) {
                [void]$node.ExtensionSet.Add($extension)
            }
        }
    }
    catch {
        $node.ScanError = $_.Exception.Message
    }

    return $node
}

function Index-DirectoryExtensions {
    param([Parameter(Mandatory = $true)][object]$Node)

    if (-not $Node.IsDirectory) { return }

    foreach ($extension in $Node.ExtensionSet) {
        if (-not $script:ExtensionToDirectories.ContainsKey($extension)) {
            $script:ExtensionToDirectories[$extension] = New-StringSet
        }
        [void]$script:ExtensionToDirectories[$extension].Add($Node.FullPath)
    }

    foreach ($child in $Node.Children) {
        if ($child.IsDirectory) {
            Index-DirectoryExtensions -Node $child
        }
    }
}

function Set-SubtreeIncluded {
    param(
        [Parameter(Mandatory = $true)][object]$Node,
        [Parameter(Mandatory = $true)][bool]$Included
    )

    $Node.Included = $Included
    foreach ($child in $Node.Children) {
        Set-SubtreeIncluded -Node $child -Included $Included
    }
}

function Update-SelectionState {
    param([Parameter(Mandatory = $true)][object]$Node)

    if (-not $Node.IsDirectory) {
        $Node.SelectionState = [bool]$Node.Included
        return $Node.SelectionState
    }

    if (-not $Node.Included) {
        $Node.SelectionState = $false
        return $false
    }

    $allChildrenSelected = $true
    foreach ($child in $Node.Children) {
        $childState = Update-SelectionState -Node $child
        if ($childState -ne $true) {
            $allChildrenSelected = $false
        }
    }

    if ($allChildrenSelected) {
        $Node.SelectionState = $true
        return $true
    }

    $Node.SelectionState = $null
    return $null
}

function Test-FileSelectedByTree {
    param([Parameter(Mandatory = $true)][object]$FileNode)

    if ($FileNode.IsDirectory) { return $false }
    if (-not $FileNode.Included) { return $false }

    $parent = $FileNode.Parent
    while ($parent -ne $null) {
        if (-not $parent.Included) { return $false }
        $parent = $parent.Parent
    }

    return $true
}

function Test-FileSelectedForExport {
    param([Parameter(Mandatory = $true)][object]$FileNode)

    if (-not (Test-FileSelectedByTree -FileNode $FileNode)) { return $false }
    if (-not $script:ExtensionEnabled.ContainsKey($FileNode.Extension)) { return $true }
    return [bool]$script:ExtensionEnabled[$FileNode.Extension]
}

function Get-SelectedFiles {
    $list = New-Object System.Collections.ArrayList
    foreach ($fileNode in $script:AllFileNodes) {
        if (Test-FileSelectedForExport -FileNode $fileNode) {
            [void]$list.Add($fileNode)
        }
    }
    return @($list | Sort-Object RelPath)
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

function Append-LineSafe {
    param(
        [Parameter(Mandatory = $true)][System.Text.StringBuilder]$StringBuilder,
        [string]$Text = ''
    )
    [void]$StringBuilder.AppendLine($Text)
}

function New-SourceContextMarkdown {
    param(
        [Parameter(Mandatory = $true)][object[]]$Files,
        [Parameter(Mandatory = $true)][bool]$IncludeLineNumbers
    )

    $sb = New-Object System.Text.StringBuilder
    Append-LineSafe -StringBuilder $sb -Text '# Source Code Context'
    Append-LineSafe -StringBuilder $sb
    Append-LineSafe -StringBuilder $sb -Text ('Root: `{0}`' -f $TargetFolder)
    Append-LineSafe -StringBuilder $sb -Text ('Generated: {0:yyyy-MM-dd HH:mm:ss}' -f (Get-Date))
    Append-LineSafe -StringBuilder $sb -Text ('Files: {0}' -f $Files.Count)
    Append-LineSafe -StringBuilder $sb -Text ('Line numbers: {0}' -f $(if ($IncludeLineNumbers) { 'yes' } else { 'no' }))
    Append-LineSafe -StringBuilder $sb
    Append-LineSafe -StringBuilder $sb -Text 'This text contains selected source files exported from the chosen directory for LLM review.'
    Append-LineSafe -StringBuilder $sb -Text 'Paths are relative to the export directory.'
    Append-LineSafe -StringBuilder $sb
    Append-LineSafe -StringBuilder $sb -Text '## File Manifest'

    foreach ($file in $Files) {
        Append-LineSafe -StringBuilder $sb -Text ('- `{0}`' -f $file.RelPath)
    }

    Append-LineSafe -StringBuilder $sb
    Append-LineSafe -StringBuilder $sb -Text '---'

    foreach ($file in $Files) {
        $language = Get-LanguageForNode -FileNode $file
        Append-LineSafe -StringBuilder $sb
        Append-LineSafe -StringBuilder $sb -Text ('## File: `{0}`' -f $file.RelPath)
        Append-LineSafe -StringBuilder $sb
        Append-LineSafe -StringBuilder $sb -Text ($script:Fence + $language)

        try {
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

    $selectedFiles = @(Get-SelectedFiles)
    if ($selectedFiles.Count -eq 0) {
        [System.Windows.MessageBox]::Show($script:Window, 'No file is selected for copy.', 'Source Context Exporter', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
        return $false
    }

    $markdown = New-SourceContextMarkdown -Files $selectedFiles -IncludeLineNumbers $IncludeLineNumbers
    [void](Set-ClipboardTextReliable -Text $markdown)

    [System.Windows.MessageBox]::Show($script:Window, ('Copied {0} files to the clipboard.' -f $selectedFiles.Count), 'Source Context Exporter', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
    return $true
}
function Collect-ExpandedPaths {
    param(
        [Parameter(Mandatory = $true)][object]$Node,
        [Parameter(Mandatory = $true)][hashtable]$Expanded
    )

    if ($Node.UiItem -ne $null -and $Node.UiItem.IsExpanded) {
        $Expanded[$Node.FullPath] = $true
    }

    foreach ($child in $Node.Children) {
        if ($child.IsDirectory) {
            Collect-ExpandedPaths -Node $child -Expanded $Expanded
        }
    }
}

function Restore-ExpandedPaths {
    param(
        [Parameter(Mandatory = $true)][object]$Node,
        [Parameter(Mandatory = $true)][hashtable]$Expanded
    )

    if ($Node.UiItem -ne $null) {
        if ($Node.Parent -eq $null) {
            $Node.UiItem.IsExpanded = $true
        }
        elseif ($Node.Included -and $Expanded.ContainsKey($Node.FullPath)) {
            $Node.UiItem.IsExpanded = $true
        }
    }

    foreach ($child in $Node.Children) {
        if ($child.IsDirectory -and $child.UiItem -ne $null) {
            Restore-ExpandedPaths -Node $child -Expanded $Expanded
        }
    }
}

function New-HeaderStack {
    param([Parameter(Mandatory = $true)][object]$Node)

    $panel = New-Object System.Windows.Controls.StackPanel
    $panel.Orientation = [System.Windows.Controls.Orientation]::Horizontal

    $checkBox = New-Object System.Windows.Controls.CheckBox
    $checkBox.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $checkBox.Margin = New-Object System.Windows.Thickness -ArgumentList 0, 0, 6, 0
    $checkBox.IsThreeState = [bool]$Node.IsDirectory
    $checkBox.IsChecked = $Node.SelectionState
    $checkBox.Tag = $Node
    $checkBox.ToolTip = 'Uncheck to remove this item and all child items from the export.'

    $checkBox.Add_Click({
        param($sender, $eventArgs)
        if ($script:SuppressEvents) { return }

        $node = $sender.Tag
        $desired = ($sender.IsChecked -eq $true)
        if ($node.IsDirectory) {
            Set-SubtreeIncluded -Node $node -Included $desired
        }
        else {
            $node.Included = $desired
        }

        Refresh-TreeView -PreserveExpansion
    })

    $icon = New-Object System.Windows.Controls.TextBlock
    $icon.Margin = New-Object System.Windows.Thickness -ArgumentList 0, 0, 5, 0
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
        $metaText = ('{0} files | {1} extensions' -f $Node.TotalFiles, $Node.ExtensionSet.Count)
        if ($Node.ScanError) {
            $metaText += ' | scan note'
            $metaBlock.Foreground = $script:ErrorBrush
            $metaBlock.ToolTip = $Node.ScanError
        }
        $metaBlock.Text = $metaText
    }
    else {
        $metaBlock.Text = ('{0} | {1}' -f (Format-ExtensionLabel -Extension $Node.Extension), (Format-Size -Bytes $Node.SizeBytes))
    }

    [void]$panel.Children.Add($checkBox)
    [void]$panel.Children.Add($icon)
    [void]$panel.Children.Add($nameBlock)
    [void]$panel.Children.Add($metaBlock)

    $Node.CheckBox = $checkBox
    return $panel
}

function New-TreeViewItemForNode {
    param([Parameter(Mandatory = $true)][object]$Node)

    $item = New-Object System.Windows.Controls.TreeViewItem
    $item.Header = New-HeaderStack -Node $Node
    $item.Tag = $Node.FullPath
    $item.Margin = New-Object System.Windows.Thickness -ArgumentList 0, 1, 0, 1
    $Node.UiItem = $item

    if ($Node.IsDirectory -and $Node.Included) {
        foreach ($child in $Node.Children) {
            if ($child.IsDirectory) {
                [void]$item.Items.Add((New-TreeViewItemForNode -Node $child))
            }
            elseif ($script:ShowFiles) {
                [void]$item.Items.Add((New-TreeViewItemForNode -Node $child))
            }
        }
    }

    return $item
}

function Update-Status {
    $selectedFiles = @(Get-SelectedFiles)

    $activeExtensionCount = 0
    foreach ($extension in $script:ExtensionToFiles.Keys) {
        $hasSelectedTreeFile = $false
        foreach ($fileNode in $script:ExtensionToFiles[$extension]) {
            if (Test-FileSelectedByTree -FileNode $fileNode) {
                $hasSelectedTreeFile = $true
                break
            }
        }
        if ($hasSelectedTreeFile) {
            $activeExtensionCount++
        }
    }

    if ($script:StatusText -ne $null) {
        $script:StatusText.Text = ('{0} of {1} files selected for export | {2} extensions in the current selection' -f $selectedFiles.Count, $script:AllFileNodes.Count, $activeExtensionCount)
    }

    $hasSelectedFiles = ($selectedFiles.Count -gt 0)

    if ($script:OkButton -ne $null) {
        $script:OkButton.IsEnabled = $hasSelectedFiles
    }

    if ($script:ExportButton -ne $null) {
        $script:ExportButton.IsEnabled = $hasSelectedFiles
    }

    if ($script:CopyButton -ne $null) {
        $script:CopyButton.IsEnabled = $hasSelectedFiles
    }

    if ($script:CopyTopButton -ne $null) {
        $script:CopyTopButton.IsEnabled = $hasSelectedFiles
    }

    if ($script:CopyInlineButton -ne $null) {
        $script:CopyInlineButton.IsEnabled = $hasSelectedFiles
    }
}

function Update-ExtensionPanel {
    if ($script:ExtensionsPanel -eq $null) { return }

    $script:ExtensionsPanel.Children.Clear()
    $counts = @{}

    foreach ($extension in $script:ExtensionToFiles.Keys) {
        $count = 0
        foreach ($fileNode in $script:ExtensionToFiles[$extension]) {
            if (Test-FileSelectedByTree -FileNode $fileNode) {
                $count++
            }
        }
        if ($count -gt 0) {
            $counts[$extension] = $count
        }
    }

    if ($counts.Count -eq 0) {
        $emptyText = New-Object System.Windows.Controls.TextBlock
        $emptyText.Text = 'No file extensions in the current selection.'
        $emptyText.Foreground = $script:MutedBrush
        [void]$script:ExtensionsPanel.Children.Add($emptyText)
        return
    }

    foreach ($extension in ($counts.Keys | Sort-Object)) {
        if (-not $script:ExtensionEnabled.ContainsKey($extension)) {
            $script:ExtensionEnabled[$extension] = Get-DefaultExtensionEnabled -Extension $extension
        }

        $checkBox = New-Object System.Windows.Controls.CheckBox
        $checkBox.Margin = New-Object System.Windows.Thickness -ArgumentList 0, 0, 14, 8
        $checkBox.Padding = New-Object System.Windows.Thickness -ArgumentList 6, 2, 6, 2
        $checkBox.Tag = $extension
        $checkBox.IsChecked = [bool]$script:ExtensionEnabled[$extension]
        $checkBox.Content = ('{0} ({1})' -f (Format-ExtensionLabel -Extension $extension), $counts[$extension])

        $dirCount = 0
        if ($script:ExtensionToDirectories.ContainsKey($extension)) {
            $dirCount = $script:ExtensionToDirectories[$extension].Count
        }
        $checkBox.ToolTip = ('{0} files in the current selection. The full scan found this extension in {1} folders.' -f $counts[$extension], $dirCount)

        $checkBox.Add_Click({
            param($sender, $eventArgs)
            if ($script:SuppressEvents) { return }
            $extensionKey = [string]$sender.Tag
            $script:ExtensionEnabled[$extensionKey] = ($sender.IsChecked -eq $true)
            Update-Status
        })

        [void]$script:ExtensionsPanel.Children.Add($checkBox)
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
        [void](Update-SelectionState -Node $script:RootNode)
        $script:ProjectTree.Items.Clear()
        [void]$script:ProjectTree.Items.Add((New-TreeViewItemForNode -Node $script:RootNode))
        Restore-ExpandedPaths -Node $script:RootNode -Expanded $expanded
    }
    finally {
        $script:SuppressEvents = $false
    }

    Update-ExtensionPanel
    Update-Status
}

$script:MutedBrush = New-Brush '#667085'
$script:TextBrush = New-Brush '#1F2937'
$script:ErrorBrush = New-Brush '#B42318'

Read-ExporterConfiguration

Show-LoadingWindow -Status 'Opening Source Context Exporter...' -Detail $TargetFolder
try {
    Update-LoadingWindow -Status 'Scanning folder tree...' -Detail ("{0}`r`nIgnored folder names loaded: {1}" -f $TargetFolder, $script:IgnoredFolderNames.Count) -Force
    $script:RootNode = New-DirectoryNode -FullPath $TargetFolder -Parent $null

    Update-LoadingWindow -Status 'Indexing file extensions...' -Detail ('{0} files found' -f $script:AllFileNodes.Count) -Force
    Index-DirectoryExtensions -Node $script:RootNode

    Update-LoadingWindow -Status 'Building dialog...' -Detail ('{0} files found, {1} folders ignored by config' -f $script:AllFileNodes.Count, $script:IgnoredDirectoryCount) -Force
}
catch {
    Close-LoadingWindow
    throw
}

$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Source Context Exporter"
        Width="1040" Height="780" MinWidth="820" MinHeight="620"
        WindowStartupLocation="CenterScreen"
        Background="#F7F8FC"
        FontFamily="Segoe UI"
        ResizeMode="CanResizeWithGrip">
    <Grid Margin="14">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto" />
            <RowDefinition Height="*" />
            <RowDefinition Height="138" />
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
                    <TextBlock Text="The initial scan skips configured ignored folders, then reads folder structure, file names, and extensions only. File contents are read during export." Margin="0,4,0,0" Foreground="#667085" TextWrapping="Wrap" />
                </StackPanel>
                <StackPanel Grid.Column="1" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="16,0,0,0">
                    <Button Name="CopyTopButton" Content="In Zwischenablage kopieren" MinWidth="160" Padding="12,7" Margin="0,0,8,0" />
                    <Button Name="ToggleFilesButton" Content="Show files" MinWidth="138" Padding="12,7" />
                </StackPanel>
            </Grid>
        </Border>

        <GroupBox Grid.Row="1" Header="Folder tree" Background="White" BorderBrush="#EAECF0" Padding="8" Margin="0,0,0,10">
            <TreeView Name="ProjectTree" BorderThickness="0" Background="White" ScrollViewer.HorizontalScrollBarVisibility="Auto" ScrollViewer.VerticalScrollBarVisibility="Auto" />
        </GroupBox>

        <GroupBox Grid.Row="2" Header="Extensions in the current selection (checked = export)" Background="White" BorderBrush="#EAECF0" Padding="10" Margin="0,0,0,10">
            <DockPanel>
                <TextBlock DockPanel.Dock="Top" Text="Known binary formats start unchecked. When folders are unchecked, extensions that only occur there disappear." Foreground="#667085" Margin="0,0,0,8" TextWrapping="Wrap" />
                <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                    <WrapPanel Name="ExtensionsPanel" />
                </ScrollViewer>
            </DockPanel>
        </GroupBox>

        <Border Grid.Row="3" Background="White" CornerRadius="12" Padding="12" Margin="0,0,0,10" BorderBrush="#EAECF0" BorderThickness="1">
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto" />
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
                <Button Name="CopyInlineButton" Grid.Row="2" Grid.Column="0" Grid.ColumnSpan="3" Content="In Zwischenablage kopieren" HorizontalAlignment="Right" MinWidth="220" Padding="12,7" Margin="0,10,0,0" />
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
                <Button Name="CopyButton" Content="In Zwischenablage kopieren" MinWidth="160" Padding="12,7" Margin="0,0,8,0" />
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
$script:ExtensionsPanel = $script:Window.FindName('ExtensionsPanel')
$script:StatusText = $script:Window.FindName('StatusText')
$script:OkButton = $script:Window.FindName('OkButton')
$script:ExportButton = $script:Window.FindName('ExportButton')
$script:CopyButton = $script:Window.FindName('CopyButton')
$script:CopyTopButton = $script:Window.FindName('CopyTopButton')
$script:CopyInlineButton = $script:Window.FindName('CopyInlineButton')
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

$script:CopyButton.Add_Click($copyToClipboardHandler)
$script:CopyTopButton.Add_Click($copyToClipboardHandler)
$script:CopyInlineButton.Add_Click($copyToClipboardHandler)
$script:OkButton.Add_Click($copyToClipboardHandler)

$script:ExportButton.Add_Click({
    param($sender, $eventArgs)

    try {
        $selectedFiles = @(Get-SelectedFiles)
        if ($selectedFiles.Count -eq 0) {
            [System.Windows.MessageBox]::Show($script:Window, 'No file is selected for export.', 'Source Context Exporter', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
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
        $markdown = New-SourceContextMarkdown -Files $selectedFiles -IncludeLineNumbers $includeLineNumbers
        $utf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList $false
        [System.IO.File]::WriteAllText($outputPath, $markdown, $utf8NoBom)

        $clipboardStatus = 'and copied to the clipboard'
        try {
            [void](Set-ClipboardTextReliable -Text $markdown)
        }
        catch {
            $clipboardStatus = 'saved; clipboard could not be set: ' + $_.Exception.Message
        }

        $message = ('Export complete: {0} files were written to`r`n{1}`r`n{2}.' -f $selectedFiles.Count, $outputPath, $clipboardStatus)
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
