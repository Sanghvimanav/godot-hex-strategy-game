extends RefCounted

const PureStateCounterfactualBenchmark = preload("res://src/simulation/pure_state_counterfactual_benchmark.gd")
const PureStateCounterfactualSuite = preload("res://src/simulation/pure_state_counterfactual_suite.gd")
const PureStateSelfPlaySuite = preload("res://src/simulation/pure_state_self_play_suite.gd")


static func run_all(tests: Node) -> bool:
	var ok := true
	ok = _test_weighted_aggregation_keeps_missing_mass_visible(tests) and ok
	ok = _test_pairwise_comparisons_preserve_uncertainty(tests) and ok
	ok = _test_terminal_candidate_and_unlabeled_candidate(tests) and ok
	ok = _test_suite_and_jsonl_provenance(tests) and ok
	ok = _test_curated_cases_are_named_and_distinct(tests) and ok
	ok = _test_baneling_sacrifice_geometries_are_distinct(tests) and ok
	return ok


static func _test_weighted_aggregation_keeps_missing_mass_visible(tests: Node) -> bool:
	tests._log("test_pure_state_counterfactual_benchmark: weighted aggregation and coverage")
	var estimate := PureStateCounterfactualBenchmark.aggregate_samples([
		{"valid": true, "labeled": true, "return": 1.0, "weight": 0.5},
		{"valid": true, "labeled": true, "return": -1.0, "weight": 0.25},
		{"valid": true, "labeled": false, "return": null, "weight": 0.25},
	])
	if str(estimate.get("status", "")) != "estimated":
		tests._fail("labeled samples should produce an estimate")
		return false
	if not is_equal_approx(float(estimate.get("mean_return", 0.0)), 1.0 / 3.0):
		tests._fail("weighted mean should condition only on terminal samples: %s" % estimate)
		return false
	if not is_equal_approx(float(estimate.get("labeled_weight_fraction", 0.0)), 0.75):
		tests._fail("unresolved mixture mass must remain visible as 75%% coverage")
		return false
	if int(estimate.get("unlabeled_count", 0)) != 1:
		tests._fail("turn-limit/no-continuation sample should remain explicitly unlabeled")
		return false
	if not is_equal_approx(float(estimate.get("effective_sample_size", 0.0)), 1.8):
		tests._fail("weighted effective sample size is incorrect: %s" % estimate)
		return false
	if float(estimate.get("estimated_standard_error", 0.0)) <= 0.0:
		tests._fail("disagreeing policy samples should expose nonzero policy-mixture uncertainty")
		return false
	if float(estimate.get("worst_case_return", 0.0)) != -1.0 or float(estimate.get("best_case_return", 0.0)) != 1.0:
		tests._fail("best/worst terminal outcomes should be retained")
		return false
	tests._pass("weighted target reports return, policy spread, and unresolved mixture coverage")
	return true


static func _test_pairwise_comparisons_preserve_uncertainty(tests: Node) -> bool:
	tests._log("test_pure_state_counterfactual_benchmark: pairwise uncertainty")
	var candidates := [
		{"candidate_id": "A", "estimate": _estimate(0.30, 0.15)},
		{"candidate_id": "B", "estimate": _estimate(0.25, 0.12)},
		{"candidate_id": "C", "estimate": _estimate(-0.40, 0.08)},
	]
	var comparisons := PureStateCounterfactualBenchmark.build_pairwise_comparisons(candidates, 1.96)
	if comparisons.size() != 3:
		tests._fail("three candidates should produce three pairwise comparisons")
		return false
	var by_pair: Dictionary = {}
	for comparison_variant in comparisons:
		var comparison: Dictionary = comparison_variant
		by_pair["%s|%s" % [comparison.left_candidate_id, comparison.right_candidate_id]] = comparison
	if bool((by_pair.get("A|B", {}) as Dictionary).get("comparable", true)):
		tests._fail("A and B should remain uncertain because their policy intervals overlap")
		return false
	if not bool((by_pair.get("A|C", {}) as Dictionary).get("comparable", false)):
		tests._fail("A should be clearly preferred to C")
		return false
	if str((by_pair.get("A|C", {}) as Dictionary).get("preferred_candidate_id", "")) != "A":
		tests._fail("A/C comparison should prefer A")
		return false
	if not bool((by_pair.get("B|C", {}) as Dictionary).get("comparable", false)):
		tests._fail("B should be clearly preferred to C")
		return false
	tests._pass("close candidates remain co-best while clearly worse candidates separate")
	return true


