"""Fail-closed Phase 1 promotion report; draws stay in the resolved denominator."""
from __future__ import annotations

import argparse
import json
import math
from collections import Counter, defaultdict
from pathlib import Path


def score_group(manifest: dict, expected_preset: str) -> dict:
    games = manifest.get("games", [])
    counts = Counter(game.get("winner_agent", "failed") for game in games)
    resolved = counts["challenger"] + counts["champion"] + counts["draw"]
    pairs = defaultdict(list)
    for game in games:
        pairs[game.get("pair_id", "")].append(game)
    complete_pairs = len(pairs) == 10 and all(
        pair_id and len(pair) == 2
        and {game.get("challenger_group") for game in pair} == {"terran", "zerg"}
        for pair_id, pair in pairs.items()
    )
    times = [float(game.get(f"{agent}_search", {}).get("max_elapsed_ms", float("inf")))
             for game in games for agent in ("champion", "challenger")]
    budget = float(manifest.get("decision_time_budget_ms", 0))
    checks = {
        "expected_suite": manifest.get("preset") == expected_preset,
        "twenty_unique_games": len(games) == 20 and len({g.get("game_id") for g in games}) == 20,
        "ten_mirrored_pairs": complete_pairs,
        "no_failed_games": all(g.get("valid", False) and g.get("winner_agent") in
            {"challenger", "champion", "draw", "unresolved"} for g in games),
        "half_resolved": resolved >= 10,
        "three_quarters_resolved_wins": resolved > 0 and counts["challenger"] * 4 >= resolved * 3,
        "equal_positive_time_budget": 0 < budget <= 30000,
        "thirty_second_cap": bool(times) and all(math.isfinite(t) and 0 <= t <= 30000 for t in times),
        "neural_vs_handwritten": manifest.get("champion_evaluator") == "handwritten"
            and manifest.get("challenger_evaluator") == "neural",
    }
    return {"passed": all(checks.values()), "checks": checks, "counts": dict(counts),
            "resolved": resolved, "resolution_rate": resolved / 20,
            "resolved_win_rate": counts["challenger"] / resolved if resolved else 0,
            "max_decision_ms": max(times) if times else None}


def promotion_report(familiar: dict, unfamiliar: dict, training: dict) -> dict:
    elapsed = training.get("pipeline_elapsed_seconds")
    checks = {
        "same_rules": bool(familiar.get("rules_version"))
            and familiar.get("rules_version") == unfamiliar.get("rules_version") == training.get("rules_version"),
        "same_budget": familiar.get("decision_time_budget_ms") == unfamiliar.get("decision_time_budget_ms"),
        "different_map_generator": familiar.get("map_profile") == "compact_v1"
            and unfamiliar.get("map_profile") == "phase1_unfamiliar_v1",
        "same_runner": bool(training.get("runner_type")) and familiar.get("runner_type")
            == unfamiliar.get("runner_type") == training.get("runner_type"),
        "training_under_four_hours": isinstance(elapsed, (int, float)) and 0 <= elapsed < 14400,
        "worker_count_recorded": isinstance(training.get("workers"), int) and training["workers"] > 0,
        "evaluation_excluded_from_training": training.get("evaluation_excluded_from_training") is True,
        "checkpoint_provenance": bool(training.get("checkpoint_sha256")) and
            familiar.get("checkpoint_sha256") == unfamiliar.get("checkpoint_sha256")
            == training.get("checkpoint_sha256"),
    }
    groups = {"familiar": score_group(familiar, "phase1_familiar"),
              "unfamiliar": score_group(unfamiliar, "phase1_unfamiliar")}
    return {"passed": all(checks.values()) and all(g["passed"] for g in groups.values()),
            "checks": checks, "groups": groups, "training": training}


def main() -> int:
    parser = argparse.ArgumentParser()
    for name in ("familiar", "unfamiliar", "training", "output"):
        parser.add_argument(f"--{name}", type=Path, required=True)
    args = parser.parse_args()
    report = promotion_report(*(json.loads(getattr(args, name).read_text())
                                for name in ("familiar", "unfamiliar", "training")))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    for name, group in report["groups"].items():
        print(f"{name}: {group['resolved']}/20 resolved; "
              f"{group['resolved_win_rate']:.1%} wins among resolved; passed={group['passed']}")
    print(f"Phase 1 passed={report['passed']}")
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
