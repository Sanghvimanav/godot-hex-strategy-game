extends RefCounted
class_name PureStateCandidateOracleFastRecall
## Two-stage Candidate Oracle Recall evaluator for broad offline diagnostics.
##
## The wide search already evaluates every wide candidate against its opponent pool.
## Reuse that ranking as a zero-extra-simulation screen, then run the expensive
## counterfactual answer key only on all production candidates plus the strongest
## oracle-only challengers. The wide-search winner is always retained. Because the
## final oracle set is screened, oracle comparison is explicitly approximate.

const Base = preload("res://src/simulation/pure_state_candidate_oracle_recall.gd")
const PureStateOpponentResponseSearch = preload("res://src/simulation/pure_state_opponent_response_search.gd")
const PureStateCounterfactualAnswerKey = preload("res://src/simulation/pure_state_counterfactual_answer_key.gd")

const SCHEMA_VERSION := Base.SCHEMA_VERSION
const BENCHMARK_VERSION := 2
const DEFAULT_TOP_ORACLE_CANDIDATES := 2
const DEFAULT_MAX_FINALISTS := 4


static func evaluate_decision(
	game_state: Dictionary,
	perspective_group: String,
	opponent_group: String,
	decision_id: String,
	config: Dictionary = {}
) -> Dictionary:
	if not bool(config.get("screening_enabled", true)):
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
			int(config.get("oracle_own_max_actions_per_unit", Base.DEFAULT_ORACLE_OWN_MAX_ACTIONS_PER_UNIT))
		),
		"own_max_plans": maxi(
			int(production_budget.own_max_plans),
			int(config.get("oracle_own_max_plans", Base.DEFAULT_ORACLE_OWN_MAX_PLANS))
		),
		"opponent_max_actions_per_unit": maxi(
			int(production_budget.opponent_max_actions_per_unit),
			int(config.get("oracle_opponent_max_actions_per_unit", Base.DEFAULT_ORACLE_OPPONENT_MAX_ACTIONS_PER_UNIT))
		),
		"opponent_max_plans": maxi(
			int(production_budget.opponent_max_plans),
			int(config.get("oracle_opponent_max_plans", Base.DEFAULT_ORACLE_OPPONENT_MAX_PLANS))
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

	var screening_started_usec := Time.get_ticks_usec()
	var finalist_selection := _select_finalists(
		union_candidates,
		oracle_search.get("ranked_results", []) as Array,
		production_signatures,
		Base.plan_signature(oracle_search.get("best_actions", [])),
		maxi(1, int(config.get("screening_top_oracle_candidates", DEFAULT_TOP_ORACLE_CANDIDATES))),
		maxi(1, int(config.get("screening_max_finalists", DEFAULT_MAX_FINALISTS)))
	)
	var finalists: Array = finalist_selection.get("candidates", [])
	if finalists.is_empty():
		invalid["error"] = "oracle_screening_empty_finalists"
		return invalid
	var screening_elapsed_ms := float(Time.get_ticks_usec() - screening_started_usec) / 1000.0

	var evaluation_config := config.duplicate(true)
	evaluation_config["own_candidates"] = finalists
	evaluation_config["include_states"] = false
	evaluation_config["opponent_policy_max_actions_per_unit"] = int(config.get(
		"oracle_value_opponent_max_actions_per_unit", oracle_budget.opponent_max_actions_per_unit
	))
	evaluation_config["opponent_policy_max_plans"] = int(config.get(
		"oracle_value_opponent_max_plans", oracle_budget.opponent_max_plans
	))
	evaluation_config["opponent_policy_response_max_actions_per_unit"] = int(config.get(
		"oracle_value_response_max_actions_per_unit", oracle_budget.own_max_actions_per_unit
	))
	evaluation_config["opponent_policy_response_max_plans"] = int(config.get(
		"oracle_value_response_max_plans", oracle_budget.own_max_plans
	))

	var evaluated := PureStateCounterfactualAnswerKey.evaluate_decision(
		game_state, perspective_group, opponent_group, decision_id, evaluation_config
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
		float(config.get("near_best_tolerance", Base.DEFAULT_NEAR_BEST_TOLERANCE)),
		float(config.get("severe_miss_threshold", Base.DEFAULT_SEVERE_MISS_THRESHOLD))
	)
	if not bool(analysis.get("valid", false)):
		invalid["error"] = str(analysis.get("error", "candidate_analysis_failed"))
		return invalid

	var loss_stage_probes: Dictionary = {"status": "not_needed", "first_recovery_probe": "production"}
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
	screening["screening_source"] = "existing_wide_search_ranked_results"
	screening["extra_screening_simulations"] = 0
	screening["screening_elapsed_ms"] = screening_elapsed_ms

	return {
		"valid": true,
		"error": "",
		"schema_version": SCHEMA_VERSION,
		"benchmark_version": BENCHMARK_VERSION,
		"decision_id": decision_id,
		"perspective_group": perspective_group,
		"opponent_group": opponent_group,
		"value_semantics": "screened_full_mixture_midpoint_of_search_policy_terminal_return_with_unresolved_bounds_v2",
		"near_best_tolerance": float(config.get("near_best_tolerance", Base.DEFAULT_NEAR_BEST_TOLERANCE)),
		"severe_miss_threshold": float(config.get("severe_miss_threshold", Base.DEFAULT_SEVERE_MISS_THRESHOLD)),
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


static func _select_finalists(
	union_candidates: Array,
	wide_ranked_results: Array,
	production_signatures: Dictionary,
	wide_best_signature: String,
	top_oracle_candidates: int,
	max_finalists: int
) -> Dictionary:
	var by_signature: Dictionary = {}
	for candidate_variant in union_candidates:
		if candidate_variant is Dictionary:
			var candidate: Dictionary = candidate_variant
			var signature := Base.plan_signature(candidate.get("actions", []))
			if not signature.is_empty():
				by_signature[signature] = candidate.duplicate(true)

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

	var oracle_kept := 0
	for ranked_variant in wide_ranked_results:
		if oracle_kept >= top_oracle_candidates or selected.size() - production_count >= oracle_slots:
			break
		if not (ranked_variant is Dictionary):
			continue
		var ranked: Dictionary = ranked_variant
		var signature := Base.plan_signature(ranked.get("actions", []))
		if signature.is_empty() or production_signatures.has(signature) or selected.has(signature) or not by_signature.has(signature):
			continue
		selected[signature] = true
		oracle_kept += 1

	# Fill remaining slots in deterministic union order if the ranked list did not
	# expose enough unique oracle-only candidates.
	for candidate_variant in union_candidates:
		if selected.size() - production_count >= oracle_slots:
			break
		if not (candidate_variant is Dictionary):
			continue
		var candidate: Dictionary = candidate_variant
		var signature := Base.plan_signature(candidate.get("actions", []))
		if not signature.is_empty() and not selected.has(signature) and not production_signatures.has(signature):
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
			"max_finalists": safe_cap,
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
