extends Node
## Counterfactual capacity probe:
## one radius-one Zergling starts adjacent to a distinct 1-HP Marine.
## Labels come only from simulator outcomes for every legal Zergling action.

const PureStateLegalActions = preload("res://src/simulation/pure_state_legal_actions.gd")
const PureStateSelfPlaySuite = preload("res://src/simulation/pure_state_self_play_suite.gd")
const PureStateSimulator = preload("res://src/simulation/pure_state_simulator.gd")

const BOARD_CELLS := [
    Vector2i(0, 0),
    Vector2i(1, 0),
    Vector2i(1, -1),
    Vector2i(0, -1),
    Vector2i(-1, 0),
    Vector2i(-1, 1),
    Vector2i(0, 1),
]


func _ready() -> void:
    call_deferred("_run")


func _run() -> void:
    var args := _parse_cmdline_kv()
    var out_dir := str(args.get("out", "user://one_hp_zergling_probe"))
    var train_examples := maxi(1, int(args.get("train-examples", "4800")))
    var eval_examples := maxi(1, int(args.get("eval-examples", "1200")))

    var layouts := _directed_adjacent_layouts()
    var train_layouts: Array = []
    var eval_layouts: Array = []
    for i in range(layouts.size()):
        if i % 4 == 0:
            eval_layouts.append(layouts[i])
        else:
            train_layouts.append(layouts[i])

    if layouts.size() != 24 or train_layouts.size() != 18 or eval_layouts.size() != 6:
        push_error("Expected 24 directed adjacent layouts split 18/6, got %d %d/%d" % [
            layouts.size(), train_layouts.size(), eval_layouts.size()
        ])
        get_tree().quit(1)
        return

    var train_rows := _build_rows(train_layouts, train_examples, "train")
    var eval_rows := _build_rows(eval_layouts, eval_examples, "eval")
    if train_rows.size() != train_examples or eval_rows.size() != eval_examples:
        push_error("Unable to generate requested probe examples")
        get_tree().quit(1)
        return

    var all_rows: Array = []
    all_rows.append_array(train_rows)
    all_rows.append_array(eval_rows)

    var target_keys := {}
    var candidate_counts: Array[int] = []
    var target_counts: Array[int] = []
    for row_variant in all_rows:
        var row: Dictionary = row_variant
        var candidates: Array = row.get("candidate_actions", [])
        var targets: Array = row.get("target_indices", [])
        candidate_counts.append(candidates.size())
        target_counts.append(targets.size())
        for target_variant in targets:
            var target := int(target_variant)
            if target >= 0 and target < candidates.size():
                var key := str((candidates[target] as Dictionary).get("action_key", ""))
                target_keys[key] = int(target_keys.get(key, 0)) + 1

    var manifest := {
        "experiment": "one_hp_adjacent_zergling_counterfactual_probe",
        "hex_radius": 1,
        "marine_health": 1,
        "zergling_health": 3,
        "different_start_hexes": true,
        "adjacent_start_hexes": true,
        "train_examples": train_rows.size(),
        "eval_examples": eval_rows.size(),
        "directed_adjacent_layouts": layouts.size(),
        "train_layouts": train_layouts.size(),
        "heldout_layouts": eval_layouts.size(),
        "target_action_keys": target_keys,
        "min_candidates": candidate_counts.min(),
        "max_candidates": candidate_counts.max(),
        "min_kill_targets": target_counts.min(),
        "max_kill_targets": target_counts.max(),
        "label_source": "simulate_every_legal_zergling_action_with_marine_holding",
        "explicit_action_mechanics_features": false,
    }

    var abs_out := ProjectSettings.globalize_path(out_dir)
    if DirAccess.make_dir_recursive_absolute(abs_out) != OK:
        push_error("Unable to create output directory: " + abs_out)
        get_tree().quit(1)
        return

    var ok := _write_json(out_dir.path_join("manifest.json"), manifest)
    ok = _write_jsonl(out_dir.path_join("train_rows.jsonl"), train_rows) and ok
    ok = _write_jsonl(out_dir.path_join("eval_rows.jsonl"), eval_rows) and ok
    print(JSON.stringify(manifest, "  "))
    get_tree().quit(0 if ok else 1)


