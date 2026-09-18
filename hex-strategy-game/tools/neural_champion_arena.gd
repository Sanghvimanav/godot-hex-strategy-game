extends Node
## Fresh radius-one candidate-vs-previous-champion arena.
##
## Each workflow shard owns one rotation. Random unit counts use a seed range that is
## disjoint from training. Every base state is played twice with the checkpoints
## swapped between Terran and Zerg so faction strength cannot masquerade as model
## improvement.

const GameplayAI = preload("res://src/battle/ai/gameplay_ai.gd")
const PureStateSelfPlaySuite = preload("res://src/simulation/pure_state_self_play_suite.gd")
const PureStateGameRollout = preload("res://src/simulation/pure_state_game_rollout.gd")
const PureStateNeuralEvaluator = preload("res://src/simulation/pure_state_neural_evaluator.gd")
const PureStateJointPolicy = preload("res://src/simulation/pure_state_joint_policy.gd")

const ROTATIONS := [0, 1, 2, 3, 4, 5]
const EVALUATION_SEED_BASE := 830101
const SEED_STRIDE := 7919
const MAX_TURNS := 8
const MAX_ACTIONS_PER_UNIT := 8
const OWN_MAX_PLANS := 4
const OPPONENT_MAX_PLANS := 4


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var args := _parse_cmdline_kv()
	var candidate_checkpoint := str(args.get("candidate-checkpoint", ""))
	var champion_checkpoint := str(args.get("champion-checkpoint", ""))
	var out_dir := str(args.get("out", "user://neural_champion_arena"))
	var rotation := int(args.get("rotation", "-1"))
	var pair_count := maxi(1, int(args.get("pair-count", "4")))
	var decision_time_budget_ms := maxf(0.0, float(args.get("decision-time-budget-ms", "5000")))
	if candidate_checkpoint.is_empty() or champion_checkpoint.is_empty():
		push_error("--candidate-checkpoint and --champion-checkpoint are required")
		get_tree().quit(1)
		return
	if rotation not in ROTATIONS:
		push_error("--rotation must be one of 0..5")
		get_tree().quit(1)
		return
	var abs_out := ProjectSettings.globalize_path(out_dir)
	if DirAccess.make_dir_recursive_absolute(abs_out) != OK:
		push_error("Unable to create arena output directory")
		get_tree().quit(1)
		return

	var candidate_settings := GameplayAI.neural_settings(
		MAX_ACTIONS_PER_UNIT,
		OWN_MAX_PLANS,
		MAX_ACTIONS_PER_UNIT,
		OPPONENT_MAX_PLANS,
		candidate_checkpoint,
		{"learned_proposals": true}
	)
	var champion_settings := GameplayAI.neural_settings(
		MAX_ACTIONS_PER_UNIT,
		OWN_MAX_PLANS,
		MAX_ACTIONS_PER_UNIT,
		OPPONENT_MAX_PLANS,
		champion_checkpoint,
		{"learned_proposals": true}
	)
	for settings in [candidate_settings, champion_settings]:
		var evaluator_settings: Dictionary = settings.get("evaluator_settings", {}).duplicate(true)
		evaluator_settings["decision_time_budget_ms"] = decision_time_budget_ms
		settings["evaluator_settings"] = evaluator_settings

	var games: Array = []
	var counts := {"candidate": 0, "champion": 0, "draw": 0, "unresolved": 0, "failed": 0}
	var candidate_faction := {"terran": {"candidate": 0, "champion": 0, "draw": 0, "unresolved": 0}, "zerg": {"candidate": 0, "champion": 0, "draw": 0, "unresolved": 0}}
	for pair_index in range(pair_count):
		var seed := EVALUATION_SEED_BASE + rotation * 100000 + pair_index * SEED_STRIDE
		var rng := RandomNumberGenerator.new()
		rng.seed = seed
		var marines := rng.randi_range(1, 4)
		var zerglings := rng.randi_range(maxi(1, marines - 1), mini(4, marines + 1)) if rng.randf() < 0.8 else rng.randi_range(1, 4)
		var base_state := PureStateSelfPlaySuite.basic_state(marines, zerglings, rotation, MAX_TURNS, "", false)
		base_state["scenario_id"] = "champion_arena_m%d_z%d_r%d_s%d" % [marines, zerglings, rotation, seed]
		for candidate_group in ["terran", "zerg"]:
			var champion_group := "zerg" if candidate_group == "terran" else "terran"
			var terran_settings := candidate_settings if candidate_group == "terran" else champion_settings
			var zerg_settings := candidate_settings if candidate_group == "zerg" else champion_settings
			var result := PureStateGameRollout.play_game_with_settings(
				base_state.duplicate(true),
				"terran",
				"zerg",
				terran_settings,
				zerg_settings,
				MAX_TURNS,
				false,
				""
			)
			var winner_agent := _winner_agent(result, candidate_group, champion_group)
			counts[winner_agent] = int(counts.get(winner_agent, 0)) + 1
			candidate_faction[candidate_group][winner_agent] = int(candidate_faction[candidate_group].get(winner_agent, 0)) + 1
			games.append({
				"pair_id": "r%d-s%d" % [rotation, seed],
				"game_id": "r%d-s%d-candidate-%s" % [rotation, seed, candidate_group],
				"rotation_steps": rotation,
				"scenario_seed": seed,
				"marines": marines,
				"zerglings": zerglings,
				"candidate_group": candidate_group,
				"champion_group": champion_group,
				"valid": bool(result.get("valid", false)),
				"status": str(result.get("status", "")),
				"winner_group": str(result.get("winner", "")),
				"winner_agent": winner_agent,
				"termination_reason": str(result.get("termination_reason", "")),
				"turns_played": int(result.get("turns_played", 0)),
			})
			print("[neural-champion-arena] rotation=%d seed=%d candidate=%s result=%s" % [rotation, seed, candidate_group, winner_agent])

	var decisive := int(counts["candidate"]) + int(counts["champion"])
	var manifest := {
		"schema_version": 1,
		"arena": "fresh_all_rotation_candidate_vs_neural_champion_v1",
		"rotation": rotation,
		"required_rotations": ROTATIONS,
		"seed_base": EVALUATION_SEED_BASE,
		"pair_count": pair_count,
		"games": games,
		"counts": counts,
		"candidate_faction_counts": candidate_faction,
		"decisive_games": decisive,
		"candidate_decisive_win_rate": float(counts["candidate"]) / float(decisive) if decisive > 0 else 0.0,
		"candidate_checkpoint_sha256": FileAccess.get_sha256(candidate_checkpoint),
		"champion_checkpoint_sha256": FileAccess.get_sha256(champion_checkpoint),
		"learned_proposals": true,
		"same_search_configuration": true,
	}
	var ok := _write_json(abs_out.path_join("manifest.json"), manifest)
	print("[neural-champion-arena] summary rotation=%d counts=%s" % [rotation, str(counts)])
	_shutdown()
	get_tree().quit(0 if ok and int(counts.get("failed", 0)) == 0 else 1)


func _winner_agent(result: Dictionary, candidate_group: String, champion_group: String) -> String:
	if not bool(result.get("valid", false)):
		return "failed"
	if str(result.get("status", "")) == "turn_limit":
		return "unresolved"
	var winner := str(result.get("winner", ""))
	if winner.is_empty():
		return "draw"
	if winner == candidate_group:
		return "candidate"
	if winner == champion_group:
		return "champion"
	return "failed"


func _write_json(path: String, value: Variant) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("Unable to write %s" % path)
		return false
	file.store_string(JSON.stringify(value, "  ") + "\n")
	file.close()
	return true


func _shutdown() -> void:
	PureStateNeuralEvaluator.shutdown()
	PureStateJointPolicy.shutdown()


func _parse_cmdline_kv() -> Dictionary:
	var result: Dictionary = {}
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
