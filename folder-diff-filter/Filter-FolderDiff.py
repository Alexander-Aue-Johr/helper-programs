from __future__ import annotations

import argparse
import difflib
import os
import queue
import re
import shutil
import threading
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
import tkinter as tk
from tkinter import filedialog, messagebox, ttk


@dataclass(frozen=True)
class TextFile:
    text: str
    encoding: str
    bom: bytes


@dataclass(frozen=True)
class Signature:
    size: int
    mtime_ns: int


@dataclass
class FilePlan:
    relative_path: str
    kind: str
    in_rest: bool
    in_feature: bool
    matching_units: int
    other_units: int
    rest_preview: str
    feature_preview: str
    sig_a: Signature | None
    sig_b: Signature


def signature(path: Path) -> Signature:
    st = path.stat()
    return Signature(st.st_size, st.st_mtime_ns)


def read_text(path: Path) -> TextFile | None:
    data = path.read_bytes()
    candidates = []
    if data.startswith(b"\xef\xbb\xbf"):
        candidates.append((3, "utf-8", b"\xef\xbb\xbf"))
    elif data.startswith(b"\xff\xfe"):
        candidates.append((2, "utf-16-le", b"\xff\xfe"))
    elif data.startswith(b"\xfe\xff"):
        candidates.append((2, "utf-16-be", b"\xfe\xff"))
    else:
        if b"\x00" in data[:8192]:
            return None
        candidates.append((0, "utf-8", b""))

    for skip, encoding, bom in candidates:
        try:
            return TextFile(data[skip:].decode(encoding), encoding, bom)
        except UnicodeDecodeError:
            return None
    return None


def write_text(path: Path, text: str, template: TextFile) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(template.bom + text.encode(template.encoding))


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


def compile_patterns(expressions: list[str], regex_mode: bool):
    values = [v.strip() for v in expressions if v.strip()]
    if not values:
        raise ValueError("Enter at least one expression.")
    patterns = []
    for value in values:
        source = value if regex_mode else re.escape(value)
        try:
            patterns.append(re.compile(source, re.IGNORECASE))
        except re.error as exc:
            raise ValueError(f"Invalid regular expression {value!r}: {exc}") from exc
    return patterns


def unit_matches(patterns, old_lines: list[str], new_lines: list[str]) -> bool:
    # Deliberately inspect the changed lines only. The surrounding hunk does not
    # turn unrelated changes into matches.
    for line in old_lines + new_lines:
        if any(pattern.search(line) for pattern in patterns):
            return True
    return False


def change_units(tag, a_lines, b_lines, i1, i2, j1, j2):
    old = a_lines[i1:i2]
    new = b_lines[j1:j2]
    if tag == "insert":
        for line in new:
            yield [], [line]
        return
    if tag == "delete":
        for line in old:
            yield [line], []
        return
    if tag != "replace":
        raise RuntimeError(f"Unexpected diff opcode: {tag}")

    # SequenceMatcher can group several changed lines into one replace opcode.
    # Split that opcode again so a single feature line does not drag all of its
    # neighboring changed lines into the same output.
    paired = min(len(old), len(new))
    for index in range(paired):
        yield [old[index]], [new[index]]
    for line in old[paired:]:
        yield [line], []
    for line in new[paired:]:
        yield [], [line]


def filtered_versions(a: TextFile, b: TextFile, patterns):
    a_lines = a.text.splitlines(keepends=True)
    b_lines = b.text.splitlines(keepends=True)
    matcher = difflib.SequenceMatcher(a=a_lines, b=b_lines, autojunk=False)

    rest: list[str] = []
    feature: list[str] = []
    matching = 0
    other = 0

    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if tag == "equal":
            rest.extend(b_lines[j1:j2])
            feature.extend(b_lines[j1:j2])
            continue

        for old_lines, new_lines in change_units(tag, a_lines, b_lines, i1, i2, j1, j2):
            if unit_matches(patterns, old_lines, new_lines):
                matching += 1
                rest.extend(old_lines)       # feature edit removed -> restore A side
                feature.extend(new_lines)   # feature edit retained -> keep B side
            else:
                other += 1
                rest.extend(new_lines)      # unrelated edit retained
                feature.extend(old_lines)   # unrelated edit removed -> restore A side

    return "".join(rest), "".join(feature), matching, other


