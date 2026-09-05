extends RefCounted
## Stable sharding helpers shared by expensive offline generators.
##
## Uses 32-bit FNV-1a over UTF-8 bytes so assignments do not depend on
## Godot's process/runtime hash implementation.


static func stable_hash(key: String) -> int:
	var value: int = 2166136261
	for byte in key.to_utf8_buffer():
		value = value ^ int(byte)
		value = (value * 16777619) & 0xffffffff
	return value


static func shard_for_key(key: String, shard_count: int) -> int:
	if shard_count <= 0:
		return -1
	return stable_hash(key) % shard_count


static func filter_jobs(jobs: Array, key_field: String, shard_index: int, shard_count: int) -> Array:
	if shard_count <= 0 or shard_index < 0 or shard_index >= shard_count:
		return []
	if shard_count == 1:
		return jobs.duplicate(true)

	var filtered: Array = []
	for job_index in range(jobs.size()):
		var job_variant = jobs[job_index]
		var key := ""
		if job_variant is Dictionary:
			key = str((job_variant as Dictionary).get(key_field, ""))
		if key.is_empty():
			# Keep malformed jobs in exactly one shard so validation/failure accounting
			# cannot silently drop them from the union of all shards.
			key = "__missing_%s_%d" % [key_field, job_index]
		if shard_for_key(key, shard_count) == shard_index:
			filtered.append(job_variant.duplicate(true) if job_variant is Dictionary else job_variant)
	return filtered


## Deterministically balance complete key groups across shards in source order.
##
## Hash partitioning is ideal when jobs arrive independently, but a small frozen
## benchmark can accidentally hash very unevenly. The arena already has a stable
## ordered seed set, so round-robin assignment gives nearly equal group counts
## while keeping every mirrored pair together and preserving reproducibility.
static func filter_grouped_jobs_round_robin(
	jobs: Array,
	key_field: String,
	shard_index: int,
	shard_count: int
) -> Array:
	if shard_count <= 0 or shard_index < 0 or shard_index >= shard_count:
		return []
	if shard_count == 1:
		return jobs.duplicate(true)

	var group_order: Array[String] = []
	var grouped: Dictionary = {}
	for job_index in range(jobs.size()):
		var job_variant = jobs[job_index]
		var key := ""
		if job_variant is Dictionary:
			key = str((job_variant as Dictionary).get(key_field, ""))
		if key.is_empty():
			key = "__missing_%s_%d" % [key_field, job_index]
		if not grouped.has(key):
			group_order.append(key)
			grouped[key] = []
		var group_jobs: Array = grouped[key]
		group_jobs.append(job_variant.duplicate(true) if job_variant is Dictionary else job_variant)

	var filtered: Array = []
	for group_index in range(group_order.size()):
		if group_index % shard_count != shard_index:
			continue
		var key := group_order[group_index]
		for job_variant in grouped[key]:
			filtered.append(job_variant.duplicate(true) if job_variant is Dictionary else job_variant)
	return filtered
