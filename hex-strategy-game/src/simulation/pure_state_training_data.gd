extends RefCounted
class_name PureStateTrainingData
## Converts deterministic full-game self-play rollouts into supervised value targets.
##
## V1 emits labels only for terminal objectives. An ordinary turn-limit game remains
## unlabeled because its eventual winner is unknown; a scenario may explicitly declare
## a winner at its objective horizon. Each visited state is emitted once per perspective.

const PureStateGameRollout = preload("res://src/simulation/pure_state_game_rollout.gd")

const SCHEMA_VERSION := 1
const TRACE_SCHEMA_VERSION := 1


static func generate_game_examples(
	game_state: Dictionary,
	group_a: String,
	group_b: String,
	game_id: String = "",
	max_turns: int = PureStateGameRollout.DEFAULT_MAX_TURNS,
	max_actions_per_unit: int = PureStateGameRollout.DEFAULT_MAX_ACTIONS_PER_UNIT,
	own_max_plans: int = PureStateGameRollout.DEFAULT_OWN_MAX_PLANS,
	opponent_max_plans: int = PureStateGameRollout.DEFAULT_OPPONENT_MAX_PLANS,
	extra_source_metadata: Dictionary = {},
	turn_limit_winner: String = ""
) -> Dictionary:
	var rollout := PureStateGameRollout.play_game(
		game_state,
		group_a,
		group_b,
		max_turns,
		max_actions_per_unit,
		own_max_plans,
		opponent_max_plans,
		true,
		turn_limit_winner
	)
	var source_metadata := {
		"max_turns": max_turns,
		"max_actions_per_unit": max_actions_per_unit,
		"own_max_plans": own_max_plans,
		"opponent_max_plans": opponent_max_plans,
		"turn_limit_winner": turn_limit_winner,
	}
	# Batch generators can attach immutable provenance (rules commit, suite version,
	# preset, rotation, etc.) without changing the stable top-level example schema.
	source_metadata.merge(extra_source_metadata.duplicate(true), true)
	return build_examples_from_rollout(
		rollout,
		group_a,
		group_b,
		_resolve_game_id(game_state, group_a, group_b, game_id),
		source_metadata
	)


static func build_examples_from_rollout(
	rollout: Dictionary,
	group_a: String,
	group_b: String,
	game_id: String,
	source_metadata: Dictionary = {}
) -> Dictionary:
	var status := str(rollout.get("status", ""))
	var winner := str(rollout.get("winner", ""))
	var turns_played := int(rollout.get("turns_played", 0))
	var termination_reason := str(rollout.get("termination_reason", ""))
	var max_non_progress_streak := int(rollout.get("max_non_progress_streak", 0))
	var result := {
		"valid": bool(rollout.get("valid", false)),
		"labeled": false,
		"status": status,
		"winner": winner,
		"termination_reason": termination_reason,
		"turns_played": turns_played,
		"max_non_progress_streak": max_non_progress_streak,
		"game_id": game_id,
		"examples": [],
		"example_count": 0,
		# Traces are diagnostic artifacts, not training examples. Preserve them for
		# terminal, turn-limit, and failed games so every rollout can be inspected.
		"trace": {
			"trace_schema_version": TRACE_SCHEMA_VERSION,
			"game_id": game_id,
			"status": status,
			"winner": winner,
			"termination_reason": termination_reason,
			"turns_played": turns_played,
			"max_non_progress_streak": max_non_progress_streak,
			"groups": [group_a, group_b],
			"source": source_metadata.duplicate(true),
			"turns": (rollout.get("history", []) as Array).duplicate(true),
			"final_state": (rollout.get("final_state", {}) as Dictionary).duplicate(true),
		},
	}
	if not bool(result.get("valid", false)):
		return result
	if group_a.is_empty() or group_b.is_empty() or group_a == group_b or game_id.is_empty():
		result["valid"] = false
		return result
	if status != "terminal":
		# Do not poison value targets from an unadjudicated turn cap.
		return result

	var states := _visited_states_from_rollout(rollout)
	if states.is_empty():
		result["valid"] = false
		return result

	var examples: Array = []
	for turn_index in range(states.size()):
		var state_variant = states[turn_index]
		if not (state_variant is Dictionary):
			result["valid"] = false
			result["examples"] = []
			result["example_count"] = 0
			return result
		var state: Dictionary = state_variant
		var terminal_state := turn_index == states.size() - 1
		examples.append(_build_example(
			state,
			game_id,
			turn_index,
			group_a,
			group_b,
			_perspective_outcome(winner, group_a),
			terminal_state,
			winner,
			source_metadata
		))
		examples.append(_build_example(
			state,
			game_id,
			turn_index,
			group_b,
			group_a,
			_perspective_outcome(winner, group_b),
			terminal_state,
			winner,
			source_metadata
		))

	result["labeled"] = true
	result["examples"] = examples
	result["example_count"] = examples.size()
	return result


static func to_jsonl(examples: Array) -> String:
	var lines: Array[String] = []
	for example_variant in examples:
		if not (example_variant is Dictionary):
			continue
		lines.append(JSON.stringify(example_variant))
	if lines.is_empty():
		return ""
	return "\n".join(lines) + "\n"


static func write_jsonl(path: String, examples: Array) -> bool:
	if path.is_empty():
		return false
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(to_jsonl(examples))
	file.close()
	return true


static func _visited_states_from_rollout(rollout: Dictionary) -> Array:
	var history: Array = rollout.get("history", [])
	var states: Array = []
	for turn_variant in history:
		if not (turn_variant is Dictionary):
			return []
		var turn: Dictionary = turn_variant
		var state_before = turn.get("state_before", null)
		if not (state_before is Dictionary):
			return []
		states.append((state_before as Dictionary).duplicate(true))

	var final_state = rollout.get("final_state", null)
	if not (final_state is Dictionary):
		return []
	# For a zero-turn terminal state, this is the only training state. Otherwise it
	# adds the terminal state after all pre-turn states without duplicating middles.
	states.append((final_state as Dictionary).duplicate(true))
	return states


static func _build_example(
	state: Dictionary,
	game_id: String,
	turn_index: int,
	perspective_group: String,
	opponent_group: String,
	outcome: float,
	terminal_state: bool,
	winner: String,
	source_metadata: Dictionary
) -> Dictionary:
	return {
		"schema_version": SCHEMA_VERSION,
		"game_id": game_id,
		"scenario_id": str(state.get("scenario_id", "")),
		"turn_index": turn_index,
		"perspective_group": perspective_group,
		"opponent_group": opponent_group,
		"outcome": outcome,
		"terminal": terminal_state,
		"winner": winner,
		"source": source_metadata.duplicate(true),
		"state": state.duplicate(true),
	}


static func _perspective_outcome(winner: String, perspective_group: String) -> float:
	if winner.is_empty():
		return 0.0
	return 1.0 if winner == perspective_group else -1.0


static func _resolve_game_id(
	game_state: Dictionary,
	group_a: String,
	group_b: String,
	requested_game_id: String
) -> String:
	if not requested_game_id.is_empty():
		return requested_game_id
	var scenario_id := str(game_state.get("scenario_id", "self_play"))
	if scenario_id.is_empty():
		scenario_id = "self_play"
	return "%s:%s-vs-%s" % [scenario_id, group_a, group_b]
