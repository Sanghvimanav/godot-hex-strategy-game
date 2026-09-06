extends RefCounted
class_name PureStatePolicyExploration
## Deterministic, training-oriented exploration over already-ranked search results.
##
## Search remains unchanged and deterministic. Exploration can only replace the
## best result with a near-best alternative from the ranked search output. A
## stable hash of the training seed + current state + group makes every sampled
## choice exactly reproducible without touching Godot's global RNG.

const PROFILE_GREEDY := "greedy"
const PROFILE_LIGHT := "light"
const PROFILE_EXPLORE := "explore"

const PROFILES := {
	PROFILE_GREEDY: {
		"exploration_rate": 0.0,
		"max_candidates": 1,
		"score_margin": 0.0,
		"temperature": 1.0,
	},
	PROFILE_LIGHT: {
		"exploration_rate": 0.25,
		"max_candidates": 3,
		"score_margin": 80.0,
		"temperature": 35.0,
	},
	PROFILE_EXPLORE: {
		"exploration_rate": 0.45,
		"max_candidates": 3,
		"score_margin": 120.0,
		"temperature": 50.0,
	},
}


static func is_supported_profile(profile_name: String) -> bool:
	return PROFILES.has(profile_name)


static func select_result(
	search_result: Dictionary,
	game_state: Dictionary,
	group_name: String,
	profile_name: String,
	exploration_seed: int
) -> Dictionary:
	var ranked: Array = search_result.get("ranked_results", [])
	if ranked.is_empty() or not (ranked[0] is Dictionary):
		return {}
	var best: Dictionary = ranked[0]
	var selection := _selection_payload(best, 0, false, profile_name, exploration_seed, 1)
	if profile_name == PROFILE_GREEDY:
		return selection
	if not is_supported_profile(profile_name):
		return {}

	var profile: Dictionary = PROFILES[profile_name]
	var eligible := _eligible_results(ranked, profile)
	selection["eligible_count"] = eligible.size()
	if eligible.size() <= 1:
		return selection

	var fingerprint := _state_fingerprint(game_state, group_name)
	var gate := _stable_unit_float("%d|%s|gate" % [exploration_seed, fingerprint])
	if gate >= float(profile.get("exploration_rate", 0.0)):
		return selection

	# When the exploration gate fires, choose only among non-best near-best plans.
	# Excluding the best here makes the configured exploration rate interpretable:
	# it is approximately the probability that training actually tries an alternate
	# competent plan rather than silently sampling the top plan again.
	var alternatives := eligible.slice(1)
	var picked_index := _weighted_alternative_index(
		alternatives,
		float(best.get("worst_case_score", 0.0)),
		float(profile.get("temperature", 1.0)),
		_stable_unit_float("%d|%s|pick" % [exploration_seed, fingerprint])
	)
	if picked_index < 0 or picked_index >= alternatives.size():
		return selection
	var picked: Dictionary = alternatives[picked_index]
	var ranked_index := int(picked.get("_exploration_rank", picked_index + 1))
	return _selection_payload(picked, ranked_index, true, profile_name, exploration_seed, eligible.size())


static func _eligible_results(ranked: Array, profile: Dictionary) -> Array:
	var result: Array = []
	if ranked.is_empty() or not (ranked[0] is Dictionary):
		return result
	var best_score := float((ranked[0] as Dictionary).get("worst_case_score", 0.0))
	var score_margin := maxf(0.0, float(profile.get("score_margin", 0.0)))
	var max_candidates := maxi(1, int(profile.get("max_candidates", 1)))
	for index in range(mini(ranked.size(), max_candidates)):
		if not (ranked[index] is Dictionary):
			continue
		var candidate: Dictionary = (ranked[index] as Dictionary).duplicate(true)
		var gap := best_score - float(candidate.get("worst_case_score", 0.0))
		if gap > score_margin and not is_equal_approx(gap, score_margin):
			continue
		candidate["_exploration_rank"] = index
		result.append(candidate)
	return result


