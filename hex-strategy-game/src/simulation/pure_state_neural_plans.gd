extends RefCounted
class_name PureStateNeuralPlans
## Autoregressive neural proposal generator for complete simultaneous-turn plans.
##
## The network scores each unit's legal next actions conditioned on the complete
## state and the actions already chosen for earlier units. A bounded beam carries
## the strongest partial joint plans forward. The robust opponent-response search
## still simulates/evaluates the resulting complete plans; this module only proposes.

const PureStateLegalActions = preload("res://src/simulation/pure_state_legal_actions.gd")
const PureStateJointPolicy = preload("res://src/simulation/pure_state_joint_policy.gd")


static func get_candidate_plans(
	game_state: Dictionary,
	group_name: String,
	opponent_group_name: String,
	max_actions_per_unit: int,
	max_plans: int,
	settings: Dictionary = {}
) -> Array:
	if group_name.is_empty() or opponent_group_name.is_empty() or group_name == opponent_group_name:
		return []
	if max_actions_per_unit <= 0 or max_plans <= 0:
		return []
	var group := _find_group(game_state, group_name)
	if group.is_empty():
		return []

	var units: Array = group.get("units", []).duplicate(true)
	units.sort_custom(func(a, b): return int(a.get("unit_id", -1)) < int(b.get("unit_id", -1)))
	var beam: Array = [{
		"actions": [],
		"proposal_score": 0.0,
		"proposal_source": "neural_joint_policy",
	}]
	var living_units := 0
	var plannable_units := 0

	for unit_variant in units:
		if not (unit_variant is Dictionary):
			continue
		var unit: Dictionary = unit_variant
		if int(unit.get("health", 0)) <= 0:
			continue
		living_units += 1
		var unit_id := int(unit.get("unit_id", -1))
		var legal: Array = PureStateLegalActions.get_legal_actions(game_state, unit_id)
		if legal.is_empty():
			continue
		legal.append({"unit_id": unit_id, "action_key": "<hold>", "end_point": unit.get("cell", [0, 0]), "path": []})
		plannable_units += 1

		var expanded: Array = []
		for partial_variant in beam:
			if not (partial_variant is Dictionary):
				continue
			var partial: Dictionary = partial_variant
			var prefix: Array = (partial.get("actions", []) as Array).duplicate(true)
			var response := PureStateJointPolicy.score_actions(
				game_state,
				group_name,
				opponent_group_name,
				prefix,
				legal,
				settings
			)
			if not bool(response.get("ok", false)):
				# Missing/old checkpoints deliberately fall back to the existing
				# heuristic candidate source in the caller.
				return []
			var scores: Array = response.get("scores", []) as Array
			if scores.size() != legal.size():
				return []
			var maximum := -INF
			for score in scores:
				if not is_finite(float(score)):
					return []
				maximum = maxf(maximum, float(score))
			var normalizer := 0.0
			for score in scores:
				normalizer += exp(float(score) - maximum)
			var log_normalizer := maximum + log(normalizer)
			var ranked: Array = []
			for index in range(legal.size()):
				if not (legal[index] is Dictionary):
					continue
				ranked.append({
					"action": (legal[index] as Dictionary).duplicate(true),
					"score": float(scores[index]) - log_normalizer,
				})
			ranked.sort_custom(_ranked_action_before)
			for index in range(mini(max_actions_per_unit, ranked.size())):
				var choice: Dictionary = ranked[index]
				var actions := prefix.duplicate(true)
				actions.append((choice.get("action", {}) as Dictionary).duplicate(true))
				expanded.append({
					"actions": actions,
					"proposal_score": float(partial.get("proposal_score", 0.0)) + float(choice.get("score", 0.0)),
					"proposal_source": "neural_joint_policy",
				})
		if expanded.is_empty():
			return []
		expanded.sort_custom(_plan_before)
		beam.clear()
		for index in range(mini(max_plans, expanded.size())):
			beam.append(expanded[index])

	if plannable_units == 0:
		if living_units > 0:
			return [{"actions": [], "proposal_score": 0.0, "proposal_source": "neural_joint_policy"}]
		return []
	# Hold is an internal policy token, represented by no submitted command.
	for plan in beam:
		var submitted: Array = []
		for action in plan.get("actions", []):
			if action.get("action_key", "") != "<hold>":
				submitted.append(action)
		plan["actions"] = submitted
	return beam


static func _find_group(game_state: Dictionary, group_name: String) -> Dictionary:
	for group_variant in game_state.get("groups", []):
		if group_variant is Dictionary and str((group_variant as Dictionary).get("name", "")) == group_name:
			return group_variant as Dictionary
	return {}


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


static func _plan_signature(actions_variant: Variant) -> String:
	if not (actions_variant is Array):
		return ""
	var parts: Array[String] = []
	for action_variant in actions_variant:
		parts.append(_action_signature(action_variant))
	return ";".join(parts)


static func _action_signature(action_variant: Variant) -> String:
	if not (action_variant is Dictionary):
		return str(action_variant)
	var action: Dictionary = action_variant
	return "%08d|%s|%s|%s" % [
		int(action.get("unit_id", -1)),
		str(action.get("action_key", "")),
		_cell_signature(action.get("end_point", [])),
		_path_signature(action.get("path", [])),
	]


static func _path_signature(path_variant: Variant) -> String:
	if not (path_variant is Array):
		return str(path_variant)
	var parts: Array[String] = []
	for cell_variant in path_variant:
		parts.append(_cell_signature(cell_variant))
	return ">".join(parts)


static func _cell_signature(cell_variant: Variant) -> String:
	if cell_variant is Vector2i:
		return "%d,%d" % [cell_variant.x, cell_variant.y]
	if cell_variant is Vector2:
		return "%d,%d" % [int(cell_variant.x), int(cell_variant.y)]
	if cell_variant is Array and (cell_variant as Array).size() >= 2:
		return "%d,%d" % [int(cell_variant[0]), int(cell_variant[1])]
	return str(cell_variant)
