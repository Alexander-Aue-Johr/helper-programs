"""Whisper transcription and raw checkpoint export."""
from __future__ import annotations

from dataclasses import asdict
import json
import math
from pathlib import Path
import subprocess
import time

from .model_manager import ensure_model


def stamp(seconds, srt=False):
    ms = round(seconds * 1000)
    h, ms = divmod(ms, 3600000)
    m, ms = divmod(ms, 60000)
    s, ms = divmod(ms, 1000)
    return f"{h:02}:{m:02}:{s:02}" + (f",{ms:03}" if srt else "")


def media_duration(source: Path) -> float:
    import av

    with av.open(str(source)) as container:
        if not container.streams.audio or not container.duration:
            raise ValueError("The file does not contain a readable audio stream with a valid duration.")
        return container.duration / av.time_base


def _all_rows(chunks: Path):
    return [
        row
        for file in sorted(chunks.glob("*.json"))
        for row in json.loads(file.read_text(encoding="utf-8"))
    ]


def _write_raw_exports(out: Path, rows) -> None:
    with (out / "transcript.txt").open("w", encoding="utf-8") as txt, (out / "transcript.srt").open(
        "w", encoding="utf-8"
    ) as srt, (out / "segments.jsonl").open("w", encoding="utf-8") as raw:
        for index, row in enumerate(rows, 1):
            text = row["text"].strip()
            txt.write(f'[{stamp(row["start"])}] {text}\n')
            srt.write(f'{index}\n{stamp(row["start"], True)} --> {stamp(row["end"], True)}\n{text}\n\n')
            raw.write(json.dumps(row, ensure_ascii=False) + "\n")


def transcribe(source: Path, out: Path, language: str = "de") -> None:
    from faster_whisper import WhisperModel
    import imageio_ffmpeg

    source, out = Path(source).resolve(), Path(out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    model_dir = ensure_model()
    started = time.monotonic()
    duration = media_duration(source)
    print(f"Duration: {duration:.1f}s", flush=True)

    model = WhisperModel(str(model_dir), device="cpu", compute_type="int8", cpu_threads=8)
    chunks = out / "chunks"
    chunks.mkdir(exist_ok=True)

    for offset in range(0, math.ceil(duration), 600):
        saved = chunks / f"{offset:06}.json"
        if saved.exists():
            print(f"CHECKPOINT {min(offset + 600, math.ceil(duration))} (existing)", flush=True)
            continue

        wav = chunks / "aktuell.wav"
        try:
            subprocess.run(
                [
                    imageio_ffmpeg.get_ffmpeg_exe(),
                    "-v",
                    "error",
                    "-y",
                    "-ss",
                    str(offset),
                    "-i",
                    str(source),
                    "-t",
                    "600",
                    "-vn",
                    "-ac",
                    "1",
                    "-ar",
                    "16000",
                    str(wav),
                ],
                check=True,
            )
            segments, _ = model.transcribe(
                str(wav),
                language=None if language == "auto" else language,
                task="transcribe",
                beam_size=5,
                vad_filter=True,
                condition_on_previous_text=False,
            )
            rows = []
            for segment in segments:
                row = asdict(segment)
                row["start"] += offset
                row["end"] += offset
                rows.append(row)
                print(
                    f'{stamp(min(row["end"], duration))} / {stamp(duration)} '
                    f'elapsed={time.monotonic() - started:.0f}s {segment.text.strip()}',
                    flush=True,
                )
            temporary = saved.with_suffix(".tmp")
            temporary.write_text(json.dumps(rows, ensure_ascii=False, indent=2), encoding="utf-8")
            temporary.replace(saved)
            _write_raw_exports(out, _all_rows(chunks))
            print(f"CHECKPOINT {min(offset + 600, math.ceil(duration))}", flush=True)
        finally:
            wav.unlink(missing_ok=True)

    _write_raw_exports(out, _all_rows(chunks))
    (out / "info.json").write_text(
        json.dumps(
            {
                "model": "large-v3",
                "language": language,
                "duration": duration,
                "elapsed_seconds": time.monotonic() - started,
            },
            indent=2,
        ),
        encoding="utf-8",
    )
