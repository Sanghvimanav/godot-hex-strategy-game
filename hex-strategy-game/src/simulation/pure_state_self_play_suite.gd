extends RefCounted
class_name PureStateSelfPlaySuite
## Curated deterministic starting states and search budgets for value-model self-play.
##
## The game is still evolving, so this suite is versioned and disposable. It favors
## distinct tactical situations over repeated identical games. Campaign scenarios
## remain excluded until pure-state rollouts understand objective-specific victories.

const TurnExecutionCore = preload("res://src/battle/turn_execution_core.gd")

const SUITE_VERSION := 4
const DEFAULT_MAX_ACTIONS_PER_UNIT := 8

const BUDGET_PROFILES := {
	"fast": {"own_max_plans": 2, "opponent_max_plans": 2},
	"balanced": {"own_max_plans": 4, "opponent_max_plans": 4},
	"broad": {"own_max_plans": 8, "opponent_max_plans": 8},
}

const _VARIATION_OFFSETS := [
	Vector2i(0, 0),
	Vector2i(1, 0),
	Vector2i(0, 1),
	Vector2i(-1, 1),
	Vector2i(-1, 0),
	Vector2i(0, -1),
	Vector2i(1, -1),
]


static func available_presets() -> Array[String]:
	return ["smoke", "starter", "diverse"]


static func get_preset(preset_name: String) -> Array:
	match preset_name:
		"smoke":
			return [
				_make_job("collapse-fast-r0", "collapse", "fast", 0, 3),
			]
		"starter":
			# Original 10-job benchmark retained as a stable historical comparison.
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
		"diverse":
			# Keep the original benchmark families, then add mechanics and formation
			# diversity. New jobs use deterministic variation seeds that perturb unit
			# position by at most one hex and vary HP/energy/resources while remaining
			# reproducible for the same suite/rules commit.
			var jobs: Array = get_preset("starter")
			jobs.append_array([
				_make_varied_job("hydra-crossfire-fast-s11", "hydra_crossfire", "fast", 1, 8, 11),
				_make_varied_job("hydra-crossfire-balanced-s12", "hydra_crossfire", "balanced", 3, 8, 12),
				_make_varied_job("hydra-crossfire-balanced-s13", "hydra_crossfire", "balanced", 5, 8, 13),
				_make_varied_job("medic-hold-fast-s21", "medic_hold", "fast", 0, 8, 21),
				_make_varied_job("medic-hold-balanced-s22", "medic_hold", "balanced", 2, 8, 22),
				_make_varied_job("medic-hold-balanced-s23", "medic_hold", "balanced", 4, 8, 23),
				_make_varied_job("scout-kite-fast-s31", "scout_kite", "fast", 1, 8, 31),
				_make_varied_job("scout-kite-balanced-s32", "scout_kite", "balanced", 4, 8, 32),
				_make_varied_job("worker-screen-fast-s41", "worker_screen", "fast", 2, 8, 41),
				_make_varied_job("worker-screen-balanced-s42", "worker_screen", "balanced", 5, 8, 42),
				_make_varied_job("baneling-flank-fast-s51", "baneling_flank", "fast", 0, 7, 51),
				_make_varied_job("baneling-flank-balanced-s52", "baneling_flank", "balanced", 3, 7, 52),
				_make_varied_job("attrition-fast-s61", "attrition", "fast", 1, 9, 61),
				_make_varied_job("attrition-balanced-s62", "attrition", "balanced", 4, 9, 62),
				# The town stays at the rotation-invariant origin. These intentionally
				# run longer so delay, repeated consumption, and spawning can affect
				# the elimination result instead of being cut off as a short skirmish.
				_make_job("fester-siege-fast-r0", "fester_siege", "fast", 0, 14),
				_make_job("fester-siege-balanced-r3", "fester_siege", "balanced", 3, 14),
			])
			return jobs
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
		"hydra_crossfire":
			return _hydra_crossfire_state()
		"medic_hold":
			return _medic_hold_state()
		"scout_kite":
			return _scout_kite_state()
		"worker_screen":
			return _worker_screen_state()
		"baneling_flank":
			return _baneling_flank_state()
		"attrition":
			return _attrition_state()
		"fester_siege":
			return _fester_siege_state()
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


static func vary_state(state: Dictionary, variation_seed: int) -> Dictionary:
	var varied := state.duplicate(true)
	if variation_seed == 0:
		return varied
	var radius := int(varied.get("hex_radius", 5))
	var rng := RandomNumberGenerator.new()
	rng.seed = variation_seed
	for group_variant in varied.get("groups", []):
		if not (group_variant is Dictionary):
			continue
		var group: Dictionary = group_variant
		var resources_variant = group.get("resources", {})
		if resources_variant is Dictionary:
			var resources: Dictionary = resources_variant
			for resource_key in resources.keys():
				var value = resources.get(resource_key, 0)
				if value is int or value is float:
					resources[resource_key] = max(0, int(value) + rng.randi_range(-1, 2))
		for unit_variant in group.get("units", []):
			if not (unit_variant is Dictionary):
				continue
			var unit: Dictionary = unit_variant
			var health := int(unit.get("health", 1))
			if health > 1 and rng.randf() < 0.65:
				health -= rng.randi_range(0, min(2, health - 1))
				unit["health"] = max(1, health)
			var energy := int(unit.get("energy", 0))
			if energy > 0 and rng.randf() < 0.70:
				energy -= rng.randi_range(0, min(2, energy))
				unit["energy"] = max(0, energy)
			var cell_variant = unit.get("cell", [])
			if cell_variant is Array and (cell_variant as Array).size() >= 2 and rng.randf() < 0.75:
				var cell := Vector2i(int(cell_variant[0]), int(cell_variant[1]))
				var offset: Vector2i = _VARIATION_OFFSETS[rng.randi_range(0, _VARIATION_OFFSETS.size() - 1)]
				var candidate := cell + offset
				if _in_hex(candidate, radius):
					unit["cell"] = [candidate.x, candidate.y]
	return varied


