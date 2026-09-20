from __future__ import annotations

import argparse
import ctypes
import os
import queue
import threading
from ctypes import wintypes
from dataclasses import dataclass
from pathlib import Path
import tkinter as tk
from tkinter import filedialog, messagebox, ttk

CHUNK_SIZE = 1024 * 1024


@dataclass(frozen=True)
class Signature:
    size: int
    mtime_ns: int


@dataclass
class MatchPair:
    relative_path: str
    path_a: Path
    path_b: Path
    size: int
    sig_a: Signature
    sig_b: Signature


def signature(path: Path) -> Signature:
    st = path.stat()
    return Signature(st.st_size, st.st_mtime_ns)


def format_size(value: int) -> str:
    if value >= 1024 ** 3:
        return f"{value / 1024 ** 3:.2f} GB"
    if value >= 1024 ** 2:
        return f"{value / 1024 ** 2:.2f} MB"
    if value >= 1024:
        return f"{value / 1024:.2f} KB"
    return f"{value} B"


def iter_files(root: Path):
    for current_root, dirs, files in os.walk(root, followlinks=False):
        current = Path(current_root)
        dirs[:] = [name for name in dirs if not (current / name).is_symlink()]
        for name in files:
            path = current / name
            if not path.is_symlink():
                yield path


def file_map(root: Path) -> dict[str, Path]:
    result: dict[str, Path] = {}
    for path in iter_files(root):
        rel = path.relative_to(root).as_posix()
        key = rel.casefold()
        if key in result:
            raise RuntimeError(f"Case-insensitive path collision: {rel}")
        result[key] = path
    return result


def nested(a: Path, b: Path) -> bool:
    try:
        a.relative_to(b)
        return True
    except ValueError:
        pass
    try:
        b.relative_to(a)
        return True
    except ValueError:
        return False


def files_equal(path_a: Path, path_b: Path, byte_progress=None) -> bool:
    with path_a.open("rb") as fa, path_b.open("rb") as fb:
        while True:
            a = fa.read(CHUNK_SIZE)
            b = fb.read(CHUNK_SIZE)
            if byte_progress:
                byte_progress(len(a) + len(b))
            if a != b:
                return False
            if not a:
                return True


def analyze(folder_a: Path, folder_b: Path, progress=None):
    folder_a = folder_a.resolve()
    folder_b = folder_b.resolve()
    if folder_a == folder_b:
        raise ValueError("Folder A and Folder B must be different.")
    if nested(folder_a, folder_b):
        raise ValueError("Folder A and Folder B must not contain one another.")

    if progress:
        progress("Scanning Folder A...", None, None)
    a_files = file_map(folder_a)
    if progress:
        progress("Scanning Folder B...", None, None)
    b_files = file_map(folder_b)

    candidates = []
    for key, b_path in b_files.items():
        a_path = a_files.get(key)
        if not a_path:
            continue
        sig_a, sig_b = signature(a_path), signature(b_path)
        if sig_a.size == sig_b.size:
            candidates.append((a_path, b_path, sig_a, sig_b))

    total_bytes = max(1, sum(a.size + b.size for _, _, a, b in candidates))
    processed = 0
    matches = []

    def add_bytes(count: int):
        nonlocal processed
        processed += count

    for index, (a_path, b_path, sig_a, sig_b) in enumerate(candidates, 1):
        rel = b_path.relative_to(folder_b).as_posix()
        if progress:
            progress(f"Comparing {index}/{len(candidates)}: {rel}", processed, total_bytes)
        before = processed
        equal = files_equal(a_path, b_path, add_bytes)
        if before == processed:  # empty files
            processed = min(total_bytes, processed + 1)
        if equal:
            matches.append(MatchPair(rel, a_path, b_path, sig_b.size, sig_a, sig_b))
        if progress:
            progress(f"Compared {index}/{len(candidates)}: {rel}", min(processed, total_bytes), total_bytes)

    return matches


class SHFILEOPSTRUCTW(ctypes.Structure):
    _fields_ = [
        ("hwnd", wintypes.HWND),
        ("wFunc", wintypes.UINT),
        ("pFrom", wintypes.LPCWSTR),
        ("pTo", wintypes.LPCWSTR),
        ("fFlags", wintypes.USHORT),
        ("fAnyOperationsAborted", wintypes.BOOL),
        ("hNameMappings", wintypes.LPVOID),
        ("lpszProgressTitle", wintypes.LPCWSTR),
    ]


def recycle_paths(paths: list[Path]) -> None:
    if os.name != "nt":
        raise RuntimeError("Recycle Bin deletion is available only on Windows.")
    FO_DELETE = 0x0003
    FOF_SILENT = 0x0004
    FOF_NOCONFIRMATION = 0x0010
    FOF_ALLOWUNDO = 0x0040
    FOF_NOERRORUI = 0x0400
    source = "\0".join(str(p) for p in paths) + "\0\0"
    op = SHFILEOPSTRUCTW()
    op.wFunc = FO_DELETE
    op.pFrom = source
    op.fFlags = FOF_SILENT | FOF_NOCONFIRMATION | FOF_ALLOWUNDO | FOF_NOERRORUI
    result = ctypes.windll.shell32.SHFileOperationW(ctypes.byref(op))
    if result != 0:
        raise OSError(result, f"Recycle Bin operation failed with code {result}.")
    if op.fAnyOperationsAborted:
        raise RuntimeError("Windows aborted the Recycle Bin operation.")


