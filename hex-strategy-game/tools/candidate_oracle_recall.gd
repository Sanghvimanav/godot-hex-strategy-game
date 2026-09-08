extends Node
## Headless Candidate Oracle Recall benchmark.
##
## Frozen suite:
##   godot --headless --path . res://tools/candidate_oracle_recall.tscn -- \
##     --preset=curated --out=user://candidate_oracle_recall
##
## Self-play search decisions:
##   ... --input-jsonl=/path/to/search_decisions.jsonl --max-decisions=20

const PureStateCandidateOracleRecall = preload("res://src/simulation/pure_state_candidate_oracle_recall.gd")
const PureStateCounterfactualSuite = preload("res://src/simulation/pure_state_counterfactual_suite.gd")
const DeterministicShard = preload("res://tools/deterministic_shard.gd")

const MANIFEST_SCHEMA_VERSION := 1


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var args := _parse_cmdline_kv()
	var preset := str(args.get("preset", "curated"))
	var input_jsonl := str(args.get("input-jsonl", ""))
	var out_dir := str(args.get("out", "user://candidate_oracle_recall"))
	var rules_version := str(args.get("rules-version", "unknown"))
	var max_decisions := int(args.get("max-decisions", "0"))
	var decision_id_filter := str(args.get("decision-id", ""))
	var shard_index := int(args.get("shard-index", "0"))
	var shard_count := int(args.get("shard-count", "1"))
	if shard_count <= 0 or shard_index < 0 or shard_index >= shard_count:
		push_error("Invalid candidate-oracle shard %d/%d" % [shard_index, shard_count])
		get_tree().quit(1)
		return

	var jobs: Array = []
	var source_kind := "counterfactual_suite"
	if not input_jsonl.is_empty():
		source_kind = "search_decision_jsonl"
		var rows_variant := _read_jsonl(input_jsonl)
		if rows_variant == null:
			get_tree().quit(1)
			return
		jobs = _jobs_from_search_decisions(rows_variant as Array, rules_version)
	else:
		jobs = PureStateCounterfactualSuite.get_preset(preset, rules_version)

	if not decision_id_filter.is_empty():
		jobs = jobs.filter(func(job):
			return job is Dictionary and str((job as Dictionary).get("decision_id", "")) == decision_id_filter
		)
	if jobs.is_empty():
		push_error("No candidate-oracle decisions selected")
		get_tree().quit(1)
		return
	if max_decisions > 0 and max_decisions < jobs.size():
		jobs = jobs.slice(0, max_decisions)
	var jobs_before_shard := jobs.size()
	jobs = DeterministicShard.filter_jobs(jobs, "decision_id", shard_index, shard_count)

	var abs_out := ProjectSettings.globalize_path(out_dir)
	if DirAccess.make_dir_recursive_absolute(abs_out) != OK:
		push_error("Unable to create candidate-oracle output directory: %s" % abs_out)
		get_tree().quit(1)
		return

	var decision_rows: Array = []
	var severe_rows: Array = []
	var failures: Array = []
	for job_variant in jobs:
		if not (job_variant is Dictionary):
			continue
		var job: Dictionary = job_variant
		var config: Dictionary = (job.get("config", {}) as Dictionary).duplicate(true)
		_apply_cli_overrides(config, args)
		config["rules_version"] = rules_version
		var result := PureStateCandidateOracleRecall.evaluate_decision(
			job.get("state", {}) as Dictionary,
			str(job.get("perspective_group", "")),
			str(job.get("opponent_group", "")),
			str(job.get("decision_id", "")),
			config
		)
		result["source_kind"] = source_kind
		result["scenario_id"] = str(job.get("scenario_id", ""))
		result["behavior_id"] = str(job.get("behavior_id", ""))
		result["family"] = str(job.get("family", job.get("behavior_id", "other")))
		result["scenario_prompt"] = str(job.get("scenario_prompt", ""))
		result["rules_version"] = rules_version
		result["source_metadata"] = (job.get("source_metadata", {}) as Dictionary).duplicate(true)
		decision_rows.append(result)
		if not bool(result.get("valid", false)):
			failures.append({
				"decision_id": str(job.get("decision_id", "")),
				"error": str(result.get("error", "unknown")),
			})
			print("[candidate-oracle] %s FAILED %s" % [job.get("decision_id", ""), result.get("error", "")])
			continue
		var analysis: Dictionary = result.get("analysis", {})
		if bool(analysis.get("severe_miss", false)):
			severe_rows.append(result.duplicate(true))
		print("[candidate-oracle] %s family=%s recall=%s gap=%.3f severe=%s classification=%s" % [
			str(job.get("decision_id", "")),
			str(result.get("family", "other")),
			str(analysis.get("candidate_recall", false)),
			float(analysis.get("oracle_value_gap", 0.0)),
			str(analysis.get("severe_miss", false)),
			str(analysis.get("failure_classification", "")),
		])

	var summary := PureStateCandidateOracleRecall.summarize(decision_rows)
	var by_family: Dictionary = {}
	for row_variant in decision_rows:
		if not (row_variant is Dictionary) or not bool((row_variant as Dictionary).get("valid", false)):
			continue
		var row: Dictionary = row_variant
		var family := str(row.get("family", "other"))
		if family.is_empty():
			family = "other"
		if not by_family.has(family):
			by_family[family] = []
		(by_family[family] as Array).append(row)
	var family_summaries: Dictionary = {}
	for family_variant in by_family.keys():
		var family := str(family_variant)
		family_summaries[family] = PureStateCandidateOracleRecall.summarize(by_family[family] as Array)

	var manifest := {
		"manifest_schema_version": MANIFEST_SCHEMA_VERSION,
		"candidate_oracle_schema_version": PureStateCandidateOracleRecall.SCHEMA_VERSION,
		"candidate_oracle_benchmark_version": PureStateCandidateOracleRecall.BENCHMARK_VERSION,
		"source_kind": source_kind,
		"preset": preset if input_jsonl.is_empty() else "",
		"input_jsonl": input_jsonl,
		"rules_version": rules_version,
		"value_semantics": "full_mixture_midpoint_of_search_policy_terminal_return_with_unresolved_bounds_v2",
		"recall_semantics": "production candidate counts as recalled when its shared oracle-controlled value is within near_best_tolerance of the best union candidate; exact plan equality is not required",
		"severe_miss_semantics": "candidate recall is false and oracle_value_gap >= severe_miss_threshold",
		"loss_stage_probe_semantics": "exact oracle-winner recovery probes are diagnostics, not causal proof",
		"near_best_tolerance": _float_arg(args, "near-best-tolerance", PureStateCandidateOracleRecall.DEFAULT_NEAR_BEST_TOLERANCE),
		"severe_miss_threshold": _float_arg(args, "severe-miss-threshold", PureStateCandidateOracleRecall.DEFAULT_SEVERE_MISS_THRESHOLD),
		"decisions_considered_before_shard": jobs_before_shard,
		"shard_index": shard_index,
		"shard_count": shard_count,
		"decisions_requested": jobs.size(),
		"decisions_failed": failures.size(),
		"severe_miss_file": "severe_misses.jsonl",
		"decision_file": "decisions.jsonl",
		"summary": summary,
		"by_family": family_summaries,
		"failures": failures,
	}

	var write_ok := _write_text(out_dir.path_join("decisions.jsonl"), _to_jsonl(decision_rows))
	write_ok = _write_text(out_dir.path_join("severe_misses.jsonl"), _to_jsonl(severe_rows)) and write_ok
	write_ok = _write_text(out_dir.path_join("manifest.json"), JSON.stringify(manifest, "  ") + "\n") and write_ok
	print("[candidate-oracle] summary decisions=%d failed=%d recall=%.3f mean_gap=%.3f severe=%d conditional_selection=%s" % [
		int(summary.get("decision_count", 0)),
		failures.size(),
		float(summary.get("near_oracle_candidate_recall", 0.0)),
		float(summary.get("mean_oracle_value_gap", 0.0)),
		int(summary.get("severe_miss_count", 0)),
		str(summary.get("selection_accuracy_conditional_on_recall", null)),
	])
	get_tree().quit(0 if write_ok and failures.is_empty() else 1)


