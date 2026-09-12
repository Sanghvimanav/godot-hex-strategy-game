from __future__ import annotations

import argparse
import json
from pathlib import Path


def _first(root: Path, name: str) -> Path:
    matches = list(root.rglob(name))
    if not matches:
        raise FileNotFoundError(f"missing {name} under {root}")
    return matches[0]


def _arena_manifest(root: Path) -> dict:
    candidates: list[dict] = []
    for path in root.rglob("manifest.json"):
        payload = json.loads(path.read_text())
        if "counts" in payload and "challenger_decisive_win_rate" in payload:
            candidates.append(payload)
    if len(candidates) != 1:
        raise ValueError(f"expected one merged Arena manifest, found {len(candidates)}")
    return candidates[0]


def _primary(row: dict) -> dict[str, float]:
    cf = row["counterfactual"]
    arena = row["arena"]
    return {
        "cf_rank": float(cf["candidate_ranking_accuracy"]),
        "cf_regret": float(cf["top_plan_mean_regret"]),
        "cf_optimal": float(cf["top_plan_optimal_rate"]),
        "arena_win": float(arena["challenger_decisive_win_rate"]),
    }


def _pct(value: float) -> str:
    return f"{100.0 * float(value):.1f}%"


def _signed_pp(value: float) -> str:
    return f"{100.0 * float(value):+.1f}pp"


