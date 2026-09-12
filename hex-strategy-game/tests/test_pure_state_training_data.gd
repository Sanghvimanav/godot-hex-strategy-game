extends RefCounted

const PureStateTrainingData = preload("res://src/simulation/pure_state_training_data.gd")
const TurnExecutionCore = preload("res://src/battle/turn_execution_core.gd")


static func run_all(tests: Node) -> bool:
	var ok := true
	ok = _test_terminal_game_emits_paired_value_examples(tests) and ok
	ok = _test_terminal_draw_emits_zero_targets(tests) and ok
	ok = _test_turn_limit_emits_no_supervised_targets(tests) and ok
	ok = _test_exploration_replay_starts_after_divergence(tests) and ok
	return ok


static func _test_terminal_game_emits_paired_value_examples(tests: Node) -> bool:
	tests._log("test_pure_state_training_data: terminal game emits perspective value targets")
	var state := _collapse_state()
	var before := state.duplicate(true)
	var result := PureStateTrainingData.generate_game_examples(
		state,
		"zerg",
		"terran",
		"collapse-training-001",
		3,
		8,
		2,
		2
	)
	if state != before:
		tests._fail("training-data generation must not mutate the source state")
		return false
	if not bool(result.get("valid", false)) or not bool(result.get("labeled", false)):
		tests._fail("terminal rollout should produce valid labeled training data: %s" % result)
		return false
	if str(result.get("status", "")) != "terminal" or str(result.get("winner", "")) != "zerg":
		tests._fail("expected terminal Zerg win, got %s" % result)
		return false

	var examples: Array = result.get("examples", [])
	# One-turn game => initial state + terminal state, each from both perspectives.
	if examples.size() != 4 or int(result.get("example_count", -1)) != 4:
		tests._fail("expected 4 paired value examples, got %d" % examples.size())
		return false

	var initial_zerg: Dictionary = examples[0]
	var initial_terran: Dictionary = examples[1]
	var terminal_zerg: Dictionary = examples[2]
	var terminal_terran: Dictionary = examples[3]
	if int(initial_zerg.get("schema_version", 0)) != PureStateTrainingData.SCHEMA_VERSION:
		tests._fail("training example missing schema version")
		return false
	if str(initial_zerg.get("game_id", "")) != "collapse-training-001":
		tests._fail("training example should preserve explicit game id")
		return false
	if str(initial_zerg.get("perspective_group", "")) != "zerg" or float(initial_zerg.get("outcome", 0.0)) != 1.0:
		tests._fail("Zerg perspective should receive +1 target: %s" % initial_zerg)
		return false
	if str(initial_terran.get("perspective_group", "")) != "terran" or float(initial_terran.get("outcome", 0.0)) != -1.0:
		tests._fail("Terran perspective should receive -1 target: %s" % initial_terran)
		return false
	if bool(initial_zerg.get("terminal", true)) or int(initial_zerg.get("turn_index", -1)) != 0:
		tests._fail("initial training state should be nonterminal at turn_index 0")
		return false
	if not bool(terminal_zerg.get("terminal", false)) or not bool(terminal_terran.get("terminal", false)):
		tests._fail("final paired examples should be marked terminal")
		return false
	if int(terminal_zerg.get("turn_index", -1)) != 1:
		tests._fail("one-turn game terminal state should use turn_index 1")
		return false
	# Rollout normalization derives command objectives on its private state copy.
	# This fixture's Zerg deployment is one hex up-left of Terran, so the
	# deployment-aware objective axis is the (-q,+r) diagonal. Training examples
	# must include those normalized objectives while the caller state stays pure.
	var expected_initial_state := before.duplicate(true)
	expected_initial_state["turn_index"] = 0
	expected_initial_state["command_hexes"] = {
		"zerg": [-5, 5],
		"terran": [5, -5],
	}
	if initial_zerg.get("state", {}) != expected_initial_state:
		tests._fail("first exported state should match the objective-normalized rollout state")
		return false
	if initial_terran.get("state", {}) != expected_initial_state:
		tests._fail("both perspective examples should share the same objective-aware initial state")
		return false
	var source: Dictionary = initial_zerg.get("source", {})
	if int(source.get("own_max_plans", 0)) != 2 or int(source.get("opponent_max_plans", 0)) != 2:
		tests._fail("training example should record self-play search budgets: %s" % source)
		return false

	var jsonl := PureStateTrainingData.to_jsonl(examples)
	var lines := jsonl.strip_edges().split("\n", false)
	if lines.size() != 4:
		tests._fail("JSONL should contain one line per example, got %d" % lines.size())
		return false
	for line in lines:
		var parsed = JSON.parse_string(line)
		if not (parsed is Dictionary):
			tests._fail("every JSONL line should parse as an object: %s" % line)
			return false

	tests._log("  winner=zerg turns=%d examples=%d jsonl_lines=%d" % [
		int(result.get("turns_played", 0)),
		examples.size(),
		lines.size(),
	])
	tests._pass("terminal self-play emits deterministic paired objective-aware value targets and JSONL")
	return true


