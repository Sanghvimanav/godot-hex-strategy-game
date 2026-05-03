extends Node
## Headless eval runner for planning snapshots (no API calls).
## Run:
## godot --headless --path hex-strategy-game res://tools/planning_eval.tscn -- --case=phase_fastmove_contact_zergling_vs_scout_t0
## Export the exact user JSON sent to the LLM (after sanitize + payload profile + mutation):
## --mode=export_llm_payload --out=res://tools/evals/runs/my_payload.json --payload_mutation_file=... (optional)

const _Harness := preload("res://tools/headless_planning_harness.gd")
const _LlmClient := preload("res://src/llm_ai/llm_openai_client.gd")
const _LlmSettings := preload("res://src/llm_ai/llm_settings.gd")
const _LlmPrompts := preload("res://src/llm_ai/llm_planning_prompts.gd")
const _LlmParser := preload("res://src/llm_ai/llm_planning_response_parser.gd")
const _LlmSnapshot := preload("res://src/llm_ai/llm_planning_snapshot.gd")


func _ready() -> void:
	call_deferred("_run_eval")


func _run_eval() -> void:
	var args: Dictionary = _parse_cmdline_kv()
	var case_id: String = str(args.get("case", "phase_fastmove_contact_zergling_vs_scout_t0"))
	var out_path: String = str(args.get("out", "user://planning_eval_result.json"))
	var mode: String = str(args.get("mode", "snapshot")).strip_edges().to_lower()
	var experiment_meta: Dictionary = {
		"run_id": str(args.get("run_id", "")).strip_edges(),
		"prompt_version": str(args.get("prompt_version", "")).strip_edges(),
		"eval_set_version": str(args.get("eval_set_version", "")).strip_edges(),
		"notes": str(args.get("notes", "")).strip_edges(),
	}
	var live_overrides: Dictionary = {
		"model": str(args.get("model", "")).strip_edges(),
		"reasoning_effort": str(args.get("thinking_level", "")).strip_edges(),
		"planning_prompt_version": str(args.get("planning_prompt_version", "")).strip_edges(),
		"use_two_call_planning": str(args.get("use_two_call_planning", "")).strip_edges(),
		"custom_system_prompt_file": str(args.get("custom_system_prompt_file", "")).strip_edges(),
		"payload_profile": str(args.get("payload_profile", "baseline")).strip_edges(),
		"payload_mutation_file": str(args.get("payload_mutation_file", "")).strip_edges(),
	}
	var pmt_arg: String = str(args.get("planning_max_tokens", "")).strip_edges()
	if not pmt_arg.is_empty() and pmt_arg.is_valid_int():
		live_overrides["planning_max_tokens"] = int(pmt_arg)
	var case_data: Dictionary = _load_case(case_id)
	if case_data.is_empty():
		push_error("Unknown eval case: %s" % case_id)
		get_tree().quit(1)
		return

	var scenario_id: String = str(case_data.get("scenario_id", ""))
	var perspective_group: String = str(case_data.get("perspective_group", ""))
	if scenario_id.is_empty() or perspective_group.is_empty():
		push_error("Eval case missing scenario_id or perspective_group: %s" % case_id)
		get_tree().quit(1)
		return

	var root: Node2D = _Harness.build_battle_root()
	get_tree().root.add_child(root)
	await get_tree().process_frame
	await get_tree().process_frame

	var units: UnitsContainer = _Harness.setup_scenario_on_tree(root, scenario_id)
	await get_tree().process_frame
	var snap: Dictionary = _Harness.snapshot_for_group(units, perspective_group)
	var choice_map: Dictionary = {}
	var llm_meta: Dictionary = {}
	if mode == "live_llm":
		var turn_multiplier: int = maxi(1, int(case_data.get("turn_count", 1)))
		var live: Dictionary = await _run_live_llm_choice(snap, turn_multiplier, live_overrides)
		if not bool(live.get("ok", false)):
			var fail_result: Dictionary = {
				"pass": false,
				"reason": "live_llm_failed: %s" % str(live.get("error", "unknown")),
				"mode": mode,
				"llm": live,
			}
			fail_result["case_id"] = case_id
			fail_result["scenario_id"] = scenario_id
			fail_result["perspective_group"] = perspective_group
			fail_result["intent"] = str(case_data.get("intent", ""))
			fail_result["experiment"] = experiment_meta
			fail_result["grading"] = _compute_simple_grading(false, fail_result)
			_write_json(out_path, fail_result)
			print("[planning-eval] wrote %s" % out_path)
			print("[planning-eval] pass=false reason=%s" % str(fail_result.get("reason", "")))
			root.queue_free()
			await get_tree().process_frame
			get_tree().quit(2)
			return
		choice_map = live.get("by_unit_id", {}) as Dictionary
		llm_meta = live
	elif mode == "export_llm_payload":
		var exported: Dictionary = _export_build_llm_payload(snap, live_overrides)
		var export_wrap: Dictionary = {
			"case_id": case_id,
			"scenario_id": scenario_id,
			"perspective_group": perspective_group,
			"intent": str(case_data.get("intent", "")),
			"payload_profile": str(live_overrides.get("payload_profile", "baseline")).strip_edges(),
			"payload_mutation_file": str(live_overrides.get("payload_mutation_file", "")).strip_edges(),
			"llm_user_payload": exported,
		}
		_write_json(out_path, export_wrap)
		print("[planning-eval] wrote llm payload export %s" % out_path)
		root.queue_free()
		await get_tree().process_frame
		get_tree().quit(0)
		return
	else:
		choice_map = _build_required_choice_map(case_data, snap)
	var eval_result: Dictionary = _evaluate_case(case_data, snap, choice_map)
	eval_result["mode"] = mode
	if not llm_meta.is_empty():
		eval_result["llm"] = llm_meta
	eval_result["case_id"] = case_id
	eval_result["scenario_id"] = scenario_id
	eval_result["perspective_group"] = perspective_group
	eval_result["intent"] = str(case_data.get("intent", ""))
	eval_result["experiment"] = experiment_meta
	eval_result["grading"] = _compute_simple_grading(bool(eval_result.get("pass", false)), eval_result)

	_write_json(out_path, eval_result)
	print("[planning-eval] wrote %s" % out_path)
	print("[planning-eval] pass=%s reason=%s chosen_option_index=%s chosen_option_indices=%s" % [
		str(eval_result.get("pass", false)),
		str(eval_result.get("reason", "")),
		str(eval_result.get("chosen_option_index", -1)),
		str(eval_result.get("chosen_option_indices", [])),
	])

	root.queue_free()
	await get_tree().process_frame
	get_tree().quit(0 if bool(eval_result.get("pass", false)) else 2)


