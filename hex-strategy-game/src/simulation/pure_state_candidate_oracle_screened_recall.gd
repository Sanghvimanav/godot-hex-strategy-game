extends RefCounted
class_name PureStateCandidateOracleScreenedRecall
## Optional two-stage Candidate Oracle Recall evaluator.
##
## The cheap screening pass evaluates the full production+oracle union with a short
## continuation. Every production candidate is retained for the expensive pass;
## screening can only prune oracle-only challengers. The wide-search winner is also
## always retained. This keeps ranking diagnostics exact over production candidates
## while making the reported oracle comparison explicitly approximate when screening
## is enabled.

const Base = preload("res://src/simulation/pure_state_candidate_oracle_recall.gd")
const PureStateOpponentResponseSearch = preload("res://src/simulation/pure_state_opponent_response_search.gd")
const PureStateCounterfactualAnswerKey = preload("res://src/simulation/pure_state_counterfactual_answer_key.gd")

const SCHEMA_VERSION := Base.SCHEMA_VERSION
const BENCHMARK_VERSION := 2

const DEFAULT_NEAR_BEST_TOLERANCE := Base.DEFAULT_NEAR_BEST_TOLERANCE
const DEFAULT_SEVERE_MISS_THRESHOLD := Base.DEFAULT_SEVERE_MISS_THRESHOLD
const DEFAULT_ORACLE_OWN_MAX_ACTIONS_PER_UNIT := Base.DEFAULT_ORACLE_OWN_MAX_ACTIONS_PER_UNIT
const DEFAULT_ORACLE_OWN_MAX_PLANS := Base.DEFAULT_ORACLE_OWN_MAX_PLANS
const DEFAULT_ORACLE_OPPONENT_MAX_ACTIONS_PER_UNIT := Base.DEFAULT_ORACLE_OPPONENT_MAX_ACTIONS_PER_UNIT
const DEFAULT_ORACLE_OPPONENT_MAX_PLANS := Base.DEFAULT_ORACLE_OPPONENT_MAX_PLANS

const DEFAULT_SCREENING_TOP_ORACLE_CANDIDATES := 4
const DEFAULT_SCREENING_VALUE_MARGIN := 0.20
const DEFAULT_SCREENING_MAX_FINALISTS := 8
const DEFAULT_SCREENING_MAX_TURNS := 2
const DEFAULT_SCREENING_OWN_MAX_PLANS := 2
const DEFAULT_SCREENING_OPPONENT_MAX_PLANS := 2