static func _test_terminal_candidate_and_unlabeled_candidate(tests: Node) -> bool:
	tests._log("test_pure_state_counterfactual_benchmark: real simultaneous-turn smoke decision")
	var state := PureStateSelfPlaySuite.build_state("baneling_finish")
	var before := state.duplicate(true)
	var result := PureStateCounterfactualBenchmark.evaluate_decision(
		state,
		"zerg",
		"terran",
		"test-baneling-choice",
		{
			"rules_version": "test-rules-sha",
			"own_candidates": [
				{
					"candidate_id": "explode",
					"actions": [
						_action(3, "explode", [0, 0]),
						_action(4, "reload", [4, 0]),
					],
				},
				{
					"candidate_id": "hold",
					"actions": [
						_action(3, "reload", [0, 0]),
						_action(4, "reload", [4, 0]),
					],
				},
			],
			"opponent_samples": [],
			"continuation_profiles": [],
			"include_states": true,
		}
	)
	if state != before:
		tests._fail("counterfactual evaluation must not mutate the source state")
		return false
	if not bool(result.get("valid", false)):
		tests._fail("baneling decision should evaluate successfully: %s" % result)
		return false
	var candidates: Array = result.get("candidate_results", [])
	if candidates.size() != 2:
		tests._fail("explicit candidate list should be preserved")
		return false
	var explode_estimate: Dictionary = (candidates[0] as Dictionary).get("estimate", {})
	var hold_estimate: Dictionary = (candidates[1] as Dictionary).get("estimate", {})
	if int(explode_estimate.get("return_count", 0)) != 1 or float(explode_estimate.get("mean_return", 0.0)) != 1.0:
		tests._fail("explode should be a terminal Zerg win in the corrected fixture: %s" % explode_estimate)
		return false
	if int(hold_estimate.get("return_count", 0)) != 0 or str(hold_estimate.get("status", "")) != "unlabeled":
		tests._fail("nonterminal hold without continuation must stay unlabeled: %s" % hold_estimate)
		return false
	if result.get("estimated_best_candidate_ids", []) != ["explode"]:
		tests._fail("the only terminally evaluated candidate should be estimated best")
		return false
	tests._pass("first joint turn labels terminal outcomes and refuses to invent capped outcomes")
	return true


static func _test_suite_and_jsonl_provenance(tests: Node) -> bool:
	tests._log("test_pure_state_counterfactual_benchmark: suite and JSONL provenance")
	var jobs := PureStateCounterfactualSuite.get_preset("starter", "rules-abc")
	if jobs.size() != 3:
		tests._fail("starter counterfactual suite should contain three distinct decisions")
		return false
	var ids: Dictionary = {}
	for job_variant in jobs:
		var job: Dictionary = job_variant
		var decision_id := str(job.get("decision_id", ""))
		if decision_id.is_empty() or ids.has(decision_id):
			tests._fail("counterfactual decision ids must be stable and unique")
			return false
		ids[decision_id] = true
		var config: Dictionary = job.get("config", {})
		if str(config.get("rules_version", "")) != "rules-abc":
			tests._fail("suite job should carry immutable rules provenance")
			return false

	var synthetic_result := {
		"valid": true,
		"schema_version": PureStateCounterfactualBenchmark.SCHEMA_VERSION,
		"benchmark_version": PureStateCounterfactualBenchmark.BENCHMARK_VERSION,
		"decision_id": "jsonl-decision",
		"perspective_group": "zerg",
		"opponent_group": "terran",
		"source_state": {"scenario_id": "synthetic"},
		"assumptions": {"rules_version": "rules-abc"},
		"candidate_results": [{
			"candidate_id": "candidate-a",
			"plan_signature": "sig",
			"actions": [],
			"proposal_score": 0.0,
			"estimate": _estimate(0.5, 0.1),
			"samples": [],
		}],
	}
	var rows := PureStateCounterfactualBenchmark.to_candidate_rows(synthetic_result)
	var jsonl := PureStateCounterfactualBenchmark.to_jsonl(rows)
	var parsed = JSON.parse_string(jsonl.strip_edges())
	if not (parsed is Dictionary):
		tests._fail("candidate JSONL row should parse as a JSON object")
		return false
	if str((parsed as Dictionary).get("decision_id", "")) != "jsonl-decision":
		tests._fail("candidate JSONL row should retain decision grouping")
		return false
	if str(((parsed as Dictionary).get("assumptions", {}) as Dictionary).get("rules_version", "")) != "rules-abc":
		tests._fail("candidate JSONL row should retain target provenance")
		return false
	tests._pass("suite jobs and exported rows retain decision and policy provenance")
	return true


