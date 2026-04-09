extends RefCounted
## Headless tests for post-game outcome + stub shape (no live API).

static func run_all(tests: Node) -> bool:
	var ok := true
	ok = _test_ai_outcome(tests) and ok
	ok = _test_build_match_summary(tests) and ok
	ok = _test_sanitize_and_payload(tests) and ok
	ok = _test_post_game_payload_includes_unit_roster(tests) and ok
	ok = _test_parse_post_game_llm_markdown(tests) and ok
	return ok


static func _test_ai_outcome(tests: Node) -> bool:
	tests._log("test_llm_post_game: ai_outcome")
	var gs1: Dictionary = {
		"groups": [
			{"name": "player", "units": [{"health": 2}]},
			{"name": "opponent", "units": [{"health": 1}]},
		]
	}
	var ai1: Array[String] = ["opponent"]
	if LlmPostGame.ai_outcome_from_game_state(gs1, ai1) != "incomplete":
		tests._fail("expected incomplete when both alive")
		return false
	var gs2: Dictionary = {
		"groups": [
			{"name": "player", "units": []},
			{"name": "opponent", "units": [{"health": 1}]},
		]
	}
	if LlmPostGame.ai_outcome_from_game_state(gs2, ai1) != "win":
		tests._fail("expected win when only AI alive")
		return false
	var gs3: Dictionary = {
		"groups": [
			{"name": "player", "units": [{"health": 1}]},
			{"name": "opponent", "units": []},
		]
	}
	if LlmPostGame.ai_outcome_from_game_state(gs3, ai1) != "loss":
		tests._fail("expected loss when only human alive")
		return false
	tests._pass("ai_outcome")
	return true


static func _test_build_match_summary(tests: Node) -> bool:
	tests._log("test_llm_post_game: build_match_summary")
	var session: Dictionary = {
		"match_had_llm_validated_plan": true,
		"scenario_id": "scout_debug",
		"turn_number": 4,
		"ai_group_names": ["opponent"],
		"game_state": {
			"groups": [
				{"name": "player", "units": [{"health": 1}]},
				{"name": "opponent", "units": [{"health": 0}]},
			]
		},
	}
	var m: Dictionary = LlmPostGame.build_match_summary(session)
	if not bool(m.get("had_llm_plans", false)):
		tests._fail("expected had_llm_plans")
		return false
	if str(m.get("ai_outcome", "")) != "loss":
		tests._fail("expected loss for AI when only human alive")
		return false
	if str(m.get("scenario_id", "")) != "scout_debug":
		tests._fail("scenario id passthrough")
		return false
	if int(m.get("recorded_turns_in_history", -1)) != 0:
		tests._fail("expected 0 recorded turns when match_turn_history absent")
		return false
	tests._pass("build_match_summary")
	return true


static func _test_sanitize_and_payload(tests: Node) -> bool:
	tests._log("test_llm_post_game: sanitize_and_payload")
	var d: Dictionary = {"cell": Vector2i(1, -2), "n": 3}
	var s: Variant = LlmPostGame.sanitize_for_json(d)
	if not (s is Dictionary):
		tests._fail("sanitize should return dict")
		return false
	var cell: Variant = (s as Dictionary).get("cell")
	if not (cell is Array) or int(cell[0]) != 1 or int(cell[1]) != -2:
		tests._fail("expected cell [1,-2], got %s" % cell)
		return false
	var session: Dictionary = {
		"match_turn_history": [
			{"turn": 1, "recording": {"died_ids": [5], "actions": []}},
		],
		"match_had_llm_validated_plan": true,
		"scenario_id": "x",
		"turn_number": 2,
		"ai_group_names": ["opponent"],
		"game_state": {"groups": []},
	}
	var ms: Dictionary = LlmPostGame.build_match_summary(session)
	if int(ms.get("recorded_turns_in_history", 0)) != 1:
		tests._fail("expected 1 turn in history count")
		return false
	var js: String = LlmPostGame.build_post_game_user_json(session, ms, "", "")
	if not js.contains("match_turn_history"):
		tests._fail("payload should include match_turn_history")
		return false
	if not js.contains("\"turn\":1"):
		tests._fail("should serialize turn number")
		return false
	tests._pass("sanitize_and_payload")
	return true


static func _test_post_game_payload_includes_unit_roster(tests: Node) -> bool:
	tests._log("test_llm_post_game: post_game_payload_unit_roster")
	var session: Dictionary = {
		"match_turn_history": [],
		"match_had_llm_validated_plan": true,
		"scenario_id": "x",
		"turn_number": 2,
		"ai_group_names": ["opponent"],
		"game_state": {"groups": []},
	}
	var ms: Dictionary = LlmPostGame.build_match_summary(session)
	var js: String = LlmPostGame.build_post_game_user_json(session, ms, "dist", "recent")
	var data: Variant = JSON.parse_string(js)
	if not (data is Dictionary):
		tests._fail("payload should parse as JSON")
		return false
	var roster: Variant = (data as Dictionary).get("unit_action_roster", null)
	if not (roster is Array):
		tests._fail("unit_action_roster should be array")
		return false
	var found_mountain := false
	for item in roster as Array:
		if item is Dictionary and str((item as Dictionary).get("name", "")) == "Mountain":
			found_mountain = true
			var moves: Variant = (item as Dictionary).get("moves", null)
			if not (moves is Array) or (moves as Array).size() != 0:
				tests._fail("Mountain should have empty moves list")
				return false
			break
	if not found_mountain:
		tests._fail("roster should include Mountain")
		return false
	if str((data as Dictionary).get("prior_distilled", "")) != "dist":
		tests._fail("prior_distilled passthrough")
		return false
	if str((data as Dictionary).get("prior_recent_session_learnings", "")) != "recent":
		tests._fail("prior_recent_session_learnings passthrough")
		return false
	tests._pass("post_game_payload_unit_roster")
	return true


static func _test_parse_post_game_llm_markdown(tests: Node) -> bool:
	tests._log("test_llm_post_game: parse_post_game_llm_markdown")
	var sample := """## Distilled
### Ranked learnings
- A

### Active contradictions
- none

### Experiments
- none

## Metadata
- scenario: x

## Learnings
- B
"""
	var p: Dictionary = LlmPostGame.parse_post_game_llm_markdown(sample)
	if not bool(p.get("ok", false)):
		tests._fail("expected ok parse")
		return false
	if not str(p.get("distilled", "")).contains("Ranked learnings"):
		tests._fail("distilled body missing")
		return false
	if not str(p.get("session", "")).begins_with("## Metadata"):
		tests._fail("session should start with Metadata")
		return false
	var bad: Dictionary = LlmPostGame.parse_post_game_llm_markdown("## Learnings\n- only")
	if bool(bad.get("ok", false)):
		tests._fail("expected fail without Distilled")
		return false
	tests._pass("parse_post_game_llm_markdown")
	return true
