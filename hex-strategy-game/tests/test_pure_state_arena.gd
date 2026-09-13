extends RefCounted

const PureStateArenaSuite = preload("res://src/simulation/pure_state_arena_suite.gd")
const PureStateGameRollout = preload("res://src/simulation/pure_state_game_rollout.gd")
const PureStateSelfPlaySuite = preload("res://src/simulation/pure_state_self_play_suite.gd")


static func run_all(tests: Node) -> bool:
	var ok := true
	ok = _test_generated_states_are_seeded_and_reproducible(tests) and ok
	ok = _test_fast_preset_covers_each_family_once(tests) and ok
	ok = _test_official_seed_sets_are_frozen_and_nested(tests) and ok
	ok = _test_generated_jobs_receive_turn_allowance(tests) and ok
	ok = _test_arena_pairs_swap_agent_factions_on_identical_state(tests) and ok
	ok = _test_asymmetric_rollout_records_per_side_search_cost(tests) and ok
	ok = _test_phase_one_map_groups(tests) and ok
	ok = _test_basic_arena_mirrored_pairs(tests) and ok
	return ok


static func _test_basic_arena_mirrored_pairs(tests: Node) -> bool:
	var jobs := PureStateArenaSuite.get_preset("basic", 0, PureStateArenaSuite.MAP_PROFILE_BASIC)
	if jobs.size() != 54:
		tests._fail("basic arena needs 27 setups and 54 faction-mirrored games")
		return false
	for i in range(0, jobs.size(), 2):
		var a: Dictionary = jobs[i]
		var b: Dictionary = jobs[i + 1]
		if a["pair_id"] != b["pair_id"] or a["state"] != b["state"] or a["challenger_group"] == b["challenger_group"]:
			tests._fail("basic arena must mirror the neural side on an identical position")
			return false
		if int(a["hex_radius"]) != 1 or int(a["rotation_steps"]) not in [1, 3, 5]:
			tests._fail("basic arena should be radius one and hold out odd rotations")
			return false
	tests._pass("basic arena spans 2-4 unit counts, odd rotations, and both neural factions")
	var first := PureStateArenaSuite.get_preset("basic_s1", 0, PureStateArenaSuite.MAP_PROFILE_BASIC)
	if first.size() != 6 or first[0]["turn_limit_winner"] != "terran" or int(first[0]["max_turns"]) != 3:
		tests._fail("scenario 1 must also have a held-out three-turn survival check")
		return false
	return true


static func _test_phase_one_map_groups(tests: Node) -> bool:
	var familiar := PureStateArenaSuite.get_preset("phase1_familiar")
	var unfamiliar := PureStateArenaSuite.get_preset("phase1_unfamiliar", 0, PureStateArenaSuite.MAP_PROFILE_UNFAMILIAR)
	if familiar.size() != 20 or unfamiliar.size() != 20:
		tests._fail("Phase 1 requires two separate twenty-game mirrored groups")
		return false
	if unfamiliar != PureStateArenaSuite.get_preset("phase1_unfamiliar", 0, PureStateArenaSuite.MAP_PROFILE_UNFAMILIAR):
		tests._fail("unfamiliar map generation must be reproducible")
		return false
	for index in range(0, 20, 2):
		if unfamiliar[index]["state"] != unfamiliar[index + 1]["state"] or unfamiliar[index]["challenger_group"] == unfamiliar[index + 1]["challenger_group"]:
			tests._fail("each unfamiliar map must be evaluated with both agent factions")
			return false
		var seed := int(unfamiliar[index]["scenario_seed"])
		var fixture := PureStateArenaSuite.build_generated_state(seed)
		if fixture.get("groups", []) == unfamiliar[index]["state"].get("groups", []):
			tests._fail("unfamiliar maps must use new deployments, not metadata-only changes")
			return false
	if not PureStateArenaSuite.get_preset("phase1_unfamiliar").is_empty():
		tests._fail("the unfamiliar preset must fail closed on the familiar generator")
		return false
	tests._pass("Phase 1 holds out deterministic unfamiliar deployments and mirrored pairs")
	return true


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


static func _test_fast_preset_covers_each_family_once(tests: Node) -> bool:
	tests._log("test_pure_state_arena: fast preset stratifies tactical families")
	var jobs := PureStateArenaSuite.get_preset("fast", 999999)
	if jobs.size() != PureStateArenaSuite.FAST_PAIR_COUNT * 2:
		tests._fail("fast arena should contain %d mirrored games, got %d" % [PureStateArenaSuite.FAST_PAIR_COUNT * 2, jobs.size()])
		return false
	var pair_families: Dictionary = {}
	for job_variant in jobs:
		if not (job_variant is Dictionary):
			continue
		var job: Dictionary = job_variant
		var pair_id := str(job.get("pair_id", ""))
		if not pair_families.has(pair_id):
			pair_families[pair_id] = str(job.get("base_scenario_id", ""))
	var counts: Dictionary = {}
	for family_variant in pair_families.values():
		var family := str(family_variant)
		counts[family] = int(counts.get(family, 0)) + 1
	for family in PureStateArenaSuite.SCENARIO_FAMILIES:
		if int(counts.get(str(family), 0)) != 1:
			tests._fail("fast arena should contain each tactical family exactly once: %s" % counts)
			return false
	tests._pass("eight-pair fast arena covers all tactical families once while keeping seeded variation")
	return true


static func _test_official_seed_sets_are_frozen_and_nested(tests: Node) -> bool:
	tests._log("test_pure_state_arena: official fast/full seeds are stable")
	if PureStateArenaSuite.FAST_SEEDS.size() != PureStateArenaSuite.FAST_PAIR_COUNT:
		tests._fail("fast seed set size must match fast pair count")
		return false
	if PureStateArenaSuite.FULL_SEEDS.size() != PureStateArenaSuite.FULL_PAIR_COUNT:
		tests._fail("full seed set size must match full pair count")
		return false
	for index in range(PureStateArenaSuite.FAST_SEEDS.size()):
		if int(PureStateArenaSuite.FAST_SEEDS[index]) != int(PureStateArenaSuite.FULL_SEEDS[index]):
			tests._fail("fast seeds must be the first stable block of the full set")
			return false
	var normal := PureStateArenaSuite.get_preset("fast", PureStateArenaSuite.DEFAULT_SEED_BASE)
	var ignored_override := PureStateArenaSuite.get_preset("fast", 999999)
	if normal != ignored_override:
		tests._fail("official fast preset must not change when a legacy seed-base argument changes")
		return false
	tests._pass("official arena seeds are explicit, stable, and fast is nested inside full")
	return true


static func _test_generated_jobs_receive_turn_allowance(tests: Node) -> bool:
	tests._log("test_pure_state_arena: procedural variants receive two extra turns")
	var jobs := PureStateArenaSuite.get_preset("fast")
	for job_variant in jobs:
		if not (job_variant is Dictionary):
			continue
		var job: Dictionary = job_variant
		var family := str(job.get("base_scenario_id", ""))
		var expected := int(PureStateArenaSuite.FAMILY_MAX_TURNS.get(family, 10)) + PureStateArenaSuite.ARENA_TURN_ALLOWANCE
		if int(job.get("max_turns", -1)) != expected:
			tests._fail("arena job %s should use family cap + allowance, expected %d got %d" % [str(job.get("game_id", "")), expected, int(job.get("max_turns", -1))])
			return false
	tests._pass("procedural arena jobs get a fixed two-turn resolution allowance")
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
