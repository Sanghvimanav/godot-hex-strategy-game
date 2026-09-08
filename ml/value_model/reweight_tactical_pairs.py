"""Reweight fresh Arena hard negatives toward observed neural-policy tactical gaps.

This intentionally operates on freshly mined Arena pairs before they are appended to
historical supervision. It keeps the evaluator/search architecture unchanged while
putting more gradient on scenario families and factions where the current policy is
measurably weak. A further multiplier can be applied when the recorded neural action
set is more passive than the handwritten alternative.
"""

from __future__ import annotations

import argparse
import json
from collections import Counter
from pathlib import Path
from typing import Iterable

PASSIVE_ACTION_KEYS = {"reload", "rest", "rest_no_energy"}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--pairs", required=True)
    parser.add_argument("--divergences", default="")
    parser.add_argument("--output", required=True)
    parser.add_argument("--manifest", required=True)
    parser.add_argument(
        "--focus-families",
        default="mixed_force,scout_kite,fester_siege",
        help="Comma-separated base_scenario_id values to upweight.",
    )
    parser.add_argument(
        "--focus-faction",
        default="terran",
        help="Perspective group receiving an additional multiplier; empty disables it.",
    )
    parser.add_argument("--family-multiplier", type=float, default=2.0)
    parser.add_argument("--faction-multiplier", type=float, default=1.5)
    parser.add_argument("--passivity-multiplier", type=float, default=1.5)
    parser.add_argument("--max-multiplier", type=float, default=4.0)
    return parser.parse_args()


def _read_jsonl(path: str | Path) -> list[dict]:
    target = Path(path)
    if not target.exists() or target.stat().st_size == 0:
        return []
    rows: list[dict] = []
    for raw in target.read_text().splitlines():
        if not raw.strip():
            continue
        row = json.loads(raw)
        if not isinstance(row, dict):
            raise ValueError(f"Expected JSON object in {target}")
        rows.append(row)
    return rows


def _write_jsonl(path: str | Path, rows: Iterable[dict]) -> None:
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    materialized = list(rows)
    text = "" if not materialized else "\n".join(json.dumps(row, sort_keys=True) for row in materialized) + "\n"
    target.write_text(text)


def _parse_families(raw: str) -> set[str]:
    return {item.strip() for item in raw.split(",") if item.strip()}


def _passive_count(actions: object) -> int:
    if not isinstance(actions, list):
        return 0
    count = 0
    for action in actions:
        if not isinstance(action, dict):
            continue
        key = str(action.get("action_key", action.get("type", "")))
        if key in PASSIVE_ACTION_KEYS:
            count += 1
    return count


def reweight_pairs(
    pairs: list[dict],
    divergences: list[dict],
    *,
    focus_families: set[str],
    focus_faction: str,
    family_multiplier: float,
    faction_multiplier: float,
    passivity_multiplier: float,
    max_multiplier: float,
) -> tuple[list[dict], dict]:
    divergence_by_key = {
        (str(row.get("game_id", "")), int(row.get("turn_index", -1))): row
        for row in divergences
    }

    counts = Counter()
    multiplier_histogram = Counter()
    output: list[dict] = []

    for original in pairs:
        row = json.loads(json.dumps(original))
        source = row.get("source", {})
        if not isinstance(source, dict):
            source = {}
            row["source"] = source

        family = str(source.get("base_scenario_id", ""))
        faction = str(row.get("perspective_group", ""))
        game_id = str(source.get("arena_game_id", row.get("game_id", "")))
        turn_index = int(row.get("turn_index", -1))

        multiplier = 1.0
        reasons: list[str] = []

        if family in focus_families:
            multiplier *= family_multiplier
            reasons.append("focus_family")
            counts["focus_family_pairs"] += 1

        if focus_faction and faction == focus_faction:
            multiplier *= faction_multiplier
            reasons.append("focus_faction")
            counts["focus_faction_pairs"] += 1

        divergence = divergence_by_key.get((game_id, turn_index), {})
        neural_passive = _passive_count(divergence.get("neural_actions", []))
        handwritten_passive = _passive_count(divergence.get("handwritten_actions", []))
        if neural_passive > handwritten_passive:
            multiplier *= passivity_multiplier
            reasons.append("passivity_gap")
            counts["passivity_gap_pairs"] += 1

        multiplier = min(max_multiplier, multiplier)
        base_weight = float(row.get("weight", 1.0))
        row["weight"] = base_weight * multiplier

        if multiplier > 1.0:
            counts["reweighted_pairs"] += 1
            existing_reasons = row.get("priority_reasons", [])
            if not isinstance(existing_reasons, list):
                existing_reasons = []
            for reason in reasons:
                if reason not in existing_reasons:
                    existing_reasons.append(reason)
            row["priority_reasons"] = existing_reasons
            source["tactical_focus_reweight"] = {
                "original_weight": base_weight,
                "multiplier": multiplier,
                "family": family,
                "faction": faction,
                "reasons": reasons,
                "neural_passive_actions": neural_passive,
                "handwritten_passive_actions": handwritten_passive,
            }

        multiplier_histogram[f"{multiplier:.3f}"] += 1
        output.append(row)

    manifest = {
        "pairs_seen": len(pairs),
        "pairs_reweighted": counts["reweighted_pairs"],
        "focus_families": sorted(focus_families),
        "focus_faction": focus_faction,
        "family_multiplier": family_multiplier,
        "faction_multiplier": faction_multiplier,
        "passivity_multiplier": passivity_multiplier,
        "max_multiplier": max_multiplier,
        "focus_family_pairs": counts["focus_family_pairs"],
        "focus_faction_pairs": counts["focus_faction_pairs"],
        "passivity_gap_pairs": counts["passivity_gap_pairs"],
        "multiplier_histogram": dict(sorted(multiplier_histogram.items())),
    }
    return output, manifest


def main() -> int:
    args = parse_args()
    pairs = _read_jsonl(args.pairs)
    divergences = _read_jsonl(args.divergences) if args.divergences else []
    output, manifest = reweight_pairs(
        pairs,
        divergences,
        focus_families=_parse_families(args.focus_families),
        focus_faction=args.focus_faction.strip(),
        family_multiplier=args.family_multiplier,
        faction_multiplier=args.faction_multiplier,
        passivity_multiplier=args.passivity_multiplier,
        max_multiplier=args.max_multiplier,
    )
    _write_jsonl(args.output, output)
    manifest_path = Path(args.manifest)
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(json.dumps(manifest, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
