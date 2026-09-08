extends RefCounted
class_name PureStateReplayV1
## Deterministic data-only replay format for simultaneous pure-state turns.
##
## ReplayV1 stores the initial state and submitted actions, then verifies every
## turn by running the same PureStateSimulator used by gameplay/AI. State hashes
## locate the first divergent boundary. This is deliberately independent of the
## existing visual replay UI; that UI can consume ReplayV1 later.

const PureStateSimulator = preload("res://src/simulation/pure_state_simulator.gd")
const PureStateHash = preload("res://src/simulation/pure_state_hash.gd")
const PureStateCommandHexRules = preload("res://src/simulation/pure_state_command_hex_rules.gd")

const SCHEMA_NAME := "ReplayV1"
const SCHEMA_VERSION := 1


static func build(initial_state: Dictionary, turns: Array, options: Dictionary = {}) -> Dictionary:
	var state: Dictionary = initial_state.duplicate(true)
	var replay_turns: Array = []
	var replay := {
		"schema": SCHEMA_NAME,
		"schema_version": SCHEMA_VERSION,
		"rules_version": str(options.get("rules_version", "")),
		"initial_state": initial_state.duplicate(true),
		"initial_state_hash": PureStateHash.hash_state(initial_state),
		"turns": replay_turns,
		"config": _dictionary_copy(options.get("config", {})),
		"result": _dictionary_copy(options.get("result", {})),
	}
	if options.has("seed"):
		replay["seed"] = options.get("seed")

	for turn_index in range(turns.size()):
		var turn_variant: Variant = turns[turn_index]
		if not (turn_variant is Dictionary):
			return _build_error("invalid_turn", turn_index + 1)
		var turn: Dictionary = turn_variant
		var submitted_variant: Variant = turn.get("submitted_actions", {})
		if not (submitted_variant is Dictionary):
			return _build_error("invalid_submitted_actions", turn_index + 1)
		var submitted_actions: Dictionary = (submitted_variant as Dictionary).duplicate(true)
		var before_hash := PureStateHash.hash_state(state)
		var simulation := PureStateSimulator.simulate_turn(state, submitted_actions)
		var next_state_variant: Variant = simulation.get("next_state", {})
		if not (next_state_variant is Dictionary) or (next_state_variant as Dictionary).is_empty():
			return _build_error("simulation_failed", turn_index + 1)
		var next_state: Dictionary = next_state_variant
		var recording: Dictionary = _dictionary_copy(simulation.get("recording", {}))
		var replay_turn := {
			"turn": int(turn.get("turn", turn_index + 1)),
			"submitted_actions": submitted_actions,
			"state_hash_before": before_hash,
			"state_hash_after": PureStateHash.hash_state(next_state),
			"resolution_events": _reason_coded_events(recording),
		}
		replay_turns.append(replay_turn)
		state = next_state

	var result: Dictionary = replay["result"]
	result["final_state_hash"] = PureStateHash.hash_state(state)
	replay["result"] = result
	replay["turns"] = replay_turns
	return replay


static func build_from_rollout(
	initial_state: Dictionary,
	group_a: String,
	group_b: String,
	rollout: Dictionary,
	rules_version: String = ""
) -> Dictionary:
	var replay_initial_state := initial_state.duplicate(true)
	PureStateCommandHexRules.ensure_command_hexes(replay_initial_state, group_a, group_b)
	var submitted_template: Dictionary = {}
	for group_variant in replay_initial_state.get("groups", []):
		if group_variant is Dictionary:
			var group_name := str((group_variant as Dictionary).get("name", ""))
			if not group_name.is_empty():
				submitted_template[group_name] = []

	var turns: Array = []
	for turn_variant in rollout.get("history", []):
		if not (turn_variant is Dictionary):
			continue
		var turn: Dictionary = turn_variant
		var submitted := submitted_template.duplicate(true)
		submitted[group_a] = (turn.get(group_a + "_actions", []) as Array).duplicate(true)
		submitted[group_b] = (turn.get(group_b + "_actions", []) as Array).duplicate(true)
		turns.append({
			"turn": int(turn.get("turn", turns.size() + 1)),
			"submitted_actions": submitted,
		})

	var replay := build(replay_initial_state, turns, {
		"rules_version": rules_version,
		"config": {
			"group_a": group_a,
			"group_b": group_b,
		},
		"result": {
			"status": str(rollout.get("status", "")),
			"winner": str(rollout.get("winner", "")),
			"termination_reason": str(rollout.get("termination_reason", "")),
			"turns_played": int(rollout.get("turns_played", turns.size())),
		},
	})
	if not bool(replay.get("schema_version", 0) == SCHEMA_VERSION):
		return replay
	var source_final_variant: Variant = rollout.get("final_state", {})
	if source_final_variant is Dictionary:
		var source_hash := PureStateHash.hash_state(source_final_variant)
		var result: Dictionary = replay.get("result", {})
		result["source_final_state_hash"] = source_hash
		result["source_final_state_matches"] = source_hash == str(result.get("final_state_hash", ""))
		replay["result"] = result
	return replay