def delete_matches(matches: list[MatchPair], progress=None):
    deleted = []
    skipped = []
    total = max(1, len(matches))
    for index, pair in enumerate(matches, 1):
        if progress:
            progress(f"Recycling {index}/{len(matches)}: {pair.relative_path}", index - 1, total)
        try:
            if not pair.path_a.is_file() or not pair.path_b.is_file():
                skipped.append((pair, "One of the files no longer exists."))
                continue
            if signature(pair.path_a) != pair.sig_a:
                skipped.append((pair, "Folder A file changed after analysis."))
                continue
            if signature(pair.path_b) != pair.sig_b:
                skipped.append((pair, "Folder B file changed after analysis."))
                continue
            recycle_paths([pair.path_a, pair.path_b])
            deleted.append(pair)
        except Exception as exc:
            skipped.append((pair, str(exc)))
        if progress:
            progress(f"Processed {index}/{len(matches)}: {pair.relative_path}", index, total)
    return deleted, skipped


class App:
    def __init__(self, root: tk.Tk, initial_folder: str):
        self.root = root
        self.initial = str(Path(initial_folder).resolve()) if initial_folder and Path(initial_folder).is_dir() else str(Path.cwd())
        self.folder_a = tk.StringVar(value=self.initial)
        self.folder_b = tk.StringVar()
        self.status = tk.StringVar(value="Choose Folder B, then Analyze.")
        self.events: queue.Queue = queue.Queue()
        self.matches: list[MatchPair] = []
        self.analysis_key = None
        self.busy = False

        root.title("Identical File Cleaner")
        root.geometry("1080x690")
        root.minsize(820, 560)
        outer = ttk.Frame(root, padding=12)
        outer.pack(fill="both", expand=True)

        ttk.Label(outer, text="Identical File Cleaner", font=("Segoe UI", 18, "bold")).pack(anchor="w")
        ttk.Label(
            outer,
            text=(
                "Files at the same relative path are compared byte-for-byte. "
                "After preview, BOTH copies of confirmed matches are moved to the Windows Recycle Bin."
            ),
            wraplength=1020,
        ).pack(anchor="w", pady=(4, 10))

        form = ttk.Frame(outer)
        form.pack(fill="x")
        form.columnconfigure(1, weight=1)
        self.folder_row(form, 0, "Folder A:", self.folder_a, "Choose Folder A")
        self.folder_row(form, 1, "Folder B:", self.folder_b, "Choose Folder B")

        actions = ttk.Frame(outer)
        actions.pack(fill="x", pady=(8, 8))
        self.analyze_btn = ttk.Button(actions, text="Analyze identical files", command=self.start_analysis)
        self.analyze_btn.pack(side="left")
        self.delete_btn = ttk.Button(actions, text="Move both copies to Recycle Bin", command=self.start_delete, state="disabled")
        self.delete_btn.pack(side="left", padx=(8, 0))
        self.progress = ttk.Progressbar(actions, maximum=100)
        self.progress.pack(side="left", fill="x", expand=True, padx=(14, 8))
        ttk.Label(actions, textvariable=self.status).pack(side="left")

        table = ttk.Frame(outer)
        table.pack(fill="both", expand=True)
        self.tree = ttk.Treeview(table, columns=("path", "size"), show="headings", selectmode="browse")
        self.tree.heading("path", text="Identical relative path")
        self.tree.heading("size", text="Size of each copy")
        self.tree.column("path", width=760, anchor="w")
        self.tree.column("size", width=140, anchor="e")
        self.tree.pack(side="left", fill="both", expand=True)
        sb = ttk.Scrollbar(table, orient="vertical", command=self.tree.yview)
        sb.pack(side="right", fill="y")
        self.tree.configure(yscrollcommand=sb.set)

        details = ttk.LabelFrame(outer, text="Selected pair", padding=8)
        details.pack(fill="x", pady=(8, 0))
        self.detail = tk.Text(details, height=5, wrap="word", state="disabled")
        self.detail.pack(fill="x")
        self.tree.bind("<<TreeviewSelect>>", self.show_selected)

        self.folder_a.trace_add("write", lambda *_: self.invalidate())
        self.folder_b.trace_add("write", lambda *_: self.invalidate())
        root.after(100, self.poll)

    def folder_row(self, parent, row, label, variable, title):
        ttk.Label(parent, text=label).grid(row=row, column=0, sticky="w", padx=(0, 8), pady=5)
        ttk.Entry(parent, textvariable=variable).grid(row=row, column=1, sticky="ew", pady=5)

        def browse():
            current = variable.get().strip()
            start = current if current and Path(current).is_dir() else self.initial
            selected = filedialog.askdirectory(title=title, initialdir=start)
            if selected:
                variable.set(selected)

        ttk.Button(parent, text="Browse...", command=browse).grid(row=row, column=2, padx=(8, 0), pady=5)

    def key(self):
        return self.folder_a.get().strip(), self.folder_b.get().strip()

    def invalidate(self):
        if self.busy:
            return
        self.matches = []
        self.analysis_key = None
        self.delete_btn.configure(state="disabled")

    def busy_state(self, value):
        self.busy = value
        self.analyze_btn.configure(state="disabled" if value else "normal")
        if value:
            self.delete_btn.configure(state="disabled")
        elif self.matches and self.analysis_key == self.key():
            self.delete_btn.configure(state="normal")

    def post(self, text, current, total):
        self.events.put(("progress", text, current, total))

    def start_analysis(self):
        if self.busy:
            return
        a, b = Path(self.folder_a.get().strip()), Path(self.folder_b.get().strip())
        if not a.is_dir() or not b.is_dir():
            messagebox.showerror("Identical File Cleaner", "Choose two valid folders.")
            return
        key = self.key()
        self.busy_state(True)
        self.progress.configure(mode="indeterminate")
        self.progress.start(12)
        self.status.set("Scanning...")

        def worker():
            try:
                matches = analyze(a, b, self.post)
                self.events.put(("analysis", key, matches))
            except Exception as exc:
                self.events.put(("error", str(exc)))
        threading.Thread(target=worker, daemon=True).start()

    def start_delete(self):
        if self.busy or not self.matches or self.analysis_key != self.key():
            return
        total = sum(p.size for p in self.matches) * 2
        if not messagebox.askyesno(
            "Identical File Cleaner",
            f"Move BOTH copies of {len(self.matches)} identical pair(s) ({format_size(total)} total) to the Recycle Bin?\n\nFiles changed since analysis are skipped.",
            default=messagebox.NO,
        ):
            return
        matches = list(self.matches)
        self.busy_state(True)
        self.progress.stop()
        self.progress.configure(mode="determinate", value=0)
        self.status.set("Deleting...")

        def worker():
            try:
                deleted, skipped = delete_matches(matches, self.post)
                self.events.put(("deleted", deleted, skipped))
            except Exception as exc:
                self.events.put(("error", str(exc)))
        threading.Thread(target=worker, daemon=True).start()

    def poll(self):
        try:
            while True:
                event = self.events.get_nowait()
                kind = event[0]
                if kind == "progress":
                    _, text, current, total = event
                    self.status.set(text)
                    if current is None:
                        if str(self.progress["mode"]) != "indeterminate":
                            self.progress.configure(mode="indeterminate")
                            self.progress.start(12)
                    else:
                        self.progress.stop()
                        self.progress.configure(mode="determinate")
                        self.progress["value"] = 100 * current / max(1, total)
                elif kind == "analysis":
                    _, key, matches = event
                    self.progress.stop()
                    self.progress.configure(mode="determinate", value=100)
                    self.matches = matches
                    self.analysis_key = key
                    self.populate()
                    self.busy_state(False)
                    total = sum(p.size for p in matches) * 2
                    self.status.set(f"{len(matches)} identical pair(s), {format_size(total)} across both folders.")
                elif kind == "deleted":
                    _, deleted, skipped = event
                    self.progress.stop()
                    self.progress.configure(mode="determinate", value=100)
                    self.busy_state(False)
                    extra = ""
                    if skipped:
                        examples = "\n".join(f"- {p.relative_path}: {reason}" for p, reason in skipped[:8])
                        extra = f"\n\nSkipped {len(skipped)} pair(s):\n{examples}"
                    messagebox.showinfo("Identical File Cleaner", f"Recycled {len(deleted)} pair(s).{extra}")
                    self.matches = []
                    self.analysis_key = None
                    self.delete_btn.configure(state="disabled")
                    self.populate()
                    self.status.set("Deletion finished. Analyze again to refresh.")
                elif kind == "error":
                    _, text = event
                    self.progress.stop()
                    self.progress.configure(mode="determinate", value=0)
                    self.busy_state(False)
                    self.status.set("Failed.")
                    messagebox.showerror("Identical File Cleaner - Error", text)
        except queue.Empty:
            pass
        self.root.after(100, self.poll)

    def populate(self):
        for item in self.tree.get_children():
            self.tree.delete(item)
        for index, pair in enumerate(self.matches):
            self.tree.insert("", "end", iid=str(index), values=(pair.relative_path, format_size(pair.size)))
        self.set_detail("Select a pair to see both full paths.")

    def show_selected(self, _event):
        selected = self.tree.selection()
        if not selected:
            return
        pair = self.matches[int(selected[0])]
        self.set_detail(f"Folder A:\n{pair.path_a}\n\nFolder B:\n{pair.path_b}\n\nSize of each copy: {format_size(pair.size)}")

    def set_detail(self, value):
        self.detail.configure(state="normal")
        self.detail.delete("1.0", "end")
        self.detail.insert("1.0", value)
        self.detail.configure(state="disabled")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--initial-folder", default="")
    args = parser.parse_args()
    root = tk.Tk()
    App(root, args.initial_folder)
    root.mainloop()


if __name__ == "__main__":
    main()