func _evaluate_case(case_data: Dictionary, snap: Dictionary, by_unit_id_choice: Dictionary) -> Dictionary:
	var checks: Dictionary = case_data.get("checks", {}) as Dictionary
	var unit_name: String = str(case_data.get("unit_name", ""))
	var ai_units: Array = snap.get("ai_units", []) as Array
	if ai_units.is_empty():
		return {"pass": false, "reason": "snapshot missing ai_units"}

	var per_unit_requirements: Array = checks.get("per_unit_requirements", []) as Array
	if not per_unit_requirements.is_empty():
		var matched_option_indices: Array = []
		for req_v in per_unit_requirements:
			if not (req_v is Dictionary):
				return {"pass": false, "reason": "invalid per_unit_requirements entry (not dictionary)"}
			var req: Dictionary = req_v
			var target_name: String = str(req.get("unit_name", "")).strip_edges()
			var start_cell: Array = req.get("start_cell", []) as Array
			var req_key: String = str(req.get("required_action_key", "")).strip_edges()
			var req_end: Array = req.get("required_end_cell", []) as Array
			if target_name.is_empty() or start_cell.size() < 2 or req_key.is_empty():
				return {"pass": false, "reason": "invalid per_unit_requirements rule"}
			var target_unit: Dictionary = _find_ai_unit_for_requirement(ai_units, target_name, start_cell)
			if target_unit.is_empty():
				return {
					"pass": false,
					"reason": "no AI unit matched requirement for %s at [%d,%d]" % [
						target_name, int(start_cell[0]), int(start_cell[1])
					],
				}
			var uid: int = int(target_unit.get("unit_id", 0))
			var chosen_idx: int = int(by_unit_id_choice.get(uid, -1))
			if chosen_idx < 0:
				return {"pass": false, "reason": "missing chosen option for required unit id=%s" % str(uid)}
			var chosen_opt: Dictionary = _option_by_index(target_unit, chosen_idx)
			if chosen_opt.is_empty():
				return {"pass": false, "reason": "chosen option index %d not found in legal_options for required unit id=%s" % [chosen_idx, str(uid)]}
			if str(chosen_opt.get("action_key", "")) != req_key:
				return {"pass": false, "reason": "required unit id=%s chose %s, expected %s" % [str(uid), str(chosen_opt.get("action_key", "")), req_key]}
			if req_end.size() >= 2:
				var end_arr: Array = chosen_opt.get("end", []) as Array
				if end_arr.size() < 2 or int(end_arr[0]) != int(req_end[0]) or int(end_arr[1]) != int(req_end[1]):
					return {"pass": false, "reason": "required unit id=%s chose end %s, expected [%d,%d]" % [str(uid), str(end_arr), int(req_end[0]), int(req_end[1])]}
			matched_option_indices.append(chosen_idx)
		return {
			"pass": true,
			"reason": "per-unit requirements satisfied (%d units)" % per_unit_requirements.size(),
			"chosen_option_indices": matched_option_indices,
		}

	var all_units_rule: Dictionary = checks.get("all_units_with_name_must_choose", {}) as Dictionary
	if not all_units_rule.is_empty():
		var target_name: String = str(all_units_rule.get("unit_name", "")).strip_edges()
		var req_key_all: String = str(all_units_rule.get("required_action_key", "")).strip_edges()
		var req_end_all: Array = all_units_rule.get("required_end_cell", []) as Array
		if target_name.is_empty() or req_key_all.is_empty() or req_end_all.size() < 2:
			return {"pass": false, "reason": "invalid all_units_with_name_must_choose rule"}
		var matched_units: int = 0
		var matched_option_indices: Array = []
		for u in ai_units:
			if not (u is Dictionary):
				continue
			var ud: Dictionary = u
			if str(ud.get("name", "")) != target_name:
				continue
			matched_units += 1
			var uid: int = int(ud.get("unit_id", 0))
			var chosen_idx: int = int(by_unit_id_choice.get(uid, -1))
			if chosen_idx < 0:
				return {"pass": false, "reason": "missing chosen option for unit %s (id=%s)" % [target_name, str(uid)]}
			var chosen_opt: Dictionary = _option_by_index(ud, chosen_idx)
			if chosen_opt.is_empty():
				return {"pass": false, "reason": "chosen option index %d not found in legal_options for unit id=%s" % [chosen_idx, str(uid)]}
			if str(chosen_opt.get("action_key", "")) != req_key_all:
				return {"pass": false, "reason": "unit id=%s chose %s, expected %s" % [str(uid), str(chosen_opt.get("action_key", "")), req_key_all]}
			var end_arr: Array = chosen_opt.get("end", []) as Array
			if end_arr.size() < 2 or int(end_arr[0]) != int(req_end_all[0]) or int(end_arr[1]) != int(req_end_all[1]):
				return {"pass": false, "reason": "unit id=%s chose end %s, expected [%d,%d]" % [str(uid), str(end_arr), int(req_end_all[0]), int(req_end_all[1])]}
			matched_option_indices.append(chosen_idx)
		if matched_units == 0:
			return {"pass": false, "reason": "no AI units matched name: %s" % target_name}
		return {
			"pass": true,
			"reason": "required option exists for all %d units named %s" % [matched_units, target_name],
			"matched_unit_count": matched_units,
			"chosen_option_indices": matched_option_indices,
		}
	var target_unit: Dictionary = {}
	for u in ai_units:
		if not (u is Dictionary):
			continue
		var ud: Dictionary = u
		if unit_name.is_empty() or str(ud.get("name", "")) == unit_name:
			target_unit = ud
			break
	if target_unit.is_empty():
		return {"pass": false, "reason": "target unit not found: %s" % unit_name}

	var options: Array = target_unit.get("legal_options", []) as Array
	if options.is_empty():
		return {"pass": false, "reason": "target unit has no legal_options"}

	var req_key: String = str(checks.get("required_action_key", ""))
	var req_end: Array = checks.get("required_end_cell", []) as Array
	var uid_single: int = int(target_unit.get("unit_id", 0))
	var chosen_idx: int = int(by_unit_id_choice.get(uid_single, -1))
	if chosen_idx < 0:
		return {"pass": false, "reason": "missing chosen option for target unit id=%s" % str(uid_single)}
	var chosen_opt: Dictionary = _option_by_index(target_unit, chosen_idx)
	if chosen_opt.is_empty():
		return {"pass": false, "reason": "chosen option index %d not found in legal_options for unit id=%s" % [chosen_idx, str(uid_single)]}
	if not req_key.is_empty() and str(chosen_opt.get("action_key", "")) != req_key:
		return {"pass": false, "reason": "chosen action key %s != required %s" % [str(chosen_opt.get("action_key", "")), req_key], "chosen_option_index": chosen_idx}
	if req_end.size() >= 2:
		var chosen_end: Array = chosen_opt.get("end", []) as Array
		if chosen_end.size() < 2 or int(chosen_end[0]) != int(req_end[0]) or int(chosen_end[1]) != int(req_end[1]):
			return {"pass": false, "reason": "chosen end %s != required [%d,%d]" % [str(chosen_end), int(req_end[0]), int(req_end[1])], "chosen_option_index": chosen_idx}

	var forbid_keys: Array = checks.get("forbid_action_keys", []) as Array
	var forbid_other: Dictionary = checks.get("forbid_any_other_end_cell_for_action_key", {}) as Dictionary
	var violations: Array[String] = []
	var chosen_ak: String = str(chosen_opt.get("action_key", ""))
	if chosen_ak in forbid_keys:
		violations.append("chosen action key is forbidden: %s" % chosen_ak)
	if not forbid_other.is_empty():
		var focus_key: String = str(forbid_other.get("action_key", ""))
		if not focus_key.is_empty() and chosen_ak == focus_key:
			var allowed: Array = forbid_other.get("allowed_end_cells", []) as Array
			var end_arr: Array = chosen_opt.get("end", []) as Array
			var ok_end := false
			for a in allowed:
				if a is Array and (a as Array).size() >= 2 and end_arr.size() >= 2:
					if int(end_arr[0]) == int(a[0]) and int(end_arr[1]) == int(a[1]):
						ok_end = true
						break
			if not ok_end:
				violations.append("chosen %s end not in allowed_end_cells" % focus_key)
	if not violations.is_empty():
		return {"pass": false, "reason": "; ".join(violations), "chosen_option_index": chosen_idx}

	return {"pass": true, "reason": "required option exists and passes checks", "chosen_option_index": chosen_idx}


