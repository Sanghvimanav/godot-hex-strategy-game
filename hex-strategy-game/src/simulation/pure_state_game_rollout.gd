extends RefCounted
class_name PureStateGameRollout
## Simple deterministic full-game rollout for two AI-controlled groups.
##
## Each turn both groups plan from the same pre-turn state through the canonical
## GameplayAI entry point. Their selected plans are then resolved simultaneously
## by the pure-state simulator. The rollout stops on elimination, command-hex
## capture, search failure, or a caller-provided safety turn cap.

const GameplayAI = preload("res://src/battle/ai/gameplay_ai.gd")
const PureStateSimulator = preload("res://src/simulation/pure_state_simulator.gd")
const PureStateCommandHexRules = preload("res://src/simulation/pure_state_command_hex_rules.gd")

const DEFAULT_MAX_TURNS := 12
const DEFAULT_MAX_ACTIONS_PER_UNIT := 8
const DEFAULT_OWN_MAX_PLANS := 4
const DEFAULT_OPPONENT_MAX_PLANS := 4


## Backward-compatible symmetric rollout used by self-play/training callers.
static func play_game(
	game_state: Dictionary,
	group_a: String,
	group_b: String,
	max_turns: int = DEFAULT_MAX_TURNS,
	max_actions_per_unit: int = DEFAULT_MAX_ACTIONS_PER_UNIT,
	own_max_plans: int = DEFAULT_OWN_MAX_PLANS,
	opponent_max_plans: int = DEFAULT_OPPONENT_MAX_PLANS,
	record_states: bool = false,
	turn_limit_winner: String = ""
) -> Dictionary:
	if max_actions_per_unit <= 0 or own_max_plans <= 0 or opponent_max_plans <= 0:
		return _empty_result(game_state, group_a, group_b)
	var settings := GameplayAI.handwritten_settings(
		max_actions_per_unit,
		own_max_plans,
		max_actions_per_unit,
		opponent_max_plans
	)
	return play_game_with_settings(
		game_state,
		group_a,
		group_b,
		settings,
		settings,
		max_turns,
		record_states,
		turn_limit_winner
	)


