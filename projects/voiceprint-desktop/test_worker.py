"""Meaningful edge cases for audio input; no microphone or recording permissions."""
import tempfile
import unittest
from pathlib import Path

import numpy as np
import soundfile as sf

from worker import compare, prepare_audio


class AudioInputTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)

    def tearDown(self):
        self.directory.cleanup()

    def write(self, name, signal, rate=16000):
        path = self.root / name
        sf.write(path, signal, rate)
        return path

    def test_silence_is_rejected(self):
        path = self.write("silent.wav", np.zeros(16000 * 3))
        with self.assertRaisesRegex(ValueError, "有效声音"):
            prepare_audio(path)

    def test_short_recording_is_rejected(self):
        path = self.write("short.wav", np.ones(4000) * 0.1)
        with self.assertRaisesRegex(ValueError, "不足 1 秒"):
            prepare_audio(path)

    def test_long_recording_is_rejected_before_full_read(self):
        path = self.write("long.wav", np.zeros(16000 * 62))
        with self.assertRaisesRegex(ValueError, "超过 60 秒"):
            prepare_audio(path)

    def test_stereo_48k_and_silence_trimming(self):
        rate = 48000
        voice = np.sin(np.arange(rate * 2) * 2 * np.pi * 180 / rate) * 0.12
        signal = np.concatenate([np.zeros(rate), voice, np.zeros(rate)])
        path = self.write("stereo.wav", np.column_stack([signal, signal]), rate)
        audio, actual_rate = prepare_audio(path)
        self.assertEqual(actual_rate, rate)
        self.assertEqual(audio.ndim, 1)
        self.assertGreater(len(audio) / rate, 1.9)
        self.assertLess(len(audio) / rate, 2.3)

    def test_identical_audio_scores_one_with_real_model(self):
        model = Path(__file__).parent / "models/eres2netv2.onnx"
        if not model.exists():
            self.skipTest("模型尚未安装")
        rate = 16000
        t = np.arange(rate * 3) / rate
        signal = 0.1 * np.sin(2 * np.pi * (180 * t + 15 * t * t))
        path = self.write("signal.wav", signal)
        result = compare({"model": str(model), "audio_a": str(path), "audio_b": str(path)})
        self.assertTrue(result["ok"])
        self.assertGreater(result["score"], 0.999)


if __name__ == "__main__":
    unittest.main()
