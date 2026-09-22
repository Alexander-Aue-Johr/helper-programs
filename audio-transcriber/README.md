# Local Audio Transcription

A small Windows-oriented helper that turns an `.m4a` recording, or an `.m4a` contained in a ZIP archive, into a local Whisper transcript, subtitles, and a title-card video.

## Starting the application

Do **not** run files below `src/` directly.

From Visual Studio Code, run the task **Audio: Convert file**. On Windows you can also start `run.cmd`. `run.py` is the only public Python entry point.

The normal GUI flow is:

1. Select an `.m4a` or `.zip` file, or open one through the Explorer context menu.
2. Choose the spoken language and optionally enter a video title.
3. Press **Start conversion**.

Opening a file from Explorer only pre-fills the selected path. It does **not** start transcription automatically.

## First run after checkout

The launcher prepares its local Python environment automatically:

- `.venv` is created inside the helper directory when necessary.
- The exact versions from `requirements.lock.txt` are installed and checked by import.
- Runtime files stay below `.runtime` and are ignored by Git.
- The pinned `Systran/faster-whisper-large-v3` model is downloaded to `.runtime/models/large-v3` when a conversion first needs it, or explicitly through the setup task.

Python 3 with the standard-library `venv` module must already be available on the machine.

The Explorer launcher intentionally prepares only the Python environment before opening the dialog. This keeps a context-menu click interactive: a potentially multi-gigabyte model download never starts merely because the user opened the dialog.

## Output

Results are created **next to the selected source file**. For example:

```text
D:\Recordings\Interview.m4a
D:\Recordings\Interview_transcript_de\
```

If that directory already exists, `_2`, `_3`, and so on are appended. For ZIP input, only the selected M4A member is extracted into the output directory's `source/` folder.

The main generated files are:

- `job.json` – source, language, archive member, and requested title.
- `transcript_raw.txt` / `transcript_raw.srt` – raw Whisper output after timestamp bounding.
- `transcript.txt` / `transcript.srt` – readable output with uncertainty markers.
- `segments.jsonl` – segment-level model data.
- `timing_corrections.json` – timestamp clipping/omission audit trail.
- `review_passages.txt` / `review.json` – automatically selected passages worth checking.
- `title.png` / `title.txt` – title-card assets.
- `<source-name>.mp4` – title-card video with the original audio when possible.
- `COMPLETED.txt` – completion marker and short result description.

Ten-minute transcription checkpoints are stored below `chunks/` so the worker can retain intermediate progress while it is running.

## Project structure

```text
.
├─ run.cmd
├─ run.py                  # single public Python launcher
├─ requirements.lock.txt
├─ Install-ContextMenu.ps1
├─ Run-AudioTranscriber.ps1
├─ Uninstall-ContextMenu.ps1
├─ src/
│  └─ audio_transcriber/
├─ tests/
├─ docs/
├─ .venv/                  # generated, ignored by Git
└─ .runtime/               # generated, ignored by Git
```

The old flat migration scripts are not entry points. Application code lives in `src/audio_transcriber/`.

## Commands and VS Code tasks

The public launcher supports:

- `python run.py gui` – open the GUI and wait for user input.
- `python run.py bootstrap` – prepare only `.venv` and Python dependencies.
- `python run.py setup` – prepare the environment and the pinned Whisper model without opening the GUI.
- `python run.py test` – run the unit-test suite.

Recommended VS Code task labels are:

- **Audio: Convert file**
- **Audio: Prepare environment + Whisper model**
- **Audio: Unit tests**
- **Install audio transcriber context menu**
- **Uninstall audio transcriber context menu**

## Processing pipeline

```text
M4A / ZIP selection
→ optional safe extraction of one M4A member
→ Whisper large-v3 in 10-minute chunks
→ raw TXT/SRT + segment data
→ timestamp and quality review
→ readable TXT/SRT + review passages
→ title card + MP4
```

Raw model output remains auditable in `transcript_raw.*` and `segments.jsonl`. Timestamp changes are recorded in `timing_corrections.json`.

## Explorer context menu

`Install-ContextMenu.ps1` adds per-user context-menu entries for `.m4a` and `.zip` files. On Windows 11 they may appear under **Show more options**.

A context launch performs this sequence:

1. Locate Python 3.
2. Create or repair `.venv` and install pinned dependencies if necessary.
3. Open the GUI with the Explorer-selected path already filled in.
4. Wait for the user to choose language/title and press **Start conversion**.
5. Download/validate the pinned Whisper model only when conversion actually starts, unless it was prepared earlier with `run.py setup`.

Bootstrap output is written to `.runtime/context-bootstrap.log`. Fatal context-launch errors are shown in a Windows message box and recorded in `.runtime/context-gui-error.log`.

## Tests

Run:

```text
python run.py test
```

The fast unit tests deliberately do not download the multi-gigabyte Whisper model. The test suite also guards the Explorer contract: context-menu launches may pre-fill a path but must never auto-start a conversion.
