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

const SUITE_VERSION := 2
const DEFAULT_SEED_BASE := 1701
const FAST_PAIR_COUNT := 8
const FULL_PAIR_COUNT := 32

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
	"broad": {"max_actions_per_unit": 8, "own_max_plans": 8, "opponent_max_plans": 8},
}


static func available_presets() -> Array[String]:
	return ["smoke", "fast", "full"]


static func agent_settings(profile_name: String) -> Dictionary:
	var profile: Dictionary = AGENT_PROFILES.get(profile_name, {})
	if profile.is_empty():
		return {}
	return GameplayAI.handwritten_settings(
		int(profile.get("max_actions_per_unit", 0)),
		int(profile.get("own_max_plans", 0)),
		int(profile.get("max_actions_per_unit", 0)),
		int(profile.get("opponent_max_plans", 0))
	)


static func get_preset(preset_name: String, seed_base: int = DEFAULT_SEED_BASE) -> Array:
	var pair_count := 0
	match preset_name:
		"smoke":
			pair_count = 2
		"fast":
			pair_count = FAST_PAIR_COUNT
		"full":
			pair_count = FULL_PAIR_COUNT
		_:
			return []

	var jobs: Array = []
	for pair_index in range(pair_count):
		# 7919 is odd and 7919 mod 8 == 7, so an eight-pair block visits every
		# family residue exactly once before repeating. That gives the PR tier
		# stratified mechanic coverage while the seed still randomizes geometry,
		# health/resources, and rotation inside each family.
		var scenario_seed := seed_base + pair_index * 7919
		jobs.append_array(_make_pair_jobs(scenario_seed, preset_name))
	return jobs


static func build_generated_state(scenario_seed: int, preset_name: String = "fast") -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = scenario_seed
	# Family choice is stratified by seed residue instead of sampled with
	# replacement. This prevents a small fast run from accidentally spending most
	# of its budget on one family while keeping the rest of the state procedural.
	var family_index := scenario_seed % SCENARIO_FAMILIES.size()
	if family_index < 0:
		family_index += SCENARIO_FAMILIES.size()
	var family := str(SCENARIO_FAMILIES[family_index])
	var rotation_steps := rng.randi_range(0, 5)
	var variation_seed := int(rng.randi())
	var state := PureStateSelfPlaySuite.build_state(family)
	state = PureStateSelfPlaySuite.vary_state(state, variation_seed)

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
	}
	return state


static func _make_pair_jobs(scenario_seed: int, preset_name: String) -> Array:
	var state := build_generated_state(scenario_seed, preset_name)
	var metadata: Dictionary = state.get("arena_metadata", {})
	var family := str(metadata.get("base_scenario_id", ""))
	var max_turns := int(FAMILY_MAX_TURNS.get(family, 10))
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
		"challenger_group": challenger_group,
		"champion_group": champion_group,
		"max_turns": max_turns,
		"state": state.duplicate(true),
	}