static func _test_curated_cases_are_named_and_distinct(tests: Node) -> bool:
	tests._log("test_pure_state_counterfactual_benchmark: curated behavior cases")
	var jobs := PureStateCounterfactualSuite.get_preset("curated", "rules-curated")
	if jobs.size() != 4:
		tests._fail("curated preset should contain four tactical regression decisions")
		return false
	var behaviors: Dictionary = {}
	for job_variant in jobs:
		if not (job_variant is Dictionary):
			return false
		var job: Dictionary = job_variant
		var behavior_id := str(job.get("behavior_id", ""))
		var scenario_prompt := str(job.get("scenario_prompt", ""))
		if behavior_id.is_empty() or behaviors.has(behavior_id) or scenario_prompt.is_empty():
			tests._fail("curated behavior ids/prompts must be non-empty and unique")
			return false
		behaviors[behavior_id] = true
		var config: Dictionary = job.get("config", {})
		var candidates: Array = config.get("own_candidates", [])
		var opponent_samples: Array = config.get("opponent_samples", [])
		if candidates.size() != 3 or opponent_samples.size() != 3:
			tests._fail("each curated case should compare three named choices against three responses")
			return false
		for candidate_variant in candidates:
			var candidate: Dictionary = candidate_variant
			if str(candidate.get("candidate_id", "")).is_empty():
				return false
			if str(candidate.get("candidate_label", "")).is_empty():
				return false
			if str(candidate.get("candidate_description", "")).is_empty():
				return false
	for required in ["sacrifice", "sacrifice_stacked", "spreading", "coordinated_commitment"]:
		if not behaviors.has(required):
			tests._fail("missing curated behavior case: %s" % required)
			return false
	tests._pass("four curated regression cases expose named choices, prompts, and opponent responses")
	return true


