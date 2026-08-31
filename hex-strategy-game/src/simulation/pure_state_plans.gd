extends RefCounted
class_name PureStatePlans
## Bounded joint-plan generation for pure-state search / neural AI.
##
## This module is intentionally a proposal generator, not a final evaluator.
## It cheaply ranks each unit's legal actions, keeps a small number per unit,
## and combines them into complete group plans with a bounded beam. The returned
## proposal_score is only useful for deciding which plans deserve simulation.

const PureStateLegalActions = preload("res://src/simulation/pure_state_legal_actions.gd")
const TurnExecutionCore = preload("res://src/battle/turn_execution_core.gd")

const REST_ACTION_KEYS := ["reload", "recharge", "rest_no_energy"]


## Returns up to max_plans candidate plans for one group.
## Each result is:
## {
##   "actions": Array[Dictionary],
##   "proposal_score": float,
## }
##
## Defaults intentionally stay small: top 3 legal actions per plannable unit,
## then at most 50 complete plans. Units with no executable planned actions
## (for example stunned/immobile units) do not block planning for the group.
static func get_candidate_plans(
	game_state: Dictionary,
	group_name: String,
	max_actions_per_unit: int = 3,
	max_plans: int = 50
) -> Array:
	if group_name.is_empty() or max_actions_per_unit <= 0 or max_plans <= 0:
		return []
	var group := _find_group(game_state, group_name)
	if group.is_empty():
		return []

	var units: Array = group.get("units", []).duplicate()
	units.sort_custom(func(a, b): return int(a.get("unit_id", -1)) < int(b.get("unit_id", -1)))

	var choices_by_unit: Array = []
	for unit_variant in units:
		if not (unit_variant is Dictionary):
			continue
		var unit: Dictionary = unit_variant
		if int(unit.get("health", 0)) <= 0:
			continue
		var unit_id := int(unit.get("unit_id", -1))
		var legal: Array = PureStateLegalActions.get_legal_actions(game_state, unit_id)
		if legal.is_empty():
			continue
		var ranked: Array = []
		for action_variant in legal:
			if not (action_variant is Dictionary):
				continue
			var action: Dictionary = action_variant
			ranked.append({
				"action": action.duplicate(true),
				"score": _score_action(game_state, group_name, unit, action),
			})
		ranked.sort_custom(_ranked_action_before)
		var kept: Array = []
		for i in range(mini(max_actions_per_unit, ranked.size())):
			kept.append(ranked[i])
		if not kept.is_empty():
			choices_by_unit.append(kept)

	if choices_by_unit.is_empty():
		return []

	var beam: Array = [{"actions": [], "proposal_score": 0.0}]
	for choices_variant in choices_by_unit:
		var choices: Array = choices_variant
		var expanded: Array = []
		for partial_variant in beam:
			var partial: Dictionary = partial_variant
			for choice_variant in choices:
				var choice: Dictionary = choice_variant
				var actions: Array = partial.get("actions", []).duplicate(true)
				actions.append((choice.get("action", {}) as Dictionary).duplicate(true))
				expanded.append({
					"actions": actions,
					"proposal_score": float(partial.get("proposal_score", 0.0)) + float(choice.get("score", 0.0)),
				})
		expanded.sort_custom(_plan_before)
		beam.clear()
		for i in range(mini(max_plans, expanded.size())):
			beam.append(expanded[i])

	return beam


static func _find_group(game_state: Dictionary, group_name: String) -> Dictionary:
	for group_variant in game_state.get("groups", []):
		if group_variant is Dictionary and str(group_variant.get("name", "")) == group_name:
			return group_variant
	return {}


## Lightweight proposal heuristic. This deliberately does not try to encode the
## full game's value function. In particular, self-damage / sacrifice is not
## penalized here; the simulator + later state evaluator should decide whether a
## sacrifice was actually good.
static func _score_action(game_state: Dictionary, group_name: String, unit: Dictionary, action: Dictionary) -> float:
	var action_key := str(action.get("action_key", ""))
	var config: Dictionary = Actions.get_action_config(action_key)
	if config.is_empty():
		return -1000.0
	var score := 0.0
	var action_type := str(config.get("type", ""))
	var cell: Array = unit.get("cell", [0, 0])
	if cell.size() < 2:
		return score
	var from_cell := Vector2i(int(cell[0]), int(cell[1]))
	var end_point = action.get("end_point", [from_cell.x, from_cell.y])
	var to_cell := _cell_from_variant(end_point, from_cell)

	var damage := int(config.get("damage", 0))
	if damage > 0:
		var damage_cells := _damage_cells_for_action(from_cell, action, config)
		var enemy_hits := _count_units_in_cells(game_state, group_name, damage_cells, true)
		score += float(enemy_hits * damage) * 4.0
		# Keep unoccupied attacks available as low-priority hypotheses. This matters
		# in simultaneous turns where an enemy may move into the targeted tile.
		if enemy_hits == 0:
			score += 0.15

	if action_type in TurnExecutionCore.MOVE_TYPES:
		var before := _nearest_enemy_distance(game_state, group_name, from_cell)
		var after := _nearest_enemy_distance(game_state, group_name, to_cell)
		if before >= 0 and after >= 0:
			score += float(before - after) * 0.75
		var enemies_on_destination := _count_units_in_cells(game_state, group_name, [to_cell], true)
		if enemies_on_destination > 0:
			# Useful for melee/passive-attack units such as Zerglings, while remaining
			# only a proposal bonus rather than a hard-coded combat value.
			score += 1.5 * float(enemies_on_destination)

	if int(config.get("tile_resource_depletion", 0)) > 0:
		# Legality already guarantees a matching resource exists on this tile.
		score += 2.0

	if action_type == "spawn":
		# Legality already guarantees the group can pay the cost.
		score += 2.0

	var heal_amount := int(config.get("heal_amount", 0))
	var recharge_amount := int(config.get("recharge", 0))
	if heal_amount > 0 or recharge_amount > 0:
		score += _support_utility(game_state, group_name, to_cell, heal_amount, recharge_amount)

	if action_key in REST_ACTION_KEYS:
		score += 0.05

	return score


