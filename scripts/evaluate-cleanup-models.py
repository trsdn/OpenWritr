#!/usr/bin/env python3
"""Benchmark OpenWritr cleanup providers against synthetic transcripts."""

import argparse
import difflib
import json
import math
import re
import statistics
import subprocess
import sys
import time
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_DATASET = ROOT / "eval" / "cleanup-cases.json"
DEFAULT_OUTPUT = ROOT / ".artifacts" / "cleanup-eval"
DEFAULT_PROMPT_CONFIG = (
    ROOT / "Sources" / "OpenWritr" / "Resources" / "cleanup-prompt-profiles.json"
)
GRAMMAR_ENHANCER = ROOT / "Sources" / "OpenWritr" / "GrammarEnhancer.swift"
APPLE_HELPER_SOURCE = ROOT / "scripts" / "apple-intelligence-eval.swift"
APPLE_SHARED_SOURCES = [
    ROOT / "Sources" / "OpenWritr" / "CleanupIntegrityValidator.swift",
    ROOT / "Sources" / "OpenWritr" / "AppleCleanupPolicy.swift",
]
APPLE_HELPER_BINARY = ROOT / ".build" / "cleanup-eval" / "apple-intelligence-eval"
APPLE_REQUEST_PATH = ROOT / ".build" / "cleanup-eval" / "requests.json"
DEFAULT_MODELS = [
    "apple-intelligence",
    "gpt-5.6-luna",
    "gemini-3.7-flash",
    "mai-code-1.1-flash",
    "gpt-5-mini",
    "claude-haiku-4.5",
]
GITHUB_PRICING_URL = (
    "https://docs.github.com/en/copilot/reference/copilot-billing/models-and-pricing"
)
MODEL_PRICING = {
    "apple-intelligence": {
        "input": 0.0,
        "cached_input": 0.0,
        "cache_write": 0.0,
        "output": 0.0,
    },
    "gpt-5.6-luna": {
        "input": 0.20,
        "cached_input": 0.02,
        "cache_write": 0.25,
        "output": 1.20,
    },
    "gemini-3.7-flash": {
        "input": 0.75,
        "cached_input": 0.075,
        "cache_write": None,
        "output": 3.75,
    },
    "mai-code-1.1-flash": {
        "input": 0.20,
        "cached_input": 0.02,
        "cache_write": None,
        "output": 1.20,
    },
    "gpt-5-mini": {
        "input": 0.25,
        "cached_input": 0.025,
        "cache_write": None,
        "output": 2.00,
    },
    "claude-haiku-4.5": {
        "input": 1.00,
        "cached_input": 0.10,
        "cache_write": 1.25,
        "output": 5.00,
    },
}


def parse_args():
    parser = argparse.ArgumentParser(
        description="Compare cleanup quality, reliability, and latency across OpenWritr models."
    )
    parser.add_argument("--models", nargs="+", default=DEFAULT_MODELS)
    parser.add_argument("--dataset", type=Path, default=DEFAULT_DATASET)
    parser.add_argument("--prompt-config", type=Path, default=DEFAULT_PROMPT_CONFIG)
    parser.add_argument("--runs", type=int, default=1)
    parser.add_argument("--case-limit", type=int)
    parser.add_argument("--case-ids", nargs="+")
    parser.add_argument("--timeout", type=int, default=45)
    parser.add_argument("--workers", type=int, default=3)
    parser.add_argument("--judge-model")
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT)
    return parser.parse_args()


def load_cleanup_prompt():
    source = GRAMMAR_ENHANCER.read_text(encoding="utf-8")
    match = re.search(r'static let defaultCleanupPrompt = "(.*)"', source)
    if not match:
        raise RuntimeError("Could not find GrammarEnhancer.defaultCleanupPrompt")
    return json.loads(f'"{match.group(1)}"')


def load_prompt_configuration(path):
    production_prompt = load_cleanup_prompt()
    if not path:
        return {
            "name": "production",
            "common_prompt": production_prompt,
            "model_suffixes": {},
        }
    configuration = json.loads(path.read_text(encoding="utf-8"))
    common_prompt = configuration.get("common_prompt", production_prompt).strip()
    if not common_prompt:
        raise ValueError("Prompt configuration common_prompt must not be empty")
    return {
        "name": configuration.get("name", path.stem),
        "common_prompt": common_prompt,
        "model_suffixes": configuration.get("model_suffixes", {}),
    }


