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
