# XML Context Formatter

This project adds a Windows Explorer context-menu entry that formats every `.xml` file in a folder using standard XML indentation.

## What it does

- Adds a `Format XML files in this folder` option to Windows Explorer.
- Works when right-clicking a folder background or a folder itself.
- Formats `.xml` files recursively in the selected folder.
- Prints each file being processed in the PowerShell window.
- Does not show any popup dialog.

## Files

- `Format-XmlFiles.ps1`: formats XML files in a target folder
- `Install-ContextMenu.ps1`: registers the Explorer context-menu entry for the current user
- `Uninstall-ContextMenu.ps1`: removes the Explorer context-menu entry

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
3. Click `Format XML files in this folder`.

Explorer opens a PowerShell window, prints each XML file as it is formatted, and keeps the window open when the script is finished.

## Remove

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Uninstall-ContextMenu.ps1
```

## Manual run

Run it in the current folder:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Format-XmlFiles.ps1 -Recurse
```

Or pass a specific folder:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Format-XmlFiles.ps1 -TargetFolder 'C:\path\to\folder' -Recurse
```
