extends RefCounted
class_name PureStateSelectiveContinuation
## Opt-in, bounded second-turn comparison of two close root plans.
## Both next-turn sides plan from the same simulated pre-turn state. This probes
## each root plan's modeled worst response, not every first-turn response.

const PureStateOpponentResponseSearch = preload("res://src/simulation/pure_state_opponent_response_search.gd")
const PureStateSimulator = preload("res://src/simulation/pure_state_simulator.gd")
const PureStateCommandHexRules = preload("res://src/simulation/pure_state_command_hex_rules.gd")


static func refine(
	game_state: Dictionary,
	group_name: String,
	opponent_group_name: String,
	search_result: Dictionary,
	settings: Dictionary,
	started_usec: int
) -> Dictionary:
	var result := search_result.duplicate(true)
	var diagnostic := {"enabled": true, "applied": false, "reason": ""}
	result["selective_continuation"] = diagnostic
	var ranked: Array = result.get("ranked_results", [])
	if ranked.size() < 2:
		diagnostic["reason"] = "fewer_than_two_plans"
		return result
	if not (settings.get("fixed_other_group_actions", {}) as Dictionary).is_empty():
		diagnostic["reason"] = "fixed_other_groups_not_supported"
		return result
	var evaluator_settings: Dictionary = settings.get("evaluator_settings", {})
	var margin := maxf(0.0, float(evaluator_settings.get("continuation_score_margin", 0.15 if str(settings.get("evaluator", "")) == "neural" else 100.0)))
	var first: Dictionary = ranked[0]
	var second: Dictionary = ranked[1]
	if bool(first.get("pruned", false)) or bool(second.get("pruned", false)):
		diagnostic["reason"] = "incomplete_root_response_coverage"
		return result
	if absf(float(first.get("worst_case_score", 0.0)) - float(second.get("worst_case_score", 0.0))) > margin:
		diagnostic["reason"] = "top_plans_not_close"
		return result

	var budget_ms := float(evaluator_settings.get("decision_time_budget_ms", 0.0))
	if budget_ms <= 0.0:
		diagnostic["reason"] = "requires_decision_budget"
		return result
	var scores: Array[float] = []
	var root_states: Array = []
	var root_recordings: Array = []
	var second_turn_simulations := 0
	var root_simulations := 0
	for candidate in [first, second]:
		var elapsed_ms := float(Time.get_ticks_usec() - started_usec) / 1000.0
		var remaining_ms := budget_ms - elapsed_ms - 500.0
		if remaining_ms < 1000.0:
			diagnostic["reason"] = "insufficient_time"
			return result
		var submitted: Dictionary = (settings.get("fixed_other_group_actions", {}) as Dictionary).duplicate(true)
		submitted[group_name] = (candidate.get("actions", []) as Array).duplicate(true)
		submitted[opponent_group_name] = (candidate.get("worst_response_actions", []) as Array).duplicate(true)
		var simulation := PureStateSimulator.simulate_turn(game_state, submitted)
		root_simulations += 1
		diagnostic["additional_simulations"] = root_simulations + second_turn_simulations
		var next_state: Dictionary = simulation.get("next_state", {})
		if next_state.is_empty():
			diagnostic["reason"] = "root_simulation_failed"
			return result
		next_state["turn_index"] = int(game_state.get("turn_index", 0)) + 1
		if _terminal_after_turn(game_state, next_state, group_name, opponent_group_name):
			diagnostic["reason"] = "terminal_root_response"
			return result
		root_states.append(next_state.duplicate(true))
		root_recordings.append((simulation.get("recording", {}) as Dictionary).duplicate(true))
		var next_settings := evaluator_settings.duplicate(true)
		next_settings["selective_continuation"] = false
		next_settings["score_command_capture"] = true
		# Divide remaining time across the current and as-yet-unsearched root.
		next_settings["decision_time_budget_ms"] = remaining_ms / float(2 - scores.size())
		var continuation := PureStateOpponentResponseSearch.search(
			next_state, group_name, opponent_group_name,
			int(settings.get("own_max_actions_per_unit", 0)),
			mini(2, int(settings.get("own_max_plans", 0))),
			int(settings.get("opponent_max_actions_per_unit", 0)),
			mini(2, int(settings.get("opponent_max_plans", 0))),
			{}, str(settings.get("evaluator", "handwritten")), next_settings
		)
		second_turn_simulations += int(continuation.get("simulations_run", 0))
		diagnostic["additional_simulations"] = root_simulations + second_turn_simulations
		if not bool(continuation.get("valid", false)) or bool(continuation.get("time_budget_exhausted", false)):
			diagnostic["reason"] = "continuation_incomplete"
			return result
		scores.append(float(continuation.get("best_worst_case_score", 0.0)))

	# Compare like-for-like second-turn scores. Keep the one-turn winner on ties.
	diagnostic["applied"] = true
	diagnostic["reason"] = "compared"
	diagnostic["second_turn_scores"] = scores.duplicate()
	diagnostic["second_turn_simulations"] = second_turn_simulations
	if scores[1] > scores[0] and not is_equal_approx(scores[1], scores[0]):
		ranked[0] = second
		ranked[1] = first
		result["ranked_results"] = ranked
		result["best_actions"] = (second.get("actions", []) as Array).duplicate(true)
		result["best_intent"] = str(second.get("intent", ""))
		result["best_counter_conditioned"] = bool(second.get("counter_conditioned", false))
		result["best_counter_cells"] = (second.get("counter_cells", []) as Array).duplicate(true)
		result["best_proposal_score"] = float(second.get("proposal_score", 0.0))
		result["best_worst_case_score"] = float(second.get("worst_case_score", 0.0))
		result["best_average_score"] = float(second.get("average_score", 0.0))
		result["best_worst_response_actions"] = (second.get("worst_response_actions", []) as Array).duplicate(true)
		result["best_worst_response_intent"] = str(second.get("worst_response_intent", ""))
		result["best_worst_response_proposal_score"] = float(second.get("worst_response_proposal_score", 0.0))
		result["best_worst_evaluation_breakdown"] = (second.get("worst_evaluation_breakdown", {}) as Dictionary).duplicate(true)
		result["best_worst_next_state"] = root_states[1]
		result["best_worst_recording"] = root_recordings[1]
		diagnostic["changed_plan"] = true
	else:
		diagnostic["changed_plan"] = false
	result["elapsed_ms"] = float(Time.get_ticks_usec() - started_usec) / 1000.0
	return result