func _build_required_choice_map(case_data: Dictionary, snap: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	var checks: Dictionary = case_data.get("checks", {}) as Dictionary
	var ai_units: Array = snap.get("ai_units", []) as Array
	var per_unit_requirements: Array = checks.get("per_unit_requirements", []) as Array
	if not per_unit_requirements.is_empty():
		for req_v in per_unit_requirements:
			if not (req_v is Dictionary):
				continue
			var req: Dictionary = req_v
			var target_name: String = str(req.get("unit_name", "")).strip_edges()
			var start_cell: Array = req.get("start_cell", []) as Array
			var req_key: String = str(req.get("required_action_key", "")).strip_edges()
			var req_end: Array = req.get("required_end_cell", []) as Array
			if target_name.is_empty() or start_cell.size() < 2:
				continue
			var target_unit: Dictionary = _find_ai_unit_for_requirement(ai_units, target_name, start_cell)
			if target_unit.is_empty():
				continue
			var uid: int = int(target_unit.get("unit_id", 0))
			out[uid] = _find_option_index(target_unit, req_key, req_end)
		return out
	var all_units_rule: Dictionary = checks.get("all_units_with_name_must_choose", {}) as Dictionary
	if not all_units_rule.is_empty():
		var target_name: String = str(all_units_rule.get("unit_name", "")).strip_edges()
		var req_key_all: String = str(all_units_rule.get("required_action_key", "")).strip_edges()
		var req_end_all: Array = all_units_rule.get("required_end_cell", []) as Array
		for u in ai_units:
			if not (u is Dictionary):
				continue
			var ud: Dictionary = u
			if str(ud.get("name", "")) != target_name:
				continue
			var idx: int = _find_option_index(ud, req_key_all, req_end_all)
			out[int(ud.get("unit_id", 0))] = idx
		return out
	var unit_name: String = str(case_data.get("unit_name", ""))
	var req_key: String = str(checks.get("required_action_key", ""))
	var req_end: Array = checks.get("required_end_cell", []) as Array
	if req_end.size() < 2:
		var forbid_other: Dictionary = checks.get("forbid_any_other_end_cell_for_action_key", {}) as Dictionary
		var focus_key: String = str(forbid_other.get("action_key", "")).strip_edges()
		if not focus_key.is_empty() and focus_key == req_key:
			var allowed: Array = forbid_other.get("allowed_end_cells", []) as Array
			for a in allowed:
				if a is Array and (a as Array).size() >= 2:
					req_end = (a as Array)
					break
	for u in ai_units:
		if not (u is Dictionary):
			continue
		var ud: Dictionary = u
		if unit_name.is_empty() or str(ud.get("name", "")) == unit_name:
			out[int(ud.get("unit_id", 0))] = _find_option_index(ud, req_key, req_end)
			break
	return out


func _find_option_index(unit_dict: Dictionary, req_key: String, req_end: Array) -> int:
	var options: Array = unit_dict.get("legal_options", []) as Array
	for opt_idx in range(options.size()):
		var opt: Variant = options[opt_idx]
		if not (opt is Dictionary):
			continue
		var od: Dictionary = opt as Dictionary
		if not req_key.is_empty() and str(od.get("action_key", "")) != req_key:
			continue
		if req_end.size() >= 2:
			var end_arr: Array = od.get("end", []) as Array
			if end_arr.size() < 2:
				continue
			if int(end_arr[0]) != int(req_end[0]) or int(end_arr[1]) != int(req_end[1]):
				continue
		return int(od.get("i", opt_idx))
	return -1


func _option_by_index(unit_dict: Dictionary, option_index: int) -> Dictionary:
	var options: Array = unit_dict.get("legal_options", []) as Array
	for opt_idx in range(options.size()):
		var opt: Variant = options[opt_idx]
		if not (opt is Dictionary):
			continue
		var od: Dictionary = opt as Dictionary
		if int(od.get("i", opt_idx)) == option_index:
			return od
	return {}


func _find_ai_unit_for_requirement(ai_units: Array, unit_name: String, start_cell: Array) -> Dictionary:
	var target_q: int = int(start_cell[0])
	var target_r: int = int(start_cell[1])
	var matches: Array = []
	for u in ai_units:
		if not (u is Dictionary):
			continue
		var ud: Dictionary = u
		if str(ud.get("name", "")) != unit_name:
			continue
		var cell: Array = ud.get("cell", []) as Array
		if cell.size() < 2:
			continue
		if int(cell[0]) == target_q and int(cell[1]) == target_r:
			matches.append(ud)
	if matches.size() == 1:
		return matches[0] as Dictionary
	return {}


func _parse_prediction_hypotheses(raw: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(raw)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	var obj: Dictionary = parsed
	var arr: Array = obj.get("enemy_predictions", []) as Array
	if arr.is_empty():
		return {}
	return {"enemy_predictions": arr}


func _run_live_llm_choice(snapshot: Dictionary, turn_multiplier: int = 1, overrides: Dictionary = {}) -> Dictionary:
	var settings := _LlmSettings.new()
	settings.load_from_disk()
	var model_override: String = str(overrides.get("model", "")).strip_edges()
	if not model_override.is_empty():
		settings.model = model_override
	var reasoning_override: String = str(overrides.get("reasoning_effort", "")).strip_edges()
	if not reasoning_override.is_empty():
		settings.reasoning_effort = reasoning_override
	if overrides.has("planning_max_tokens"):
		var pmt_v: Variant = overrides.get("planning_max_tokens")
		if typeof(pmt_v) == TYPE_INT:
			settings.planning_max_tokens = clampi(pmt_v, 256, 65536)
		else:
			var pmt_s: String = str(pmt_v).strip_edges()
			if pmt_s.is_valid_int():
				settings.planning_max_tokens = clampi(int(pmt_s), 256, 65536)
	var prompt_override: String = str(overrides.get("planning_prompt_version", "")).strip_edges()
	if not prompt_override.is_empty():
		settings.planning_prompt_version = prompt_override
	var two_call_override: String = str(overrides.get("use_two_call_planning", "")).strip_edges().to_lower()
	if two_call_override == "true" or two_call_override == "1" or two_call_override == "yes":
		settings.use_two_call_planning = true
	elif two_call_override == "false" or two_call_override == "0" or two_call_override == "no":
		settings.use_two_call_planning = false
	if not settings.has_configured_key():
		return {"ok": false, "error": "missing_api_key"}
	if str(settings.model).strip_edges().is_empty():
		return {"ok": false, "error": "missing_model"}
	var http := HTTPRequest.new()
	add_child(http)
	var client := _LlmClient.new()
	var payload_profile: String = str(overrides.get("payload_profile", "baseline")).strip_edges()
	if payload_profile.is_empty():
		payload_profile = "baseline"
	var working_snapshot: Dictionary = snapshot.duplicate(true)
	_sanitize_eval_snapshot_for_llm(working_snapshot)
	_apply_payload_profile(working_snapshot, payload_profile)
	var payload_mutation_file: String = str(overrides.get("payload_mutation_file", "")).strip_edges()
	if not payload_mutation_file.is_empty():
		var payload_mutation_spec: Dictionary = _read_json_file_as_dictionary(payload_mutation_file)
		if not payload_mutation_spec.is_empty():
			_apply_payload_mutation_spec(working_snapshot, payload_mutation_spec)
	var user_json: String = JSON.stringify(working_snapshot)
	if user_json.is_empty():
		http.queue_free()
		return {"ok": false, "error": "snapshot_encode_failed"}
	var http_result: Dictionary = {}
	var call_timings_ms: Array = []
	var prediction_usage: Dictionary = {}
	var retry_system_prompt: String = ""
	var retry_user_json: String = ""
	var custom_system_prompt: String = ""
	var custom_system_prompt_file: String = str(overrides.get("custom_system_prompt_file", "")).strip_edges()
	if not custom_system_prompt_file.is_empty() and FileAccess.file_exists(custom_system_prompt_file):
		custom_system_prompt = FileAccess.get_file_as_string(custom_system_prompt_file)
		if custom_system_prompt.strip_edges().is_empty():
			custom_system_prompt = ""
	var use_two_call_effective: bool = settings.use_two_call_planning and _LlmPrompts.supports_two_call(settings.planning_prompt_version)
	if use_two_call_effective:
		var pred_payload: Dictionary = working_snapshot.duplicate(true)
		_LlmSnapshot.prepare_snapshot_for_prediction_api_call(pred_payload)
		var pred_json: String = JSON.stringify(pred_payload)
		if pred_json.is_empty():
			http.queue_free()
			return {"ok": false, "error": "prediction_payload_encode_failed"}
		var pred_prompt_text: String = _LlmPrompts.prediction_only_prompt_for_version(settings.planning_prompt_version)
		var pred_result: Dictionary = await _planning_api_call(client, http, settings, pred_prompt_text, pred_json)
		call_timings_ms.append(int(pred_result.get("elapsed_ms", 0)))
		if not bool(pred_result.get("ok", false)):
			http.queue_free()
			return {
				"ok": false,
				"error": "prediction_call_failed",
				"detail": pred_result,
				"call_timings_ms": call_timings_ms,
				"latency_grader": _build_latency_grader(call_timings_ms, turn_multiplier),
			}
		prediction_usage = pred_result.get("usage", {}) as Dictionary
		var pred_hyp: Dictionary = _parse_prediction_hypotheses(str(pred_result.get("content", "")))
		var second_snapshot: Dictionary = working_snapshot.duplicate(true)
		if not pred_hyp.is_empty():
			second_snapshot["enemy_prediction_hypotheses"] = pred_hyp
			_LlmSnapshot.apply_prediction_hypotheses_to_legal_options(second_snapshot, pred_hyp)
		var second_json: String = JSON.stringify(second_snapshot)
		if second_json.is_empty():
			http.queue_free()
			return {"ok": false, "error": "second_payload_encode_failed"}
		var action_prompt_text: String = _LlmPrompts.action_only_system_prompt_for_version(settings.planning_prompt_version)
		retry_system_prompt = action_prompt_text
		retry_user_json = second_json
		http_result = await _planning_api_call(client, http, settings, action_prompt_text, second_json)
		call_timings_ms.append(int(http_result.get("elapsed_ms", 0)))
		var out_two: Dictionary = {
			"prediction_prompt": pred_prompt_text,
			"action_prompt": action_prompt_text,
			"prediction_input_preview": pred_json.substr(0, mini(pred_json.length(), 1200)),
			"action_input_preview": second_json.substr(0, mini(second_json.length(), 1200)),
			"payload_profile": payload_profile,
			"payload_mutation_file": payload_mutation_file,
		}
		http_result["_prompt_debug"] = out_two
	else:
		var sys_prompt_text: String = _LlmPrompts.system_prompt_for_version(settings.planning_prompt_version)
		if not custom_system_prompt.is_empty():
			sys_prompt_text = custom_system_prompt
		retry_system_prompt = sys_prompt_text
		retry_user_json = user_json
		http_result = await _planning_api_call(client, http, settings, sys_prompt_text, user_json)
		call_timings_ms.append(int(http_result.get("elapsed_ms", 0)))
		http_result["_prompt_debug"] = {
			"system_prompt": sys_prompt_text,
			"input_preview": user_json.substr(0, mini(user_json.length(), 1200)),
			"custom_system_prompt_file": custom_system_prompt_file,
			"payload_profile": payload_profile,
			"payload_mutation_file": payload_mutation_file,
		}
	http.queue_free()
	if not bool(http_result.get("ok", false)):
		return {
			"ok": false,
			"error": "planning_call_failed",
			"detail": http_result,
			"call_timings_ms": call_timings_ms,
			"latency_grader": _build_latency_grader(call_timings_ms, turn_multiplier),
		}
	var parse: Dictionary = {}
	var by_unit_id: Dictionary = {}
	var retries_used: int = 0
	while true:
		parse = _LlmParser.parse_json_actions(str(http_result.get("content", "")))
		if bool(parse.get("ok", false)):
			var action_req_by_id: Dictionary = parse.get("action_request_by_unit_id", {}) as Dictionary
			var legacy_by_id: Dictionary = parse.get("legacy_option_index_by_unit_id", {}) as Dictionary
			var resolved: Dictionary = _resolve_choices_against_snapshot(snapshot, action_req_by_id, legacy_by_id)
			if bool(resolved.get("ok", false)):
				by_unit_id = resolved.get("by_unit_id", {}) as Dictionary
				break
			parse = {"ok": false, "error": "invalid_action_selection", "detail": resolved}
		if retries_used >= 1:
			return {
				"ok": false,
				"error": str(parse.get("error", "parse_failed")),
				"detail": parse.get("detail", parse),
				"raw": str(http_result.get("content", "")),
				"call_timings_ms": call_timings_ms,
				"latency_grader": _build_latency_grader(call_timings_ms, turn_multiplier),
			}
		retries_used += 1
		http_result = await _planning_api_call(client, http, settings, retry_system_prompt, retry_user_json)
		call_timings_ms.append(int(http_result.get("elapsed_ms", 0)))
		if not bool(http_result.get("ok", false)):
			return {
				"ok": false,
				"error": "planning_retry_call_failed",
				"detail": http_result,
				"call_timings_ms": call_timings_ms,
				"latency_grader": _build_latency_grader(call_timings_ms, turn_multiplier),
			}
	var out: Dictionary = {
		"ok": true,
		"by_unit_id": by_unit_id,
		"usage": http_result.get("usage", {}) as Dictionary,
		"thinking": str(http_result.get("thinking", "")),
		"raw": str(http_result.get("content", "")),
		"base_url": str(settings.get_effective_base_url()),
		"reasoning_effort": str(settings.reasoning_effort),
		"planning_max_tokens": int(settings.planning_max_tokens),
		"use_two_call_planning": use_two_call_effective,
		"model": str(settings.model),
		"planning_prompt_version": str(settings.planning_prompt_version),
		"payload_profile": payload_profile,
		"payload_mutation_file": payload_mutation_file,
		"use_responses_api": settings.use_responses_api,
		"call_timings_ms": call_timings_ms,
		"latency_grader": _build_latency_grader(call_timings_ms, turn_multiplier),
	}
	var prompt_debug: Dictionary = http_result.get("_prompt_debug", {}) as Dictionary
	if not prompt_debug.is_empty():
		out["prompt_debug"] = prompt_debug
	if not prediction_usage.is_empty():
		out["prediction_usage"] = prediction_usage
	return out


func _resolve_choices_against_snapshot(
	snapshot: Dictionary, action_request_by_unit_id: Dictionary, legacy_option_index_by_unit_id: Dictionary
) -> Dictionary:
	var ai_units: Array = snapshot.get("ai_units", []) as Array
	if ai_units.is_empty():
		return {"ok": false, "error": "snapshot_missing_ai_units"}
	var resolved_by_unit_id: Dictionary = {}
	for unit_v in ai_units:
		if not (unit_v is Dictionary):
			continue
		var unit_d: Dictionary = unit_v as Dictionary
		var uid: int = int(unit_d.get("unit_id", 0))
		if uid <= 0:
			continue
		var chosen_idx: int = -1
		if action_request_by_unit_id.has(uid):
			var req: Dictionary = action_request_by_unit_id.get(uid, {}) as Dictionary
			var req_key: String = str(req.get("action_key", "")).strip_edges()
			var req_cell: Array = req.get("target_cell", []) as Array
			if req_key.is_empty() or req_cell.size() < 2:
				return {"ok": false, "error": "invalid_target_action_request", "unit_id": uid}
			var rq: int = int(req_cell[0])
			var rr: int = int(req_cell[1])
			var best_i: int = 1_000_000
			var options_scan: Array = unit_d.get("legal_options", []) as Array
			for scan_idx in range(options_scan.size()):
				var opt_v_scan: Variant = options_scan[scan_idx]
				if not (opt_v_scan is Dictionary):
					continue
				var od_scan: Dictionary = opt_v_scan as Dictionary
				if str(od_scan.get("action_key", "")) != req_key:
					continue
				var end_scan: Array = od_scan.get("target_cell", od_scan.get("end_cell", od_scan.get("end", []))) as Array
				if end_scan.size() < 2:
					continue
				if int(end_scan[0]) != rq or int(end_scan[1]) != rr:
					continue
				var oi_scan: int = int(od_scan.get("i", scan_idx))
				if oi_scan >= 0 and oi_scan < best_i:
					best_i = oi_scan
					chosen_idx = oi_scan
		elif legacy_option_index_by_unit_id.has(uid):
			chosen_idx = int(legacy_option_index_by_unit_id.get(uid, -1))
		else:
			return {"ok": false, "error": "missing_choice_for_unit", "unit_id": uid}
		var options: Array = unit_d.get("legal_options", []) as Array
		var chosen_opt: Dictionary = {}
		for opt_idx in range(options.size()):
			var opt_v: Variant = options[opt_idx]
			if not (opt_v is Dictionary):
				continue
			var od: Dictionary = opt_v as Dictionary
			if int(od.get("i", opt_idx)) == chosen_idx:
				chosen_opt = od
				break
		if chosen_opt.is_empty():
			return {"ok": false, "error": "chosen_option_not_found", "unit_id": uid, "option_index": chosen_idx}
		resolved_by_unit_id[uid] = chosen_idx
	return {"ok": true, "by_unit_id": resolved_by_unit_id}


func _export_build_llm_payload(snapshot: Dictionary, overrides: Dictionary) -> Dictionary:
	## Same snapshot shaping as the live LLM user JSON (sanitize + profile + optional mutation file).
	var working_snapshot: Dictionary = snapshot.duplicate(true)
	_sanitize_eval_snapshot_for_llm(working_snapshot)
	var payload_profile: String = str(overrides.get("payload_profile", "baseline")).strip_edges()
	if payload_profile.is_empty():
		payload_profile = "baseline"
	_apply_payload_profile(working_snapshot, payload_profile)
	var payload_mutation_file: String = str(overrides.get("payload_mutation_file", "")).strip_edges()
	if not payload_mutation_file.is_empty():
		var payload_mutation_spec: Dictionary = _read_json_file_as_dictionary(payload_mutation_file)
		if not payload_mutation_spec.is_empty():
			_apply_payload_mutation_spec(working_snapshot, payload_mutation_spec)
	return working_snapshot


func _sanitize_eval_snapshot_for_llm(snap: Dictionary) -> void:
	snap.erase("scenario_id")
	snap.erase("scenario_description")
	var rules_digest: String = str(snap.get("rules_digest", ""))
	if not rules_digest.is_empty():
		snap["rules_digest"] = _strip_scenario_objective_from_rules_digest(rules_digest)


func _strip_scenario_objective_from_rules_digest(rules_digest: String) -> String:
	var marker: String = "Scenario objective:"
	var marker_idx: int = rules_digest.find(marker)
	if marker_idx < 0:
		return rules_digest
	var suffix: String = " Standard win rule: eliminate all opposing units."
	var suffix_idx: int = rules_digest.find(suffix, marker_idx)
	if suffix_idx < 0:
		return rules_digest
	var prefix: String = rules_digest.substr(0, marker_idx)
	var tail_start: int = suffix_idx + suffix.length()
	var tail: String = rules_digest.substr(tail_start)
	return "%sWin by eliminating all enemy units (last side with any unit on the board wins).%s" % [prefix, tail]


func _apply_payload_profile(snap: Dictionary, payload_profile: String) -> void:
	var profile := payload_profile.strip_edges().to_lower()
	if profile.is_empty() or profile == "baseline":
		return
	var ai_units: Array = snap.get("ai_units", []) as Array
	for i in range(ai_units.size()):
		var unit_v: Variant = ai_units[i]
		if not (unit_v is Dictionary):
			continue
		var unit_d: Dictionary = unit_v as Dictionary
		var options: Array = unit_d.get("legal_options", []) as Array
		for j in range(options.size()):
			var opt_v: Variant = options[j]
			if not (opt_v is Dictionary):
				continue
			var od: Dictionary = opt_v as Dictionary
			if profile == "timing_heavy":
				# Timing-heavy: de-emphasize distance-only vectors; keep phase/timing and predicted damage signals.
				od.erase("distances_to_visible_enemies")
				od.erase("distances_to_last_known_enemies")
			elif profile == "targeting_heavy":
				# Targeting-heavy: de-emphasize phase explanation prose; keep hit/damage and distance vectors.
				od.erase("pred_damage_resolution_note")
				od.erase("predicted_enemy_damage_timing_vs_our_action")
			options[j] = od
		unit_d["legal_options"] = options
		ai_units[i] = unit_d
	snap["ai_units"] = ai_units


func _read_json_file_as_dictionary(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var text: String = FileAccess.get_file_as_string(path)
	if text.strip_edges().is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	return parsed as Dictionary


func _apply_payload_mutation_spec(snap: Dictionary, spec: Dictionary) -> void:
	# Supported keys:
	# - remove_paths: Array[String] (dot paths, [] wildcard for arrays)
	# - set_values: Dictionary path -> Variant
	# - copy_paths: Array[{"from":"a.b","to":"x.y"}]
	var remove_paths: Array = spec.get("remove_paths", []) as Array
	for p in remove_paths:
		if p is String:
			_remove_path_inplace(snap, str(p))

	var set_values_v: Variant = spec.get("set_values", {})
	if typeof(set_values_v) == TYPE_DICTIONARY:
		var set_values: Dictionary = set_values_v as Dictionary
		for k in set_values.keys():
			_set_path_inplace(snap, str(k), set_values[k])

	var copy_paths: Array = spec.get("copy_paths", []) as Array
	for c in copy_paths:
		if not (c is Dictionary):
			continue
		var cd: Dictionary = c as Dictionary
		var from_p: String = str(cd.get("from", "")).strip_edges()
		var to_p: String = str(cd.get("to", "")).strip_edges()
		if from_p.is_empty() or to_p.is_empty():
			continue
		var got: Dictionary = _get_path_value(snap, from_p)
		if not bool(got.get("ok", false)):
			continue
		_set_path_inplace(snap, to_p, got.get("value", null))


func _path_segments(path: String) -> Array[String]:
	var raw: PackedStringArray = path.split(".", false)
	var out: Array[String] = []
	for s in raw:
		var part: String = str(s).strip_edges()
		if not part.is_empty():
			out.append(part)
	return out


func _is_array_wildcard(seg: String) -> bool:
	return seg.ends_with("[]")


func _segment_key(seg: String) -> String:
	if _is_array_wildcard(seg):
		return seg.substr(0, max(0, seg.length() - 2))
	return seg


func _remove_path_inplace(root: Variant, path: String) -> void:
	var segs: Array[String] = _path_segments(path)
	if segs.is_empty():
		return
	_remove_path_recur(root, segs, 0)


func _remove_path_recur(node: Variant, segs: Array[String], idx: int) -> void:
	if idx >= segs.size():
		return
	var seg: String = segs[idx]
	var key: String = _segment_key(seg)
	var arr_wild: bool = _is_array_wildcard(seg)
	var is_leaf: bool = idx == segs.size() - 1

	if typeof(node) == TYPE_DICTIONARY:
		var d: Dictionary = node as Dictionary
		if not d.has(key):
			return
		if arr_wild:
			var arr_v: Variant = d.get(key, [])
			if typeof(arr_v) != TYPE_ARRAY:
				return
			var arr: Array = arr_v as Array
			for i in range(arr.size()):
				if is_leaf:
					# leaf [] means clear elements
					arr[i] = null
				else:
					_remove_path_recur(arr[i], segs, idx + 1)
			d[key] = arr
			return
		if is_leaf:
			d.erase(key)
			return
		_remove_path_recur(d[key], segs, idx + 1)
		return

	if typeof(node) == TYPE_ARRAY:
		var a: Array = node as Array
		for i in range(a.size()):
			_remove_path_recur(a[i], segs, idx)


func _set_path_inplace(root: Variant, path: String, value: Variant) -> void:
	var segs: Array[String] = _path_segments(path)
	if segs.is_empty():
		return
	_set_path_recur(root, segs, 0, value)


func _set_path_recur(node: Variant, segs: Array[String], idx: int, value: Variant) -> void:
	if idx >= segs.size():
		return
	var seg: String = segs[idx]
	var key: String = _segment_key(seg)
	var arr_wild: bool = _is_array_wildcard(seg)
	var is_leaf: bool = idx == segs.size() - 1

	if typeof(node) == TYPE_DICTIONARY:
		var d: Dictionary = node as Dictionary
		if arr_wild:
			if not d.has(key) or typeof(d.get(key, null)) != TYPE_ARRAY:
				d[key] = []
			var arr: Array = d[key] as Array
			for i in range(arr.size()):
				if is_leaf:
					arr[i] = value
				else:
					_set_path_recur(arr[i], segs, idx + 1, value)
			d[key] = arr
			return
		if is_leaf:
			d[key] = value
			return
		if not d.has(key) or (typeof(d[key]) != TYPE_DICTIONARY and typeof(d[key]) != TYPE_ARRAY):
			d[key] = {}
		_set_path_recur(d[key], segs, idx + 1, value)
		return

	if typeof(node) == TYPE_ARRAY:
		var a: Array = node as Array
		for i in range(a.size()):
			_set_path_recur(a[i], segs, idx, value)


func _get_path_value(root: Variant, path: String) -> Dictionary:
	var segs: Array[String] = _path_segments(path)
	if segs.is_empty():
		return {"ok": false}
	var node: Variant = root
	for seg in segs:
		var key: String = _segment_key(seg)
		if _is_array_wildcard(seg):
			if typeof(node) != TYPE_DICTIONARY:
				return {"ok": false}
			var d: Dictionary = node as Dictionary
			if not d.has(key):
				return {"ok": false}
			var arr_v: Variant = d[key]
			if typeof(arr_v) != TYPE_ARRAY:
				return {"ok": false}
			var arr: Array = arr_v as Array
			if arr.is_empty():
				return {"ok": false}
			node = arr[0]
			continue
		if typeof(node) != TYPE_DICTIONARY:
			return {"ok": false}
		var dict_node: Dictionary = node as Dictionary
		if not dict_node.has(key):
			return {"ok": false}
		node = dict_node[key]
	return {"ok": true, "value": node}


func _planning_api_call(
	client: LlmOpenAiClient,
	http: HTTPRequest,
	settings: LlmAiSettings,
	system_prompt: String,
	user_json: String,
) -> Dictionary:
	var t0_ms: int = Time.get_ticks_msec()
	if settings.use_responses_api:
		var rr: Dictionary = await client.responses_create(
			http,
			settings.get_effective_base_url(),
			settings.api_key,
			settings.model,
			system_prompt,
			user_json,
			settings.reasoning_effort,
			settings.planning_max_tokens
		)
		rr["elapsed_ms"] = Time.get_ticks_msec() - t0_ms
		return rr
	var messages: Array = [
		{"role": "system", "content": system_prompt},
		{"role": "user", "content": user_json},
	]
	var cr: Dictionary = await client.chat_completions(
		http,
		settings.get_effective_base_url(),
		settings.api_key,
		settings.model,
		messages,
		LlmOpenAiClient.Profile.PLANNING,
		settings.planning_max_tokens
	)
	cr["elapsed_ms"] = Time.get_ticks_msec() - t0_ms
	return cr


func _latency_score_for_seconds(seconds: float) -> float:
	# Score definition requested by user:
	# <=30s => 1.0, linearly down to 0.0 at 120s.
	if seconds <= 30.0:
		return 1.0
	if seconds >= 120.0:
		return 0.0
	return (120.0 - seconds) / 90.0


func _build_latency_grader(call_timings_ms: Array, turn_multiplier: int) -> Dictionary:
	var calls: Array = []
	var sum_scores: float = 0.0
	for ms_val in call_timings_ms:
		var ms_i: int = int(ms_val)
		var sec: float = float(ms_i) / 1000.0
		var score: float = _latency_score_for_seconds(sec)
		sum_scores += score
		calls.append({
			"elapsed_ms": ms_i,
			"elapsed_seconds": sec,
			"score": score,
		})
	var avg_score: float = 0.0
	if not calls.is_empty():
		avg_score = sum_scores / float(calls.size())
	var turns_i: int = maxi(1, turn_multiplier)
	return {
		"name": "latency_under_30s_to_120s",
		"definition": "<=30s => 1.0, linear to 0 at 120s",
		"turn_multiplier": turns_i,
		"calls": calls,
		"average_call_score": avg_score,
		"turn_scaled_score": avg_score * float(turns_i),
	}


func _compute_simple_grading(correctness_pass: bool, eval_result: Dictionary) -> Dictionary:
	var correctness: float = 1.0 if correctness_pass else 0.0
	var speed_score: float = 1.0
	var llm: Dictionary = eval_result.get("llm", {}) as Dictionary
	if not llm.is_empty():
		var latency: Dictionary = llm.get("latency_grader", {}) as Dictionary
		if not latency.is_empty():
			speed_score = float(latency.get("turn_scaled_score", latency.get("average_call_score", 1.0)))
	var final_score: float = correctness * speed_score
	return {
		"formula": "correctness * speed_score",
		"correctness": correctness,
		"speed_score": speed_score,
		"final_score": final_score,
	}


func _load_case(case_id: String) -> Dictionary:
	var p: String = "res://tools/evals/planning_eval_cases.json"
	var f: FileAccess = FileAccess.open(p, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	var root: Dictionary = parsed
	var cases: Array = root.get("cases", []) as Array
	for c in cases:
		if c is Dictionary and str((c as Dictionary).get("case_id", "")) == case_id:
			return c
	return {}


func _parse_cmdline_kv() -> Dictionary:
	var result: Dictionary = {}
	var raw: PackedStringArray = OS.get_cmdline_user_args()
	if raw.is_empty():
		raw = OS.get_cmdline_args()
	var i := 0
	while i < raw.size():
		var a: String = str(raw[i]).strip_edges()
		if a.is_empty():
			i += 1
			continue
		if a.begins_with("--"):
			a = a.substr(2)
		if a.contains("="):
			var parts: PackedStringArray = a.split("=", true, 1)
			result[parts[0]] = parts[1]
		else:
			var next_val: String = ""
			if i + 1 < raw.size() and not str(raw[i + 1]).begins_with("-"):
				next_val = str(raw[i + 1]).strip_edges()
				i += 1
			result[a] = next_val if not next_val.is_empty() else "true"
		i += 1
	return result


func _write_json(path: String, data: Dictionary) -> void:
	var abs_path: String = ProjectSettings.globalize_path(path)
	var f: FileAccess = FileAccess.open(abs_path, FileAccess.WRITE)
	if f == null:
		push_error("Cannot write %s" % abs_path)
		return
	f.store_string(JSON.stringify(data, "  "))
	f.close()
