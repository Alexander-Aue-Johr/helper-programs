# Single public launcher for the local audio transcription project.
#
# This file deliberately uses only the Python standard library until the
# repository-local virtual environment has been prepared. A fresh checkout can
# therefore bootstrap itself from run.cmd and from the Explorer context menu.

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import traceback

REPO_ROOT = Path(__file__).resolve().parent
VENV_DIR = REPO_ROOT / ".venv"
REQUIREMENTS = REPO_ROOT / "requirements.lock.txt"
REQUIREMENTS_STAMP = VENV_DIR / ".requirements.sha256"
SRC_DIR = REPO_ROOT / "src"
RUNTIME_DIR = REPO_ROOT / ".runtime"

DEPENDENCY_IMPORT_CHECK = (
    "import av, imageio_ffmpeg, PIL, faster_whisper, huggingface_hub"
)


def _venv_python() -> Path:
    if os.name == "nt":
        return VENV_DIR / "Scripts" / "python.exe"
    return VENV_DIR / "bin" / "python"


def _requirements_hash() -> str:
    return hashlib.sha256(REQUIREMENTS.read_bytes()).hexdigest()


def _same_file(left: Path, right: Path) -> bool:
    try:
        return left.resolve() == right.resolve()
    except OSError:
        return False


def _python_works(python: Path) -> bool:
    if not python.is_file():
        return False
    try:
        completed = subprocess.run(
            [str(python), "-c", "import sys; raise SystemExit(0 if sys.version_info.major == 3 else 1)"],
            cwd=REPO_ROOT,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=30,
            check=False,
        )
        return completed.returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def _dependencies_available(python: Path) -> bool:
    if not _python_works(python):
        return False
    try:
        completed = subprocess.run(
            [str(python), "-c", DEPENDENCY_IMPORT_CHECK],
            cwd=REPO_ROOT,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=120,
            check=False,
        )
        return completed.returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def _create_venv() -> Path:
    python = _venv_python()

    if VENV_DIR.exists() and not _python_works(python):
        print("[Setup] Existing .venv is incomplete or broken; rebuilding it.", flush=True)
        shutil.rmtree(VENV_DIR)

    if not python.is_file():
        print("[Setup] Creating local Python environment .venv ...", flush=True)
        try:
            subprocess.run([sys.executable, "-m", "venv", str(VENV_DIR)], cwd=REPO_ROOT, check=True)
        except Exception as exc:
            raise RuntimeError(
                "The local Python environment could not be created. "
                "Make sure the selected Python installation includes the standard-library 'venv' module."
            ) from exc

    if not _python_works(python):
        raise RuntimeError(f"The newly created virtual environment is not usable: {python}")
    return python


def ensure_environment(argv: list[str]) -> bool:
    if not REQUIREMENTS.is_file():
        raise RuntimeError(f"requirements.lock.txt is missing: {REQUIREMENTS}")

    python = _create_venv()
    expected = _requirements_hash()
    try:
        installed = REQUIREMENTS_STAMP.read_text(encoding="utf-8").strip()
    except OSError:
        installed = ""

    needs_install = installed != expected or not _dependencies_available(python)
    if needs_install:
        print("[Setup] Installing/updating pinned Python dependencies ...", flush=True)
        try:
            subprocess.run(
                [
                    str(python),
                    "-m",
                    "pip",
                    "install",
                    "--disable-pip-version-check",
                    "-r",
                    str(REQUIREMENTS),
                ],
                cwd=REPO_ROOT,
                check=True,
            )
        except Exception as exc:
            raise RuntimeError(
                "Python dependencies could not be installed completely. "
                "Details are available in the Explorer launcher bootstrap log."
            ) from exc

        if not _dependencies_available(python):
            raise RuntimeError(
                "pip completed, but at least one required Python dependency still cannot be imported "
                "from .venv."
            )
        REQUIREMENTS_STAMP.write_text(expected + "\n", encoding="utf-8")

    if not _same_file(Path(sys.executable), python):
        completed = subprocess.run(
            [str(python), str(Path(__file__).resolve()), *argv],
            cwd=REPO_ROOT,
            env={**os.environ, "PYTHONUTF8": "1", "PYTHONIOENCODING": "utf-8"},
        )
        raise SystemExit(completed.returncode)

    return True


def _import_project() -> None:
    sys.path.insert(0, str(SRC_DIR))


def _context_launch() -> bool:
    return os.environ.get("AUDIO_TRANSCRIBER_CONTEXT_LAUNCH", "").strip().lower() in {
        "1",
        "true",
        "yes",
    }


def _report_context_fatal(exc: BaseException) -> None:
    if not _context_launch():
        return

    try:
        RUNTIME_DIR.mkdir(parents=True, exist_ok=True)
        log = RUNTIME_DIR / "context-gui-error.log"
        detail = "".join(traceback.format_exception(type(exc), exc, exc.__traceback__))
        log.write_text(detail, encoding="utf-8")

        try:
            import tkinter as tk
            from tkinter import messagebox

            root = tk.Tk()
            root.withdraw()
            messagebox.showerror(
                "Audio Transcriber - Fehler",
                "Audio Transcriber could not be started after environment preparation.\n\n"
                f"{exc}\n\nDetails:\n{log}",
                parent=root,
            )
            root.destroy()
        except Exception:
            pass
    except Exception:
        pass


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    ensure_environment(argv)
    _import_project()

    command = argv[0] if argv else "gui"
    rest = argv[1:] if argv else []

    if command == "bootstrap":
        print("[Setup] Python environment is ready.", flush=True)
        return 0

    if command == "setup":
        from audio_transcriber.model_manager import ensure_model

        ensure_model()
        print("[Setup] Environment and Whisper model are ready.", flush=True)
        return 0

    if command == "gui":
        from audio_transcriber.app import main as gui_main

        gui_main()
        return 0

    if command == "test":
        return subprocess.call(
            [str(_venv_python()), "-m", "unittest", "discover", "-s", "tests", "-v"],
            cwd=REPO_ROOT,
            env={**os.environ, "PYTHONPATH": str(SRC_DIR)},
        )

    if command == "_worker":
        from audio_transcriber.worker import main as worker_main

        return worker_main(rest)

    print(f"Unknown command: {command}", file=sys.stderr)
    print("Available: gui, bootstrap, setup, test", file=sys.stderr)
    return 2


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except SystemExit:
        raise
    except BaseException as exc:
        _report_context_fatal(exc)
        raise
