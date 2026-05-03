extends RefCounted
## Headless tests for LLM planning JSON parse (no live API).

static func run_all(tests: Node) -> bool:
	var ok := true
	ok = _test_parse_valid_object(tests) and ok
	ok = _test_parse_braced_substring_and_fence(tests) and ok
	ok = _test_parse_rejects_bad_json(tests) and ok
	ok = _test_rules_catalog_json(tests) and ok
	ok = _test_enemy_reaction_candidates_scout(tests) and ok
	ok = _test_prediction_metrics_from_hypotheses(tests) and ok
	return ok

static func _test_parse_valid_object(tests: Node) -> bool:
	tests._log("test_llm_planning: parse_valid_object")
	var raw := '{"opponent_prediction":"Enemy marine will advance toward [2,1] to attack our scout.","reasoning_summary":"x","actions":[{"unit_id":42,"action_key":"attack_ray","target_cell":[2,1]}]}'
	var r: Dictionary = LlmPlanningResponseParser.parse_json_actions(raw)
	if not r.get("ok", false):
		tests._fail("expected ok, got %s" % r)
		return false
	var req_by_id: Dictionary = r.get("action_request_by_unit_id", {})
	var req: Dictionary = req_by_id.get(42, {}) as Dictionary
	if str(req.get("action_key", "")) != "attack_ray":
		tests._fail("expected unit 42 action_key attack_ray, got %s" % req)
		return false
	var target_cell: Array = req.get("target_cell", []) as Array
	if target_cell.size() < 2 or int(target_cell[0]) != 2 or int(target_cell[1]) != 1:
		tests._fail("expected unit 42 target_cell [2,1], got %s" % target_cell)
		return false
	if str(r.get("opponent_prediction", "")) != "Enemy marine will advance toward [2,1] to attack our scout.":
		tests._fail("expected opponent_prediction passthrough, got %s" % r.get("opponent_prediction", null))
		return false
	if str(r.get("reasoning_summary", "")) != "x":
		tests._fail("expected reasoning_summary passthrough, got %s" % r.get("reasoning_summary", null))
		return false
	tests._pass("parse_valid_object")
	return true

static func _test_parse_braced_substring_and_fence(tests: Node) -> bool:
	tests._log("test_llm_planning: parse_braced_substring_and_fence")
	var raw := 'Here is JSON:\n```json\n{"actions":[{"unit_id":7,"action_key":"move_short","target_cell":[0,0]}]}\n```\nDone.'
	var r: Dictionary = LlmPlanningResponseParser.parse_json_actions(raw)
	if not r.get("ok", false):
		tests._fail("expected ok for fenced content, got %s" % r)
		return false
	var req_by_id: Dictionary = r.get("action_request_by_unit_id", {})
	var req: Dictionary = req_by_id.get(7, {}) as Dictionary
	if str(req.get("action_key", "")) != "move_short":
		tests._fail("expected unit 7 action_key move_short, got %s" % req)
		return false
	if str(r.get("opponent_prediction", "")) != "":
		tests._fail("missing opponent_prediction should default to empty")
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
	var r3: Dictionary = LlmPlanningResponseParser.parse_json_actions('{"actions":[{"unit_id":1,"action_key":"move_short"}]}')
	if r3.get("ok", true):
		tests._fail("missing target_cell should not be ok")
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


static func _test_enemy_reaction_candidates_scout(tests: Node) -> bool:
	tests._log("test_llm_planning: enemy_reaction_candidates scout")
	var entry: Dictionary = {
		"unit_id": 999,
		"name": "Scout",
		"cell": [0, 0],
		"def": "res://src/unit/definitions/scout.tres",
		"ability_action_keys": ["attack_ray", "recruit_people"],
	}
	var cand: Dictionary = LlmPlanningSnapshot._build_enemy_reaction_candidates(entry)
	var list: Array = cand.get("candidates", []) as Array
	var has_attack := false
	var has_move := false
	var has_recruit := false
	for c in list:
		if not (c is Dictionary):
			continue
		var cd: Dictionary = c
		if str(cd.get("type", "")) == "attack_from_current_cell" and str(cd.get("action_key", "")) == "attack_ray":
			has_attack = true
		if str(cd.get("type", "")) == "move_only_no_same_turn_attack":
			has_move = true
		if str(cd.get("type", "")) == "non_damage_ability" and str(cd.get("action_key", "")) == "recruit_people":
			has_recruit = true
	if not has_attack or not has_move or not has_recruit:
		tests._fail("expected attack_ray, move, and recruit_people in reaction candidates, got %s" % list)
		return false
	tests._pass("enemy_reaction_candidates scout")
	return true


static func _test_prediction_metrics_from_hypotheses(tests: Node) -> bool:
	tests._log("test_llm_planning: prediction metrics from hypotheses")
	var snap: Dictionary = {
		"visible_enemy_units": [],
		"last_known_enemy_positions": [
			{
				"unit_id": 111,
				"cell": [0, 0],
				"ability_action_keys": ["attack_ray"],
			},
		],
		"enemy_reaction_candidates": [{"unit_id": 111}],
		"ai_units": [
			{
				"unit_id": 1,
				"legal_options": [
					{
						"i": 0,
						"action_key": "fast_move",
						"end": [2, 0],
						"incoming_damage_if_enemies_hold_and_shoot_end": 2,
						"enemy_count_can_hit_end_if_hold": 2,
						"is_end_cell_threatened_if_hold": true,
					},
					{"i": 1, "action_key": "fast_move", "end": [3, 0]},
				],
			},
		],
	}
	var hyp: Dictionary = {
		"enemy_predictions": [
			{
				"enemy_unit_id": 111,
				"top1": {"action_key": "attack_ray", "end": [2, 0], "confidence": 0.9},
			},
		],
	}
	LlmPlanningSnapshot.apply_prediction_hypotheses_to_legal_options(snap, hyp)
	if snap.has("enemy_reaction_candidates"):
		tests._fail("expected enemy_reaction_candidates removed")
		return false
	var au: Array = snap.get("ai_units", []) as Array
	var opts: Array = (au[0] as Dictionary).get("legal_options", []) as Array
	var o0: Dictionary = opts[0]
	if int(o0.get("pred_damage_at_end", 0)) != 1:
		tests._fail("expected pred_damage_at_end 1 on [2,0], got %s" % o0.get("pred_damage_at_end", -1))
		return false
	if int(o0.get("pred_enemies_hitting", 0)) != 1:
		tests._fail("expected pred_enemies_hitting 1, got %s" % o0.get("pred_enemies_hitting", -1))
		return false
	if not bool(o0.get("pred_end_threatened", false)):
		tests._fail("expected pred_end_threatened true")
		return false
	if str(o0.get("predicted_enemy_damage_timing_vs_our_action", "")) != "our_action_resolves_first":
		tests._fail("expected fast_move before enemy attack_ray timing, got %s" % o0.get("predicted_enemy_damage_timing_vs_our_action", null))
		return false
	if str(o0.get("pred_damage_resolution_note", "")).is_empty():
		tests._fail("expected pred_damage_resolution_note when pred_damage > 0")
		return false
	if o0.has("incoming_damage_if_enemies_hold_and_shoot_end"):
		tests._fail("hold threat keys should be removed")
		return false
	var o1: Dictionary = opts[1]
	if int(o1.get("pred_damage_at_end", 0)) != 0:
		tests._fail("expected 0 pred damage on [3,0]")
		return false
	tests._pass("prediction metrics from hypotheses")
	return true
