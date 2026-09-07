#!/usr/bin/env python3
"""Merge deterministic AI arena shards and write a compact tournament summary."""

from __future__ import annotations

import argparse
import json
from collections import Counter, defaultdict
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input-root", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument(
        "--checkpoint-source",
        default="",
        help="Reproducible checkpoint provenance such as artifact:123 or run:456/file.pt",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    root = Path(args.input_root)
    manifests = sorted(root.glob("**/manifest.json"))
    if not manifests:
        raise SystemExit(f"No arena manifests found under {root}")

    shards = [json.loads(path.read_text()) for path in manifests]
    first = shards[0]
    invariant_keys = [
        "manifest_schema_version",
        "arena_suite_version",
        "preset",
        "seed_base",
        "rules_version",
        "champion_profile",
        "challenger_profile",
        "champion_evaluator",
        "challenger_evaluator",
        "preset_games",
        "preset_pairs",
        "shard_count",
    ]
    for shard in shards[1:]:
        for key in invariant_keys:
            if shard.get(key) != first.get(key):
                raise SystemExit(
                    f"Arena shard metadata mismatch for {key}: "
                    f"{shard.get(key)!r} != {first.get(key)!r}"
                )

    expected_shards = int(first["shard_count"])
    shard_indexes = sorted(int(shard["shard_index"]) for shard in shards)
    if shard_indexes != list(range(expected_shards)):
        raise SystemExit(
            f"Arena shards incomplete: got {shard_indexes}, "
            f"expected 0..{expected_shards - 1}"
        )

    games = []
    seen_game_ids = set()
    for shard in shards:
        for game in shard.get("games", []):
            game_id = game.get("game_id", "")
            if not game_id or game_id in seen_game_ids:
                raise SystemExit(f"Missing or duplicate arena game_id: {game_id!r}")
            seen_game_ids.add(game_id)
            games.append(game)
    games.sort(key=lambda row: row["game_id"])

    expected_games = int(first["preset_games"])
    if len(games) != expected_games:
        raise SystemExit(
            f"Arena game coverage mismatch: got {len(games)}, expected {expected_games}"
        )

    pairs = defaultdict(list)
    for game in games:
        pairs[game["pair_id"]].append(game)
    expected_pairs = int(first["preset_pairs"])
    if len(pairs) != expected_pairs:
        raise SystemExit(
            f"Arena pair coverage mismatch: got {len(pairs)}, expected {expected_pairs}"
        )
    for pair_id, rows in pairs.items():
        groups = sorted(row["challenger_group"] for row in rows)
        if len(rows) != 2 or groups != ["terran", "zerg"]:
            raise SystemExit(f"Arena pair {pair_id} is not a complete side swap: {groups}")

    counts = Counter(game["winner_agent"] for game in games)
    termination_counts = Counter(game["termination_reason"] for game in games)
    decisive = counts["challenger"] + counts["champion"]
    decisive_win_rate = counts["challenger"] / decisive if decisive else 0.0

    family_counts: dict[str, Counter] = defaultdict(Counter)
    challenger_faction_counts: dict[str, Counter] = defaultdict(Counter)
    winner_faction_counts = Counter()
    for game in games:
        outcome = str(game.get("winner_agent", "failed"))
        family = str(game.get("base_scenario_id", "unknown"))
        challenger_group = str(game.get("challenger_group", "unknown"))
        family_counts[family][outcome] += 1
        challenger_faction_counts[challenger_group][outcome] += 1
        if outcome in {"challenger", "champion"}:
            winner_group = str(game.get("winner_group", "unknown"))
            winner_faction_counts[winner_group] += 1
        else:
            winner_faction_counts[outcome] += 1

    pair_counts = Counter()
    scored_pairs = 0
    pair_family_counts: dict[str, Counter] = defaultdict(Counter)
    for rows in pairs.values():
        points = 0.0
        scored = 0
        family = str(rows[0].get("base_scenario_id", "unknown"))
        for game in rows:
            outcome = game["winner_agent"]
            if outcome == "challenger":
                points += 1.0
                scored += 1
            elif outcome == "champion":
                scored += 1
            elif outcome == "draw":
                points += 0.5
                scored += 1
        if scored != 2:
            pair_counts["unresolved"] += 1
            pair_family_counts[family]["unresolved"] += 1
            continue
        scored_pairs += 1
        if points > 1.0:
            pair_counts["challenger"] += 1
            pair_family_counts[family]["challenger"] += 1
        elif points < 1.0:
            pair_counts["champion"] += 1
            pair_family_counts[family]["champion"] += 1
        else:
            pair_counts["tie"] += 1
            pair_family_counts[family]["tie"] += 1

    def search_totals(agent_key: str) -> dict:
        elapsed = 0.0
        decisions = 0
        simulations = 0
        max_elapsed = 0.0
        for game in games:
            metrics = game.get(f"{agent_key}_search", {})
            elapsed += float(metrics.get("elapsed_ms", 0.0))
            decisions += int(metrics.get("decisions", 0))
            simulations += int(metrics.get("simulations", 0))
            max_elapsed = max(max_elapsed, float(metrics.get("max_elapsed_ms", 0.0)))
        return {
            "decisions": decisions,
            "elapsed_ms": elapsed,
            "mean_decision_ms": elapsed / decisions if decisions else 0.0,
            "max_decision_ms": max_elapsed,
            "simulations": simulations,
            "simulations_per_decision": simulations / decisions if decisions else 0.0,
        }

    champion_search = search_totals("champion")
    challenger_search = search_totals("challenger")
    max_non_progress = max(
        (int(game.get("max_non_progress_streak", 0)) for game in games), default=0
    )
    mean_turns = sum(int(game.get("turns_played", 0)) for game in games) / len(games)

    merged = {
        "manifest_schema_version": first["manifest_schema_version"],
        "arena_suite_version": first["arena_suite_version"],
        "preset": first["preset"],
        "seed_base": first["seed_base"],
        "rules_version": first["rules_version"],
        "checkpoint_source": args.checkpoint_source,
        "champion_profile": first["champion_profile"],
        "challenger_profile": first["challenger_profile"],
        "champion_evaluator": first["champion_evaluator"],
        "challenger_evaluator": first["challenger_evaluator"],
        "champion_settings": first["champion_settings"],
        "challenger_settings": first["challenger_settings"],
        "generation_shards": expected_shards,
        "games": games,
        "games_played": len(games),
        "pairs_played": len(pairs),
        "counts": dict(counts),
        "pair_counts": dict(pair_counts),
        "family_counts": {key: dict(value) for key, value in family_counts.items()},
        "pair_family_counts": {
            key: dict(value) for key, value in pair_family_counts.items()
        },
        "challenger_faction_counts": {
            key: dict(value) for key, value in challenger_faction_counts.items()
        },
        "winner_faction_counts": dict(winner_faction_counts),
        "scored_pairs": scored_pairs,
        "termination_counts": dict(termination_counts),
        "decisive_games": decisive,
        "challenger_decisive_win_rate": decisive_win_rate,
        "mean_turns": mean_turns,
        "max_non_progress_streak": max_non_progress,
        "champion_search": champion_search,
        "challenger_search": challenger_search,
    }

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    (out / "manifest.json").write_text(json.dumps(merged, indent=2) + "\n")

    unresolved_games = [
        game["game_id"] for game in games if game["winner_agent"] == "unresolved"
    ]

    family_lines = [
        "| Family | Neural wins | Handwritten wins | Draws | Unresolved | Pair: neural | Pair: handwritten | Pair ties |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    for family in sorted(family_counts):
        game_row = family_counts[family]
        pair_row = pair_family_counts[family]
        family_lines.append(
            f"| {family} | {game_row['challenger']} | {game_row['champion']} | "
            f"{game_row['draw']} | {game_row['unresolved']} | {pair_row['challenger']} | "
            f"{pair_row['champion']} | {pair_row['tie']} |"
        )

    faction_lines = [
        "| Neural playing as | Neural wins | Handwritten wins | Draws | Unresolved |",
        "| --- | ---: | ---: | ---: | ---: |",
    ]
    for faction in ["terran", "zerg"]:
        row = challenger_faction_counts[faction]
        faction_lines.append(
            f"| {faction} | {row['challenger']} | {row['champion']} | "
            f"{row['draw']} | {row['unresolved']} |"
        )

    checkpoint_line = args.checkpoint_source or "not recorded"
    summary = f"""## Seeded AI arena

| Metric | Result |
| --- | ---: |
| Preset | {first['preset']} |
| Generated pairs | {len(pairs)} |
| Games | {len(games)} |
| Challenger wins | {counts['challenger']} |
| Champion wins | {counts['champion']} |
| Draws | {counts['draw']} |
| Unresolved turn limits | {counts['unresolved']} |
| Challenger decisive win rate | {decisive_win_rate:.1%} |
| Challenger pair wins | {pair_counts['challenger']} |
| Champion pair wins | {pair_counts['champion']} |
| Tied pairs | {pair_counts['tie']} |
| Unresolved pairs | {pair_counts['unresolved']} |
| Mean turns | {mean_turns:.2f} |
| Max non-progress streak | {max_non_progress} |
| Challenger mean decision time | {challenger_search['mean_decision_ms']:.1f} ms |
| Champion mean decision time | {champion_search['mean_decision_ms']:.1f} ms |
| Challenger sims / decision | {challenger_search['simulations_per_decision']:.1f} |
| Champion sims / decision | {champion_search['simulations_per_decision']:.1f} |

**Champion:** `{first['champion_profile']}` / `{first['champion_evaluator']}`  
**Challenger:** `{first['challenger_profile']}` / `{first['challenger_evaluator']}`  
**Checkpoint source:** `{checkpoint_line}`  
**Winning factions:** `{dict(winner_faction_counts)}`  
**Termination reasons:** `{dict(termination_counts)}`  
**Unresolved games:** {', '.join(unresolved_games) or 'none'}

### Results by scenario family

{chr(10).join(family_lines)}

### Neural results by faction

{chr(10).join(faction_lines)}
"""
    (out / "summary.md").write_text(summary)
    print(summary)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
