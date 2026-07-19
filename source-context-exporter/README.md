# Source Context Exporter

This project adds a Windows Explorer context-menu entry that opens a PowerShell/WPF dialog for exporting selected source files from a folder as LLM-friendly Markdown.

## What it does

- Adds an `Export source context...` option to Windows Explorer.
- Works when right-clicking a folder background or a folder itself.
- Shows a loading dialog immediately, skips configured ignored folders, then scans folder structure, file names, and file extensions before export.
- Lets you include or exclude folders, files, and extensions.
- Starts known binary formats unchecked.
- Can copy the current selection directly to the clipboard or write it to a Markdown file and copy it at the same time.

## Files

- `Export-SourceContext.ps1`: main WPF dialog and export logic
- `Install-ContextMenu.ps1`: registers the Explorer context-menu entry for the current user
- `Uninstall-ContextMenu.ps1`: removes the Explorer context-menu entry
- `SourceContext.ico`: optional context-menu icon
- `source-context-exporter.config.json`: ignored-folder configuration

## Configuration

Edit `source-context-exporter.config.json` to define folder names that should always be skipped before scanning. Entries are matched by folder name, case-insensitively. The default list includes `.venv`.

```json
{
  "ignoredFolderNames": [
    ".git",
    ".venv",
    "node_modules"
  ]
}
```

## Install

Run this from PowerShell in the project folder:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-ContextMenu.ps1
```

No admin rights are required because the registry entries are written to `HKCU`.

If you installed an older version of the context menu already, run the install script again to update the registered command.

## Use

After installation:

1. Open any folder in Windows Explorer.
2. Right-click the folder background or right-click a folder.
3. Click `Export source context...`.
4. Choose folders, files, and extensions in the dialog.
5. Click `In Zwischenablage kopieren` for clipboard-only export, or `Datei exportieren` to write a Markdown file and copy it.

On Windows 11 this entry may appear under `Show more options`.

## Remove

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Uninstall-ContextMenu.ps1
```

## Manual run

Run it in the current folder:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\Export-SourceContext.ps1
```

Or pass a specific folder:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\Export-SourceContext.ps1 -TargetFolder 'C:\path\to\folder'
```

## Notes

This tool needs no compilation and no external packages. It uses Windows PowerShell 5.1 and WPF, which are available on normal Windows systems.

Reparse points and junctions are not followed recursively to avoid loops and unexpectedly large linked directories.