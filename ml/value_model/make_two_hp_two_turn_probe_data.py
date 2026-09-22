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


def make_state(
    zerg: tuple[int, int],
    marine: tuple[int, int],
    marine_health: int,
    zerg_health: int,
    turn_index: int,
) -> dict[str, Any]:
    return {
        "scenario_id": "probe_two_hp_two_turn",
        "hex_radius": 1,
        "command_hexes_enabled": False,
        "tile_resources": {},
        "turn_index": turn_index,
        "curriculum": {"max_turns": 2, "turn_limit_winner": ""},
        "groups": [
            {
                "name": "terran",
                "resources": {},
                "units": [unit(1, MARINE_PATH, marine, marine_health, 4)],
            },
            {
                "name": "zerg",
                "resources": {},
                "units": [unit(2, ZERGLING_PATH, zerg, zerg_health, 3)],
            },
        ],
    }


def signature(action: dict[str, Any]) -> str:
    return f"{int(action['unit_id'])}|{action['action_key']}|{action['end_point']}|{action['path']}"


def zerg_candidates(zerg: tuple[int, int]) -> list[dict[str, Any]]:
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


def marine_responses(marine: tuple[int, int]) -> list[dict[str, Any]]:
    responses: list[dict[str, Any]] = [
        {
            "unit_id": 1,
            "action_key": "<hold>",
            "path": [],
            "end_point": [marine[0], marine[1]],
        }
    ]
    for target in BOARD_CELLS:
        if hex_distance(marine, target) != 1:
            continue
        responses.append(
            {
                "unit_id": 1,
                "action_key": "move_short",
                "path": [[target[0], target[1]]],
                "end_point": [target[0], target[1]],
            }
        )
    responses.sort(key=signature)
    return responses


def initial_row(
    zerg: tuple[int, int],
    marine: tuple[int, int],
    split: str,
    layout_id: str,
) -> dict[str, Any]:
    candidates = zerg_candidates(zerg)
    targets = [
        i
        for i, action in enumerate(candidates)
        if action["action_key"] == "fast_move"
        and action["end_point"] == [marine[0], marine[1]]
    ]
    if len(targets) != 1:
        raise ValueError(f"expected one robust opening action, got {targets}")
    return {
        "game_id": f"{split}-{layout_id}-t0",
        "split": split,
        "initial_layout_id": layout_id,
        "decision_id": f"{layout_id}-t0",
        "turn_index": 0,
        "state": make_state(zerg, marine, marine_health=2, zerg_health=3, turn_index=0),
        "perspective_group": "zerg",
        "opponent_group": "terran",
        "prefix_actions": [],
        "candidate_actions": candidates,
        "target_indices": targets,
        "selected_index": targets[0],
        "decision_role": "opening",
        "marine_response": None,
    }


def continuation_row(
    initial_zerg: tuple[int, int],
    initial_marine: tuple[int, int],
    response: dict[str, Any],
    split: str,
    layout_id: str,
    response_index: int,
) -> dict[str, Any]:
    # Turn 1 robust opening: Zerg fast-moves onto the Marine's starting cell and
    # its same-tile fast passive attack reduces Marine 2 -> 1 before Marine's
    # normal move. If Marine holds, its normal passive later hits the Zergling
    # once (3 -> 2). If Marine moves, the units end separated and Zerg stays at 3.
    zerg_after = initial_marine
    if response["action_key"] == "<hold>":
        marine_after = initial_marine
        zerg_health = 2
    else:
        marine_after = tuple(response["end_point"])
        zerg_health = 3

    state = make_state(
        zerg_after,
        marine_after,
        marine_health=1,
        zerg_health=zerg_health,
        turn_index=1,
    )
    candidates = zerg_candidates(zerg_after)

    if zerg_after == marine_after:
        # They already share the tile. The automatic fast passive attack fires
        # before reload/hold or the Marine's normal move, so either non-move wins.
        targets = [
            i
            for i, action in enumerate(candidates)
            if action["action_key"] in {"reload", "<hold>"}
        ]
    else:
        if hex_distance(zerg_after, marine_after) != 1:
            raise ValueError("Marine one-hex response must remain adjacent to Zerg at old Marine cell")
        targets = [
            i
            for i, action in enumerate(candidates)
            if action["action_key"] == "fast_move"
            and action["end_point"] == [marine_after[0], marine_after[1]]
        ]

    if not targets:
        raise ValueError("continuation has no two-turn kill action")

    return {
        "game_id": f"{split}-{layout_id}-t1-r{response_index}",
        "split": split,
        "initial_layout_id": layout_id,
        "decision_id": f"{layout_id}-t1-r{response_index}",
        "turn_index": 1,
        "state": state,
        "perspective_group": "zerg",
        "opponent_group": "terran",
        "prefix_actions": [
            {
                "unit_id": 2,
                "action_key": "fast_move",
                "path": [[initial_marine[0], initial_marine[1]]],
                "end_point": [initial_marine[0], initial_marine[1]],
            }
        ],
        "candidate_actions": candidates,
        "target_indices": targets,
        "selected_index": targets[0],
        "decision_role": "continuation",
        "marine_response": response,
    }


