from __future__ import annotations

import argparse
import json
import random
from collections import Counter
from pathlib import Path
from typing import Any, Iterable


def _read_jsonl(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    rows: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as handle:
        for line_number, raw in enumerate(handle, start=1):
            line = raw.strip()
            if not line:
                continue
            value = json.loads(line)
            if not isinstance(value, dict):
                raise ValueError(f"{path}:{line_number} is not a JSON object")
            rows.append(value)
    return rows


def _read_root(root: Path, name: str) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for path in sorted(root.rglob(name)):
        rows.extend(_read_jsonl(path))
    return rows


def _write_jsonl(path: Path, rows: Iterable[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, separators=(",", ":")) + "\n")


def _source(row: dict[str, Any]) -> dict[str, Any]:
    value = row.get("source", {})
    return value if isinstance(value, dict) else {}


def _is_frozen_arena_value(row: dict[str, Any]) -> bool:
    source = _source(row)
    if source.get("data_origin") == "arena_divergence_hard_negative":
        return True
    return (
        source.get("data_policy") == "neural_vs_handwritten"
        and bool(source.get("arena_preset"))
    )


def _is_frozen_arena_pair(row: dict[str, Any]) -> bool:
    source = _source(row)
    return (
        source.get("data_origin") == "arena_divergence_hard_negative"
        or bool(source.get("tactical_focus_reweight"))
    )


def _sample(rows: list[dict[str, Any]], count: int, seed: int) -> list[dict[str, Any]]:
    if count <= 0:
        return []
    if len(rows) <= count:
        return list(rows)
    indices = list(range(len(rows)))
    random.Random(seed).shuffle(indices)
    selected = sorted(indices[:count])
    return [rows[index] for index in selected]


def build_replay(
    new_examples: list[dict[str, Any]],
    history_examples: list[dict[str, Any]],
    max_examples: int,
    seed: int,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    eligible_history = [row for row in history_examples if not _is_frozen_arena_value(row)]
    excluded_history = len(history_examples) - len(eligible_history)

    new_selected = _sample(new_examples, min(max_examples, len(new_examples)), seed)
    remaining = max(0, max_examples - len(new_selected))
    history_selected = _sample(eligible_history, remaining, seed + 1)
    combined = new_selected + history_selected

    manifest = {
        "max_examples": max_examples,
        "seed": seed,
        "new_examples_seen": len(new_examples),
        "new_examples_selected": len(new_selected),
        "history_examples_seen": len(history_examples),
        "history_examples_excluded_frozen_arena": excluded_history,
        "history_examples_eligible": len(eligible_history),
        "history_examples_selected": len(history_selected),
        "output_examples": len(combined),
        "data_policy_counts": dict(Counter(
            str(_source(row).get("data_policy", "")) for row in combined
        )),
        "scenario_family_counts": dict(Counter(
            str(_source(row).get("base_scenario_id", "")) for row in combined
        )),
    }
    return combined, manifest


def build_ranking_replay(
    history_pairs: list[dict[str, Any]],
    max_pairs: int,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    eligible = [row for row in history_pairs if not _is_frozen_arena_pair(row)]
    excluded = len(history_pairs) - len(eligible)
    selected = eligible[-max_pairs:] if max_pairs > 0 else []
    manifest = {
        "max_pairs": max_pairs,
        "history_pairs_seen": len(history_pairs),
        "history_pairs_excluded_frozen_arena": excluded,
        "history_pairs_eligible": len(eligible),
        "output_pairs": len(selected),
        "pair_kind_counts": dict(Counter(str(row.get("pair_kind", "")) for row in selected)),
        "continuation_policy_counts": dict(Counter(
            str(row.get("continuation_policy", "")) for row in selected
        )),
    }
    return selected, manifest


def run(args: argparse.Namespace) -> dict[str, Any]:
    new_examples = _read_root(Path(args.new_root), "examples.jsonl")
    history_examples = _read_jsonl(Path(args.history_examples)) if args.history_examples else []
    replay, replay_manifest = build_replay(
        new_examples,
        history_examples,
        args.max_examples,
        args.seed,
    )
    if not replay:
        raise ValueError("replay buffer would be empty")
    _write_jsonl(Path(args.output_examples), replay)

    ranking_manifest: dict[str, Any] | None = None
    if args.output_ranking_pairs:
        history_pairs = _read_jsonl(Path(args.history_ranking_pairs)) if args.history_ranking_pairs else []
        ranking, ranking_manifest = build_ranking_replay(history_pairs, args.max_ranking_pairs)
        if not ranking:
            raise ValueError("ranking replay would be empty")
        _write_jsonl(Path(args.output_ranking_pairs), ranking)

    manifest: dict[str, Any] = {"value_replay": replay_manifest}
    if ranking_manifest is not None:
        manifest["ranking_replay"] = ranking_manifest
    manifest_path = Path(args.manifest)
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(manifest, indent=2))
    return manifest


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Build a bounded recent-policy replay buffer and exclude frozen Arena supervision."
    )
    parser.add_argument("--new-root", required=True)
    parser.add_argument("--history-examples", default=None)
    parser.add_argument("--output-examples", required=True)
    parser.add_argument("--max-examples", type=int, default=5000)
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--history-ranking-pairs", default=None)
    parser.add_argument("--output-ranking-pairs", default=None)
    parser.add_argument("--max-ranking-pairs", type=int, default=1000)
    parser.add_argument("--manifest", required=True)
    return parser


def main() -> None:
    run(build_parser().parse_args())


if __name__ == "__main__":
    main()
