#!/usr/bin/env python3
"""Merge deterministic basic-random self-play shard artifacts.

Each shard is produced by basic_random_self_play.gd with the same requested game
count and a different BASIC_RANDOM_SHARD_INDEX. The shard manifests describe only
the jobs executed on that runner; this tool reconstructs the original logical
training dataset, verifies invariants, and concatenates the JSONL files in stable
order.
"""

from __future__ import annotations

import argparse
import json
from collections import Counter
from pathlib import Path
from typing import Any

JSONL_FILES = ("examples.jsonl", "search_decisions.jsonl", "traces.jsonl")
INVARIANT_KEYS = (
    "manifest_schema_version",
    "suite_version",
    "rules_version",
    "evaluator",
    "search_policy",
    "training_rotations",
    "evaluation_rotations_excluded",
    "command_hexes_enabled",
    "near_balanced_probability",
    "reward_discount",
    "capture_decisions_per_game",
    "learned_proposals",
    "puct_simulations",
    "puct_max_depth",
    "puct_c",
)


def _read_jsonl(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    rows: list[dict[str, Any]] = []
    for line in path.read_text().splitlines():
        if not line.strip():
            continue
        value = json.loads(line)
        if not isinstance(value, dict):
            raise ValueError(f"{path} contains a non-object JSONL row")
        rows.append(value)
    return rows


def _write_jsonl(path: Path, rows: list[dict[str, Any]]) -> None:
    path.write_text("".join(json.dumps(row, separators=(",", ":")) + "\n" for row in rows))


def _find_shards(root: Path) -> list[Path]:
    manifests = sorted(root.rglob("manifest.json"))
    if not manifests:
        raise ValueError(f"no shard manifests found below {root}")
    return [path.parent for path in manifests]


def merge(input_root: Path, out: Path) -> dict[str, Any]:
    shard_dirs = _find_shards(input_root)
    manifests = [json.loads((directory / "manifest.json").read_text()) for directory in shard_dirs]
    first = manifests[0]
    for index, manifest in enumerate(manifests[1:], start=1):
        for key in INVARIANT_KEYS:
            if manifest.get(key) != first.get(key):
                raise ValueError(
                    f"shard invariant mismatch for {key}: shard0={first.get(key)!r} "
                    f"shard{index}={manifest.get(key)!r}"
                )

    games: list[dict[str, Any]] = []
    all_rows: dict[str, list[dict[str, Any]]] = {name: [] for name in JSONL_FILES}
    outcomes: Counter[str] = Counter()
    profiles: Counter[str] = Counter()
    base_game_ids: set[str] = set()
    trajectory_ids: set[str] = set()

    for directory, manifest in zip(shard_dirs, manifests):
        shard_games = manifest.get("games", [])
        if not isinstance(shard_games, list):
            raise ValueError(f"invalid games array in {directory}")
        for game in shard_games:
            if not isinstance(game, dict):
                raise ValueError(f"invalid game row in {directory}")
            game_id = str(game.get("game_id", ""))
            base_game_id = str(game.get("base_game_id", ""))
            if not game_id or game_id in trajectory_ids:
                raise ValueError(f"duplicate or missing trajectory id {game_id!r}")
            trajectory_ids.add(game_id)
            if base_game_id:
                base_game_ids.add(base_game_id)
            games.append(game)
        outcomes.update({str(k): int(v) for k, v in dict(manifest.get("outcomes", {})).items()})
        profiles.update({str(k): int(v) for k, v in dict(manifest.get("profiles", {})).items()})
        for name in JSONL_FILES:
            all_rows[name].extend(_read_jsonl(directory / name))

    games.sort(key=lambda row: (str(row.get("base_game_id", "")), str(row.get("policy_profile", "")), str(row.get("game_id", ""))))
    for name in JSONL_FILES:
        if name == "examples.jsonl":
            all_rows[name].sort(key=lambda row: (str(row.get("game_id", "")), int(row.get("turn_index", 0)), str(row.get("perspective_group", ""))))
        elif name == "search_decisions.jsonl":
            all_rows[name].sort(key=lambda row: (str(row.get("game_id", "")), int(row.get("turn_index", 0))))
        else:
            all_rows[name].sort(key=lambda row: str(row.get("game_id", "")))

    merged = dict(first)
    merged["base_games"] = len(base_game_ids)
    merged["trajectories"] = len(games)
    merged["profiles"] = dict(profiles)
    merged["outcomes"] = dict(outcomes)
    merged["example_count"] = len(all_rows["examples.jsonl"])
    merged["search_decision_count"] = len(all_rows["search_decisions.jsonl"])
    merged["games"] = games
    merged["merged_shards"] = len(shard_dirs)

    expected_profiles = {"greedy": len(base_game_ids), "light": len(base_game_ids), "explore": len(base_game_ids)}
    if dict(profiles) != expected_profiles:
        raise ValueError(f"profile coverage mismatch: {dict(profiles)} != {expected_profiles}")
    if len(games) != len(base_game_ids) * 3:
        raise ValueError("each base game must contribute exactly three trajectories")
    if merged["example_count"] != sum(int(m.get("example_count", 0)) for m in manifests):
        raise ValueError("example count mismatch while merging shards")
    if merged["search_decision_count"] != sum(int(m.get("search_decision_count", 0)) for m in manifests):
        raise ValueError("search-decision count mismatch while merging shards")

    out.mkdir(parents=True, exist_ok=True)
    (out / "manifest.json").write_text(json.dumps(merged, indent=2, sort_keys=True) + "\n")
    for name, rows in all_rows.items():
        _write_jsonl(out / name, rows)
    return merged


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input-root", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    result = merge(args.input_root, args.out)
    print(json.dumps({
        "base_games": result["base_games"],
        "trajectories": result["trajectories"],
        "examples": result["example_count"],
        "search_decisions": result["search_decision_count"],
        "outcomes": result["outcomes"],
        "merged_shards": result["merged_shards"],
    }, sort_keys=True))


if __name__ == "__main__":
    main()