static func _test_baneling_sacrifice_geometries_are_distinct(tests: Node) -> bool:
	tests._log("test_pure_state_counterfactual_benchmark: Baneling escape versus stacked blast geometry")
	var jobs := PureStateCounterfactualSuite.get_preset("curated", "rules-curated")
	var escape_job := _find_job_by_behavior(jobs, "sacrifice")
	var stacked_job := _find_job_by_behavior(jobs, "sacrifice_stacked")
	if escape_job.is_empty() or stacked_job.is_empty():
		tests._fail("both Baneling sacrifice fixtures must exist")
		return false
	if str(escape_job.get("decision_id", "")) == str(stacked_job.get("decision_id", "")):
		tests._fail("escape and stacked Baneling fixtures must use distinct decision ids")
		return false

	var escape_baneling := _unit_cell(escape_job.get("state", {}), "zerg", 4)
	var escape_response := _find_opponent_sample(escape_job, "weak_marines_escape_blast")
	if escape_baneling.is_empty() or escape_response.is_empty():
		tests._fail("escapable Baneling fixture is missing its center or escape response")
		return false
	for unit_id in [1, 2]:
		var start_cell := _unit_cell(escape_job.get("state", {}), "terran", int(unit_id))
		var end_cell := _action_endpoint(escape_response.get("actions", []), int(unit_id))
		if _hex_distance(start_cell, escape_baneling) != 1:
			tests._fail("escapable Marine %d should start adjacent to the Baneling" % unit_id)
			return false
		if _hex_distance(end_cell, escape_baneling) != 2:
			tests._fail("escapable Marine %d should finish at distance two, outside the center-plus-adjacent blast" % unit_id)
			return false

	var stacked_baneling := _unit_cell(stacked_job.get("state", {}), "zerg", 4)
	var stacked_response := _find_opponent_sample(stacked_job, "stacked_marines_step_out")
	if stacked_baneling.is_empty() or stacked_response.is_empty():
		tests._fail("stacked Baneling fixture is missing its center or step-out response")
		return false
	for unit_id in [1, 2]:
		var start_cell := _unit_cell(stacked_job.get("state", {}), "terran", int(unit_id))
		var end_cell := _action_endpoint(stacked_response.get("actions", []), int(unit_id))
		if _hex_distance(start_cell, stacked_baneling) != 0:
			tests._fail("stacked Marine %d should begin on the Baneling's tile" % unit_id)
			return false
		if _hex_distance(end_cell, stacked_baneling) != 1:
			tests._fail("stacked Marine %d should still be in the adjacent blast ring after one move" % unit_id)
			return false

	tests._pass("adjacent Marines can escape to distance two while stacked Marines remain in blast range after one move")
	return true


static func _find_job_by_behavior(jobs: Array, behavior_id: String) -> Dictionary:
	for job_variant in jobs:
		if job_variant is Dictionary and str((job_variant as Dictionary).get("behavior_id", "")) == behavior_id:
			return job_variant as Dictionary
	return {}


static func _find_opponent_sample(job: Dictionary, sample_id: String) -> Dictionary:
	var config: Dictionary = job.get("config", {})
	for sample_variant in config.get("opponent_samples", []):
		if sample_variant is Dictionary and str((sample_variant as Dictionary).get("sample_id", "")) == sample_id:
			return sample_variant as Dictionary
	return {}


static func _unit_cell(state_variant: Variant, group_name: String, unit_id: int) -> Array:
	if not (state_variant is Dictionary):
		return []
	var state: Dictionary = state_variant
	for group_variant in state.get("groups", []):
		if not (group_variant is Dictionary):
			continue
		var group: Dictionary = group_variant
		if str(group.get("name", "")) != group_name:
			continue
		for unit_variant in group.get("units", []):
			if unit_variant is Dictionary and int((unit_variant as Dictionary).get("unit_id", -1)) == unit_id:
				return ((unit_variant as Dictionary).get("cell", []) as Array).duplicate()
	return []


static func _action_endpoint(actions_variant: Variant, unit_id: int) -> Array:
	if not (actions_variant is Array):
		return []
	for action_variant in actions_variant:
		if action_variant is Dictionary and int((action_variant as Dictionary).get("unit_id", -1)) == unit_id:
			return ((action_variant as Dictionary).get("end_point", []) as Array).duplicate()
	return []


static func _hex_distance(a: Array, b: Array) -> int:
	if a.size() < 2 or b.size() < 2:
		return -1
	var dq := int(a[0]) - int(b[0])
	var dr := int(a[1]) - int(b[1])
	return int((abs(dq) + abs(dr) + abs(dq + dr)) / 2)


static func _estimate(mean_return: float, standard_error: float) -> Dictionary:
	return {
		"status": "estimated",
		"return_count": 2,
		"mean_return": mean_return,
		"estimated_standard_error": standard_error,
	}


static func _action(unit_id: int, action_key: String, end_point: Array) -> Dictionary:
	return {
		"unit_id": unit_id,
		"action_key": action_key,
		"path": [],
		"end_point": end_point.duplicate(),
	}