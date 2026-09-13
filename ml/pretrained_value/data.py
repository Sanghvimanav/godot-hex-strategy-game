from __future__ import annotations

import hashlib
import math
from collections import defaultdict
from pathlib import Path
from typing import Any, Iterable, Sequence

from ml.value_model.data import (
    ENERGY_SCALE,
    HEALTH_SCALE,
    MAX_RADIUS,
    RESOURCE_SCALE,
    TURN_SCALE,
    UNIT_COUNT_SCALE,
    UNIT_TYPE_INDEX,
)
from ml.value_model.ranking import pair_as_example


def _clip01(value: float) -> float:
    return max(0.0, min(1.0, value))


def _unit_type(def_path: str) -> str:
    name = Path(def_path).stem.lower()
    return name if name in UNIT_TYPE_INDEX else "other"


def _cell(value: Any) -> tuple[int, int] | None:
    if not isinstance(value, list) or len(value) < 2:
        return None
    return int(value[0]), int(value[1])


def _groups(state: dict[str, Any]) -> list[dict[str, Any]]:
    groups = state.get("groups", [])
    return [group for group in groups if isinstance(group, dict)] if isinstance(groups, list) else []


def _resource_total(group: dict[str, Any] | None) -> float:
    if not group:
        return 0.0
    resources = group.get("resources", {})
    if not isinstance(resources, dict):
        return 0.0
    return sum(float(value) for value in resources.values() if isinstance(value, (int, float)))


def _command_cell(state: dict[str, Any], group_name: str) -> tuple[int, int] | None:
    command_hexes = state.get("command_hexes", {})
    if not isinstance(command_hexes, dict):
        return None
    return _cell(command_hexes.get(group_name))


def _format_cell(value: tuple[int, int] | None) -> str:
    if value is None:
        return "none"
    return f"q={value[0]} r={value[1]}"


def _format_type_counts(counts: dict[str, int]) -> str:
    if not counts:
        return "none"
    return ",".join(f"{name}:{counts[name]}" for name in sorted(counts))


