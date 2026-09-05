from __future__ import annotations

from typing import Any, Hashable, Sequence

import torch

TERMINAL_WEIGHT = 100000.0
UNIT_COUNT_WEIGHT = 100.0
HEALTH_WEIGHT = 10.0
RESOURCE_WEIGHT = 2.0
ENERGY_WEIGHT = 1.0


def _resource_total(resources: Any) -> float:
    if not isinstance(resources, dict):
        return 0.0
    return sum(float(value) for value in resources.values() if isinstance(value, (int, float)))


def _group_totals(group: dict[str, Any]) -> tuple[int, float, float, float]:
    units = 0
    health = 0.0
    energy = 0.0
    for unit in group.get("units", []):
        if not isinstance(unit, dict):
            continue
        unit_health = float(unit.get("health", 0.0))
        if unit_health <= 0:
            continue
        units += 1
        health += unit_health
        energy += max(0.0, float(unit.get("energy", 0.0)))
    return units, health, _resource_total(group.get("resources", {})), energy


def handwritten_evaluator_score(example: dict[str, Any]) -> float:
    """Python parity implementation of PureStateEvaluator for offline comparison."""
    perspective = str(example.get("perspective_group", ""))
    state = example.get("state", {})
    if not isinstance(state, dict):
        return 0.0
    groups = [group for group in state.get("groups", []) if isinstance(group, dict)]
    own_group = next((group for group in groups if str(group.get("name", "")) == perspective), None)
    if own_group is None:
        return 0.0
    own_units, own_health, own_resources, own_energy = _group_totals(own_group)
    enemy_units = 0
    enemy_health = 0.0
    enemy_resources = 0.0
    enemy_energy = 0.0
    enemy_group_count = 0
    for group in groups:
        if str(group.get("name", "")) == perspective:
            continue
        enemy_group_count += 1
        units, health, resources, energy = _group_totals(group)
        enemy_units += units
        enemy_health += health
        enemy_resources += resources
        enemy_energy += energy

    terminal = 0.0
    if enemy_group_count > 0:
        if own_units > 0 and enemy_units == 0:
            terminal = TERMINAL_WEIGHT
        elif own_units == 0 and enemy_units > 0:
            terminal = -TERMINAL_WEIGHT
    return (
        terminal
        + (own_units - enemy_units) * UNIT_COUNT_WEIGHT
        + (own_health - enemy_health) * HEALTH_WEIGHT
        + (own_resources - enemy_resources) * RESOURCE_WEIGHT
        + (own_energy - enemy_energy) * ENERGY_WEIGHT
    )


def sign_accuracy(scores: Sequence[float] | torch.Tensor, targets: Sequence[float] | torch.Tensor) -> float:
    score_tensor = torch.as_tensor(scores, dtype=torch.float32)
    target_tensor = torch.as_tensor(targets, dtype=torch.float32)
    if target_tensor.numel() == 0:
        return float("nan")
    return float((torch.sign(score_tensor) == torch.sign(target_tensor)).float().mean().item())


def _group_candidate_indices(
    predictions: Sequence[float] | torch.Tensor,
    targets: Sequence[float] | torch.Tensor,
    decision_ids: Sequence[Hashable],
) -> tuple[torch.Tensor, torch.Tensor, dict[Hashable, list[int]]]:
    prediction_tensor = torch.as_tensor(predictions, dtype=torch.float32).flatten()
    target_tensor = torch.as_tensor(targets, dtype=torch.float32).flatten()
    if prediction_tensor.numel() != target_tensor.numel():
        raise ValueError("predictions and targets must contain the same number of candidates")
    if prediction_tensor.numel() != len(decision_ids):
        raise ValueError("decision_ids must contain one id per candidate")
    grouped: dict[Hashable, list[int]] = {}
    for index, decision_id in enumerate(decision_ids):
        grouped.setdefault(decision_id, []).append(index)
    return prediction_tensor, target_tensor, grouped


def candidate_ranking_metrics(
    predictions: Sequence[float] | torch.Tensor,
    targets: Sequence[float] | torch.Tensor,
    decision_ids: Sequence[Hashable],
    tie_tolerance: float = 1e-8,
) -> dict[str, float | int]:
    """Measure pairwise ordering within each decision's candidate plans.

    Target ties are omitted because neither candidate is objectively better.
    Prediction ties receive half credit. Every remaining candidate pair is
    weighted equally across the benchmark.
    """
    prediction_tensor, target_tensor, grouped = _group_candidate_indices(
        predictions, targets, decision_ids
    )
    correct_credit = 0.0
    comparable_pairs = 0
    decisions_with_pairs = 0
    for indices in grouped.values():
        decision_pairs = 0
        for left_offset, left in enumerate(indices):
            for right in indices[left_offset + 1 :]:
                target_delta = float(target_tensor[left] - target_tensor[right])
                if abs(target_delta) <= tie_tolerance:
                    continue
                prediction_delta = float(prediction_tensor[left] - prediction_tensor[right])
                comparable_pairs += 1
                decision_pairs += 1
                if abs(prediction_delta) <= tie_tolerance:
                    correct_credit += 0.5
                elif (prediction_delta > 0.0) == (target_delta > 0.0):
                    correct_credit += 1.0
        if decision_pairs > 0:
            decisions_with_pairs += 1

    accuracy = correct_credit / comparable_pairs if comparable_pairs else float("nan")
    return {
        "candidate_ranking_accuracy": accuracy,
        "candidate_ranking_pairs": comparable_pairs,
        "candidate_ranking_decisions": decisions_with_pairs,
    }


