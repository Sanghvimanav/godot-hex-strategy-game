"""Assemble fresh sibling supervision and audit reserved evaluation exclusions."""
import argparse
import json
from pathlib import Path
from .build_replay_buffer import _read_jsonl, _write_jsonl, build_replay, build_ranking_replay

RESERVED_SEEDS = {base + i * 7919 for base in (2100001, 3100001) for i in range(10)}


def audit(rows):
    for row in rows:
        source = row.get("source", {})
        if int(source.get("scenario_seed", -1)) in RESERVED_SEEDS or source.get("map_profile") == "phase1_unfamiliar_v1":
            raise ValueError("reserved Phase 1 evaluation data found in training")


def main():
    parser = argparse.ArgumentParser()
    for name in ("fresh", "parent", "output"):
        parser.add_argument(f"--{name}", type=Path, required=True)
    args = parser.parse_args()
    new_values = [r for p in args.fresh.rglob("examples.jsonl") for r in _read_jsonl(p)]
    new_pairs = [r for p in args.fresh.rglob("neural_ranking_pairs.jsonl") for r in _read_jsonl(p)]
    old_values_path = next(args.parent.rglob("combined_examples.jsonl"))
    old_pairs_path = next(args.parent.rglob("combined_ranking_pairs.jsonl"))
    old_values, old_pairs = _read_jsonl(old_values_path), _read_jsonl(old_pairs_path)
    audit(new_values + new_pairs + old_values + old_pairs)
    values, value_report = build_replay(new_values, old_values, 5000, 0)
    pairs, ranking_report = build_ranking_replay(new_pairs + old_pairs, 5000)
    if not values or not pairs or not new_pairs:
        raise ValueError("fresh sibling supervision is required; do not silently reuse only old pairs")
    _write_jsonl(args.output / "examples.jsonl", values)
    _write_jsonl(args.output / "ranking_pairs.jsonl", pairs)
    args.output.joinpath("dataset_report.json").write_text(json.dumps({
        "fresh_value_examples": len(new_values), "fresh_ranking_pairs": len(new_pairs),
        "evaluation_excluded_from_training": True,
        "value_replay": value_report, "ranking_replay": ranking_report}, indent=2) + "\n")


if __name__ == "__main__":
    main()