def prompt_for_model(configuration, model):
    suffix = str(configuration["model_suffixes"].get(model, "")).strip()
    if not suffix:
        return configuration["common_prompt"]
    return f"{configuration['common_prompt']}\n\nModel-specific requirements:\n{suffix}"


def normalize(text):
    text = text.casefold().replace("„", '"').replace("“", '"')
    text = re.sub(r"[^\w\s.-]", " ", text, flags=re.UNICODE)
    return re.sub(r"\s+", " ", text).strip()


def normalize_model_output(text):
    trimmed = text.strip()
    return "" if trimmed == "[[EMPTY]]" else trimmed


def ends_with_punctuation(text):
    return not text or text.rstrip().endswith((".", "!", "?", "…"))


def deterministic_score(case, output):
    normalized_output = normalize(output)
    normalized_reference = normalize(case["reference"])
    expected_empty = case.get("expect_empty", False)

    if expected_empty:
        empty_score = float(not normalized_output)
        return {
            "score": empty_score,
            "reference_similarity": empty_score,
            "required_terms": empty_score,
            "forbidden_terms": empty_score,
            "punctuation": empty_score,
            "output_only": empty_score,
        }

    required = case.get("must_contain", [])
    forbidden = case.get("must_not_contain", [])
    required_score = (
        sum(normalize(term) in normalized_output for term in required) / len(required)
        if required
        else 1.0
    )
    forbidden_score = (
        sum(normalize(term) not in normalized_output for term in forbidden) / len(forbidden)
        if forbidden
        else 1.0
    )
    similarity = difflib.SequenceMatcher(
        None, normalized_reference, normalized_output
    ).ratio()
    punctuation = float(ends_with_punctuation(output))
    output_only = float(
        not re.match(
            r"^(corrected|cleaned|output|result|here(?:'s| is))\s*:",
            output.strip(),
            flags=re.IGNORECASE,
        )
    )
    score = (
        0.35 * required_score
        + 0.25 * forbidden_score
        + 0.25 * similarity
        + 0.10 * punctuation
        + 0.05 * output_only
    )
    return {
        "score": round(score, 4),
        "reference_similarity": round(similarity, 4),
        "required_terms": round(required_score, 4),
        "forbidden_terms": round(forbidden_score, 4),
        "punctuation": punctuation,
        "output_only": output_only,
    }


