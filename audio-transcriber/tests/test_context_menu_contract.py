from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


class ContextLaunchContractTests(unittest.TestCase):
    def test_context_launcher_prefills_without_autostart(self):
        launcher = (ROOT / "Run-AudioTranscriber.ps1").read_text(encoding="utf-8")
        self.assertIn("AUDIO_TRANSCRIBER_INPUT", launcher)
        self.assertIn("$runner bootstrap", launcher)
        self.assertNotIn("AUDIO_TRANSCRIBER_AUTOSTART", launcher)

    def test_gui_has_no_autostart_hook(self):
        app = (ROOT / "src/audio_transcriber/app.py").read_text(encoding="utf-8")
        self.assertNotIn("AUDIO_TRANSCRIBER_AUTOSTART", app)
        self.assertNotIn("root.after(350, self.start)", app)

    def test_gui_command_does_not_prepare_model_before_opening(self):
        launcher = (ROOT / "run.py").read_text(encoding="utf-8")
        gui_section = launcher.split('if command == "gui":', 1)[1].split('if command == "test":', 1)[0]
        self.assertNotIn("ensure_model", gui_section)


if __name__ == "__main__":
    unittest.main()
