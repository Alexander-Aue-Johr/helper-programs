import math
import unittest

from audio_transcriber.subtitle_timing import bound_segments


class SubtitleTimingTests(unittest.TestCase):
    def test_clips_and_omits_outside_segments(self):
        fixed, changes = bound_segments(
            [{"start": -2, "end": 2}, {"start": 4, "end": 9}, {"start": 10, "end": 12}, {"start": 3, "end": 3}],
            5,
        )
        self.assertEqual([(row["start"], row["end"]) for row in fixed], [(0, 2), (4, 5)])
        self.assertEqual(len(changes), 4)

    def test_reversed_timestamp_is_rejected(self):
        with self.assertRaises(ValueError):
            bound_segments([{"start": 2, "end": 1}], 5)

    def test_invalid_duration_is_rejected(self):
        for duration in (0, -1, math.inf):
            with self.subTest(duration=duration), self.assertRaises(ValueError):
                bound_segments([], duration)


if __name__ == "__main__":
    unittest.main()