def run_copilot(model, prompt, text, timeout):
    start = time.monotonic()
    command = [
        "copilot",
        "-p",
        f"{prompt}\n\n{text}",
        "-s",
        "--model",
        model,
        "--no-custom-instructions",
        "--disable-builtin-mcps",
    ]
    try:
        completed = subprocess.run(
            command,
            cwd=ROOT,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
        duration_ms = round((time.monotonic() - start) * 1000)
        output = normalize_model_output(completed.stdout)
        error = None
        if completed.returncode != 0:
            error = completed.stderr.strip() or f"copilot exited {completed.returncode}"
        elif not output:
            error = completed.stderr.strip() or "copilot returned empty output"
        return output, error, duration_ms
    except subprocess.TimeoutExpired:
        return "", f"timed out after {timeout}s", round((time.monotonic() - start) * 1000)


def build_apple_helper():
    APPLE_HELPER_BINARY.parent.mkdir(parents=True, exist_ok=True)
    helper_sources = [APPLE_HELPER_SOURCE, *APPLE_SHARED_SOURCES]
    if (
        APPLE_HELPER_BINARY.exists()
        and APPLE_HELPER_BINARY.stat().st_mtime
        >= max(source.stat().st_mtime for source in helper_sources)
    ):
        return
    completed = subprocess.run(
        [
            "swiftc",
            "-parse-as-library",
            "-O",
            "-target",
            "arm64-apple-macosx26.0",
            *(str(source) for source in helper_sources),
            "-o",
            str(APPLE_HELPER_BINARY),
        ],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    if completed.returncode != 0:
        raise RuntimeError(completed.stderr.strip() or "Apple helper compilation failed")


def run_apple_batch(cases, prompt, timeout):
    build_apple_helper()
    requests = [
        {"id": case["id"], "prompt": prompt, "text": case["input"]} for case in cases
    ]
    APPLE_REQUEST_PATH.write_text(
        json.dumps(requests, ensure_ascii=False),
        encoding="utf-8",
    )
    try:
        completed = subprocess.run(
            [str(APPLE_HELPER_BINARY), str(APPLE_REQUEST_PATH)],
            cwd=ROOT,
            capture_output=True,
            text=True,
            timeout=max(timeout * len(cases), timeout),
            check=False,
        )
    finally:
        APPLE_REQUEST_PATH.unlink(missing_ok=True)
    if completed.returncode != 0:
        message = completed.stderr.strip() or "Apple helper failed"
        return {
            case["id"]: {"output": "", "error": message, "durationMilliseconds": 0}
            for case in cases
        }
    return {item["id"]: item for item in json.loads(completed.stdout)}


def parse_json_object(text):
    match = re.search(r"\{.*\}", text, flags=re.DOTALL)
    if not match:
        raise ValueError("judge returned no JSON object")
    return json.loads(match.group(0))


def judge_output(judge_model, case, output, timeout):
    prompt = f"""Evaluate a speech-transcript cleanup without knowing which model produced it.
Return JSON only with this schema:
{{"fidelity":0-5,"cleanup":0-5,"language":0-5,"terminology":0-5,"conciseness":0-5,"hallucination":true|false,"reason":"short explanation"}}

Scoring:
- fidelity: preserves facts, intent, negation, numbers, and tone
- cleanup: fixes grammar, spelling, punctuation, fillers, and stuttering
- language: preserves the original language and mixed-language phrases
- terminology: preserves product names, commands, and technical terms
- conciseness: returns only corrected text without commentary

Input transcript:
{case["input"]}

Reference cleanup:
{case["reference"]}

Candidate cleanup:
{output}
"""
    response, error, _ = run_copilot(judge_model, "", prompt, timeout)
    if error:
        return None, error
    try:
        value = parse_json_object(response)
        dimensions = [
            float(value[name])
            for name in ("fidelity", "cleanup", "language", "terminology", "conciseness")
        ]
        value["score"] = round(sum(dimensions) / (len(dimensions) * 5), 4)
        return value, None
    except (ValueError, KeyError, TypeError, json.JSONDecodeError) as exception:
        return None, f"invalid judge response: {exception}"


def summarize(rows):
    grouped = defaultdict(list)
    for row in rows:
        grouped[row["model"]].append(row)
    summary = {}
    for model, model_rows in grouped.items():
        successful = [row for row in model_rows if not row["error"]]
        deterministic = [row["deterministic"]["score"] for row in successful]
        judged = [
            row["judge"]["score"]
            for row in successful
            if row.get("judge") and "score" in row["judge"]
        ]
        latencies = [row["duration_ms"] for row in successful]
        first_pass_latencies = [
            row["apple_metrics"]["first_pass_duration_ms"]
            for row in successful
            if row.get("apple_metrics")
        ]
        repair_latencies = [
            row["apple_metrics"]["repair_duration_ms"]
            for row in successful
            if row.get("apple_metrics")
            and row["apple_metrics"]["repair_duration_ms"] is not None
        ]
        repair_attempts = sum(
            bool(row.get("apple_metrics", {}).get("repair_attempted"))
            for row in successful
        )
        repairs_used = sum(
            bool(row.get("apple_metrics", {}).get("repair_used"))
            for row in successful
        )
        violation_counts = defaultdict(int)
        violation_rows = 0
        for row in successful:
            violations = (row.get("integrity_report") or {}).get("violations", [])
            if violations:
                violation_rows += 1
            for violation in violations:
                violation_counts[violation["category"]] += 1

        category_summary = {}
        for category in sorted({row["category"] for row in model_rows}):
            category_rows = [
                row for row in successful if row["category"] == category
            ]
            scores = [row["deterministic"]["score"] for row in category_rows]
            category_latencies = [row["duration_ms"] for row in category_rows]
            category_summary[category] = {
                "requests": sum(row["category"] == category for row in model_rows),
                "successes": len(category_rows),
                "deterministic_mean": round(statistics.mean(scores), 4)
                if scores
                else None,
                "deterministic_min": round(min(scores), 4) if scores else None,
                "latency_mean_ms": round(statistics.mean(category_latencies))
                if category_latencies
                else None,
            }

        run_scores = []
        for run in sorted({row["run"] for row in model_rows}):
            scores = [
                row["deterministic"]["score"]
                for row in successful
                if row["run"] == run
            ]
            if scores:
                run_scores.append(round(statistics.mean(scores), 4))
        summary[model] = {
            "requests": len(model_rows),
            "successes": len(successful),
            "errors": len(model_rows) - len(successful),
            "deterministic_mean": round(statistics.mean(deterministic), 4)
            if deterministic
            else None,
            "deterministic_min": round(min(deterministic), 4)
            if deterministic
            else None,
            "judge_mean": round(statistics.mean(judged), 4) if judged else None,
            "latency_mean_ms": round(statistics.mean(latencies)) if latencies else None,
            "latency_p95_ms": round(
                sorted(latencies)[max(0, math.ceil(len(latencies) * 0.95) - 1)]
            )
            if latencies
            else None,
            "production_equivalent_latency_mean_ms": round(statistics.mean(latencies))
            if latencies
            else None,
            "candidate_timings": {
                "first_pass_mean_ms": round(statistics.mean(first_pass_latencies))
                if first_pass_latencies
                else None,
                "repair_mean_ms": round(statistics.mean(repair_latencies))
                if repair_latencies
                else None,
            },
            "repairs": {
                "attempted": repair_attempts,
                "used": repairs_used,
                "attempt_rate": round(repair_attempts / len(successful), 4)
                if successful
                else None,
                "use_rate": round(repairs_used / len(successful), 4)
                if successful
                else None,
            },
            "integrity": {
                "rows_with_violations": violation_rows,
                "violation_rate": round(violation_rows / len(successful), 4)
                if successful
                else None,
                "violations_by_category": dict(sorted(violation_counts.items())),
            },
            "per_category": category_summary,
            "run_variance": {
                "means": run_scores,
                "minimum": min(run_scores) if run_scores else None,
                "maximum": max(run_scores) if run_scores else None,
                "range": round(max(run_scores) - min(run_scores), 4)
                if run_scores
                else None,
                "population_variance": round(statistics.pvariance(run_scores), 8)
                if len(run_scores) > 1
                else 0.0 if run_scores else None,
            },
            "github_usd_per_million_tokens": MODEL_PRICING.get(model),
        }
    return summary


def print_summary(summary):
    print("\nModel results")
    print(
        f"{'Model':<24} {'Success':>9} {'Rules':>8} {'Judge':>8} {'Mean ms':>10} {'P95 ms':>9}"
    )
    print("-" * 74)
    for model, result in sorted(
        summary.items(),
        key=lambda item: (
            item[1]["judge_mean"] if item[1]["judge_mean"] is not None else -1,
            item[1]["deterministic_mean"]
            if item[1]["deterministic_mean"] is not None
            else -1,
        ),
        reverse=True,
    ):
        judge = (
            f"{result['judge_mean']:.3f}"
            if result["judge_mean"] is not None
            else "-"
        )
        rules = (
            f"{result['deterministic_mean']:.3f}"
            if result["deterministic_mean"] is not None
            else "-"
        )
        print(
            f"{model:<24} {result['successes']:>3}/{result['requests']:<5} "
            f"{rules:>8} {judge:>8} "
            f"{str(result['latency_mean_ms'] or '-'):>10} "
            f"{str(result['latency_p95_ms'] or '-'):>9}"
        )
        if result["repairs"]["attempted"]:
            print(
                " " * 26
                + f"repairs {result['repairs']['used']}/{result['repairs']['attempted']} used; "
                + f"violations {result['integrity']['rows_with_violations']}; "
                + f"run variance {result['run_variance']['population_variance']}"
            )


def evaluate_case(model, case, prompt, timeout, judge_model):
    output, error, duration_ms = run_copilot(model, prompt, case["input"], timeout)
    if case.get("expect_empty") and error == "copilot returned empty output":
        error = None
    row = build_result_row(model, case, output, error, duration_ms)
    if judge_model and not error:
        judge, judge_error = judge_output(judge_model, case, output, timeout)
        row["judge"] = judge
        row["judge_error"] = judge_error
    return row


def build_result_row(model, case, output, error, duration_ms, apple_result=None):
    row = {
        "model": model,
        "case_id": case["id"],
        "category": case["category"],
        "input": case["input"],
        "reference": case["reference"],
        "output": output,
        "error": error,
        "duration_ms": duration_ms,
        "deterministic": deterministic_score(case, output) if not error else None,
    }
    if apple_result:
        row["integrity_report"] = apple_result.get("report")
        row["first_pass_integrity_report"] = apple_result.get("firstPassReport")
        row["repair_integrity_report"] = apple_result.get("repairReport")
        row["apple_metrics"] = {
            "first_pass_duration_ms": apple_result.get(
                "firstPassDurationMilliseconds", 0
            ),
            "repair_duration_ms": apple_result.get("repairDurationMilliseconds"),
            "repair_attempted": apple_result.get("repairAttempted", False),
            "repair_used": apple_result.get("repairUsed", False),
            "production_equivalent_latency_ms": duration_ms,
        }
    return row


def main():
    args = parse_args()
    if args.runs < 1:
        sys.exit("--runs must be at least 1")
    if args.workers < 1:
        sys.exit("--workers must be at least 1")
    dataset = json.loads(args.dataset.read_text(encoding="utf-8"))
    cases = dataset["cases"]
    if args.case_ids:
        requested = set(args.case_ids)
        cases = [case for case in cases if case["id"] in requested]
        missing = requested - {case["id"] for case in cases}
        if missing:
            sys.exit(f"Unknown case IDs: {', '.join(sorted(missing))}")
    cases = cases[: args.case_limit]
    prompt_configuration = load_prompt_configuration(args.prompt_config)
    rows = []

    for run_number in range(1, args.runs + 1):
        apple_results = {}
        if "apple-intelligence" in args.models:
            apple_results = run_apple_batch(
                cases,
                prompt_for_model(prompt_configuration, "apple-intelligence"),
                args.timeout,
            )

        for model in args.models:
            model_prompt = prompt_for_model(prompt_configuration, model)
            if model == "apple-intelligence":
                model_rows = []
                for case in cases:
                    result = apple_results[case["id"]]
                    row = build_result_row(
                        model,
                        case,
                        result["output"].strip(),
                        result.get("error"),
                        result["durationMilliseconds"],
                        apple_result=result,
                    )
                    if args.judge_model and not row["error"]:
                        judge, judge_error = judge_output(
                            args.judge_model,
                            case,
                            row["output"],
                            args.timeout,
                        )
                        row["judge"] = judge
                        row["judge_error"] = judge_error
                    model_rows.append(row)
            else:
                with ThreadPoolExecutor(max_workers=args.workers) as executor:
                    model_rows = list(
                        executor.map(
                            lambda case: evaluate_case(
                                model,
                                case,
                                model_prompt,
                                args.timeout,
                                args.judge_model,
                            ),
                            cases,
                        )
                    )

            for position, row in enumerate(model_rows, 1):
                print(
                    f"[run {run_number}/{args.runs}] [{position:02d}/{len(cases)}] "
                    f"{model}: {row['case_id']}",
                    flush=True,
                )
                row["run"] = run_number
                rows.append(row)

    summary = summarize(rows)
    report = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "configuration": {
            "models": args.models,
            "judge_model": args.judge_model,
            "runs": args.runs,
            "workers": args.workers,
            "cases": len(cases),
            "dataset": str(args.dataset.relative_to(ROOT)),
            "prompt_profile": prompt_configuration["name"],
            "common_prompt": prompt_configuration["common_prompt"],
            "model_suffixes": prompt_configuration["model_suffixes"],
            "pricing_source": GITHUB_PRICING_URL,
        },
        "summary": summary,
        "results": rows,
    }
    args.output_dir.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    report_path = args.output_dir / f"cleanup-eval-{timestamp}.json"
    latest_path = args.output_dir / "latest.json"
    rendered = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    report_path.write_text(rendered, encoding="utf-8")
    latest_path.write_text(rendered, encoding="utf-8")
    print_summary(summary)
    print(f"\nReport: {report_path}")
    print(f"Latest: {latest_path}")


if __name__ == "__main__":
    main()
