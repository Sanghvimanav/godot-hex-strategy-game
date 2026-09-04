extends RefCounted
class_name PureStateCounterfactualBenchmark
## Policy-conditional counterfactual evaluation for candidate joint plans.
##
## These results are estimates, not oracle labels. Each own candidate is evaluated
## against a versioned weighted mixture of simultaneous opponent plans. Nonterminal
## resulting states are then played out by versioned continuation search profiles.
## Turn-limit and failed continuations remain explicitly unlabeled.

const PureStatePlans = preload("res://src/simulation/pure_state_plans.gd")
const PureStateSimulator = preload("res://src/simulation/pure_state_simulator.gd")
const PureStateGameRollout = preload("res://src/simulation/pure_state_game_rollout.gd")

const SCHEMA_VERSION := 1
const BENCHMARK_VERSION := 1
const DEFAULT_OPPONENT_MIXTURE_VERSION := "proposal_mixture_v1"
const DEFAULT_CONTINUATION_MIXTURE_VERSION := "search_budget_mixture_v1"

const DEFAULT_OPPONENT_PROFILES := [
	{
		"profile_id": "proposal_fast",
		"max_actions_per_unit": 3,
		"max_plans": 2,
		"preserve_intent_diversity": false,
		"weight": 0.5,
	},
	{
		"profile_id": "proposal_balanced",
		"max_actions_per_unit": 8,
		"max_plans": 4,
		"preserve_intent_diversity": true,
		"weight": 0.5,
	},
]

const DEFAULT_CONTINUATION_PROFILES := [
	{
		"profile_id": "search_fast_2x2",
		"max_turns": 6,
		"max_actions_per_unit": 8,
		"own_max_plans": 2,
		"opponent_max_plans": 2,
		"weight": 0.5,
	},
	{
		"profile_id": "search_balanced_4x4",
		"max_turns": 8,
		"max_actions_per_unit": 8,
		"own_max_plans": 4,
		"opponent_max_plans": 4,
		"weight": 0.5,
	},
]


