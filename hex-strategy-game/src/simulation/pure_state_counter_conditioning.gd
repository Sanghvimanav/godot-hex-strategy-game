extends RefCounted
class_name PureStateCounterConditioning
## Opponent-conditioned proposal augmentation for simultaneous-turn search.
##
## Opponent response plans reveal cells an enemy may occupy after movement. Normal
## proposal scoring sees those cells as empty during planning, so predictive shots
## can be pruned before simulation. This helper injects legal damaging actions whose
## real damage footprint covers modeled movement destinations, while leaving the
## simulator/evaluator responsible for deciding whether the prediction is good.

const PureStateLegalActions = preload("res://src/simulation/pure_state_legal_actions.gd")
const TurnExecutionCore = preload("res://src/battle/turn_execution_core.gd")

const COUNTER_PROPOSAL_BONUS_PER_CELL := 5.0
const DEFAULT_MAX_INJECTED_PLANS := 24


static func get_condition_cells(opponent_candidates: Array) -> Array:
	var by_key: Dictionary = {}
	for candidate_variant in opponent_candidates:
		if not (candidate_variant is Dictionary):
			continue
		var candidate: Dictionary = candidate_variant
		for action_variant in candidate.get("actions", []):
			if not (action_variant is Dictionary):
				continue
			var action: Dictionary = action_variant
			var config: Dictionary = Actions.get_action_config(str(action.get("action_key", "")))
			if str(config.get("type", "")) not in TurnExecutionCore.MOVE_TYPES:
				continue
			var cell := _cell_from_variant(action.get("end_point", []), Vector2i(999999, 999999))
			if cell == Vector2i(999999, 999999):
				continue
			by_key[HexGrid.get_cell_key(cell.x, cell.y)] = [cell.x, cell.y]
	var keys: Array = by_key.keys()
	keys.sort()
	var result: Array = []
	for key in keys:
		result.append((by_key[key] as Array).duplicate(true))
	return result


static func inject_counter_plans(
	game_state: Dictionary,
	group_name: String,
	base_candidates: Array,
	condition_cells: Array,
	max_injected_plans: int = DEFAULT_MAX_INJECTED_PLANS
) -> Array:
	var result: Array = []
	for candidate_variant in base_candidates:
		if candidate_variant is Dictionary:
			result.append((candidate_variant as Dictionary).duplicate(true))
	if result.is_empty() or condition_cells.is_empty() or max_injected_plans <= 0:
		return result

	var condition_keys := _cell_key_set(condition_cells)
	var existing_signatures: Dictionary = {}
	for candidate_variant in result:
		if candidate_variant is Dictionary:
			existing_signatures[_plan_signature((candidate_variant as Dictionary).get("actions", []))] = true

	var group := _find_group(game_state, group_name)
	if group.is_empty():
		return result
	var injected := 0
	var units: Array = group.get("units", []).duplicate()
	units.sort_custom(func(a, b): return int(a.get("unit_id", -1)) < int(b.get("unit_id", -1)))
	for unit_variant in units:
		if injected >= max_injected_plans:
			break
		if not (unit_variant is Dictionary):
			continue
		var unit: Dictionary = unit_variant
		if int(unit.get("health", 0)) <= 0:
			continue
		var unit_id := int(unit.get("unit_id", -1))
		var legal: Array = PureStateLegalActions.get_legal_actions(game_state, unit_id)
		var counter_actions: Array = []
		for action_variant in legal:
			if not (action_variant is Dictionary):
				continue
			var action: Dictionary = action_variant
			var config: Dictionary = Actions.get_action_config(str(action.get("action_key", "")))
			if int(config.get("damage", 0)) <= 0:
				continue
			var covered := _covered_condition_cells(unit, action, config, condition_keys)
			if covered.is_empty():
				continue
			counter_actions.append({
				"action": action.duplicate(true),
				"covered_cells": covered,
			})
		counter_actions.sort_custom(_counter_action_before)

		for counter_variant in counter_actions:
			if injected >= max_injected_plans:
				break
			var counter: Dictionary = counter_variant
			var action: Dictionary = counter.get("action", {})
			var covered_cells: Array = counter.get("covered_cells", [])
			# Complete the counter with the strongest existing joint plan. This keeps
			# every other unit's action coherent while swapping only this unit's move.
			for base_variant in base_candidates:
				if not (base_variant is Dictionary):
					continue
				var base: Dictionary = base_variant
				var actions: Array = base.get("actions", []).duplicate(true)
				var replaced := false
				for i in range(actions.size()):
					if actions[i] is Dictionary and int((actions[i] as Dictionary).get("unit_id", -1)) == unit_id:
						actions[i] = action.duplicate(true)
						replaced = true
						break
				if not replaced:
					continue
				var signature := _plan_signature(actions)
				if existing_signatures.has(signature):
					break
				var candidate := {
					"actions": actions,
					"proposal_score": float(base.get("proposal_score", 0.0)) + COUNTER_PROPOSAL_BONUS_PER_CELL * float(covered_cells.size()),
					"counter_conditioned": true,
					"counter_cells": covered_cells.duplicate(true),
				}
				result.append(candidate)
				existing_signatures[signature] = true
				injected += 1
				break

	result.sort_custom(_candidate_before)
	return result


static func _covered_condition_cells(
	unit: Dictionary,
	action: Dictionary,
	config: Dictionary,
	condition_keys: Dictionary
) -> Array:
	var from_cell := _cell_from_variant(unit.get("cell", [0, 0]), Vector2i.ZERO)
	var damage_cells: Array = TurnExecutionCore.get_damage_cells_for_config(
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
			if aoe_cell not in damage_cells:
				damage_cells.append(aoe_cell)
	var covered_by_key: Dictionary = {}
	for damage_cell_variant in damage_cells:
		var cell := _cell_from_variant(damage_cell_variant, Vector2i(999999, 999999))
		var key := HexGrid.get_cell_key(cell.x, cell.y)
		if condition_keys.has(key):
			covered_by_key[key] = [cell.x, cell.y]
	var keys: Array = covered_by_key.keys()
	keys.sort()
	var result: Array = []
	for key in keys:
		result.append((covered_by_key[key] as Array).duplicate(true))
	return result


static func _cell_key_set(cells: Array) -> Dictionary:
	var result: Dictionary = {}
	for value in cells:
		var cell := _cell_from_variant(value, Vector2i(999999, 999999))
		if cell != Vector2i(999999, 999999):
			result[HexGrid.get_cell_key(cell.x, cell.y)] = true
	return result


static func _find_group(game_state: Dictionary, group_name: String) -> Dictionary:
	for group_variant in game_state.get("groups", []):
		if group_variant is Dictionary and str((group_variant as Dictionary).get("name", "")) == group_name:
			return group_variant
	return {}


static func _counter_action_before(a: Dictionary, b: Dictionary) -> bool:
	var a_count := (a.get("covered_cells", []) as Array).size()
	var b_count := (b.get("covered_cells", []) as Array).size()
	if a_count != b_count:
		return a_count > b_count
	return _action_signature(a.get("action", {})) < _action_signature(b.get("action", {}))


static func _candidate_before(a: Dictionary, b: Dictionary) -> bool:
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


static func _cell_from_variant(value: Variant, fallback: Vector2i) -> Vector2i:
	if value is Vector2i:
		return value
	if value is Vector2:
		return Vector2i(int(value.x), int(value.y))
	if value is Array and value.size() >= 2:
		return Vector2i(int(value[0]), int(value[1]))
	return fallback
