extends RefCounted
class_name PureStateArenaSuite
## Reproducible full-game head-to-head arena scenarios.
##
## Arena states are not unconstrained random noise. Each seed selects a proven
## tactical family, applies small seeded state perturbations, then rotates the
## deployment. This preserves meaningful game mechanics while measuring whether
## an AI improvement survives small geometry/HP/resource changes.

const GameplayAI = preload("res://src/battle/ai/gameplay_ai.gd")
const PureStateSelfPlaySuite = preload("res://src/simulation/pure_state_self_play_suite.gd")

const SUITE_VERSION := 6
const DEFAULT_SEED_BASE := 1701
const FAST_PAIR_COUNT := 8
const FULL_PAIR_COUNT := 32
const ARENA_TURN_ALLOWANCE := 2

const MAP_PROFILE_LEGACY := "legacy_v1"
const MAP_PROFILE_COMPACT := "compact_v1"
const DEFAULT_MAP_PROFILE := MAP_PROFILE_COMPACT
const MAP_PROFILE_UNFAMILIAR := "phase1_unfamiliar_v1"
const MAP_PROFILE_BASIC := "basic_radius1_v1"
# Reserved evaluation seeds. Never use either group for training or mistake mining.
const PHASE1_FAMILIAR_SEEDS := [2100001, 2107920, 2115839, 2123758, 2131677, 2139596, 2147515, 2155434, 2163353, 2171272]
const PHASE1_UNFAMILIAR_SEEDS := [3100001, 3107920, 3115839, 3123758, 3131677, 3139596, 3147515, 3155434, 3163353, 3171272]
const COMPACT_FAMILY_HEX_RADIUS := {
	"mixed_force": 4,
	"hydra_crossfire": 3,
	"medic_hold": 3,
	"scout_kite": 3,
	"worker_screen": 3,
	"baneling_flank": 3,
	"attrition": 3,
	"fester_siege": 4,
}

# Official benchmark seeds are explicit rather than regenerated from an editable
# base. This makes fast/full arena results comparable across commits and over time.
# The fast set is a strict subset of the full set so PR results can be reproduced
# inside the larger manual tournament.
const FAST_SEEDS := [
	1701,
	9620,
	17539,
	25458,
	33377,
	41296,
	49215,
	57134,
]

const FULL_SEEDS := [
	1701,
	9620,
	17539,
	25458,
	33377,
	41296,
	49215,
	57134,
	65053,
	72972,
	80891,
	88810,
	96729,
	104648,
	112567,
	120486,
	128405,
	136324,
	144243,
	152162,
	160081,
	168000,
	175919,
	183838,
	191757,
	199676,
	207595,
	215514,
	223433,
	231352,
	239271,
	247190,
]

const SCENARIO_FAMILIES := [
	"mixed_force",
	"hydra_crossfire",
	"medic_hold",
	"scout_kite",
	"worker_screen",
	"baneling_flank",
	"attrition",
	"fester_siege",
]

const FAMILY_MAX_TURNS := {
	"mixed_force": 8,
	"hydra_crossfire": 9,
	"medic_hold": 9,
	"scout_kite": 10,
	"worker_screen": 10,
	"baneling_flank": 8,
	"attrition": 11,
	"fester_siege": 15,
}

const AGENT_PROFILES := {
	# Plan-pair count dominates one-turn search cost. Keep the per-PR tier at 2x2
	# while preserving the same action enumeration used by existing self-play.
	"fast": {"max_actions_per_unit": 8, "own_max_plans": 2, "opponent_max_plans": 2},
	"balanced": {"max_actions_per_unit": 8, "own_max_plans": 4, "opponent_max_plans": 4},
	# Intermediate diagnostic profile: if 6x6 cannot justify its extra compute on
	# the frozen arena, there is little reason to spend full-run budget on 8x8.
	"wide": {"max_actions_per_unit": 8, "own_max_plans": 6, "opponent_max_plans": 6},
	"broad": {"max_actions_per_unit": 8, "own_max_plans": 8, "opponent_max_plans": 8},
}


static func available_presets() -> Array[String]:
	return ["smoke", "fast", "full", "phase1_familiar", "phase1_unfamiliar", "basic", "basic_s1"]


static func available_map_profiles() -> Array[String]:
	return [MAP_PROFILE_LEGACY, MAP_PROFILE_COMPACT, MAP_PROFILE_UNFAMILIAR, MAP_PROFILE_BASIC]


