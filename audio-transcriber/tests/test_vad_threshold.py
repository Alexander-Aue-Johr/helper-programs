from pathlib import Path
import json
import tempfile
import unittest
from unittest.mock import patch

from audio_transcriber import transcription


ROOT = Path(__file__).resolve().parents[1]


class VadThresholdTests(unittest.TestCase):
    def test_default_preserves_quiet_speech_configuration(self):
        params = transcription.make_vad_parameters()
        self.assertEqual(params["threshold"], 0.25)
        self.assertEqual(params["neg_threshold"], 0.10)
        self.assertEqual(params["min_speech_duration_ms"], 0)
        self.assertEqual(params["min_silence_duration_ms"], 2000)
        self.assertEqual(params["speech_pad_ms"], 600)
        self.assertLess(params["threshold"], 0.5)

    def test_hysteresis_tracks_gui_threshold(self):
        params = transcription.make_vad_parameters(0.40)
        self.assertEqual(params["threshold"], 0.40)
        self.assertEqual(params["neg_threshold"], 0.25)

    def test_low_threshold_does_not_create_negative_hysteresis(self):
        params = transcription.make_vad_parameters(0.05)
        self.assertEqual(params["neg_threshold"], 0.0)

    def test_out_of_range_threshold_is_rejected(self):
        for value in (0.0, 0.81, 2.0):
            with self.subTest(value=value), self.assertRaises(ValueError):
                transcription.make_vad_parameters(value)

    def test_gui_passes_threshold_to_worker(self):
        source = (ROOT / "src/audio_transcriber/app.py").read_text(encoding="utf-8")
        self.assertIn('text="Speech detection threshold (VAD)"', source)
        self.assertIn('"--vad-threshold"', source)
        self.assertIn('"vad_threshold": vad_threshold', source)

    def test_worker_forwards_threshold_to_transcriber(self):
        from audio_transcriber import worker

        with patch("audio_transcriber.transcription.transcribe") as transcribe:
            result = worker.main(
                [
                    "transcribe",
                    "--source",
                    "source.m4a",
                    "--out",
                    "output",
                    "--language",
                    "de",
                    "--vad-threshold",
                    "0.40",
                ]
            )

        self.assertEqual(result, 0)
        transcribe.assert_called_once_with(
            Path("source.m4a"), Path("output"), "de", 0.4
        )

    def test_transcriber_passes_vad_and_no_speech_settings_to_model(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source = root / "source.m4a"
            source.touch()
            output = root / "output"

            with (
                patch.object(transcription, "ensure_model", return_value=root),
                patch.object(transcription, "media_duration", return_value=1.0),
                patch.object(transcription.subprocess, "run"),
                patch("imageio_ffmpeg.get_ffmpeg_exe", return_value="ffmpeg"),
                patch("faster_whisper.WhisperModel") as model_class,
            ):
                model_class.return_value.transcribe.return_value = (iter(()), None)
                transcription.transcribe(source, output, vad_threshold=0.40)

            kwargs = model_class.return_value.transcribe.call_args.kwargs
            self.assertTrue(kwargs["vad_filter"])
            self.assertEqual(kwargs["vad_parameters"], transcription.make_vad_parameters(0.40))
            self.assertEqual(
                kwargs["no_speech_threshold"],
                transcription.QUIET_SPEECH_NO_SPEECH_THRESHOLD,
            )

            info = json.loads((output / "info.json").read_text(encoding="utf-8"))
            self.assertEqual(info["quiet_speech_vad"], kwargs["vad_parameters"])
            self.assertEqual(
                info["no_speech_threshold"],
                transcription.QUIET_SPEECH_NO_SPEECH_THRESHOLD,
            )

    def test_readme_documents_quiet_speech_behavior(self):
        readme = (ROOT / "README.md").read_text(encoding="utf-8")
        self.assertIn("## Quiet speech detection", readme)
        self.assertIn("`0.25`", readme)
        self.assertIn("`0.80`", readme)

    def test_whisper_no_speech_threshold_is_relaxed(self):
        self.assertGreater(transcription.QUIET_SPEECH_NO_SPEECH_THRESHOLD, 0.6)
        self.assertLessEqual(transcription.QUIET_SPEECH_NO_SPEECH_THRESHOLD, 1.0)


if __name__ == "__main__":
    unittest.main()
