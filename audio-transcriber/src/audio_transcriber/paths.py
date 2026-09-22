from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
RUNTIME_DIR = REPO_ROOT / ".runtime"
MODEL_DIR = RUNTIME_DIR / "models" / "large-v3"
HF_HOME = RUNTIME_DIR / "huggingface"
RUNNER = REPO_ROOT / "run.py"