static func evaluate_decision(
	game_state: Dictionary,
	perspective_group: String,
	opponent_group: String,
	decision_id: String,
	config: Dictionary = {}
) -> Dictionary:
	var invalid := _empty_result(game_state, perspective_group, opponent_group, decision_id)
	if game_state.is_empty() or decision_id.is_empty():
		return invalid
	if perspective_group.is_empty() or opponent_group.is_empty() or perspective_group == opponent_group:
		return invalid
	if not _has_group(game_state, perspective_group) or not _has_group(game_state, opponent_group):
		return invalid

	var own_candidates := _get_own_candidates(game_state, perspective_group, config)
	var opponent_samples := _get_opponent_samples(game_state, opponent_group, config)
	var continuation_profiles := _get_continuation_profiles(config)
	if own_candidates.is_empty() or opponent_samples.is_empty():
		return invalid

	var include_states := bool(config.get("include_states", true))
	var candidate_results: Array = []
	for candidate_index in range(own_candidates.size()):
		var candidate: Dictionary = own_candidates[candidate_index]
		var candidate_id := str(candidate.get("candidate_id", "candidate_%02d" % candidate_index))
		var actions: Array = (candidate.get("actions", []) as Array).duplicate(true)
		var samples: Array = []
		for opponent_variant in opponent_samples:
			if not (opponent_variant is Dictionary):
				continue
			var opponent_sample: Dictionary = opponent_variant
			var opponent_actions: Array = (opponent_sample.get("actions", []) as Array).duplicate(true)
			var submitted := _submitted_actions(
				game_state,
				perspective_group,
				actions,
				opponent_group,
				opponent_actions
			)
			var simulation := PureStateSimulator.simulate_turn(game_state, submitted)
			var next_state: Dictionary = simulation.get("next_state", {})
			if next_state.is_empty():
				samples.append(_invalid_sample(candidate_id, opponent_sample, "simulation_failed"))
				continue

			var immediate := _terminal_outcome(next_state, perspective_group, opponent_group)
			if bool(immediate.get("terminal", false)):
				var terminal_sample := _terminal_sample(
					candidate_id,
					opponent_sample,
					"terminal_after_joint_turn",
					float(opponent_sample.get("weight", 0.0)),
					str(immediate.get("winner", "")),
					perspective_group,
					opponent_group
				)
				if include_states:
					terminal_sample["state_after_first_turn"] = next_state.duplicate(true)
				samples.append(terminal_sample)
				continue

			if continuation_profiles.is_empty():
				var unlabeled := _unlabeled_sample(
					candidate_id,
					opponent_sample,
					"no_continuation",
					float(opponent_sample.get("weight", 0.0))
				)
				if include_states:
					unlabeled["state_after_first_turn"] = next_state.duplicate(true)
				samples.append(unlabeled)
				continue

			for continuation_variant in continuation_profiles:
				if not (continuation_variant is Dictionary):
					continue
				var continuation: Dictionary = continuation_variant
				var sample_weight := (
					float(opponent_sample.get("weight", 0.0))
					* float(continuation.get("weight", 0.0))
				)
				var rollout := PureStateGameRollout.play_game(
					next_state,
					perspective_group,
					opponent_group,
					int(continuation.get("max_turns", 1)),
					int(continuation.get("max_actions_per_unit", 1)),
					int(continuation.get("own_max_plans", 1)),
					int(continuation.get("opponent_max_plans", 1)),
					false
				)
				var sample := _sample_from_rollout(
					candidate_id,
					opponent_sample,
					continuation,
					sample_weight,
					rollout,
					perspective_group,
					opponent_group
				)
				if include_states:
					sample["state_after_first_turn"] = next_state.duplicate(true)
				samples.append(sample)

		var estimate := aggregate_samples(samples)
		candidate_results.append({
			"candidate_id": candidate_id,
			"candidate_index": candidate_index,
			"candidate_label": str(candidate.get("candidate_label", candidate_id)),
			"candidate_description": str(candidate.get("candidate_description", "")),
			"plan_signature": _plan_signature(actions),
			"actions": actions,
			"proposal_score": float(candidate.get("proposal_score", 0.0)),
			"estimate": estimate,
			"samples": samples,
		})

	var separation_z := float(config.get("separation_z", 1.96))
	var pairwise := build_pairwise_comparisons(candidate_results, separation_z)
	var result := {
		"valid": not candidate_results.is_empty(),
		"schema_version": SCHEMA_VERSION,
		"benchmark_version": BENCHMARK_VERSION,
		"decision_id": decision_id,
		"perspective_group": perspective_group,
		"opponent_group": opponent_group,
		"source_state": game_state.duplicate(true),
		"candidate_results": candidate_results,
		"pairwise_comparisons": pairwise,
		"estimated_best_candidate_ids": _estimated_best_candidate_ids(candidate_results, separation_z),
		"assumptions": {
			"rules_version": str(config.get("rules_version", "unknown")),
			"opponent_mixture_version": str(config.get(
				"opponent_mixture_version",
				DEFAULT_OPPONENT_MIXTURE_VERSION
			)),
			"continuation_mixture_version": str(config.get(
				"continuation_mixture_version",
				DEFAULT_CONTINUATION_MIXTURE_VERSION
			)),
			"opponent_samples": _sample_assumptions(opponent_samples),
			"continuation_profiles": continuation_profiles.duplicate(true),
			"separation_z": separation_z,
			"turn_limit_is_unlabeled": true,
			"target_semantics": "policy_conditional_terminal_return_estimate",
			"uncertainty_semantics": "descriptive_between_policy_sample_spread_not_statistical_confidence",
			"comparison_rule": "prefer_only_when_mean_gap_exceeds_separation_z_times_combined_policy_standard_error",
		},
	}
	return result


