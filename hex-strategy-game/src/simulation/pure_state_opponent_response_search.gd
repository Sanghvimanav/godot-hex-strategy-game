extends RefCounted
class_name PureStateOpponentResponseSearch
## Robust one-turn simultaneous search over bounded own-plan and opponent-plan sets.
##
## Opponent plans are generated first. Their modeled movement destinations are then
## fed back into own proposal generation so legal attacks covering those future
## cells survive even when the cells are empty in the current planning state.
##
## Candidate sourcing also preserves four tactical intent buckets before final
## selection: commit / hold / reposition / disengage.
##
## Rank own plans by:
##   1. highest worst-case evaluation
##   2. highest average evaluation
##   3. highest own proposal score
##   4. deterministic plan signature

const PureStatePlans = preload("res://src/simulation/pure_state_plans.gd")
const PureStatePlanIntents = preload("res://src/simulation/pure_state_plan_intents.gd")
const PureStateCounterConditioning = preload("res://src/simulation/pure_state_counter_conditioning.gd")
const PureStateSimulator = preload("res://src/simulation/pure_state_simulator.gd")
const PureStateEvaluator = preload("res://src/simulation/pure_state_evaluator.gd")
const PureStateNeuralEvaluator = preload("res://src/simulation/pure_state_neural_evaluator.gd")

const EVALUATOR_HANDWRITTEN := "handwritten"
const EVALUATOR_NEURAL := "neural"
const DEFAULT_OWN_MAX_ACTIONS_PER_UNIT := 8
const DEFAULT_OWN_MAX_PLANS := 12
const DEFAULT_OPPONENT_MAX_ACTIONS_PER_UNIT := 10
const DEFAULT_OPPONENT_MAX_PLANS := 8
const SOURCE_POOL_MULTIPLIER := 4