static func _weighted_alternative_index(
	alternatives: Array,
	best_score: float,
	temperature: float,
	roll: float
) -> int:
	if alternatives.is_empty():
		return -1
	var safe_temperature := maxf(1.0, temperature)
	var weights: Array[float] = []
	var total := 0.0
	for candidate_variant in alternatives:
		if not (candidate_variant is Dictionary):
			weights.append(0.0)
			continue
		var candidate: Dictionary = candidate_variant
		var gap := maxf(0.0, best_score - float(candidate.get("worst_case_score", 0.0)))
		var weight := exp(-gap / safe_temperature)
		weights.append(weight)
		total += weight
	if total <= 0.0:
		return 0
	var target := clampf(roll, 0.0, 0.999999) * total
	var running := 0.0
	for index in range(weights.size()):
		running += weights[index]
		if target < running:
			return index
	return weights.size() - 1


static func _selection_payload(
	candidate: Dictionary,
	rank: int,
	explored: bool,
	profile_name: String,
	exploration_seed: int,
	eligible_count: int
) -> Dictionary:
	return {
		"actions": (candidate.get("actions", []) as Array).duplicate(true),
		"selected_rank": rank,
		"explored": explored,
		"profile": profile_name,
		"seed": exploration_seed,
		"eligible_count": eligible_count,
		"selected_worst_case_score": float(candidate.get("worst_case_score", 0.0)),
		"selected_average_score": float(candidate.get("average_score", 0.0)),
		"selected_proposal_score": float(candidate.get("proposal_score", 0.0)),
		"selected_intent": str(candidate.get("intent", "")),
	}


static func _state_fingerprint(game_state: Dictionary, group_name: String) -> String:
	var parts: PackedStringArray = [
		group_name,
		str(game_state.get("scenario_id", "")),
		str(int(game_state.get("hex_radius", 0))),
	]
	var groups: Array = []
	for group_variant in game_state.get("groups", []):
		if group_variant is Dictionary:
			groups.append((group_variant as Dictionary).duplicate(true))
	groups.sort_custom(func(a, b): return str(a.get("name", "")) < str(b.get("name", "")))
	for group_variant in groups:
		var group: Dictionary = group_variant
		parts.append("g=" + str(group.get("name", "")))
		var resource_keys: Array = []
		var resources: Dictionary = group.get("resources", {}) if group.get("resources", {}) is Dictionary else {}
		resource_keys.assign(resources.keys())
		resource_keys.sort_custom(func(a, b): return str(a) < str(b))
		for key_variant in resource_keys:
			parts.append("r=%s:%s" % [str(key_variant), str(resources.get(key_variant, 0))])
		var units: Array = []
		for unit_variant in group.get("units", []):
			if unit_variant is Dictionary:
				units.append((unit_variant as Dictionary).duplicate(true))
		units.sort_custom(func(a, b): return int(a.get("unit_id", -1)) < int(b.get("unit_id", -1)))
		for unit_variant in units:
			var unit: Dictionary = unit_variant
			parts.append("u=%d|%s|%s|%d|%d|%s" % [
				int(unit.get("unit_id", -1)),
				str(unit.get("def_path", "")),
				str(unit.get("cell", [])),
				int(unit.get("health", 0)),
				int(unit.get("energy", 0)),
				str(unit.get("effects", [])),
			])
	var command_hexes: Dictionary = game_state.get("command_hexes", {}) if game_state.get("command_hexes", {}) is Dictionary else {}
	var command_keys: Array = []
	command_keys.assign(command_hexes.keys())
	command_keys.sort_custom(func(a, b): return str(a) < str(b))
	for key_variant in command_keys:
		parts.append("c=%s:%s" % [str(key_variant), str(command_hexes.get(key_variant, []))])
	return ";".join(parts)


static func _stable_unit_float(text: String) -> float:
	var value := 2166136261
	for byte in text.to_utf8_buffer():
		value = int((value ^ int(byte)) * 16777619) & 0xffffffff
	return float(value % 1000000) / 1000000.0
