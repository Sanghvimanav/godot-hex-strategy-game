extends RefCounted
## Tests for canonical state hashing and deterministic ReplayV1 verification.

const PureStateHash = preload("res://src/simulation/pure_state_hash.gd")
const PureStateReplayV1 = preload("res://src/simulation/pure_state_replay_v1.gd")


static func run_all(tests: Node) -> bool:
	var ok := true
	ok = _test_hash_ignores_dictionary_insertion_order(tests) and ok
	ok = _test_hash_changes_when_state_changes(tests) and ok
	ok = _test_replay_round_trip_verifies(tests) and ok
	ok = _test_replay_reports_first_divergent_turn(tests) and ok
	return ok


static func _make_fixture() -> Dictionary:
	return {
		"game_state": {
			"groups": [
				{
					"name": "terran",
					"ai": false,
					"units": [{
						"unit_id": 1,
						"def_path": "res://src/unit/definitions/marine.tres",
						"cell": [1, 0],
						"health": 3,
						"max_health": 3,
						"energy": 4,
						"max_energy": 4,
					}],
				},
				{
					"name": "zerg",
					"ai": false,
					"units": [{
						"unit_id": 2,
						"def_path": "res://src/unit/definitions/zergling.tres",
						"cell": [0, 0],
						"health": 1,
						"max_health": 1,
						"energy": 0,
						"max_energy": 0,
					}],
				},
			]
		},
		"player_actions": {
			"terran": [{
				"unit_id": 1,
				"action_key": "attack_short",
				"path": [],
				"end_point": [0, 0],
			}],
			"zerg": [],
		},
	}


static func _test_hash_ignores_dictionary_insertion_order(tests: Node) -> bool:
	tests._log("test_pure_state_replay_v1: canonical hash ignores dictionary insertion order")
	var a := {
		"groups": [{"name": "terran", "resources": {"crystal": 2, "people": 1}}],
		"turn_index": 3,
	}
	var b := {
		"turn_index": 3,
		"groups": [{"resources": {"people": 1, "crystal": 2}, "name": "terran"}],
	}
	if PureStateHash.hash_state(a) != PureStateHash.hash_state(b):
		tests._fail("equivalent dictionaries should have the same canonical hash")
		return false
	tests._pass("canonical hash ignores dictionary insertion order")
	return true


static func _test_hash_changes_when_state_changes(tests: Node) -> bool:
	tests._log("test_pure_state_replay_v1: canonical hash changes with state")
	var fixture := _make_fixture()
	var state_a: Dictionary = fixture.game_state
	var state_b: Dictionary = state_a.duplicate(true)
	state_b["groups"][0]["units"][0]["health"] = 2
	if PureStateHash.hash_state(state_a) == PureStateHash.hash_state(state_b):
		tests._fail("different game states should not share a canonical hash")
		return false
	tests._pass("canonical hash changes with state")
	return true


static func _test_replay_round_trip_verifies(tests: Node) -> bool:
	tests._log("test_pure_state_replay_v1: replay round trip verifies")
	var fixture := _make_fixture()
	var replay := PureStateReplayV1.build(
		fixture.game_state,
		[{"turn": 1, "submitted_actions": fixture.player_actions}],
		{"rules_version": "test-rules"}
	)
	if str(replay.get("schema", "")) != "ReplayV1" or int(replay.get("schema_version", 0)) != 1:
		tests._fail("ReplayV1 should emit a versioned schema")
		return false
	var verified := PureStateReplayV1.verify(replay)
	if not bool(verified.get("verified", false)):
		tests._fail("freshly built ReplayV1 should verify: %s" % [verified])
		return false
	if int(verified.get("turns_replayed", 0)) != 1:
		tests._fail("ReplayV1 should replay exactly one submitted turn")
		return false
	var events: Array = replay.get("turns", [])[0].get("resolution_events", [])
	var saw_elimination := false
	var saw_executed_action := false
	for event_variant in events:
		if not (event_variant is Dictionary):
			continue
		var event: Dictionary = event_variant
		if str(event.get("code", "")) == "unit_eliminated" and int(event.get("unit_id", -1)) == 2:
			saw_elimination = true
		if str(event.get("code", "")) == "action_executed" and int(event.get("unit_id", -1)) == 1:
			saw_executed_action = true
	if not saw_elimination or not saw_executed_action:
		tests._fail("ReplayV1 should include reason-coded execution/elimination events")
		return false
	tests._pass("replay round trip verifies")
	return true


static func _test_replay_reports_first_divergent_turn(tests: Node) -> bool:
	tests._log("test_pure_state_replay_v1: tampered replay reports divergence")
	var fixture := _make_fixture()
	var replay := PureStateReplayV1.build(
		fixture.game_state,
		[{"turn": 1, "submitted_actions": fixture.player_actions}]
	)
	var tampered := replay.duplicate(true)
	tampered["turns"][0]["submitted_actions"]["terran"][0]["end_point"] = [1, 0]
	var verified := PureStateReplayV1.verify(tampered)
	if bool(verified.get("verified", false)):
		tests._fail("tampered ReplayV1 should not verify")
		return false
	if int(verified.get("diverged_at_turn", 0)) != 1:
		tests._fail("tampered ReplayV1 should identify turn 1 as the divergence")
		return false
	if str(verified.get("error", "")) != "state_hash_after_mismatch":
		tests._fail("expected state_hash_after_mismatch, got %s" % [verified.get("error", "")])
		return false
	tests._pass("tampered replay reports divergence")
	return true
