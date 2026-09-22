import tempfile
from pathlib import Path
import unittest
from unittest.mock import patch

from audio_transcriber import model_manager


class ModelManagerTests(unittest.TestCase):
    def test_ready_marker_avoids_download(self):
        with tempfile.TemporaryDirectory() as temp:
            model_dir = Path(temp)
            for name in model_manager.REQUIRED_FILES:
                path = model_dir / name
                if name == "model.bin":
                    # Do not allocate 3 GB in a unit test; mock the marker check instead.
                    path.write_bytes(b"x")
                else:
                    path.write_text("{}", encoding="utf-8")
            with patch.object(model_manager, "_marker_matches", return_value=True):
                self.assertEqual(model_manager.ensure_model(model_dir), model_dir)


if __name__ == "__main__":
    unittest.main()
