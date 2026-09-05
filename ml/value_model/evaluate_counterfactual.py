from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any, Sequence

import torch
from torch.utils.data import DataLoader

from .data import SCHEMA_VERSION, HexStateEncoder, ValueExampleDataset, load_jsonl_examples
from .metrics import (
    candidate_ranking_metrics,
    handwritten_evaluator_score,
    top_plan_regret_metrics,
    uncertainty_aware_candidate_ranking_metrics,
)
from .model import HexValueNet


def _is_terminal(state: dict[str, Any], perspective_group: str, opponent_group: str) -> bool:
    alive: dict[str, int] = {perspective_group: 0, opponent_group: 0}
    for group in state.get("groups", []):
        if not isinstance(group, dict):
            continue
        name = str(group.get("name", ""))
        if name not in alive:
            continue
        units = group.get("units", [])
        if isinstance(units, list):
            alive[name] = sum(
                1
                for unit in units
                if isinstance(unit, dict) and float(unit.get("health", 0.0)) > 0.0
            )
    return alive[perspective_group] == 0 or alive[opponent_group] == 0


def _sample_example(row: dict[str, Any], sample: dict[str, Any]) -> dict[str, Any]:
    state = sample["state_after_first_turn"]
    perspective_group = str(row["perspective_group"])
    opponent_group = str(row["opponent_group"])
    return {
        "schema_version": SCHEMA_VERSION,
        "perspective_group": perspective_group,
        "opponent_group": opponent_group,
        "turn_index": int(
            state.get(
                "turn_index",
                int(row.get("source_state", {}).get("turn_index", -1)) + 1,
            )
        ),
        "terminal": _is_terminal(state, perspective_group, opponent_group),
        # The target is not used while scoring, but the shared encoder requires
        # the ordinary value-example shape.
        "outcome": 0.0,
        "state": state,
    }


def _load_model(checkpoint_path: str | Path, device: torch.device) -> HexValueNet:
    checkpoint = torch.load(checkpoint_path, map_location=device, weights_only=True)
    config = checkpoint.get("model_config", {})
    encoder = HexStateEncoder()
    expected = {
        "board_channels": encoder.board_channels,
        "global_features": encoder.global_features,
        "board_size": encoder.board_size,
        "max_radius": encoder.max_radius,
        "unit_types": list(encoder.unit_types),
    }
    for key, value in expected.items():
        if config.get(key) != value:
            raise ValueError(f"checkpoint {key} does not match encoder: {config.get(key)!r} != {value!r}")
    model = HexValueNet(
        board_channels=int(config["board_channels"]),
        global_features=int(config["global_features"]),
        hidden_channels=int(config["hidden_channels"]),
        residual_blocks=int(config["residual_blocks"]),
    ).to(device)
    model.load_state_dict(checkpoint["model_state_dict"])
    model.eval()
    return model


def _neural_scores(
    model: HexValueNet,
    examples: Sequence[dict[str, Any]],
    batch_size: int,
    device: torch.device,
) -> list[float]:
    dataset = ValueExampleDataset(examples)
    loader = DataLoader(dataset, batch_size=batch_size, shuffle=False)
    scores: list[float] = []
    with torch.no_grad():
        for board, globals_, _target in loader:
            scores.extend(model(board.to(device), globals_.to(device)).cpu().tolist())
    return scores


def _metric_set(
    predictions: Sequence[float],
    targets: Sequence[float],
    target_standard_errors: Sequence[float],
    decision_ids: Sequence[str],
    separation_z: float,
) -> dict[str, float | int]:
    return {
        **candidate_ranking_metrics(predictions, targets, decision_ids),
        **uncertainty_aware_candidate_ranking_metrics(
            predictions,
            targets,
            target_standard_errors,
            decision_ids,
            separation_z=separation_z,
        ),
        **top_plan_regret_metrics(predictions, targets, decision_ids),
    }