static func _damage_cells_for_action(from_cell: Vector2i, action: Dictionary, config: Dictionary) -> Array:
	var cells: Array = TurnExecutionCore.get_damage_cells_for_config(
		from_cell.x,
		from_cell.y,
		action.get("path", []),
		action.get("end_point", [from_cell.x, from_cell.y]),
		config
	)
	var aoe = config.get("area_of_effect", {})
	if aoe is Dictionary and not aoe.is_empty():
		var target := _cell_from_variant(action.get("end_point", [from_cell.x, from_cell.y]), from_cell)
		for aoe_cell in HexGrid.get_aoe_tiles(Vector2(from_cell.x, from_cell.y), Vector2(target.x, target.y), aoe):
			if aoe_cell not in cells:
				cells.append(aoe_cell)
	return cells


static func _count_units_in_cells(game_state: Dictionary, group_name: String, cells: Array, enemies: bool) -> int:
	var keys: Dictionary = {}
	for raw_cell in cells:
		var cell := _cell_from_variant(raw_cell, Vector2i(999999, 999999))
		keys[HexGrid.get_cell_key(cell.x, cell.y)] = true
	var count := 0
	for group_variant in game_state.get("groups", []):
		if not (group_variant is Dictionary):
			continue
		var group: Dictionary = group_variant
		var is_enemy := str(group.get("name", "")) != group_name
		if is_enemy != enemies:
			continue
		for unit_variant in group.get("units", []):
			if not (unit_variant is Dictionary):
				continue
			var other: Dictionary = unit_variant
			if int(other.get("health", 0)) <= 0:
				continue
			var c := _cell_from_variant(other.get("cell", [0, 0]), Vector2i.ZERO)
			if keys.has(HexGrid.get_cell_key(c.x, c.y)):
				count += 1
	return count


static func _nearest_enemy_distance(game_state: Dictionary, group_name: String, from_cell: Vector2i) -> int:
	var best := -1
	for group_variant in game_state.get("groups", []):
		if not (group_variant is Dictionary):
			continue
		var group: Dictionary = group_variant
		if str(group.get("name", "")) == group_name:
			continue
		for unit_variant in group.get("units", []):
			if not (unit_variant is Dictionary):
				continue
			var other: Dictionary = unit_variant
			if int(other.get("health", 0)) <= 0:
				continue
			var c := _cell_from_variant(other.get("cell", [0, 0]), Vector2i.ZERO)
			var dist := HexGrid.hex_distance(from_cell.x, from_cell.y, c.x, c.y)
			if best < 0 or dist < best:
				best = dist
	return best


static func _support_utility(
	game_state: Dictionary,
	group_name: String,
	target: Vector2i,
	heal_amount: int,
	recharge_amount: int
) -> float:
	var score := 0.0
	for group_variant in game_state.get("groups", []):
		if not (group_variant is Dictionary):
			continue
		var group: Dictionary = group_variant
		if str(group.get("name", "")) != group_name:
			continue
		for unit_variant in group.get("units", []):
			if not (unit_variant is Dictionary):
				continue
			var ally: Dictionary = unit_variant
			if int(ally.get("health", 0)) <= 0:
				continue
			var c := _cell_from_variant(ally.get("cell", [0, 0]), Vector2i.ZERO)
			if c != target:
				continue
			if heal_amount > 0 and int(ally.get("health", 0)) < int(ally.get("max_health", 0)):
				score += 1.5
			if recharge_amount > 0 and int(ally.get("max_energy", 0)) > 0 and int(ally.get("energy", 0)) < int(ally.get("max_energy", 0)):
				score += 1.0
	return score


static func _cell_from_variant(value: Variant, fallback: Vector2i) -> Vector2i:
	if value is Vector2i:
		return value
	if value is Vector2:
		return Vector2i(int(value.x), int(value.y))
	if value is Array and value.size() >= 2:
		return Vector2i(int(value[0]), int(value[1]))
	return fallback


static func _ranked_action_before(a: Dictionary, b: Dictionary) -> bool:
	var a_score := float(a.get("score", 0.0))
	var b_score := float(b.get("score", 0.0))
	if not is_equal_approx(a_score, b_score):
		return a_score > b_score
	return _action_signature(a.get("action", {})) < _action_signature(b.get("action", {}))


static func _plan_before(a: Dictionary, b: Dictionary) -> bool:
	var a_score := float(a.get("proposal_score", 0.0))
	var b_score := float(b.get("proposal_score", 0.0))
	if not is_equal_approx(a_score, b_score):
		return a_score > b_score
	return _plan_signature(a.get("actions", [])) < _plan_signature(b.get("actions", []))


static func _action_signature(action: Dictionary) -> String:
	return "%08d|%s|%s|%s" % [
		int(action.get("unit_id", -1)),
		str(action.get("action_key", "")),
		str(action.get("end_point", [])),
		str(action.get("path", [])),
	]


static func _plan_signature(actions: Array) -> String:
	var parts: PackedStringArray = []
	for action_variant in actions:
		if action_variant is Dictionary:
			parts.append(_action_signature(action_variant))
	return ";".join(parts)