func _build_rows(layouts: Array, count: int, split: String) -> Array:
    var rows: Array = []
    for i in range(count):
        var layout: Dictionary = layouts[i % layouts.size()]
        var marine_cell: Vector2i = layout["marine"]
        var zerg_cell: Vector2i = layout["zerg"]
        var state := PureStateSelfPlaySuite.basic_state(1, 1, 0, 1, "", false)
        state["scenario_id"] = "probe_one_hp_adjacent"
        state["turn_index"] = 0
        var groups: Array = state.get("groups", [])
        var marine: Dictionary = ((groups[0] as Dictionary).get("units", []) as Array)[0]
        var zergling: Dictionary = ((groups[1] as Dictionary).get("units", []) as Array)[0]
        marine["health"] = 1
        marine["max_health"] = 4
        marine["cell"] = [marine_cell.x, marine_cell.y]
        zergling["health"] = 3
        zergling["max_health"] = 3
        zergling["cell"] = [zerg_cell.x, zerg_cell.y]

        if _hex_distance(marine_cell, zerg_cell) != 1 or marine_cell == zerg_cell:
            push_error("Probe layout is not adjacent/distinct")
            return []

        var candidates := _planning_actions(state, zergling)
        if candidates.size() < 2:
            push_error("Probe state has fewer than two legal candidates")
            return []

        var target_indices: Array[int] = []
        for candidate_index in range(candidates.size()):
            var action: Dictionary = (candidates[candidate_index] as Dictionary).duplicate(true)
            var sim := PureStateSimulator.simulate_turn(
                state,
                {
                    "terran": [],
                    "zerg": [] if str(action.get("action_key", "")) == "<hold>" else [action],
                }
            )
            var next_state: Dictionary = sim.get("next_state", {})
            if not _marine_alive(next_state):
                target_indices.append(candidate_index)

        if target_indices.is_empty():
            push_error("No legal Zergling action kills the adjacent 1-HP Marine: %s -> %s" % [
                str(zerg_cell), str(marine_cell)
            ])
            return []

        var layout_id := "%d,%d_to_%d,%d" % [
            zerg_cell.x, zerg_cell.y, marine_cell.x, marine_cell.y
        ]
        rows.append({
            "game_id": "%s-%s-%d" % [split, layout_id, i],
            "split": split,
            "layout_id": layout_id,
            "state": state.duplicate(true),
            "perspective_group": "zerg",
            "opponent_group": "terran",
            "prefix_actions": [],
            "candidate_actions": candidates,
            "target_indices": target_indices,
            "selected_index": int(target_indices[0]),
            "marine_cell": [marine_cell.x, marine_cell.y],
            "zergling_cell": [zerg_cell.x, zerg_cell.y],
        })
    return rows


func _planning_actions(state: Dictionary, unit: Dictionary) -> Array:
    var seen := {}
    var actions: Array = []
    for action_variant in PureStateLegalActions.get_legal_actions(state, int(unit.get("unit_id", -1))):
        if not (action_variant is Dictionary):
            continue
        var action: Dictionary = (action_variant as Dictionary).duplicate(true)
        var signature := _signature(action)
        if seen.has(signature):
            continue
        seen[signature] = true
        actions.append(action)

    var cell: Array = unit.get("cell", [0, 0])
    var hold := {
        "unit_id": int(unit.get("unit_id", -1)),
        "action_key": "<hold>",
        "path": [],
        "end_point": cell.duplicate(),
    }
    if not seen.has(_signature(hold)):
        actions.append(hold)
    actions.sort_custom(func(a, b): return _signature(a) < _signature(b))
    return actions


func _directed_adjacent_layouts() -> Array:
    var result: Array = []
    for zerg_cell in BOARD_CELLS:
        for marine_cell in BOARD_CELLS:
            if zerg_cell == marine_cell:
                continue
            if _hex_distance(zerg_cell, marine_cell) == 1:
                result.append({
                    "zerg": zerg_cell,
                    "marine": marine_cell,
                })
    result.sort_custom(func(a, b):
        var az: Vector2i = a["zerg"]
        var am: Vector2i = a["marine"]
        var bz: Vector2i = b["zerg"]
        var bm: Vector2i = b["marine"]
        return "%d,%d|%d,%d" % [az.x, az.y, am.x, am.y] < "%d,%d|%d,%d" % [bz.x, bz.y, bm.x, bm.y]
    )
    return result


func _marine_alive(state: Dictionary) -> bool:
    for group_variant in state.get("groups", []):
        if not (group_variant is Dictionary):
            continue
        var group: Dictionary = group_variant
        if str(group.get("name", "")) != "terran":
            continue
        for unit_variant in group.get("units", []):
            if unit_variant is Dictionary:
                return int((unit_variant as Dictionary).get("health", 0)) > 0
    return false


func _signature(action: Dictionary) -> String:
    return "%d|%s|%s|%s" % [
        int(action.get("unit_id", -1)),
        str(action.get("action_key", "")),
        str(action.get("end_point", [])),
        str(action.get("path", [])),
    ]


func _hex_distance(a: Vector2i, b: Vector2i) -> int:
    var dq := a.x - b.x
    var dr := a.y - b.y
    var ds := (-a.x - a.y) - (-b.x - b.y)
    return maxi(abs(dq), maxi(abs(dr), abs(ds)))


func _write_json(path: String, value: Variant) -> bool:
    var file := FileAccess.open(path, FileAccess.WRITE)
    if file == null:
        return false
    file.store_string(JSON.stringify(value, "  ") + "\n")
    file.close()
    return true


func _write_jsonl(path: String, rows: Array) -> bool:
    var file := FileAccess.open(path, FileAccess.WRITE)
    if file == null:
        return false
    for row_variant in rows:
        if row_variant is Dictionary:
            file.store_line(JSON.stringify(row_variant))
    file.close()
    return true


func _parse_cmdline_kv() -> Dictionary:
    var result := {}
    var raw := OS.get_cmdline_user_args()
    if raw.is_empty():
        raw = OS.get_cmdline_args()
    var i := 0
    while i < raw.size():
        var arg := str(raw[i]).strip_edges()
        if arg.begins_with("--"):
            arg = arg.substr(2)
        if arg.contains("="):
            var parts := arg.split("=", true, 1)
            result[parts[0]] = parts[1]
        elif not arg.is_empty():
            var next_value := ""
            if i + 1 < raw.size() and not str(raw[i + 1]).begins_with("-"):
                next_value = str(raw[i + 1]).strip_edges()
                i += 1
            result[arg] = next_value if not next_value.is_empty() else "true"
        i += 1
    return result