static func search(
	game_state: Dictionary,
	group_name: String,
	opponent_group_name: String,
	own_max_actions_per_unit: int = DEFAULT_OWN_MAX_ACTIONS_PER_UNIT,
	own_max_plans: int = DEFAULT_OWN_MAX_PLANS,
	opponent_max_actions_per_unit: int = DEFAULT_OPPONENT_MAX_ACTIONS_PER_UNIT,
	opponent_max_plans: int = DEFAULT_OPPONENT_MAX_PLANS,
	fixed_other_group_actions: Dictionary = {},
	evaluator_mode: String = EVALUATOR_HANDWRITTEN,
	evaluator_settings: Dictionary = {}
) -> Dictionary:
	var started_usec := Time.get_ticks_usec()
	var invalid := _empty_result(group_name, opponent_group_name, evaluator_mode)
	if group_name.is_empty() or opponent_group_name.is_empty() or group_name == opponent_group_name:
		return invalid
	if evaluator_mode not in [EVALUATOR_HANDWRITTEN, EVALUATOR_NEURAL]:
		invalid["error"] = "unsupported_evaluator"
		return invalid
	if own_max_actions_per_unit <= 0 or own_max_plans <= 0:
		return invalid
	if opponent_max_actions_per_unit <= 0 or opponent_max_plans <= 0:
		return invalid
	if not _has_group(game_state, group_name) or not _has_group(game_state, opponent_group_name):
		return invalid

	var opponent_pool_limit := maxi(opponent_max_plans, opponent_max_plans * SOURCE_POOL_MULTIPLIER)
	var opponent_pool := PureStatePlans.get_candidate_plans(
		game_state,
		opponent_group_name,
		opponent_max_actions_per_unit,
		opponent_pool_limit,
		true
	)
	var opponent_candidates := PureStatePlanIntents.select_opponent_candidates(
		game_state,
		opponent_group_name,
		opponent_pool,
		opponent_max_plans
	)
	if opponent_candidates.is_empty():
		opponent_candidates = [{"actions": [], "proposal_score": 0.0, "intent": PureStatePlanIntents.HOLD}]
	var counter_condition_cells := PureStateCounterConditioning.get_condition_cells(opponent_candidates)

	var own_pool_limit := maxi(own_max_plans, own_max_plans * SOURCE_POOL_MULTIPLIER)
	var own_base_pool := PureStatePlans.get_candidate_plans(
		game_state,
		group_name,
		own_max_actions_per_unit,
		own_pool_limit,
		true
	)
	var own_pool := PureStateCounterConditioning.inject_counter_plans(
		game_state,
		group_name,
		own_base_pool,
		counter_condition_cells
	)
	var counter_injected_source_candidates := maxi(0, own_pool.size() - own_base_pool.size())
	var own_candidates := PureStatePlanIntents.select_own_candidates(
		game_state,
		group_name,
		own_pool,
		own_max_plans
	)
	if own_candidates.is_empty():
		return invalid

	var own_intent_counts := PureStatePlanIntents.count_intents(own_candidates)
	var opponent_intent_counts := PureStatePlanIntents.count_intents(opponent_candidates)
	var ranked: Array = []
	var best_full: Dictionary = {}
	var simulations_run := 0
	var pruned_candidates := 0
	var use_neural_batch := (
		evaluator_mode == EVALUATOR_NEURAL
		and bool(evaluator_settings.get("batch_evaluation", true))
	)
	var neural_batch_calls := 0
	var neural_batch_leaf_requests := 0
	var neural_unique_runtime_states := 0
	var neural_cache_hits := 0
	var neural_runtime_ms := 0.0

	for own_variant in own_candidates:
		if not (own_variant is Dictionary):
			continue
		var own: Dictionary = own_variant
		var own_actions: Array = own.get("actions", []).duplicate(true)
		var response_count := 0
		var sum_evaluation := 0.0
		var worst_result: Dictionary = {}
		var pruned := false

		if use_neural_batch:
			var leaf_entries: Array = []
			var leaf_states: Array = []
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
				leaf_entries.append({
					"opponent": opponent,
					"opponent_actions": opponent_actions,
					"next_state": next_state,
					"recording": simulation.get("recording", {}),
				})
				leaf_states.append(next_state)

			# Batched neural evaluation simulates every opponent leaf before minimax
			# pruning is examined. Count the actual simulations performed, not only
			# the responses later consumed by the ranking loop.
			simulations_run += leaf_states.size()
			var breakdowns := PureStateNeuralEvaluator.evaluate_many_breakdowns(
				leaf_states,
				group_name,
				opponent_group_name,
				evaluator_settings
			)
			neural_batch_calls += 1
			neural_batch_leaf_requests += leaf_states.size()
			if breakdowns.size() != leaf_entries.size():
				invalid["error"] = "evaluation_failed"
				invalid["evaluation_error"] = "neural_batch_size_mismatch"
				invalid["simulations_run"] = simulations_run
				invalid["elapsed_ms"] = float(Time.get_ticks_usec() - started_usec) / 1000.0
				return invalid
			if not breakdowns.is_empty() and breakdowns[0] is Dictionary:
				var batch_diag: Dictionary = (breakdowns[0] as Dictionary).get("neural_batch", {})
				neural_unique_runtime_states += int(batch_diag.get("unique_runtime_states", 0))
				neural_cache_hits += int(batch_diag.get("cache_hits", 0))
				var runtime_timing: Dictionary = batch_diag.get("runtime_timing_ms", {})
				neural_runtime_ms += float(runtime_timing.get("total_ms", 0.0))

			for leaf_index in range(leaf_entries.size()):
				var entry: Dictionary = leaf_entries[leaf_index]
				var breakdown: Dictionary = breakdowns[leaf_index]
				if not bool(breakdown.get("valid", false)):
					invalid["error"] = "evaluation_failed"
					invalid["evaluation_error"] = str(breakdown.get("error", ""))
					invalid["simulations_run"] = simulations_run
					invalid["elapsed_ms"] = float(Time.get_ticks_usec() - started_usec) / 1000.0
					return invalid
				var opponent: Dictionary = entry.get("opponent", {})
				var evaluation := float(breakdown.get("total", 0.0))
				var response := {
					"evaluation_score": evaluation,
					"opponent_actions": (entry.get("opponent_actions", []) as Array).duplicate(true),
					"opponent_proposal_score": float(opponent.get("proposal_score", 0.0)),
					"opponent_intent": str(opponent.get("intent", "")),
					"evaluation_breakdown": breakdown,
				}
				response_count += 1
				sum_evaluation += evaluation
				if worst_result.is_empty() or _response_is_worse(response, worst_result):
					worst_result = response.duplicate(true)
					worst_result["next_state"] = (entry.get("next_state", {}) as Dictionary).duplicate(true)
					worst_result["recording"] = entry.get("recording", {})
				if not best_full.is_empty():
					var current_worst := float(worst_result.get("evaluation_score", 0.0))
					var best_worst := float(best_full.get("worst_case_score", 0.0))
					if current_worst < best_worst and not is_equal_approx(current_worst, best_worst):
						pruned = true
						pruned_candidates += 1
						break
		else:
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
				var breakdown := _evaluate_leaf(
					next_state,
					group_name,
					opponent_group_name,
					evaluator_mode,
					evaluator_settings
				)
				if not bool(breakdown.get("valid", false)):
					invalid["error"] = "evaluation_failed"
					invalid["evaluation_error"] = str(breakdown.get("error", ""))
					invalid["simulations_run"] = simulations_run + 1
					invalid["elapsed_ms"] = float(Time.get_ticks_usec() - started_usec) / 1000.0
					return invalid
				var evaluation := float(breakdown.get("total", 0.0))
				var response := {
					"evaluation_score": evaluation,
					"opponent_actions": opponent_actions,
					"opponent_proposal_score": float(opponent.get("proposal_score", 0.0)),
					"opponent_intent": str(opponent.get("intent", "")),
					"evaluation_breakdown": breakdown,
				}
				response_count += 1
				simulations_run += 1
				sum_evaluation += evaluation
				if worst_result.is_empty() or _response_is_worse(response, worst_result):
					worst_result = response.duplicate(true)
					worst_result["next_state"] = next_state
					worst_result["recording"] = simulation.get("recording", {})
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
			"intent": str(own.get("intent", "")),
			"proposal_score": float(own.get("proposal_score", 0.0)),
			"counter_conditioned": bool(own.get("counter_conditioned", false)),
			"counter_cells": (own.get("counter_cells", []) as Array).duplicate(true),
			"worst_case_score": float(worst_result.get("evaluation_score", 0.0)),
			"average_score": sum_evaluation / float(response_count),
			"average_complete": not pruned,
			"pruned": pruned,
			"responses_considered": response_count,
			"responses_total": opponent_candidates.size(),
			"worst_response_actions": (worst_result.get("opponent_actions", []) as Array).duplicate(true),
			"worst_response_intent": str(worst_result.get("opponent_intent", "")),
			"worst_response_proposal_score": float(worst_result.get("opponent_proposal_score", 0.0)),
			"worst_evaluation_breakdown": (worst_result.get("evaluation_breakdown", {}) as Dictionary).duplicate(true),
		}
		ranked.append(result)

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
		"error": "",
		"evaluator": evaluator_mode,
		"group_name": group_name,
		"opponent_group_name": opponent_group_name,
		"own_base_source_candidates": own_base_pool.size(),
		"own_source_candidates": own_pool.size(),
		"counter_injected_source_candidates": counter_injected_source_candidates,
		"counter_condition_cells": counter_condition_cells.duplicate(true),
		"opponent_source_candidates": opponent_pool.size(),
		"own_candidates_considered": ranked.size(),
		"opponent_candidates_considered": opponent_candidates.size(),
		"own_candidate_intent_counts": own_intent_counts,
		"opponent_candidate_intent_counts": opponent_intent_counts,
		"simulations_run": simulations_run,
		"pruned_candidates": pruned_candidates,
		"elapsed_ms": elapsed_ms,
		"neural_batch_evaluation": use_neural_batch,
		"neural_batch_calls": neural_batch_calls,
		"neural_batch_leaf_requests": neural_batch_leaf_requests,
		"neural_unique_runtime_states": neural_unique_runtime_states,
		"neural_cache_hits": neural_cache_hits,
		"neural_runtime_ms": neural_runtime_ms,
		"best_actions": (best_full.get("actions", []) as Array).duplicate(true),
		"best_intent": str(best_full.get("intent", "")),
		"best_counter_conditioned": bool(best_full.get("counter_conditioned", false)),
		"best_counter_cells": (best_full.get("counter_cells", []) as Array).duplicate(true),
		"best_proposal_score": float(best_full.get("proposal_score", 0.0)),
		"best_worst_case_score": float(best_full.get("worst_case_score", 0.0)),
		"best_average_score": float(best_full.get("average_score", 0.0)),
		"best_worst_response_actions": (best_full.get("worst_response_actions", []) as Array).duplicate(true),
		"best_worst_response_intent": str(best_full.get("worst_response_intent", "")),
		"best_worst_response_proposal_score": float(best_full.get("worst_response_proposal_score", 0.0)),
		"best_worst_evaluation_breakdown": (best_full.get("worst_evaluation_breakdown", {}) as Dictionary).duplicate(true),
		"best_worst_next_state": (best_full.get("worst_next_state", {}) as Dictionary).duplicate(true),
		"best_worst_recording": (best_full.get("worst_recording", {}) as Dictionary).duplicate(true),
		"ranked_results": ranked,
	}


