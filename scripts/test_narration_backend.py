"""Model-free worker contract checks; run with the isolated narration Python."""

import contextlib
import io
import sys
import tempfile
from types import SimpleNamespace
from unittest.mock import patch
import unittest
from pathlib import Path

import narration_backend as worker
import narration_compare as comparison


class NarrationContracts(unittest.TestCase):
    def test_chunking_preserves_every_word_in_order(self):
        text = ("We finished the export. Ahora lo probamos juntos. " * 80).strip()
        chunks = worker.split_text(text)
        self.assertEqual(" ".join(chunks), text)
        self.assertTrue(all(len(chunk) <= 420 for chunk in chunks))
        self.assertGreater(len(chunks), 1)

    def test_failure_diagnostics_contain_locations_not_private_contents(self):
        secret_text = "Private conversation content must not appear in frames"
        try:
            raise OSError(28, secret_text)
        except OSError as error:
            details = worker.failure_details(error)
        self.assertEqual(details["errno"], 28)
        self.assertNotIn(secret_text, str(details))
        self.assertTrue(details["frames"])
        self.assertEqual(set(details["frames"][-1]), {"file", "function", "line"})

    def test_comparison_planner_preserves_exact_text_and_does_not_run_models(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            reference = root / "reference.wav"
            reference.write_bytes(b"reference fixture")
            backend = root / "backend.py"
            backend.write_text("# fixture")
            exact_text = "Exact words.\n\nOtra frase."
            manifest = {
                "root": str(root),
                "reference": str(reference),
                "runtimes": [{"id": "candidate", "python": sys.executable}],
                "cases": [{"id": "target", "text": exact_text}],
                "seeds": [42, 71],
            }
            with patch.object(
                comparison.subprocess, "check_output", return_value="0.6.4\n"
            ) as version, patch.object(comparison.subprocess, "Popen") as start:
                plan = comparison.plan(manifest, backend)
            self.assertEqual(version.call_count, 1)
            start.assert_not_called()
            self.assertEqual(len(plan["trials"]), 4)
            self.assertTrue(all(t["text"] == exact_text for t in plan["trials"]))
            self.assertEqual(plan["referenceSHA256"], comparison.digest(reference))
            reference.write_bytes(b"changed reference")
            with patch.object(comparison.subprocess, "Popen") as start:
                with self.assertRaisesRegex(ValueError, "reference audio has changed"):
                    comparison.execute(plan, root / "outputs")
            start.assert_not_called()

    def test_empty_text_is_not_a_successful_export(self):
        with self.assertRaises(ValueError):
            worker.split_text(" \n ")

    def test_speaker_only_does_not_import_or_require_reference_asr(self):
        import numpy as np
        from scipy.io import wavfile

        calls = []
        fake_mx = SimpleNamespace(
            set_cache_limit=lambda _: None,
            set_memory_limit=lambda _: None,
            clear_cache=lambda: None,
            random=SimpleNamespace(seed=lambda _: None),
            get_peak_memory=lambda: 0,
        )

        class Model:
            sample_rate = 24000

            def generate(self, **kwargs):
                calls.append(kwargs)
                yield SimpleNamespace(
                    audio=np.ones(2400, dtype=np.float32) * 0.1, token_count=2
                )

        modules = {
            "mlx": SimpleNamespace(core=fake_mx),
            "mlx.core": fake_mx,
            "mlx_audio.tts.utils": SimpleNamespace(load_model=lambda _: Model()),
            "mlx_whisper": None,
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source.wav"
            wavfile.write(source, 16000, np.ones(16000 * 5, dtype=np.float32) * 0.1)
            with patch.dict(sys.modules, modules), patch.object(
                worker, "status", return_value={"ready": True}
            ), contextlib.redirect_stdout(io.StringIO()):
                result = worker.synthesize(
                    root,
                    {
                        "text": "The intended words.",
                        "voiceSampleURL": str(source),
                        "outputURL": str(root / "out.wav"),
                        "speakerOnly": True,
                    },
                )
            self.assertEqual(result["conditioning"], "speaker-only")
            self.assertIsNone(calls[0]["ref_text"])
            self.assertFalse((root / "reference-text").exists())
            self.assertAlmostEqual(result["duration"], 0.1)

    def test_partial_download_is_not_ready(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = worker.paths(root)[0] / "config.json"
            config.parent.mkdir(parents=True)
            config.write_text("{}")
            self.assertFalse(worker.status(root)["ready"])

    def test_reference_crop_is_private_bounded_and_leaves_original_intact(self):
        import numpy as np
        from scipy.io import wavfile

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            original = root / "source.wav"
            signal = np.sin(np.arange(16000 * 20) * 2 * np.pi * 180 / 16000) * 0.1
            wavfile.write(original, 16000, signal.astype(np.float32))
            before = original.read_bytes()
            clip, samples = worker.reference_clip(original, root)
            self.assertEqual(original.read_bytes(), before)
            self.assertLessEqual(len(samples), 16000 * 12)
            self.assertGreaterEqual(len(samples), 16000 * 3)
            self.assertEqual(clip.stat().st_mode & 0o777, 0o600)


if __name__ == "__main__":
    unittest.main()
