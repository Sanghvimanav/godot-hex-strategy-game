extends RefCounted

static func run_all(tests: Node) -> bool:
	var ok := true
	ok = _test_last_five_and_compact(tests) and ok
	ok = _test_empty_history(tests) and ok
	return ok

static func _test_empty_history(tests: Node) -> bool:
	tests._log("test_llm_planning_recent_turns: empty_history")
	var r: Array = LlmPlanningRecentTurns.build_from_history([])
	if not r.is_empty():
		tests._fail("empty history should yield []")
		return false
	tests._pass("empty_history")
	return true

static func _test_last_five_and_compact(tests: Node) -> bool:
	tests._log("test_llm_planning_recent_turns: last_five_and_compact")
	var hist: Array = []
	for t in range(1, 9):
		hist.append({
			"turn": t,
			"recording": {
				"died_ids": [t * 10],
				"actions": [
					{
						"unit_id": 100 + t,
						"unit_name": "Marine",
						"type": "move" if t % 2 == 0 else "ability",
						"action_key": "attack" if t % 2 == 1 else "",
						"path": [[0, 0], [1, 1]],
					}
				],
			},
		})
	var out: Array = LlmPlanningRecentTurns.build_from_history(hist)
	if out.size() != 5:
		tests._fail("expected 5 turns kept, got %d" % out.size())
		return false
	var first: Dictionary = out[0] as Dictionary
	if int(first.get("turn", 0)) != 4:
		tests._fail("oldest kept turn should be 4, got %s" % str(first.get("turn")))
		return false
	var last: Dictionary = out[out.size() - 1] as Dictionary
	if int(last.get("turn", 0)) != 8:
		tests._fail("newest turn should be 8")
		return false
	var acts: Array = last.get("actions", []) as Array
	if acts.is_empty():
		tests._fail("expected actions")
		return false
	var a0: Dictionary = acts[0] as Dictionary
	if not a0.has("end"):
		tests._fail("move should have end from path tail")
		return false
	tests._pass("last_five_and_compact")
	return true
