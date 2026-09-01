extends RefCounted
class_name PureStateGameRollout
## Simple deterministic full-game rollout for two AI-controlled groups.
##
## Each turn both groups plan from the same pre-turn state using bounded
## opponent-response search. Their selected plans are then resolved simultaneously
## by the pure-state simulator. The rollout stops on elimination, search failure,
## or a caller-provided turn cap.

const PureStateOpponentResponseSearch = preload("res://src/simulation/pure_state_opponent_response_search.gd")
const PureStateSimulator = preload("res://src/simulation/pure_state_simulator.gd")

const DEFAULT_MAX_TURNS := 12
const DEFAULT_MAX_ACTIONS_PER_UNIT := 8
const DEFAULT_OWN_MAX_PLANS := 4
const DEFAULT_OPPONENT_MAX_PLANS := 4


static func play_game(
	game_state: Dictionary,
	group_a: String,
	group_b: String,
	max_turns: int = DEFAULT_MAX_TURNS,
	max_actions_per_unit: int = DEFAULT_MAX_ACTIONS_PER_UNIT,
	own_max_plans: int = DEFAULT_OWN_MAX_PLANS,
	opponent_max_plans: int = DEFAULT_OPPONENT_MAX_PLANS
) -> Dictionary:
	var invalid := _empty_result(game_state, group_a, group_b)
	if group_a.is_empty() or group_b.is_empty() or group_a == group_b:
		return invalid
	if max_turns <= 0 or max_actions_per_unit <= 0 or own_max_plans <= 0 or opponent_max_plans <= 0:
		return invalid
	if not _has_group(game_state, group_a) or not _has_group(game_state, group_b):
		return invalid

	var state := game_state.duplicate(true)
	var history: Array = []
	var initial_outcome := _outcome(state, group_a, group_b)
	if bool(initial_outcome.get("terminal", false)):
		return _build_result(true, "terminal", str(initial_outcome.get("winner", "")), 0, state, history, group_a, group_b)

	for turn_index in range(max_turns):
		# Both searches intentionally read the same pre-turn state. Neither side gets
		# privileged knowledge of the other side's selected simultaneous action.
		var search_a := PureStateOpponentResponseSearch.search(
			state,
			group_a,
			group_b,
			max_actions_per_unit,
			own_max_plans,
			max_actions_per_unit,
			opponent_max_plans
		)
		var search_b := PureStateOpponentResponseSearch.search(
			state,
			group_b,
			group_a,
			max_actions_per_unit,
			own_max_plans,
			max_actions_per_unit,
			opponent_max_plans
		)

		if not bool(search_a.get("valid", false)) or not bool(search_b.get("valid", false)):
			var failed_history := history.duplicate(true)
			failed_history.append({
				"turn": turn_index + 1,
				"search_a_valid": bool(search_a.get("valid", false)),
				"search_b_valid": bool(search_b.get("valid", false)),
			})
			return _build_result(false, "search_failed", "", turn_index, state, failed_history, group_a, group_b)

		var actions_a: Array = (search_a.get("best_actions", []) as Array).duplicate(true)
		var actions_b: Array = (search_b.get("best_actions", []) as Array).duplicate(true)
		var submitted := _submitted_actions(state, group_a, actions_a, group_b, actions_b)
		var simulation := PureStateSimulator.simulate_turn(state, submitted)
		var next_state: Dictionary = simulation.get("next_state", {})
		if next_state.is_empty():
			return _build_result(false, "simulation_failed", "", turn_index, state, history, group_a, group_b)

		var counts := _alive_counts(next_state, group_a, group_b)
		var turn_record := {
			"turn": turn_index + 1,
			"alive_after": counts,
		}
		turn_record[group_a + "_actions"] = actions_a
		turn_record[group_b + "_actions"] = actions_b
		turn_record[group_a + "_worst_case_score"] = float(search_a.get("best_worst_case_score", 0.0))
		turn_record[group_b + "_worst_case_score"] = float(search_b.get("best_worst_case_score", 0.0))
		history.append(turn_record)
		state = next_state

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
				group_b
			)

	return _build_result(true, "turn_limit", "", max_turns, state, history, group_a, group_b)


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
	group_b: String
) -> Dictionary:
	return {
		"valid": valid,
		"status": status,
		"winner": winner,
		"turns_played": turns_played,
		"final_state": state.duplicate(true),
		"history": history.duplicate(true),
		"final_alive_counts": _alive_counts(state, group_a, group_b),
	}


static func _empty_result(state: Dictionary, group_a: String, group_b: String) -> Dictionary:
	return _build_result(false, "invalid", "", 0, state, [], group_a, group_b)
