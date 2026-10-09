import importlib.util
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).with_name("evaluate-cleanup-models.py")
SPEC = importlib.util.spec_from_file_location("cleanup_evaluation", SCRIPT)
cleanup_evaluation = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(cleanup_evaluation)


class CleanupConfigurationTests(unittest.TestCase):
    def test_current_pricing_matches_model_catalog(self):
        expected = {
            "gpt-6-luna": (0.10, 0.01, 0.125, 0.50),
            "gemini-3.8-flash": (0.75, 0.075, None, 3.75),
            "mai-code-1.1-flash": (0.20, 0.02, None, 1.20),
            "gpt-5.4-mini": (0.75, 0.075, None, 4.50),
            "claude-haiku-5.5": (0.10, 0.01, 0.125, 0.50),
        }
        self.assertEqual(set(expected), set(cleanup_evaluation.DEFAULT_MODELS) - {"apple-intelligence"})
        for model, rates in expected.items():
            pricing = cleanup_evaluation.MODEL_PRICING[model]
            self.assertEqual(
                tuple(pricing[key] for key in ("input", "cached_input", "cache_write", "output")),
                rates,
            )

    def test_default_timeout_matches_production(self):
        with patch("sys.argv", [str(SCRIPT)]):
            self.assertEqual(cleanup_evaluation.parse_args().timeout, 90)

    def test_luna_uses_low_reasoning_without_changing_other_models(self):
        for model in cleanup_evaluation.DEFAULT_MODELS:
            if model == "apple-intelligence":
                continue
            with self.subTest(model=model):
                result = subprocess.CompletedProcess([], 0, "Synthetic output", "")
                with patch.object(
                    cleanup_evaluation.subprocess, "run", return_value=result
                ) as run:
                    output, error, _ = cleanup_evaluation.run_copilot(
                        model, "Synthetic prompt", "Synthetic input", 90
                    )
                command = run.call_args.args[0]
                self.assertEqual(output, "Synthetic output")
                self.assertIsNone(error)
                self.assertEqual(run.call_args.kwargs["timeout"], 90)
                if model == "gpt-6-luna":
                    self.assertEqual(command[-2:], ["--reasoning-effort", "low"])
                else:
                    self.assertNotIn("--reasoning-effort", command)


if __name__ == "__main__":
    unittest.main()
