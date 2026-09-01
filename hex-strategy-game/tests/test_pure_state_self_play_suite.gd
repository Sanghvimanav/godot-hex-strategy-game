extends RefCounted

const PureStateSelfPlaySuite = preload("res://src/simulation/pure_state_self_play_suite.gd")
const PureStateTrainingData = preload("res://src/simulation/pure_state_training_data.gd")


static func run_all(tests: Node) -> bool:
	var ok := true
	ok = _test_starter_preset_is_versioned_and_diverse(tests) and ok
	ok = _test_diverse_preset_expands_tactical_families(tests) and ok
	ok = _test_seeded_variation_is_reproducible_and_valid(tests) and ok
	ok = _test_six_hex_rotations_round_trip(tests) and ok
	ok = _test_smoke_game_emits_rules_provenance(tests) and ok
	return ok


static func _test_starter_preset_is_versioned_and_diverse(tests: Node) -> bool:
	tests._log("test_pure_state_self_play_suite: starter preset structure")
	var jobs := PureStateSelfPlaySuite.get_preset("starter")
	if jobs.size() != 10:
		tests._fail("starter self-play preset should contain 10 distinct jobs, got %d" % jobs.size())
		return false
	var ids: Dictionary = {}
	var profiles: Dictionary = {}
	for job_variant in jobs:
		if not (job_variant is Dictionary):
			tests._fail("every self-play job must be a Dictionary")
			return false
		var job: Dictionary = job_variant
		var game_id := str(job.get("game_id", ""))
		if game_id.is_empty() or ids.has(game_id):
			tests._fail("self-play game ids must be non-empty and unique: %s" % game_id)
			return false
		ids[game_id] = true
		profiles[str(job.get("budget_profile", ""))] = true
		var state: Dictionary = job.get("state", {})
		if state.is_empty() or int(state.get("hex_radius", 0)) <= 0:
			tests._fail("self-play jobs must contain bounded pure states")
			return false
		if int(job.get("own_max_plans", 0)) <= 0 or int(job.get("opponent_max_plans", 0)) <= 0:
			tests._fail("self-play jobs must contain positive search budgets")
			return false
	for required in ["fast", "balanced", "broad"]:
		if not profiles.has(required):
			tests._fail("starter preset should include %s search profile" % required)
			return false
	tests._pass("starter preset is unique, bounded, and spans fast/balanced/broad search")
	return true


static func _test_diverse_preset_expands_tactical_families(tests: Node) -> bool:
	tests._log("test_pure_state_self_play_suite: diverse preset spans mechanics and families")
	var jobs := PureStateSelfPlaySuite.get_preset("diverse")
	if jobs.size() != 24:
		tests._fail("diverse preset should contain 24 jobs, got %d" % jobs.size())
		return false
	var ids: Dictionary = {}
	var families: Dictionary = {}
	var varied_jobs := 0
	var definition_paths: Dictionary = {}
	for job_variant in jobs:
		if not (job_variant is Dictionary):
			return false
		var job: Dictionary = job_variant
		var game_id := str(job.get("game_id", ""))
		if game_id.is_empty() or ids.has(game_id):
			tests._fail("diverse game ids must be unique: %s" % game_id)
			return false
		ids[game_id] = true
		families[str(job.get("scenario_id", ""))] = true
		if int(job.get("variation_seed", 0)) != 0:
			varied_jobs += 1
		var state: Dictionary = job.get("state", {})
		for group_variant in state.get("groups", []):
			if not (group_variant is Dictionary):
				continue
			for unit_variant in (group_variant as Dictionary).get("units", []):
				if unit_variant is Dictionary:
					definition_paths[str((unit_variant as Dictionary).get("def_path", ""))] = true
	if families.size() < 10:
		tests._fail("diverse preset should span at least 10 tactical families, got %d" % families.size())
		return false
	if varied_jobs != 14:
		tests._fail("diverse preset should contain 14 seeded variants, got %d" % varied_jobs)
		return false
	for required_path in [
		"res://src/unit/definitions/hydralisk.tres",
		"res://src/unit/definitions/medic.tres",
		"res://src/unit/definitions/excavator.tres",
		"res://src/unit/definitions/shardling.tres",
	]:
		if not definition_paths.has(required_path):
			tests._fail("diverse preset is missing unit coverage for %s" % required_path)
			return false
	tests._pass("diverse preset expands to 24 jobs, 10+ families, and support/ranged/economy units")
	return true


