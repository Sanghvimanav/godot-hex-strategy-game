extends RefCounted
class_name PureStateBasicRandomSuite
## Deterministic random curriculum for the radius-one Marine-vs-Zergling experiment.
##
## Training and evaluation are intentionally separated by rotation parity and seed
## ranges. Training may use only 0/2/4. Evaluation may use only 1/3/5. Both sides
## remain stacked on opposing edge cells and command-hex objectives stay disabled.
##
## Training generation can be deterministically sharded in CI with
## BASIC_RANDOM_SHARD_INDEX / BASIC_RANDOM_SHARD_COUNT. With those variables unset,
## behavior is byte-for-byte equivalent to the historical single-process suite.

const PureStateSelfPlaySuite = preload("res://src/simulation/pure_state_self_play_suite.gd")

const VERSION := 1
const TRAINING_ROTATIONS := [0, 2, 4]
const EVALUATION_ROTATIONS := [1, 3, 5]
const TRAINING_SEED_BASE := 610101
const EVALUATION_SEED_BASE := 710101
const SEED_STRIDE := 7919
const DEFAULT_TRAINING_GAMES := 18
const DEFAULT_EVALUATION_PAIRS := 36
const NEAR_BALANCED_PROBABILITY := 0.80
const MAX_TURNS := 8
const REWARD_DISCOUNT := 0.95
const MAX_ACTIONS_PER_UNIT := 8
const OWN_MAX_PLANS := 4
const OPPONENT_MAX_PLANS := 4
const MAP_PROFILE := "basic_radius1_random_v1"


static func training_jobs(game_count: int = DEFAULT_TRAINING_GAMES) -> Array:
	var jobs: Array = []
	var shard_count := maxi(1, int(OS.get_environment("BASIC_RANDOM_SHARD_COUNT") if OS.has_environment("BASIC_RANDOM_SHARD_COUNT") else "1"))
	var shard_index := int(OS.get_environment("BASIC_RANDOM_SHARD_INDEX") if OS.has_environment("BASIC_RANDOM_SHARD_INDEX") else "0")
	if shard_index < 0 or shard_index >= shard_count:
		push_error("Invalid basic-random shard %d/%d" % [shard_index, shard_count])
		return jobs
	for index in range(maxi(0, game_count)):
		if index % shard_count != shard_index:
			continue
		var seed := TRAINING_SEED_BASE + index * SEED_STRIDE
		jobs.append(_random_job(seed, TRAINING_ROTATIONS, "training"))
	return jobs


static func evaluation_pair_jobs(pair_count: int = DEFAULT_EVALUATION_PAIRS) -> Array:
	var jobs: Array = []
	for index in range(maxi(0, pair_count)):
		var seed := EVALUATION_SEED_BASE + index * SEED_STRIDE
		var base := _random_job(seed, EVALUATION_ROTATIONS, "evaluation")
		jobs.append_array(_mirrored_pair(base, "random"))
	return jobs


## The three original drills are retained as held-out counterfactual diagnostics.
## They are never returned by training_jobs().
static func counterfactual_pair_jobs() -> Array:
	var jobs: Array = []
	for scenario in range(1, 4):
		for rotation in EVALUATION_ROTATIONS:
			var marines := 1 if scenario == 1 else (3 if scenario == 2 else 2)
			var zerglings := 2 if scenario != 3 else 4
			var cap := 3 if scenario == 1 else (8 if scenario == 2 else 4)
			var turn_limit_winner := "terran" if scenario != 2 else "zerg"
			var state := PureStateSelfPlaySuite.basic_state(
				marines, zerglings, rotation, cap, turn_limit_winner, false
			)
			state["arena_metadata"] = {
				"base_scenario_id": "counterfactual_s%d" % scenario,
				"rotation_steps": rotation,
				"map_profile": MAP_PROFILE,
				"hex_radius": 1,
				"marines": marines,
				"zerglings": zerglings,
			}
			var base := {
				"game_id": "counterfactual-s%d-r%d" % [scenario, rotation],
				"scenario_id": "counterfactual_s%d" % scenario,
				"scenario_seed": scenario * 100 + rotation,
				"rotation_steps": rotation,
				"marines": marines,
				"zerglings": zerglings,
				"max_turns": cap,
				"turn_limit_winner": turn_limit_winner,
				"reward_discount": REWARD_DISCOUNT,
				"state": state,
			}
			jobs.append_array(_mirrored_pair(base, "counterfactual"))
	return jobs


static func _random_job(seed: int, rotations: Array, split_name: String) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var counts := _sample_counts(rng)
	var marines := int(counts[0])
	var zerglings := int(counts[1])
	var rotation := int(rotations[rng.randi_range(0, rotations.size() - 1)])
	var state := PureStateSelfPlaySuite.basic_state(
		marines, zerglings, rotation, MAX_TURNS, "", false
	)
	state["scenario_id"] = "basic_random_m%d_z%d_s%d" % [marines, zerglings, seed]
	state["arena_metadata"] = {
		"base_scenario_id": "basic_m%d_z%d" % [marines, zerglings],
		"rotation_steps": rotation,
		"map_profile": MAP_PROFILE,
		"hex_radius": 1,
		"marines": marines,
		"zerglings": zerglings,
		"split": split_name,
		"scenario_seed": seed,
	}
	return {
		"game_id": "%s-random-m%d-z%d-r%d-s%d" % [split_name, marines, zerglings, rotation, seed],
		"scenario_id": "basic_m%d_z%d" % [marines, zerglings],
		"scenario_seed": seed,
		"rotation_steps": rotation,
		"marines": marines,
		"zerglings": zerglings,
		"max_turns": MAX_TURNS,
		"turn_limit_winner": "",
		"reward_discount": REWARD_DISCOUNT,
		"max_actions_per_unit": MAX_ACTIONS_PER_UNIT,
		"own_max_plans": OWN_MAX_PLANS,
		"opponent_max_plans": OPPONENT_MAX_PLANS,
		"state": state,
	}


static func _sample_counts(rng: RandomNumberGenerator) -> Array:
	var marines := rng.randi_range(1, 4)
	var zerglings: int
	if rng.randf() < NEAR_BALANCED_PROBABILITY:
		var nearby: Array[int] = []
		for candidate in range(1, 5):
			if absi(candidate - marines) <= 1:
				nearby.append(candidate)
		zerglings = nearby[rng.randi_range(0, nearby.size() - 1)]
	else:
		zerglings = rng.randi_range(1, 4)
	return [marines, zerglings]


static func _mirrored_pair(base: Dictionary, prefix: String) -> Array:
	var pair_id := "%s-%s" % [prefix, str(base.get("game_id", "pair"))]
	var jobs: Array = []
	for challenger_group in ["terran", "zerg"]:
		var champion_group := "zerg" if challenger_group == "terran" else "terran"
		jobs.append({
			"pair_id": pair_id,
			"game_id": "%s-challenger-%s" % [pair_id, challenger_group],
			"scenario_seed": int(base.get("scenario_seed", 0)),
			"base_scenario_id": str(base.get("scenario_id", "")),
			"rotation_steps": int(base.get("rotation_steps", 0)),
			"marines": int(base.get("marines", 0)),
			"zerglings": int(base.get("zerglings", 0)),
			"map_profile": MAP_PROFILE,
			"hex_radius": 1,
			"challenger_group": challenger_group,
			"champion_group": champion_group,
			"max_turns": int(base.get("max_turns", MAX_TURNS)),
			"turn_limit_winner": str(base.get("turn_limit_winner", "")),
			"state": (base.get("state", {}) as Dictionary).duplicate(true),
		})
	return jobs