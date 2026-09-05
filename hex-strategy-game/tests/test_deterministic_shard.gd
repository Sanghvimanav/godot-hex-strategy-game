extends RefCounted

const DeterministicShard = preload("res://tools/deterministic_shard.gd")


static func run_all(tests: Node) -> bool:
	var ok := true
	ok = _test_hash_is_stable(tests) and ok
	ok = _test_four_shards_partition_without_overlap(tests) and ok
	ok = _test_grouped_round_robin_balances_complete_pairs(tests) and ok
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


static func _test_grouped_round_robin_balances_complete_pairs(tests: Node) -> bool:
	tests._log("test_deterministic_shard: grouped round-robin keeps pairs complete and balanced")
	var jobs: Array = []
	for pair_index in range(32):
		var pair_id := "pair-%02d" % pair_index
		jobs.append({"pair_id": pair_id, "game_id": pair_id + "-a"})
		jobs.append({"pair_id": pair_id, "game_id": pair_id + "-b"})

	var seen_games: Dictionary = {}
	for shard_index in range(8):
		var shard := DeterministicShard.filter_grouped_jobs_round_robin(jobs, "pair_id", shard_index, 8)
		if shard.size() != 8:
			tests._fail("32 mirrored pairs across 8 shards should yield exactly 8 games per shard, got %d on shard %d" % [shard.size(), shard_index])
			return false
		var pair_counts: Dictionary = {}
		for job_variant in shard:
			var job: Dictionary = job_variant
			var game_id := str(job.get("game_id", ""))
			var pair_id := str(job.get("pair_id", ""))
			if seen_games.has(game_id):
				tests._fail("round-robin grouped job appeared in more than one shard: %s" % game_id)
				return false
			seen_games[game_id] = shard_index
			pair_counts[pair_id] = int(pair_counts.get(pair_id, 0)) + 1
		for pair_id_variant in pair_counts.keys():
			if int(pair_counts[pair_id_variant]) != 2:
				tests._fail("mirrored pair was split or incomplete on shard %d: %s" % [shard_index, pair_counts])
				return false

	if seen_games.size() != jobs.size():
		tests._fail("grouped round-robin should cover all %d games exactly once, got %d" % [jobs.size(), seen_games.size()])
		return false
	tests._pass("stable ordered pairs are evenly distributed without splitting mirrors")
	return true
