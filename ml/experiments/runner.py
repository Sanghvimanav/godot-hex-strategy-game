from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

from ml.experiments.manifest import ManifestError, build_plan, load_manifest
from ml.experiments.results import (
    ResultContractError,
    build_scorecard,
    completed_shard_ids,
    load_shard_results,
    matching_shard_results,
)


def _read_json(path: str | Path) -> dict[str, Any]:
    with Path(path).open("r", encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict):
        raise ValueError(f"{path} must contain a JSON object")
    return data


def _write_json(path: str | Path | None, data: dict[str, Any]) -> None:
    text = json.dumps(data, indent=2, sort_keys=True) + "\n"
    if path:
        target = Path(path)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")
    else:
        sys.stdout.write(text)


def _append_github_output(path: str | Path, plan: dict[str, Any]) -> None:
    pending = plan["pending_shards"]
    with Path(path).open("a", encoding="utf-8") as handle:
        handle.write(f"experiment_id={plan['experiment_id']}\n")
        handle.write(f"tier={plan['tier']}\n")
        handle.write(f"pending_count={len(pending)}\n")
        handle.write("matrix=" + json.dumps({"include": pending}, separators=(",", ":")) + "\n")


def _cmd_validate(args: argparse.Namespace) -> int:
    manifest = load_manifest(args.manifest)
    summary = {
        "schema_version": manifest["schema_version"],
        "experiment_id": manifest["experiment_id"],
        "tiers": sorted(manifest["tiers"]),
        "partitions": sorted(manifest["seed_partitions"]),
        "valid": True,
    }
    _write_json(args.output, summary)
    return 0


def _cmd_plan(args: argparse.Namespace) -> int:
    manifest = load_manifest(args.manifest)
    base_plan = build_plan(
        manifest,
        args.tier,
        rules_sha=args.rules_sha,
        checkpoint_sha256=args.checkpoint_sha256,
    )

    completed: set[str] = set()
    if args.results_dir:
        all_results = load_shard_results(args.results_dir)
        exact_results = matching_shard_results(base_plan, all_results)
        completed = completed_shard_ids(exact_results)
    if args.completed_shard:
        completed.update(args.completed_shard)

    plan = build_plan(
        manifest,
        args.tier,
        rules_sha=args.rules_sha,
        checkpoint_sha256=args.checkpoint_sha256,
        completed_shards=completed,
    )
    _write_json(args.output, plan)
    if args.github_output:
        _append_github_output(args.github_output, plan)
    return 0


def _cmd_missing(args: argparse.Namespace) -> int:
    plan = _read_json(args.plan)
    expected = {item["shard_id"] for item in plan.get("expected_shards", [])}
    results = matching_shard_results(plan, load_shard_results(args.results_dir))
    completed = completed_shard_ids(results)
    payload = {
        "expected": sorted(expected),
        "completed": sorted(completed),
        "missing": sorted(expected - completed),
    }
    _write_json(args.output, payload)
    return 0


def _cmd_summarize(args: argparse.Namespace) -> int:
    plan = _read_json(args.plan)
    results = matching_shard_results(plan, load_shard_results(args.results_dir))
    scorecard = build_scorecard(plan, results)
    _write_json(args.output, scorecard)
    if args.github_output:
        with Path(args.github_output).open("a", encoding="utf-8") as handle:
            handle.write(f"passed={'true' if scorecard['passed'] else 'false'}\n")
            handle.write(f"missing_count={len(scorecard['shards']['missing_ids'])}\n")
    if args.require_pass and not scorecard["passed"]:
        return 2
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Versioned experiment planning, resume checks, and standard scorecards."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    validate = subparsers.add_parser("validate", help="Validate a versioned experiment manifest")
    validate.add_argument("manifest")
    validate.add_argument("--output")
    validate.set_defaults(func=_cmd_validate)

    plan = subparsers.add_parser("plan", help="Resolve a manifest tier into stable shard IDs")
    plan.add_argument("manifest")
    plan.add_argument("--tier", required=True)
    plan.add_argument("--rules-sha", required=True)
    plan.add_argument("--checkpoint-sha256")
    plan.add_argument("--results-dir", help="Downloaded prior shard results; only exact provenance matches resume")
    plan.add_argument("--completed-shard", action="append", default=[], help="Explicitly mark a trusted shard ID complete")
    plan.add_argument("--output")
    plan.add_argument("--github-output", help="Append matrix and counts to a GitHub Actions output file")
    plan.set_defaults(func=_cmd_plan)

    missing = subparsers.add_parser("missing", help="Compare a plan against exact-provenance shard results")
    missing.add_argument("--plan", required=True)
    missing.add_argument("--results-dir", required=True)
    missing.add_argument("--output")
    missing.set_defaults(func=_cmd_missing)

    summarize = subparsers.add_parser("summarize", help="Build the standard scorecard and evaluate gates")
    summarize.add_argument("--plan", required=True)
    summarize.add_argument("--results-dir", required=True)
    summarize.add_argument("--output")
    summarize.add_argument("--github-output")
    summarize.add_argument("--require-pass", action="store_true")
    summarize.set_defaults(func=_cmd_summarize)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return int(args.func(args))
    except (ManifestError, ResultContractError, OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"experiment runner error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
