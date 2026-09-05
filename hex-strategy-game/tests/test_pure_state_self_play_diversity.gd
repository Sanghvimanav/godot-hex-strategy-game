extends RefCounted

const PureStateSelfPlaySuite = preload("res://src/simulation/pure_state_self_play_suite.gd")
const PureStateSelfPlayDiversity = preload("res://src/simulation/pure_state_self_play_diversity.gd")
const PureStateArenaSuite = preload("res://src/simulation/pure_state_arena_suite.gd")


static func run_all(tests: Node) -> bool:
	var ok := true
	ok = _test_diverse_expansion_is_deterministic_and_training_only(tests) and ok
	ok = _test_procedural_jobs_cover_each_family_twice(tests) and ok
	ok = _test_non_diverse_presets_are_unchanged(tests) and ok
	return ok


static func _test_diverse_expansion_is_deterministic_and_training_only(tests: Node) -> bool:
	tests._log("test_pure_state_self_play_diversity: deterministic training-only expansion")
	var base := PureStateSelfPlaySuite.get_preset("diverse")
	var first := PureStateSelfPlayDiversity.expand_jobs(base, "diverse")
	var again := PureStateSelfPlayDiversity.expand_jobs(base, "diverse")
	if first != again:
		tests._fail("same diversity version must produce identical expanded jobs")
		return false
	if base.size() != 26 or first.size() != 42:
		tests._fail("diverse training set should expand 26 curated jobs to 42 total, got %d -> %d" % [base.size(), first.size()])
		return false

	var arena_seeds: Dictionary = {}
	for seed_variant in PureStateArenaSuite.FULL_SEEDS:
		arena_seeds[int(seed_variant)] = true
	var ids: Dictionary = {}
	var procedural_count := 0
	for job_variant in first:
		if not (job_variant is Dictionary):
			tests._fail("every expanded self-play job must be a Dictionary")
			return false
		var job: Dictionary = job_variant
		var game_id := str(job.get("game_id", ""))
		if game_id.is_empty() or ids.has(game_id):
			tests._fail("expanded self-play ids must be non-empty and unique: %s" % game_id)
			return false
		ids[game_id] = true
		if not bool(job.get("training_variant", false)):
			continue
		procedural_count += 1
		var seed := int(job.get("variation_seed", 0))
		if seed < PureStateSelfPlayDiversity.TRAINING_SEED_MIN:
			tests._fail("procedural seed must use the dedicated training namespace: %d" % seed)
			return false
		if arena_seeds.has(seed):
			tests._fail("training-only seed leaked into frozen arena evaluation set: %d" % seed)
			return false
		if str(job.get("budget_profile", "")) == "broad":
			tests._fail("procedural diversity should spend compute on coverage, not 8x8 search")
			return false
		if int(job.get("diversity_version", 0)) != PureStateSelfPlayDiversity.VERSION:
			tests._fail("procedural job is missing diversity version provenance")
			return false
		if not _state_is_valid(job.get("state", {}) as Dictionary):
			tests._fail("procedural job produced an invalid starting state: %s" % game_id)
			return false
	if procedural_count != PureStateSelfPlayDiversity.PROCEDURAL_VARIANT_COUNT:
		tests._fail("expected %d procedural jobs, got %d" % [PureStateSelfPlayDiversity.PROCEDURAL_VARIANT_COUNT, procedural_count])
		return false
	tests._pass("diverse training expands to 42 unique jobs without arena-seed leakage")
	return true


static func _test_procedural_jobs_cover_each_family_twice(tests: Node) -> bool:
	tests._log("test_pure_state_self_play_diversity: two variants per strategic family")
	var jobs := PureStateSelfPlayDiversity.procedural_jobs()
	var family_counts: Dictionary = {}
	var profile_counts := {"fast": 0, "balanced": 0}
	for job_variant in jobs:
		var job: Dictionary = job_variant
		var family := str(job.get("scenario_id", ""))
		family_counts[family] = int(family_counts.get(family, 0)) + 1
		var profile := str(job.get("budget_profile", ""))
		if profile_counts.has(profile):
			profile_counts[profile] = int(profile_counts[profile]) + 1
	for config_variant in PureStateSelfPlayDiversity.FAMILY_CONFIGS:
		var config: Dictionary = config_variant
		var family := str(config.get("scenario_id", ""))
		if int(family_counts.get(family, 0)) != 2:
			tests._fail("family %s should receive exactly two procedural variants, got %d" % [family, int(family_counts.get(family, 0))])
			return false
	if family_counts.size() != 8:
		tests._fail("procedural diversity should cover exactly eight strategic families, got %d" % family_counts.size())
		return false
	if int(profile_counts["fast"]) != 8 or int(profile_counts["balanced"]) != 8:
		tests._fail("procedural jobs should split evenly between fast and balanced search: %s" % profile_counts)
		return false
	tests._pass("eight families each receive one fast and one balanced training variant")
	return true


static func _test_non_diverse_presets_are_unchanged(tests: Node) -> bool:
	tests._log("test_pure_state_self_play_diversity: smoke/starter remain historical baselines")
	for preset in ["smoke", "starter"]:
		var base := PureStateSelfPlaySuite.get_preset(preset)
		var expanded := PureStateSelfPlayDiversity.expand_jobs(base, preset)
		if expanded != base:
			tests._fail("%s preset should not receive procedural training variants" % preset)
			return false
	tests._pass("procedural expansion is isolated to the diverse training preset")
	return true


static func _state_is_valid(state: Dictionary) -> bool:
	var radius := int(state.get("hex_radius", 0))
	if radius <= 0:
		return false
	var seen_cells: Dictionary = {}
	for group_variant in state.get("groups", []):
		if not (group_variant is Dictionary):
			return false
		for unit_variant in (group_variant as Dictionary).get("units", []):
			if not (unit_variant is Dictionary):
				return false
			var unit: Dictionary = unit_variant
			if int(unit.get("health", 0)) <= 0:
				return false
			var cell_variant = unit.get("cell", [])
			if not (cell_variant is Array) or (cell_variant as Array).size() < 2:
				return false
			var cell := Vector2i(int(cell_variant[0]), int(cell_variant[1]))
			if not _cell_in_hex(cell, radius):
				return false
			# Stacking is valid in several authored fixtures, so do not reject it.
			seen_cells[str(cell)] = true
	return true


static func _cell_in_hex(cell: Vector2i, radius: int) -> bool:
	var s := -cell.x - cell.y
	return max(abs(cell.x), max(abs(cell.y), abs(s))) <= radius