static func aggregate_samples(samples: Array) -> Dictionary:
	var total_weight := 0.0
	var labeled_weight := 0.0
	var labeled_weight_squared := 0.0
	var weighted_return_sum := 0.0
	var labeled_returns: Array = []
	var wins := 0
	var draws := 0
	var losses := 0
	var unlabeled := 0
	var invalid := 0
	var win_weight := 0.0
	var draw_weight := 0.0
	var loss_weight := 0.0

	for sample_variant in samples:
		if not (sample_variant is Dictionary):
			continue
		var sample: Dictionary = sample_variant
		var weight := maxf(0.0, float(sample.get("weight", 0.0)))
		total_weight += weight
		if not bool(sample.get("valid", true)):
			invalid += 1
			continue
		if not bool(sample.get("labeled", false)):
			unlabeled += 1
			continue
		var return_value := float(sample.get("return", 0.0))
		labeled_returns.append(return_value)
		labeled_weight += weight
		labeled_weight_squared += weight * weight
		weighted_return_sum += weight * return_value
		if return_value > 0.0:
			wins += 1
			win_weight += weight
		elif return_value < 0.0:
			losses += 1
			loss_weight += weight
		else:
			draws += 1
			draw_weight += weight

	if labeled_weight <= 0.0:
		return {
			"status": "unlabeled",
			"sample_count": samples.size(),
			"return_count": 0,
			"unlabeled_count": unlabeled,
			"invalid_count": invalid,
			"total_weight": total_weight,
			"labeled_weight": 0.0,
			"labeled_weight_fraction": 0.0,
			"mean_return": 0.0,
			"return_stddev": 0.0,
			"estimated_standard_error": 0.0,
			"effective_sample_size": 0.0,
			"worst_case_return": 0.0,
			"best_case_return": 0.0,
			"wins": 0,
			"draws": 0,
			"losses": 0,
			"win_weight": 0.0,
			"draw_weight": 0.0,
			"loss_weight": 0.0,
		}

	var mean_return := weighted_return_sum / labeled_weight
	var weighted_variance := 0.0
	for sample_variant in samples:
		if not (sample_variant is Dictionary):
			continue
		var sample: Dictionary = sample_variant
		if not bool(sample.get("valid", true)) or not bool(sample.get("labeled", false)):
			continue
		var weight := maxf(0.0, float(sample.get("weight", 0.0)))
		var delta := float(sample.get("return", 0.0)) - mean_return
		weighted_variance += weight * delta * delta
	weighted_variance /= labeled_weight

	var effective_sample_size := 0.0
	if labeled_weight_squared > 0.0:
		effective_sample_size = labeled_weight * labeled_weight / labeled_weight_squared
	var standard_error := 0.0
	if effective_sample_size > 0.0:
		standard_error = sqrt(weighted_variance / effective_sample_size)

	var worst := float(labeled_returns[0])
	var best := worst
	for value_variant in labeled_returns:
		var value := float(value_variant)
		worst = minf(worst, value)
		best = maxf(best, value)

	return {
		"status": "estimated",
		"sample_count": samples.size(),
		"return_count": labeled_returns.size(),
		"unlabeled_count": unlabeled,
		"invalid_count": invalid,
		"total_weight": total_weight,
		"labeled_weight": labeled_weight,
		"labeled_weight_fraction": labeled_weight / total_weight if total_weight > 0.0 else 0.0,
		"mean_return": mean_return,
		"return_stddev": sqrt(weighted_variance),
		"estimated_standard_error": standard_error,
		"effective_sample_size": effective_sample_size,
		"worst_case_return": worst,
		"best_case_return": best,
		"wins": wins,
		"draws": draws,
		"losses": losses,
		"win_weight": win_weight,
		"draw_weight": draw_weight,
		"loss_weight": loss_weight,
	}


static func build_pairwise_comparisons(candidate_results: Array, separation_z: float = 1.96) -> Array:
	var comparisons: Array = []
	for left_index in range(candidate_results.size()):
		if not (candidate_results[left_index] is Dictionary):
			continue
		var left: Dictionary = candidate_results[left_index]
		var left_estimate: Dictionary = left.get("estimate", {})
		if int(left_estimate.get("return_count", 0)) <= 0:
			continue
		for right_index in range(left_index + 1, candidate_results.size()):
			if not (candidate_results[right_index] is Dictionary):
				continue
			var right: Dictionary = candidate_results[right_index]
			var right_estimate: Dictionary = right.get("estimate", {})
			if int(right_estimate.get("return_count", 0)) <= 0:
				continue
			var difference := (
				float(left_estimate.get("mean_return", 0.0))
				- float(right_estimate.get("mean_return", 0.0))
			)
			var combined_error := sqrt(
				pow(float(left_estimate.get("estimated_standard_error", 0.0)), 2.0)
				+ pow(float(right_estimate.get("estimated_standard_error", 0.0)), 2.0)
			)
			var threshold := maxf(0.0, separation_z) * combined_error
			var comparable := absf(difference) > threshold and not is_equal_approx(difference, 0.0)
			var preferred := "uncertain"
			if comparable:
				preferred = (
					str(left.get("candidate_id", ""))
					if difference > 0.0
					else str(right.get("candidate_id", ""))
				)
			elif is_equal_approx(difference, 0.0) and is_zero_approx(combined_error):
				preferred = "tie"
			comparisons.append({
				"left_candidate_id": str(left.get("candidate_id", "")),
				"right_candidate_id": str(right.get("candidate_id", "")),
				"estimated_return_difference": difference,
				"combined_standard_error": combined_error,
				"separation_threshold": threshold,
				"comparable": comparable,
				"preferred_candidate_id": preferred,
			})
	return comparisons


