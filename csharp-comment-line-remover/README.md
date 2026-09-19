# C# Comment Line Remover

This project adds a Windows Explorer context-menu entry that recursively removes standalone `//` comment lines from `.cs` files.

## What it removes

A line is removed only when its first non-whitespace characters are `//`.

Removed examples:

```csharp
// comment
    // indented comment
\t// tab-indented comment
/// XML documentation comment
```

Untouched examples:

```csharp
var url = "https://example.org";
DoSomething(); // inline comment
var text = "// this is text";
```

In other words, the tool deliberately does **not** remove inline `//` sequences. It also does not remove `/* ... */` block comments.

## Files

- `Remove-CSharpCommentLines.ps1`: recursively edits `.cs` files in a target folder
- `Install-ContextMenu.ps1`: registers the Explorer context-menu entry for the current user
- `Uninstall-ContextMenu.ps1`: removes the Explorer context-menu entry

## Install

Run this from PowerShell in the project folder:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-ContextMenu.ps1
```

No admin rights are required because the registry entries are written to `HKCU`.

You can also install every helper in the repository from the repository root:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-AllContextMenus.ps1
```

## Use

After installation:

1. Open any folder in Windows Explorer.
2. Right-click the folder background or right-click a folder.
3. Click `Remove standalone C# comment lines`.
4. The PowerShell window lists changed files and prints a summary.

All `.cs` files below the selected folder are scanned recursively.

On Windows 11 this entry may appear under `Show more options`.

## Preview without changing files

Run the script manually with PowerShell's standard `-WhatIf` switch:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Remove-CSharpCommentLines.ps1 -TargetFolder 'C:\path\to\project' -WhatIf
```

## Manual run

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Remove-CSharpCommentLines.ps1 -TargetFolder 'C:\path\to\project'
```

## Remove

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Uninstall-ContextMenu.ps1
```

## Notes

The matching rule is intentionally textual and narrow: only full lines beginning with optional whitespace followed by `//` are removed. This avoids cutting URLs or inline comments out of code.
