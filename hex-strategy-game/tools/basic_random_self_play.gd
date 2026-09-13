extends Node
## Randomized radius-one self-play generator used by the neural self-play experiment.
##
## Every training start is replayed along greedy, light, and explore paths. For the
## two alternative paths, only states after the first divergence from the greedy
## trajectory are exported. This gives the value model counterfactual evidence
## without assigning conflicting outcomes to an identical pre-divergence state.
## Greedy trajectories may also capture bounded robust search decisions for
## autoregressive joint-plan policy distillation.

const GameplayAI = preload("res://src/battle/ai/gameplay_ai.gd")
const PureStateBasicRandomSuite = preload("res://src/simulation/pure_state_basic_random_suite.gd")
const PureStateGameRollout = preload("res://src/simulation/pure_state_game_rollout.gd")
const PureStateTrainingData = preload("res://src/simulation/pure_state_training_data.gd")
const PureStateNeuralEvaluator = preload("res://src/simulation/pure_state_neural_evaluator.gd")
const PureStateSearchDecisionData = preload("res://src/simulation/pure_state_search_decision_data.gd")

const PROFILES := ["greedy", "light", "explore"]
const MANIFEST_SCHEMA_VERSION := 1


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var args := _parse_cmdline_kv()
	var evaluator := str(args.get("evaluator", "handwritten"))
	var checkpoint := str(args.get("checkpoint", ""))
	var out_dir := str(args.get("out", "user://basic_random_self_play"))
	var rules_version := str(args.get("rules-version", "unknown"))
	var game_count := int(args.get("game-count", str(PureStateBasicRandomSuite.DEFAULT_TRAINING_GAMES)))
	var capture_decisions_per_game := maxi(0, int(args.get("capture-decisions-per-game", "0")))
	var learned_proposals := _parse_bool(args.get("learned-proposals", "false"))
	if evaluator not in ["handwritten", "neural"]:
		push_error("Unsupported evaluator: %s" % evaluator)
		get_tree().quit(1)
		return
	if evaluator == "neural" and checkpoint.is_empty():
		push_error("Neural self-play requires --checkpoint")
		get_tree().quit(1)
		return
	if evaluator != "neural" and learned_proposals:
		push_error("Learned proposals require the neural evaluator")
		get_tree().quit(1)
		return

	var jobs := PureStateBasicRandomSuite.training_jobs(game_count)
	var all_examples: Array = []
	var all_traces: Array = []
	var all_search_decisions: Array = []
	var summaries: Array = []
	var outcomes := {"terran": 0, "zerg": 0, "draw": 0, "unresolved": 0, "failed": 0}
	var profile_counts := {"greedy": 0, "light": 0, "explore": 0}

	for job_variant in jobs:
		if not (job_variant is Dictionary):
			continue
		var job: Dictionary = job_variant
		var greedy_settings_a := _settings_for(job, evaluator, checkpoint, "greedy", 0, learned_proposals)
		var greedy_settings_b := greedy_settings_a.duplicate(true)
		var greedy_rollout := PureStateGameRollout.play_game_with_settings(
			job.get("state", {}) as Dictionary,
			"terran",
			"zerg",
			greedy_settings_a,
			greedy_settings_b,
			int(job.get("max_turns", PureStateBasicRandomSuite.MAX_TURNS)),
			true,
			str(job.get("turn_limit_winner", ""))
		)

		for profile_index in range(PROFILES.size()):
			var profile := str(PROFILES[profile_index])
			var policy_seed := int(job.get("scenario_seed", 0)) + profile_index * 100003 + 17
			var rollout: Dictionary
			var training_start_turn := 0
			if profile == "greedy":
				rollout = greedy_rollout
			else:
				var settings_a := _settings_for(job, evaluator, checkpoint, profile, policy_seed, learned_proposals)
				var settings_b := settings_a.duplicate(true)
				rollout = PureStateGameRollout.play_game_with_settings(
					job.get("state", {}) as Dictionary,
					"terran",
					"zerg",
					settings_a,
					settings_b,
					int(job.get("max_turns", PureStateBasicRandomSuite.MAX_TURNS)),
					true,
					str(job.get("turn_limit_winner", ""))
				)
				training_start_turn = PureStateTrainingData.first_divergent_state_index(
					rollout, greedy_rollout
				)

			var source := {
				"rules_version": rules_version,
				"dataset": "basic_random_self_play",
				"evaluator": evaluator,
				"scenario_seed": int(job.get("scenario_seed", 0)),
				"rotation_steps": int(job.get("rotation_steps", 0)),
				"marines": int(job.get("marines", 0)),
				"zerglings": int(job.get("zerglings", 0)),
				"reward_discount": float(job.get("reward_discount", PureStateBasicRandomSuite.REWARD_DISCOUNT)),
				"policy_exploration_profile": profile,
				"policy_exploration_seed": policy_seed,
				"training_start_turn": training_start_turn,
				"counterfactual_path": profile != "greedy",
				"learned_proposals": learned_proposals,
			}
			var trajectory_id := "%s-%s-%s" % [str(job.get("game_id", "game")), evaluator, profile]
			var built := PureStateTrainingData.build_examples_from_rollout(
				rollout, "terran", "zerg", trajectory_id, source
			)
			if bool(built.get("labeled", false)):
				all_examples.append_array((built.get("examples", []) as Array).duplicate(true))

			# One robust candidate matrix already supplies counterfactual alternatives,
			# so capture only greedy trajectories instead of triplicating the same
			# starting decisions across the light/explore replay variants.
			if profile == "greedy" and capture_decisions_per_game > 0:
				var history: Array = rollout.get("history", [])
				for group_name in ["terran", "zerg"]:
					var opponent_group := "zerg" if group_name == "terran" else "terran"
					var action_key := group_name + "_actions"
					var captured := 0
					for history_index in range(history.size() - 1, -1, -1):
						if captured >= capture_decisions_per_game:
							break
						var turn_variant = history[history_index]
						if not (turn_variant is Dictionary):
							continue
						var turn: Dictionary = turn_variant
						if not turn.has(action_key):
							continue
						var state_before_variant = turn.get("state_before", {})
						var selected_variant = turn.get(action_key, [])
						if not (state_before_variant is Dictionary) or not (selected_variant is Array):
							continue
						var decision_source := source.duplicate(true)
						decision_source["search_decision_policy"] = "robust_candidate_distillation"
						var row := PureStateSearchDecisionData.capture_decision(
							state_before_variant as Dictionary,
							group_name,
							opponent_group,
							(selected_variant as Array).duplicate(true),
							int(job.get("max_actions_per_unit", PureStateBasicRandomSuite.MAX_ACTIONS_PER_UNIT)),
							int(job.get("own_max_plans", PureStateBasicRandomSuite.OWN_MAX_PLANS)),
							int(job.get("opponent_max_plans", PureStateBasicRandomSuite.OPPONENT_MAX_PLANS)),
							"%s-%s" % [trajectory_id, group_name],
							int(turn.get("turn", history_index + 1)),
							{},
							decision_source
						)
						if bool(row.get("valid", false)):
							all_search_decisions.append(row)
							captured += 1

			var status := str(rollout.get("status", ""))
			var winner := str(rollout.get("winner", ""))
			if not bool(rollout.get("valid", false)):
				outcomes["failed"] = int(outcomes["failed"]) + 1
			elif status != "terminal":
				outcomes["unresolved"] = int(outcomes["unresolved"]) + 1
			elif winner.is_empty():
				outcomes["draw"] = int(outcomes["draw"]) + 1
			elif outcomes.has(winner):
				outcomes[winner] = int(outcomes[winner]) + 1
			profile_counts[profile] = int(profile_counts[profile]) + 1
			var summary := {
				"game_id": trajectory_id,
				"base_game_id": str(job.get("game_id", "")),
				"scenario_seed": int(job.get("scenario_seed", 0)),
				"scenario_id": str(job.get("scenario_id", "")),
				"rotation_steps": int(job.get("rotation_steps", 0)),
				"marines": int(job.get("marines", 0)),
				"zerglings": int(job.get("zerglings", 0)),
				"evaluator": evaluator,
				"policy_profile": profile,
				"policy_seed": policy_seed,
				"counterfactual_path": profile != "greedy",
				"training_start_turn": training_start_turn,
				"valid": bool(rollout.get("valid", false)),
				"status": status,
				"winner": winner,
				"termination_reason": str(rollout.get("termination_reason", "")),
				"turns_played": int(rollout.get("turns_played", 0)),
				"example_count": int(built.get("example_count", 0)),
			}
			summaries.append(summary)
			all_traces.append({
				"game_id": trajectory_id,
				"source": source,
				"winner": winner,
				"status": status,
				"history": (rollout.get("history", []) as Array).duplicate(true),
			})
			print("[basic-random-self-play] %s m=%d z=%d r=%d evaluator=%s profile=%s status=%s winner=%s start=%d examples=%d" % [
				trajectory_id,
				int(job.get("marines", 0)),
				int(job.get("zerglings", 0)),
				int(job.get("rotation_steps", 0)),
				evaluator,
				profile,
				status,
				winner,
				training_start_turn,
				int(built.get("example_count", 0)),
			])

	var abs_out := ProjectSettings.globalize_path(out_dir)
	if DirAccess.make_dir_recursive_absolute(abs_out) != OK:
		push_error("Unable to create output directory: %s" % abs_out)
		get_tree().quit(1)
		return
	var manifest := {
		"manifest_schema_version": MANIFEST_SCHEMA_VERSION,
		"suite_version": PureStateBasicRandomSuite.VERSION,
		"rules_version": rules_version,
		"evaluator": evaluator,
		"training_rotations": PureStateBasicRandomSuite.TRAINING_ROTATIONS,
		"evaluation_rotations_excluded": PureStateBasicRandomSuite.EVALUATION_ROTATIONS,
		"command_hexes_enabled": false,
		"near_balanced_probability": PureStateBasicRandomSuite.NEAR_BALANCED_PROBABILITY,
		"reward_discount": PureStateBasicRandomSuite.REWARD_DISCOUNT,
		"base_games": jobs.size(),
		"trajectories": summaries.size(),
		"profiles": profile_counts,
		"outcomes": outcomes,
		"example_count": all_examples.size(),
		"capture_decisions_per_game": capture_decisions_per_game,
		"search_decision_count": all_search_decisions.size(),
		"learned_proposals": learned_proposals,
		"games": summaries,
	}
	var ok := _write_text(out_dir.path_join("examples.jsonl"), PureStateTrainingData.to_jsonl(all_examples))
	ok = _write_json(out_dir.path_join("manifest.json"), manifest) and ok
	ok = _write_jsonl(out_dir.path_join("traces.jsonl"), all_traces) and ok
	if capture_decisions_per_game > 0:
		ok = _write_jsonl(out_dir.path_join("search_decisions.jsonl"), all_search_decisions) and ok
	print("[basic-random-self-play] summary evaluator=%s base_games=%d trajectories=%d examples=%d decisions=%d learned_proposals=%s outcomes=%s" % [
		evaluator, jobs.size(), summaries.size(), all_examples.size(), all_search_decisions.size(), str(learned_proposals), str(outcomes)
	])
	PureStateNeuralEvaluator.shutdown()
	get_tree().quit(0 if ok else 1)


