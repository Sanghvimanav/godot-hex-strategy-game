extends RefCounted
class_name LlmPlanningResponseParser
## Extracts per-unit action requests (action_key + target_cell) from model output.


static func parse_json_actions(raw: String) -> Dictionary:
	var text := raw.strip_edges()
	if text.is_empty():
		return { "ok": false, "error": "empty_content" }
	text = _extract_json_object_text(text)

	var data: Variant = JSON.parse_string(text)
	if typeof(data) != TYPE_DICTIONARY:
		return { "ok": false, "error": "not_json_object" }
	var root: Dictionary = data
	var actions: Array = root.get("actions", []) as Array
	if actions.is_empty():
		return { "ok": false, "error": "no_actions" }

	var action_request_by_unit_id: Dictionary = {}
	var legacy_option_index_by_unit_id: Dictionary = {}
	for item in actions:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = item
		var uid := int(d.get("unit_id", -1))
		if uid <= 0:
			continue
		var action_key: String = str(d.get("action_key", "")).strip_edges()
		var target_raw: Variant = d.get("target_cell", d.get("end_cell", d.get("echo_cell", d.get("echo_end_cell", []))))
		if typeof(target_raw) != TYPE_ARRAY:
			continue
		var target_arr: Array = target_raw as Array
		if target_arr.size() < 2:
			continue
		var target_cell: Array = [int(target_arr[0]), int(target_arr[1])]
		if not action_key.is_empty():
			action_request_by_unit_id[uid] = {
				"action_key": action_key,
				"target_cell": target_cell,
			}
			continue
		# Backward-compatible path (legacy option index output).
		var oi := int(d.get("option_index", -1))
		if oi >= 0:
			legacy_option_index_by_unit_id[uid] = oi

	if action_request_by_unit_id.is_empty() and legacy_option_index_by_unit_id.is_empty():
		return { "ok": false, "error": "no_valid_action_entries" }

	var rs: Variant = root.get("reasoning_summary", "")
	var op: Variant = root.get("opponent_prediction", "")
	if op == null or str(op).is_empty():
		op = root.get("previous_turn_analysis", "")
	return {
		"ok": true,
		"action_request_by_unit_id": action_request_by_unit_id,
		"legacy_option_index_by_unit_id": legacy_option_index_by_unit_id,
		"reasoning_summary": str(rs) if rs != null else "",
		"opponent_prediction": str(op) if op != null else "",
	}


static func _extract_json_object_text(s: String) -> String:
	var a: int = s.find("{")
	var b: int = s.rfind("}")
	if a >= 0 and b > a:
		return s.substr(a, b - a + 1)
	return s