def build_layout_rows(
    zerg: tuple[int, int],
    marine: tuple[int, int],
    split: str,
) -> list[dict[str, Any]]:
    if zerg == marine or hex_distance(zerg, marine) != 1:
        raise ValueError("initial units must be adjacent and on different hexes")
    layout_id = f"{zerg[0]},{zerg[1]}_to_{marine[0]},{marine[1]}"
    rows = [initial_row(zerg, marine, split, layout_id)]
    for i, response in enumerate(marine_responses(marine)):
        rows.append(continuation_row(zerg, marine, response, split, layout_id, i))
    return rows


def write_jsonl(path: Path, rows: list[dict[str, Any]]) -> None:
    path.write_text("".join(json.dumps(row, sort_keys=True) + "\n" for row in rows))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()

    layouts = sorted(
        [
            (zerg, marine)
            for zerg in BOARD_CELLS
            for marine in BOARD_CELLS
            if zerg != marine and hex_distance(zerg, marine) == 1
        ]
    )
    if len(layouts) != 24:
        raise ValueError(f"expected 24 directed adjacent layouts, got {len(layouts)}")

    train_rows: list[dict[str, Any]] = []
    eval_rows: list[dict[str, Any]] = []
    train_layouts: list[str] = []
    eval_layouts: list[str] = []

    for i, (zerg, marine) in enumerate(layouts):
        split = "eval" if i % 4 == 0 else "train"
        layout_id = f"{zerg[0]},{zerg[1]}_to_{marine[0]},{marine[1]}"
        rows = build_layout_rows(zerg, marine, split)
        if split == "eval":
            eval_rows.extend(rows)
            eval_layouts.append(layout_id)
        else:
            train_rows.extend(rows)
            train_layouts.append(layout_id)

    if len(train_layouts) != 18 or len(eval_layouts) != 6:
        raise ValueError(f"expected 18/6 layout split, got {len(train_layouts)}/{len(eval_layouts)}")

    for row in train_rows + eval_rows:
        state = row["state"]
        groups = {g["name"]: g for g in state["groups"]}
        marine = groups["terran"]["units"][0]
        zerg = groups["zerg"]["units"][0]
        assert state["hex_radius"] == 1
        assert marine["health"] in {1, 2}
        assert zerg["health"] in {2, 3}
        assert row["target_indices"]

    args.out.mkdir(parents=True, exist_ok=True)
    write_jsonl(args.out / "train_rows.jsonl", train_rows)
    write_jsonl(args.out / "eval_rows.jsonl", eval_rows)

    manifest = {
        "experiment": "two_hp_two_turn_zergling_probe",
        "hex_radius": 1,
        "initial_marine_health": 2,
        "initial_zergling_health": 3,
        "initial_adjacent": True,
        "initial_different_hexes": True,
        "marine_allowed_actions": ["<hold>", "move_short"],
        "marine_attack_short_excluded": True,
        "turn_limit": 2,
        "directed_initial_layouts": len(layouts),
        "train_initial_layouts": len(train_layouts),
        "heldout_initial_layouts": len(eval_layouts),
        "train_decision_rows": len(train_rows),
        "eval_decision_rows": len(eval_rows),
        "opening_target": "fast_move_to_initial_marine_hex",
        "continuation_targets": "kill_before_marine_normal_move_on_turn_2",
        "robust_requirement": "opening and continuation must succeed for every legal Marine hold/move response",
        "explicit_action_mechanics_features": False,
    }
    (args.out / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(json.dumps(manifest, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