def evaluate_counterfactual_rows(
    rows: Sequence[dict[str, Any]],
    checkpoint_path: str | Path,
    batch_size: int = 64,
    device_name: str = "cpu",
) -> dict[str, Any]:
    """Score counterfactual candidates with neural, handwritten, and planner evaluators.

    Each candidate is scored after its first simultaneous turn. Scores are averaged
    over the same labeled opponent/continuation sample weights used by the
    counterfactual target, preventing unlabeled turn limits from changing the
    evaluation population.
    """
    candidates: list[dict[str, Any]] = []
    examples: list[dict[str, Any]] = []
    sample_weights: list[float] = []

    for row in rows:
        if not isinstance(row, dict):
            continue
        estimate = row.get("target_estimate", {})
        if not isinstance(estimate, dict) or int(estimate.get("return_count", 0)) <= 0:
            continue
        assumptions = row.get("assumptions", {})
        if not isinstance(assumptions, dict):
            assumptions = {}
        start = len(examples)
        for sample in row.get("samples", []):
            if not isinstance(sample, dict):
                continue
            weight = max(0.0, float(sample.get("weight", 0.0)))
            state = sample.get("state_after_first_turn")
            if (
                not bool(sample.get("valid", True))
                or not bool(sample.get("labeled", False))
                or weight <= 0.0
                or not isinstance(state, dict)
                or not state
            ):
                continue
            examples.append(_sample_example(row, sample))
            sample_weights.append(weight)
        stop = len(examples)
        if stop == start:
            continue
        candidates.append(
            {
                "decision_id": str(row.get("decision_id", "")),
                "candidate_id": str(row.get("candidate_id", "")),
                "candidate_label": str(row.get("candidate_label", row.get("candidate_id", ""))),
                "candidate_description": str(row.get("candidate_description", "")),
                "target": float(estimate.get("mean_return", 0.0)),
                "target_standard_error": max(0.0, float(estimate.get("estimated_standard_error", 0.0))),
                "proposal_score": float(row.get("proposal_score", 0.0)),
                "sample_start": start,
                "sample_stop": stop,
                "coverage": float(estimate.get("labeled_weight_fraction", 0.0)),
                "separation_z": max(0.0, float(assumptions.get("separation_z", 1.96))),
            }
        )

    if not candidates:
        raise ValueError("counterfactual data contains no labeled candidates with first-turn states")

    separation_values = {float(candidate["separation_z"]) for candidate in candidates}
    if len(separation_values) != 1:
        raise ValueError(f"counterfactual candidates disagree on separation_z: {sorted(separation_values)}")
    separation_z = next(iter(separation_values))

    device = torch.device(device_name)
    model = _load_model(checkpoint_path, device)
    neural_sample_scores = _neural_scores(model, examples, batch_size, device)
    handwritten_sample_scores = [handwritten_evaluator_score(example) for example in examples]

    neural_candidates: list[float] = []
    handwritten_candidates: list[float] = []
    for candidate in candidates:
        start = int(candidate["sample_start"])
        stop = int(candidate["sample_stop"])
        weights = sample_weights[start:stop]
        total_weight = sum(weights)
        neural_candidates.append(
            sum(weight * score for weight, score in zip(weights, neural_sample_scores[start:stop]))
            / total_weight
        )
        handwritten_candidates.append(
            sum(weight * score for weight, score in zip(weights, handwritten_sample_scores[start:stop]))
            / total_weight
        )

    targets = [float(candidate["target"]) for candidate in candidates]
    target_standard_errors = [float(candidate["target_standard_error"]) for candidate in candidates]
    decision_ids = [str(candidate["decision_id"]) for candidate in candidates]
    proposal_scores = [float(candidate["proposal_score"]) for candidate in candidates]
    decision_counts: dict[str, int] = {}
    for decision_id in decision_ids:
        decision_counts[decision_id] = decision_counts.get(decision_id, 0) + 1
    evaluated_decisions = sum(count >= 2 for count in decision_counts.values())
    if evaluated_decisions == 0:
        raise ValueError("counterfactual data contains no decision with at least two labeled candidates")

    candidate_details = []
    for candidate, neural_score, handwritten_score in zip(
        candidates, neural_candidates, handwritten_candidates
    ):
        candidate_details.append(
            {
                "decision_id": candidate["decision_id"],
                "candidate_id": candidate["candidate_id"],
                "candidate_label": candidate["candidate_label"],
                "candidate_description": candidate["candidate_description"],
                "target_return": candidate["target"],
                "target_standard_error": candidate["target_standard_error"],
                "target_coverage": candidate["coverage"],
                "neural_score": neural_score,
                "handwritten_score": handwritten_score,
                "planner_proposal_score": candidate["proposal_score"],
            }
        )

    return {
        "candidate_rows": len(rows),
        "evaluated_candidates": len(candidates),
        "excluded_candidates": len(rows) - len(candidates),
        "evaluated_decisions": evaluated_decisions,
        "labeled_sample_states": len(examples),
        "mean_target_coverage": sum(float(candidate["coverage"]) for candidate in candidates) / len(candidates),
        "target_semantics": "policy_conditional_terminal_return_estimate",
        "candidate_score_semantics": "weighted_first_turn_state_value_over_labeled_policy_samples",
        "uncertainty_semantics": "descriptive_between_policy_sample_spread_not_statistical_confidence",
        "separation_z": separation_z,
        "candidate_details": candidate_details,
        "evaluators": {
            "neural_value_model": _metric_set(
                neural_candidates, targets, target_standard_errors, decision_ids, separation_z
            ),
            "handwritten_state_evaluator": _metric_set(
                handwritten_candidates, targets, target_standard_errors, decision_ids, separation_z
            ),
            "planner_proposal_score": _metric_set(
                proposal_scores, targets, target_standard_errors, decision_ids, separation_z
            ),
        },
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Evaluate plan ranking and regret on counterfactual candidates.")
    parser.add_argument("--candidates", required=True, help="Counterfactual candidates.jsonl")
    parser.add_argument("--checkpoint", required=True, help="Trained value-model checkpoint")
    parser.add_argument("--output", required=True, help="Path for decision-quality metrics JSON")
    parser.add_argument("--batch-size", type=int, default=64)
    parser.add_argument("--device", default="cpu")
    return parser


def main() -> None:
    args = build_parser().parse_args()
    rows = load_jsonl_examples(args.candidates)
    result = evaluate_counterfactual_rows(rows, args.checkpoint, args.batch_size, args.device)
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
