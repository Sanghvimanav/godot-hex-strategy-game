from __future__ import annotations

import json
import random
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Sequence

import torch
from torch.utils.data import Dataset

SCHEMA_VERSION = 1
MAX_RADIUS = 5
BOARD_SIZE = MAX_RADIUS * 2 + 1

# Stable V1 vocabulary. Unknown/future units intentionally fall into "other" so
# old datasets remain readable when new unit definitions are added.
UNIT_TYPES: tuple[str, ...] = (
    "baneling",
    "excavator",
    "fester",
    "ghost",
    "hydralisk",
    "infantry_camp",
    "mage",
    "marine",
    "medic",
    "mountain",
    "peasant",
    "scout",
    "shardling",
    "spire",
    "zergling",
    "other",
)
UNIT_TYPE_INDEX = {name: index for index, name in enumerate(UNIT_TYPES)}

# Board channels are perspective-relative, which lets one model learn both sides.
VALID_MASK_CHANNEL = 0
OWN_TYPE_OFFSET = 1
ENEMY_TYPE_OFFSET = OWN_TYPE_OFFSET + len(UNIT_TYPES)
OWN_HEALTH_CHANNEL = ENEMY_TYPE_OFFSET + len(UNIT_TYPES)
ENEMY_HEALTH_CHANNEL = OWN_HEALTH_CHANNEL + 1
OWN_ENERGY_CHANNEL = ENEMY_HEALTH_CHANNEL + 1
ENEMY_ENERGY_CHANNEL = OWN_ENERGY_CHANNEL + 1
BOARD_CHANNELS = ENEMY_ENERGY_CHANNEL + 1

GLOBAL_FEATURE_NAMES: tuple[str, ...] = (
    "own_alive_units",
    "enemy_alive_units",
    "own_health",
    "enemy_health",
    "own_resources",
    "enemy_resources",
    "own_energy",
    "enemy_energy",
    "turn_index",
    "terminal",
    "hex_radius",
)
GLOBAL_FEATURES = len(GLOBAL_FEATURE_NAMES)

# Conservative normalization constants for the compact scenarios in the current
# game. Values are clipped so unusually large future states remain bounded.
UNIT_COUNT_SCALE = 20.0
HEALTH_SCALE = 100.0
RESOURCE_SCALE = 50.0
ENERGY_SCALE = 50.0
TURN_SCALE = 50.0


@dataclass(frozen=True)
class EncodedExample:
    board: torch.Tensor
    global_features: torch.Tensor
    target: torch.Tensor


def _clip01(value: float) -> float:
    return max(0.0, min(1.0, value))


def _unit_type(def_path: str) -> str:
    name = Path(def_path).stem.lower()
    return name if name in UNIT_TYPE_INDEX else "other"


def _cell(unit: dict[str, Any]) -> tuple[int, int] | None:
    value = unit.get("cell")
    if not isinstance(value, list) or len(value) < 2:
        return None
    return int(value[0]), int(value[1])


def _in_hex(q: int, r: int, radius: int) -> bool:
    s = -q - r
    return max(abs(q), abs(r), abs(s)) <= radius


def _resource_total(group: dict[str, Any]) -> float:
    resources = group.get("resources", {})
    if not isinstance(resources, dict):
        return 0.0
    return sum(float(value) for value in resources.values() if isinstance(value, (int, float)))


