import tempfile
from pathlib import Path
import unittest

from audio_transcriber.output import create_output


class OutputTests(unittest.TestCase):
    def test_results_are_created_next_to_selected_source(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / "My Recording.m4a"
            source.write_bytes(b"")
            first = create_output(source, "de")
            second = create_output(source, "de")
            self.assertEqual(first, root / "My Recording_transcript_de")
            self.assertEqual(second, root / "My Recording_transcript_de_2")


if __name__ == "__main__":
    unittest.main()
