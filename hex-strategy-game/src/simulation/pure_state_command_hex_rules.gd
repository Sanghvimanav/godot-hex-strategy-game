extends RefCounted
class_name PureStateCommandHexRules
## Shared pure-state rules for opposite-side command hex objectives.
##
## Each side owns the center hex on its starting back edge. A capture completes
## only when the same living enemy unit occupies the command hex at both the
## beginning and end of a complete resolved turn.

const DEFAULT_HEX_RADIUS := 5
const OBJECTIVE_DISTANCE_WEIGHT := 12.0
const OBJECTIVE_OCCUPANCY_WEIGHT := 1000.0


static func ensure_command_hexes(game_state: Dictionary, group_a: String, group_b: String) -> Dictionary:
	var existing_variant = game_state.get("command_hexes", {})
	if existing_variant is Dictionary:
		var existing: Dictionary = existing_variant
		if existing.has(group_a) and existing.has(group_b):
			var normalized: Dictionary = {}
			normalized[group_a] = _cell_array(existing.get(group_a, [0, 0]))
			normalized[group_b] = _cell_array(existing.get(group_b, [0, 0]))
			game_state["command_hexes"] = normalized.duplicate(true)
			return normalized

	var radius := maxi(1, int(game_state.get("hex_radius", DEFAULT_HEX_RADIUS)))
	var average_q_a := _average_living_q(game_state, group_a)
	var average_q_b := _average_living_q(game_state, group_b)
	# The side that starts farther right owns the +q back edge. Ties are resolved
	# deterministically in favor of group_a so fixtures with centered deployments
	# still receive opposite objectives.
	var a_owns_positive_edge := average_q_a >= average_q_b
	var command_hexes: Dictionary = {}
	command_hexes[group_a] = [radius, 0] if a_owns_positive_edge else [-radius, 0]
	command_hexes[group_b] = [-radius, 0] if a_owns_positive_edge else [radius, 0]
	game_state["command_hexes"] = command_hexes.duplicate(true)
	return command_hexes


static func occupants_on_enemy_command(
	game_state: Dictionary,
	attacker_group: String,
	defender_group: String,
	command_hexes: Dictionary
) -> Array:
	if not command_hexes.has(defender_group):
		return []
	var target := _cell_from_variant(command_hexes.get(defender_group, [0, 0]))
	var occupants: Array = []
	for group_variant in game_state.get("groups", []):
		if not (group_variant is Dictionary):
			continue
		var group: Dictionary = group_variant
		if str(group.get("name", "")) != attacker_group:
			continue
		for unit_variant in group.get("units", []):
			if not (unit_variant is Dictionary):
				continue
			var unit: Dictionary = unit_variant
			if int(unit.get("health", 0)) <= 0:
				continue
			if _cell_from_variant(unit.get("cell", [0, 0])) == target:
				occupants.append(int(unit.get("unit_id", -1)))
	occupants.sort()
	return occupants


## Capture is checked only at complete-turn boundaries. The same unit id must be
## present before and after the resolved turn; swapping units on the objective
## does not satisfy the one-complete-turn hold requirement.
static func capture_after_complete_turn(
	game_state: Dictionary,
	group_a: String,
	group_b: String,
	command_hexes: Dictionary,
	previous_occupants: Dictionary
) -> Dictionary:
	var current_a := occupants_on_enemy_command(game_state, group_a, group_b, command_hexes)
	var current_b := occupants_on_enemy_command(game_state, group_b, group_a, command_hexes)
	var previous_a: Array = previous_occupants.get(group_a, [])
	var previous_b: Array = previous_occupants.get(group_b, [])
	var completed: Dictionary = {}
	completed[group_a] = _shares_unit(previous_a, current_a)
	completed[group_b] = _shares_unit(previous_b, current_b)
	var current: Dictionary = {}
	current[group_a] = current_a.duplicate()
	current[group_b] = current_b.duplicate()
	return {
		"completed": completed,
		"occupants": current,
	}


