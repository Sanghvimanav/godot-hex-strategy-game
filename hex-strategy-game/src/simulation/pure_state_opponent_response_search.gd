extends RefCounted
class_name PureStateOpponentResponseSearch
## Robust one-turn simultaneous search over bounded own-plan and opponent-plan sets.
##
## For each candidate own plan, simulate it against generated opponent plans.
## Rank own plans by:
##   1. highest worst-case evaluation
##   2. highest average evaluation
##   3. highest own proposal score
##   4. deterministic plan signature
##
## Once a completed candidate establishes the current best worst-case score, later
## candidates are cut off as soon as one response makes their worst-case strictly
## worse. That branch cannot recover under minimax ranking, so further simulations
## would not change the selected plan.

const PureStatePlans = preload("res://src/simulation/pure_state_plans.gd")
const PureStateSimulator = preload("res://src/simulation/pure_state_simulator.gd")
const PureStateEvaluator = preload("res://src/simulation/pure_state_evaluator.gd")

const DEFAULT_OWN_MAX_ACTIONS_PER_UNIT := 8
const DEFAULT_OWN_MAX_PLANS := 12
const DEFAULT_OPPONENT_MAX_ACTIONS_PER_UNIT := 10
const DEFAULT_OPPONENT_MAX_PLANS := 8