class HexStateEncoder:
    """Encode schema-v1 self-play examples into perspective-relative tensors."""

    board_channels = BOARD_CHANNELS
    global_features = GLOBAL_FEATURES
    board_size = BOARD_SIZE
    max_radius = MAX_RADIUS
    unit_types = UNIT_TYPES

    def encode(self, example: dict[str, Any]) -> EncodedExample:
        if int(example.get("schema_version", -1)) != SCHEMA_VERSION:
            raise ValueError(f"unsupported schema_version: {example.get('schema_version')}")
        perspective = str(example.get("perspective_group", ""))
        if not perspective:
            raise ValueError("perspective_group is required")
        state = example.get("state")
        if not isinstance(state, dict):
            raise ValueError("state must be an object")

        radius = int(state.get("hex_radius", MAX_RADIUS))
        if radius <= 0 or radius > MAX_RADIUS:
            raise ValueError(f"hex_radius must be in [1, {MAX_RADIUS}], got {radius}")

        board = torch.zeros((BOARD_CHANNELS, BOARD_SIZE, BOARD_SIZE), dtype=torch.float32)
        for q in range(-MAX_RADIUS, MAX_RADIUS + 1):
            for r in range(-MAX_RADIUS, MAX_RADIUS + 1):
                if _in_hex(q, r, radius):
                    board[VALID_MASK_CHANNEL, r + MAX_RADIUS, q + MAX_RADIUS] = 1.0

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

        groups = state.get("groups", [])
        if not isinstance(groups, list):
            raise ValueError("state.groups must be an array")

        for group in groups:
            if not isinstance(group, dict):
                continue
            relation = "own" if str(group.get("name", "")) == perspective else "enemy"
            totals[f"{relation}_resources"] += _resource_total(group)
            units = group.get("units", [])
            if not isinstance(units, list):
                continue
            for unit in units:
                if not isinstance(unit, dict):
                    continue
                health = float(unit.get("health", 0.0))
                if health <= 0:
                    continue
                cell = _cell(unit)
                if cell is None:
                    continue
                q, r = cell
                if not _in_hex(q, r, radius):
                    continue
                row, col = r + MAX_RADIUS, q + MAX_RADIUS
                unit_type = _unit_type(str(unit.get("def_path", "")))
                type_index = UNIT_TYPE_INDEX[unit_type]
                type_channel = (OWN_TYPE_OFFSET if relation == "own" else ENEMY_TYPE_OFFSET) + type_index
                board[type_channel, row, col] += 1.0

                max_health = max(1.0, float(unit.get("max_health", health)))
                health_channel = OWN_HEALTH_CHANNEL if relation == "own" else ENEMY_HEALTH_CHANNEL
                board[health_channel, row, col] += _clip01(health / max_health)

                energy = max(0.0, float(unit.get("energy", 0.0)))
                max_energy = max(0.0, float(unit.get("max_energy", 0.0)))
                energy_channel = OWN_ENERGY_CHANNEL if relation == "own" else ENEMY_ENERGY_CHANNEL
                board[energy_channel, row, col] += 0.0 if max_energy <= 0 else _clip01(energy / max_energy)

                totals[f"{relation}_units"] += 1.0
                totals[f"{relation}_health"] += health
                totals[f"{relation}_energy"] += energy

        turn_index = float(example.get("turn_index", 0.0))
        terminal = 1.0 if bool(example.get("terminal", False)) else 0.0
        global_features = torch.tensor(
            [
                _clip01(totals["own_units"] / UNIT_COUNT_SCALE),
                _clip01(totals["enemy_units"] / UNIT_COUNT_SCALE),
                _clip01(totals["own_health"] / HEALTH_SCALE),
                _clip01(totals["enemy_health"] / HEALTH_SCALE),
                _clip01(totals["own_resources"] / RESOURCE_SCALE),
                _clip01(totals["enemy_resources"] / RESOURCE_SCALE),
                _clip01(totals["own_energy"] / ENERGY_SCALE),
                _clip01(totals["enemy_energy"] / ENERGY_SCALE),
                _clip01(turn_index / TURN_SCALE),
                terminal,
                radius / MAX_RADIUS,
            ],
            dtype=torch.float32,
        )
        target = torch.tensor(float(example.get("outcome", 0.0)), dtype=torch.float32)
        return EncodedExample(board=board, global_features=global_features, target=target)


class ValueExampleDataset(Dataset[tuple[torch.Tensor, torch.Tensor, torch.Tensor]]):
    def __init__(self, examples: Sequence[dict[str, Any]], encoder: HexStateEncoder | None = None):
        self.examples = list(examples)
        self.encoder = encoder or HexStateEncoder()

    def __len__(self) -> int:
        return len(self.examples)

    def __getitem__(self, index: int) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
        encoded = self.encoder.encode(self.examples[index])
        return encoded.board, encoded.global_features, encoded.target


def load_jsonl_examples(path: str | Path) -> list[dict[str, Any]]:
    examples: list[dict[str, Any]] = []
    with Path(path).open("r", encoding="utf-8") as handle:
        for line_number, raw_line in enumerate(handle, start=1):
            line = raw_line.strip()
            if not line:
                continue
            value = json.loads(line)
            if not isinstance(value, dict):
                raise ValueError(f"line {line_number} is not a JSON object")
            examples.append(value)
    return examples


def example_group_value(example: dict[str, Any], group_key: str) -> str:
    """Return a non-empty grouping value from a dotted example key path."""
    if not group_key:
        raise ValueError("group_key is required")
    value: Any = example
    for part in group_key.split("."):
        if not isinstance(value, dict) or part not in value:
            raise ValueError(f"example is missing split key '{group_key}'")
        value = value[part]
    result = str(value)
    if not result:
        raise ValueError(f"example split key '{group_key}' is empty")
    return result


def split_examples_by_group(
    examples: Sequence[dict[str, Any]],
    validation_fraction: float = 0.2,
    seed: int = 0,
    group_key: str = "game_id",
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    """Split whole groups so related examples never leak across train/validation."""
    if not 0.0 <= validation_fraction < 1.0:
        raise ValueError("validation_fraction must be in [0, 1)")
    by_group: dict[str, list[dict[str, Any]]] = {}
    for example in examples:
        group_value = example_group_value(example, group_key)
        by_group.setdefault(group_value, []).append(example)

    group_values = sorted(by_group)
    random.Random(seed).shuffle(group_values)
    if len(group_values) <= 1 or validation_fraction == 0.0:
        validation_values: set[str] = set()
    else:
        validation_count = max(1, round(len(group_values) * validation_fraction))
        validation_count = min(validation_count, len(group_values) - 1)
        validation_values = set(group_values[:validation_count])

    train: list[dict[str, Any]] = []
    validation: list[dict[str, Any]] = []
    for group_value, group_examples in by_group.items():
        (validation if group_value in validation_values else train).extend(group_examples)
    return train, validation


def split_examples_by_game(
    examples: Sequence[dict[str, Any]], validation_fraction: float = 0.2, seed: int = 0
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    """Backward-compatible game-level split for ordinary training."""
    return split_examples_by_group(
        examples,
        validation_fraction=validation_fraction,
        seed=seed,
        group_key="game_id",
    )
