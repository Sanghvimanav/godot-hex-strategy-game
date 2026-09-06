extends RefCounted

const PureStateSelfPlaySuite = preload("res://src/simulation/pure_state_self_play_suite.gd")
const PureStateSelfPlayDiversity = preload("res://src/simulation/pure_state_self_play_diversity.gd")
const PureStatePolicyExploration = preload("res://src/simulation/pure_state_policy_exploration.gd")
const PureStateArenaSuite = preload("res://src/simulation/pure_state_arena_suite.gd")


static func run_all(tests: Node) -> bool:
	var ok := true
	ok = _test_diverse_expansion_is_deterministic_and_training_only(tests) and ok
	ok = _test_procedural_jobs_cover_each_family_twice(tests) and ok
	ok = _test_policy_replays_reuse_fast_states_with_seeded_profiles(tests) and ok
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
	if base.size() != 26 or first.size() != 58:
		tests._fail("diverse training set should expand 26 curated jobs to 58 total, got %d -> %d" % [base.size(), first.size()])
		return false

	var arena_seeds: Dictionary = {}
	for seed_variant in PureStateArenaSuite.FULL_SEEDS:
		arena_seeds[int(seed_variant)] = true
	var ids: Dictionary = {}
	var training_variant_count := 0
	var policy_replay_count := 0
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
		training_variant_count += 1
		var seed := int(job.get("variation_seed", 0))
		if seed < PureStateSelfPlayDiversity.TRAINING_SEED_MIN:
			tests._fail("procedural seed must use the dedicated training namespace: %d" % seed)
			return false
		if arena_seeds.has(seed):
			tests._fail("training-only seed leaked into frozen arena evaluation set: %d" % seed)
			return false
		if str(job.get("budget_profile", "")) == "broad":
			tests._fail("training diversity should spend compute on coverage, not 8x8 search")
			return false
		if int(job.get("diversity_version", 0)) != PureStateSelfPlayDiversity.VERSION:
			tests._fail("training job is missing diversity version provenance")
			return false
		if not _state_is_valid(job.get("state", {}) as Dictionary):
			tests._fail("training job produced an invalid starting state: %s" % game_id)
			return false
		if bool(job.get("policy_replay", false)):
			policy_replay_count += 1
			var policy: Dictionary = job.get("policy_exploration", {})
			var policy_seed := int(policy.get("seed", 0))
			if policy_seed < PureStateSelfPlayDiversity.POLICY_SEED_MIN:
				tests._fail("policy replay must use its dedicated deterministic seed namespace")
				return false
			if arena_seeds.has(policy_seed):
				tests._fail("policy exploration seed leaked into frozen arena evaluation set: %d" % policy_seed)
				return false
	if training_variant_count != PureStateSelfPlayDiversity.TOTAL_TRAINING_VARIANT_COUNT:
		tests._fail("expected %d training variants, got %d" % [PureStateSelfPlayDiversity.TOTAL_TRAINING_VARIANT_COUNT, training_variant_count])
		return false
	if policy_replay_count != PureStateSelfPlayDiversity.POLICY_REPLAY_COUNT:
		tests._fail("expected %d policy replays, got %d" % [PureStateSelfPlayDiversity.POLICY_REPLAY_COUNT, policy_replay_count])
		return false
	tests._pass("diverse training expands to 58 unique jobs without evaluation-seed leakage")
	return true


static func _test_procedural_jobs_cover_each_family_twice(tests: Node) -> bool:
	tests._log("test_pure_state_self_play_diversity: two geometry variants per strategic family")
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
		var policy: Dictionary = job.get("policy_exploration", {})
		if str(policy.get("profile", "")) != PureStatePolicyExploration.PROFILE_GREEDY:
			tests._fail("geometry variants should remain greedy baselines")
			return false
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
	tests._pass("eight families each receive one fast and one balanced geometry variant")
	return true


static func _test_policy_replays_reuse_fast_states_with_seeded_profiles(tests: Node) -> bool:
	tests._log("test_pure_state_self_play_diversity: policy replays isolate trajectory variation")
	var procedural := PureStateSelfPlayDiversity.procedural_jobs()
	var fast_by_family: Dictionary = {}
	for job_variant in procedural:
		var job: Dictionary = job_variant
		if str(job.get("budget_profile", "")) == "fast":
			fast_by_family[str(job.get("scenario_id", ""))] = job

	var replays := PureStateSelfPlayDiversity.policy_replay_jobs()
	if replays.size() != PureStateSelfPlayDiversity.POLICY_REPLAY_COUNT:
		tests._fail("expected %d policy replays, got %d" % [PureStateSelfPlayDiversity.POLICY_REPLAY_COUNT, replays.size()])
		return false
	var family_counts: Dictionary = {}
	var profile_counts := {
		PureStatePolicyExploration.PROFILE_LIGHT: 0,
		PureStatePolicyExploration.PROFILE_EXPLORE: 0,
	}
	var seen_policy_seeds: Dictionary = {}
	for replay_variant in replays:
		var replay: Dictionary = replay_variant
		var family := str(replay.get("scenario_id", ""))
		family_counts[family] = int(family_counts.get(family, 0)) + 1
		if str(replay.get("budget_profile", "")) != "fast":
			tests._fail("policy replays should stay on the cheap 2x2 fast search budget")
			return false
		if not fast_by_family.has(family):
			tests._fail("policy replay has no matching fast procedural baseline: %s" % family)
			return false
		var baseline: Dictionary = fast_by_family[family]
		if replay.get("state", {}) != baseline.get("state", {}):
			tests._fail("policy replay must reuse the exact same starting state as its fast baseline: %s" % family)
			return false
		if int(replay.get("variation_seed", 0)) != int(baseline.get("variation_seed", -1)):
			tests._fail("policy replay must preserve the baseline variation seed")
			return false
		var policy: Dictionary = replay.get("policy_exploration", {})
		var profile := str(policy.get("profile", ""))
		if not profile_counts.has(profile):
			tests._fail("unexpected policy replay profile: %s" % profile)
			return false
		profile_counts[profile] = int(profile_counts[profile]) + 1
		var seed := int(policy.get("seed", 0))
		if seed < PureStateSelfPlayDiversity.POLICY_SEED_MIN or seen_policy_seeds.has(seed):
			tests._fail("policy replay seeds must be unique and use the dedicated namespace: %d" % seed)
			return false
		seen_policy_seeds[seed] = true
	for config_variant in PureStateSelfPlayDiversity.FAMILY_CONFIGS:
		var family := str((config_variant as Dictionary).get("scenario_id", ""))
		if int(family_counts.get(family, 0)) != 2:
			tests._fail("family %s should receive one light and one explore replay" % family)
			return false
	if int(profile_counts[PureStatePolicyExploration.PROFILE_LIGHT]) != 8 or int(profile_counts[PureStatePolicyExploration.PROFILE_EXPLORE]) != 8:
		tests._fail("policy replays should split evenly between light/explore: %s" % profile_counts)
		return false
	tests._pass("policy diversity replays identical fast states with deterministic light/explore policies")
	return true


static func _test_non_diverse_presets_are_unchanged(tests: Node) -> bool:
	tests._log("test_pure_state_self_play_diversity: smoke/starter remain historical baselines")
	for preset in ["smoke", "starter"]:
		var base := PureStateSelfPlaySuite.get_preset(preset)
		var expanded := PureStateSelfPlayDiversity.expand_jobs(base, preset)
		if expanded != base:
			tests._fail("%s preset should not receive procedural training variants" % preset)
			return false
	tests._pass("training expansion is isolated to the diverse preset")
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
