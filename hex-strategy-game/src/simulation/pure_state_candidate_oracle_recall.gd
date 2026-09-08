extends RefCounted
class_name PureStateCandidateOracleRecall
## Offline diagnostic that separates candidate-generation misses from ranking misses.
##
## Production and intentionally wider searches only SOURCE candidate plans. Their
## union is then evaluated once by the coverage-aware counterfactual answer key so
## every plan is compared under the same opponent policy and continuation semantics.
## A production plan counts as recalled when its oracle-controlled value is within
## a configurable tolerance of the best union plan; exact action equality is not
## required.

const PureStateOpponentResponseSearch = preload("res://src/simulation/pure_state_opponent_response_search.gd")
const PureStateCounterfactualAnswerKey = preload("res://src/simulation/pure_state_counterfactual_answer_key.gd")

const SCHEMA_VERSION := 1
const BENCHMARK_VERSION := 1

const DEFAULT_NEAR_BEST_TOLERANCE := 0.10
const DEFAULT_SEVERE_MISS_THRESHOLD := 0.50
const DEFAULT_ORACLE_OWN_MAX_ACTIONS_PER_UNIT := 12
const DEFAULT_ORACLE_OWN_MAX_PLANS := 48
const DEFAULT_ORACLE_OPPONENT_MAX_ACTIONS_PER_UNIT := 12
const DEFAULT_ORACLE_OPPONENT_MAX_PLANS := 16


