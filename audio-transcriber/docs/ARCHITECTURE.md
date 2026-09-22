# Architecture

`run.py` is both the bootstrapper and the single public application entry point. Until `.venv` has been created and activated, it must import only Python's standard library.

The GUI process stays responsive. Long-running conversion work runs in a separate Python process through the internal `run.py _worker ...` command. This allows **Cancel** to terminate the complete worker process tree on Windows.

## Launch modes

- `gui` prepares Python dependencies, opens the Tkinter UI, and waits for explicit user input.
- `bootstrap` prepares only `.venv` and locked Python dependencies. The Explorer launcher uses this mode before opening the GUI.
- `setup` additionally downloads or validates the pinned Whisper model and is intended for explicit pre-warming.
- `_worker` is internal and performs transcription, review, or video creation.

Explorer context launches communicate the selected source path through `AUDIO_TRANSCRIBER_INPUT`. There is deliberately no auto-start environment variable: opening the GUI must never start a conversion.

## Internal modules

- `app.py` – Tkinter dialog and orchestration.
- `model_manager.py` – pinned local Whisper model.
- `transcription.py` – ten-minute Whisper checkpoints and raw exports.
- `review.py` – quality markers and final TXT/SRT output.
- `subtitle_timing.py` – bounds invalid model timestamps to the media duration.
- `video.py` – title card and MP4 creation.
- `zip_recording.py` – safe selection/extraction of one M4A file from a ZIP archive.
- `output.py` – unique result directory next to the selected source file.

The model is pinned to revision `edaa852ec7e145841d8ffdb056a99866b5f0a478`. On first use, `model.bin` is validated once with SHA-256 and a marker file is written. Later starts can use the marker and file size instead of hashing roughly 3 GB every time.

## Output contract

The output schema uses English names consistently: `job.json`, `source/`, `chunks/`, `segments.jsonl`, `transcript*.txt`, `transcript*.srt`, `timing_corrections.json`, `review_passages.txt`, `review.json`, `title.*`, and `COMPLETED.txt`.
