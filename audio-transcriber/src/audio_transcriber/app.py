"""Tkinter front-end for the complete local transcription pipeline."""
from __future__ import annotations

import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import threading
import tkinter as tk
from tkinter import filedialog, messagebox, ttk

from .output import create_output
from .paths import REPO_ROOT, RUNNER
from .title import suggest_title
from .transcription import DEFAULT_VAD_THRESHOLD, MAX_VAD_THRESHOLD, MIN_VAD_THRESHOLD, media_duration
from .zip_recording import audio_entries, extract_audio

LANGUAGES = {
    "German": "de",
    "English": "en",
    "French": "fr",
    "Spanish": "es",
    "Italian": "it",
    "Portuguese": "pt",
    "Dutch": "nl",
    "Polish": "pl",
    "Russian": "ru",
    "Turkish": "tr",
    "Ukrainian": "uk",
    "Arabic": "ar",
    "Chinese": "zh",
    "Japanese": "ja",
    "Detect automatically": "auto",
}


class App:
    def __init__(self, root):
        self.root = root
        root.title("Audio Transcriber")
        root.geometry("780x540")
        root.minsize(640, 440)
        self.events = queue.Queue()
        self.cancelled = threading.Event()
        self.proc = None
        self.running = False
        self.output = None
        self.path = tk.StringVar(value=os.environ.get("AUDIO_TRANSCRIBER_INPUT", ""))
        self.language = tk.StringVar(value="German")
        self.vad_threshold = tk.DoubleVar(value=DEFAULT_VAD_THRESHOLD)
        self.title = tk.StringVar()
        self.status = tk.StringVar(value="Select an M4A or ZIP file and choose the spoken language.")

        frame = ttk.Frame(root, padding=18)
        frame.pack(fill="both", expand=True)
        frame.columnconfigure(0, weight=1)
        frame.rowconfigure(11, weight=1)
        ttk.Label(frame, text="Audio file or ZIP recording").grid(row=0, column=0, sticky="w")
        self.entry = ttk.Entry(frame, textvariable=self.path)
        self.entry.grid(row=1, column=0, sticky="ew", pady=(4, 12))
        self.browse = ttk.Button(frame, text="Choose M4A / ZIP …", command=self.choose)
        self.browse.grid(row=1, column=1, padx=(10, 0), pady=(4, 12))
        ttk.Label(frame, text="Spoken language").grid(row=2, column=0, sticky="w")
        self.combo = ttk.Combobox(frame, textvariable=self.language, values=list(LANGUAGES), state="readonly")
        self.combo.grid(row=3, column=0, sticky="w", pady=(4, 12))
        self.combo.bind("<MouseWheel>", lambda event: "break")
        ttk.Label(frame, text="Speech detection threshold (VAD)").grid(row=4, column=0, sticky="w")
        vad_row = ttk.Frame(frame)
        vad_row.grid(row=5, column=0, columnspan=2, sticky="ew", pady=(2, 12))
        vad_row.columnconfigure(0, weight=1)
        self.vad_scale = tk.Scale(
            vad_row,
            from_=MIN_VAD_THRESHOLD,
            to=MAX_VAD_THRESHOLD,
            resolution=0.05,
            orient="horizontal",
            variable=self.vad_threshold,
            showvalue=True,
            length=420,
        )
        self.vad_scale.grid(row=0, column=0, sticky="ew")
        ttk.Label(
            vad_row,
            text="Lower = more sensitive to quiet speech. faster-whisper default: 0.50",
        ).grid(row=1, column=0, sticky="w")

        ttk.Label(frame, text="Video title (optional; empty = suggest from frequent terms)").grid(
            row=6, column=0, columnspan=2, sticky="w"
        )
        self.title_entry = ttk.Entry(frame, textvariable=self.title)
        self.title_entry.grid(row=7, column=0, columnspan=2, sticky="ew", pady=(4, 12))
        ttk.Label(
            frame,
            text=(
                "Runs locally with Whisper large-v3. Creates TXT, SRT, and an MP4 title card.\n"
                "Results are saved next to the selected M4A or ZIP file."
            ),
        ).grid(row=8, column=0, columnspan=2, sticky="w")
        buttons = ttk.Frame(frame)
        buttons.grid(row=9, column=0, columnspan=2, sticky="w", pady=12)
        self.start_button = ttk.Button(buttons, text="Start conversion", command=self.start)
        self.start_button.pack(side="left")
        self.cancel_button = ttk.Button(buttons, text="Cancel", command=self.cancel, state="disabled")
        self.cancel_button.pack(side="left", padx=10)
        self.open_button = ttk.Button(buttons, text="Open output folder", command=self.open_output, state="disabled")
        self.open_button.pack(side="left")
        ttk.Label(frame, textvariable=self.status, wraplength=710).grid(
            row=10, column=0, columnspan=2, sticky="w", pady=(0, 8)
        )
        self.log = tk.Text(frame, height=10, wrap="word", state="disabled")
        self.log.grid(row=11, column=0, columnspan=2, sticky="nsew")
        root.protocol("WM_DELETE_WINDOW", self.close)
        root.after(150, self.poll)

    def choose(self):
        path = filedialog.askopenfilename(
            parent=self.root,
            title="Choose M4A or ZIP",
            filetypes=[
                ("Recordings (M4A and ZIP)", ("*.m4a", "*.zip")),
                ("ZIP files", "*.zip"),
                ("M4A audio files", "*.m4a"),
                ("All files", "*.*"),
            ],
        )
        if path:
            self.path.set(path)

    def choose_archive_entry(self, entries):
        if len(entries) == 1:
            return entries[0]
        dialog = tk.Toplevel(self.root)
        dialog.title("Choose recording from ZIP")
        dialog.geometry("650x300")
        dialog.transient(self.root)
        ttk.Label(dialog, text="Which recording should be processed?", padding=12).pack(anchor="w")
        listing = tk.Listbox(dialog, exportselection=False)
        listing.pack(fill="both", expand=True, padx=12)
        for _, name, size in entries:
            listing.insert("end", f"{name} ({size / 1024**2:.1f} MB)")
        listing.selection_set(0)
        selected = []

        def accept():
            if listing.curselection():
                selected.append(entries[listing.curselection()[0]])
                dialog.destroy()

        buttons = ttk.Frame(dialog, padding=12)
        buttons.pack(fill="x")
        ttk.Button(buttons, text="Use this recording", command=accept).pack(side="left")
        ttk.Button(buttons, text="Cancel", command=dialog.destroy).pack(side="right")
        listing.bind("<Double-Button-1>", lambda event: accept())
        dialog.grab_set()
        self.root.wait_window(dialog)
        return selected[0] if selected else None

    def start(self):
        source = Path(self.path.get().strip().strip('"')).expanduser()
        if not source.is_file() or source.suffix.lower() not in (".m4a", ".zip"):
            messagebox.showerror(
                "Choose a file", "Please select an existing M4A or ZIP file.", parent=self.root
            )
            return
        if len(self.title.get()) > 200:
            messagebox.showerror("Title too long", "Please use at most 200 characters for the title.", parent=self.root)
            return
        vad_threshold = round(float(self.vad_threshold.get()), 2)
        if not MIN_VAD_THRESHOLD <= vad_threshold <= MAX_VAD_THRESHOLD:
            messagebox.showerror(
                "Invalid VAD threshold",
                f"Choose a VAD threshold between {MIN_VAD_THRESHOLD:.2f} and {MAX_VAD_THRESHOLD:.2f}.",
                parent=self.root,
            )
            return

        archive_entry = None
        if source.suffix.lower() == ".zip":
            try:
                archive_entry = self.choose_archive_entry(audio_entries(source))
            except Exception as exc:
                messagebox.showerror("Could not open ZIP", str(exc), parent=self.root)
                return
            if archive_entry is None:
                return

        self.running = True
        self.output = None
        self.log.configure(state="normal")
        self.log.delete("1.0", "end")
        self.log.configure(state="disabled")
        self.cancelled.clear()
        for widget in (
            self.entry,
            self.browse,
            self.combo,
            self.vad_scale,
            self.title_entry,
            self.start_button,
            self.open_button,
        ):
            widget.configure(state="disabled")
        self.cancel_button.configure(state="normal")
        self.status.set("Checking audio file …")
        threading.Thread(
            target=self.work,
            args=(
                source.resolve(),
                LANGUAGES[self.language.get()],
                self.title.get().strip(),
                vad_threshold,
                archive_entry,
            ),
            daemon=True,
        ).start()

    def run_command(self, arguments):
        if self.cancelled.is_set():
            raise InterruptedError("Conversion cancelled.")
        env = dict(os.environ, PYTHONUTF8="1", PYTHONIOENCODING="utf-8", PYTHONPATH=str(REPO_ROOT / "src"))
        interpreter = Path(sys.executable)
        self.proc = subprocess.Popen(
            [str(interpreter), "-u", str(RUNNER), "_worker", *map(str, arguments)],
            cwd=REPO_ROOT,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
            creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0,
        )
        if self.cancelled.is_set():
            self.stop_process()
        for line in self.proc.stdout:
            if line.strip():
                self.events.put(("log", line.strip()))
        code = self.proc.wait()
        self.proc = None
        if self.cancelled.is_set():
            raise InterruptedError("Cancelled. Files already written remain in the output folder.")
        if code:
            raise RuntimeError(f"Processing failed (exit code {code}). See the log for details.")

    def work(self, source, language, title, vad_threshold, archive_entry=None):
        try:
            input_path = source
            if source.suffix.lower() == ".zip":
                entries = audio_entries(source)
                if archive_entry is None:
                    if len(entries) != 1:
                        raise ValueError("Please select a recording from the ZIP archive.")
                    archive_entry = entries[0]
                if archive_entry not in entries:
                    raise ValueError("The selected recording is no longer present in the ZIP archive.")
                self.output = create_output(source, language)
                self.events.put(("status", f"Extracting recording from ZIP: {archive_entry[1]}"))
                source = extract_audio(source, archive_entry, self.output / "source", self.cancelled)
            if self.cancelled.is_set():
                raise InterruptedError("Conversion cancelled.")

            duration = media_duration(source)
            if source == input_path:
                self.output = create_output(source, language)
            (self.output / "job.json").write_text(
                json.dumps(
                    {
                        "source": str(source),
                        "input": str(input_path),
                        "archive_member": archive_entry[1] if archive_entry else None,
                        "language": language,
                        "requested_title": title,
                        "vad_threshold": vad_threshold,
                    },
                    ensure_ascii=False,
                    indent=2,
                ),
                encoding="utf-8",
            )
            language_name = next(name for name, code in LANGUAGES.items() if code == language)
            self.events.put(
                (
                    "status",
                    f"Transcription is running – language: {language_name} ({duration / 60:.1f} minutes of audio). "
                    "Long recordings can take several hours.",
                )
            )
            self.run_command(
                [
                    "transcribe",
                    "--source",
                    source,
                    "--out",
                    self.output,
                    "--language",
                    language,
                    "--vad-threshold",
                    f"{vad_threshold:.2f}",
                ]
            )
            self.events.put(("status", "Reviewing transcript and subtitles …"))
            self.run_command(["finish", "--out", self.output])
            title = title or suggest_title(self.output, source.stem)
            self.events.put(("status", f"Creating title-card video: {title}"))
            self.run_command(["video", "--source", source, "--out", self.output, "--title", title])

            import av

            with av.open(str(self.output / f"{source.stem}.mp4")) as video:
                if not video.streams.audio or not video.streams.video or abs(video.duration / av.time_base - duration) > 2:
                    raise RuntimeError("Validation of the generated video failed.")
                next(video.decode(video=0))
            (self.output / "COMPLETED.txt").write_text(
                f"Conversion completed.\nTitle: {title}\n\n"
                "transcript.srt is UTF-8 and contains timestamps.\n"
                "Uncertainty markers are also visible in the subtitles.\n"
                "Raw output and review passages are stored alongside it.\n",
                encoding="utf-8",
            )
            self.events.put(("done", f"Done! Title: {title}\nResults: {self.output}"))
        except InterruptedError as exc:
            self.events.put(("cancelled", str(exc)))
        except Exception as exc:
            self.events.put(("error", str(exc)))

    def stop_process(self):
        process = self.proc
        if process is not None and process.poll() is None:
            if os.name == "nt":
                result = subprocess.run(
                    ["taskkill", "/PID", str(process.pid), "/T", "/F"],
                    capture_output=True,
                    creationflags=subprocess.CREATE_NO_WINDOW,
                )
                if result.returncode and process.poll() is None:
                    process.terminate()
            else:
                process.terminate()

    def cancel(self):
        self.cancelled.set()
        self.cancel_button.configure(state="disabled")
        self.status.set("Cancelling conversion …")
        threading.Thread(target=self.stop_process, daemon=True).start()

    def close(self):
        if self.running:
            if messagebox.askyesno("Conversion in progress", "Cancel the running conversion?", parent=self.root):
                self.cancel()
            return
        self.root.destroy()

    def open_output(self):
        if not self.output:
            return
        if os.name == "nt":
            os.startfile(str(self.output))
        elif sys.platform == "darwin":
            subprocess.Popen(["open", str(self.output)])
        else:
            subprocess.Popen(["xdg-open", str(self.output)])

    def poll(self):
        try:
            while True:
                kind, text = self.events.get_nowait()
                self.log.configure(state="normal")
                self.log.insert("end", text + "\n")
                if int(self.log.index("end-1c").split(".")[0]) > 500:
                    self.log.delete("1.0", "100.0")
                self.log.see("end")
                self.log.configure(state="disabled")
                if self.output:
                    try:
                        with (self.output / "verarbeitung.log").open("a", encoding="utf-8") as log:
                            log.write(text + "\n")
                    except OSError:
                        pass
                if kind != "log":
                    self.status.set(text)
                elif text.startswith("CHECKPOINT"):
                    try:
                        seconds = float(text.split()[1])
                        self.status.set(f"Transcript saved through minute {seconds / 60:.1f}. Continuing …")
                    except (ValueError, IndexError):
                        pass
                if kind in ("done", "error", "cancelled"):
                    self.running = False
                    for widget in (self.entry, self.browse, self.title_entry, self.start_button):
                        widget.configure(state="normal")
                    self.combo.configure(state="readonly")
                    self.vad_scale.configure(state="normal")
                    self.cancel_button.configure(state="disabled")
                    self.open_button.configure(state="normal" if self.output else "disabled")
                    if kind == "error":
                        messagebox.showerror("Conversion failed", text, parent=self.root)
        except queue.Empty:
            pass
        self.root.after(150, self.poll)


def main():
    root = tk.Tk()
    App(root)
    root.mainloop()