static func verify(replay: Dictionary) -> Dictionary:
	if str(replay.get("schema", "")) != SCHEMA_NAME or int(replay.get("schema_version", 0)) != SCHEMA_VERSION:
		return _verify_error("unsupported_schema", 0, "", "")
	var initial_variant: Variant = replay.get("initial_state", {})
	if not (initial_variant is Dictionary):
		return _verify_error("invalid_initial_state", 0, "", "")
	var state: Dictionary = (initial_variant as Dictionary).duplicate(true)
	var initial_actual := PureStateHash.hash_state(state)
	var initial_expected := str(replay.get("initial_state_hash", ""))
	if initial_actual != initial_expected:
		return _verify_error("initial_state_hash_mismatch", 0, initial_expected, initial_actual)

	var turns_variant: Variant = replay.get("turns", [])
	if not (turns_variant is Array):
		return _verify_error("invalid_turns", 0, "", "")
	var turns: Array = turns_variant
	for turn_index in range(turns.size()):
		var turn_variant: Variant = turns[turn_index]
		if not (turn_variant is Dictionary):
			return _verify_error("invalid_turn", turn_index + 1, "", "")
		var turn: Dictionary = turn_variant
		var before_actual := PureStateHash.hash_state(state)
		var before_expected := str(turn.get("state_hash_before", ""))
		if before_actual != before_expected:
			return _verify_error("state_hash_before_mismatch", turn_index + 1, before_expected, before_actual)
		var submitted_variant: Variant = turn.get("submitted_actions", {})
		if not (submitted_variant is Dictionary):
			return _verify_error("invalid_submitted_actions", turn_index + 1, "", "")
		var simulation := PureStateSimulator.simulate_turn(state, submitted_variant)
		var next_state_variant: Variant = simulation.get("next_state", {})
		if not (next_state_variant is Dictionary):
			return _verify_error("simulation_failed", turn_index + 1, "", "")
		var next_state: Dictionary = next_state_variant
		var after_actual := PureStateHash.hash_state(next_state)
		var after_expected := str(turn.get("state_hash_after", ""))
		if after_actual != after_expected:
			return _verify_error("state_hash_after_mismatch", turn_index + 1, after_expected, after_actual)
		var expected_events_variant: Variant = turn.get("resolution_events", [])
		if expected_events_variant is Array:
			var actual_events := _reason_coded_events(_dictionary_copy(simulation.get("recording", {})))
			if actual_events != expected_events_variant:
				return _verify_error("resolution_events_mismatch", turn_index + 1, PureStateHash.hash_value(expected_events_variant), PureStateHash.hash_value(actual_events))
		state = next_state

	var final_actual := PureStateHash.hash_state(state)
	var result: Dictionary = _dictionary_copy(replay.get("result", {}))
	var final_expected := str(result.get("final_state_hash", ""))
	if not final_expected.is_empty() and final_actual != final_expected:
		return _verify_error("final_state_hash_mismatch", turns.size(), final_expected, final_actual)
	var source_expected := str(result.get("source_final_state_hash", ""))
	if not source_expected.is_empty() and final_actual != source_expected:
		return _verify_error("source_final_state_hash_mismatch", turns.size(), source_expected, final_actual)
	return {
		"valid": true,
		"verified": true,
		"diverged_at_turn": 0,
		"turns_replayed": turns.size(),
		"final_state_hash": final_actual,
		"final_state": state,
	}


static func _reason_coded_events(recording: Dictionary) -> Array:
	var events: Array = []
	for summary_variant in recording.get("summary", []):
		if not (summary_variant is Dictionary):
			continue
		var summary: Dictionary = summary_variant
		var cancelled := bool(summary.get("cancelled", false))
		events.append({
			"code": "action_cancelled" if cancelled else "action_executed",
			"reason": str(summary.get("cancelled_reason", "resolved")) if cancelled else "resolved",
			"unit_id": int(summary.get("unit_id", -1)),
			"action_key": str(summary.get("action_key", "")),
			"action_type": str(summary.get("action_type", "")),
		})
	for action_variant in recording.get("actions", []):
		if not (action_variant is Dictionary):
			continue
		var action: Dictionary = action_variant
		var event := {
			"code": _event_code_for_action(action),
			"reason": "resolved",
			"unit_id": int(action.get("unit_id", -1)),
		}
		if action.has("action_key"):
			event["action_key"] = str(action.get("action_key", ""))
		if action.has("from_cell"):
			event["from_cell"] = action.get("from_cell")
		if action.has("path"):
			event["path"] = action.get("path")
		events.append(event)
	for unit_id_variant in recording.get("died_ids", []):
		events.append({
			"code": "unit_eliminated",
			"reason": "health_depleted",
			"unit_id": int(unit_id_variant),
		})
	return events


static func _event_code_for_action(action: Dictionary) -> String:
	var action_type := str(action.get("type", ""))
	var action_key := str(action.get("action_key", ""))
	if action_type == "move":
		return "movement_resolved"
	if action_type == "spawn":
		return "spawn_resolved"
	if action_key in ["extract_tile", "recruit_people", "consume", "mine_crystal"]:
		return "resource_extracted"
	if action_key in ["heal_adjacent", "support_adjacent", "resupply_adjacent"]:
		return "support_resolved"
	return "ability_resolved"


static func _dictionary_copy(value: Variant) -> Dictionary:
	if value is Dictionary:
		return (value as Dictionary).duplicate(true)
	return {}


static func _build_error(error: String, turn: int) -> Dictionary:
	return {
		"schema": SCHEMA_NAME,
		"schema_version": SCHEMA_VERSION,
		"valid": false,
		"error": error,
		"turn": turn,
	}


static func _verify_error(error: String, turn: int, expected: String, actual: String) -> Dictionary:
	return {
		"valid": false,
		"verified": false,
		"error": error,
		"diverged_at_turn": turn,
		"expected": expected,
		"actual": actual,
	}
