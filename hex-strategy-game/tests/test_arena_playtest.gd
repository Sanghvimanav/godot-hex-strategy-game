extends RefCounted

const ArenaPlaytestScenario = preload("res://src/battle/arena_playtest_scenario.gd")
const ArenaPlaytestData = preload("res://src/battle/arena_playtest_data.gd")
const PureStateArenaSuite = preload("res://src/simulation/pure_state_arena_suite.gd")
const PureStateSelfPlaySuite = preload("res://src/simulation/pure_state_self_play_suite.gd")


static func run_all(tests: Node) -> bool:
	var ok := true
	ok = _test_playable_scenario_preserves_arena_state_and_ids(tests) and ok
	ok = _test_terminal_human_game_emits_policy_and_value_examples(tests) and ok
	ok = _test_turn_limit_keeps_policy_data_without_value_labels(tests) and ok
	return ok


static func _test_playable_scenario_preserves_arena_state_and_ids(tests: Node) -> bool:
	tests._log("test_arena_playtest: playable adapter preserves canonical Arena provenance")
	var seed := int(PureStateArenaSuite.FAST_SEEDS[0])
	var expected_state := PureStateArenaSuite.build_generated_state(seed, "fast", PureStateArenaSuite.DEFAULT_MAP_PROFILE)
	var scenario := ArenaPlaytestScenario.build(seed, "zerg", "balanced")
	if scenario.is_empty():
		tests._fail("playable Arena scenario should build from an official seed")
		return false
	var config: Dictionary = scenario.get("arena_playtest", {})
	if config.get("initial_state", {}) != expected_state:
		tests._fail("playable adapter must retain the exact pure-state Arena start")
		return false
	if str(config.get("agent_profile", "")) != "balanced" or str(config.get("evaluator", "")) != "handwritten":
		tests._fail("playable adapter should preserve selected handwritten agent config: %s" % config)
		return false
	var found_human := false
	var found_ai := false
	for group_variant in scenario.get("groups", []):
		if not (group_variant is Dictionary):
			continue
		var group: Dictionary = group_variant
		var group_name := str(group.get("name", ""))
		if group_name == "zerg" and not bool(group.get("ai", true)):
			found_human = true
		if group_name == "terran" and bool(group.get("ai", false)):
			found_ai = true
		for unit_variant in group.get("units", []):
			if not (unit_variant is Dictionary):
				continue
			var unit: Dictionary = unit_variant
			if not unit.has("unit_id") or not (unit.get("cell") is Vector2i):
				tests._fail("live Arena units must keep stable unit_id and convert cells for the scene: %s" % unit)
				return false
	if not found_human or not found_ai:
		tests._fail("requested human faction should be human and opponent should be AI")
		return false
	tests._pass("Arena seed, search config, faction ownership, and stable unit IDs survive the live adapter")
	return true


static func _test_terminal_human_game_emits_policy_and_value_examples(tests: Node) -> bool:
	tests._log("test_arena_playtest: terminal human games become policy + value data")
	var before := PureStateSelfPlaySuite.build_state("collapse")
	var after := before.duplicate(true)
	for group_variant in after.get("groups", []):
		if group_variant is Dictionary and str((group_variant as Dictionary).get("name", "")) == "zerg":
			for unit_variant in (group_variant as Dictionary).get("units", []):
				if unit_variant is Dictionary:
					(unit_variant as Dictionary)["health"] = 0
	var human_action := {
		"unit_id": 1,
		"action_key": "test_action",
		"path": [],
		"end_point": [0, 0],
	}
	var history := [{
		"turn": 1,
		"state_before": before.duplicate(true),
		"state_after": after.duplicate(true),
		"human_actions": [human_action],
		"ai_actions": [],
	}]
	var config := _config()
	var artifacts := ArenaPlaytestData.build_artifacts(
		"human-terminal-test",
		"terran",
		"zerg",
		config,
		history,
		after,
		"terminal",
		"terran",
		"elimination"
	)
	var policy: Array = artifacts.get("human_policy_examples", [])
	var values: Array = artifacts.get("value_examples", [])
	if policy.size() != 1:
		tests._fail("one completed human turn should emit one policy example, got %d" % policy.size())
		return false
	if values.size() != 4:
		tests._fail("one-turn terminal rollout should emit pre/final value states for both perspectives, got %d" % values.size())
		return false
	var policy_example: Dictionary = policy[0]
	if policy_example.get("chosen_actions", []) != [human_action] or float(policy_example.get("terminal_outcome", 0.0)) != 1.0:
		tests._fail("policy example should retain the human choice and terminal result: %s" % policy_example)
		return false
	tests._pass("terminal playtests reuse the value schema and preserve human choices for imitation/policy learning")
	return true


static func _test_turn_limit_keeps_policy_data_without_value_labels(tests: Node) -> bool:
	tests._log("test_arena_playtest: unresolved games do not poison value targets")
	var state := PureStateSelfPlaySuite.build_state("collapse")
	var history := [{
		"turn": 1,
		"state_before": state.duplicate(true),
		"state_after": state.duplicate(true),
		"human_actions": [],
		"ai_actions": [],
	}]
	var artifacts := ArenaPlaytestData.build_artifacts(
		"human-turn-limit-test",
		"terran",
		"zerg",
		_config(),
		history,
		state,
		"turn_limit",
		"",
		"turn_limit"
	)
	if (artifacts.get("human_policy_examples", []) as Array).size() != 1:
		tests._fail("turn-limit game should still retain the observed human policy choice")
		return false
	if not (artifacts.get("value_examples", []) as Array).is_empty():
		tests._fail("unresolved turn-limit game must not create speculative value labels")
		return false
	var policy_example: Dictionary = (artifacts.get("human_policy_examples", []) as Array)[0]
	if policy_example.get("terminal_outcome", "sentinel") != null:
		tests._fail("unresolved policy examples should carry a null terminal outcome")
		return false
	tests._pass("unresolved matches remain useful demonstrations without inventing a winner")
	return true


static func _config() -> Dictionary:
	return {
		"suite_version": PureStateArenaSuite.SUITE_VERSION,
		"preset": "fast",
		"scenario_seed": int(PureStateArenaSuite.FAST_SEEDS[0]),
		"base_scenario_id": "mixed_force",
		"map_profile": PureStateArenaSuite.DEFAULT_MAP_PROFILE,
		"agent_profile": "fast",
		"evaluator": "handwritten",
		"arena_metadata": {},
	}
