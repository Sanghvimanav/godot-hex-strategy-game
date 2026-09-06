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
    if not examples:
        return []
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


def _weighted_average(weights: Sequence[float], scores: Sequence[float]) -> float:
    total_weight = sum(weights)
    if total_weight <= 0.0:
        raise ValueError("weighted score population has no positive weight")
    return sum(weight * score for weight, score in zip(weights, scores)) / total_weight


def _interval_fit_metrics(
    predictions: Sequence[float],
    lower_bounds: Sequence[float],
    upper_bounds: Sequence[float],
) -> dict[str, float | int]:
    if not (len(predictions) == len(lower_bounds) == len(upper_bounds)):
        raise ValueError("interval metric inputs must have equal lengths")
    if not predictions:
        return {
            "interval_fit_candidates": 0,
            "interval_fit_rate": 0.0,
            "mean_distance_outside_interval": 0.0,
            "max_distance_outside_interval": 0.0,
        }
    distances: list[float] = []
    inside = 0
    for prediction, lower, upper in zip(predictions, lower_bounds, upper_bounds):
        if lower <= prediction <= upper:
            inside += 1
            distances.append(0.0)
        elif prediction < lower:
            distances.append(lower - prediction)
        else:
            distances.append(prediction - upper)
    return {
        "interval_fit_candidates": len(predictions),
        "interval_fit_rate": inside / len(predictions),
        "mean_distance_outside_interval": sum(distances) / len(distances),
        "max_distance_outside_interval": max(distances),
    }