## Arena entry point. Each side receives an independent GameplayAI settings
## dictionary while both still plan from the exact same simultaneous pre-turn
## state. This lets us compare search/evaluator/model configurations head-to-head
## without duplicating rollout or game-rule logic.
static func play_game_with_settings(
	game_state: Dictionary,
	group_a: String,
	group_b: String,
	settings_a: Dictionary,
	settings_b: Dictionary,
	max_turns: int = DEFAULT_MAX_TURNS,
	record_states: bool = false,
	turn_limit_winner: String = ""
) -> Dictionary:
	var invalid := _empty_result(game_state, group_a, group_b)
	if group_a.is_empty() or group_b.is_empty() or group_a == group_b:
		return invalid
	if max_turns <= 0:
		return invalid
	if not _has_group(game_state, group_a) or not _has_group(game_state, group_b):
		return invalid
	if not turn_limit_winner.is_empty() and turn_limit_winner not in [group_a, group_b]:
		return invalid

	var state := game_state.duplicate(true)
	var initial_turn_index := int(state.get("turn_index", 0))
	var command_hexes := PureStateCommandHexRules.ensure_command_hexes(state, group_a, group_b)
	var command_occupants := PureStateCommandHexRules.initial_occupants(state, group_a, group_b, command_hexes)
	var history: Array = []
	var non_progress_streak := 0
	var initial_outcome := _outcome(state, group_a, group_b)
	if bool(initial_outcome.get("terminal", false)):
		return _build_result(true, "terminal", str(initial_outcome.get("winner", "")), 0, state, history, group_a, group_b, "elimination")

	for turn_index in range(max_turns):
		# Match the turn feature exported by PureStateTrainingData. Both agents
		# receive the same clock; simulated leaves represent the following turn.
		state["turn_index"] = initial_turn_index + turn_index
		# Both searches intentionally read the same pre-turn state. Neither side gets
		# privileged knowledge of the other side's selected simultaneous action.
		var decision_a := GameplayAI.choose_actions(
			state,
			group_a,
			group_b,
			settings_a
		)
		var decision_b := GameplayAI.choose_actions(
			state,
			group_b,
			group_a,
			settings_b
		)

		if not bool(decision_a.get("valid", false)) or not bool(decision_b.get("valid", false)):
			var failed_history := history.duplicate(true)
			var failed_diagnostics_a: Dictionary = decision_a.get("diagnostics", {})
			var failed_diagnostics_b: Dictionary = decision_b.get("diagnostics", {})
			var failed_record := {
				"turn": turn_index + 1,
				"search_a_valid": bool(decision_a.get("valid", false)),
				"search_b_valid": bool(decision_b.get("valid", false)),
			}
			_add_search_metrics(failed_record, group_a, failed_diagnostics_a)
			_add_search_metrics(failed_record, group_b, failed_diagnostics_b)
			if record_states:
				failed_record["state_before"] = state.duplicate(true)
			failed_history.append(failed_record)
			return _build_result(false, "search_failed", "", turn_index, state, failed_history, group_a, group_b)

		var actions_a: Array = (decision_a.get("actions", []) as Array).duplicate(true)
		var actions_b: Array = (decision_b.get("actions", []) as Array).duplicate(true)
		var diagnostics_a: Dictionary = decision_a.get("diagnostics", {})
		var diagnostics_b: Dictionary = decision_b.get("diagnostics", {})
		var submitted := _submitted_actions(state, group_a, actions_a, group_b, actions_b)
		var simulation := PureStateSimulator.simulate_turn(state, submitted)
		var next_state: Dictionary = simulation.get("next_state", {})
		next_state["turn_index"] = initial_turn_index + turn_index + 1
		if next_state.is_empty():
			return _build_result(false, "simulation_failed", "", turn_index, state, history, group_a, group_b)
		next_state["command_hexes"] = command_hexes.duplicate(true)

		# Objective capture is evaluated only after the full simultaneous turn has
		# resolved. Requiring the same unit id at consecutive boundaries enforces a
		# complete-turn hold instead of awarding capture on entry.
		var capture := PureStateCommandHexRules.capture_after_complete_turn(
			next_state,
			group_a,
			group_b,
			command_hexes,
			command_occupants
		)
		var capture_completed: Dictionary = capture.get("completed", {})
		var next_command_occupants: Dictionary = capture.get("occupants", {})
		var captured_by_a := bool(capture_completed.get(group_a, false))
		var captured_by_b := bool(capture_completed.get(group_b, false))

		# Track repeated turns that fail to change strategically relevant state. We
		# deliberately ignore energy/effect ticking so an empty predictive attack is
		# still visible as non-progress, while movement, HP/unit changes, resource
		# changes, production, and completed objective holds reset the streak.
		var made_strategic_progress := _strategic_state_changed(state, next_state) or captured_by_a or captured_by_b
		if made_strategic_progress:
			non_progress_streak = 0
		else:
			non_progress_streak += 1

		var counts := _alive_counts(next_state, group_a, group_b)
		var turn_record := {
			"turn": turn_index + 1,
			"alive_after": counts,
			"execution": (simulation.get("recording", {}) as Dictionary).duplicate(true),
			"command_hexes": command_hexes.duplicate(true),
			"command_hex_occupants_after": next_command_occupants.duplicate(true),
			"command_hex_capture_completed": capture_completed.duplicate(true),
			"made_strategic_progress": made_strategic_progress,
			"non_progress_streak": non_progress_streak,
		}
		turn_record[group_a + "_actions"] = actions_a
		turn_record[group_b + "_actions"] = actions_b
		turn_record[group_a + "_worst_case_score"] = float(diagnostics_a.get("best_worst_case_score", 0.0))
		turn_record[group_b + "_worst_case_score"] = float(diagnostics_b.get("best_worst_case_score", 0.0))
		_add_search_metrics(turn_record, group_a, diagnostics_a)
		_add_search_metrics(turn_record, group_b, diagnostics_b)
		if record_states:
			turn_record["state_before"] = state.duplicate(true)
			turn_record["state_after"] = next_state.duplicate(true)
		history.append(turn_record)
		state = next_state
		command_occupants = next_command_occupants

		# The simultaneous-capture draw is checked before the existing elimination
		# rule because it is an explicit same-turn objective outcome.
		if captured_by_a and captured_by_b:
			return _build_result(
				true,
				"terminal",
				"",
				turn_index + 1,
				state,
				history,
				group_a,
				group_b,
				"simultaneous_command_hex_capture"
			)

		var outcome := _outcome(state, group_a, group_b)
		if bool(outcome.get("terminal", false)):
			return _build_result(
				true,
				"terminal",
				str(outcome.get("winner", "")),
				turn_index + 1,
				state,
				history,
				group_a,
				group_b,
				"elimination"
			)

		if captured_by_a:
			return _build_result(
				true,
				"terminal",
				group_a,
				turn_index + 1,
				state,
				history,
				group_a,
				group_b,
				"command_hex_capture"
			)
		if captured_by_b:
			return _build_result(
				true,
				"terminal",
				group_b,
				turn_index + 1,
				state,
				history,
				group_a,
				group_b,
				"command_hex_capture"
			)

	if not turn_limit_winner.is_empty():
		return _build_result(
			true,
			"terminal",
			turn_limit_winner,
			max_turns,
			state,
			history,
			group_a,
			group_b,
			"turn_limit_adjudication"
		)
	return _build_result(true, "turn_limit", "", max_turns, state, history, group_a, group_b, "turn_limit")