static func _test_terminal_draw_emits_zero_targets(tests: Node) -> bool:
	tests._log("test_pure_state_training_data: terminal draw emits zero targets")
	var state := {
		"scenario_id": "training_draw",
		"hex_radius": 5,
		"groups": [
			{"name": "terran", "resources": {}, "units": [_dead_unit(1, "res://src/unit/definitions/marine.tres", Vector2i.ZERO)]},
			{"name": "zerg", "resources": {}, "units": [_dead_unit(2, "res://src/unit/definitions/zergling.tres", Vector2i(1, 0))]},
		],
		"tile_resources": {},
	}
	var result := PureStateTrainingData.generate_game_examples(
		state,
		"terran",
		"zerg",
		"draw-training-001",
		2,
		8,
		1,
		1
	)
	if not bool(result.get("valid", false)) or not bool(result.get("labeled", false)):
		tests._fail("initial terminal draw should be valid labeled data")
		return false
	if str(result.get("winner", "not-empty")) != "" or int(result.get("turns_played", -1)) != 0:
		tests._fail("expected zero-turn terminal draw: %s" % result)
		return false
	var examples: Array = result.get("examples", [])
	if examples.size() != 2:
		tests._fail("zero-turn draw should emit one state from two perspectives")
		return false
	for example_variant in examples:
		var example: Dictionary = example_variant
		if float(example.get("outcome", 1.0)) != 0.0 or not bool(example.get("terminal", false)):
			tests._fail("draw targets should be terminal zero values: %s" % example)
			return false
	tests._pass("true terminal draws receive 0 value targets")
	return true


static func _test_turn_limit_emits_no_supervised_targets(tests: Node) -> bool:
	tests._log("test_pure_state_training_data: turn limit is not mislabeled as draw")
	var state := _distant_scout_vs_zergling_state()
	var result := PureStateTrainingData.generate_game_examples(
		state,
		"terran",
		"zerg",
		"capped-training-001",
		1,
		8,
		1,
		1
	)
	if not bool(result.get("valid", false)):
		tests._fail("capped self-play rollout should still be valid")
		return false
	if str(result.get("status", "")) != "turn_limit":
		tests._fail("expected explicit turn_limit status, got %s" % result.get("status", ""))
		return false
	if bool(result.get("labeled", true)):
		tests._fail("turn-limit games must not be marked labeled")
		return false
	var examples: Array = result.get("examples", [])
	if not examples.is_empty() or int(result.get("example_count", -1)) != 0:
		tests._fail("turn-limit games must emit zero supervised examples")
		return false
	if PureStateTrainingData.to_jsonl(examples) != "":
		tests._fail("empty unlabeled dataset should serialize to empty JSONL")
		return false
	tests._pass("turn-limit games remain unlabeled instead of becoming false draws")
	return true