static func evaluate_decision(
	game_state: Dictionary,
	perspective_group: String,
	opponent_group: String,
	decision_id: String,
	config: Dictionary = {}
) -> Dictionary:
	var started_usec := Time.get_ticks_usec()
	var invalid := _empty_result(decision_id, perspective_group, opponent_group)
	if game_state.is_empty() or decision_id.is_empty():
		invalid["error"] = "invalid_state_or_decision_id"
		return invalid
	if perspective_group.is_empty() or opponent_group.is_empty() or perspective_group == opponent_group:
		invalid["error"] = "invalid_groups"
		return invalid

	var production_budget := {
		"own_max_actions_per_unit": maxi(1, int(config.get(
			"production_own_max_actions_per_unit",
			config.get("own_max_actions_per_unit", PureStateOpponentResponseSearch.DEFAULT_OWN_MAX_ACTIONS_PER_UNIT)
		))),
		"own_max_plans": maxi(1, int(config.get(
			"production_own_max_plans",
			config.get("own_max_plans", PureStateOpponentResponseSearch.DEFAULT_OWN_MAX_PLANS)
		))),
		"opponent_max_actions_per_unit": maxi(1, int(config.get(
			"production_opponent_max_actions_per_unit",
			config.get("opponent_max_actions_per_unit", PureStateOpponentResponseSearch.DEFAULT_OPPONENT_MAX_ACTIONS_PER_UNIT)
		))),
		"opponent_max_plans": maxi(1, int(config.get(
			"production_opponent_max_plans",
			config.get("opponent_max_plans", PureStateOpponentResponseSearch.DEFAULT_OPPONENT_MAX_PLANS)
		))),
	}
	var oracle_budget := {
		"own_max_actions_per_unit": maxi(
			int(production_budget.own_max_actions_per_unit),
			int(config.get("oracle_own_max_actions_per_unit", DEFAULT_ORACLE_OWN_MAX_ACTIONS_PER_UNIT))
		),
		"own_max_plans": maxi(
			int(production_budget.own_max_plans),
			int(config.get("oracle_own_max_plans", DEFAULT_ORACLE_OWN_MAX_PLANS))
		),
		"opponent_max_actions_per_unit": maxi(
			int(production_budget.opponent_max_actions_per_unit),
			int(config.get("oracle_opponent_max_actions_per_unit", DEFAULT_ORACLE_OPPONENT_MAX_ACTIONS_PER_UNIT))
		),
		"opponent_max_plans": maxi(
			int(production_budget.opponent_max_plans),
			int(config.get("oracle_opponent_max_plans", DEFAULT_ORACLE_OPPONENT_MAX_PLANS))
		),
	}

	var production_search := _run_search(game_state, perspective_group, opponent_group, production_budget)
	if not bool(production_search.get("valid", false)):
		invalid["error"] = "production_search_failed"
		invalid["production_search"] = _search_diagnostics(production_search, production_budget)
		return invalid
	var oracle_search := _run_search(game_state, perspective_group, opponent_group, oracle_budget)
	if not bool(oracle_search.get("valid", false)):
		invalid["error"] = "oracle_search_failed"
		invalid["production_search"] = _search_diagnostics(production_search, production_budget)
		invalid["oracle_search"] = _search_diagnostics(oracle_search, oracle_budget)
		return invalid

	var production_signatures := _signature_set_from_search(production_search)
	var oracle_signatures := _signature_set_from_search(oracle_search)
	var union_candidates := _union_candidates(production_search, oracle_search)
	if union_candidates.is_empty():
		invalid["error"] = "empty_candidate_union"
		return invalid

	var evaluation_config := config.duplicate(true)
	evaluation_config["own_candidates"] = union_candidates
	evaluation_config["include_states"] = false
	# The answer key builds this opponent policy once from the pre-turn state and
	# reuses it for every own candidate. Widen it with the teacher budget by default.
	evaluation_config["opponent_policy_max_actions_per_unit"] = int(config.get(
		"oracle_value_opponent_max_actions_per_unit",
		oracle_budget.opponent_max_actions_per_unit
	))
	evaluation_config["opponent_policy_max_plans"] = int(config.get(
		"oracle_value_opponent_max_plans",
		oracle_budget.opponent_max_plans
	))
	evaluation_config["opponent_policy_response_max_actions_per_unit"] = int(config.get(
		"oracle_value_response_max_actions_per_unit",
		oracle_budget.own_max_actions_per_unit
	))
	evaluation_config["opponent_policy_response_max_plans"] = int(config.get(
		"oracle_value_response_max_plans",
		oracle_budget.own_max_plans
	))

	var evaluated := PureStateCounterfactualAnswerKey.evaluate_decision(
		game_state,
		perspective_group,
		opponent_group,
		decision_id,
		evaluation_config
	)
	if not bool(evaluated.get("valid", false)):
		invalid["error"] = "oracle_value_evaluation_failed"
		return invalid

	var selected_signature := plan_signature(production_search.get("best_actions", []))
	var analysis := analyze_evaluated_candidates(
		evaluated.get("candidate_results", []) as Array,
		production_signatures,
		oracle_signatures,
		selected_signature,
		float(config.get("near_best_tolerance", DEFAULT_NEAR_BEST_TOLERANCE)),
		float(config.get("severe_miss_threshold", DEFAULT_SEVERE_MISS_THRESHOLD))
	)
	if not bool(analysis.get("valid", false)):
		invalid["error"] = str(analysis.get("error", "candidate_analysis_failed"))
		return invalid

	var loss_stage_probes: Dictionary = {
		"status": "not_needed",
		"first_recovery_probe": "production",
	}
	if bool(analysis.get("candidate_generation_failure", false)):
		loss_stage_probes = _diagnose_loss_stage(
			game_state,
			perspective_group,
			opponent_group,
			str(analysis.get("oracle_best_plan_signature", "")),
			production_budget,
			oracle_budget
		)

	return {
		"valid": true,
		"error": "",
		"schema_version": SCHEMA_VERSION,
		"benchmark_version": BENCHMARK_VERSION,
		"decision_id": decision_id,
		"perspective_group": perspective_group,
		"opponent_group": opponent_group,
		"value_semantics": "full_mixture_midpoint_of_search_policy_terminal_return_with_unresolved_bounds_v2",
		"near_best_tolerance": float(config.get("near_best_tolerance", DEFAULT_NEAR_BEST_TOLERANCE)),
		"severe_miss_threshold": float(config.get("severe_miss_threshold", DEFAULT_SEVERE_MISS_THRESHOLD)),
		"production_search": _search_diagnostics(production_search, production_budget),
		"oracle_search": _search_diagnostics(oracle_search, oracle_budget),
		"candidate_union_count": union_candidates.size(),
		"analysis": analysis,
		"loss_stage_probes": loss_stage_probes,
		"answer_key_assumptions": (evaluated.get("assumptions", {}) as Dictionary).duplicate(true),
		"elapsed_ms": float(Time.get_ticks_usec() - started_usec) / 1000.0,
	}