static func _evaluate_leaf(
	game_state: Dictionary,
	group_name: String,
	opponent_group_name: String,
	evaluator_mode: String,
	evaluator_settings: Dictionary
) -> Dictionary:
	if evaluator_mode == EVALUATOR_NEURAL:
		return PureStateNeuralEvaluator.evaluate_breakdown(
			game_state,
			group_name,
			opponent_group_name,
			evaluator_settings
		)
	return PureStateEvaluator.evaluate_breakdown(game_state, group_name)


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


static func _empty_result(
	group_name: String,
	opponent_group_name: String,
	evaluator_mode: String = EVALUATOR_HANDWRITTEN
) -> Dictionary:
	return {
		"valid": false,
		"error": "",
		"evaluation_error": "",
		"evaluator": evaluator_mode,
		"group_name": group_name,
		"opponent_group_name": opponent_group_name,
		"own_base_source_candidates": 0,
		"own_source_candidates": 0,
		"counter_injected_source_candidates": 0,
		"counter_condition_cells": [],
		"opponent_source_candidates": 0,
		"own_candidates_considered": 0,
		"opponent_candidates_considered": 0,
		"own_candidate_intent_counts": {},
		"opponent_candidate_intent_counts": {},
		"simulations_run": 0,
		"pruned_candidates": 0,
		"elapsed_ms": 0.0,
		"neural_batch_evaluation": false,
		"neural_batch_calls": 0,
		"neural_batch_leaf_requests": 0,
		"neural_unique_runtime_states": 0,
		"neural_cache_hits": 0,
		"neural_runtime_ms": 0.0,
		"best_actions": [],
		"best_intent": "",
		"best_counter_conditioned": false,
		"best_counter_cells": [],
		"best_proposal_score": 0.0,
		"best_worst_case_score": 0.0,
		"best_average_score": 0.0,
		"best_worst_response_actions": [],
		"best_worst_response_intent": "",
		"best_worst_response_proposal_score": 0.0,
		"best_worst_evaluation_breakdown": {},
		"best_worst_next_state": {},
		"best_worst_recording": {},
		"ranked_results": [],
	}
