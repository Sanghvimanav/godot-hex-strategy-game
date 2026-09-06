extends RefCounted

const PureStateCounterfactualAnswerKey = preload("res://src/simulation/pure_state_counterfactual_answer_key.gd")


static func run_all(tests: Node) -> bool:
	var ok := true
	ok = _test_unresolved_mass_expands_full_mixture_bounds(tests) and ok
	ok = _test_search_policy_ignores_author_likelihood_weights(tests) and ok
	ok = _test_curated_responses_are_stress_only(tests) and ok
	ok = _test_interval_pairwise_requires_nonoverlap(tests) and ok
	return ok


static func _test_unresolved_mass_expands_full_mixture_bounds(tests: Node) -> bool:
	tests._log("test_pure_state_counterfactual_answer_key: unresolved mass bounds")
	var estimate := PureStateCounterfactualAnswerKey.enrich_estimate([
		{"valid": true, "labeled": true, "return": 1.0, "weight": 0.5},
		{"valid": true, "labeled": true, "return": -1.0, "weight": 0.25},
		{"valid": true, "labeled": false, "return": null, "weight": 0.25},
	])
	if not is_equal_approx(float(estimate.get("conditional_labeled_mean_return", 0.0)), 1.0 / 3.0):
		tests._fail("resolved-only conditional mean should stay backward compatible: %s" % estimate)
		return false
	if not is_equal_approx(float(estimate.get("known_weighted_return_contribution", 0.0)), 0.25):
		tests._fail("known contribution should retain its whole-mixture weight: %s" % estimate)
		return false
	if not is_equal_approx(float(estimate.get("unresolved_weight_fraction", 0.0)), 0.25):
		tests._fail("unresolved quarter of the policy mixture should remain visible: %s" % estimate)
		return false
	if not is_equal_approx(float(estimate.get("full_mixture_lower_bound", -1.0)), 0.0):
		tests._fail("unknown mass assigned -1 should give a zero lower bound: %s" % estimate)
		return false
	if not is_equal_approx(float(estimate.get("full_mixture_upper_bound", 1.0)), 0.5):
		tests._fail("unknown mass assigned +1 should give a 0.5 upper bound: %s" % estimate)
		return false
	tests._pass("coverage-aware target keeps unresolved policy mass in the answer interval")
	return true


static func _test_search_policy_ignores_author_likelihood_weights(tests: Node) -> bool:
	tests._log("test_pure_state_counterfactual_answer_key: search policy weighting")
	var weighted := PureStateCounterfactualAnswerKey.normalize_policy_samples([
		{
			"sample_id": "strong-search-plan",
			"policy_score": 8.0,
			"weight": 0.01,
		},
		{
			"sample_id": "weak-search-plan",
			"policy_score": 1.0,
			"weight": 0.99,
		},
	], 1.0)
	if weighted.size() != 2:
		tests._fail("two policy cases should remain two cases")
		return false
	var strong: Dictionary = weighted[0]
	var weak: Dictionary = weighted[1]
	if float(strong.get("author_sampling_weight", 0.0)) >= float(weak.get("author_sampling_weight", 0.0)):
		tests._fail("fixture should give the weak plan the larger authored weight")
		return false
	if float(strong.get("search_policy_weight", 0.0)) <= float(weak.get("search_policy_weight", 0.0)):
		tests._fail("better search score must outweigh authored sampling weight: %s" % weighted)
		return false
	var total := float(strong.get("search_policy_weight", 0.0)) + float(weak.get("search_policy_weight", 0.0))
	if not is_equal_approx(total, 1.0):
		tests._fail("search policy weights should normalize to one")
		return false
	tests._pass("authored response weights no longer masquerade as likelihoods")
	return true


static func _test_curated_responses_are_stress_only(tests: Node) -> bool:
	tests._log("test_pure_state_counterfactual_answer_key: curated stress separation")
	var stress := PureStateCounterfactualAnswerKey._build_curated_stress_samples({
		"opponent_samples": [
			{"sample_id": "author-favorite", "actions": [], "weight": 0.9},
			{"sample_id": "author-rare", "actions": [], "weight": 0.1},
		],
	})
	if stress.size() != 2:
		tests._fail("authored responses should remain available as two stress cases")
		return false
	var favorite: Dictionary = stress[0]
	var rare: Dictionary = stress[1]
	if not bool(favorite.get("curated", false)) or str(favorite.get("source", "")) != "curated_stress":
		tests._fail("authored responses must be labeled as curated stress cases")
		return false
	if not is_equal_approx(float(favorite.get("author_sampling_weight", 0.0)), 0.9):
		tests._fail("historical author weight should survive only as metadata")
		return false
	if not is_equal_approx(float(rare.get("author_sampling_weight", 0.0)), 0.1):
		tests._fail("historical author weight should survive only as metadata")
		return false
	if not is_zero_approx(float(favorite.get("search_policy_weight", -1.0))) or not is_zero_approx(float(rare.get("search_policy_weight", -1.0))):
		tests._fail("curated cases must have zero search-policy probability")
		return false
	if not is_equal_approx(float(favorite.get("weight", 0.0)), 1.0) or not is_equal_approx(float(rare.get("weight", 0.0)), 1.0):
		tests._fail("curated pass should allocate equal evaluation effort independent of author weights")
		return false
	tests._pass("authored cases are preserved for stress testing but excluded from policy value")
	return true


static func _test_interval_pairwise_requires_nonoverlap(tests: Node) -> bool:
	tests._log("test_pure_state_counterfactual_answer_key: interval pairwise comparison")
	var candidates := [
		{
			"candidate_id": "A",
			"estimate": {"full_mixture_lower_bound": 0.4, "full_mixture_upper_bound": 0.9},
		},
		{
			"candidate_id": "B",
			"estimate": {"full_mixture_lower_bound": -0.6, "full_mixture_upper_bound": -0.1},
		},
		{
			"candidate_id": "C",
			"estimate": {"full_mixture_lower_bound": 0.2, "full_mixture_upper_bound": 0.6},
		},
	]
	var comparisons := PureStateCounterfactualAnswerKey.build_interval_pairwise_comparisons(candidates)
	var by_pair: Dictionary = {}
	for comparison_variant in comparisons:
		var comparison: Dictionary = comparison_variant
		by_pair["%s|%s" % [comparison.left_candidate_id, comparison.right_candidate_id]] = comparison
	if not bool((by_pair.get("A|B", {}) as Dictionary).get("comparable", false)):
		tests._fail("nonoverlapping A/B full-mixture intervals should be comparable")
		return false
	if str((by_pair.get("A|B", {}) as Dictionary).get("preferred_candidate_id", "")) != "A":
		tests._fail("A should dominate B")
		return false
	if bool((by_pair.get("A|C", {}) as Dictionary).get("comparable", true)):
		tests._fail("overlapping A/C intervals must remain uncertain")
		return false
	var best := PureStateCounterfactualAnswerKey.estimated_interval_best_candidate_ids(candidates)
	if "B" in best or "A" not in best or "C" not in best:
		tests._fail("interval-best set should keep A/C and reject dominated B: %s" % best)
		return false
	tests._pass("candidate ordering now waits for whole-mixture interval separation")
	return true