## Pure metric helper used by unit tests and downstream analysis. Candidate identity
## is only used for membership/selected-plan lookup. Recall itself is VALUE based.
static func analyze_evaluated_candidates(
	candidate_results: Array,
	production_signatures: Dictionary,
	oracle_signatures: Dictionary,
	selected_signature: String,
	near_best_tolerance: float = DEFAULT_NEAR_BEST_TOLERANCE,
	severe_miss_threshold: float = DEFAULT_SEVERE_MISS_THRESHOLD
) -> Dictionary:
	var rows: Array = []
	for candidate_variant in candidate_results:
		if not (candidate_variant is Dictionary):
			continue
		var candidate: Dictionary = candidate_variant
		var actions: Array = (candidate.get("actions", []) as Array).duplicate(true)
		var signature := plan_signature(actions)
		var estimate: Dictionary = candidate.get("estimate", {})
		var lower := float(estimate.get("full_mixture_lower_bound", -1.0))
		var upper := float(estimate.get("full_mixture_upper_bound", 1.0))
		var midpoint := float(estimate.get("full_mixture_midpoint", 0.5 * (lower + upper)))
		rows.append({
			"candidate_id": str(candidate.get("candidate_id", "")),
			"plan_signature": signature,
			"actions": actions,
			"value": midpoint,
			"value_lower_bound": lower,
			"value_upper_bound": upper,
			"labeled_weight_fraction": float(estimate.get("labeled_weight_fraction", 0.0)),
			"production_member": production_signatures.has(signature),
			"oracle_search_member": oracle_signatures.has(signature),
		})
	if rows.is_empty():
		return {"valid": false, "error": "no_evaluated_candidates"}

	rows.sort_custom(func(a, b):
		var a_value := float((a as Dictionary).get("value", -INF))
		var b_value := float((b as Dictionary).get("value", -INF))
		if not is_equal_approx(a_value, b_value):
			return a_value > b_value
		return str((a as Dictionary).get("plan_signature", "")) < str((b as Dictionary).get("plan_signature", ""))
	)
	var best: Dictionary = rows[0]
	var oracle_best_value := float(best.get("value", -1.0))
	var safe_tolerance := maxf(0.0, near_best_tolerance)
	var near_floor := oracle_best_value - safe_tolerance

	var production_best: Dictionary = {}
	var selected: Dictionary = {}
	var production_near_best: Array = []
	for row_variant in rows:
		var row: Dictionary = row_variant
		var signature := str(row.get("plan_signature", ""))
		if signature == selected_signature:
			selected = row
		if not bool(row.get("production_member", false)):
			continue
		if production_best.is_empty() or float(row.get("value", -INF)) > float(production_best.get("value", -INF)):
			production_best = row
		if float(row.get("value", -INF)) >= near_floor or is_equal_approx(float(row.get("value", -INF)), near_floor):
			production_near_best.append(signature)
	if production_best.is_empty():
		return {"valid": false, "error": "production_candidates_missing_from_evaluation"}

	var production_best_value := float(production_best.get("value", -1.0))
	var oracle_value_gap := maxf(0.0, oracle_best_value - production_best_value)
	var recall := not production_near_best.is_empty()
	var selection_accurate = null
	if recall:
		selection_accurate = (
			not selected.is_empty()
			and float(selected.get("value", -INF)) >= near_floor
		)
	var severe_miss := (not recall) and oracle_value_gap >= maxf(0.0, severe_miss_threshold)
	var classification := "ok"
	if not recall:
		classification = "candidate_generation"
	elif selection_accurate != true:
		classification = "ranking"

	return {
		"valid": true,
		"candidate_recall": recall,
		"candidate_generation_failure": not recall,
		"ranking_failure": recall and selection_accurate != true,
		"failure_classification": classification,
		"severe_miss": severe_miss,
		"oracle_best_value": oracle_best_value,
		"oracle_best_value_lower_bound": float(best.get("value_lower_bound", -1.0)),
		"oracle_best_value_upper_bound": float(best.get("value_upper_bound", 1.0)),
		"oracle_best_labeled_weight_fraction": float(best.get("labeled_weight_fraction", 0.0)),
		"oracle_best_plan_signature": str(best.get("plan_signature", "")),
		"oracle_best_actions": (best.get("actions", []) as Array).duplicate(true),
		"oracle_best_from_production": bool(best.get("production_member", false)),
		"oracle_best_from_wide_search": bool(best.get("oracle_search_member", false)),
		"best_production_value": production_best_value,
		"best_production_value_lower_bound": float(production_best.get("value_lower_bound", -1.0)),
		"best_production_value_upper_bound": float(production_best.get("value_upper_bound", 1.0)),
		"best_production_plan_signature": str(production_best.get("plan_signature", "")),
		"oracle_value_gap": oracle_value_gap,
		"near_best_value_floor": near_floor,
		"near_best_production_plan_signatures": production_near_best,
		"selected_plan_signature": selected_signature,
		"selected_plan_found": not selected.is_empty(),
		"selected_oracle_value": float(selected.get("value", 0.0)) if not selected.is_empty() else null,
		"selection_accurate_conditional_on_recall": selection_accurate,
		"evaluated_candidate_count": rows.size(),
		"production_candidate_count": production_signatures.size(),
		"wide_search_candidate_count": oracle_signatures.size(),
	}