static func _add_search_metrics(record: Dictionary, group_name: String, diagnostics: Dictionary) -> void:
	record[group_name + "_search_elapsed_ms"] = float(diagnostics.get("elapsed_ms", 0.0))
	record[group_name + "_search_simulations"] = int(diagnostics.get("simulations_run", 0))


static func _outcome(state: Dictionary, group_a: String, group_b: String) -> Dictionary:
	var counts := _alive_counts(state, group_a, group_b)
	var alive_a := int(counts.get(group_a, 0))
	var alive_b := int(counts.get(group_b, 0))
	if alive_a <= 0 and alive_b <= 0:
		return {"terminal": true, "winner": ""}
	if alive_a <= 0:
		return {"terminal": true, "winner": group_b}
	if alive_b <= 0:
		return {"terminal": true, "winner": group_a}
	return {"terminal": false, "winner": ""}


static func _alive_counts(state: Dictionary, group_a: String, group_b: String) -> Dictionary:
	var counts: Dictionary = {}
	counts[group_a] = _alive_count_for_group(state, group_a)
	counts[group_b] = _alive_count_for_group(state, group_b)
	return counts


static func _alive_count_for_group(state: Dictionary, group_name: String) -> int:
	for group_variant in state.get("groups", []):
		if not (group_variant is Dictionary):
			continue
		var group: Dictionary = group_variant
		if str(group.get("name", "")) != group_name:
			continue
		var count := 0
		for unit_variant in group.get("units", []):
			if unit_variant is Dictionary and int((unit_variant as Dictionary).get("health", 0)) > 0:
				count += 1
		return count
	return 0


static func _strategic_state_changed(before: Dictionary, after: Dictionary) -> bool:
	return _strategic_state_signature(before) != _strategic_state_signature(after)


static func _strategic_state_signature(state: Dictionary) -> Dictionary:
	var groups: Dictionary = {}
	for group_variant in state.get("groups", []):
		if not (group_variant is Dictionary):
			continue
		var group: Dictionary = group_variant
		var name := str(group.get("name", ""))
		if name.is_empty():
			continue
		var units: Array = []
		for unit_variant in group.get("units", []):
			if not (unit_variant is Dictionary):
				continue
			var unit: Dictionary = unit_variant
			if int(unit.get("health", 0)) <= 0:
				continue
			var cell := _cell_from_variant(unit.get("cell", [0, 0]))
			units.append([
				int(unit.get("unit_id", -1)),
				int(unit.get("health", 0)),
				cell.x,
				cell.y,
			])
		units.sort_custom(func(a, b): return int(a[0]) < int(b[0]))
		groups[name] = {
			"units": units,
			"resources": (group.get("resources", {}) as Dictionary).duplicate(true) if group.get("resources", {}) is Dictionary else {},
		}
	return {
		"groups": groups,
		"tile_resources": (state.get("tile_resources", {}) as Dictionary).duplicate(true) if state.get("tile_resources", {}) is Dictionary else {},
	}


static func _max_non_progress_streak(history: Array) -> int:
	var best := 0
	for turn_variant in history:
		if turn_variant is Dictionary:
			best = maxi(best, int((turn_variant as Dictionary).get("non_progress_streak", 0)))
	return best


