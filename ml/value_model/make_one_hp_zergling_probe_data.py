from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

BOARD_CELLS = [
    (0, 0),
    (1, 0),
    (1, -1),
    (0, -1),
    (-1, 0),
    (-1, 1),
    (0, 1),
]

MARINE_PATH = "res://src/unit/definitions/marine.tres"
ZERGLING_PATH = "res://src/unit/definitions/zergling.tres"


def hex_distance(a: tuple[int, int], b: tuple[int, int]) -> int:
    dq = a[0] - b[0]
    dr = a[1] - b[1]
    ds = (-a[0] - a[1]) - (-b[0] - b[1])
    return max(abs(dq), abs(dr), abs(ds))


def in_radius_one(cell: tuple[int, int]) -> bool:
    return hex_distance((0, 0), cell) <= 1


def unit(unit_id: int, path: str, cell: tuple[int, int], health: int, max_health: int) -> dict[str, Any]:
    return {
        "unit_id": unit_id,
        "def_path": path,
        "cell": [cell[0], cell[1]],
        "health": health,
        "max_health": max_health,
        "energy": 0,
        "max_energy": 0,
        "effects": [],
        "is_active": True,
    }


def state_for(zerg: tuple[int, int], marine: tuple[int, int]) -> dict[str, Any]:
    return {
        "scenario_id": "probe_one_hp_adjacent",
        "hex_radius": 1,
        "command_hexes_enabled": False,
        "tile_resources": {},
        "turn_index": 0,
        "curriculum": {"max_turns": 1, "turn_limit_winner": ""},
        "groups": [
            {
                "name": "terran",
                "resources": {},
                "units": [unit(1, MARINE_PATH, marine, 1, 4)],
            },
            {
                "name": "zerg",
                "resources": {},
                "units": [unit(2, ZERGLING_PATH, zerg, 3, 3)],
            },
        ],
    }


def signature(action: dict[str, Any]) -> str:
    return f"{int(action['unit_id'])}|{action['action_key']}|{action['end_point']}|{action['path']}"


def candidates_for(zerg: tuple[int, int]) -> list[dict[str, Any]]:
    candidates: list[dict[str, Any]] = []
    for target in BOARD_CELLS:
        if hex_distance(zerg, target) != 1:
            continue
        candidates.append(
            {
                "unit_id": 2,
                "action_key": "fast_move",
                "path": [[target[0], target[1]]],
                "end_point": [target[0], target[1]],
            }
        )
    candidates.append(
        {
            "unit_id": 2,
            "action_key": "reload",
            "path": [],
            "end_point": [zerg[0], zerg[1]],
        }
    )
    candidates.append(
        {
            "unit_id": 2,
            "action_key": "<hold>",
            "path": [],
            "end_point": [zerg[0], zerg[1]],
        }
    )
    candidates.sort(key=signature)
    return candidates


def build_row(zerg: tuple[int, int], marine: tuple[int, int], split: str) -> dict[str, Any]:
    if zerg == marine or hex_distance(zerg, marine) != 1:
        raise ValueError("probe starts must be adjacent and distinct")
    candidates = candidates_for(zerg)
    target_indices = [
        i
        for i, action in enumerate(candidates)
        if action["action_key"] == "fast_move" and action["end_point"] == [marine[0], marine[1]]
    ]
    if len(target_indices) != 1:
        raise ValueError(f"expected one fast_move kill target, got {target_indices}")
    layout_id = f"{zerg[0]},{zerg[1]}_to_{marine[0]},{marine[1]}"
    return {
        "game_id": f"{split}-{layout_id}",
        "split": split,
        "layout_id": layout_id,
        "state": state_for(zerg, marine),
        "perspective_group": "zerg",
        "opponent_group": "terran",
        "prefix_actions": [],
        "candidate_actions": candidates,
        "target_indices": target_indices,
        "selected_index": target_indices[0],
        "marine_cell": [marine[0], marine[1]],
        "zergling_cell": [zerg[0], zerg[1]],
    }


def write_jsonl(path: Path, rows: list[dict[str, Any]]) -> None:
    path.write_text("".join(json.dumps(row, sort_keys=True) + "\n" for row in rows))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()

    layouts = [
        (zerg, marine)
        for zerg in BOARD_CELLS
        for marine in BOARD_CELLS
        if zerg != marine and hex_distance(zerg, marine) == 1
    ]
    layouts.sort()
    if len(layouts) != 24:
        raise ValueError(f"expected 24 directed adjacent layouts, got {len(layouts)}")

    train_rows: list[dict[str, Any]] = []
    eval_rows: list[dict[str, Any]] = []
    for i, (zerg, marine) in enumerate(layouts):
        row = build_row(zerg, marine, "eval" if i % 4 == 0 else "train")
        (eval_rows if i % 4 == 0 else train_rows).append(row)

    if len(train_rows) != 18 or len(eval_rows) != 6:
        raise ValueError(f"expected 18/6 split, got {len(train_rows)}/{len(eval_rows)}")

    for row in train_rows + eval_rows:
        state = row["state"]
        marine = state["groups"][0]["units"][0]
        zerg = state["groups"][1]["units"][0]
        assert marine["health"] == 1
        assert marine["cell"] != zerg["cell"]
        assert hex_distance(tuple(marine["cell"]), tuple(zerg["cell"])) == 1
        target = row["candidate_actions"][row["target_indices"][0]]
        assert target["action_key"] == "fast_move"
        assert target["end_point"] == marine["cell"]
        assert all(in_radius_one(tuple(a["end_point"])) for a in row["candidate_actions"])

    args.out.mkdir(parents=True, exist_ok=True)
    write_jsonl(args.out / "train_rows.jsonl", train_rows)
    write_jsonl(args.out / "eval_rows.jsonl", eval_rows)
    manifest = {
        "experiment": "one_hp_adjacent_zergling_counterfactual_probe",
        "hex_radius": 1,
        "marine_health": 1,
        "zergling_health": 3,
        "different_start_hexes": True,
        "adjacent_start_hexes": True,
        "directed_adjacent_layouts": len(layouts),
        "train_layouts": len(train_rows),
        "heldout_layouts": len(eval_rows),
        "train_examples": len(train_rows),
        "eval_examples": len(eval_rows),
        "target_action_keys": {"fast_move": len(layouts)},
        "min_kill_targets": 1,
        "max_kill_targets": 1,
        "label_source": "game_rule_fast_move_then_same_tile_passive_attack_damage_1",
        "explicit_action_mechanics_features": False,
    }
    (args.out / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(json.dumps(manifest, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
