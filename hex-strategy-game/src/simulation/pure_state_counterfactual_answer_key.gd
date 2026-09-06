extends RefCounted
class_name PureStateCounterfactualAnswerKey
## Coverage-aware counterfactual answer key built on top of the raw benchmark.
##
## The raw benchmark remains responsible for deterministic simultaneous-turn
## simulation and continuation rollouts. This layer changes the interpretation:
##
## - expected-value opponent weights come only from a search-derived policy proxy
##   computed once from the original pre-turn state, never from the own candidate;
## - authored opponent responses are evaluated in a separate curated stress pass and
##   therefore cannot change the expected-value mixture at all;
## - unresolved continuation mass stays visible through full-mixture value bounds;
## - adversarial/best-response diagnostics are reported separately from policy value.

const PureStateCounterfactualBenchmark = preload("res://src/simulation/pure_state_counterfactual_benchmark.gd")
const PureStatePlans = preload("res://src/simulation/pure_state_plans.gd")
const PureStateOpponentResponseSearch = preload("res://src/simulation/pure_state_opponent_response_search.gd")

const SCHEMA_VERSION := PureStateCounterfactualBenchmark.SCHEMA_VERSION
const BENCHMARK_VERSION := 2
const ANSWER_KEY_VERSION := 2
const DEFAULT_POLICY_TEMPERATURE := 1.0
const DEFAULT_POLICY_MAX_PLANS := 4
const DEFAULT_POLICY_MAX_ACTIONS_PER_UNIT := 8
const DEFAULT_POLICY_RESPONSE_MAX_PLANS := 4


static func evaluate_decision(
	game_state: Dictionary,
	perspective_group: String,
	opponent_group: String,
	decision_id: String,
	config: Dictionary = {}
) -> Dictionary:
	var policy_temperature := maxf(
		0.05,
		float(config.get("opponent_policy_temperature", DEFAULT_POLICY_TEMPERATURE))
	)
	var policy_samples := _build_search_policy_samples(
		game_state,
		perspective_group,
		opponent_group,
		config,
		policy_temperature
	)
	if policy_samples.is_empty():
		return PureStateCounterfactualBenchmark.evaluate_decision(
			game_state,
			perspective_group,
			opponent_group,
			decision_id,
			config
		)

	# Expected policy value: search-generated responses only. This distribution is
	# computed once from the shared pre-turn state and reused for every own candidate.
	var policy_config := config.duplicate(true)
	policy_config["opponent_samples"] = policy_samples.duplicate(true)
	policy_config["opponent_mixture_version"] = "%s|pre_turn_search_policy_v2" % str(
		config.get("opponent_mixture_version", "unknown")
	)
	var result := PureStateCounterfactualBenchmark.evaluate_decision(
		game_state,
		perspective_group,
		opponent_group,
		decision_id,
		policy_config
	)
	if not bool(result.get("valid", false)):
		return result

	# Authored responses are a completely separate stress pass. Their historical
	# authored weights are retained as metadata only; they never enter policy value.
	var curated_samples := _build_curated_stress_samples(config)
	var curated_by_candidate: Dictionary = {}
	if not curated_samples.is_empty():
		var stress_config := config.duplicate(true)
		stress_config["opponent_samples"] = curated_samples.duplicate(true)
		stress_config["opponent_mixture_version"] = "%s|curated_stress_only_v1" % str(
			config.get("opponent_mixture_version", "unknown")
		)
		var stress_result := PureStateCounterfactualBenchmark.evaluate_decision(
			game_state,
			perspective_group,
			opponent_group,
			"%s|curated_stress" % decision_id,
			stress_config
		)
		if bool(stress_result.get("valid", false)):
			for stress_candidate_variant in stress_result.get("candidate_results", []):
				if not (stress_candidate_variant is Dictionary):
					continue
				var stress_candidate: Dictionary = stress_candidate_variant
				curated_by_candidate[str(stress_candidate.get("candidate_id", ""))] = build_response_diagnostics(
					stress_candidate.get("samples", []) as Array,
					curated_samples
				)

	var conditional_pairwise: Array = (result.get("pairwise_comparisons", []) as Array).duplicate(true)
	for candidate_variant in result.get("candidate_results", []):
		if not (candidate_variant is Dictionary):
			continue
		var candidate: Dictionary = candidate_variant
		var samples: Array = candidate.get("samples", [])
		var enriched := enrich_estimate(samples)
		var response_diagnostics := build_response_diagnostics(samples, policy_samples)
		enriched["response_diagnostics"] = response_diagnostics
		enriched["curated_stress_tests"] = (
			(curated_by_candidate.get(str(candidate.get("candidate_id", "")), []) as Array).duplicate(true)
		)
		var adversarial := _adversarial_bounds(response_diagnostics)
		for key in adversarial.keys():
			enriched[key] = adversarial[key]
		candidate["estimate"] = enriched

	result["benchmark_version"] = BENCHMARK_VERSION
	result["answer_key_version"] = ANSWER_KEY_VERSION
	result["conditional_pairwise_comparisons"] = conditional_pairwise
	result["pairwise_comparisons"] = build_interval_pairwise_comparisons(
		result.get("candidate_results", []) as Array
	)
	result["estimated_best_candidate_ids"] = estimated_interval_best_candidate_ids(
		result.get("candidate_results", []) as Array
	)

	var assumptions: Dictionary = result.get("assumptions", {})
	assumptions["target_semantics"] = "search_policy_terminal_return_with_unresolved_bounds_v2"
	assumptions["opponent_weight_semantics"] = "normalized_search_policy_proxy_not_empirical_behavior_probability"
	assumptions["opponent_policy_semantics"] = "opponent plan scores are computed once from the original pre-turn state and shared across every own candidate"
	assumptions["opponent_policy_temperature"] = policy_temperature
	assumptions["opponent_policy_computed_once_from_pre_turn_state"] = true
	assumptions["curated_response_semantics"] = "authored responses are separate stress tests and never enter policy expected value; authored weights are metadata only"
	assumptions["curated_responses_excluded_from_policy_value"] = true
	assumptions["turn_limit_is_unlabeled"] = true
	assumptions["unresolved_mass_semantics"] = "full-mixture bounds assign every unresolved/invalid unit of weight either -1 or +1"
	assumptions["comparison_rule"] = "prefer_only_when_full_mixture_value_bounds_do_not_overlap"
	assumptions["conditional_mean_semantics"] = "backward-compatible diagnostic over resolved terminal mass only"
	assumptions["opponent_samples"] = _policy_assumptions(policy_samples)
	assumptions["curated_stress_samples"] = _policy_assumptions(curated_samples)
	result["assumptions"] = assumptions
	return result


