from __future__ import annotations

from typing import Any, Sequence

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
