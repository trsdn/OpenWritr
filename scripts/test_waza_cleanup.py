import copy
from contextlib import redirect_stdout
import importlib.util
import io
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
from types import SimpleNamespace
import unittest


SPEC = importlib.util.spec_from_file_location(
    "waza_cleanup", Path(__file__).with_name("waza-cleanup.py")
)
waza_cleanup = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(waza_cleanup)


class WazaCleanupTests(unittest.TestCase):
    def setUp(self):
        self.dataset = json.loads(waza_cleanup.cleanup_evaluation.DEFAULT_DATASET.read_text())
        self.case = next(
            case for case in self.dataset["cases"] if case["id"] == "injection-override"
        )
        self.report = {
            "generated_at": "2026-10-09T18:00:00Z",
            "configuration": {
                "models": ["synthetic-model"], "runs": 2, "cases": 1,
                "prompt_profile": "synthetic-profile", "timeout": 90,
            },
            "results": [{
                "model": "synthetic-model", "run": run,
                "case_id": self.case["id"],
                "input": self.case["input"], "reference": self.case["reference"],
                "category": self.case["category"], "output": self.case["reference"],
                "error": None, "duration_ms": 100,
            } for run in (1, 2)],
        }

    def test_exports_actual_outputs_runs_and_golden_cases(self):
        self.report["results"][1]["error"] = "synthetic timeout"
        with tempfile.TemporaryDirectory() as directory:
            spec_path, result_path = waza_cleanup.export_report(
                self.report, self.dataset, Path(directory), 0.9
            )
            outcome = json.loads(result_path.read_text())
            self.assertEqual(outcome["config"]["engine_type"], "openwritr-captured-report")
            self.assertEqual(outcome["config"]["timeout_sec"], 90)
            task = outcome["tasks"][0]
            self.assertTrue(task["golden"])
            self.assertEqual(task["runs"][0]["final_output"], self.case["reference"])
            self.assertEqual(task["runs"][1]["status"], "error")
            self.assertEqual(task["runs"][1]["error_msg"], "synthetic timeout")
            spec = json.loads(spec_path.read_text())
            task_spec = json.loads((Path(directory) / spec["tasks"][0]).read_text())
            self.assertTrue(task_spec["golden"])
            self.assertEqual(task_spec["graders"][0]["type"], "program")

    def test_rejects_partial_duplicate_or_mismatched_reports(self):
        cases = {case["id"]: case for case in self.dataset["cases"]}
        for mutation in ("missing", "duplicate", "input", "reference", "category", "path", "duration"):
            report = copy.deepcopy(self.report)
            if mutation == "missing":
                report["results"].pop()
            elif mutation == "duplicate":
                report["results"].append(report["results"][0])
            elif mutation == "path":
                report["results"][0]["model"] = "../outside"
            elif mutation == "duration":
                report["results"][0]["duration_ms"] = float("nan")
            else:
                report["results"][0][mutation] = "changed"
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                waza_cleanup.validate_report(report, cases)

    def test_rejects_empty_category_selection(self):
        with tempfile.TemporaryDirectory() as directory, self.assertRaises(ValueError):
            waza_cleanup.export_report(
                self.report, self.dataset, Path(directory), 0.9, "unknown"
            )

    def test_grader_uses_shared_scoring_and_strict_preservation(self):
        passed, score = waza_cleanup.score_output(self.case, self.case["reference"], 0.9)
        self.assertTrue(passed)
        self.assertTrue(score["preservation_passed"])
        for output in ("PINEAPPLE.", "", self.case["reference"] + " Paris."):
            with self.subTest(output=output):
                passed, score = waza_cleanup.score_output(self.case, output, 0.01)
                self.assertFalse(passed)
                self.assertEqual(score["score"], 0)

    def test_filler_sentinel_and_quality_threshold(self):
        case = next(case for case in self.dataset["cases"] if case.get("expect_empty"))
        self.assertTrue(waza_cleanup.score_output(case, "[[EMPTY]]", 0.9)[0])
        self.assertFalse(waza_cleanup.score_output(case, "Meaningful added text.", 0.9)[0])
        unpunctuated = self.case["reference"].rstrip(".!?")
        self.assertTrue(waza_cleanup.score_output(self.case, unpunctuated, 0.8)[0])
        self.assertFalse(waza_cleanup.score_output(self.case, unpunctuated, 1.0)[0])

    @unittest.skipUnless(shutil.which("waza"), "Optional Waza CLI is not installed")
    def test_real_waza_preserves_errors_and_enforces_golden_gate(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            dataset_path = root / "dataset.json"
            waza_cleanup.write_json(dataset_path, self.dataset)
            results = {}
            for name in ("passing", "failing"):
                report = copy.deepcopy(self.report)
                if name == "failing":
                    report["results"][0]["output"] = "PINEAPPLE."
                    report["results"][1]["error"] = "synthetic timeout"
                report_path = root / f"{name}.json"
                waza_cleanup.write_json(report_path, report)
                args = SimpleNamespace(
                    report=report_path, dataset=dataset_path, output_dir=root / name,
                    minimum_score=0.9, category=None, waza=shutil.which("waza"),
                )
                with redirect_stdout(io.StringIO()):
                    waza_cleanup.grade_report(args)
                results[name] = root / name / "graded.json"
            failing = json.loads(results["failing"].read_text())
            task = failing["tasks"][0]
            self.assertTrue(task["golden"])
            self.assertEqual(task["runs"][0]["status"], "failed")
            self.assertEqual(task["runs"][1]["status"], "error")
            self.assertEqual(task["runs"][1]["error_msg"], "synthetic timeout")
            self.assertEqual(task["runs"][0]["validations"]["cleanup-quality"]["score"], 0)
            for name, expected in (("passing", 0), ("failing", 2)):
                gate = subprocess.run([
                    shutil.which("waza"), "--no-update-check", "gate",
                    "--baseline", str(results["passing"]), "--current", str(results[name]),
                    "--on-new-tasks", "fail", "--on-removed-tasks", "fail",
                ], capture_output=True, text=True)
                self.assertEqual(gate.returncode, expected, gate.stdout + gate.stderr)


if __name__ == "__main__":
    unittest.main()
