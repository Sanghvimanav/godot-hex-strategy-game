extends RefCounted
class_name PureStateSelfPlayDiversity
## Training-only deterministic expansion for the self-play dataset.
##
## The curated SelfPlaySuite remains a compact historical benchmark. This layer
## adds reproducible geometry/HP/resource variants and controlled policy replays
## for training without reusing the frozen AI-arena evaluation seeds.

const PureStateSelfPlaySuite = preload("res://src/simulation/pure_state_self_play_suite.gd")
const PureStatePolicyExploration = preload("res://src/simulation/pure_state_policy_exploration.gd")

const VERSION := 2
const PROCEDURAL_VARIANT_COUNT := 16
const POLICY_REPLAY_COUNT := 16
const TOTAL_TRAINING_VARIANT_COUNT := PROCEDURAL_VARIANT_COUNT + POLICY_REPLAY_COUNT
const TRAINING_SEED_MIN := 510101
const POLICY_SEED_MIN := 520101

const TRAINING_SEEDS := [
	510101,
	510102,
	510201,
	510202,
	510301,
	510302,
	510401,
	510402,
	510501,
	510502,
	510601,
	510602,
	510701,
	510702,
	510801,
	510802,
]

const POLICY_SEEDS := [
	520101,
	520102,
	520201,
	520202,
	520301,
	520302,
	520401,
	520402,
	520501,
	520502,
	520601,
	520602,
	520701,
	520702,
	520801,
	520802,
]

# Two geometry/resource variants per strategic family. Caps intentionally allow a
# little more room than the original short fixtures so generated states are more
# likely to reach a real terminal label instead of being discarded at the cap.
const FAMILY_CONFIGS := [
	{"scenario_id": "mixed_force", "max_turns": 10},
	{"scenario_id": "hydra_crossfire", "max_turns": 11},
	{"scenario_id": "medic_hold", "max_turns": 11},
	{"scenario_id": "scout_kite", "max_turns": 12},
	{"scenario_id": "worker_screen", "max_turns": 12},
	{"scenario_id": "baneling_flank", "max_turns": 10},
	{"scenario_id": "attrition", "max_turns": 13},
	{"scenario_id": "fester_siege", "max_turns": 17},
]

const POLICY_PROFILES := [
	PureStatePolicyExploration.PROFILE_LIGHT,
	PureStatePolicyExploration.PROFILE_EXPLORE,
]


static func expand_jobs(base_jobs: Array, preset_name: String) -> Array:
	var jobs := base_jobs.duplicate(true)
	if preset_name != "diverse":
		return jobs
	jobs.append_array(procedural_jobs())
	jobs.append_array(policy_replay_jobs())
	return jobs


static func procedural_jobs() -> Array:
	var jobs: Array = []
	for family_index in range(FAMILY_CONFIGS.size()):
		var config: Dictionary = FAMILY_CONFIGS[family_index]
		var scenario_id := str(config.get("scenario_id", ""))
		var max_turns := int(config.get("max_turns", 10))
		for variant_index in range(2):
			var seed_index := family_index * 2 + variant_index
			var variation_seed := int(TRAINING_SEEDS[seed_index])
			var budget_profile := "fast" if variant_index == 0 else "balanced"
			var rotation_steps := posmod(family_index * 2 + 1 + variant_index * 3, 6)
			jobs.append(_make_job(
				scenario_id,
				budget_profile,
				rotation_steps,
				max_turns,
				variation_seed,
				PureStatePolicyExploration.PROFILE_GREEDY,
				0,
				false
			))
	return jobs


static func policy_replay_jobs() -> Array:
	var jobs: Array = []
	for family_index in range(FAMILY_CONFIGS.size()):
		var config: Dictionary = FAMILY_CONFIGS[family_index]
		var scenario_id := str(config.get("scenario_id", ""))
		var max_turns := int(config.get("max_turns", 10))
		# Reuse the fast procedural starting state exactly; only the policy seed/profile
		# changes. This isolates trajectory diversity from starting-state diversity.
		var variation_seed := int(TRAINING_SEEDS[family_index * 2])
		var rotation_steps := posmod(family_index * 2 + 1, 6)
		for profile_index in range(POLICY_PROFILES.size()):
			var policy_seed := int(POLICY_SEEDS[family_index * 2 + profile_index])
			jobs.append(_make_job(
				scenario_id,
				"fast",
				rotation_steps,
				max_turns,
				variation_seed,
				str(POLICY_PROFILES[profile_index]),
				policy_seed,
				true
			))
	return jobs


static func _make_job(
	scenario_id: String,
	budget_profile: String,
	rotation_steps: int,
	max_turns: int,
	variation_seed: int,
	policy_profile: String,
	policy_seed: int,
	policy_replay: bool
) -> Dictionary:
	var profile: Dictionary = PureStateSelfPlaySuite.BUDGET_PROFILES.get(budget_profile, {})
	var base_state := PureStateSelfPlaySuite.build_state(scenario_id)
	var varied_state := PureStateSelfPlaySuite.vary_state(base_state, variation_seed)
	var state := PureStateSelfPlaySuite.rotate_state(varied_state, rotation_steps)
	state["scenario_id"] = "training_%s" % scenario_id
	var replay_suffix := ""
	if policy_replay:
		replay_suffix = "-policy-%s-p%d" % [policy_profile, policy_seed]
	return {
		"game_id": "procedural-%s-%s-s%d-r%d%s" % [
			scenario_id.replace("_", "-"),
			budget_profile,
			variation_seed,
			posmod(rotation_steps, 6),
			replay_suffix,
		],
		"scenario_id": scenario_id,
		"budget_profile": budget_profile,
		"rotation_steps": posmod(rotation_steps, 6),
		"variation_seed": variation_seed,
		"training_variant": true,
		"policy_replay": policy_replay,
		"policy_exploration": {
			"profile": policy_profile,
			"seed": policy_seed,
		},
		"diversity_version": VERSION,
		"group_a": "terran",
		"group_b": "zerg",
		"max_turns": max_turns,
		"turn_limit_winner": "",
		"max_actions_per_unit": PureStateSelfPlaySuite.DEFAULT_MAX_ACTIONS_PER_UNIT,
		"own_max_plans": int(profile.get("own_max_plans", 1)),
		"opponent_max_plans": int(profile.get("opponent_max_plans", 1)),
		"state": state,
	}
