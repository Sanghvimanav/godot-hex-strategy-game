extends RefCounted

const PureStateCandidateOracleRecall = preload("res://src/simulation/pure_state_candidate_oracle_recall.gd")


static func run_all(tests: Node) -> bool:
	var ok := true
	ok = _test_value_near_match_counts_without_exact_action_match(tests) and ok
	ok = _test_candidate_generation_failure_is_separated(tests) and ok
	ok = _test_ranking_failure_is_conditional_on_recall(tests) and ok
	ok = _test_summary_reports_required_metrics(tests) and ok
	return ok


static func _test_value_near_match_counts_without_exact_action_match(tests: Node) -> bool:
	tests._log("test_candidate_oracle_recall: value-equivalent recall does not require exact action match")
	var oracle_actions := [_action(1, "oracle_best")]
	var near_actions := [_action(1, "different_but_near")]
	var oracle_signature := PureStateCandidateOracleRecall.plan_signature(oracle_actions)
	var near_signature := PureStateCandidateOracleRecall.plan_signature(near_actions)
	var result := PureStateCandidateOracleRecall.analyze_evaluated_candidates(
		[
			_candidate("oracle", oracle_actions, 0.90),
			_candidate("near", near_actions, 0.84),
		],
		{near_signature: true},
		{oracle_signature: true},
		near_signature,
		0.10,
		0.50
	)
	if not bool(result.get("candidate_recall", false)):
		tests._fail("a different plan within value tolerance should count as recalled: %s" % result)
		return false
	if bool(result.get("oracle_best_from_production", true)):
		tests._fail("fixture requires the exact oracle winner to be absent from production")
		return false
	if result.get("selection_accurate_conditional_on_recall", false) != true:
		tests._fail("the selected near-best production plan should be conditionally accurate")
		return false
	tests._pass("near-oracle recall is value-based instead of exact-action based")
	return true


static func _test_candidate_generation_failure_is_separated(tests: Node) -> bool:
	tests._log("test_candidate_oracle_recall: candidate-generation miss classification")
	var oracle_actions := [_action(1, "materially_stronger")]
	var production_actions := [_action(1, "weak_production")]
	var oracle_signature := PureStateCandidateOracleRecall.plan_signature(oracle_actions)
	var production_signature := PureStateCandidateOracleRecall.plan_signature(production_actions)
	var result := PureStateCandidateOracleRecall.analyze_evaluated_candidates(
		[
			_candidate("oracle", oracle_actions, 0.90),
			_candidate("production", production_actions, 0.10),
		],
		{production_signature: true},
		{oracle_signature: true},
		production_signature,
		0.10,
		0.50
	)
	if not bool(result.get("candidate_generation_failure", false)):
		tests._fail("missing all near-best plans must be a candidate-generation failure")
		return false
	if bool(result.get("ranking_failure", true)):
		tests._fail("ranking cannot be blamed when no near-best production candidate exists")
		return false
	if not bool(result.get("severe_miss", false)):
		tests._fail("0.8 value gap should exceed the severe-miss threshold")
		return false
	if str(result.get("failure_classification", "")) != "candidate_generation":
		tests._fail("failure classification should name candidate generation")
		return false
	tests._pass("candidate omission is distinguished from valuation/ranking error")
	return true


static func _test_ranking_failure_is_conditional_on_recall(tests: Node) -> bool:
	tests._log("test_candidate_oracle_recall: ranking failure conditional on recall")
	var oracle_actions := [_action(1, "oracle")]
	var near_actions := [_action(1, "near")]
	var poor_actions := [_action(1, "poor_selected")]
	var oracle_signature := PureStateCandidateOracleRecall.plan_signature(oracle_actions)
	var near_signature := PureStateCandidateOracleRecall.plan_signature(near_actions)
	var poor_signature := PureStateCandidateOracleRecall.plan_signature(poor_actions)
	var result := PureStateCandidateOracleRecall.analyze_evaluated_candidates(
		[
			_candidate("oracle", oracle_actions, 0.90),
			_candidate("near", near_actions, 0.85),
			_candidate("poor", poor_actions, 0.20),
		],
		{near_signature: true, poor_signature: true},
		{oracle_signature: true},
		poor_signature,
		0.10,
		0.50
	)
	if not bool(result.get("candidate_recall", false)):
		tests._fail("near-best production candidate should establish recall")
		return false
	if not bool(result.get("ranking_failure", false)):
		tests._fail("selecting the poor plan despite a near-best candidate should be ranking failure")
		return false
	if result.get("selection_accurate_conditional_on_recall", true) != false:
		tests._fail("conditional selection accuracy should be false")
		return false
	if str(result.get("failure_classification", "")) != "ranking":
		tests._fail("failure classification should name ranking")
		return false
	tests._pass("ranking is blamed only after candidate recall succeeds")
	return true


static func _test_summary_reports_required_metrics(tests: Node) -> bool:
	tests._log("test_candidate_oracle_recall: aggregate metric contract")
	var rows := [
		{
			"valid": true,
			"analysis": {
				"candidate_recall": true,
				"candidate_generation_failure": false,
				"ranking_failure": false,
				"severe_miss": false,
				"oracle_value_gap": 0.05,
				"selection_accurate_conditional_on_recall": true,
			},
			"production_search": {"simulations_run": 10, "elapsed_ms": 5.0},
			"oracle_search": {"simulations_run": 40, "elapsed_ms": 20.0},
		},
		{
			"valid": true,
			"analysis": {
				"candidate_recall": false,
				"candidate_generation_failure": true,
				"ranking_failure": false,
				"severe_miss": true,
				"oracle_value_gap": 0.60,
				"selection_accurate_conditional_on_recall": null,
			},
			"production_search": {"simulations_run": 10, "elapsed_ms": 5.0},
			"oracle_search": {"simulations_run": 40, "elapsed_ms": 20.0},
		},
	]
	var summary := PureStateCandidateOracleRecall.summarize(rows)
	if not is_equal_approx(float(summary.get("near_oracle_candidate_recall", -1.0)), 0.5):
		tests._fail("summary should report recall across decisions: %s" % summary)
		return false
	if not is_equal_approx(float(summary.get("mean_oracle_value_gap", -1.0)), 0.325):
		tests._fail("summary should report mean oracle value gap: %s" % summary)
		return false
	if not is_equal_approx(float(summary.get("severe_miss_rate", -1.0)), 0.5):
		tests._fail("summary should report severe miss rate: %s" % summary)
		return false
	if not is_equal_approx(float(summary.get("selection_accuracy_conditional_on_recall", -1.0)), 1.0):
		tests._fail("summary should report conditional selection accuracy: %s" % summary)
		return false
	if not is_equal_approx(float(summary.get("oracle_to_production_simulation_ratio", -1.0)), 4.0):
		tests._fail("summary should expose compute ratio: %s" % summary)
		return false
	tests._pass("aggregate output covers recall, gap, severe misses, conditional selection, and compute")
	return true


static func _candidate(id: String, actions: Array, value: float) -> Dictionary:
	return {
		"candidate_id": id,
		"actions": actions,
		"estimate": {
			"full_mixture_midpoint": value,
			"full_mixture_lower_bound": value,
			"full_mixture_upper_bound": value,
			"labeled_weight_fraction": 1.0,
		},
	}


static func _action(unit_id: int, action_key: String) -> Dictionary:
	return {
		"unit_id": unit_id,
		"action_key": action_key,
		"end_point": [0, 0],
		"path": [],
	}
