"""Download and validate the pinned faster-whisper model inside the repository."""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path

from .paths import HF_HOME, MODEL_DIR

MODEL_REPO = "Systran/faster-whisper-large-v3"
MODEL_REVISION = "edaa852ec7e145841d8ffdb056a99866b5f0a478"
MODEL_BIN_SHA256 = "69f74147e3334731bc3a76048724833325d2ec74642fb52620eda87352e3d4f1"
MODEL_BIN_SIZE = 3_087_284_237
REQUIRED_FILES = (
    "config.json",
    "model.bin",
    "preprocessor_config.json",
    "tokenizer.json",
    "vocabulary.json",
)
MARKER = ".model-ready.json"


def _files_present(model_dir: Path) -> bool:
    return all((model_dir / name).is_file() for name in REQUIRED_FILES)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(8 * 1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _marker_matches(model_dir: Path) -> bool:
    marker = model_dir / MARKER
    if not marker.is_file() or not _files_present(model_dir):
        return False
    try:
        data = json.loads(marker.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return False
    return (
        data.get("repo") == MODEL_REPO
        and data.get("revision") == MODEL_REVISION
        and data.get("model_bin_sha256") == MODEL_BIN_SHA256
        and (model_dir / "model.bin").stat().st_size == MODEL_BIN_SIZE
    )


def _validate_and_mark(model_dir: Path) -> None:
    missing = [name for name in REQUIRED_FILES if not (model_dir / name).is_file()]
    if missing:
        raise RuntimeError("Whisper model is incomplete; missing: " + ", ".join(missing))
    model_bin = model_dir / "model.bin"
    if model_bin.stat().st_size != MODEL_BIN_SIZE:
        raise RuntimeError(f"Unexpected model.bin size: {model_bin.stat().st_size} bytes")
    print("[Setup] Validating the Whisper model once with SHA-256 ...", flush=True)
    actual = _sha256(model_bin)
    if actual != MODEL_BIN_SHA256:
        raise RuntimeError(f"Whisper model has an unexpected SHA-256 checksum: {actual}")
    (model_dir / MARKER).write_text(
        json.dumps(
            {
                "repo": MODEL_REPO,
                "revision": MODEL_REVISION,
                "model_bin_sha256": MODEL_BIN_SHA256,
                "required_files": list(REQUIRED_FILES),
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )


def ensure_model(model_dir: Path = MODEL_DIR) -> Path:
    """Return a complete local model directory, downloading it when necessary."""
    model_dir = Path(model_dir)
    if _marker_matches(model_dir):
        return model_dir

    if _files_present(model_dir):
        _validate_and_mark(model_dir)
        return model_dir

    os.environ.setdefault("HF_HOME", str(HF_HOME))
    os.environ.setdefault("HF_HUB_DISABLE_XET", "1")
    HF_HOME.mkdir(parents=True, exist_ok=True)
    model_dir.mkdir(parents=True, exist_ok=True)

    print("[Setup] Whisper large-v3 is missing or incomplete.", flush=True)
    print(f"[Setup] Downloading {MODEL_REPO}@{MODEL_REVISION[:12]} to {model_dir} ...", flush=True)
    try:
        from huggingface_hub import snapshot_download

        snapshot_download(
            repo_id=MODEL_REPO,
            revision=MODEL_REVISION,
            local_dir=str(model_dir),
            allow_patterns=list(REQUIRED_FILES),
        )
    except Exception as exc:
        raise RuntimeError(
            "The Whisper model could not be downloaded. "
            "Check the internet connection and try again."
        ) from exc

    _validate_and_mark(model_dir)
    print("[Setup] Whisper model is complete and ready.", flush=True)
    return model_dir
