"""Bound subtitle cues to the media while retaining original model data elsewhere."""
import math


def bound_segments(rows, duration):
    if not math.isfinite(duration) or duration <= 0:
        raise ValueError("Invalid audio duration.")
    limit = math.floor(duration * 1000) / 1000
    result, changes = [], []
    for index, original in enumerate(rows):
        start, end = original["start"], original["end"]
        if not math.isfinite(start) or not math.isfinite(end) or end < start:
            raise ValueError(f"Invalid model timestamp in segment {index + 1}.")
        start = round(min(limit, max(0, start)), 3)
        end = round(min(limit, max(0, end)), 3)
        if end <= start:
            changes.append(
                {
                    "segment": index + 1,
                    "action": "omitted",
                    "original_start": original["start"],
                    "original_end": original["end"],
                }
            )
            continue
        row = {**original, "start": start, "end": end}
        if start != round(original["start"], 3) or end != round(original["end"], 3):
            changes.append(
                {
                    "segment": index + 1,
                    "action": "clipped",
                    "original_start": original["start"],
                    "original_end": original["end"],
                    "start": start,
                    "end": end,
                }
            )
        result.append(row)
    return result, changes