func _jobs_from_search_decisions(rows: Array, rules_version: String) -> Array:
	var jobs: Array = []
	for row_variant in rows:
		if not (row_variant is Dictionary):
			continue
		var row: Dictionary = row_variant
		if not bool(row.get("valid", true)):
			continue
		var state_variant = row.get("starting_state", {})
		if not (state_variant is Dictionary) or (state_variant as Dictionary).is_empty():
			continue
		var game_id := str(row.get("game_id", "game"))
		var turn_index := int(row.get("turn_index", 0))
		var perspective := str(row.get("perspective_group", ""))
		var source: Dictionary = (row.get("source", {}) as Dictionary).duplicate(true)
		var budget: Dictionary = (row.get("budget", {}) as Dictionary).duplicate(true)
		var max_actions := maxi(1, int(budget.get("max_actions_per_unit", source.get("max_actions_per_unit", 8))))
		var config := {
			"rules_version": rules_version,
			"production_own_max_actions_per_unit": max_actions,
			"production_opponent_max_actions_per_unit": max_actions,
			"production_own_max_plans": maxi(1, int(budget.get("own_max_plans", source.get("own_max_plans", 2)))),
			"production_opponent_max_plans": maxi(1, int(budget.get("opponent_max_plans", source.get("opponent_max_plans", 2)))),
		}
		var family := str(source.get("family", source.get("scenario_family", source.get("scenario_id", "self_play"))))
		jobs.append({
			"decision_id": "%s|turn_%03d|%s" % [game_id, turn_index, perspective],
			"state": (state_variant as Dictionary).duplicate(true),
			"perspective_group": perspective,
			"opponent_group": str(row.get("opponent_group", "")),
			"scenario_id": str(source.get("scenario_id", game_id)),
			"behavior_id": family,
			"family": family,
			"scenario_prompt": "self-play decision %s turn %d" % [game_id, turn_index],
			"config": config,
			"source_metadata": {
				"game_id": game_id,
				"turn_index": turn_index,
				"selected_actions": (row.get("selected_actions", []) as Array).duplicate(true),
				"budget": budget,
				"source": source,
			},
		})
	return jobs