static func enrich_estimate(samples: Array) -> Dictionary:
	var estimate := PureStateCounterfactualBenchmark.aggregate_samples(samples)
	var total_weight := maxf(0.0, float(estimate.get("total_weight", 0.0)))
	var labeled_weight := maxf(0.0, float(estimate.get("labeled_weight", 0.0)))
	var weighted_return_sum := 0.0
	for sample_variant in samples:
		if not (sample_variant is Dictionary):
			continue
		var sample: Dictionary = sample_variant
		if not bool(sample.get("valid", true)) or not bool(sample.get("labeled", false)):
			continue
		weighted_return_sum += (
			maxf(0.0, float(sample.get("weight", 0.0)))
			* float(sample.get("return", 0.0))
		)

	var coverage := labeled_weight / total_weight if total_weight > 0.0 else 0.0
	var unresolved_fraction := maxf(0.0, 1.0 - coverage) if total_weight > 0.0 else 1.0
	var known_contribution := weighted_return_sum / total_weight if total_weight > 0.0 else 0.0
	var lower_bound := clampf(known_contribution - unresolved_fraction, -1.0, 1.0)
	var upper_bound := clampf(known_contribution + unresolved_fraction, -1.0, 1.0)

	estimate["conditional_labeled_mean_return"] = float(estimate.get("mean_return", 0.0))
	estimate["known_weighted_return_contribution"] = known_contribution
	estimate["unresolved_weight_fraction"] = unresolved_fraction
	estimate["full_mixture_lower_bound"] = lower_bound
	estimate["full_mixture_upper_bound"] = upper_bound
	estimate["full_mixture_midpoint"] = 0.5 * (lower_bound + upper_bound)
	estimate["full_mixture_interval_width"] = upper_bound - lower_bound
	return estimate


