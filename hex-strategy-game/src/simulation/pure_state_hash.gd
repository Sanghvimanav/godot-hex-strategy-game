extends RefCounted
class_name PureStateHash
## Deterministic canonical serialization and SHA-256 hashing for data-only game state.
##
## Dictionary insertion order must not affect the hash. This is intentionally kept
## separate from gameplay rules so replay verification, neural caches, and future
## transposition-style reuse can share one stable state identity contract.


static func hash_state(game_state: Dictionary) -> String:
	return hash_value(game_state)


static func hash_value(value: Variant) -> String:
	return canonical_string(value).sha256_text()


static func canonical_string(value: Variant) -> String:
	match typeof(value):
		TYPE_NIL:
			return "n"
		TYPE_BOOL:
			return "b:1" if bool(value) else "b:0"
		TYPE_INT:
			return "i:%d" % int(value)
		TYPE_FLOAT:
			return "f:%s" % JSON.stringify(float(value))
		TYPE_STRING, TYPE_STRING_NAME:
			return "s:%s" % JSON.stringify(str(value))
		TYPE_VECTOR2:
			var vector: Vector2 = value
			return "v2:%s,%s" % [JSON.stringify(vector.x), JSON.stringify(vector.y)]
		TYPE_VECTOR2I:
			var vector_i: Vector2i = value
			return "v2i:%d,%d" % [vector_i.x, vector_i.y]
		TYPE_ARRAY:
			return _canonical_sequence(value, "a")
		TYPE_PACKED_BYTE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_STRING_ARRAY, TYPE_PACKED_VECTOR2_ARRAY, TYPE_PACKED_VECTOR3_ARRAY, TYPE_PACKED_COLOR_ARRAY:
			return _canonical_sequence(value, "p")
		TYPE_DICTIONARY:
			return _canonical_dictionary(value)
		_:
			# Canonical state is expected to remain data-only. Keep unsupported values
			# deterministic enough for diagnostics while making their type explicit.
			return "u:%d:%s" % [typeof(value), var_to_str(value)]


static func _canonical_sequence(sequence: Variant, prefix: String) -> String:
	var parts := PackedStringArray()
	for item in sequence:
		parts.append(canonical_string(item))
	return "%s[%s]" % [prefix, ",".join(parts)]


static func _canonical_dictionary(dictionary: Dictionary) -> String:
	var entries := PackedStringArray()
	for key in dictionary.keys():
		var canonical_key := canonical_string(key)
		var canonical_value := canonical_string(dictionary[key])
		entries.append("%s=%s" % [canonical_key, canonical_value])
	entries.sort()
	return "d{%s}" % ",".join(entries)
