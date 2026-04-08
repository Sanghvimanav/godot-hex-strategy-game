extends RefCounted
class_name LlmPlanningResponseParser
## Extracts { unit_id: option_index } from model output (spec §6).


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

	var by_unit_id: Dictionary = {}
	for item in actions:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = item
		var uid := int(d.get("unit_id", -1))
		if uid <= 0:
			continue
		var oi := int(d.get("option_index", -1))
		if oi < 0:
			continue
		by_unit_id[uid] = oi

	if by_unit_id.is_empty():
		return { "ok": false, "error": "no_valid_action_entries" }

	var rs: Variant = root.get("reasoning_summary", "")
	return {
		"ok": true,
		"by_unit_id": by_unit_id,
		"reasoning_summary": str(rs) if rs != null else "",
	}


static func _extract_json_object_text(s: String) -> String:
	var a: int = s.find("{")
	var b: int = s.rfind("}")
	if a >= 0 and b > a:
		return s.substr(a, b - a + 1)
	return s
