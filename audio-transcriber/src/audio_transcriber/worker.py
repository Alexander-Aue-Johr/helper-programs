"""Internal CLI used by the GUI so long-running work can be cancelled as a process."""
from __future__ import annotations

import argparse
from pathlib import Path


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(prog="run.py _worker")
    sub = parser.add_subparsers(dest="action", required=True)

    transcribe_parser = sub.add_parser("transcribe")
    transcribe_parser.add_argument("--source", type=Path, required=True)
    transcribe_parser.add_argument("--out", type=Path, required=True)
    transcribe_parser.add_argument("--language", default="de")
    transcribe_parser.add_argument("--vad-threshold", type=float, default=0.25)

    finish_parser = sub.add_parser("finish")
    finish_parser.add_argument("--out", type=Path, required=True)

    video_parser = sub.add_parser("video")
    video_parser.add_argument("--source", type=Path, required=True)
    video_parser.add_argument("--out", type=Path, required=True)
    video_parser.add_argument("--title", required=True)

    args = parser.parse_args(argv)
    if args.action == "transcribe":
        from .transcription import transcribe

        transcribe(args.source, args.out, args.language, args.vad_threshold)
    elif args.action == "finish":
        from .review import finish_transcript

        finish_transcript(args.out)
    elif args.action == "video":
        from .video import create_video

        create_video(args.source, args.out, args.title)
    return 0