static func _search_metrics(history: Array, group_a: String, group_b: String) -> Dictionary:
	var result := {
		group_a: {"decisions": 0, "elapsed_ms": 0.0, "max_elapsed_ms": 0.0, "simulations": 0},
		group_b: {"decisions": 0, "elapsed_ms": 0.0, "max_elapsed_ms": 0.0, "simulations": 0},
	}
	for turn_variant in history:
		if not (turn_variant is Dictionary):
			continue
		var turn: Dictionary = turn_variant
		for group_name_variant in [group_a, group_b]:
			var group_name: String = str(group_name_variant)
			var elapsed_key: String = group_name + "_search_elapsed_ms"
			var simulations_key: String = group_name + "_search_simulations"
			if not turn.has(elapsed_key):
				continue
			var metrics: Dictionary = result[group_name]
			var elapsed := float(turn.get(elapsed_key, 0.0))
			metrics["decisions"] = int(metrics.get("decisions", 0)) + 1
			metrics["elapsed_ms"] = float(metrics.get("elapsed_ms", 0.0)) + elapsed
			metrics["max_elapsed_ms"] = maxf(float(metrics.get("max_elapsed_ms", 0.0)), elapsed)
			metrics["simulations"] = int(metrics.get("simulations", 0)) + int(turn.get(simulations_key, 0))
	for group_name_variant in [group_a, group_b]:
		var group_name: String = str(group_name_variant)
		var metrics: Dictionary = result[group_name]
		var decisions := int(metrics.get("decisions", 0))
		metrics["mean_elapsed_ms"] = float(metrics.get("elapsed_ms", 0.0)) / float(decisions) if decisions > 0 else 0.0
	return result


static func _deterministic_history(history: Array) -> Array:
	# Wall-clock timing is useful arena telemetry but cannot be part of the
	# reproducible game record. Keep deterministic simulation counts in history,
	# while elapsed milliseconds remain available through result.search_metrics.
	var clean: Array = history.duplicate(true)
	for turn_variant in clean:
		if not (turn_variant is Dictionary):
			continue
		var turn: Dictionary = turn_variant
		var keys := turn.keys()
		for key_variant in keys:
			var key := str(key_variant)
			if key.ends_with("_search_elapsed_ms"):
				turn.erase(key_variant)
	return clean


static func _cell_from_variant(value: Variant) -> Vector2i:
	if value is Vector2i:
		return value
	if value is Vector2:
		return Vector2i(int(value.x), int(value.y))
	if value is Array and value.size() >= 2:
		return Vector2i(int(value[0]), int(value[1]))
	return Vector2i.ZERO


static func _submitted_actions(
	state: Dictionary,
	group_a: String,
	actions_a: Array,
	group_b: String,
	actions_b: Array
) -> Dictionary:
	var submitted: Dictionary = {}
	for group_variant in state.get("groups", []):
		if group_variant is Dictionary:
			var name := str((group_variant as Dictionary).get("name", ""))
			if not name.is_empty():
				submitted[name] = []
	submitted[group_a] = actions_a.duplicate(true)
	submitted[group_b] = actions_b.duplicate(true)
	return submitted


static func _has_group(state: Dictionary, group_name: String) -> bool:
	for group_variant in state.get("groups", []):
		if group_variant is Dictionary and str((group_variant as Dictionary).get("name", "")) == group_name:
			return true
	return false


static func _build_result(
	valid: bool,
	status: String,
	winner: String,
	turns_played: int,
	state: Dictionary,
	history: Array,
	group_a: String,
	group_b: String,
	termination_reason: String = ""
) -> Dictionary:
	var command_hexes: Dictionary = {}
	var command_variant = state.get("command_hexes", {})
	if command_variant is Dictionary:
		command_hexes = command_variant
	return {
		"valid": valid,
		"status": status,
		"winner": winner,
		"termination_reason": termination_reason,
		"turns_played": turns_played,
		"final_state": state.duplicate(true),
		"history": _deterministic_history(history),
		"final_alive_counts": _alive_counts(state, group_a, group_b),
		"command_hexes": command_hexes.duplicate(true),
		"max_non_progress_streak": _max_non_progress_streak(history),
		"search_metrics": _search_metrics(history, group_a, group_b),
	}


static func _empty_result(state: Dictionary, group_a: String, group_b: String) -> Dictionary:
	return _build_result(false, "invalid", "", 0, state, [], group_a, group_b)
