#!/usr/bin/env python3
"""Grade captured OpenWritr cleanup results with Waza, without rerunning models."""

import argparse
import importlib.util
import json
import math
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path


SCRIPT = Path(__file__).resolve()
SPEC = importlib.util.spec_from_file_location(
    "cleanup_evaluation", SCRIPT.with_name("evaluate-cleanup-models.py")
)
cleanup_evaluation = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(cleanup_evaluation)


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def minimum_score(value):
    score = float(value)
    if not math.isfinite(score) or not 0 < score <= 1:
        raise argparse.ArgumentTypeError("minimum score must be greater than 0 and at most 1")
    return score


def validate_report(report, cases):
    rows = report["results"]
    configuration = report["configuration"]
    models = configuration["models"]
    runs = configuration["runs"]
    if not rows or not models or len(set(models)) != len(models):
        raise ValueError("Report must contain results and unique model IDs")
    if not isinstance(runs, int) or isinstance(runs, bool) or runs < 1:
        raise ValueError("Report runs must be a positive integer")
    seen = set()
    case_ids = set()
    for row in rows:
        model, case_id, run = row["model"], row["case_id"], row["run"]
        if not all(re.fullmatch(r"[a-zA-Z0-9._-]+", name) for name in (model, case_id)):
            raise ValueError("Model and case IDs must be safe filename components")
        if model not in models or not isinstance(run, int) or isinstance(run, bool) or not 1 <= run <= runs:
            raise ValueError(f"Unexpected model or run for {model}/{case_id}")
        if case_id not in cases:
            raise ValueError(f"Unknown dataset case: {case_id}")
        for field in ("input", "reference", "category"):
            if row[field] != cases[case_id][field]:
                raise ValueError(f"Dataset {field} differs from captured case: {case_id}")
        if not isinstance(row["output"], str):
            raise ValueError(f"Output must be text: {model}/{case_id}")
        if row["error"] is not None and not isinstance(row["error"], str):
            raise ValueError(f"Error must be text or null: {model}/{case_id}")
        duration = row["duration_ms"]
        if not isinstance(duration, (int, float)) or not math.isfinite(duration) or duration < 0:
            raise ValueError(f"Invalid duration: {model}/{case_id}")
        key = (model, case_id, run)
        if key in seen:
            raise ValueError(f"Duplicate model/case/run: {key}")
        seen.add(key)
        case_ids.add(case_id)
    if len(case_ids) != configuration["cases"]:
        raise ValueError("Report case count does not match captured results")
    expected = {
        (model, case_id, run)
        for model in models for case_id in case_ids for run in range(1, runs + 1)
    }
    if seen != expected:
        raise ValueError("Report is missing model/case/run results; refusing partial grading")


def export_report(report, dataset, output_dir, threshold, category=None):
    cases = {case["id"]: case for case in dataset["cases"]}
    if len(cases) != len(dataset["cases"]):
        raise ValueError("Dataset contains duplicate case IDs")
    validate_report(report, cases)
    selected = [
        row for row in report["results"]
        if category is None or row["category"] == category
    ]
    if not selected:
        raise ValueError(f"No captured cases match category: {category}")
    groups = defaultdict(list)
    for row in selected:
        groups[(row["model"], row["case_id"])].append(row)

    tasks = []
    task_paths = []
    for index, ((model, case_id), rows) in enumerate(groups.items(), 1):
        case = cases[case_id]
        task_id = f"{model}/{case_id}"
        filename = f"{index:04d}.yaml"
        case_path = output_dir / "cases" / f"{index:04d}.json"
        write_json(case_path, case)
        task_path = output_dir / "tasks" / filename
        write_json(task_path, {
            "id": task_id,
            "name": task_id,
            "description": "Grade captured cleanup text; do not execute with waza run.",
            "inputs": {"prompt": case["input"]},
            "golden": bool(case.get("expect_preserved_text")),
            "graders": [{
                "name": "cleanup-quality",
                "type": "program",
                "config": {
                    "command": sys.executable,
                    "args": [
                        str(SCRIPT), "score", "--case", str(case_path),
                        "--minimum-score", str(threshold),
                    ],
                    "timeout": 30,
                },
            }],
        })
        task_paths.append(f"tasks/{filename}")
        runs = [{
            "run_number": row["run"],
            "status": "error" if row["error"] else "passed",
            "error_msg": row["error"] or "",
            "duration_ms": round(row["duration_ms"]),
            "final_output": row["output"],
            "validations": {},
            "session_digest": {},
        } for row in sorted(rows, key=lambda row: row["run"])]
        tasks.append({
            "test_id": task_id,
            "display_name": task_id,
            "group": case["category"],
            "golden": bool(case.get("expect_preserved_text")),
            "status": "error" if any(row["error"] for row in rows) else "passed",
            "runs": runs,
        })

    spec_path = output_dir / "eval.yaml"
    write_json(spec_path, {
        "schemaVersion": "1.0",
        "name": "openwritr-captured-cleanup",
        "description": "Offline grading only; production execution remains in OpenWritr's runner.",
        "skill": "openwritr-cleanup",
        "version": "1.0",
        "config": {
            "trials_per_task": report["configuration"]["runs"],
            "timeout_seconds": 30,
        },
        "tasks": task_paths,
    })
    result_path = output_dir / "captured.json"
    write_json(result_path, {
        "schemaVersion": "1.0",
        "eval_id": report["generated_at"],
        "eval_name": report["configuration"]["prompt_profile"],
        "skill": "openwritr-cleanup",
        "timestamp": report["generated_at"],
        "config": {
            "runs_per_test": report["configuration"]["runs"],
            "model_id": ",".join(report["configuration"]["models"]),
            "engine_type": "openwritr-captured-report",
            "timeout_sec": report["configuration"].get("timeout", 0),
        },
        "summary": {},
        "metrics": {},
        "metadata": {
            "execution": "Imported captured outputs; Waza did not execute model requests.",
            "source_configuration": report["configuration"],
            "minimum_cleanup_score": threshold,
            "category_filter": category,
        },
        "tasks": tasks,
    })
    return spec_path, result_path