def preview(base: str, result: str, rel: str, limit: int = 100) -> str:
    if base == result:
        return "[No diff remains; file omitted from this output.]"
    lines = list(difflib.unified_diff(
        base.splitlines(keepends=True),
        result.splitlines(keepends=True),
        fromfile=f"A/{rel}",
        tofile=f"result/{rel}",
        n=3,
    ))
    if len(lines) > limit:
        lines = lines[:limit] + [f"\n[Preview truncated after {limit} diff lines.]\n"]
    return "".join(lines)


def compute_plan(folder_a: Path, folder_b: Path, a_path: Path | None, b_path: Path, patterns):
    rel = b_path.relative_to(folder_b).as_posix()
    sig_b = signature(b_path)
    sig_a = signature(a_path) if a_path else None

    if a_path and a_path.read_bytes() == b_path.read_bytes():
        return FilePlan(rel, "equal", False, False, 0, 0, "[No diff.]", "[No diff.]", sig_a, sig_b), None, None, None

    b_text = read_text(b_path)
    a_text = read_text(a_path) if a_path else TextFile("", "utf-8", b"")

    if b_text is not None and a_text is not None:
        rest, feature, matching, other = filtered_versions(a_text, b_text, patterns)
        return (
            FilePlan(
                rel,
                "text",
                rest != a_text.text,
                feature != a_text.text,
                matching,
                other,
                preview(a_text.text, rest, rel),
                preview(a_text.text, feature, rel),
                sig_a,
                sig_b,
            ),
            rest,
            feature,
            b_text,
        )

    # Binary/unknown encodings are atomic. Only the relative path is searchable;
    # arbitrary bytes are never decoded as text.
    matches = any(pattern.search(rel) for pattern in patterns)
    note = "[Binary/unsupported encoding; atomic file-level diff. Expressions match the relative path only.]"
    return (
        FilePlan(
            rel,
            "binary",
            not matches,
            matches,
            1 if matches else 0,
            0 if matches else 1,
            note if not matches else "[No diff remains in this output.]",
            note if matches else "[No diff remains in this output.]",
            sig_a,
            sig_b,
        ),
        None,
        None,
        None,
    )


def analyze(folder_a: Path, folder_b: Path, expressions: list[str], regex_mode: bool, progress=None):
    folder_a = folder_a.resolve()
    folder_b = folder_b.resolve()
    if folder_a == folder_b:
        raise ValueError("Folder A and Folder B must be different.")
    if nested(folder_a, folder_b):
        raise ValueError("Folder A and Folder B must not contain one another.")

    patterns = compile_patterns(expressions, regex_mode)
    if progress:
        progress("Scanning Folder A...", None, None)
    a_files = file_map(folder_a)
    if progress:
        progress("Scanning Folder B...", None, None)
    b_files = list(iter_files(folder_b))

    plans = []
    total = max(1, len(b_files))
    for index, b_path in enumerate(b_files, 1):
        rel = b_path.relative_to(folder_b).as_posix()
        if progress:
            progress(f"Comparing {rel}", index, total)
        a_path = a_files.get(rel.casefold())
        plan, _, _, _ = compute_plan(folder_a, folder_b, a_path, b_path, patterns)
        plans.append(plan)
    return plans


def validate_file_state(folder_a: Path, folder_b: Path, plan: FilePlan):
    b_path = folder_b / Path(plan.relative_path)
    if not b_path.is_file() or signature(b_path) != plan.sig_b:
        raise RuntimeError(f"Folder B changed after analysis: {plan.relative_path}")

    a_path = folder_a / Path(plan.relative_path)
    if plan.sig_a is None:
        if a_path.exists():
            raise RuntimeError(f"Folder A changed after analysis: {plan.relative_path}")
        return None, b_path

    if not a_path.is_file() or signature(a_path) != plan.sig_a:
        raise RuntimeError(f"Folder A changed after analysis: {plan.relative_path}")
    return a_path, b_path