static func to_candidate_rows(result: Dictionary) -> Array:
	if not bool(result.get("valid", false)):
		return []
	var rows: Array = []
	for candidate_variant in result.get("candidate_results", []):
		if not (candidate_variant is Dictionary):
			continue
		var candidate: Dictionary = candidate_variant
		rows.append({
			"schema_version": int(result.get("schema_version", SCHEMA_VERSION)),
			"benchmark_version": int(result.get("benchmark_version", BENCHMARK_VERSION)),
			"decision_id": str(result.get("decision_id", "")),
			"candidate_id": str(candidate.get("candidate_id", "")),
			"candidate_label": str(candidate.get("candidate_label", candidate.get("candidate_id", ""))),
			"candidate_description": str(candidate.get("candidate_description", "")),
			"perspective_group": str(result.get("perspective_group", "")),
			"opponent_group": str(result.get("opponent_group", "")),
			"plan_signature": str(candidate.get("plan_signature", "")),
			"actions": (candidate.get("actions", []) as Array).duplicate(true),
			"proposal_score": float(candidate.get("proposal_score", 0.0)),
			"target_estimate": (candidate.get("estimate", {}) as Dictionary).duplicate(true),
			"samples": (candidate.get("samples", []) as Array).duplicate(true),
			"source_state": (result.get("source_state", {}) as Dictionary).duplicate(true),
			"assumptions": (result.get("assumptions", {}) as Dictionary).duplicate(true),
		})
	return rows


static func to_jsonl(rows: Array) -> String:
	var lines := PackedStringArray()
	for row_variant in rows:
		if row_variant is Dictionary:
			lines.append(JSON.stringify(row_variant))
	return "\n".join(lines) + ("\n" if not lines.is_empty() else "")


static func _get_own_candidates(game_state: Dictionary, group_name: String, config: Dictionary) -> Array:
	if config.has("own_candidates"):
		return _normalize_own_candidates(config.get("own_candidates", []))
	var max_actions := int(config.get("own_max_actions_per_unit", 8))
	var max_plans := int(config.get("own_max_plans", 8))
	var generated := PureStatePlans.get_candidate_plans(
		game_state,
		group_name,
		max_actions,
		max_plans,
		true
	)
	return _normalize_own_candidates(generated)


static func _normalize_own_candidates(raw_candidates: Variant) -> Array:
	if not (raw_candidates is Array):
		return []
	var result: Array = []
	for index in range((raw_candidates as Array).size()):
		var candidate_variant = (raw_candidates as Array)[index]
		if not (candidate_variant is Dictionary):
			continue
		var candidate: Dictionary = (candidate_variant as Dictionary).duplicate(true)
		var actions = candidate.get("actions", [])
		if not (actions is Array):
			continue
		candidate["candidate_id"] = str(candidate.get("candidate_id", "candidate_%02d" % index))
		candidate["actions"] = (actions as Array).duplicate(true)
		result.append(candidate)
	return result


static func _get_opponent_samples(game_state: Dictionary, group_name: String, config: Dictionary) -> Array:
	if config.has("opponent_samples"):
		var explicit = config.get("opponent_samples", [])
		if explicit is Array and not (explicit as Array).is_empty():
			return _normalize_weighted_samples(explicit as Array)
		return [{
			"sample_id": "opponent_no_action",
			"profile_id": "explicit_empty",
			"actions": [],
			"weight": 1.0,
		}]

	var profiles_variant = config.get("opponent_profiles", DEFAULT_OPPONENT_PROFILES)
	if not (profiles_variant is Array):
		return []
	var samples: Array = []
	for profile_variant in profiles_variant:
		if not (profile_variant is Dictionary):
			continue
		var profile: Dictionary = profile_variant
		var plans := PureStatePlans.get_candidate_plans(
			game_state,
			group_name,
			int(profile.get("max_actions_per_unit", 3)),
			int(profile.get("max_plans", 1)),
			bool(profile.get("preserve_intent_diversity", false))
		)
		if plans.is_empty():
			continue
		var profile_weight := maxf(0.0, float(profile.get("weight", 1.0)))
		var plan_weight := profile_weight / float(plans.size())
		for plan_index in range(plans.size()):
			var plan: Dictionary = plans[plan_index]
			samples.append({
				"sample_id": "%s_plan_%02d" % [str(profile.get("profile_id", "profile")), plan_index],
				"profile_id": str(profile.get("profile_id", "profile")),
				"actions": (plan.get("actions", []) as Array).duplicate(true),
				"proposal_score": float(plan.get("proposal_score", 0.0)),
				"weight": plan_weight,
			})
	return _normalize_weighted_samples(samples)