static func initial_occupants(
	game_state: Dictionary,
	group_a: String,
	group_b: String,
	command_hexes: Dictionary
) -> Dictionary:
	var result: Dictionary = {}
	result[group_a] = occupants_on_enemy_command(game_state, group_a, group_b, command_hexes)
	result[group_b] = occupants_on_enemy_command(game_state, group_b, group_a, command_hexes)
	return result


## Positional value used by the one-turn evaluator so a runner cannot make
## endless kiting optimal. Moving toward the enemy command hex improves value;
## allowing an enemy toward our own objective hurts it. Actual capture remains a
## rollout terminal rule rather than an evaluator shortcut.
static func objective_score(game_state: Dictionary, group_name: String) -> float:
	var command_variant = game_state.get("command_hexes", {})
	if not (command_variant is Dictionary):
		return 0.0
	var command_hexes: Dictionary = command_variant
	if not command_hexes.has(group_name):
		return 0.0

	var opponent_group := ""
	for owner_variant in command_hexes.keys():
		var owner := str(owner_variant)
		if owner != group_name:
			opponent_group = owner
			break
	if opponent_group.is_empty() or not command_hexes.has(opponent_group):
		return 0.0

	var own_command := _cell_from_variant(command_hexes.get(group_name, [0, 0]))
	var enemy_command := _cell_from_variant(command_hexes.get(opponent_group, [0, 0]))
	var own_distance := _nearest_living_distance(game_state, group_name, enemy_command)
	var enemy_distance := _nearest_living_distance(game_state, opponent_group, own_command)
	var score := 0.0
	if own_distance >= 0 and enemy_distance >= 0:
		score += float(enemy_distance - own_distance) * OBJECTIVE_DISTANCE_WEIGHT
	if own_distance == 0:
		score += OBJECTIVE_OCCUPANCY_WEIGHT
	if enemy_distance == 0:
		score -= OBJECTIVE_OCCUPANCY_WEIGHT
	return score


static func _shares_unit(before: Array, after: Array) -> bool:
	for unit_id_variant in before:
		if unit_id_variant in after:
			return true
	return false


static func _average_living_q(game_state: Dictionary, group_name: String) -> float:
	var total := 0.0
	var count := 0
	for group_variant in game_state.get("groups", []):
		if not (group_variant is Dictionary):
			continue
		var group: Dictionary = group_variant
		if str(group.get("name", "")) != group_name:
			continue
		for unit_variant in group.get("units", []):
			if not (unit_variant is Dictionary):
				continue
			var unit: Dictionary = unit_variant
			if int(unit.get("health", 0)) <= 0:
				continue
			total += float(_cell_from_variant(unit.get("cell", [0, 0])).x)
			count += 1
		break
	return total / float(count) if count > 0 else 0.0


static func _nearest_living_distance(game_state: Dictionary, group_name: String, target: Vector2i) -> int:
	var best := -1
	for group_variant in game_state.get("groups", []):
		if not (group_variant is Dictionary):
			continue
		var group: Dictionary = group_variant
		if str(group.get("name", "")) != group_name:
			continue
		for unit_variant in group.get("units", []):
			if not (unit_variant is Dictionary):
				continue
			var unit: Dictionary = unit_variant
			if int(unit.get("health", 0)) <= 0:
				continue
			var cell := _cell_from_variant(unit.get("cell", [0, 0]))
			var distance := HexGrid.hex_distance(cell.x, cell.y, target.x, target.y)
			if best < 0 or distance < best:
				best = distance
		break
	return best


static func _cell_array(value: Variant) -> Array:
	var cell := _cell_from_variant(value)
	return [cell.x, cell.y]


static func _cell_from_variant(value: Variant) -> Vector2i:
	if value is Vector2i:
		return value
	if value is Vector2:
		return Vector2i(int(value.x), int(value.y))
	if value is Array and value.size() >= 2:
		return Vector2i(int(value[0]), int(value[1]))
	return Vector2i.ZERO
