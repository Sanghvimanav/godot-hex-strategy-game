extends RefCounted
class_name PureStateSelfPlaySuite
## Curated deterministic starting states and search budgets for value-model self-play.
##
## The game is still evolving, so this suite is intentionally small and versioned.
## It favors distinct tactical situations over repeated identical games. Campaign
## scenarios are excluded until pure-state rollouts understand scenario-specific
## victory conditions beyond unit elimination.

const TurnExecutionCore = preload("res://src/battle/turn_execution_core.gd")

const SUITE_VERSION := 1
const DEFAULT_MAX_ACTIONS_PER_UNIT := 8

const BUDGET_PROFILES := {
	"fast": {"own_max_plans": 2, "opponent_max_plans": 2},
	"balanced": {"own_max_plans": 4, "opponent_max_plans": 4},
	"broad": {"own_max_plans": 8, "opponent_max_plans": 8},
}


static func available_presets() -> Array[String]:
	return ["smoke", "starter"]


static func get_preset(preset_name: String) -> Array:
	match preset_name:
		"smoke":
			return [
				_make_job("collapse-fast-r0", "collapse", "fast", 0, 3),
			]
		"starter":
			# 10 deterministic but distinct jobs. Broad 8x8 search is intentionally
			# restricted to short decisive states because it is much more expensive.
			return [
				_make_job("collapse-fast-r0", "collapse", "fast", 0, 3),
				_make_job("collapse-balanced-r2", "collapse", "balanced", 2, 3),
				_make_job("collapse-broad-r4", "collapse", "broad", 4, 3),
				_make_job("baneling-finish-fast-r1", "baneling_finish", "fast", 1, 3),
				_make_job("baneling-finish-balanced-r3", "baneling_finish", "balanced", 3, 3),
				_make_job("baneling-finish-broad-r5", "baneling_finish", "broad", 5, 3),
				_make_job("marine-spread-balanced-r0", "marine_spread", "balanced", 0, 4),
				_make_job("marine-spread-balanced-r3", "marine_spread", "balanced", 3, 4),
				_make_job("mixed-force-fast-r0", "mixed_force", "fast", 0, 6),
				_make_job("mixed-force-fast-r3", "mixed_force", "fast", 3, 6),
			]
	return []


static func build_state(scenario_id: String) -> Dictionary:
	match scenario_id:
		"collapse":
			return _collapse_state()
		"baneling_finish":
			return _baneling_finish_state()
		"marine_spread":
			return _marine_spread_state()
		"mixed_force":
			return _mixed_force_state()
	return {}


static func rotate_state(state: Dictionary, rotation_steps: int) -> Dictionary:
	var rotated := state.duplicate(true)
	var steps := posmod(rotation_steps, 6)
	if steps == 0:
		return rotated
	for group_variant in rotated.get("groups", []):
		if not (group_variant is Dictionary):
			continue
		var group: Dictionary = group_variant
		for unit_variant in group.get("units", []):
			if not (unit_variant is Dictionary):
				continue
			var unit: Dictionary = unit_variant
			var cell_variant = unit.get("cell", [])
			if cell_variant is Array and (cell_variant as Array).size() >= 2:
				unit["cell"] = _rotate_cell(cell_variant as Array, steps)
	return rotated


static func _make_job(
	game_id: String,
	scenario_id: String,
	budget_profile: String,
	rotation_steps: int,
	max_turns: int
) -> Dictionary:
	var profile: Dictionary = BUDGET_PROFILES.get(budget_profile, {})
	var base_state := build_state(scenario_id)
	var state := rotate_state(base_state, rotation_steps)
	state["scenario_id"] = "training_%s" % scenario_id
	return {
		"game_id": game_id,
		"scenario_id": scenario_id,
		"budget_profile": budget_profile,
		"rotation_steps": posmod(rotation_steps, 6),
		"group_a": "terran",
		"group_b": "zerg",
		"max_turns": max_turns,
		"max_actions_per_unit": DEFAULT_MAX_ACTIONS_PER_UNIT,
		"own_max_plans": int(profile.get("own_max_plans", 1)),
		"opponent_max_plans": int(profile.get("opponent_max_plans", 1)),
		"state": state,
	}


static func _rotate_cell(cell: Array, rotation_steps: int) -> Array:
	var q := int(cell[0])
	var r := int(cell[1])
	for _i in range(rotation_steps):
		# 60-degree axial rotation around the origin.
		var next_q := -r
		var next_r := q + r
		q = next_q
		r = next_r
	return [q, r]


