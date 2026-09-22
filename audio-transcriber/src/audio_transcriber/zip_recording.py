"""Read only the selected M4A from a recording ZIP; never extract archive paths."""
from pathlib import Path, PurePosixPath
import re
import stat
from zipfile import ZipFile


def audio_entries(archive):
    with ZipFile(archive) as zip_file:
        entries = []
        for index, item in enumerate(zip_file.infolist()):
            path = PurePosixPath(item.filename.replace("\\", "/"))
            if item.is_dir() or path.suffix.lower() != ".m4a":
                continue
            if "__MACOSX" in path.parts or path.name.startswith("._"):
                continue
            if path.is_absolute() or ".." in path.parts or ":" in item.filename:
                raise ValueError("The ZIP contains an invalid audio path.")
            if stat.S_ISLNK(item.external_attr >> 16):
                raise ValueError("ZIP symlinks are not processed as audio files.")
            entries.append((index, item.filename, item.file_size))
    if not entries:
        raise ValueError("No M4A file was found in this ZIP archive.")
    return entries


def extract_audio(archive, entry, folder, cancelled):
    folder = Path(folder).resolve()
    folder.mkdir(parents=True, exist_ok=True)
    index, name, size = entry
    filename = PurePosixPath(name.replace("\\", "/")).name
    filename = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "_", filename).rstrip(" .")
    reserved = {"CON", "PRN", "AUX", "NUL", *[f"COM{i}" for i in range(1, 10)], *[f"LPT{i}" for i in range(1, 10)]}
    if filename.split(".")[0].upper() in reserved:
        filename = "_" + filename
    target = folder / filename
    if target.resolve().parent != folder:
        raise ValueError("Invalid destination filename.")
    temporary = target.with_suffix(".m4a.part")
    created = False
    try:
        with ZipFile(archive) as zip_file:
            item = zip_file.infolist()[index]
            if (item.filename, item.file_size) != (name, size):
                raise ValueError("The ZIP archive changed after selection. Please select the recording again.")
            if item.flag_bits & 1:
                raise ValueError("Please extract password-protected ZIP archives manually first.")
            total = 0
            with zip_file.open(item) as source, temporary.open("xb") as dest:
                created = True
                while True:
                    if cancelled.is_set():
                        raise InterruptedError("Entpacken abgebrochen.")
                    block = source.read(1024 * 1024)
                    if not block:
                        break
                    dest.write(block)
                    total += len(block)
            if total != size:
                raise ValueError("The audio file was not extracted completely.")
        if target.exists():
            raise FileExistsError("The extracted audio file already exists.")
        temporary.replace(target)
        return target
    except Exception:
        if created:
            temporary.unlink(missing_ok=True)
        raise
