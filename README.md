# Helper Programs

This repository collects small standalone Windows helper programs. Each helper lives in its own kebab-case subfolder with its own README and implementation files.

## Projects

- `csharp-comment-line-remover`: Explorer context-menu tool that recursively removes C# lines whose first non-whitespace characters are `//`.
- `source-context-exporter`: Explorer context-menu tool that exports selected source files from a folder as LLM-friendly Markdown.
- `xml-context-formatter`: Explorer context-menu tool that formats all `.xml` files in a folder.
- `identical-file-cleaner`: Explorer helper with preview and progress that finds byte-identical file pairs and recycles both copies.

## Install All Context Menus

Run this from PowerShell in the repository root:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-AllContextMenus.ps1
```

No admin rights are required because the registry entries are written to `HKCU` for the current user.

## Remove All Context Menus

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Uninstall-AllContextMenus.ps1
```

## Conventions

- Helper folders use kebab-case.
- Each helper has `README.md`, `Install-ContextMenu.ps1`, and `Uninstall-ContextMenu.ps1`.
- Text files are UTF-8 without BOM for good GitHub display and diffs.
- PowerShell scripts keep user-facing strings ASCII-only so Windows PowerShell 5.1 can run them reliably without a BOM.
