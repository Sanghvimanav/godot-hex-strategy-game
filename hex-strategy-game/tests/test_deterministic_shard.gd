extends RefCounted

const DeterministicShard = preload("res://tools/deterministic_shard.gd")


static func run_all(tests: Node) -> bool:
	var ok := true
	ok = _test_hash_is_stable(tests) and ok
	ok = _test_four_shards_partition_without_overlap(tests) and ok
	return ok


static func _test_hash_is_stable(tests: Node) -> bool:
	tests._log("test_deterministic_shard: stable FNV-1a assignments")
	if DeterministicShard.stable_hash("game-0") != 1529306474:
		tests._fail("game-0 stable hash changed")
		return false
	if DeterministicShard.shard_for_key("game-0", 4) != 2:
		tests._fail("game-0 should deterministically map to shard 2 of 4")
		return false
	if DeterministicShard.shard_for_key("decision-0", 4) != 2:
		tests._fail("decision-0 should deterministically map to shard 2 of 4")
		return false
	tests._pass("stable hash and four-way assignments are reproducible")
	return true


static func _test_four_shards_partition_without_overlap(tests: Node) -> bool:
	tests._log("test_deterministic_shard: four shards cover the source exactly once")
	var jobs: Array = []
	for i in range(20):
		jobs.append({"game_id": "game-%d" % i, "ordinal": i})

	var seen: Dictionary = {}
	for shard_index in range(4):
		var shard := DeterministicShard.filter_jobs(jobs, "game_id", shard_index, 4)
		if shard.is_empty():
			tests._fail("expected every shard to receive at least one fixture job")
			return false
		for job_variant in shard:
			var job: Dictionary = job_variant
			var game_id := str(job.get("game_id", ""))
			if seen.has(game_id):
				tests._fail("job appeared in more than one shard: %s" % game_id)
				return false
			seen[game_id] = shard_index

	if seen.size() != jobs.size():
		tests._fail("four shards should cover all %d jobs exactly once, got %d" % [jobs.size(), seen.size()])
		return false
	tests._pass("four-way partition is complete and disjoint")
	return true
