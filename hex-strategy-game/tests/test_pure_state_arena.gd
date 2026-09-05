extends RefCounted

const PureStateArenaSuite = preload("res://src/simulation/pure_state_arena_suite.gd")
const PureStateGameRollout = preload("res://src/simulation/pure_state_game_rollout.gd")
const PureStateSelfPlaySuite = preload("res://src/simulation/pure_state_self_play_suite.gd")


static func run_all(tests: Node) -> bool:
	var ok := true
	ok = _test_generated_states_are_seeded_and_reproducible(tests) and ok
	ok = _test_arena_pairs_swap_agent_factions_on_identical_state(tests) and ok
	ok = _test_asymmetric_rollout_records_per_side_search_cost(tests) and ok
	return ok


static func _test_generated_states_are_seeded_and_reproducible(tests: Node) -> bool:
	tests._log("test_pure_state_arena: seeded generated states are reproducible")
	var first := PureStateArenaSuite.build_generated_state(424242, "fast")
	var again := PureStateArenaSuite.build_generated_state(424242, "fast")
	var different := PureStateArenaSuite.build_generated_state(424243, "fast")
	if first != again:
		tests._fail("same arena seed must reproduce the exact same generated state")
		return false
	if first == different:
		tests._fail("neighboring arena seeds should not collapse to the exact same state")
		return false
	var metadata: Dictionary = first.get("arena_metadata", {})
	if int(metadata.get("scenario_seed", 0)) != 424242 or str(metadata.get("base_scenario_id", "")).is_empty():
		tests._fail("generated arena state should retain seed/family provenance: %s" % metadata)
		return false
	tests._pass("arena randomness is reproducible and records exact scenario provenance")
	return true


static func _test_arena_pairs_swap_agent_factions_on_identical_state(tests: Node) -> bool:
	tests._log("test_pure_state_arena: every seed gets a side-swapped mirror game")
	var jobs := PureStateArenaSuite.get_preset("smoke", 777)
	if jobs.size() != 4:
		tests._fail("smoke arena should contain two generated pairs / four games, got %d" % jobs.size())
		return false
	for pair_start in [0, 2]:
		var a: Dictionary = jobs[pair_start]
		var b: Dictionary = jobs[pair_start + 1]
		if str(a.get("pair_id", "")) != str(b.get("pair_id", "")):
			tests._fail("mirror games must share one pair id")
			return false
		if a.get("state", {}) != b.get("state", {}):
			tests._fail("mirror games must use the exact same generated starting state")
			return false
		if str(a.get("challenger_group", "")) != "terran" or str(b.get("challenger_group", "")) != "zerg":
			tests._fail("challenger must play both factions inside each pair")
			return false
	tests._pass("paired arena games cancel faction/geometry bias by swapping AI ownership")
	return true


static func _test_asymmetric_rollout_records_per_side_search_cost(tests: Node) -> bool:
	tests._log("test_pure_state_arena: asymmetric rollout exposes per-side compute")
	var state := PureStateSelfPlaySuite.build_state("collapse")
	var before := state.duplicate(true)
	var fast := PureStateArenaSuite.agent_settings("fast")
	var balanced := PureStateArenaSuite.agent_settings("balanced")
	var result := PureStateGameRollout.play_game_with_settings(
		state,
		"terran",
		"zerg",
		fast,
		balanced,
		1,
		false
	)
	if state != before:
		tests._fail("arena rollout must not mutate the generated source state")
		return false
	if not bool(result.get("valid", false)):
		tests._fail("asymmetric one-turn arena rollout should be valid: %s" % result)
		return false
	var metrics: Dictionary = result.get("search_metrics", {})
	var terran: Dictionary = metrics.get("terran", {})
	var zerg: Dictionary = metrics.get("zerg", {})
	if int(terran.get("decisions", 0)) != 1 or int(zerg.get("decisions", 0)) != 1:
		tests._fail("both arena agents should record one decision: %s" % metrics)
		return false
	if int(terran.get("simulations", 0)) <= 0 or int(zerg.get("simulations", 0)) <= 0:
		tests._fail("arena metrics should expose simulated plan pairs for both agents: %s" % metrics)
		return false
	tests._pass("arena rollout compares independent configs and measures their search cost")
	return true