static func normalize_policy_samples(samples: Array, temperature: float = DEFAULT_POLICY_TEMPERATURE) -> Array:
	var normalized: Array = []
	for index in range(samples.size()):
		if not (samples[index] is Dictionary):
			continue
		var sample: Dictionary = (samples[index] as Dictionary).duplicate(true)
		sample["sample_id"] = str(sample.get("sample_id", "policy_%02d" % index))
		sample["author_sampling_weight"] = maxf(0.0, float(sample.get(
			"author_sampling_weight",
			sample.get("weight", 0.0)
		)))
		sample["policy_score"] = float(sample.get("policy_score", sample.get("proposal_score", 0.0)))
		normalized.append(sample)
	if normalized.is_empty():
		return []

	var mean_score := 0.0
	for sample in normalized:
		mean_score += float(sample.get("policy_score", 0.0))
	mean_score /= float(normalized.size())
	var variance := 0.0
	var max_score := float(normalized[0].get("policy_score", 0.0))
	for sample in normalized:
		var score := float(sample.get("policy_score", 0.0))
		var delta := score - mean_score
		variance += delta * delta
		max_score = maxf(max_score, score)
	variance /= float(normalized.size())
	var score_scale := maxf(1.0, sqrt(variance))
	var safe_temperature := maxf(0.05, temperature)
	var total_exp := 0.0
	for sample in normalized:
		var logit := (
			(float(sample.get("policy_score", 0.0)) - max_score)
			/ (score_scale * safe_temperature)
		)
		logit = clampf(logit, -20.0, 0.0)
		var exp_weight := exp(logit)
		sample["policy_logit"] = logit
		sample["_exp_weight"] = exp_weight
		total_exp += exp_weight

	var equal_weight := 1.0 / float(normalized.size())
	for sample in normalized:
		var weight := (
			float(sample.get("_exp_weight", 0.0)) / total_exp
			if total_exp > 0.0
			else equal_weight
		)
		sample.erase("_exp_weight")
		sample["search_policy_weight"] = weight
		sample["weight"] = weight
	return normalized


static func build_response_diagnostics(samples: Array, policy_samples: Array) -> Array:
	var policy_by_id: Dictionary = {}
	for sample_variant in policy_samples:
		if sample_variant is Dictionary:
			var sample: Dictionary = sample_variant
			policy_by_id[str(sample.get("sample_id", ""))] = sample

	var grouped: Dictionary = {}
	for sample_variant in samples:
		if not (sample_variant is Dictionary):
			continue
		var sample: Dictionary = sample_variant
		var response_id := str(sample.get("opponent_sample_id", ""))
		if response_id.is_empty():
			continue
		if not grouped.has(response_id):
			grouped[response_id] = []
		(grouped[response_id] as Array).append(sample.duplicate(true))

	var response_ids: Array = grouped.keys()
	response_ids.sort()
	var result: Array = []
	for response_id_variant in response_ids:
		var response_id := str(response_id_variant)
		var local_samples: Array = grouped.get(response_id, [])
		var estimate := enrich_estimate(local_samples)
		var policy: Dictionary = policy_by_id.get(response_id, {})
		result.append({
			"opponent_sample_id": response_id,
			"profile_id": str(policy.get("profile_id", "")),
			"intent": str(policy.get("intent", "")),
			"source": str(policy.get("source", "unknown")),
			"curated": bool(policy.get("curated", false)),
			"author_sampling_weight": float(policy.get("author_sampling_weight", 0.0)),
			"search_policy_weight": float(policy.get("search_policy_weight", 0.0)),
			"policy_score": float(policy.get("policy_score", 0.0)),
			"conditional_labeled_mean_return": float(estimate.get("conditional_labeled_mean_return", 0.0)),
			"labeled_weight_fraction": float(estimate.get("labeled_weight_fraction", 0.0)),
			"full_mixture_lower_bound": float(estimate.get("full_mixture_lower_bound", -1.0)),
			"full_mixture_upper_bound": float(estimate.get("full_mixture_upper_bound", 1.0)),
		})
	return result


static func build_interval_pairwise_comparisons(candidate_results: Array) -> Array:
	var comparisons: Array = []
	for left_index in range(candidate_results.size()):
		if not (candidate_results[left_index] is Dictionary):
			continue
		var left: Dictionary = candidate_results[left_index]
		var left_estimate: Dictionary = left.get("estimate", {})
		var left_lower := float(left_estimate.get("full_mixture_lower_bound", -1.0))
		var left_upper := float(left_estimate.get("full_mixture_upper_bound", 1.0))
		for right_index in range(left_index + 1, candidate_results.size()):
			if not (candidate_results[right_index] is Dictionary):
				continue
			var right: Dictionary = candidate_results[right_index]
			var right_estimate: Dictionary = right.get("estimate", {})
			var right_lower := float(right_estimate.get("full_mixture_lower_bound", -1.0))
			var right_upper := float(right_estimate.get("full_mixture_upper_bound", 1.0))
			var preferred := "uncertain"
			var comparable := false
			if left_lower > right_upper and not is_equal_approx(left_lower, right_upper):
				preferred = str(left.get("candidate_id", ""))
				comparable = true
			elif right_lower > left_upper and not is_equal_approx(right_lower, left_upper):
				preferred = str(right.get("candidate_id", ""))
				comparable = true
			elif is_equal_approx(left_lower, right_lower) and is_equal_approx(left_upper, right_upper) and is_equal_approx(left_lower, left_upper):
				preferred = "tie"
			comparisons.append({
				"left_candidate_id": str(left.get("candidate_id", "")),
				"right_candidate_id": str(right.get("candidate_id", "")),
				"left_lower_bound": left_lower,
				"left_upper_bound": left_upper,
				"right_lower_bound": right_lower,
				"right_upper_bound": right_upper,
				"comparable": comparable,
				"preferred_candidate_id": preferred,
				"comparison_semantics": "full_mixture_interval_dominance",
			})
	return comparisons


