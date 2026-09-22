import tempfile
from pathlib import Path
import threading
import unittest
from zipfile import ZipFile

from audio_transcriber.zip_recording import audio_entries, extract_audio


class ZipRecordingTests(unittest.TestCase):
    def test_nested_m4a_is_found_and_extracted(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            archive = root / "recording.zip"
            with ZipFile(archive, "w") as zip_file:
                zip_file.writestr("notes.txt", "sidecar")
                zip_file.writestr("folder/recording.m4a", b"audio")
            entries = audio_entries(archive)
            self.assertEqual(len(entries), 1)
            extracted = extract_audio(archive, entries[0], root / "out", threading.Event())
            self.assertEqual(extracted.read_bytes(), b"audio")

    def test_zip_slip_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            archive = Path(temp) / "invalid.zip"
            with ZipFile(archive, "w") as zip_file:
                zip_file.writestr("../escape.m4a", b"bad")
            with self.assertRaises(ValueError):
                audio_entries(archive)

    def test_archive_without_m4a_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            archive = Path(temp) / "empty.zip"
            with ZipFile(archive, "w") as zip_file:
                zip_file.writestr("notes.txt", "no audio")
            with self.assertRaises(ValueError):
                audio_entries(archive)


if __name__ == "__main__":
    unittest.main()
