extends Node
## Headless exporter for the coverage-aware counterfactual answer key.
##
## godot --headless --path . res://tools/counterfactual_benchmark.tscn -- \
##   --preset=starter --out=user://counterfactual_benchmark --rules-version=<git-sha>

const PureStateCounterfactualBenchmark = preload("res://src/simulation/pure_state_counterfactual_benchmark.gd")
const PureStateCounterfactualAnswerKey = preload("res://src/simulation/pure_state_counterfactual_answer_key.gd")
const PureStateCounterfactualSuite = preload("res://src/simulation/pure_state_counterfactual_suite.gd")
const DeterministicShard = preload("res://tools/deterministic_shard.gd")

const MANIFEST_SCHEMA_VERSION := 2


func _ready() -> void:
	call_deferred("_run_benchmark")


func _run_benchmark() -> void:
	var args := _parse_cmdline_kv()
	var preset := str(args.get("preset", "starter"))
	var out_dir := str(args.get("out", "user://counterfactual_benchmark"))
	var rules_version := str(args.get("rules-version", "unknown"))
	var max_decisions := int(args.get("max-decisions", "0"))
	var decision_id_filter := str(args.get("decision-id", ""))
	var shard_index := int(args.get("shard-index", "0"))
	var shard_count := int(args.get("shard-count", "1"))
	if shard_count <= 0 or shard_index < 0 or shard_index >= shard_count:
		push_error("Invalid counterfactual shard %d/%d" % [shard_index, shard_count])
		get_tree().quit(1)
		return

	var jobs: Array = PureStateCounterfactualSuite.get_preset(preset, rules_version)
	if not decision_id_filter.is_empty():
		jobs = jobs.filter(func(job):
			return job is Dictionary and str((job as Dictionary).get("decision_id", "")) == decision_id_filter
		)
	if jobs.is_empty():
		push_error("Unknown/empty counterfactual preset or decision filter '%s'. Available: %s" % [
			preset,
			str(PureStateCounterfactualSuite.available_presets()),
		])
		get_tree().quit(1)
		return
	if max_decisions > 0 and max_decisions < jobs.size():
		jobs = jobs.slice(0, max_decisions)

	var preset_decisions_considered := jobs.size()
	var benchmark_config: Dictionary = {}
	if not jobs.is_empty() and jobs[0] is Dictionary:
		benchmark_config = ((jobs[0] as Dictionary).get("config", {}) as Dictionary).duplicate(true)
	jobs = DeterministicShard.filter_jobs(jobs, "decision_id", shard_index, shard_count)
	print("[counterfactual] shard=%d/%d selected=%d/%d by decision_id" % [
		shard_index,
		shard_count,
		jobs.size(),
		preset_decisions_considered,
	])

	var abs_out := ProjectSettings.globalize_path(out_dir)
	if DirAccess.make_dir_recursive_absolute(abs_out) != OK:
		push_error("Unable to create counterfactual output directory: %s" % abs_out)
		get_tree().quit(1)
		return
	if rules_version == "unknown" or rules_version.is_empty():
		push_warning("Counterfactual benchmark has no rules git SHA; pass --rules-version or use run_counterfactual_benchmark.sh")

	var all_rows: Array = []
	var decision_summaries: Array = []
	var failed_decisions := 0
	var fully_labeled_candidates := 0
	var partially_labeled_candidates := 0
	var unlabeled_candidates := 0

	for job_variant in jobs:
		if not (job_variant is Dictionary):
			failed_decisions += 1
			continue
		var job: Dictionary = job_variant
		var result := PureStateCounterfactualAnswerKey.evaluate_decision(
			job.get("state", {}) as Dictionary,
			str(job.get("perspective_group", "")),
			str(job.get("opponent_group", "")),
			str(job.get("decision_id", "")),
			job.get("config", {}) as Dictionary
		)
		var valid := bool(result.get("valid", false))
		if not valid:
			failed_decisions += 1
		else:
			all_rows.append_array(PureStateCounterfactualBenchmark.to_candidate_rows(result))

		var candidate_summaries: Array = []
		for candidate_variant in result.get("candidate_results", []):
			if not (candidate_variant is Dictionary):
				continue
			var candidate: Dictionary = candidate_variant
			var estimate: Dictionary = candidate.get("estimate", {})
			var coverage := float(estimate.get("labeled_weight_fraction", 0.0))
			if int(estimate.get("return_count", 0)) <= 0:
				unlabeled_candidates += 1
			elif coverage >= 1.0 - 0.000001:
				fully_labeled_candidates += 1
			else:
				partially_labeled_candidates += 1
			candidate_summaries.append({
				"candidate_id": str(candidate.get("candidate_id", "")),
				"candidate_label": str(candidate.get("candidate_label", candidate.get("candidate_id", ""))),
				"candidate_description": str(candidate.get("candidate_description", "")),
				"status": str(estimate.get("status", "")),
				"conditional_labeled_mean_return": float(estimate.get("conditional_labeled_mean_return", 0.0)),
				"estimated_standard_error": float(estimate.get("estimated_standard_error", 0.0)),
				"labeled_weight_fraction": coverage,
				"known_weighted_return_contribution": float(estimate.get("known_weighted_return_contribution", 0.0)),
				"full_mixture_lower_bound": float(estimate.get("full_mixture_lower_bound", -1.0)),
				"full_mixture_upper_bound": float(estimate.get("full_mixture_upper_bound", 1.0)),
				"best_response_value_lower_bound": float(estimate.get("best_response_value_lower_bound", -1.0)),
				"best_response_value_upper_bound": float(estimate.get("best_response_value_upper_bound", 1.0)),
				"best_response_opponent_sample_id": str(estimate.get("best_response_opponent_sample_id", "")),
				"curated_stress_test_count": (estimate.get("curated_stress_tests", []) as Array).size(),
			})
		decision_summaries.append({
			"decision_id": str(job.get("decision_id", "")),
			"scenario_id": str(job.get("scenario_id", "")),
			"behavior_id": str(job.get("behavior_id", "")),
			"scenario_prompt": str(job.get("scenario_prompt", "")),
			"valid": valid,
			"candidate_count": (result.get("candidate_results", []) as Array).size(),
			"estimated_best_candidate_ids": (result.get("estimated_best_candidate_ids", []) as Array).duplicate(),
			"pairwise_comparison_count": (result.get("pairwise_comparisons", []) as Array).size(),
			"candidates": candidate_summaries,
		})
		print("[counterfactual] %s valid=%s candidates=%d interval_best=%s" % [
			str(job.get("decision_id", "")),
			str(valid),
			(result.get("candidate_results", []) as Array).size(),
			str(result.get("estimated_best_candidate_ids", [])),
		])

	var manifest := {
		"manifest_schema_version": MANIFEST_SCHEMA_VERSION,
		"candidate_schema_version": PureStateCounterfactualAnswerKey.SCHEMA_VERSION,
		"counterfactual_benchmark_version": PureStateCounterfactualAnswerKey.BENCHMARK_VERSION,
		"answer_key_version": PureStateCounterfactualAnswerKey.ANSWER_KEY_VERSION,
		"counterfactual_suite_version": PureStateCounterfactualSuite.SUITE_VERSION,
		"preset": preset,
		"rules_version": rules_version,
		"target_semantics": "search_policy_terminal_return_with_unresolved_bounds_v2",
		"uncertainty_semantics": "full-mixture bounds preserve unresolved continuation mass; conditional spread remains diagnostic only",
		"opponent_weight_semantics": "normalized_search_policy_proxy_not_empirical_behavior_probability",
		"curated_response_semantics": "authored responses are stress cases and authored weights are not policy likelihoods",
		"opponent_mixture_version": str(benchmark_config.get("opponent_mixture_version", "")),
		"continuation_mixture_version": str(benchmark_config.get("continuation_mixture_version", "")),
		"turn_limit_is_unlabeled": true,
		"preset_decisions_considered": preset_decisions_considered,
		"shard_index": shard_index,
		"shard_count": shard_count,
		"shard_key": "decision_id",
		"decisions_requested": jobs.size(),
		"decisions_failed": failed_decisions,
		"candidate_count": all_rows.size(),
		"fully_labeled_candidates": fully_labeled_candidates,
		"partially_labeled_candidates": partially_labeled_candidates,
		"unlabeled_candidates": unlabeled_candidates,
		"decisions": decision_summaries,
	}

	var candidates_path := out_dir.path_join("candidates.jsonl")
	var manifest_path := out_dir.path_join("manifest.json")
	var write_ok := _write_text(candidates_path, PureStateCounterfactualBenchmark.to_jsonl(all_rows))
	write_ok = _write_json(manifest_path, manifest) and write_ok
	print("[counterfactual] wrote %s" % ProjectSettings.globalize_path(candidates_path))
	print("[counterfactual] wrote %s" % ProjectSettings.globalize_path(manifest_path))
	print("[counterfactual] summary decisions=%d failed=%d candidates=%d full=%d partial=%d unlabeled=%d" % [
		jobs.size(), failed_decisions, all_rows.size(), fully_labeled_candidates,
		partially_labeled_candidates, unlabeled_candidates,
	])
	get_tree().quit(0 if write_ok and failed_decisions == 0 else 1)


func _parse_cmdline_kv() -> Dictionary:
	var result: Dictionary = {}
	var raw: PackedStringArray = OS.get_cmdline_user_args()
	if raw.is_empty():
		raw = OS.get_cmdline_args()
	var i := 0
	while i < raw.size():
		var arg := str(raw[i]).strip_edges()
		if arg.is_empty():
			i += 1
			continue
		if arg.begins_with("--"):
			arg = arg.substr(2)
		if arg.contains("="):
			var parts := arg.split("=", true, 1)
			result[parts[0]] = parts[1]
		else:
			var next_value := ""
			if i + 1 < raw.size() and not str(raw[i + 1]).begins_with("-"):
				next_value = str(raw[i + 1]).strip_edges()
				i += 1
			result[arg] = next_value if not next_value.is_empty() else "true"
		i += 1
	return result


func _write_text(path: String, value: String) -> bool:
	var abs_path := ProjectSettings.globalize_path(path)
	var file := FileAccess.open(abs_path, FileAccess.WRITE)
	if file == null:
		push_error("Cannot write %s" % abs_path)
		return false
	file.store_string(value)
	file.close()
	return true


func _write_json(path: String, data: Dictionary) -> bool:
	return _write_text(path, JSON.stringify(data, "  ") + "\n")