static func _test_exploration_replay_starts_after_divergence(tests: Node) -> bool:
	tests._log("test_pure_state_training_data: exploration skips shared pre-divergence states")
	var shared := _synthetic_training_state("shared", 0)
	var explore_after := _synthetic_training_state("explore_after", 1)
	var greedy_after := _synthetic_training_state("greedy_after", -1)
	var explore_final := _synthetic_training_state("explore_final", 2)
	var greedy_final := _synthetic_training_state("greedy_final", -2)
	var exploration_rollout := {
		"valid": true,
		"status": "terminal",
		"winner": "terran",
		"termination_reason": "elimination",
		"turns_played": 2,
		"max_non_progress_streak": 0,
		"history": [
			{"state_before": shared.duplicate(true)},
			{"state_before": explore_after.duplicate(true)},
		],
		"final_state": explore_final.duplicate(true),
	}
	var greedy_rollout := {
		"valid": true,
		"status": "terminal",
		"winner": "zerg",
		"termination_reason": "elimination",
		"turns_played": 2,
		"max_non_progress_streak": 0,
		"history": [
			{"state_before": shared.duplicate(true)},
			{"state_before": greedy_after.duplicate(true)},
		],
		"final_state": greedy_final.duplicate(true),
	}
	var divergence := PureStateTrainingData.first_divergent_state_index(exploration_rollout, greedy_rollout)
	if divergence != 1:
		tests._fail("expected first novel exploration state at turn 1, got %d" % divergence)
		return false
	var result := PureStateTrainingData.build_examples_from_rollout(
		exploration_rollout,
		"terran",
		"zerg",
		"explore-divergence-test",
		{"training_start_turn": divergence, "policy_exploration_profile": "light"}
	)
	var examples: Array = result.get("examples", [])
	if examples.size() != 4:
		tests._fail("two post-divergence states from two perspectives should emit 4 examples, got %d" % examples.size())
		return false
	if int((examples[0] as Dictionary).get("turn_index", -1)) != 1:
		tests._fail("first exploration training example must begin after divergence")
		return false
	if (examples[0] as Dictionary).get("state", {}) == shared:
		tests._fail("shared pre-divergence state must not be emitted by exploration replay")
		return false
	var identical_divergence := PureStateTrainingData.first_divergent_state_index(exploration_rollout, exploration_rollout)
	if identical_divergence != -1:
		tests._fail("identical replay should have no novel training state")
		return false
	var no_novel_examples := PureStateTrainingData.build_examples_from_rollout(
		exploration_rollout,
		"terran",
		"zerg",
		"explore-identical-test",
		{"training_start_turn": -1, "policy_exploration_profile": "light"}
	)
	if not (no_novel_examples.get("examples", []) as Array).is_empty():
		tests._fail("non-divergent exploration replay must add zero supervised examples")
		return false
	tests._pass("exploration replays add only states created after trajectory divergence")
	return true


static func _collapse_state() -> Dictionary:
	return {
		"scenario_id": "training_collapse",
		"hex_radius": 5,
		"groups": [
			{"name": "terran", "resources": {}, "units": [
				_make_unit(1, "res://src/unit/definitions/marine.tres", Vector2i(-2, 1)),
				_make_unit(2, "res://src/unit/definitions/marine.tres", Vector2i(-2, 1)),
				_make_unit(3, "res://src/unit/definitions/marine.tres", Vector2i(-2, 1)),
			]},
			{"name": "zerg", "resources": {}, "units": [
				_make_unit(4, "res://src/unit/definitions/zergling.tres", Vector2i(-3, 2)),
				_make_unit(5, "res://src/unit/definitions/zergling.tres", Vector2i(-3, 2)),
				_make_unit(6, "res://src/unit/definitions/zergling.tres", Vector2i(-3, 2)),
				_make_unit(7, "res://src/unit/definitions/zergling.tres", Vector2i(-3, 2)),
			]},
		],
		"tile_resources": {},
	}


static func _distant_scout_vs_zergling_state() -> Dictionary:
	return {
		"scenario_id": "training_turn_limit",
		"hex_radius": 5,
		"groups": [
			{"name": "terran", "resources": {}, "units": [
				_make_unit(1, "res://src/unit/definitions/scout.tres", Vector2i(4, 0)),
			]},
			{"name": "zerg", "resources": {}, "units": [
				_make_unit(2, "res://src/unit/definitions/zergling.tres", Vector2i(-4, 0)),
			]},
		],
		"tile_resources": {},
	}


static func _synthetic_training_state(scenario_id: String, marker: int) -> Dictionary:
	return {
		"scenario_id": scenario_id,
		"hex_radius": 2,
		"groups": [
			{"name": "terran", "resources": {"marker": marker}, "units": []},
			{"name": "zerg", "resources": {}, "units": []},
		],
		"tile_resources": {},
	}


static func _make_unit(unit_id: int, def_path: String, cell: Vector2i) -> Dictionary:
	var def_dict := TurnExecutionCore.get_unit_def(def_path)
	var max_health := int(def_dict.get("max_health", 2))
	var max_energy := int(def_dict.get("max_energy", 0))
	var start_energy := int(def_dict.get("start_energy", max_energy))
	return {
		"unit_id": unit_id,
		"def_path": def_path,
		"cell": [cell.x, cell.y],
		"health": max_health,
		"max_health": max_health,
		"energy": start_energy,
		"max_energy": max_energy,
		"effects": [],
		"is_active": true,
	}


static func _dead_unit(unit_id: int, def_path: String, cell: Vector2i) -> Dictionary:
	var unit := _make_unit(unit_id, def_path, cell)
	unit["health"] = 0
	return unit