def uncertainty_aware_candidate_ranking_metrics(
    predictions: Sequence[float] | torch.Tensor,
    targets: Sequence[float] | torch.Tensor,
    target_standard_errors: Sequence[float] | torch.Tensor,
    decision_ids: Sequence[Hashable],
    separation_z: float = 1.96,
    tie_tolerance: float = 1e-8,
) -> dict[str, float | int]:
    """Rank only candidate pairs the counterfactual samples meaningfully separate.

    This mirrors the benchmark's descriptive separation rule. The standard errors
    summarize spread across a small, versioned policy mixture; they are not a
    claim of classical statistical significance or independent random sampling.
    """
    prediction_tensor, target_tensor, grouped = _group_candidate_indices(
        predictions, targets, decision_ids
    )
    error_tensor = torch.as_tensor(target_standard_errors, dtype=torch.float32).flatten()
    if error_tensor.numel() != target_tensor.numel():
        raise ValueError("target_standard_errors must contain one value per candidate")

    correct_credit = 0.0
    comparable_pairs = 0
    decisions_with_pairs = 0
    safe_z = max(0.0, float(separation_z))
    for indices in grouped.values():
        decision_pairs = 0
        for left_offset, left in enumerate(indices):
            for right in indices[left_offset + 1 :]:
                target_delta = float(target_tensor[left] - target_tensor[right])
                if abs(target_delta) <= tie_tolerance:
                    continue
                combined_error = (
                    float(error_tensor[left]) ** 2 + float(error_tensor[right]) ** 2
                ) ** 0.5
                if abs(target_delta) <= safe_z * combined_error:
                    continue
                prediction_delta = float(prediction_tensor[left] - prediction_tensor[right])
                comparable_pairs += 1
                decision_pairs += 1
                if abs(prediction_delta) <= tie_tolerance:
                    correct_credit += 0.5
                elif (prediction_delta > 0.0) == (target_delta > 0.0):
                    correct_credit += 1.0
        if decision_pairs > 0:
            decisions_with_pairs += 1

    accuracy = correct_credit / comparable_pairs if comparable_pairs else float("nan")
    return {
        "uncertainty_aware_candidate_ranking_accuracy": accuracy,
        "uncertainty_aware_candidate_ranking_pairs": comparable_pairs,
        "uncertainty_aware_candidate_ranking_decisions": decisions_with_pairs,
        "uncertainty_aware_separation_z": safe_z,
    }


def top_plan_regret_metrics(
    predictions: Sequence[float] | torch.Tensor,
    targets: Sequence[float] | torch.Tensor,
    decision_ids: Sequence[Hashable],
    tie_tolerance: float = 1e-8,
) -> dict[str, float | int]:
    """Measure value lost by choosing the top predicted plan per decision.

    Prediction ties are resolved by stable input order, matching a deterministic
    planner. Decisions with fewer than two candidates are excluded because they
    contain no choice.
    """
    prediction_tensor, target_tensor, grouped = _group_candidate_indices(
        predictions, targets, decision_ids
    )
    regrets: list[float] = []
    optimal_choices = 0
    for indices in grouped.values():
        if len(indices) < 2:
            continue
        chosen = max(indices, key=lambda index: float(prediction_tensor[index]))
        oracle_value = max(float(target_tensor[index]) for index in indices)
        chosen_value = float(target_tensor[chosen])
        regret = max(0.0, oracle_value - chosen_value)
        regrets.append(regret)
        if regret <= tie_tolerance:
            optimal_choices += 1

    if not regrets:
        return {
            "top_plan_mean_regret": float("nan"),
            "top_plan_max_regret": float("nan"),
            "top_plan_optimal_rate": float("nan"),
            "top_plan_decisions": 0,
        }
    return {
        "top_plan_mean_regret": sum(regrets) / len(regrets),
        "top_plan_max_regret": max(regrets),
        "top_plan_optimal_rate": optimal_choices / len(regrets),
        "top_plan_decisions": len(regrets),
    }
