# Folder Diff Filter

Compares Folder B with Folder A and separates the **individual changed lines** into two sparse outputs.

- `B__diff_without_matches_<timestamp>` keeps non-matching line-level edits.
- `B__diff_only_matches_<timestamp>` keeps matching line-level edits.

Enter multiple expressions, one per line. They use OR semantics. By default they are literal case-insensitive searches; regex mode treats every line as a Python regular expression.

The important detail is that matching happens on individual changed lines, not whole diff hunks. A multi-line replace block is split into small replacement/insertion/deletion units, so one identifiable feature line does not pull unrelated neighboring changes into the same output.

The dialog has an explicit **Analyze / Refresh preview** step. Each output has its own file list and selecting a file shows a unified-diff preview of exactly what would remain there. Only then can both output folders be created.

Folder A is prefilled with the Explorer folder used to launch the helper. Both Browse dialogs start there when their field is empty.

If a filtered text file has no difference to A anymore, it is omitted from that output. The original A and B folders are never modified.

Binary/unsupported files are atomic changes; their contents are not decoded and expressions can classify them only by relative path.
