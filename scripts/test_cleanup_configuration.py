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
                if model == "gpt-5.6-luna":
                    self.assertEqual(command[-2:], ["--reasoning-effort", "low"])
                else:
                    self.assertNotIn("--reasoning-effort", command)


if __name__ == "__main__":
    unittest.main()
