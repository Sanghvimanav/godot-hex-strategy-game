extends RefCounted
class_name PureStateSmallArenaSuite
## Radius-one Marine-vs-Zergling training/evaluation states.
##
## The policy still sees distinct unit entities and the spatial board. This suite only
## controls the starting distribution: overwhelmingly 3v3, with small neighboring
## count variants and seeded formation jitter on the seven-cell radius-one board.

const PureStateSelfPlaySuite = preload("res://src/simulation/pure_state_self_play_suite.gd")

const MARINE_PATH := "res://src/unit/definitions/marine.tres"
const ZERGLING_PATH := "res://src/unit/definitions/zergling.tres"
const DEFAULT_MAX_TURNS := 8

const _BOARD_CELLS := [
    Vector2i(0, 0),
    Vector2i(1, 0),
    Vector2i(1, -1),
    Vector2i(0, -1),
    Vector2i(-1, 0),
    Vector2i(-1, 1),
    Vector2i(0, 1),
]

const _MARINE_HOME := [
    Vector2i(1, 0),
    Vector2i(1, -1),
    Vector2i(0, -1),
]

const _ZERG_HOME := [
    Vector2i(-1, 0),
    Vector2i(-1, 1),
    Vector2i(0, 1),
]


static func matchup_for_seed(seed: int) -> Dictionary:
    # Exact 20-state mix: 80% 3v3, 10% 2v2, 5% 3v2, 5% 2v3.
    var bucket := posmod(seed, 20)
    if bucket < 16:
        return {"id": "3v3", "marines": 3, "zerglings": 3}
    if bucket < 18:
        return {"id": "2v2", "marines": 2, "zerglings": 2}
    if bucket == 18:
        return {"id": "3v2", "marines": 3, "zerglings": 2}
    return {"id": "2v3", "marines": 2, "zerglings": 3}


static func build_state(seed: int, max_turns: int = DEFAULT_MAX_TURNS) -> Dictionary:
    var matchup := matchup_for_seed(seed)
    var marines := int(matchup["marines"])
    var zerglings := int(matchup["zerglings"])
    var state := PureStateSelfPlaySuite.basic_state(
        marines,
        zerglings,
        0,
        max_turns,
        "",
        false
    )
    state["scenario_id"] = "small_arena_%s" % str(matchup["id"])
    state["turn_index"] = 0

    var rng := RandomNumberGenerator.new()
    rng.seed = seed

    var marine_cells := _MARINE_HOME.duplicate()
    var zerg_cells := _ZERG_HOME.duplicate()
    marine_cells.shuffle()
    zerg_cells.shuffle()
    _set_group_cells(state, 0, marine_cells.slice(0, marines))
    _set_group_cells(state, 1, zerg_cells.slice(0, zerglings))

    # A few legal one-hex moves create nearby formations rather than unrelated
    # random boards. On 3v3 there is one empty hex, so each jitter step slides
    # one unit into the vacancy and changes the local formation.
    var jitter_steps := 1 + rng.randi_range(0, 3)
    _jitter_positions(state, rng, jitter_steps)

    var rotation := rng.randi_range(0, 5)
    state = PureStateSelfPlaySuite.rotate_state(state, rotation)
    state["small_arena"] = {
        "seed": seed,
        "matchup": str(matchup["id"]),
        "rotation_steps": rotation,
        "jitter_steps": jitter_steps,
        "distribution": "80pct_3v3_10pct_2v2_5pct_3v2_5pct_2v3",
    }
    return state


static func layout_signature(state: Dictionary) -> String:
    var parts: Array[String] = []
    for group_variant in state.get("groups", []):
        if not (group_variant is Dictionary):
            continue
        var group: Dictionary = group_variant
        var cells: Array[String] = []
        for unit_variant in group.get("units", []):
            if not (unit_variant is Dictionary):
                continue
            var cell: Array = (unit_variant as Dictionary).get("cell", [])
            if cell.size() >= 2:
                cells.append("%d,%d" % [int(cell[0]), int(cell[1])])
        cells.sort()
        parts.append("%s:%s" % [str(group.get("name", "")), ";".join(cells)])
    return "|".join(parts)


static func _set_group_cells(state: Dictionary, group_index: int, cells: Array) -> void:
    var groups: Array = state.get("groups", [])
    if group_index < 0 or group_index >= groups.size():
        return
    var group: Dictionary = groups[group_index]
    var units: Array = group.get("units", [])
    for i in range(mini(units.size(), cells.size())):
        var cell: Vector2i = cells[i]
        (units[i] as Dictionary)["cell"] = [cell.x, cell.y]


static func _jitter_positions(state: Dictionary, rng: RandomNumberGenerator, steps: int) -> void:
    var groups: Array = state.get("groups", [])
    for _step in range(steps):
        var occupied := _occupied_cells(state)
        var movable: Array = []
        for group_index in range(groups.size()):
            var group: Dictionary = groups[group_index]
            var units: Array = group.get("units", [])
            for unit_index in range(units.size()):
                var unit: Dictionary = units[unit_index]
                var from := _vec(unit.get("cell", [0, 0]))
                var candidates: Array[Vector2i] = []
                for candidate in _BOARD_CELLS:
                    var key := _key(candidate)
                    if occupied.has(key):
                        continue
                    if _hex_distance(from, candidate) <= 1:
                        candidates.append(candidate)
                if not candidates.is_empty():
                    movable.append({
                        "group_index": group_index,
                        "unit_index": unit_index,
                        "candidates": candidates,
                    })
        if movable.is_empty():
            return
        var choice: Dictionary = movable[rng.randi_range(0, movable.size() - 1)]
        var candidates: Array = choice["candidates"]
        var target: Vector2i = candidates[rng.randi_range(0, candidates.size() - 1)]
        var group: Dictionary = groups[int(choice["group_index"])]
        var units: Array = group.get("units", [])
        (units[int(choice["unit_index"])] as Dictionary)["cell"] = [target.x, target.y]


static func _occupied_cells(state: Dictionary) -> Dictionary:
    var result := {}
    for group_variant in state.get("groups", []):
        if not (group_variant is Dictionary):
            continue
        for unit_variant in (group_variant as Dictionary).get("units", []):
            if unit_variant is Dictionary:
                result[_key(_vec((unit_variant as Dictionary).get("cell", [0, 0])))] = true
    return result


static func _vec(value: Variant) -> Vector2i:
    if value is Array and (value as Array).size() >= 2:
        return Vector2i(int(value[0]), int(value[1]))
    return Vector2i.ZERO


static func _key(cell: Vector2i) -> String:
    return "%d,%d" % [cell.x, cell.y]


static func _hex_distance(a: Vector2i, b: Vector2i) -> int:
    var dq := a.x - b.x
    var dr := a.y - b.y
    var ds := (-a.x - a.y) - (-b.x - b.y)
    return maxi(abs(dq), maxi(abs(dr), abs(ds)))
