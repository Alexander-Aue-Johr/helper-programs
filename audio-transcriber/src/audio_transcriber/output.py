from pathlib import Path


def create_output(source: Path, language: str) -> Path:
    """Create a unique result directory next to the user's selected input file."""
    source = Path(source)
    base = source.parent / f"{source.stem}_transcript_{language}"
    for number in range(1, 10000):
        candidate = base if number == 1 else base.with_name(f"{base.name}_{number}")
        try:
            candidate.mkdir()
            return candidate
        except FileExistsError:
            continue
    raise RuntimeError("Could not create a free output directory name.")