static func search(
	game_state: Dictionary,
	group_name: String,
	opponent_group_name: String,
	own_max_actions_per_unit: int = DEFAULT_OWN_MAX_ACTIONS_PER_UNIT,
	own_max_plans: int = DEFAULT_OWN_MAX_PLANS,
	opponent_max_actions_per_unit: int = DEFAULT_OPPONENT_MAX_ACTIONS_PER_UNIT,
	opponent_max_plans: int = DEFAULT_OPPONENT_MAX_PLANS,
	fixed_other_group_actions: Dictionary = {}
) -> Dictionary:
	var started_usec := Time.get_ticks_usec()
	var invalid := _empty_result(group_name, opponent_group_name)
	if group_name.is_empty() or opponent_group_name.is_empty() or group_name == opponent_group_name:
		return invalid
	if own_max_actions_per_unit <= 0 or own_max_plans <= 0:
		return invalid
	if opponent_max_actions_per_unit <= 0 or opponent_max_plans <= 0:
		return invalid
	if not _has_group(game_state, group_name) or not _has_group(game_state, opponent_group_name):
		return invalid

	var own_candidates := PureStatePlans.get_candidate_plans(
		game_state,
		group_name,
		own_max_actions_per_unit,
		own_max_plans
	)
	if own_candidates.is_empty():
		return invalid

	var opponent_candidates := PureStatePlans.get_candidate_plans(
		game_state,
		opponent_group_name,
		opponent_max_actions_per_unit,
		opponent_max_plans
	)
	if opponent_candidates.is_empty():
		opponent_candidates = [{"actions": [], "proposal_score": 0.0}]

	var ranked: Array = []
	var best_full: Dictionary = {}
	var simulations_run := 0
	var pruned_candidates := 0

	for own_variant in own_candidates:
		if not (own_variant is Dictionary):
			continue
		var own: Dictionary = own_variant
		var own_actions: Array = own.get("actions", []).duplicate(true)
		var response_count := 0
		var sum_evaluation := 0.0
		var worst_result: Dictionary = {}
		var pruned := false

		for opponent_variant in opponent_candidates:
			if not (opponent_variant is Dictionary):
				continue
			var opponent: Dictionary = opponent_variant
			var opponent_actions: Array = opponent.get("actions", []).duplicate(true)
			var submitted := _build_player_actions(
				game_state,
				group_name,
				own_actions,
				opponent_group_name,
				opponent_actions,
				fixed_other_group_actions
			)
			var simulation := PureStateSimulator.simulate_turn(game_state, submitted)
			var next_state: Dictionary = simulation.get("next_state", {})
			var breakdown := PureStateEvaluator.evaluate_breakdown(next_state, group_name)
			var evaluation := float(breakdown.get("total", 0.0))
			var response := {
				"evaluation_score": evaluation,
				"opponent_actions": opponent_actions,
				"opponent_proposal_score": float(opponent.get("proposal_score", 0.0)),
				"evaluation_breakdown": breakdown,
			}
			response_count += 1
			simulations_run += 1
			sum_evaluation += evaluation

			if worst_result.is_empty() or _response_is_worse(response, worst_result):
				worst_result = response.duplicate(true)
				# These are already fresh simulator outputs. Keep references while this
				# candidate is active; deep-copy only the final selected candidate.
				worst_result["next_state"] = next_state
				worst_result["recording"] = simulation.get("recording", {})

			# Safe minimax cutoff: once this candidate has a response strictly worse
			# than the best completed candidate's worst case, no unseen response can
			# improve its worst-case value enough to win.
			if not best_full.is_empty():
				var current_worst := float(worst_result.get("evaluation_score", 0.0))
				var best_worst := float(best_full.get("worst_case_score", 0.0))
				if current_worst < best_worst and not is_equal_approx(current_worst, best_worst):
					pruned = true
					pruned_candidates += 1
					break

		if response_count <= 0 or worst_result.is_empty():
			continue

		var result := {
			"actions": own_actions,
			"proposal_score": float(own.get("proposal_score", 0.0)),
			"worst_case_score": float(worst_result.get("evaluation_score", 0.0)),
			"average_score": sum_evaluation / float(response_count),
			"average_complete": not pruned,
			"pruned": pruned,
			"responses_considered": response_count,
			"responses_total": opponent_candidates.size(),
			"worst_response_actions": (worst_result.get("opponent_actions", []) as Array).duplicate(true),
			"worst_response_proposal_score": float(worst_result.get("opponent_proposal_score", 0.0)),
			"worst_evaluation_breakdown": (worst_result.get("evaluation_breakdown", {}) as Dictionary).duplicate(true),
		}
		ranked.append(result)

		# A pruned candidate is already proven unable to beat best_full. Only fully
		# evaluated candidates can become the alpha bound for later candidates.
		if not pruned and (best_full.is_empty() or _own_result_before(result, best_full)):
			best_full = result.duplicate(true)
			best_full["worst_next_state"] = (worst_result.get("next_state", {}) as Dictionary).duplicate(true)
			best_full["worst_recording"] = (worst_result.get("recording", {}) as Dictionary).duplicate(true)

	if ranked.is_empty() or best_full.is_empty():
		return invalid

	ranked.sort_custom(_own_result_before)
	var elapsed_ms := float(Time.get_ticks_usec() - started_usec) / 1000.0
	return {
		"valid": true,
		"group_name": group_name,
		"opponent_group_name": opponent_group_name,
		"own_candidates_considered": ranked.size(),
		"opponent_candidates_considered": opponent_candidates.size(),
		"simulations_run": simulations_run,
		"pruned_candidates": pruned_candidates,
		"elapsed_ms": elapsed_ms,
		"best_actions": (best_full.get("actions", []) as Array).duplicate(true),
		"best_proposal_score": float(best_full.get("proposal_score", 0.0)),
		"best_worst_case_score": float(best_full.get("worst_case_score", 0.0)),
		"best_average_score": float(best_full.get("average_score", 0.0)),
		"best_worst_response_actions": (best_full.get("worst_response_actions", []) as Array).duplicate(true),
		"best_worst_response_proposal_score": float(best_full.get("worst_response_proposal_score", 0.0)),
		"best_worst_evaluation_breakdown": (best_full.get("worst_evaluation_breakdown", {}) as Dictionary).duplicate(true),
		"best_worst_next_state": (best_full.get("worst_next_state", {}) as Dictionary).duplicate(true),
		"best_worst_recording": (best_full.get("worst_recording", {}) as Dictionary).duplicate(true),
		"ranked_results": ranked,
	}


