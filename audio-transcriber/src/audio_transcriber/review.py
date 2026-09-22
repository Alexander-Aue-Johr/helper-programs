"""Check completed transcription and collect passages worth listening to again."""
from __future__ import annotations

from collections import Counter
import json
import math
from pathlib import Path
import re

from .subtitle_timing import bound_segments
from .transcription import stamp


def finish_transcript(out: Path) -> dict:
    out = Path(out).resolve()
    info = json.loads((out / "info.json").read_text(encoding="utf-8"))
    duration = info["duration"]
    expected = set(range(0, math.ceil(duration), 600))
    actual = {int(path.stem) for path in (out / "chunks").glob("*.json")}
    if expected != actual:
        missing = sorted(expected - actual)
        raise RuntimeError(f"Transcription is incomplete. Missing chunks: {missing}")

    original_rows = [json.loads(line) for line in (out / "segments.jsonl").read_text(encoding="utf-8").splitlines()]
    rows, timing_changes = bound_segments(original_rows, duration)
    (out / "timing_corrections.json").write_text(
        json.dumps(timing_changes, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    if not all(0 <= row["start"] < row["end"] <= duration for row in rows):
        raise RuntimeError("Invalid timestamps remain after bounding.")
    if not all(a["start"] <= b["start"] for a, b in zip(rows, rows[1:])):
        raise RuntimeError("Timestamps are not sorted in ascending order.")

    flags, display_rows = [], []
    for row in rows:
        reasons = []
        if row["avg_logprob"] < -0.8:
            reasons.append("low model confidence")
        if row["no_speech_prob"] > 0.6:
            reasons.append("possibly no speech")
        if row["compression_ratio"] > 2.4:
            reasons.append("suspicious repetition")
        stock_phrase = any(
            term in row["text"].lower()
            for term in ("untertitelung", "amara.org", "untertitel im auftrag", "untertitel von")
        )
        tokens = re.findall(r"\w+", row["text"].lower())
        repeating = row["compression_ratio"] > 2.4 and max(Counter(tokens).values(), default=0) >= 8
        if stock_phrase:
            reasons.append("possible automatically generated boilerplate")
        text = row["text"].strip()
        if stock_phrase or repeating:
            text = "[Unclear passage – possible recognition artifact; see raw output and review passages]"
        elif reasons:
            text = "[Low-confidence recognition] " + text
        display_rows.append({**row, "text": text})
        if reasons:
            flags.append(
                f'[{stamp(row["start"])} – {stamp(row["end"])}] {row["text"].strip()}\n'
                f'Note: {", ".join(reasons)}\n'
            )

    header = (
        "Automatically selected review passages\n\n"
        "These markers do not prove that a passage is wrong, and unmarked passages can still contain recognition errors. "
        "Selection is based on model values and suspicious wording; it does not replace listening to the original audio. "
        "The readable transcript marks low-confidence output. Boilerplate-like phrases and strong repetition are replaced "
        "with a notice there. Original recognition remains available in transcript_raw.txt and segments.jsonl.\n\n"
    )
    (out / "review_passages.txt").write_text(header + "\n".join(flags), encoding="utf-8")

    for stem, selected in (("transcript_raw", rows), ("transcript", display_rows)):
        with (out / f"{stem}.txt").open("w", encoding="utf-8") as txt, (out / f"{stem}.srt").open(
            "w", encoding="utf-8"
        ) as srt:
            for index, row in enumerate(selected, 1):
                text = row["text"].strip()
                txt.write(f'[{stamp(row["start"])}] {text}\n')
                srt.write(f'{index}\n{stamp(row["start"], True)} --> {stamp(row["end"], True)}\n{text}\n\n')

    result = {
        "status": "complete",
        "chunks": len(actual),
        "segments": len(rows),
        "review_passages": len(flags),
        "duration_seconds": duration,
        "timing_corrections": len(timing_changes),
    }
    (out / "review.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(json.dumps(result, indent=2))
    return result