static func _terminal_after_turn(before: Dictionary, after: Dictionary, group_name: String, opponent_group_name: String) -> bool:
	var own_alive := 0
	var opponent_alive := 0
	for group_variant in after.get("groups", []):
		if not (group_variant is Dictionary):
			continue
		var group: Dictionary = group_variant
		for unit_variant in group.get("units", []):
			if unit_variant is Dictionary and int((unit_variant as Dictionary).get("health", 0)) > 0:
				if str(group.get("name", "")) == group_name:
					own_alive += 1
				elif str(group.get("name", "")) == opponent_group_name:
					opponent_alive += 1
	if own_alive == 0 or opponent_alive == 0:
		return true
	var command_variant = before.get("command_hexes", {})
	if not (command_variant is Dictionary):
		return false
	var command_hexes: Dictionary = command_variant
	if not command_hexes.has(group_name) or not command_hexes.has(opponent_group_name):
		return false
	var occupants := PureStateCommandHexRules.initial_occupants(before, group_name, opponent_group_name, command_hexes)
	var capture := PureStateCommandHexRules.capture_after_complete_turn(after, group_name, opponent_group_name, command_hexes, occupants)
	var completed: Dictionary = capture.get("completed", {})
	return bool(completed.get(group_name, false)) or bool(completed.get(opponent_group_name, false))