def create_outputs(folder_a: Path, folder_b: Path, expressions, regex_mode, plans, progress=None):
    folder_a = folder_a.resolve()
    folder_b = folder_b.resolve()
    patterns = compile_patterns(expressions, regex_mode)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    rest_dir = folder_b.parent / f"{folder_b.name}__diff_without_matches_{stamp}"
    feature_dir = folder_b.parent / f"{folder_b.name}__diff_only_matches_{stamp}"
    if rest_dir.exists() or feature_dir.exists():
        raise RuntimeError("Generated output folder already exists. Run again.")
    rest_dir.mkdir(parents=True)
    feature_dir.mkdir(parents=True)

    active = [p for p in plans if p.in_rest or p.in_feature]
    try:
        for index, plan in enumerate(active, 1):
            if progress:
                progress(f"Writing {plan.relative_path}", index, max(1, len(active)))
            a_path, b_path = validate_file_state(folder_a, folder_b, plan)
            fresh, rest, feature, b_text = compute_plan(folder_a, folder_b, a_path, b_path, patterns)
            if (fresh.in_rest, fresh.in_feature, fresh.matching_units, fresh.other_units) != (
                plan.in_rest, plan.in_feature, plan.matching_units, plan.other_units
            ):
                raise RuntimeError(f"Diff changed after analysis: {plan.relative_path}")

            rel = Path(plan.relative_path)
            for enabled, target_root, content in (
                (plan.in_rest, rest_dir, rest),
                (plan.in_feature, feature_dir, feature),
            ):
                if not enabled:
                    continue
                target = target_root / rel
                target.parent.mkdir(parents=True, exist_ok=True)
                if plan.kind == "text" and content is not None and b_text is not None:
                    write_text(target, content, b_text)
                    shutil.copystat(b_path, target, follow_symlinks=False)
                else:
                    shutil.copy2(b_path, target)
        return rest_dir, feature_dir
    except Exception:
        shutil.rmtree(rest_dir, ignore_errors=True)
        shutil.rmtree(feature_dir, ignore_errors=True)
        raise