static func evaluate_decision(
	game_state: Dictionary,
	perspective_group: String,
	opponent_group: String,
	decision_id: String,
	config: Dictionary = {}
) -> Dictionary:
	if not bool(config.get("screening_enabled", false)):
		return Base.evaluate_decision(game_state, perspective_group, opponent_group, decision_id, config)

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

	var production_search := Base._run_search(game_state, perspective_group, opponent_group, production_budget)
	if not bool(production_search.get("valid", false)):
		invalid["error"] = "production_search_failed"
		invalid["production_search"] = Base._search_diagnostics(production_search, production_budget)
		return invalid
	var oracle_search := Base._run_search(game_state, perspective_group, opponent_group, oracle_budget)
	if not bool(oracle_search.get("valid", false)):
		invalid["error"] = "oracle_search_failed"
		invalid["production_search"] = Base._search_diagnostics(production_search, production_budget)
		invalid["oracle_search"] = Base._search_diagnostics(oracle_search, oracle_budget)
		return invalid

	var production_signatures := Base._signature_set_from_search(production_search)
	var oracle_signatures := Base._signature_set_from_search(oracle_search)
	var union_candidates := Base._union_candidates(production_search, oracle_search)
	if union_candidates.is_empty():
		invalid["error"] = "empty_candidate_union"
		return invalid

	var common_value_config := _common_value_config(config, oracle_budget)
	var screening_config := common_value_config.duplicate(true)
	screening_config["own_candidates"] = union_candidates
	screening_config["include_states"] = false
	# Authored stress responses are useful in the final report, but not for candidate
	# triage. Removing them here avoids doubling the screening work on curated jobs.
	screening_config["opponent_samples"] = []
	screening_config["continuation_profiles"] = [{
		"profile_id": "candidate_oracle_screen_2x2",
		"max_turns": maxi(1, int(config.get("screening_max_turns", DEFAULT_SCREENING_MAX_TURNS))),
		"max_actions_per_unit": maxi(1, int(config.get("screening_max_actions_per_unit", 8))),
		"own_max_plans": maxi(1, int(config.get("screening_own_max_plans", DEFAULT_SCREENING_OWN_MAX_PLANS))),
		"opponent_max_plans": maxi(1, int(config.get("screening_opponent_max_plans", DEFAULT_SCREENING_OPPONENT_MAX_PLANS))),
		"weight": 1.0,
	}]
	var screening_started_usec := Time.get_ticks_usec()
	var screened := PureStateCounterfactualAnswerKey.evaluate_decision(
		game_state,
		perspective_group,
		opponent_group,
		"%s|screen" % decision_id,
		screening_config
	)
	if not bool(screened.get("valid", false)):
		invalid["error"] = "oracle_screening_evaluation_failed"
		return invalid

	var screening_elapsed_ms := float(Time.get_ticks_usec() - screening_started_usec) / 1000.0
	var finalist_selection := _select_finalists(
		union_candidates,
		screened.get("candidate_results", []) as Array,
		production_signatures,
		Base.plan_signature(oracle_search.get("best_actions", [])),
		maxi(1, int(config.get("screening_top_oracle_candidates", DEFAULT_SCREENING_TOP_ORACLE_CANDIDATES))),
		maxf(0.0, float(config.get("screening_value_margin", DEFAULT_SCREENING_VALUE_MARGIN))),
		maxi(1, int(config.get("screening_max_finalists", DEFAULT_SCREENING_MAX_FINALISTS)))
	)
	var finalists: Array = finalist_selection.get("candidates", [])
	if finalists.is_empty():
		invalid["error"] = "oracle_screening_empty_finalists"
		return invalid

	var evaluation_config := common_value_config.duplicate(true)
	evaluation_config["own_candidates"] = finalists
	evaluation_config["include_states"] = false
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

	var selected_signature := Base.plan_signature(production_search.get("best_actions", []))
	var analysis := Base.analyze_evaluated_candidates(
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
		loss_stage_probes = Base._diagnose_loss_stage(
			game_state,
			perspective_group,
			opponent_group,
			str(analysis.get("oracle_best_plan_signature", "")),
			production_budget,
			oracle_budget
		)

	var screening := (finalist_selection.get("diagnostics", {}) as Dictionary).duplicate(true)
	screening["enabled"] = true
	screening["approximate_oracle"] = true
	screening["screening_elapsed_ms"] = screening_elapsed_ms
	screening["screening_continuation_profiles"] = (screening_config.get("continuation_profiles", []) as Array).duplicate(true)

	return {
		"valid": true,
		"error": "",
		"schema_version": SCHEMA_VERSION,
		"benchmark_version": BENCHMARK_VERSION,
		"decision_id": decision_id,
		"perspective_group": perspective_group,
		"opponent_group": opponent_group,
		"value_semantics": "screened_full_mixture_midpoint_of_search_policy_terminal_return_with_unresolved_bounds_v2",
		"near_best_tolerance": float(config.get("near_best_tolerance", DEFAULT_NEAR_BEST_TOLERANCE)),
		"severe_miss_threshold": float(config.get("severe_miss_threshold", DEFAULT_SEVERE_MISS_THRESHOLD)),
		"production_search": Base._search_diagnostics(production_search, production_budget),
		"oracle_search": Base._search_diagnostics(oracle_search, oracle_budget),
		"candidate_union_count": union_candidates.size(),
		"candidate_finalist_count": finalists.size(),
		"screening": screening,
		"analysis": analysis,
		"loss_stage_probes": loss_stage_probes,
		"answer_key_assumptions": (evaluated.get("assumptions", {}) as Dictionary).duplicate(true),
		"elapsed_ms": float(Time.get_ticks_usec() - started_usec) / 1000.0,
	}


static func summarize(decisions: Array) -> Dictionary:
	var summary := Base.summarize(decisions)
	var screened := 0
	var union_total := 0
	var finalist_total := 0
	var screening_ms := 0.0
	for row_variant in decisions:
		if not (row_variant is Dictionary) or not bool((row_variant as Dictionary).get("valid", false)):
			continue
		var row: Dictionary = row_variant
		var diagnostics: Dictionary = row.get("screening", {})
		if not bool(diagnostics.get("enabled", false)):
			continue
		screened += 1
		union_total += int(row.get("candidate_union_count", 0))
		finalist_total += int(row.get("candidate_finalist_count", row.get("candidate_union_count", 0)))
		screening_ms += float(diagnostics.get("screening_elapsed_ms", 0.0))
	summary["screened_decision_count"] = screened
	summary["screening_elapsed_ms"] = screening_ms
	summary["mean_candidate_union_count"] = float(union_total) / float(screened) if screened > 0 else null
	summary["mean_candidate_finalist_count"] = float(finalist_total) / float(screened) if screened > 0 else null
	summary["finalist_fraction"] = float(finalist_total) / float(union_total) if union_total > 0 else null
	return summary


static func _common_value_config(config: Dictionary, oracle_budget: Dictionary) -> Dictionary:
	var result := config.duplicate(true)
	result["opponent_policy_max_actions_per_unit"] = int(config.get(
		"oracle_value_opponent_max_actions_per_unit",
		oracle_budget.opponent_max_actions_per_unit
	))
	result["opponent_policy_max_plans"] = int(config.get(
		"oracle_value_opponent_max_plans",
		oracle_budget.opponent_max_plans
	))
	result["opponent_policy_response_max_actions_per_unit"] = int(config.get(
		"oracle_value_response_max_actions_per_unit",
		oracle_budget.own_max_actions_per_unit
	))
	result["opponent_policy_response_max_plans"] = int(config.get(
		"oracle_value_response_max_plans",
		oracle_budget.own_max_plans
	))
	return result


static func _select_finalists(
	union_candidates: Array,
	screening_results: Array,
	production_signatures: Dictionary,
	wide_best_signature: String,
	top_oracle_candidates: int,
	value_margin: float,
	max_finalists: int
) -> Dictionary:
	var by_signature: Dictionary = {}
	for candidate_variant in union_candidates:
		if not (candidate_variant is Dictionary):
			continue
		var candidate: Dictionary = candidate_variant
		var signature := Base.plan_signature(candidate.get("actions", []))
		if not signature.is_empty():
			by_signature[signature] = candidate.duplicate(true)

	var rows: Array = []
	for row_variant in screening_results:
		if not (row_variant is Dictionary):
			continue
		var row: Dictionary = row_variant
		var signature := Base.plan_signature(row.get("actions", []))
		var estimate: Dictionary = row.get("estimate", {})
		var lower := float(estimate.get("full_mixture_lower_bound", -1.0))
		var upper := float(estimate.get("full_mixture_upper_bound", 1.0))
		rows.append({
			"signature": signature,
			"value": float(estimate.get("full_mixture_midpoint", 0.5 * (lower + upper))),
			"production": production_signatures.has(signature),
		})
	rows.sort_custom(func(a, b):
		var av := float((a as Dictionary).get("value", -INF))
		var bv := float((b as Dictionary).get("value", -INF))
		if not is_equal_approx(av, bv):
			return av > bv
		return str((a as Dictionary).get("signature", "")) < str((b as Dictionary).get("signature", ""))
	)

	var selected: Dictionary = {}
	for signature_variant in production_signatures.keys():
		var signature := str(signature_variant)
		if by_signature.has(signature):
			selected[signature] = true

	var production_count := selected.size()
	var safe_cap := maxi(max_finalists, production_count + 1)
	var oracle_slots := maxi(1, safe_cap - production_count)
	if not wide_best_signature.is_empty() and not production_signatures.has(wide_best_signature) and by_signature.has(wide_best_signature):
		selected[wide_best_signature] = true

	var best_value := float((rows[0] as Dictionary).get("value", 0.0)) if not rows.is_empty() else 0.0
	var oracle_rank := 0
	for row_variant in rows:
		var row: Dictionary = row_variant
		if bool(row.get("production", false)):
			continue
		var signature := str(row.get("signature", ""))
		var keep_for_rank := oracle_rank < top_oracle_candidates
		var keep_for_margin := float(row.get("value", -INF)) >= best_value - value_margin
		oracle_rank += 1
		if not keep_for_rank and not keep_for_margin:
			continue
		if selected.has(signature):
			continue
		if selected.size() - production_count >= oracle_slots:
			continue
		selected[signature] = true

	# Fill unused oracle slots deterministically so a flat/unresolved screen still
	# compares several challengers instead of collapsing to only the wide winner.
	for row_variant in rows:
		if selected.size() - production_count >= oracle_slots:
			break
		var row: Dictionary = row_variant
		if bool(row.get("production", false)):
			continue
		var signature := str(row.get("signature", ""))
		if not selected.has(signature):
			selected[signature] = true

	var finalists: Array = []
	var finalist_signatures: Array = []
	for candidate_variant in union_candidates:
		if not (candidate_variant is Dictionary):
			continue
		var candidate: Dictionary = candidate_variant
		var signature := Base.plan_signature(candidate.get("actions", []))
		if selected.has(signature):
			finalists.append(candidate.duplicate(true))
			finalist_signatures.append(signature)

	return {
		"candidates": finalists,
		"diagnostics": {
			"candidate_count": union_candidates.size(),
			"production_candidate_count": production_count,
			"oracle_only_candidate_count": maxi(0, union_candidates.size() - production_count),
			"finalist_count": finalists.size(),
			"screened_out_count": maxi(0, union_candidates.size() - finalists.size()),
			"top_oracle_candidates": top_oracle_candidates,
			"value_margin": value_margin,
			"max_finalists": safe_cap,
			"best_screening_value": best_value,
			"wide_search_best_forced": selected.has(wide_best_signature),
			"finalist_signatures": finalist_signatures,
		}
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