static func _get_continuation_profiles(config: Dictionary) -> Array:
	var profiles_variant = (
		config.get("continuation_profiles", [])
		if config.has("continuation_profiles")
		else DEFAULT_CONTINUATION_PROFILES
	)
	if not (profiles_variant is Array):
		return []
	var profiles: Array = []
	for profile_variant in profiles_variant:
		if profile_variant is Dictionary:
			profiles.append((profile_variant as Dictionary).duplicate(true))
	return _normalize_weighted_samples(profiles, "profile_id")


static func _normalize_weighted_samples(samples: Array, id_key: String = "sample_id") -> Array:
	var result: Array = []
	var total_weight := 0.0
	for index in range(samples.size()):
		if not (samples[index] is Dictionary):
			continue
		var sample: Dictionary = (samples[index] as Dictionary).duplicate(true)
		sample[id_key] = str(sample.get(id_key, "%s_%02d" % [id_key, index]))
		sample["weight"] = maxf(0.0, float(sample.get("weight", 1.0)))
		total_weight += float(sample["weight"])
		result.append(sample)
	if result.is_empty():
		return []
	if total_weight <= 0.0:
		var equal_weight := 1.0 / float(result.size())
		for sample in result:
			sample["weight"] = equal_weight
	else:
		for sample in result:
			sample["weight"] = float(sample.get("weight", 0.0)) / total_weight
	return result


static func _terminal_sample(
	candidate_id: String,
	opponent_sample: Dictionary,
	continuation_profile_id: String,
	weight: float,
	winner: String,
	perspective_group: String,
	opponent_group: String
) -> Dictionary:
	return {
		"sample_id": "%s|%s|%s" % [
			candidate_id,
			str(opponent_sample.get("sample_id", "")),
			continuation_profile_id,
		],
		"valid": true,
		"labeled": true,
		"status": "terminal",
		"winner": winner,
		"return": _return_for_winner(winner, perspective_group, opponent_group),
		"weight": weight,
		"opponent_sample_id": str(opponent_sample.get("sample_id", "")),
		"opponent_profile_id": str(opponent_sample.get("profile_id", "")),
		"opponent_actions": (opponent_sample.get("actions", []) as Array).duplicate(true),
		"continuation_profile_id": continuation_profile_id,
	}


static func _sample_from_rollout(
	candidate_id: String,
	opponent_sample: Dictionary,
	continuation: Dictionary,
	weight: float,
	rollout: Dictionary,
	perspective_group: String,
	opponent_group: String
) -> Dictionary:
	var profile_id := str(continuation.get("profile_id", "continuation"))
	var valid := bool(rollout.get("valid", false))
	var status := str(rollout.get("status", "invalid"))
	if valid and status == "terminal":
		return _terminal_sample(
			candidate_id,
			opponent_sample,
			profile_id,
			weight,
			str(rollout.get("winner", "")),
			perspective_group,
			opponent_group
		)
	var sample := _unlabeled_sample(candidate_id, opponent_sample, profile_id, weight)
	sample["valid"] = valid
	sample["status"] = status
	sample["turns_played"] = int(rollout.get("turns_played", 0))
	return sample


static func _unlabeled_sample(
	candidate_id: String,
	opponent_sample: Dictionary,
	continuation_profile_id: String,
	weight: float
) -> Dictionary:
	return {
		"sample_id": "%s|%s|%s" % [
			candidate_id,
			str(opponent_sample.get("sample_id", "")),
			continuation_profile_id,
		],
		"valid": true,
		"labeled": false,
		"status": "unlabeled",
		"winner": "",
		"return": null,
		"weight": weight,
		"opponent_sample_id": str(opponent_sample.get("sample_id", "")),
		"opponent_profile_id": str(opponent_sample.get("profile_id", "")),
		"opponent_actions": (opponent_sample.get("actions", []) as Array).duplicate(true),
		"continuation_profile_id": continuation_profile_id,
	}


static func _invalid_sample(candidate_id: String, opponent_sample: Dictionary, status: String) -> Dictionary:
	var sample := _unlabeled_sample(
		candidate_id,
		opponent_sample,
		"not_started",
		float(opponent_sample.get("weight", 0.0))
	)
	sample["valid"] = false
	sample["status"] = status
	return sample


