extends RefCounted
class_name PureStateSmallArenaSelfPlaySuiteV5

const PureStateSelfPlaySuite = preload("res://src/simulation/pure_state_self_play_suite.gd")
const DEFAULT_MAX_TURNS := 10

const _BOARD_CELLS := [
    Vector2i(0, 0), Vector2i(1, 0), Vector2i(1, -1), Vector2i(0, -1),
    Vector2i(-1, 0), Vector2i(-1, 1), Vector2i(0, 1),
]
const _MARINE_HOME := [Vector2i(1, 0), Vector2i(1, -1), Vector2i(0, -1)]
const _ZERG_HOME := [Vector2i(-1, 0), Vector2i(-1, 1), Vector2i(0, 1), Vector2i(0, 0)]

static func matchup_for_seed(seed: int) -> Dictionary:
    var bucket := posmod(seed, 12)
    var marines := 1 + posmod(bucket, 3)
    var zerglings := 1 + int(bucket / 3)
    return {"id": "%dv%d" % [marines, zerglings], "marines": marines, "zerglings": zerglings}

static func build_state(seed: int, max_turns: int = DEFAULT_MAX_TURNS) -> Dictionary:
    var matchup := matchup_for_seed(seed)
    var marines := int(matchup["marines"])
    var zerglings := int(matchup["zerglings"])
    var state := PureStateSelfPlaySuite.basic_state(marines, zerglings, 0, max_turns, "", false)
    state["scenario_id"] = "small_selfplay_v5_%s" % str(matchup["id"])
    state["turn_index"] = 0

    var rng := RandomNumberGenerator.new()
    rng.seed = seed
    var marine_cells := _MARINE_HOME.duplicate()
    var zerg_cells := _ZERG_HOME.duplicate()
    _shuffle_cells(marine_cells, rng)
    _shuffle_cells(zerg_cells, rng)
    _set_group_cells(state, 0, marine_cells.slice(0, marines))
    _set_group_cells(state, 1, zerg_cells.slice(0, zerglings))

    var jitter_steps := 1 + rng.randi_range(0, 3)
    _jitter_positions(state, rng, jitter_steps)
    var rotation := rng.randi_range(0, 5)
    state = PureStateSelfPlaySuite.rotate_state(state, rotation)
    state["small_arena"] = {
        "seed": seed,
        "matchup": str(matchup["id"]),
        "rotation_steps": rotation,
        "jitter_steps": jitter_steps,
        "distribution": "uniform_1to3_marines_vs_1to4_zerglings",
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

static func _shuffle_cells(cells: Array, rng: RandomNumberGenerator) -> void:
    for i in range(cells.size() - 1, 0, -1):
        var j := rng.randi_range(0, i)
        var tmp = cells[i]
        cells[i] = cells[j]
        cells[j] = tmp

static func _set_group_cells(state: Dictionary, group_index: int, cells: Array) -> void:
    var groups: Array = state.get("groups", [])
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
        for gi in range(groups.size()):
            var units: Array = (groups[gi] as Dictionary).get("units", [])
            for ui in range(units.size()):
                var from := _vec((units[ui] as Dictionary).get("cell", [0, 0]))
                var candidates: Array[Vector2i] = []
                for candidate in _BOARD_CELLS:
                    if occupied.has(_key(candidate)):
                        continue
                    if _hex_distance(from, candidate) <= 1:
                        candidates.append(candidate)
                if not candidates.is_empty():
                    movable.append({"group_index": gi, "unit_index": ui, "candidates": candidates})
        if movable.is_empty():
            return
        var choice: Dictionary = movable[rng.randi_range(0, movable.size() - 1)]
        var candidates: Array = choice["candidates"]
        var target: Vector2i = candidates[rng.randi_range(0, candidates.size() - 1)]
        var units: Array = (groups[int(choice["group_index"])] as Dictionary).get("units", [])
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