static func agent_settings(
	profile_name: String,
	evaluator_name: String = GameplayAI.EVALUATOR_HANDWRITTEN
) -> Dictionary:
	var profile: Dictionary = AGENT_PROFILES.get(profile_name, {})
	if profile.is_empty():
		return {}
	var max_actions := int(profile.get("max_actions_per_unit", 0))
	var own_plans := int(profile.get("own_max_plans", 0))
	var opponent_plans := int(profile.get("opponent_max_plans", 0))
	if evaluator_name == GameplayAI.EVALUATOR_HANDWRITTEN:
		return GameplayAI.handwritten_settings(max_actions, own_plans, max_actions, opponent_plans)
	if evaluator_name == GameplayAI.EVALUATOR_NEURAL:
		return GameplayAI.neural_settings(max_actions, own_plans, max_actions, opponent_plans)
	return {}


static func get_preset(
	preset_name: String,
	seed_base: int = DEFAULT_SEED_BASE,
	map_profile: String = DEFAULT_MAP_PROFILE
) -> Array:
	if preset_name in ["basic", "basic_s1"]:
		if map_profile != MAP_PROFILE_BASIC:
			return []
		var jobs: Array = []
		var marine_counts := [1] if preset_name == "basic_s1" else [2, 3, 4]
		var zerg_counts := [2] if preset_name == "basic_s1" else [2, 3, 4]
		for marines in marine_counts:
			for zerglings in zerg_counts:
				for rotation in [1, 3, 5]:
					var cap := 3 if preset_name == "basic_s1" else (8 if marines == 3 and zerglings == 2 else 4)
					var survivor := "terran" if preset_name == "basic_s1" or (marines == 2 and zerglings == 4) else ("zerg" if marines == 3 and zerglings == 2 else "")
					var state := PureStateSelfPlaySuite.basic_state(marines, zerglings, rotation, cap, survivor)
					state["arena_metadata"] = {"base_scenario_id": "basic_m%d_z%d" % [marines, zerglings],
						"rotation_steps": rotation, "map_profile": MAP_PROFILE_BASIC, "hex_radius": 1}
					var pair_id := "basic-m%d-z%d-r%d" % [marines, zerglings, rotation]
					for faction in ["terran", "zerg"]:
						var job := _make_job(pair_id, marines * 100 + zerglings * 10 + rotation, state, cap, faction)
						job["turn_limit_winner"] = survivor
						jobs.append(job)
		return jobs
	if map_profile not in available_map_profiles():
		return []
	var scenario_seeds: Array = []
	match preset_name:
		"smoke":
			# Smoke remains intentionally movable for cheap local/debug checks.
			for pair_index in range(2):
				scenario_seeds.append(seed_base + pair_index * 7919)
		"fast":
			scenario_seeds = FAST_SEEDS.duplicate()
		"full":
			scenario_seeds = FULL_SEEDS.duplicate()
		"phase1_familiar":
			if map_profile != MAP_PROFILE_COMPACT:
				return []
			scenario_seeds = PHASE1_FAMILIAR_SEEDS.duplicate()
		"phase1_unfamiliar":
			if map_profile != MAP_PROFILE_UNFAMILIAR:
				return []
			scenario_seeds = PHASE1_UNFAMILIAR_SEEDS.duplicate()
		_:
			return []

	var jobs: Array = []
	for scenario_seed_variant in scenario_seeds:
		var scenario_seed := int(scenario_seed_variant)
		jobs.append_array(_make_pair_jobs(scenario_seed, preset_name, map_profile))
	return jobs


static func build_generated_state(
	scenario_seed: int,
	preset_name: String = "fast",
	map_profile: String = DEFAULT_MAP_PROFILE
) -> Dictionary:
	if map_profile not in available_map_profiles():
		return {}
	var rng := RandomNumberGenerator.new()
	rng.seed = scenario_seed
	# Family choice is stratified by seed residue instead of sampled with
	# replacement. Each official eight-seed block visits all eight families once,
	# while the seed still randomizes geometry, health/resources, and rotation.
	var family_index := scenario_seed % SCENARIO_FAMILIES.size()
	if family_index < 0:
		family_index += SCENARIO_FAMILIES.size()
	var family := str(SCENARIO_FAMILIES[family_index])
	var rotation_steps := rng.randi_range(0, 5)
	var variation_seed := int(rng.randi())
	var state := PureStateSelfPlaySuite.build_state(family)
	_apply_map_profile(state, family, map_profile)
	state = PureStateSelfPlaySuite.vary_state(state, variation_seed)
	if map_profile == MAP_PROFILE_UNFAMILIAR:
		_redeploy_unfamiliar(state, rng)

	# Full runs spend their extra budget on scenario coverage first, not wider
	# search. A minority of states receive a second small perturbation so the full
	# arena probes slightly farther from the hand-authored fixture manifold.
	var variation_passes := 1
	if preset_name == "full" and rng.randf() < 0.35:
		state = PureStateSelfPlaySuite.vary_state(state, int(rng.randi()))
		variation_passes = 2
	state = PureStateSelfPlaySuite.rotate_state(state, rotation_steps)
	state["scenario_id"] = "arena_%s_s%d" % [family, scenario_seed]
	state["arena_metadata"] = {
		"suite_version": SUITE_VERSION,
		"scenario_seed": scenario_seed,
		"base_scenario_id": family,
		"rotation_steps": rotation_steps,
		"variation_seed": variation_seed,
		"variation_passes": variation_passes,
		"map_profile": map_profile,
		"hex_radius": int(state.get("hex_radius", 0)),
	}
	return state