static func summarize(decisions: Array) -> Dictionary:
	var valid_rows: Array = []
	for row_variant in decisions:
		if row_variant is Dictionary and bool((row_variant as Dictionary).get("valid", false)):
			valid_rows.append(row_variant)
	var recall_count := 0
	var severe_count := 0
	var candidate_failures := 0
	var ranking_failures := 0
	var conditional_correct := 0
	var conditional_count := 0
	var total_gap := 0.0
	var max_gap := 0.0
	var production_simulations := 0
	var oracle_simulations := 0
	var production_ms := 0.0
	var oracle_ms := 0.0
	for row_variant in valid_rows:
		var row: Dictionary = row_variant
		var analysis: Dictionary = row.get("analysis", {})
		var recall := bool(analysis.get("candidate_recall", false))
		if recall:
			recall_count += 1
		if bool(analysis.get("severe_miss", false)):
			severe_count += 1
		if bool(analysis.get("candidate_generation_failure", false)):
			candidate_failures += 1
		if bool(analysis.get("ranking_failure", false)):
			ranking_failures += 1
		if recall:
			conditional_count += 1
			if analysis.get("selection_accurate_conditional_on_recall", null) == true:
				conditional_correct += 1
		var gap := float(analysis.get("oracle_value_gap", 0.0))
		total_gap += gap
		max_gap = maxf(max_gap, gap)
		var production: Dictionary = row.get("production_search", {})
		var oracle: Dictionary = row.get("oracle_search", {})
		production_simulations += int(production.get("simulations_run", 0))
		oracle_simulations += int(oracle.get("simulations_run", 0))
		production_ms += float(production.get("elapsed_ms", 0.0))
		oracle_ms += float(oracle.get("elapsed_ms", 0.0))
	var count := valid_rows.size()
	return {
		"decision_count": count,
		"near_oracle_candidate_recall": float(recall_count) / float(count) if count > 0 else 0.0,
		"mean_oracle_value_gap": total_gap / float(count) if count > 0 else 0.0,
		"max_oracle_value_gap": max_gap,
		"severe_miss_count": severe_count,
		"severe_miss_rate": float(severe_count) / float(count) if count > 0 else 0.0,
		"candidate_generation_failure_count": candidate_failures,
		"ranking_failure_count": ranking_failures,
		"selection_accuracy_conditional_on_recall": (
			float(conditional_correct) / float(conditional_count) if conditional_count > 0 else null
		),
		"selection_accuracy_conditional_decisions": conditional_count,
		"production_simulations": production_simulations,
		"oracle_simulations": oracle_simulations,
		"production_elapsed_ms": production_ms,
		"oracle_elapsed_ms": oracle_ms,
		"oracle_to_production_simulation_ratio": (
			float(oracle_simulations) / float(production_simulations) if production_simulations > 0 else null
		),
		"oracle_to_production_time_ratio": oracle_ms / production_ms if production_ms > 0.0 else null,
	}


static func plan_signature(actions_variant: Variant) -> String:
	if not (actions_variant is Array):
		return ""
	var parts: Array[String] = []
	for action_variant in actions_variant:
		if not (action_variant is Dictionary):
			continue
		var action: Dictionary = action_variant
		parts.append("%08d|%s|%s|%s" % [
			int(action.get("unit_id", -1)),
			str(action.get("action_key", "")),
			JSON.stringify(action.get("end_point", [])),
			JSON.stringify(action.get("path", [])),
		])
	parts.sort()
	return ";".join(parts)


static func _run_search(
	game_state: Dictionary,
	perspective_group: String,
	opponent_group: String,
	budget: Dictionary
) -> Dictionary:
	return PureStateOpponentResponseSearch.search(
		game_state,
		perspective_group,
		opponent_group,
		int(budget.own_max_actions_per_unit),
		int(budget.own_max_plans),
		int(budget.opponent_max_actions_per_unit),
		int(budget.opponent_max_plans)
	)