static func _collapse_state() -> Dictionary:
	return {
		"scenario_id": "training_collapse",
		"hex_radius": 5,
		"groups": [
			{"name": "terran", "resources": {}, "units": [
				_make_unit(1, "res://src/unit/definitions/marine.tres", Vector2i(-2, 1)),
				_make_unit(2, "res://src/unit/definitions/marine.tres", Vector2i(-2, 1)),
				_make_unit(3, "res://src/unit/definitions/marine.tres", Vector2i(-2, 1)),
			]},
			{"name": "zerg", "resources": {}, "units": [
				_make_unit(4, "res://src/unit/definitions/zergling.tres", Vector2i(-3, 2)),
				_make_unit(5, "res://src/unit/definitions/zergling.tres", Vector2i(-3, 2)),
				_make_unit(6, "res://src/unit/definitions/zergling.tres", Vector2i(-3, 2)),
				_make_unit(7, "res://src/unit/definitions/zergling.tres", Vector2i(-3, 2)),
			]},
		],
		"tile_resources": {},
	}


static func _baneling_finish_state() -> Dictionary:
	return {
		"scenario_id": "training_baneling_finish",
		"hex_radius": 5,
		"groups": [
			{"name": "terran", "resources": {}, "units": [
				_make_unit(1, "res://src/unit/definitions/marine.tres", Vector2i(0, 0), 2),
				_make_unit(2, "res://src/unit/definitions/marine.tres", Vector2i(0, 0), 2),
			]},
			{"name": "zerg", "resources": {}, "units": [
				_make_unit(3, "res://src/unit/definitions/baneling.tres", Vector2i(0, 0)),
				_make_unit(4, "res://src/unit/definitions/zergling.tres", Vector2i(4, 0)),
			]},
		],
		"tile_resources": {},
	}


static func _marine_spread_state() -> Dictionary:
	return {
		"scenario_id": "training_marine_spread",
		"hex_radius": 4,
		"groups": [
			{"name": "terran", "resources": {}, "units": [
				_make_unit(1, "res://src/unit/definitions/marine.tres", Vector2i(1, 0)),
				_make_unit(2, "res://src/unit/definitions/marine.tres", Vector2i(1, -1)),
				_make_unit(3, "res://src/unit/definitions/marine.tres", Vector2i(2, -2)),
			]},
			{"name": "zerg", "resources": {}, "units": [
				_make_unit(4, "res://src/unit/definitions/zergling.tres", Vector2i(0, 0), 1),
			]},
		],
		"tile_resources": {},
	}


static func _mixed_force_state() -> Dictionary:
	return {
		"scenario_id": "training_mixed_force",
		"hex_radius": 5,
		"groups": [
			{"name": "terran", "resources": {}, "units": [
				_make_unit(1, "res://src/unit/definitions/marine.tres", Vector2i(2, -1)),
				_make_unit(2, "res://src/unit/definitions/marine.tres", Vector2i(2, 0)),
				_make_unit(3, "res://src/unit/definitions/scout.tres", Vector2i(2, 1)),
			]},
			{"name": "zerg", "resources": {}, "units": [
				_make_unit(4, "res://src/unit/definitions/zergling.tres", Vector2i(-3, -1)),
				_make_unit(5, "res://src/unit/definitions/zergling.tres", Vector2i(-3, 0)),
				_make_unit(6, "res://src/unit/definitions/zergling.tres", Vector2i(-3, 1)),
				_make_unit(7, "res://src/unit/definitions/baneling.tres", Vector2i(-4, 0)),
			]},
		],
		"tile_resources": {},
	}


static func _make_unit(
	unit_id: int,
	def_path: String,
	cell: Vector2i,
	health_override: int = -1
) -> Dictionary:
	var def_dict := TurnExecutionCore.get_unit_def(def_path)
	var max_health := int(def_dict.get("max_health", 2))
	var max_energy := int(def_dict.get("max_energy", 0))
	var start_energy := int(def_dict.get("start_energy", max_energy))
	var health := max_health if health_override < 0 else health_override
	return {
		"unit_id": unit_id,
		"def_path": def_path,
		"cell": [cell.x, cell.y],
		"health": health,
		"max_health": max_health,
		"energy": start_energy,
		"max_energy": max_energy,
		"effects": [],
		"is_active": true,
	}