static func estimated_interval_best_candidate_ids(candidate_results: Array) -> Array:
	var result: Array = []
	for candidate_variant in candidate_results:
		if not (candidate_variant is Dictionary):
			continue
		var candidate: Dictionary = candidate_variant
		var candidate_id := str(candidate.get("candidate_id", ""))
		var candidate_estimate: Dictionary = candidate.get("estimate", {})
		var candidate_upper := float(candidate_estimate.get("full_mixture_upper_bound", 1.0))
		var dominated := false
		for other_variant in candidate_results:
			if not (other_variant is Dictionary):
				continue
			var other: Dictionary = other_variant
			if str(other.get("candidate_id", "")) == candidate_id:
				continue
			var other_estimate: Dictionary = other.get("estimate", {})
			var other_lower := float(other_estimate.get("full_mixture_lower_bound", -1.0))
			if other_lower > candidate_upper and not is_equal_approx(other_lower, candidate_upper):
				dominated = true
				break
		if not dominated:
			result.append(candidate_id)
	return result


static func _build_search_policy_samples(
	game_state: Dictionary,
	perspective_group: String,
	opponent_group: String,
	config: Dictionary,
	temperature: float
) -> Array:
	var policy_max_actions := maxi(1, int(config.get(
		"opponent_policy_max_actions_per_unit",
		DEFAULT_POLICY_MAX_ACTIONS_PER_UNIT
	)))
	var policy_max_plans := maxi(1, int(config.get(
		"opponent_policy_max_plans",
		DEFAULT_POLICY_MAX_PLANS
	)))
	var response_max_actions := maxi(1, int(config.get(
		"opponent_policy_response_max_actions_per_unit",
		config.get("own_max_actions_per_unit", DEFAULT_POLICY_MAX_ACTIONS_PER_UNIT)
	)))
	var response_max_plans := maxi(1, int(config.get(
		"opponent_policy_response_max_plans",
		DEFAULT_POLICY_RESPONSE_MAX_PLANS
	)))

	var generated: Array = []
	var search := PureStateOpponentResponseSearch.search(
		game_state,
		opponent_group,
		perspective_group,
		policy_max_actions,
		policy_max_plans,
		response_max_actions,
		response_max_plans
	)
	if bool(search.get("valid", false)):
		var ranked: Array = search.get("ranked_results", [])
		for index in range(mini(policy_max_plans, ranked.size())):
			if not (ranked[index] is Dictionary):
				continue
			var row: Dictionary = ranked[index]
			generated.append({
				"sample_id": "search_policy_%02d" % index,
				"profile_id": "pre_turn_opponent_response_search",
				"actions": (row.get("actions", []) as Array).duplicate(true),
				"proposal_score": float(row.get("proposal_score", 0.0)),
				"policy_score": float(row.get("worst_case_score", row.get("average_score", 0.0))),
				"policy_average_score": float(row.get("average_score", 0.0)),
				"intent": str(row.get("intent", "")),
				"source": "search",
				"curated": false,
				"author_sampling_weight": 0.0,
			})
	else:
		var plans := PureStatePlans.get_candidate_plans(
			game_state,
			opponent_group,
			policy_max_actions,
			policy_max_plans,
			true
		)
		for index in range(plans.size()):
			if not (plans[index] is Dictionary):
				continue
			var plan: Dictionary = plans[index]
			generated.append({
				"sample_id": "proposal_fallback_%02d" % index,
				"profile_id": "proposal_fallback",
				"actions": (plan.get("actions", []) as Array).duplicate(true),
				"proposal_score": float(plan.get("proposal_score", 0.0)),
				"policy_score": float(plan.get("proposal_score", 0.0)),
				"intent": str(plan.get("intent", "")),
				"source": "proposal_fallback",
				"curated": false,
				"author_sampling_weight": 0.0,
			})

	# Deduplicate identical action plans before softmax weighting. The same plan can
	# surface through different intent-preserving search paths.
	var unique: Array = []
	var seen: Dictionary = {}
	for sample_variant in generated:
		if not (sample_variant is Dictionary):
			continue
		var sample: Dictionary = sample_variant
		var signature := _plan_signature(sample.get("actions", []))
		if seen.has(signature):
			continue
		seen[signature] = true
		unique.append(sample.duplicate(true))
	if unique.is_empty():
		unique = [{
			"sample_id": "opponent_no_action",
			"profile_id": "forced_no_action",
			"actions": [],
			"proposal_score": 0.0,
			"policy_score": 0.0,
			"intent": "hold",
			"source": "fallback",
			"curated": false,
			"author_sampling_weight": 0.0,
		}]
	return normalize_policy_samples(unique, temperature)


