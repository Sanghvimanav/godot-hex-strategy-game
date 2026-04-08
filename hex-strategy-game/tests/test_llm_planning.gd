extends RefCounted
## Headless tests for LLM planning JSON parse (no live API).

static func run_all(tests: Node) -> bool:
	var ok := true
	ok = _test_parse_valid_object(tests) and ok
	ok = _test_parse_braced_substring_and_fence(tests) and ok
	ok = _test_parse_rejects_bad_json(tests) and ok
	ok = _test_rules_catalog_json(tests) and ok
	return ok

static func _test_parse_valid_object(tests: Node) -> bool:
	tests._log("test_llm_planning: parse_valid_object")
	var raw := '{"reasoning_summary":"x","actions":[{"unit_id":42,"option_index":1}]}'
	var r: Dictionary = LlmPlanningResponseParser.parse_json_actions(raw)
	if not r.get("ok", false):
		tests._fail("expected ok, got %s" % r)
		return false
	var by_id: Dictionary = r.get("by_unit_id", {})
	if by_id.get(42) != 1:
		tests._fail("expected unit 42 -> option 1, got %s" % by_id)
		return false
	if str(r.get("reasoning_summary", "")) != "x":
		tests._fail("expected reasoning_summary passthrough, got %s" % r.get("reasoning_summary", null))
		return false
	tests._pass("parse_valid_object")
	return true

static func _test_parse_braced_substring_and_fence(tests: Node) -> bool:
	tests._log("test_llm_planning: parse_braced_substring_and_fence")
	var raw := 'Here is JSON:\n```json\n{"actions":[{"unit_id":7,"option_index":0}]}\n```\nDone.'
	var r: Dictionary = LlmPlanningResponseParser.parse_json_actions(raw)
	if not r.get("ok", false):
		tests._fail("expected ok for fenced content, got %s" % r)
		return false
	var by_id: Dictionary = r.get("by_unit_id", {})
	if by_id.get(7) != 0:
		tests._fail("expected unit 7 -> 0, got %s" % by_id)
		return false
	tests._pass("parse_braced_substring_and_fence")
	return true

static func _test_parse_rejects_bad_json(tests: Node) -> bool:
	tests._log("test_llm_planning: parse_rejects_bad_json")
	var r1: Dictionary = LlmPlanningResponseParser.parse_json_actions("")
	if r1.get("ok", true):
		tests._fail("empty should not be ok")
		return false
	var r2: Dictionary = LlmPlanningResponseParser.parse_json_actions('{"actions":[]}')
	if r2.get("ok", true):
		tests._fail("empty actions should not be ok")
		return false
	tests._pass("parse_rejects_bad_json")
	return true


static func _test_rules_catalog_json(tests: Node) -> bool:
	tests._log("test_llm_planning: rules_catalog_json")
	var ad: Array = LlmPlanningRulesCatalog.build_action_definitions()
	var ud: Array = LlmPlanningRulesCatalog.build_unit_type_definitions()
	if ad.is_empty():
		tests._fail("action_definitions empty")
		return false
	if ud.is_empty():
		tests._fail("unit_type_definitions empty")
		return false
	var js := JSON.stringify({"a": ad, "u": ud})
	if js.is_empty():
		tests._fail("JSON.stringify rules catalog failed")
		return false
	var found_marine := false
	for u in ud:
		if str(u.get("description", "")).is_empty():
			tests._fail("unit type %s missing description" % str(u.get("id", "")))
			return false
		if str(u.get("id", "")) != "marine":
			continue
		found_marine = true
		var mk: Array = u.get("move_action_keys", [])
		if not ("move_short" in mk):
			tests._fail("marine expected move_short in move_action_keys")
			return false
		break
	if not found_marine:
		tests._fail("marine unit type missing from catalog")
		return false
	var first: Dictionary = ad[0]
	if not first.has("key") or str(first.get("key", "")).is_empty():
		tests._fail("action definition entry missing key")
		return false
	tests._pass("rules_catalog_json")
	return true
