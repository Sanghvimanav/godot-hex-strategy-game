"""Merge deterministic self-play and counterfactual generator shards.

This module intentionally has no PyTorch dependency so the GitHub workflow can
merge/audit simulation outputs before installing the ML environment.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any, Iterable


FNV_OFFSET_BASIS = 2166136261
FNV_PRIME = 16777619
FNV_MASK = 0xFFFFFFFF


def stable_hash(key: str) -> int:
    value = FNV_OFFSET_BASIS
    for byte in key.encode("utf-8"):
        value ^= byte
        value = (value * FNV_PRIME) & FNV_MASK
    return value


def shard_for_key(key: str, shard_count: int) -> int:
    if shard_count <= 0:
        raise ValueError("shard_count must be positive")
    return stable_hash(key) % shard_count


def _read_jsonl(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        raise FileNotFoundError(path)
    rows: list[dict[str, Any]] = []
    for line_number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        line = raw.strip()
        if not line:
            continue
        value = json.loads(line)
        if not isinstance(value, dict):
            raise ValueError(f"{path}:{line_number} must contain a JSON object")
        rows.append(value)
    return rows


def _write_jsonl(path: Path, rows: Iterable[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    text = "".join(json.dumps(row, sort_keys=True, separators=(",", ":")) + "\n" for row in rows)
    path.write_text(text, encoding="utf-8")


def _write_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def _load_shards(root: Path) -> list[tuple[Path, dict[str, Any]]]:
    manifests = sorted(root.glob("*/manifest.json"))
    if not manifests and (root / "manifest.json").exists():
        manifests = [root / "manifest.json"]
    if not manifests:
        raise ValueError(f"no shard manifests found below {root}")
    result: list[tuple[Path, dict[str, Any]]] = []
    for path in manifests:
        value = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(value, dict):
            raise ValueError(f"manifest must be an object: {path}")
        result.append((path.parent, value))
    return result


def _validate_shard_set(
    shards: list[tuple[Path, dict[str, Any]]],
    expected_key: str,
    common_fields: Iterable[str],
) -> int:
    shard_counts = {int(manifest.get("shard_count", 0)) for _, manifest in shards}
    if len(shard_counts) != 1:
        raise ValueError(f"inconsistent shard_count values: {sorted(shard_counts)}")
    shard_count = next(iter(shard_counts))
    if shard_count <= 0:
        raise ValueError("shard_count must be positive")
    indices = {int(manifest.get("shard_index", -1)) for _, manifest in shards}
    expected_indices = set(range(shard_count))
    if indices != expected_indices:
        raise ValueError(f"expected shard indices {sorted(expected_indices)}, got {sorted(indices)}")
    if len(shards) != shard_count:
        raise ValueError(f"expected {shard_count} shard manifests, got {len(shards)}")
    if {str(manifest.get("shard_key", "")) for _, manifest in shards} != {expected_key}:
        raise ValueError(f"expected shard_key={expected_key!r} in every manifest")

    first = shards[0][1]
    for field in common_fields:
        expected = first.get(field)
        for directory, manifest in shards[1:]:
            if manifest.get(field) != expected:
                raise ValueError(f"inconsistent {field!r} in {directory / 'manifest.json'}")
    return shard_count


def _assert_unique(values: Iterable[str], label: str) -> None:
    seen: set[str] = set()
    duplicates: set[str] = set()
    for value in values:
        if value in seen:
            duplicates.add(value)
        seen.add(value)
    if duplicates:
        raise ValueError(f"duplicate {label}: {sorted(duplicates)}")


def merge_self_play(root: Path, output: Path) -> dict[str, Any]:
    shards = _load_shards(root)
    shard_count = _validate_shard_set(
        shards,
        "game_id",
        (
            "manifest_schema_version",
            "training_example_schema_version",
            "trace_schema_version",
            "self_play_suite_version",
            "preset",
            "rules_version",
            "budget_profiles",
            "trace_file",
            "preset_jobs_considered",
        ),
    )

    examples: list[dict[str, Any]] = []
    traces: list[dict[str, Any]] = []
    games: list[dict[str, Any]] = []
    outcomes = {"terran": 0, "zerg": 0, "draw": 0}

    for directory, manifest in shards:
        shard_index = int(manifest["shard_index"])
        shard_games = list(manifest.get("games", []))
        for game in shard_games:
            game_id = str(game.get("game_id", ""))
            if not game_id:
                raise ValueError(f"missing game_id in {directory / 'manifest.json'}")
            if shard_for_key(game_id, shard_count) != shard_index:
                raise ValueError(f"game {game_id} is in the wrong shard {shard_index}")
        games.extend(shard_games)
        examples.extend(_read_jsonl(directory / "examples.jsonl"))
        traces.extend(_read_jsonl(directory / "traces.jsonl"))
        for faction in outcomes:
            outcomes[faction] += int(manifest.get("outcomes", {}).get(faction, 0))

    _assert_unique((str(game.get("game_id", "")) for game in games), "game_id values")
    _assert_unique((str(trace.get("game_id", "")) for trace in traces), "trace game_id values")

    examples.sort(
        key=lambda row: (
            str(row.get("game_id", "")),
            int(row.get("turn_index", 0)),
            str(row.get("perspective_group", "")),
            str(row.get("opponent_group", "")),
        )
    )
    traces.sort(key=lambda row: str(row.get("game_id", "")))
    games.sort(key=lambda row: str(row.get("game_id", "")))

    first = dict(shards[0][1])
    for key in ("shard_index", "shard_count"):
        first.pop(key, None)
    first.update(
        {
            "generation_shards": shard_count,
            "games_requested": sum(int(manifest.get("games_requested", 0)) for _, manifest in shards),
            "games_labeled": sum(int(manifest.get("games_labeled", 0)) for _, manifest in shards),
            "games_unlabeled": sum(int(manifest.get("games_unlabeled", 0)) for _, manifest in shards),
            "games_failed": sum(int(manifest.get("games_failed", 0)) for _, manifest in shards),
            "example_count": len(examples),
            "trace_count": len(traces),
            "outcomes": outcomes,
            "games": games,
            "source_shards": [
                {
                    "shard_index": int(manifest["shard_index"]),
                    "games_requested": int(manifest.get("games_requested", 0)),
                }
                for _, manifest in sorted(shards, key=lambda item: int(item[1]["shard_index"]))
            ],
        }
    )
    if len(games) != int(first["games_requested"]):
        raise ValueError("self-play manifest game count does not match games_requested")
    if len(traces) != int(first["trace_count"]):
        raise ValueError("self-play trace count mismatch")
    if len(examples) != sum(int(manifest.get("example_count", 0)) for _, manifest in shards):
        raise ValueError("self-play example count mismatch")

    _write_jsonl(output / "examples.jsonl", examples)
    _write_jsonl(output / "traces.jsonl", traces)
    _write_json(output / "manifest.json", first)
    return first


def merge_counterfactual(root: Path, output: Path) -> dict[str, Any]:
    shards = _load_shards(root)
    shard_count = _validate_shard_set(
        shards,
        "decision_id",
        (
            "manifest_schema_version",
            "candidate_schema_version",
            "counterfactual_benchmark_version",
            "counterfactual_suite_version",
            "preset",
            "rules_version",
            "target_semantics",
            "uncertainty_semantics",
            "opponent_mixture_version",
            "continuation_mixture_version",
            "turn_limit_is_unlabeled",
            "preset_decisions_considered",
        ),
    )

    candidates: list[dict[str, Any]] = []
    decisions: list[dict[str, Any]] = []
    for directory, manifest in shards:
        shard_index = int(manifest["shard_index"])
        shard_decisions = list(manifest.get("decisions", []))
        for decision in shard_decisions:
            decision_id = str(decision.get("decision_id", ""))
            if not decision_id:
                raise ValueError(f"missing decision_id in {directory / 'manifest.json'}")
            if shard_for_key(decision_id, shard_count) != shard_index:
                raise ValueError(f"decision {decision_id} is in the wrong shard {shard_index}")
        decisions.extend(shard_decisions)
        candidates.extend(_read_jsonl(directory / "candidates.jsonl"))

    _assert_unique((str(decision.get("decision_id", "")) for decision in decisions), "decision_id values")
    candidates.sort(key=lambda row: (str(row.get("decision_id", "")), str(row.get("candidate_id", ""))))
    decisions.sort(key=lambda row: str(row.get("decision_id", "")))

    first = dict(shards[0][1])
    for key in ("shard_index", "shard_count"):
        first.pop(key, None)
    first.update(
        {
            "generation_shards": shard_count,
            "decisions_requested": sum(int(manifest.get("decisions_requested", 0)) for _, manifest in shards),
            "decisions_failed": sum(int(manifest.get("decisions_failed", 0)) for _, manifest in shards),
            "candidate_count": len(candidates),
            "fully_labeled_candidates": sum(
                int(manifest.get("fully_labeled_candidates", 0)) for _, manifest in shards
            ),
            "partially_labeled_candidates": sum(
                int(manifest.get("partially_labeled_candidates", 0)) for _, manifest in shards
            ),
            "unlabeled_candidates": sum(
                int(manifest.get("unlabeled_candidates", 0)) for _, manifest in shards
            ),
            "decisions": decisions,
            "source_shards": [
                {
                    "shard_index": int(manifest["shard_index"]),
                    "decisions_requested": int(manifest.get("decisions_requested", 0)),
                }
                for _, manifest in sorted(shards, key=lambda item: int(item[1]["shard_index"]))
            ],
        }
    )
    if len(decisions) != int(first["decisions_requested"]):
        raise ValueError("counterfactual manifest decision count does not match decisions_requested")
    if len(candidates) != sum(int(manifest.get("candidate_count", 0)) for _, manifest in shards):
        raise ValueError("counterfactual candidate count mismatch")

    _write_jsonl(output / "candidates.jsonl", candidates)
    _write_json(output / "manifest.json", first)
    return first


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-play-root", type=Path, required=True)
    parser.add_argument("--counterfactual-root", type=Path, required=True)
    parser.add_argument("--self-play-output", type=Path, required=True)
    parser.add_argument("--counterfactual-output", type=Path, required=True)
    args = parser.parse_args()

    self_play = merge_self_play(args.self_play_root, args.self_play_output)
    counterfactual = merge_counterfactual(args.counterfactual_root, args.counterfactual_output)
    print(
        "[merge] self-play games=%d examples=%d traces=%d shards=%d"
        % (
            self_play["games_requested"],
            self_play["example_count"],
            self_play["trace_count"],
            self_play["generation_shards"],
        )
    )
    print(
        "[merge] counterfactual decisions=%d candidates=%d shards=%d"
        % (
            counterfactual["decisions_requested"],
            counterfactual["candidate_count"],
            counterfactual["generation_shards"],
        )
    )


if __name__ == "__main__":
    main()