static func _make_job(
	game_id: String,
	scenario_id: String,
	budget_profile: String,
	rotation_steps: int,
	max_turns: int
) -> Dictionary:
	return _make_varied_job(game_id, scenario_id, budget_profile, rotation_steps, max_turns, 0)


static func _make_varied_job(
	game_id: String,
	scenario_id: String,
	budget_profile: String,
	rotation_steps: int,
	max_turns: int,
	variation_seed: int
) -> Dictionary:
	var profile: Dictionary = BUDGET_PROFILES.get(budget_profile, {})
	var base_state := build_state(scenario_id)
	var varied_state := vary_state(base_state, variation_seed)
	var state := rotate_state(varied_state, rotation_steps)
	state["scenario_id"] = "training_%s" % scenario_id
	return {
		"game_id": game_id,
		"scenario_id": scenario_id,
		"budget_profile": budget_profile,
		"rotation_steps": posmod(rotation_steps, 6),
		"variation_seed": variation_seed,
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
		var next_q := -r
		var next_r := q + r
		q = next_q
		r = next_r
	return [q, r]


static func _in_hex(cell: Vector2i, radius: int) -> bool:
	var s := -cell.x - cell.y
	return max(abs(cell.x), max(abs(cell.y), abs(s))) <= radius


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
				# Two Marine/Scout stacks create a coordinated interception puzzle:
				# Marines can cover the three q=0 cells while Scouts reach the
				# two distance-two escape cells on the left.
				_make_unit(1, "res://src/unit/definitions/marine.tres", Vector2i(1, 0)),
				_make_unit(2, "res://src/unit/definitions/marine.tres", Vector2i(1, -1)),
				_make_unit(5, "res://src/unit/definitions/scout.tres", Vector2i(1, 0)),
				_make_unit(6, "res://src/unit/definitions/scout.tres", Vector2i(1, -1)),
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


static func _hydra_crossfire_state() -> Dictionary:
	return {
		"scenario_id": "training_hydra_crossfire",
		"hex_radius": 5,
		"groups": [
			{"name": "terran", "resources": {}, "units": [
				_make_unit(1, "res://src/unit/definitions/marine.tres", Vector2i(2, -1)),
				_make_unit(2, "res://src/unit/definitions/marine.tres", Vector2i(2, 0)),
				_make_unit(3, "res://src/unit/definitions/scout.tres", Vector2i(1, 1)),
			]},
			{"name": "zerg", "resources": {}, "units": [
				_make_unit(4, "res://src/unit/definitions/hydralisk.tres", Vector2i(-2, 0)),
				_make_unit(5, "res://src/unit/definitions/hydralisk.tres", Vector2i(-2, 1)),
				_make_unit(6, "res://src/unit/definitions/zergling.tres", Vector2i(-1, -1)),
			]},
		],
		"tile_resources": {},
	}


static func _medic_hold_state() -> Dictionary:
	return {
		"scenario_id": "training_medic_hold",
		"hex_radius": 5,
		"groups": [
			{"name": "terran", "resources": {}, "units": [
				_make_unit(1, "res://src/unit/definitions/marine.tres", Vector2i(1, 0), 1),
				_make_unit(2, "res://src/unit/definitions/marine.tres", Vector2i(1, -1), 2),
				_make_unit(3, "res://src/unit/definitions/medic.tres", Vector2i(2, -1)),
				_make_unit(4, "res://src/unit/definitions/scout.tres", Vector2i(2, 0)),
			]},
			{"name": "zerg", "resources": {}, "units": [
				_make_unit(5, "res://src/unit/definitions/zergling.tres", Vector2i(-2, 0)),
				_make_unit(6, "res://src/unit/definitions/zergling.tres", Vector2i(-2, 1)),
				_make_unit(7, "res://src/unit/definitions/zergling.tres", Vector2i(-1, -1)),
				_make_unit(8, "res://src/unit/definitions/baneling.tres", Vector2i(-3, 1)),
			]},
		],
		"tile_resources": {},
	}


static func _scout_kite_state() -> Dictionary:
	return {
		"scenario_id": "training_scout_kite",
		"hex_radius": 5,
		"groups": [
			{"name": "terran", "resources": {}, "units": [
				_make_unit(1, "res://src/unit/definitions/scout.tres", Vector2i(2, 0)),
				_make_unit(2, "res://src/unit/definitions/marine.tres", Vector2i(2, -1)),
			]},
			{"name": "zerg", "resources": {}, "units": [
				_make_unit(3, "res://src/unit/definitions/zergling.tres", Vector2i(-1, 0)),
				_make_unit(4, "res://src/unit/definitions/zergling.tres", Vector2i(-2, 1)),
				_make_unit(5, "res://src/unit/definitions/hydralisk.tres", Vector2i(-3, 0)),
			]},
		],
		"tile_resources": {},
	}


static func _worker_screen_state() -> Dictionary:
	return {
		"scenario_id": "training_worker_screen",
		"hex_radius": 5,
		"groups": [
			{"name": "terran", "resources": {"crystal": 3, "people": 1}, "units": [
				_make_unit(1, "res://src/unit/definitions/excavator.tres", Vector2i(1, 0)),
				_make_unit(2, "res://src/unit/definitions/marine.tres", Vector2i(2, -1)),
				_make_unit(3, "res://src/unit/definitions/scout.tres", Vector2i(2, 0)),
			]},
			{"name": "zerg", "resources": {"crystal": 3}, "units": [
				_make_unit(4, "res://src/unit/definitions/shardling.tres", Vector2i(-1, 0)),
				_make_unit(5, "res://src/unit/definitions/zergling.tres", Vector2i(-2, 1)),
				_make_unit(6, "res://src/unit/definitions/hydralisk.tres", Vector2i(-2, -1)),
			]},
		],
		"tile_resources": {},
	}


static func _baneling_flank_state() -> Dictionary:
	return {
		"scenario_id": "training_baneling_flank",
		"hex_radius": 4,
		"groups": [
			{"name": "terran", "resources": {}, "units": [
				_make_unit(1, "res://src/unit/definitions/marine.tres", Vector2i(0, 0)),
				_make_unit(2, "res://src/unit/definitions/marine.tres", Vector2i(1, -1)),
				_make_unit(3, "res://src/unit/definitions/scout.tres", Vector2i(1, 0)),
			]},
			{"name": "zerg", "resources": {}, "units": [
				_make_unit(4, "res://src/unit/definitions/baneling.tres", Vector2i(-1, 0)),
				_make_unit(5, "res://src/unit/definitions/zergling.tres", Vector2i(-2, 0)),
				_make_unit(6, "res://src/unit/definitions/zergling.tres", Vector2i(-1, -1)),
			]},
		],
		"tile_resources": {},
	}


static func _attrition_state() -> Dictionary:
	return {
		"scenario_id": "training_attrition",
		"hex_radius": 5,
		"groups": [
			{"name": "terran", "resources": {"crystal": 1}, "units": [
				_make_unit(1, "res://src/unit/definitions/marine.tres", Vector2i(2, -1), 2),
				_make_unit(2, "res://src/unit/definitions/marine.tres", Vector2i(2, 0), 2),
				_make_unit(3, "res://src/unit/definitions/medic.tres", Vector2i(3, -1)),
				_make_unit(4, "res://src/unit/definitions/scout.tres", Vector2i(2, 1)),
			]},
			{"name": "zerg", "resources": {"crystal": 1}, "units": [
				_make_unit(5, "res://src/unit/definitions/hydralisk.tres", Vector2i(-2, -1)),
				_make_unit(6, "res://src/unit/definitions/hydralisk.tres", Vector2i(-2, 0)),
				_make_unit(7, "res://src/unit/definitions/zergling.tres", Vector2i(-1, 1)),
				_make_unit(8, "res://src/unit/definitions/baneling.tres", Vector2i(-3, 0)),
			]},
		],
		"tile_resources": {},
	}


static func _fester_siege_state() -> Dictionary:
	# Elimination remains the only victory condition. Zerg begins one people
	# short of spawning, so the Fester must consume from the town before the
	# first reinforcement. The initial Zerglings screen the producer while the
	# nearby Marines have a narrow window to break through before production
	# compounds. Twelve people supports several consume/heal cycles without
	# making the producer immortal.
	return {
		"scenario_id": "training_fester_siege",
		"hex_radius": 5,
		"groups": [
			{"name": "terran", "resources": {}, "units": [
				_make_unit(1, "res://src/unit/definitions/marine.tres", Vector2i(3, -1)),
				_make_unit(2, "res://src/unit/definitions/marine.tres", Vector2i(3, 0)),
				_make_unit(3, "res://src/unit/definitions/marine.tres", Vector2i(2, 1)),
			]},
			{"name": "zerg", "resources": {"people": 2}, "units": [
				_make_unit(4, "res://src/unit/definitions/fester.tres", Vector2i(0, 0)),
				_make_unit(5, "res://src/unit/definitions/zergling.tres", Vector2i(1, 0)),
				_make_unit(6, "res://src/unit/definitions/zergling.tres", Vector2i(1, -1)),
			]},
		],
		"tile_resources": {
			HexGrid.get_cell_key(0, 0): {
				"amount": 12,
				"max_amount": 12,
				"resource_type": "people",
			},
		},
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