def evaluate_counterfactual_rows(
    rows: Sequence[dict[str, Any]],
    checkpoint_path: str | Path,
    batch_size: int = 64,
    device_name: str = "cpu",
) -> dict[str, Any]:
    """Score counterfactual candidates with neural, handwritten, and planner evaluators.

    The benchmark target keeps unresolved continuation mass as an interval. For
    backward-compatible ranking metrics we still compare against the conditional
    terminal mean, but evaluator diagnostics now score two populations:

    1. labeled-policy states: only branches whose continuation reached a terminal;
    2. all-policy states: every valid first-turn branch, including unresolved ones.

    The second population lets us see what the evaluator thinks about states such
    as a successful escape even when the rollout cannot yet produce a terminal label.
    """
    candidates: list[dict[str, Any]] = []
    labeled_examples: list[dict[str, Any]] = []
    labeled_weights: list[float] = []
    all_examples: list[dict[str, Any]] = []
    all_weights: list[float] = []

    for row in rows:
        if not isinstance(row, dict):
            continue
        estimate = row.get("target_estimate", {})
        if not isinstance(estimate, dict) or int(estimate.get("return_count", 0)) <= 0:
            continue
        assumptions = row.get("assumptions", {})
        if not isinstance(assumptions, dict):
            assumptions = {}

        labeled_start = len(labeled_examples)
        all_start = len(all_examples)
        for sample in row.get("samples", []):
            if not isinstance(sample, dict):
                continue
            weight = max(0.0, float(sample.get("weight", 0.0)))
            state = sample.get("state_after_first_turn")
            if (
                not bool(sample.get("valid", True))
                or weight <= 0.0
                or not isinstance(state, dict)
                or not state
            ):
                continue
            example = _sample_example(row, sample)
            all_examples.append(example)
            all_weights.append(weight)
            if bool(sample.get("labeled", False)):
                labeled_examples.append(example)
                labeled_weights.append(weight)

        labeled_stop = len(labeled_examples)
        all_stop = len(all_examples)
        if labeled_stop == labeled_start or all_stop == all_start:
            continue

        conditional_target = float(
            estimate.get(
                "conditional_labeled_mean_return",
                estimate.get("mean_return", 0.0),
            )
        )
        lower_bound = float(estimate.get("full_mixture_lower_bound", conditional_target))
        upper_bound = float(estimate.get("full_mixture_upper_bound", conditional_target))
        candidates.append(
            {
                "decision_id": str(row.get("decision_id", "")),
                "candidate_id": str(row.get("candidate_id", "")),
                "candidate_label": str(row.get("candidate_label", row.get("candidate_id", ""))),
                "candidate_description": str(row.get("candidate_description", "")),
                "target": conditional_target,
                "target_lower_bound": lower_bound,
                "target_upper_bound": upper_bound,
                "target_standard_error": max(0.0, float(estimate.get("estimated_standard_error", 0.0))),
                "proposal_score": float(row.get("proposal_score", 0.0)),
                "labeled_sample_start": labeled_start,
                "labeled_sample_stop": labeled_stop,
                "all_sample_start": all_start,
                "all_sample_stop": all_stop,
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
    neural_labeled_sample_scores = _neural_scores(model, labeled_examples, batch_size, device)
    neural_all_sample_scores = _neural_scores(model, all_examples, batch_size, device)
    handwritten_labeled_sample_scores = [
        handwritten_evaluator_score(example) for example in labeled_examples
    ]
    handwritten_all_sample_scores = [
        handwritten_evaluator_score(example) for example in all_examples
    ]

    neural_labeled_candidates: list[float] = []
    neural_all_candidates: list[float] = []
    handwritten_labeled_candidates: list[float] = []
    handwritten_all_candidates: list[float] = []
    for candidate in candidates:
        labeled_start = int(candidate["labeled_sample_start"])
        labeled_stop = int(candidate["labeled_sample_stop"])
        all_start = int(candidate["all_sample_start"])
        all_stop = int(candidate["all_sample_stop"])

        neural_labeled_candidates.append(
            _weighted_average(
                labeled_weights[labeled_start:labeled_stop],
                neural_labeled_sample_scores[labeled_start:labeled_stop],
            )
        )
        neural_all_candidates.append(
            _weighted_average(
                all_weights[all_start:all_stop],
                neural_all_sample_scores[all_start:all_stop],
            )
        )
        handwritten_labeled_candidates.append(
            _weighted_average(
                labeled_weights[labeled_start:labeled_stop],
                handwritten_labeled_sample_scores[labeled_start:labeled_stop],
            )
        )
        handwritten_all_candidates.append(
            _weighted_average(
                all_weights[all_start:all_stop],
                handwritten_all_sample_scores[all_start:all_stop],
            )
        )

    targets = [float(candidate["target"]) for candidate in candidates]
    lower_bounds = [float(candidate["target_lower_bound"]) for candidate in candidates]
    upper_bounds = [float(candidate["target_upper_bound"]) for candidate in candidates]
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
    for candidate, neural_labeled, neural_all, handwritten_labeled, handwritten_all in zip(
        candidates,
        neural_labeled_candidates,
        neural_all_candidates,
        handwritten_labeled_candidates,
        handwritten_all_candidates,
    ):
        candidate_details.append(
            {
                "decision_id": candidate["decision_id"],
                "candidate_id": candidate["candidate_id"],
                "candidate_label": candidate["candidate_label"],
                "candidate_description": candidate["candidate_description"],
                "target_return": candidate["target"],
                "target_conditional_labeled_mean_return": candidate["target"],
                "target_full_mixture_lower_bound": candidate["target_lower_bound"],
                "target_full_mixture_upper_bound": candidate["target_upper_bound"],
                "target_standard_error": candidate["target_standard_error"],
                "target_coverage": candidate["coverage"],
                # Backward-compatible names remain the labeled-policy population.
                "neural_score": neural_labeled,
                "handwritten_score": handwritten_labeled,
                "neural_score_labeled_policy": neural_labeled,
                "neural_score_all_policy": neural_all,
                "handwritten_score_labeled_policy": handwritten_labeled,
                "handwritten_score_all_policy": handwritten_all,
                "planner_proposal_score": candidate["proposal_score"],
                "labeled_policy_sample_states": int(candidate["labeled_sample_stop"])
                - int(candidate["labeled_sample_start"]),
                "all_policy_sample_states": int(candidate["all_sample_stop"])
                - int(candidate["all_sample_start"]),
            }
        )

    return {
        "candidate_rows": len(rows),
        "evaluated_candidates": len(candidates),
        "excluded_candidates": len(rows) - len(candidates),
        "evaluated_decisions": evaluated_decisions,
        "labeled_sample_states": len(labeled_examples),
        "all_valid_first_turn_sample_states": len(all_examples),
        "mean_target_coverage": sum(float(candidate["coverage"]) for candidate in candidates) / len(candidates),
        "target_semantics": "search_policy_terminal_return_with_unresolved_bounds_v2",
        "candidate_score_semantics": {
            "labeled_policy": "weighted_first_turn_state_value_over_labeled_policy_samples",
            "all_policy": "weighted_first_turn_state_value_over_all_valid_policy_samples_including_unresolved_continuations",
        },
        "uncertainty_semantics": "full-mixture terminal-return bounds preserve unresolved continuation mass",
        "separation_z": separation_z,
        "candidate_details": candidate_details,
        "interval_diagnostics": {
            "neural_value_model_all_policy": _interval_fit_metrics(
                neural_all_candidates, lower_bounds, upper_bounds
            ),
            "handwritten_state_evaluator_all_policy": _interval_fit_metrics(
                handwritten_all_candidates, lower_bounds, upper_bounds
            ),
        },
        "evaluators": {
            # Ranking/regret remain tied to the conditional labeled target for
            # backward compatibility; interval diagnostics above are the preferred
            # interpretation when target coverage is incomplete.
            "neural_value_model": _metric_set(
                neural_labeled_candidates, targets, target_standard_errors, decision_ids, separation_z
            ),
            "handwritten_state_evaluator": _metric_set(
                handwritten_labeled_candidates, targets, target_standard_errors, decision_ids, separation_z
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