static func _build_curated_stress_samples(config: Dictionary) -> Array:
	var raw_variant = config.get("opponent_samples", [])
	if not (raw_variant is Array):
		return []
	var result: Array = []
	for index in range((raw_variant as Array).size()):
		var raw_sample_variant = (raw_variant as Array)[index]
		if not (raw_sample_variant is Dictionary):
			continue
		var raw_sample: Dictionary = raw_sample_variant
		result.append({
			"sample_id": str(raw_sample.get("sample_id", "curated_%02d" % index)),
			"profile_id": str(raw_sample.get("profile_id", "curated_stress")),
			"actions": (raw_sample.get("actions", []) as Array).duplicate(true),
			"proposal_score": float(raw_sample.get("proposal_score", 0.0)),
			"policy_score": 0.0,
			"intent": str(raw_sample.get("intent", "")),
			"source": "curated_stress",
			"curated": true,
			"author_sampling_weight": maxf(0.0, float(raw_sample.get("weight", 0.0))),
			# Equal evaluation allocation only; this weight is never used in policy value.
			"weight": 1.0,
			"search_policy_weight": 0.0,
		})
	return result


static func _adversarial_bounds(response_diagnostics: Array) -> Dictionary:
	if response_diagnostics.is_empty():
		return {
			"best_response_value_lower_bound": -1.0,
			"best_response_value_upper_bound": 1.0,
			"best_response_opponent_sample_id": "",
		}
	var lower := 1.0
	var upper := 1.0
	var worst_id := ""
	var worst_midpoint := INF
	for response_variant in response_diagnostics:
		if not (response_variant is Dictionary):
			continue
		var response: Dictionary = response_variant
		var response_lower := float(response.get("full_mixture_lower_bound", -1.0))
		var response_upper := float(response.get("full_mixture_upper_bound", 1.0))
		lower = minf(lower, response_lower)
		upper = minf(upper, response_upper)
		var midpoint := 0.5 * (response_lower + response_upper)
		var response_id := str(response.get("opponent_sample_id", ""))
		if midpoint < worst_midpoint or (
			is_equal_approx(midpoint, worst_midpoint)
			and (worst_id.is_empty() or response_id < worst_id)
		):
			worst_midpoint = midpoint
			worst_id = response_id
	return {
		"best_response_value_lower_bound": lower,
		"best_response_value_upper_bound": upper,
		"best_response_opponent_sample_id": worst_id,
	}


static func _policy_assumptions(policy_samples: Array) -> Array:
	var result: Array = []
	for sample_variant in policy_samples:
		if not (sample_variant is Dictionary):
			continue
		var sample: Dictionary = sample_variant
		result.append({
			"sample_id": str(sample.get("sample_id", "")),
			"profile_id": str(sample.get("profile_id", "")),
			"intent": str(sample.get("intent", "")),
			"source": str(sample.get("source", "")),
			"curated": bool(sample.get("curated", false)),
			"author_sampling_weight": float(sample.get("author_sampling_weight", 0.0)),
			"policy_score": float(sample.get("policy_score", 0.0)),
			"search_policy_weight": float(sample.get("search_policy_weight", 0.0)),
			"plan_signature": _plan_signature(sample.get("actions", [])),
		})
	return result


static func _plan_signature(actions_variant: Variant) -> String:
	if not (actions_variant is Array):
		return ""
	var parts := PackedStringArray()
	for action_variant in actions_variant:
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