func _apply_cli_overrides(config: Dictionary, args: Dictionary) -> void:
	var integer_keys := {
		"production-own-max-actions-per-unit": "production_own_max_actions_per_unit",
		"production-own-max-plans": "production_own_max_plans",
		"production-opponent-max-actions-per-unit": "production_opponent_max_actions_per_unit",
		"production-opponent-max-plans": "production_opponent_max_plans",
		"oracle-own-max-actions-per-unit": "oracle_own_max_actions_per_unit",
		"oracle-own-max-plans": "oracle_own_max_plans",
		"oracle-opponent-max-actions-per-unit": "oracle_opponent_max_actions_per_unit",
		"oracle-opponent-max-plans": "oracle_opponent_max_plans",
		"oracle-value-opponent-max-actions-per-unit": "oracle_value_opponent_max_actions_per_unit",
		"oracle-value-opponent-max-plans": "oracle_value_opponent_max_plans",
		"oracle-value-response-max-actions-per-unit": "oracle_value_response_max_actions_per_unit",
		"oracle-value-response-max-plans": "oracle_value_response_max_plans",
	}
	for arg_key_variant in integer_keys.keys():
		var arg_key := str(arg_key_variant)
		if args.has(arg_key):
			config[str(integer_keys[arg_key])] = maxi(1, int(args[arg_key]))
	if args.has("near-best-tolerance"):
		config["near_best_tolerance"] = maxf(0.0, float(args["near-best-tolerance"]))
	if args.has("severe-miss-threshold"):
		config["severe_miss_threshold"] = maxf(0.0, float(args["severe-miss-threshold"]))


func _float_arg(args: Dictionary, key: String, fallback: float) -> float:
	return float(args.get(key, fallback))


func _read_jsonl(path: String) -> Variant:
	var resolved := ProjectSettings.globalize_path(path)
	var file := FileAccess.open(resolved, FileAccess.READ)
	if file == null:
		push_error("Cannot open candidate-oracle input JSONL: %s" % resolved)
		return null
	var rows: Array = []
	while not file.eof_reached():
		var line := file.get_line().strip_edges()
		if line.is_empty():
			continue
		var parsed = JSON.parse_string(line)
		if not (parsed is Dictionary):
			push_error("Invalid JSONL row in %s" % resolved)
			file.close()
			return null
		rows.append(parsed)
	file.close()
	return rows


func _to_jsonl(rows: Array) -> String:
	var lines: PackedStringArray = []
	for row_variant in rows:
		if row_variant is Dictionary:
			lines.append(JSON.stringify(row_variant))
	return "\n".join(lines) + ("\n" if not lines.is_empty() else "")


func _write_text(path: String, text: String) -> bool:
	var resolved := ProjectSettings.globalize_path(path)
	var file := FileAccess.open(resolved, FileAccess.WRITE)
	if file == null:
		push_error("Cannot write %s" % resolved)
		return false
	file.store_string(text)
	file.close()
	return true


func _parse_cmdline_kv() -> Dictionary:
	var result: Dictionary = {}
	var raw: PackedStringArray = OS.get_cmdline_user_args()
	if raw.is_empty():
		raw = OS.get_cmdline_args()
	var i := 0
	while i < raw.size():
		var arg := str(raw[i]).strip_edges()
		if arg.begins_with("--"):
			arg = arg.substr(2)
		if arg.contains("="):
			var parts := arg.split("=", true, 1)
			result[parts[0]] = parts[1]
		elif not arg.is_empty():
			var next_value := ""
			if i + 1 < raw.size() and not str(raw[i + 1]).begins_with("-"):
				next_value = str(raw[i + 1]).strip_edges()
				i += 1
			result[arg] = next_value if not next_value.is_empty() else "true"
		i += 1
	return result
