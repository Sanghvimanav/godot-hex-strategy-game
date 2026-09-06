extends RefCounted
class_name PureStateSearchDecisionData
## Builds training-ready search-decision records without changing gameplay search.
##
## The recorder intentionally reruns candidate generation after a self-play game has
## completed. That keeps normal gameplay pruning/latency unchanged while preserving
## every candidate x opponent-response leaf for fast 2x2 training decisions.

const PureStatePlans = preload("res://src/simulation/pure_state_plans.gd")
const PureStatePlanIntents = preload("res://src/simulation/pure_state_plan_intents.gd")
const PureStateCounterConditioning = preload("res://src/simulation/pure_state_counter_conditioning.gd")
const PureStateSimulator = preload("res://src/simulation/pure_state_simulator.gd")
const PureStateEvaluator = preload("res://src/simulation/pure_state_evaluator.gd")

const SCHEMA_VERSION := 1
const CANDIDATE_GENERATION_CONTRACT_VERSION := 1
const SOURCE_POOL_MULTIPLIER := 4


static func capture_decision(
	game_state: Dictionary,
	perspective_group: String,
	opponent_group: String,
	selected_actions: Array,
	max_actions_per_unit: int,
	own_max_plans: int,
	opponent_max_plans: int,
	game_id: String,
	turn_index: int,
	game_outcome: Dictionary,
	source_metadata: Dictionary = {}
) -> Dictionary:
	var invalid := {
		"valid": false,
		"error": "",
		"schema_version": SCHEMA_VERSION,
		"game_id": game_id,
		"turn_index": turn_index,
		"perspective_group": perspective_group,
		"opponent_group": opponent_group,
	}
	if game_state.is_empty() or perspective_group.is_empty() or opponent_group.is_empty():
		invalid["error"] = "invalid_state_or_groups"
		return invalid
	if perspective_group == opponent_group:
		invalid["error"] = "same_group"
		return invalid
	if max_actions_per_unit <= 0 or own_max_plans <= 0 or opponent_max_plans <= 0:
		invalid["error"] = "invalid_search_budget"
		return invalid

	# Mirror PureStateOpponentResponseSearch candidate sourcing. The generated
	# selected-plan match is validated by the dataset tool so future sourcing drift
	# fails closed instead of silently producing misaligned training rows.
	var opponent_pool_limit := maxi(opponent_max_plans, opponent_max_plans * SOURCE_POOL_MULTIPLIER)
	var opponent_pool := PureStatePlans.get_candidate_plans(
		game_state,
		opponent_group,
		max_actions_per_unit,
		opponent_pool_limit,
		true
	)
	var opponent_candidates := PureStatePlanIntents.select_opponent_candidates(
		game_state,
		opponent_group,
		opponent_pool,
		opponent_max_plans
	)
	if opponent_candidates.is_empty():
		opponent_candidates = [{
			"actions": [],
			"proposal_score": 0.0,
			"intent": PureStatePlanIntents.HOLD,
		}]

	var counter_condition_cells := PureStateCounterConditioning.get_condition_cells(opponent_candidates)
	var own_pool_limit := maxi(own_max_plans, own_max_plans * SOURCE_POOL_MULTIPLIER)
	var own_base_pool := PureStatePlans.get_candidate_plans(
		game_state,
		perspective_group,
		max_actions_per_unit,
		own_pool_limit,
		true
	)
	var own_pool := PureStateCounterConditioning.inject_counter_plans(
		game_state,
		perspective_group,
		own_base_pool,
		counter_condition_cells
	)
	var own_candidates := PureStatePlanIntents.select_own_candidates(
		game_state,
		perspective_group,
		own_pool,
		own_max_plans
	)
	if own_candidates.is_empty():
		invalid["error"] = "no_own_candidates"
		return invalid

	var opponent_rows: Array = []
	for response_index in range(opponent_candidates.size()):
		var response_variant = opponent_candidates[response_index]
		if not (response_variant is Dictionary):
			continue
		var response: Dictionary = response_variant
		opponent_rows.append({
			"response_index": response_index,
			"actions": (response.get("actions", []) as Array).duplicate(true),
			"intent": str(response.get("intent", "")),
			"proposal_score": float(response.get("proposal_score", 0.0)),
		})

	var selected_signature := _plan_signature(selected_actions)
	var selected_candidate_index := -1
	var candidate_rows: Array = []
	for candidate_index in range(own_candidates.size()):
		var own_variant = own_candidates[candidate_index]
		if not (own_variant is Dictionary):
			continue
		var own: Dictionary = own_variant
		var own_actions: Array = (own.get("actions", []) as Array).duplicate(true)
		var is_selected := _plan_signature(own_actions) == selected_signature
		if is_selected:
			selected_candidate_index = candidate_index

		var leaves: Array = []
		var leaf_scores: Array[float] = []
		for response_index in range(opponent_candidates.size()):
			var response_variant = opponent_candidates[response_index]
			if not (response_variant is Dictionary):
				continue
			var response: Dictionary = response_variant
			var opponent_actions: Array = (response.get("actions", []) as Array).duplicate(true)
			var submitted := _submitted_actions(
				game_state,
				perspective_group,
				own_actions,
				opponent_group,
				opponent_actions
			)
			var simulation := PureStateSimulator.simulate_turn(game_state, submitted)
			var next_state: Dictionary = simulation.get("next_state", {})
			if next_state.is_empty():
				invalid["error"] = "simulation_failed"
				return invalid
			var evaluation := PureStateEvaluator.evaluate_breakdown(next_state, perspective_group)
			if not bool(evaluation.get("valid", false)):
				invalid["error"] = "evaluation_failed"
				return invalid
			var score := float(evaluation.get("total", 0.0))
			leaf_scores.append(score)
			leaves.append({
				"response_index": response_index,
				"opponent_actions": opponent_actions,
				"opponent_intent": str(response.get("intent", "")),
				"opponent_proposal_score": float(response.get("proposal_score", 0.0)),
				"handwritten_evaluation": evaluation.duplicate(true),
				"state_after_first_turn": next_state.duplicate(true),
			})

		var worst_score := 0.0
		var average_score := 0.0
		if not leaf_scores.is_empty():
			worst_score = leaf_scores[0]
			var total := 0.0
			for score in leaf_scores:
				worst_score = minf(worst_score, score)
				total += score
			average_score = total / float(leaf_scores.size())
		candidate_rows.append({
			"candidate_index": candidate_index,
			"actions": own_actions,
			"intent": str(own.get("intent", "")),
			"proposal_score": float(own.get("proposal_score", 0.0)),
			"counter_conditioned": bool(own.get("counter_conditioned", false)),
			"selected": is_selected,
			"handwritten_worst_case_score": worst_score,
			"handwritten_average_score": average_score,
			"responses": leaves,
		})

	return {
		"valid": true,
		"error": "",
		"schema_version": SCHEMA_VERSION,
		"candidate_generation_contract_version": CANDIDATE_GENERATION_CONTRACT_VERSION,
		"game_id": game_id,
		"turn_index": turn_index,
		"perspective_group": perspective_group,
		"opponent_group": opponent_group,
		"starting_state": game_state.duplicate(true),
		"budget": {
			"max_actions_per_unit": max_actions_per_unit,
			"own_max_plans": own_max_plans,
			"opponent_max_plans": opponent_max_plans,
		},
		"candidate_count": candidate_rows.size(),
		"opponent_response_count": opponent_rows.size(),
		"complete_requested_matrix": (
			candidate_rows.size() == own_max_plans
			and opponent_rows.size() == opponent_max_plans
		),
		"selected_actions": selected_actions.duplicate(true),
		"selected_candidate_index": selected_candidate_index,
		"opponent_responses": opponent_rows,
		"candidates": candidate_rows,
		# This is the outcome of the actually played self-play trajectory. It is
		# deliberately not copied onto rejected leaves as a counterfactual target.
		"game_outcome": game_outcome.duplicate(true),
		"source": source_metadata.duplicate(true),
	}


static func _submitted_actions(
	game_state: Dictionary,
	perspective_group: String,
	own_actions: Array,
	opponent_group: String,
	opponent_actions: Array
) -> Dictionary:
	var submitted: Dictionary = {}
	for group_variant in game_state.get("groups", []):
		if not (group_variant is Dictionary):
			continue
		var group_name := str((group_variant as Dictionary).get("name", ""))
		if not group_name.is_empty():
			submitted[group_name] = []
	submitted[perspective_group] = own_actions.duplicate(true)
	submitted[opponent_group] = opponent_actions.duplicate(true)
	return submitted


static func _plan_signature(actions: Array) -> String:
	var signatures: Array[String] = []
	for action_variant in actions:
		if action_variant is Dictionary:
			signatures.append(JSON.stringify(action_variant))
	signatures.sort()
	return "|".join(signatures)