static func _redeploy_unfamiliar(state: Dictionary, rng: RandomNumberGenerator) -> void:
	# A new deployment generator, rather than another one-cell fixture variation:
	# armies occupy opposing wedges, with randomized depth/formation and neutral
	# resource terrain retained. Objectives are derived from the new deployment.
	var radius := 4
	state["hex_radius"] = radius
	state.erase("command_hexes")
	var used: Dictionary = {}
	for group_variant in state.get("groups", []):
		var group: Dictionary = group_variant
		if str(group.get("name", "")) not in ["terran", "zerg"]:
			for unit in group.get("units", []):
				var cell: Array = unit.get("cell", [0, 0])
				used["%d,%d" % [int(cell[0]), int(cell[1])]] = true
	for group_variant in state.get("groups", []):
		var group: Dictionary = group_variant
		var name := str(group.get("name", ""))
		if name not in ["terran", "zerg"]:
			continue
		var direction := 1 if name == "terran" else -1
		for unit_variant in group.get("units", []):
			var unit: Dictionary = unit_variant
			if int(unit.get("health", 0)) <= 0:
				continue
			var choices: Array = []
			for q in range(1, 4):
				for r in range(-2, 3):
					var cq := q * direction
					if maxi(abs(cq), maxi(abs(r), abs(cq + r))) <= radius and not used.has("%d,%d" % [cq, r]):
						choices.append([cq, r])
			if choices.is_empty():
				continue
			var cell: Array = choices[rng.randi_range(0, choices.size() - 1)]
			unit["cell"] = cell
			used["%d,%d" % [int(cell[0]), int(cell[1])]] = true


static func _apply_map_profile(state: Dictionary, family: String, map_profile: String) -> void:
	if map_profile == MAP_PROFILE_LEGACY:
		return
	if map_profile == MAP_PROFILE_COMPACT:
		state["hex_radius"] = int(
			COMPACT_FAMILY_HEX_RADIUS.get(family, int(state.get("hex_radius", 5)))
		)


static func _make_pair_jobs(scenario_seed: int, preset_name: String, map_profile: String) -> Array:
	var state := build_generated_state(scenario_seed, preset_name, map_profile)
	if state.is_empty():
		return []
	var metadata: Dictionary = state.get("arena_metadata", {})
	var family := str(metadata.get("base_scenario_id", ""))
	# Generated variants can move objectives/fights far enough that the original
	# handcrafted cap ends one or two turns before a real resolution. Give every
	# arena variant two additional turns while keeping the cap a hard safety bound.
	var max_turns := int(FAMILY_MAX_TURNS.get(family, 10)) + ARENA_TURN_ALLOWANCE
	var pair_id := "%s-s%d" % [family, scenario_seed]
	return [
		_make_job(pair_id, scenario_seed, state, max_turns, "terran"),
		_make_job(pair_id, scenario_seed, state, max_turns, "zerg"),
	]


static func _make_job(
	pair_id: String,
	scenario_seed: int,
	state: Dictionary,
	max_turns: int,
	challenger_group: String
) -> Dictionary:
	var champion_group := "zerg" if challenger_group == "terran" else "terran"
	var metadata: Dictionary = state.get("arena_metadata", {})
	return {
		"pair_id": pair_id,
		"game_id": "%s-challenger-%s" % [pair_id, challenger_group],
		"scenario_seed": scenario_seed,
		"base_scenario_id": str(metadata.get("base_scenario_id", "")),
		"rotation_steps": int(metadata.get("rotation_steps", 0)),
		"variation_seed": int(metadata.get("variation_seed", 0)),
		"variation_passes": int(metadata.get("variation_passes", 1)),
		"map_profile": str(metadata.get("map_profile", MAP_PROFILE_LEGACY)),
		"hex_radius": int(metadata.get("hex_radius", state.get("hex_radius", 0))),
		"challenger_group": challenger_group,
		"champion_group": champion_group,
		"max_turns": max_turns,
		"state": state.duplicate(true),
	}