def summarize(args: argparse.Namespace) -> dict:
    baseline_train = json.loads(_first(args.baseline_candidate_root, "ranked_metrics.json").read_text())
    baseline_cf = json.loads(
        _first(args.baseline_candidate_root, "ranked_counterfactual_metrics.json").read_text()
    )["evaluators"]["neural_value_model"]
    baseline_arena = _arena_manifest(args.baseline_arena_root)

    rows: list[dict] = [
        {
            "cycle_id": 0,
            "label": "Iteration 2 baseline",
            "parent_policy": "-",
            "self_play": None,
            "training": baseline_train,
            "counterfactual": baseline_cf,
            "arena": {
                "counts": baseline_arena.get("counts", {}),
                "challenger_decisive_win_rate": baseline_arena.get(
                    "challenger_decisive_win_rate", 0.0
                ),
                "passivity": baseline_arena.get("passivity", {}),
            },
        }
    ]

    cycle_payloads = [json.loads(path.read_text()) for path in args.cycles_root.rglob("cycle_metrics.json")]
    cycle_payloads.sort(key=lambda row: int(row["cycle_id"]))
    if [int(row["cycle_id"]) for row in cycle_payloads] != list(range(1, 7)):
        raise ValueError("expected exactly cycle metrics 1 through 6")
    for payload in cycle_payloads:
        payload["label"] = f"Cycle {payload['cycle_id']}"
        rows.append(payload)

    transitions: list[dict] = []
    for previous, current in zip(rows, rows[1:]):
        old = _primary(previous)
        new = _primary(current)
        transitions.append(
            {
                "from_cycle": previous["cycle_id"],
                "to_cycle": current["cycle_id"],
                "cf_rank_delta": new["cf_rank"] - old["cf_rank"],
                "cf_regret_delta": new["cf_regret"] - old["cf_regret"],
                "cf_optimal_delta": new["cf_optimal"] - old["cf_optimal"],
                "arena_win_delta": new["arena_win"] - old["arena_win"],
            }
        )

    series = [_primary(row) for row in rows]
    monotonic = {
        "cf_candidate_ranking_nondecreasing": all(
            new["cf_rank"] >= old["cf_rank"] for old, new in zip(series, series[1:])
        ),
        "cf_mean_regret_nonincreasing": all(
            new["cf_regret"] <= old["cf_regret"] for old, new in zip(series, series[1:])
        ),
        "cf_optimal_rate_nondecreasing": all(
            new["cf_optimal"] >= old["cf_optimal"] for old, new in zip(series, series[1:])
        ),
        "arena_decisive_win_rate_nondecreasing": all(
            new["arena_win"] >= old["arena_win"] for old, new in zip(series, series[1:])
        ),
    }

    report = {
        "experiment": "six_cycle_iterative_self_play",
        "total_self_play_games": 720,
        "games_per_cycle": 120,
        "cycles": 6,
        "baseline_run_id": args.baseline_run_id,
        "rows": rows,
        "transitions": transitions,
        "monotonic_primary_metrics": monotonic,
    }
    args.output_json.parent.mkdir(parents=True, exist_ok=True)
    args.output_json.write_text(json.dumps(report, indent=2) + "\n")

    lines = [
        "## Iterative self-play checkpoint progression",
        "",
        "Same total self-play budget as the one-shot scale experiment: **720 games = 6 cycles × 120 games**.",
        "Frozen evaluation data is never added to training replay.",
        "",
        "| Checkpoint | Parent used for self-play | Labeled / unresolved | Fresh examples | Held-out sign | Held-out sibling | Frozen CF rank | CF regret | CF optimal | Frozen Arena W-L-D-U | Arena decisive win | Neural passivity |",
        "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    for row in rows:
        train, cf, arena = row["training"], row["counterfactual"], row["arena"]
        counts = arena.get("counts", {})
        passivity = arena.get("passivity", {}).get("challenger", {}).get("passive_rate", 0.0)
        if row["cycle_id"] == 0:
            labeled, examples, parent = "-", "-", "-"
        else:
            sp = row["self_play"]
            labeled = f"{sp['games_labeled']} / {sp['games_unlabeled']}"
            examples = str(sp["examples_generated"])
            parent = row["parent_policy"]
        lines.append(
            f"| {row['label']} | {parent} | {labeled} | {examples} | "
            f"{_pct(train['neural_eval_sign_accuracy_nonterminal'])} | {_pct(train['eval_ranking_accuracy'])} | "
            f"{_pct(cf['candidate_ranking_accuracy'])} | {float(cf['top_plan_mean_regret']):.3f} | "
            f"{_pct(cf['top_plan_optimal_rate'])} | "
            f"{counts.get('challenger',0)}-{counts.get('champion',0)}-{counts.get('draw',0)}-{counts.get('unresolved',0)} | "
            f"{_pct(arena['challenger_decisive_win_rate'])} | {_pct(passivity)} |"
        )

    lines += [
        "",
        "### Change after each training step",
        "",
        "| Training step | CF rank | CF regret | CF optimal | Arena win rate |",
        "| --- | ---: | ---: | ---: | ---: |",
    ]
    for delta in transitions:
        lines.append(
            f"| {delta['from_cycle']} → {delta['to_cycle']} | {_signed_pp(delta['cf_rank_delta'])} | "
            f"{delta['cf_regret_delta']:+.3f} | {_signed_pp(delta['cf_optimal_delta'])} | "
            f"{_signed_pp(delta['arena_win_delta'])} |"
        )
    lines += ["", "### Monotonicity check", ""]
    for key, value in monotonic.items():
        lines.append(f"- {key}: **{'yes' if value else 'no'}**")
    lines += [
        "",
        "Lower counterfactual regret is better; the other frozen primary metrics are better when higher.",
        "The learner always advances during this experiment, but the Iteration-2 champion is not automatically replaced after a regressing cycle.",
        "",
    ]
    args.output_markdown.write_text("\n".join(lines))
    return report


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cycles-root", type=Path, required=True)
    parser.add_argument("--baseline-candidate-root", type=Path, required=True)
    parser.add_argument("--baseline-arena-root", type=Path, required=True)
    parser.add_argument("--baseline-run-id", required=True)
    parser.add_argument("--output-json", type=Path, required=True)
    parser.add_argument("--output-markdown", type=Path, required=True)
    return parser


def main() -> None:
    summarize(build_parser().parse_args())


if __name__ == "__main__":
    main()