func _settings_for(job: Dictionary, evaluator: String, checkpoint: String, profile: String, seed: int, learned_proposals: bool) -> Dictionary:
	var max_actions := int(job.get("max_actions_per_unit", PureStateBasicRandomSuite.MAX_ACTIONS_PER_UNIT))
	var own_plans := int(job.get("own_max_plans", PureStateBasicRandomSuite.OWN_MAX_PLANS))
	var opponent_plans := int(job.get("opponent_max_plans", PureStateBasicRandomSuite.OPPONENT_MAX_PLANS))
	var settings: Dictionary
	if evaluator == "neural":
		settings = GameplayAI.neural_settings(
			max_actions,
			own_plans,
			max_actions,
			opponent_plans,
			checkpoint,
			{"learned_proposals": learned_proposals}
		)
	else:
		settings = GameplayAI.handwritten_settings(max_actions, own_plans, max_actions, opponent_plans)
	settings["exploration_profile"] = profile
	settings["exploration_seed"] = seed
	return settings


func _parse_bool(value: Variant) -> bool:
	return str(value).strip_edges().to_lower() in ["1", "true", "yes", "on"]


func _write_json(path: String, value: Variant) -> bool:
	return _write_text(path, JSON.stringify(value, "  ") + "\n")


func _write_jsonl(path: String, rows: Array) -> bool:
	var lines := PackedStringArray()
	for row in rows:
		lines.append(JSON.stringify(row))
	return _write_text(path, "\n".join(lines) + ("\n" if not lines.is_empty() else ""))


func _write_text(path: String, content: String) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("Unable to write %s" % ProjectSettings.globalize_path(path))
		return false
	file.store_string(content)
	file.close()
	return true


func _parse_cmdline_kv() -> Dictionary:
	var result: Dictionary = {}
	var raw: PackedStringArray = OS.get_cmdline_user_args()
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