class App:
    def __init__(self, root: tk.Tk, initial_folder: str):
        self.root = root
        self.initial = str(Path(initial_folder).resolve()) if initial_folder and Path(initial_folder).is_dir() else str(Path.cwd())
        self.folder_a = tk.StringVar(value=self.initial)
        self.folder_b = tk.StringVar()
        self.regex_mode = tk.BooleanVar(master=root, value=False)
        self.status = tk.StringVar(value="Choose folders and expressions, then Analyze.")
        self.events: queue.Queue = queue.Queue()
        self.plans: list[FilePlan] = []
        self.analysis_key = None
        self.busy = False

        root.title("Folder Diff Filter")
        root.geometry("1180x780")
        root.minsize(900, 640)
        outer = ttk.Frame(root, padding=12)
        outer.pack(fill="both", expand=True)

        ttk.Label(outer, text="Folder Diff Filter", font=("Segoe UI", 18, "bold")).pack(anchor="w")
        ttk.Label(
            outer,
            text=(
                "Separates individual changed lines in Folder B relative to Folder A. "
                "Matching line-level edits go to the feature output; unrelated edits go to the complementary output."
            ),
            wraplength=1120,
        ).pack(anchor="w", pady=(4, 10))

        form = ttk.Frame(outer)
        form.pack(fill="x")
        form.columnconfigure(1, weight=1)
        self.folder_row(form, 0, "Folder A:", self.folder_a, "Choose Folder A")
        self.folder_row(form, 1, "Folder B:", self.folder_b, "Choose Folder B")

        ttk.Label(form, text="Expressions (one per line):").grid(row=2, column=0, sticky="nw", padx=(0, 8), pady=5)
        self.expr = tk.Text(form, height=5, wrap="none")
        self.expr.grid(row=2, column=1, columnspan=2, sticky="ew", pady=5)
        ttk.Checkbutton(
            form,
            text="Treat every expression as a regular expression (OR semantics)",
            variable=self.regex_mode,
            command=self.invalidate,
        ).grid(row=3, column=1, columnspan=2, sticky="w", pady=(0, 8))

        actions = ttk.Frame(outer)
        actions.pack(fill="x", pady=(2, 8))
        self.analyze_btn = ttk.Button(actions, text="Analyze / Refresh preview", command=self.start_analysis)
        self.analyze_btn.pack(side="left")
        self.create_btn = ttk.Button(actions, text="Create both filtered folders", command=self.start_create, state="disabled")
        self.create_btn.pack(side="left", padx=(8, 0))
        self.progress = ttk.Progressbar(actions, maximum=100)
        self.progress.pack(side="left", fill="x", expand=True, padx=(14, 8))
        ttk.Label(actions, textvariable=self.status).pack(side="left")

        notebook = ttk.Notebook(outer)
        notebook.pack(fill="both", expand=True)
        self.rest_tree, self.rest_preview = self.preview_tab(notebook, "Without matching lines")
        self.feature_tree, self.feature_preview = self.preview_tab(notebook, "Only matching lines")

        self.folder_a.trace_add("write", lambda *_: self.invalidate())
        self.folder_b.trace_add("write", lambda *_: self.invalidate())
        self.expr.bind("<<Modified>>", self.expr_modified)
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

    def preview_tab(self, notebook, title):
        frame = ttk.Frame(notebook, padding=8)
        notebook.add(frame, text=title)
        pane = ttk.Panedwindow(frame, orient="vertical")
        pane.pack(fill="both", expand=True)
        top = ttk.Frame(pane)
        bottom = ttk.Frame(pane)
        pane.add(top, weight=2)
        pane.add(bottom, weight=3)

        tree = ttk.Treeview(top, columns=("path", "matching", "other", "kind"), show="headings", selectmode="browse")
        for col, label, width in (
            ("path", "File", 650), ("matching", "Matching edits", 110),
            ("other", "Other edits", 100), ("kind", "Type", 90),
        ):
            tree.heading(col, text=label)
            tree.column(col, width=width, anchor="w" if col in ("path", "kind") else "e")
        tree.pack(side="left", fill="both", expand=True)
        sb = ttk.Scrollbar(top, orient="vertical", command=tree.yview)
        sb.pack(side="right", fill="y")
        tree.configure(yscrollcommand=sb.set)

        text = tk.Text(bottom, wrap="none", font=("Consolas", 10), state="disabled")
        text.pack(side="left", fill="both", expand=True)
        tsb = ttk.Scrollbar(bottom, orient="vertical", command=text.yview)
        tsb.pack(side="right", fill="y")
        text.configure(yscrollcommand=tsb.set)
        tree.bind("<<TreeviewSelect>>", lambda _e: self.show_preview(tree, text))
        return tree, text

    def expressions(self):
        return self.expr.get("1.0", "end").splitlines()

    def expr_modified(self, _event):
        if self.expr.edit_modified():
            self.expr.edit_modified(False)
            self.invalidate()

    def key(self):
        return (self.folder_a.get().strip(), self.folder_b.get().strip(), tuple(self.expressions()), bool(self.regex_mode.get()))

    def invalidate(self):
        if self.busy:
            return
        self.plans = []
        self.analysis_key = None
        self.create_btn.configure(state="disabled")

    def busy_state(self, value):
        self.busy = value
        self.analyze_btn.configure(state="disabled" if value else "normal")
        if value:
            self.create_btn.configure(state="disabled")
        elif self.plans and self.analysis_key == self.key():
            self.create_btn.configure(state="normal")

    def post(self, text, current, total):
        self.events.put(("progress", text, current, total))

    def start_analysis(self):
        if self.busy:
            return
        a, b = Path(self.folder_a.get().strip()), Path(self.folder_b.get().strip())
        if not a.is_dir() or not b.is_dir():
            messagebox.showerror("Folder Diff Filter", "Choose two valid folders.")
            return
        try:
            compile_patterns(self.expressions(), self.regex_mode.get())
        except Exception as exc:
            messagebox.showerror("Folder Diff Filter", str(exc))
            return

        key = self.key()
        expressions = self.expressions()
        regex_mode = self.regex_mode.get()
        self.busy_state(True)
        self.progress.configure(mode="indeterminate")
        self.progress.start(12)
        self.status.set("Starting analysis...")

        def worker():
            try:
                plans = analyze(a, b, expressions, regex_mode, self.post)
                self.events.put(("analysis", key, plans))
            except Exception as exc:
                self.events.put(("error", str(exc)))
        threading.Thread(target=worker, daemon=True).start()

    def start_create(self):
        if self.busy or not self.plans or self.analysis_key != self.key():
            return
        rest_count = sum(p.in_rest for p in self.plans)
        feature_count = sum(p.in_feature for p in self.plans)
        if not messagebox.askyesno(
            "Folder Diff Filter",
            f"Create both sparse outputs?\n\nRest: {rest_count} file(s)\nFeature: {feature_count} file(s)\n\nThe original folders are not modified.",
            default=messagebox.NO,
        ):
            return

        a = Path(self.folder_a.get().strip()).resolve()
        b = Path(self.folder_b.get().strip()).resolve()
        expressions = self.expressions()
        regex_mode = self.regex_mode.get()
        plans = list(self.plans)
        self.busy_state(True)
        self.progress.stop()
        self.progress.configure(mode="determinate", value=0)
        self.status.set("Creating outputs...")

        def worker():
            try:
                result = create_outputs(a, b, expressions, regex_mode, plans, self.post)
                self.events.put(("created", result))
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
                    _, key, plans = event
                    self.progress.stop()
                    self.progress.configure(mode="determinate", value=100)
                    self.plans = plans
                    self.analysis_key = key
                    self.populate()
                    self.busy_state(False)
                    self.status.set(f"Preview ready: {sum(p.in_rest for p in plans)} rest file(s), {sum(p.in_feature for p in plans)} feature file(s).")
                elif kind == "created":
                    _, paths = event
                    self.progress.stop()
                    self.progress.configure(mode="determinate", value=100)
                    self.busy_state(False)
                    self.status.set("Finished.")
                    messagebox.showinfo("Folder Diff Filter", f"Created:\n\n{paths[0]}\n\n{paths[1]}")
                elif kind == "error":
                    _, text = event
                    self.progress.stop()
                    self.progress.configure(mode="determinate", value=0)
                    self.busy_state(False)
                    self.status.set("Failed.")
                    messagebox.showerror("Folder Diff Filter - Error", text)
        except queue.Empty:
            pass
        self.root.after(100, self.poll)

    def populate(self):
        for tree in (self.rest_tree, self.feature_tree):
            for item in tree.get_children():
                tree.delete(item)
        for index, plan in enumerate(self.plans):
            values = (plan.relative_path, plan.matching_units, plan.other_units, plan.kind)
            if plan.in_rest:
                self.rest_tree.insert("", "end", iid=str(index), values=values)
            if plan.in_feature:
                self.feature_tree.insert("", "end", iid=str(index), values=values)
        self.set_text(self.rest_preview, "Select a file to preview its remaining diff.")
        self.set_text(self.feature_preview, "Select a file to preview its remaining diff.")

    def show_preview(self, tree, widget):
        selected = tree.selection()
        if not selected:
            return
        plan = self.plans[int(selected[0])]
        self.set_text(widget, plan.rest_preview if tree is self.rest_tree else plan.feature_preview)

    @staticmethod
    def set_text(widget, value):
        widget.configure(state="normal")
        widget.delete("1.0", "end")
        widget.insert("1.0", value)
        widget.configure(state="disabled")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--initial-folder", default="")
    args = parser.parse_args()
    root = tk.Tk()
    App(root, args.initial_folder)
    root.mainloop()


if __name__ == "__main__":
    main()