def serialize_value_example(example: dict[str, Any]) -> str:
    """Serialize exactly the information exposed by ``HexStateEncoder``.

    The text intentionally omits winner labels, action choices, evaluator scores,
    unit ids, effects, activity flags, resource names, and other raw-state fields
    that the CNN cannot see. It retains the perspective-relative unit-type
    occupancy, per-cell HP/energy ratios, command hexes, and normalized global
    features used by the current neural evaluator.
    """

    perspective = str(example.get("perspective_group", ""))
    if not perspective:
        raise ValueError("perspective_group is required")
    opponent = str(example.get("opponent_group", ""))
    state = example.get("state")
    if not isinstance(state, dict):
        raise ValueError("state must be an object")

    groups = _groups(state)
    if not opponent:
        for group in groups:
            name = str(group.get("name", ""))
            if name and name != perspective:
                opponent = name
                break
    if not opponent:
        raise ValueError("opponent_group is required or inferable")

    radius = int(state.get("hex_radius", MAX_RADIUS))
    if radius <= 0 or radius > MAX_RADIUS:
        raise ValueError(f"hex_radius must be in [1, {MAX_RADIUS}], got {radius}")

    per_cell: dict[tuple[int, int], dict[str, Any]] = defaultdict(
        lambda: {
            "own_types": defaultdict(int),
            "enemy_types": defaultdict(int),
            "own_hp": 0.0,
            "enemy_hp": 0.0,
            "own_energy": 0.0,
            "enemy_energy": 0.0,
        }
    )
    totals = {
        "own_units": 0.0,
        "enemy_units": 0.0,
        "own_health": 0.0,
        "enemy_health": 0.0,
        "own_resources": 0.0,
        "enemy_resources": 0.0,
        "own_energy": 0.0,
        "enemy_energy": 0.0,
    }

    for group in groups:
        name = str(group.get("name", ""))
        relation = "own" if name == perspective else "enemy"
        totals[f"{relation}_resources"] += _resource_total(group)
        units = group.get("units", [])
        if not isinstance(units, list):
            continue
        for unit in units:
            if not isinstance(unit, dict):
                continue
            health = float(unit.get("health", 0.0))
            if health <= 0.0:
                continue
            cell = _cell(unit.get("cell"))
            if cell is None:
                continue
            q, r = cell
            s = -q - r
            if max(abs(q), abs(r), abs(s)) > radius:
                continue
            max_health = max(1.0, float(unit.get("max_health", health)))
            energy = max(0.0, float(unit.get("energy", 0.0)))
            max_energy = max(0.0, float(unit.get("max_energy", 0.0)))
            type_name = _unit_type(str(unit.get("def_path", "")))
            cell_features = per_cell[cell]
            cell_features[f"{relation}_types"][type_name] += 1
            cell_features[f"{relation}_hp"] += _clip01(health / max_health)
            if max_energy > 0.0:
                cell_features[f"{relation}_energy"] += _clip01(energy / max_energy)
            totals[f"{relation}_units"] += 1.0
            totals[f"{relation}_health"] += health
            totals[f"{relation}_energy"] += energy

    turn_index = float(example.get("turn_index", 0.0))
    terminal = 1 if bool(example.get("terminal", False)) else 0
    global_values = {
        "own_units": _clip01(totals["own_units"] / UNIT_COUNT_SCALE),
        "enemy_units": _clip01(totals["enemy_units"] / UNIT_COUNT_SCALE),
        "own_health": _clip01(totals["own_health"] / HEALTH_SCALE),
        "enemy_health": _clip01(totals["enemy_health"] / HEALTH_SCALE),
        "own_resources": _clip01(totals["own_resources"] / RESOURCE_SCALE),
        "enemy_resources": _clip01(totals["enemy_resources"] / RESOURCE_SCALE),
        "own_energy": _clip01(totals["own_energy"] / ENERGY_SCALE),
        "enemy_energy": _clip01(totals["enemy_energy"] / ENERGY_SCALE),
        "turn": _clip01(turn_index / TURN_SCALE),
        "terminal": float(terminal),
        "radius": radius / MAX_RADIUS,
    }

    lines = [
        "HEX_VALUE_STATE_V1",
        f"PERSPECTIVE {perspective}",
        f"TURN_NORM {global_values['turn']:.4f}",
        f"TERMINAL {terminal}",
        f"RADIUS {radius}",
        f"OWN_COMMAND {_format_cell(_command_cell(state, perspective))}",
        f"ENEMY_COMMAND {_format_cell(_command_cell(state, opponent))}",
        "GLOBALS "
        + " ".join(
            f"{key}={global_values[key]:.4f}"
            for key in (
                "own_units",
                "enemy_units",
                "own_health",
                "enemy_health",
                "own_resources",
                "enemy_resources",
                "own_energy",
                "enemy_energy",
                "turn",
                "terminal",
                "radius",
            )
        ),
    ]
    for q, r in sorted(per_cell):
        features = per_cell[(q, r)]
        lines.append(
            "CELL "
            f"q={q} r={r} "
            f"own_types={_format_type_counts(dict(features['own_types']))} "
            f"enemy_types={_format_type_counts(dict(features['enemy_types']))} "
            f"own_hp={features['own_hp']:.4f} enemy_hp={features['enemy_hp']:.4f} "
            f"own_energy={features['own_energy']:.4f} enemy_energy={features['enemy_energy']:.4f}"
        )
    return "\n".join(lines)


def ranking_pair_texts(pair: dict[str, Any]) -> tuple[str, str]:
    return (
        serialize_value_example(pair_as_example(pair, "better")),
        serialize_value_example(pair_as_example(pair, "worse")),
    )


def _group_id(row: dict[str, Any], key: str) -> str:
    value: Any = row
    for part in key.split("."):
        if not isinstance(value, dict) or part not in value:
            raise ValueError(f"row is missing grouping key '{key}'")
        value = value[part]
    result = str(value)
    if not result:
        raise ValueError(f"grouping key '{key}' is empty")
    return result


def nested_group_subsample(
    rows: Sequence[dict[str, Any]],
    fraction: float,
    group_key: str = "game_id",
    seed: int = 0,
) -> list[dict[str, Any]]:
    """Choose a deterministic nested fraction while keeping whole groups together."""

    if not 0.0 < fraction <= 1.0:
        raise ValueError("fraction must be in (0, 1]")
    if not rows:
        return []
    groups: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in rows:
        groups[_group_id(row, group_key)].append(row)
    ordered = sorted(
        groups,
        key=lambda value: hashlib.sha256(f"{seed}:{value}".encode("utf-8")).hexdigest(),
    )
    take = max(1, min(len(ordered), math.ceil(len(ordered) * fraction)))
    selected = set(ordered[:take])
    return [row for row in rows if _group_id(row, group_key) in selected]


def rows_with_group_values(
    rows: Iterable[dict[str, Any]],
    group_key: str,
    values: set[str],
    include: bool,
) -> list[dict[str, Any]]:
    return [row for row in rows if (_group_id(row, group_key) in values) is include]