static func _build_player_actions(
	game_state: Dictionary,
	group_name: String,
	own_actions: Array,
	opponent_group_name: String,
	opponent_actions: Array,
	fixed_other_group_actions: Dictionary
) -> Dictionary:
	var submitted: Dictionary = {}
	for group_variant in game_state.get("groups", []):
		if not (group_variant is Dictionary):
			continue
		var name := str(group_variant.get("name", ""))
		if not name.is_empty():
			submitted[name] = []

	for fixed_name_variant in fixed_other_group_actions.keys():
		var fixed_name := str(fixed_name_variant)
		if fixed_name == group_name or fixed_name == opponent_group_name:
			continue
		var fixed_actions = fixed_other_group_actions.get(fixed_name_variant, [])
		if fixed_actions is Array:
			submitted[fixed_name] = fixed_actions.duplicate(true)

	submitted[group_name] = own_actions.duplicate(true)
	submitted[opponent_group_name] = opponent_actions.duplicate(true)
	return submitted


static func _response_is_worse(a: Dictionary, b: Dictionary) -> bool:
	var a_eval := float(a.get("evaluation_score", 0.0))
	var b_eval := float(b.get("evaluation_score", 0.0))
	if not is_equal_approx(a_eval, b_eval):
		return a_eval < b_eval
	var a_proposal := float(a.get("opponent_proposal_score", 0.0))
	var b_proposal := float(b.get("opponent_proposal_score", 0.0))
	if not is_equal_approx(a_proposal, b_proposal):
		return a_proposal > b_proposal
	return _plan_signature(a.get("opponent_actions", [])) < _plan_signature(b.get("opponent_actions", []))


static func _own_result_before(a: Dictionary, b: Dictionary) -> bool:
	var a_worst := float(a.get("worst_case_score", 0.0))
	var b_worst := float(b.get("worst_case_score", 0.0))
	if not is_equal_approx(a_worst, b_worst):
		return a_worst > b_worst
	var a_complete := bool(a.get("average_complete", true))
	var b_complete := bool(b.get("average_complete", true))
	if a_complete != b_complete:
		return a_complete
	var a_average := float(a.get("average_score", 0.0))
	var b_average := float(b.get("average_score", 0.0))
	if not is_equal_approx(a_average, b_average):
		return a_average > b_average
	var a_proposal := float(a.get("proposal_score", 0.0))
	var b_proposal := float(b.get("proposal_score", 0.0))
	if not is_equal_approx(a_proposal, b_proposal):
		return a_proposal > b_proposal
	return _plan_signature(a.get("actions", [])) < _plan_signature(b.get("actions", []))


static func _has_group(game_state: Dictionary, group_name: String) -> bool:
	for group_variant in game_state.get("groups", []):
		if group_variant is Dictionary and str(group_variant.get("name", "")) == group_name:
			return true
	return false


static func _plan_signature(actions: Array) -> String:
	var parts: PackedStringArray = []
	for action_variant in actions:
		if not (action_variant is Dictionary):
			continue
		var action: Dictionary = action_variant
		parts.append("%08d|%s|%s|%s" % [
			int(action.get("unit_id", -1)),
			str(action.get("action_key", "")),
			str(action.get("end_point", [])),
			str(action.get("path", [])),
		])
	return ";".join(parts)


static func _empty_result(group_name: String, opponent_group_name: String) -> Dictionary:
	return {
		"valid": false,
		"group_name": group_name,
		"opponent_group_name": opponent_group_name,
		"own_candidates_considered": 0,
		"opponent_candidates_considered": 0,
		"simulations_run": 0,
		"pruned_candidates": 0,
		"elapsed_ms": 0.0,
		"best_actions": [],
		"best_proposal_score": 0.0,
		"best_worst_case_score": 0.0,
		"best_average_score": 0.0,
		"best_worst_response_actions": [],
		"best_worst_response_proposal_score": 0.0,
		"best_worst_evaluation_breakdown": {},
		"best_worst_next_state": {},
		"best_worst_recording": {},
		"ranked_results": [],
	}