def grade_report(args):
    report = json.loads(args.report.read_text(encoding="utf-8"))
    dataset = json.loads(args.dataset.read_text(encoding="utf-8"))
    output_dir = args.output_dir.resolve()
    spec_path, captured_path = export_report(
        report, dataset, output_dir, args.minimum_score, args.category
    )
    graded_path = output_dir / "graded.json"
    result = subprocess.run(
        [
            args.waza, "--no-update-check", "grade", str(spec_path),
            "--results", str(captured_path), "--output", str(graded_path),
        ],
        capture_output=True, text=True, check=True,
    )
    grades = json.loads(result.stdout)
    graded = json.loads(graded_path.read_text(encoding="utf-8"))
    captured = json.loads(captured_path.read_text(encoding="utf-8"))
    original_tasks = {task["test_id"]: task for task in captured["tasks"]}
    if {task["test_id"] for task in graded["tasks"]} != set(original_tasks):
        raise ValueError("Waza did not grade every captured task")
    for task in graded["tasks"]:
        original = original_tasks[task["test_id"]]
        if len(task["runs"]) != len(original["runs"]):
            raise ValueError(f"Waza did not grade every run: {task['test_id']}")
        # Waza 0.38.7 grade drops task golden/group fields; restore gate semantics.
        task["golden"] = original["golden"]
        task["group"] = original["group"]
    write_json(graded_path, graded)
    write_json(output_dir / "grades.json", grades)
    if result.stderr:
        print(result.stderr, file=sys.stderr, end="")
    print(
        f"Graded {len(graded['tasks'])} captured tasks; "
        f"all passed: {grades['passed']}; pass/fail score: {grades['overall_score']:.4f}"
    )
    print(f"Waza results: {graded_path}")
    print("Grading completed; use waza gate to enforce regression and must-pass checks.")


def score_output(case, output, threshold):
    score = cleanup_evaluation.deterministic_score(
        case, cleanup_evaluation.normalize_model_output(output)
    )
    passed = score["score"] >= threshold
    if case.get("expect_preserved_text"):
        passed = passed and score["preservation_passed"]
    return passed, score


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    grade = commands.add_parser("grade", help="Export and grade a captured cleanup report")
    grade.add_argument("report", type=Path)
    grade.add_argument("--output-dir", type=Path, required=True)
    grade.add_argument("--dataset", type=Path, default=cleanup_evaluation.DEFAULT_DATASET)
    grade.add_argument("--minimum-score", type=minimum_score, default=0.90)
    grade.add_argument("--category")
    grade.add_argument("--waza", default="waza")
    score = commands.add_parser("score", help="Waza program grader: read captured output on stdin")
    score.add_argument("--case", type=Path, required=True)
    score.add_argument("--minimum-score", type=minimum_score, default=0.90)
    args = parser.parse_args()
    try:
        if args.command == "grade":
            grade_report(args)
            return 0
        case = json.loads(args.case.read_text(encoding="utf-8"))
        passed, details = score_output(case, sys.stdin.read(), args.minimum_score)
        print(json.dumps(details, ensure_ascii=False))
        return 0 if passed else 1
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        print(f"Waza cleanup {args.command} failed: {error}", file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError):
            print(error.stderr or error.stdout or "Waza returned no diagnostics", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