static func _signature_set_from_search(search: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for row_variant in search.get("ranked_results", []):
		if row_variant is Dictionary:
			var signature := plan_signature((row_variant as Dictionary).get("actions", []))
			if not signature.is_empty():
				result[signature] = true
	return result


static func _union_candidates(production_search: Dictionary, oracle_search: Dictionary) -> Array:
	var result: Array = []
	var seen: Dictionary = {}
	for source_variant in [production_search, oracle_search]:
		var source: Dictionary = source_variant
		for row_variant in source.get("ranked_results", []):
			if not (row_variant is Dictionary):
				continue
			var row: Dictionary = row_variant
			var actions: Array = (row.get("actions", []) as Array).duplicate(true)
			var signature := plan_signature(actions)
			if signature.is_empty() or seen.has(signature):
				continue
			seen[signature] = true
			result.append({
				"candidate_id": "oracle_union_%03d" % result.size(),
				"candidate_label": "oracle union candidate %d" % result.size(),
				"actions": actions,
				"proposal_score": float(row.get("proposal_score", 0.0)),
			})
	return result


static func _search_diagnostics(search: Dictionary, budget: Dictionary) -> Dictionary:
	return {
		"valid": bool(search.get("valid", false)),
		"error": str(search.get("error", "")),
		"budget": budget.duplicate(true),
		"own_base_source_candidates": int(search.get("own_base_source_candidates", 0)),
		"own_source_candidates": int(search.get("own_source_candidates", 0)),
		"counter_injected_source_candidates": int(search.get("counter_injected_source_candidates", 0)),
		"opponent_source_candidates": int(search.get("opponent_source_candidates", 0)),
		"own_candidates_considered": int(search.get("own_candidates_considered", 0)),
		"opponent_candidates_considered": int(search.get("opponent_candidates_considered", 0)),
		"own_candidate_intent_counts": (search.get("own_candidate_intent_counts", {}) as Dictionary).duplicate(true),
		"opponent_candidate_intent_counts": (search.get("opponent_candidate_intent_counts", {}) as Dictionary).duplicate(true),
		"simulations_run": int(search.get("simulations_run", 0)),
		"pruned_candidates": int(search.get("pruned_candidates", 0)),
		"elapsed_ms": float(search.get("elapsed_ms", 0.0)),
		"best_plan_signature": plan_signature(search.get("best_actions", [])),
	}


static func _diagnose_loss_stage(
	game_state: Dictionary,
	perspective_group: String,
	opponent_group: String,
	oracle_signature: String,
	production_budget: Dictionary,
	oracle_budget: Dictionary
) -> Dictionary:
	var probes: Array = []
	var definitions := [
		{
			"id": "wider_final_plan_cap",
			"budget": {
				"own_max_actions_per_unit": production_budget.own_max_actions_per_unit,
				"own_max_plans": oracle_budget.own_max_plans,
				"opponent_max_actions_per_unit": production_budget.opponent_max_actions_per_unit,
				"opponent_max_plans": production_budget.opponent_max_plans,
			},
		},
		{
			"id": "wider_per_unit_actions",
			"budget": {
				"own_max_actions_per_unit": oracle_budget.own_max_actions_per_unit,
				"own_max_plans": oracle_budget.own_max_plans,
				"opponent_max_actions_per_unit": production_budget.opponent_max_actions_per_unit,
				"opponent_max_plans": production_budget.opponent_max_plans,
			},
		},
		{
			"id": "wider_opponent_conditioning",
			"budget": {
				"own_max_actions_per_unit": production_budget.own_max_actions_per_unit,
				"own_max_plans": oracle_budget.own_max_plans,
				"opponent_max_actions_per_unit": oracle_budget.opponent_max_actions_per_unit,
				"opponent_max_plans": oracle_budget.opponent_max_plans,
			},
		},
	]
	var first_recovery := "full_oracle_only"
	for definition_variant in definitions:
		var definition: Dictionary = definition_variant
		var budget: Dictionary = definition.get("budget", {})
		var search := _run_search(game_state, perspective_group, opponent_group, budget)
		var signatures := _signature_set_from_search(search)
		var recovered := signatures.has(oracle_signature)
		probes.append({
			"probe": str(definition.get("id", "")),
			"recovered_exact_oracle_winner": recovered,
			"candidate_count": signatures.size(),
			"simulations_run": int(search.get("simulations_run", 0)),
			"elapsed_ms": float(search.get("elapsed_ms", 0.0)),
			"budget": budget.duplicate(true),
		})
		if recovered and first_recovery == "full_oracle_only":
			first_recovery = str(definition.get("id", ""))
	return {
		"status": "probed",
		"semantics": "exact oracle-winner recovery probes; use alongside value-based recall rather than as a causal proof",
		"first_recovery_probe": first_recovery,
		"probes": probes,
	}


static func _empty_result(decision_id: String, perspective_group: String, opponent_group: String) -> Dictionary:
	return {
		"valid": false,
		"error": "",
		"schema_version": SCHEMA_VERSION,
		"benchmark_version": BENCHMARK_VERSION,
		"decision_id": decision_id,
		"perspective_group": perspective_group,
		"opponent_group": opponent_group,
	}