static func _return_for_winner(winner: String, perspective_group: String, opponent_group: String) -> float:
	if winner == perspective_group:
		return 1.0
	if winner == opponent_group:
		return -1.0
	return 0.0


static func _terminal_outcome(state: Dictionary, group_a: String, group_b: String) -> Dictionary:
	var alive_a := _alive_count(state, group_a)
	var alive_b := _alive_count(state, group_b)
	if alive_a <= 0 and alive_b <= 0:
		return {"terminal": true, "winner": ""}
	if alive_a <= 0:
		return {"terminal": true, "winner": group_b}
	if alive_b <= 0:
		return {"terminal": true, "winner": group_a}
	return {"terminal": false, "winner": ""}


static func _alive_count(state: Dictionary, group_name: String) -> int:
	for group_variant in state.get("groups", []):
		if not (group_variant is Dictionary):
			continue
		var group: Dictionary = group_variant
		if str(group.get("name", "")) != group_name:
			continue
		var result := 0
		for unit_variant in group.get("units", []):
			if unit_variant is Dictionary and int((unit_variant as Dictionary).get("health", 0)) > 0:
				result += 1
		return result
	return 0


static func _submitted_actions(
	state: Dictionary,
	group_a: String,
	actions_a: Array,
	group_b: String,
	actions_b: Array
) -> Dictionary:
	var submitted: Dictionary = {}
	for group_variant in state.get("groups", []):
		if group_variant is Dictionary:
			var name := str((group_variant as Dictionary).get("name", ""))
			if not name.is_empty():
				submitted[name] = []
	submitted[group_a] = actions_a.duplicate(true)
	submitted[group_b] = actions_b.duplicate(true)
	return submitted


static func _estimated_best_candidate_ids(candidate_results: Array, separation_z: float) -> Array:
	var labeled: Array = []
	for candidate_variant in candidate_results:
		if not (candidate_variant is Dictionary):
			continue
		var candidate: Dictionary = candidate_variant
		var estimate: Dictionary = candidate.get("estimate", {})
		if int(estimate.get("return_count", 0)) > 0:
			labeled.append(candidate)
	if labeled.is_empty():
		return []
	var best: Dictionary = labeled[0]
	for candidate_variant in labeled:
		var candidate: Dictionary = candidate_variant
		if float((candidate.get("estimate", {}) as Dictionary).get("mean_return", 0.0)) > float(
			(best.get("estimate", {}) as Dictionary).get("mean_return", 0.0)
		):
			best = candidate
	var best_estimate: Dictionary = best.get("estimate", {})
	var best_mean := float(best_estimate.get("mean_return", 0.0))
	var best_error := float(best_estimate.get("estimated_standard_error", 0.0))
	var result: Array = []
	for candidate_variant in labeled:
		var candidate: Dictionary = candidate_variant
		var estimate: Dictionary = candidate.get("estimate", {})
		var difference := best_mean - float(estimate.get("mean_return", 0.0))
		var combined_error := sqrt(
			pow(best_error, 2.0)
				+ pow(float(estimate.get("estimated_standard_error", 0.0)), 2.0)
		)
		if difference <= maxf(0.0, separation_z) * combined_error or is_zero_approx(difference):
			result.append(str(candidate.get("candidate_id", "")))
	return result


static func _sample_assumptions(samples: Array) -> Array:
	var result: Array = []
	for sample_variant in samples:
		if not (sample_variant is Dictionary):
			continue
		var sample: Dictionary = sample_variant
		result.append({
			"sample_id": str(sample.get("sample_id", "")),
			"profile_id": str(sample.get("profile_id", "")),
			"weight": float(sample.get("weight", 0.0)),
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


static func _has_group(state: Dictionary, group_name: String) -> bool:
	for group_variant in state.get("groups", []):
		if group_variant is Dictionary and str((group_variant as Dictionary).get("name", "")) == group_name:
			return true
	return false


static func _empty_result(
	state: Dictionary,
	perspective_group: String,
	opponent_group: String,
	decision_id: String
) -> Dictionary:
	return {
		"valid": false,
		"schema_version": SCHEMA_VERSION,
		"benchmark_version": BENCHMARK_VERSION,
		"decision_id": decision_id,
		"perspective_group": perspective_group,
		"opponent_group": opponent_group,
		"source_state": state.duplicate(true),
		"candidate_results": [],
		"pairwise_comparisons": [],
		"estimated_best_candidate_ids": [],
		"assumptions": {},
	}