static func _test_seeded_variation_is_reproducible_and_valid(tests: Node) -> bool:
	tests._log("test_pure_state_self_play_suite: seeded variation is reproducible and bounded")
	var original := PureStateSelfPlaySuite.build_state("attrition")
	var snapshot := original.duplicate(true)
	var first := PureStateSelfPlaySuite.vary_state(original, 12345)
	var again := PureStateSelfPlaySuite.vary_state(original, 12345)
	var different := PureStateSelfPlaySuite.vary_state(original, 54321)
	if first != again:
		tests._fail("same variation seed should produce identical states")
		return false
	if first == different:
		tests._fail("different variation seeds should produce different tactical states")
		return false
	if original != snapshot:
		tests._fail("variation helper must not mutate its source state")
		return false
	var radius := int(first.get("hex_radius", 0))
	for group_variant in first.get("groups", []):
		if not (group_variant is Dictionary):
			continue
		for unit_variant in (group_variant as Dictionary).get("units", []):
			if not (unit_variant is Dictionary):
				continue
			var unit: Dictionary = unit_variant
			if int(unit.get("health", 0)) <= 0:
				tests._fail("variation must never create a dead starting unit")
				return false
			var energy := int(unit.get("energy", 0))
			if energy < 0 or energy > int(unit.get("max_energy", 0)):
				tests._fail("variation must keep energy within unit bounds")
				return false
			var cell: Array = unit.get("cell", [])
			if cell.size() < 2 or not _cell_in_hex(Vector2i(int(cell[0]), int(cell[1])), radius):
				tests._fail("variation moved a unit outside radius %d: %s" % [radius, str(cell)])
				return false
	tests._pass("seeded variation is deterministic, pure, alive, and inside the map")
	return true


static func _test_six_hex_rotations_round_trip(tests: Node) -> bool:
	tests._log("test_pure_state_self_play_suite: six rotations return original state")
	var original := PureStateSelfPlaySuite.build_state("mixed_force")
	var rotated := PureStateSelfPlaySuite.rotate_state(original, 6)
	if rotated != original:
		tests._fail("six 60-degree rotations should return the original pure state")
		return false
	var once := PureStateSelfPlaySuite.rotate_state(original, 1)
	if once == original:
		tests._fail("one 60-degree rotation should actually change asymmetric mixed-force coordinates")
		return false
	if original != PureStateSelfPlaySuite.build_state("mixed_force"):
		tests._fail("rotation helper must not mutate source state")
		return false
	tests._pass("hex rotations are deterministic, pure, and round-trip after six steps")
	return true


static func _test_smoke_game_emits_rules_provenance(tests: Node) -> bool:
	tests._log("test_pure_state_self_play_suite: smoke game emits versioned training examples")
	var jobs := PureStateSelfPlaySuite.get_preset("smoke")
	if jobs.size() != 1:
		tests._fail("smoke preset should contain exactly one cheap game")
		return false
	var job: Dictionary = jobs[0]
	var result := PureStateTrainingData.generate_game_examples(
		job.get("state", {}) as Dictionary,
		str(job.get("group_a", "terran")),
		str(job.get("group_b", "zerg")),
		str(job.get("game_id", "")),
		int(job.get("max_turns", 1)),
		int(job.get("max_actions_per_unit", 1)),
		int(job.get("own_max_plans", 1)),
		int(job.get("opponent_max_plans", 1)),
		{
			"rules_version": "test-rules-sha",
			"self_play_suite_version": PureStateSelfPlaySuite.SUITE_VERSION,
			"dataset_preset": "smoke",
		}
	)
	if not bool(result.get("valid", false)) or not bool(result.get("labeled", false)):
		tests._fail("smoke self-play game should terminate and emit labels: %s" % result)
		return false
	var examples: Array = result.get("examples", [])
	if examples.is_empty():
		tests._fail("smoke self-play game should emit at least one training example")
		return false
	for example_variant in examples:
		if not (example_variant is Dictionary):
			return false
		var source: Dictionary = (example_variant as Dictionary).get("source", {})
		if str(source.get("rules_version", "")) != "test-rules-sha":
			tests._fail("training example is missing immutable rules provenance")
			return false
		if int(source.get("self_play_suite_version", 0)) != PureStateSelfPlaySuite.SUITE_VERSION:
			tests._fail("training example is missing self-play suite version")
			return false
	tests._log("  winner=%s turns=%d examples=%d" % [
		str(result.get("winner", "")),
		int(result.get("turns_played", 0)),
		examples.size(),
	])
	tests._pass("terminal smoke self-play emits labels carrying rules/suite provenance")
	return true


static func _cell_in_hex(cell: Vector2i, radius: int) -> bool:
	var s := -cell.x - cell.y
	return max(abs(cell.x), max(abs(cell.y), abs(s))) <= radius
