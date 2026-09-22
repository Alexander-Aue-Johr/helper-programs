"""Create a title-card video while preserving the original audio when possible."""
from __future__ import annotations

from pathlib import Path
import subprocess


def _font(size: int):
    from PIL import ImageFont

    for candidate in ("C:/Windows/Fonts/arial.ttf", "DejaVuSans.ttf"):
        try:
            return ImageFont.truetype(candidate, size)
        except OSError:
            pass
    raise RuntimeError("No suitable TrueType font was found for the title card.")


def create_video(source: Path, out: Path, title: str) -> Path:
    source, out = Path(source).resolve(), Path(out).resolve()
    if not title:
        raise ValueError("A title is required for the video.")
    video = out / f"{source.stem}.mp4"
    if video.exists():
        print(f"Video already exists: {video}", flush=True)
        return video

    from PIL import Image, ImageDraw
    import imageio_ffmpeg
    import av

    image = Image.new("RGB", (1920, 1080), "black")
    draw = ImageDraw.Draw(image)
    for size in range(66, 19, -2):
        font = _font(size)
        lines, line = [], ""
        for word in title.split():
            candidate = (line + " " + word).strip()
            if line and draw.textlength(candidate, font=font) > 1540:
                lines.append(line)
                line = word
            else:
                line = candidate
        lines.append(line)
        wrapped = "\n".join(lines)
        box = draw.multiline_textbbox((0, 0), wrapped, font=font, spacing=22)
        if box[2] - box[0] <= 1540 and box[3] - box[1] <= 800:
            break
    else:
        raise ValueError("The title is too long. Please use a shorter title.")

    draw.multiline_text((960, 540), wrapped, font=font, fill="white", anchor="mm", align="center", spacing=22)
    cover = out / "title.png"
    image.save(cover)
    (out / "title.txt").write_text(title + "\n", encoding="utf-8")

    with av.open(str(source)) as container:
        if not container.streams.audio:
            raise ValueError("The source file does not contain an audio stream.")
        codec = container.streams.audio[0].codec_context.name
    audio_options = ["-c:a", "copy"] if codec in ("aac", "alac") else ["-c:a", "aac", "-b:a", "192k"]
    temporary = out / f"{source.stem}.partial.mp4"
    subprocess.run(
        [
            imageio_ffmpeg.get_ffmpeg_exe(),
            "-hide_banner",
            "-loglevel",
            "error",
            "-stats",
            "-y",
            "-loop",
            "1",
            "-framerate",
            "1",
            "-i",
            str(cover),
            "-i",
            str(source),
            "-map",
            "0:v:0",
            "-map",
            "1:a:0",
            "-c:v",
            "libx264",
            "-threads",
            "2",
            "-preset",
            "ultrafast",
            "-tune",
            "stillimage",
            "-crf",
            "24",
            "-pix_fmt",
            "yuv420p",
            *audio_options,
            "-shortest",
            "-movflags",
            "+faststart",
            str(temporary),
        ],
        check=True,
    )
    temporary.replace(video)
    return video
