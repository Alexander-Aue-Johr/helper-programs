# Identical File Cleaner

Shows one dialog immediately with Folder A, Folder B, preview, and progress.

- Folder A is prefilled with the Explorer folder used to launch the helper.
- Folder B starts empty.
- Both Browse dialogs start in that launch folder if their field is empty.
- `Analyze identical files` scans both trees and compares candidate files while progress is visible.
- The preview lists all identical pairs and shows both full paths for the selected row.
- `Move both copies to Recycle Bin` displays deletion progress and removes **both** copies.

Files are candidates only when they have the same relative path and size. They are then compared byte-for-byte in chunks, so this works for text and binary files without depending on encoding.

Before deletion, size and modification time are checked again. Files changed after analysis are skipped. Reparse-point/symlink directories are not traversed.
