extends RefCounted
## Scripted opponent behaviors for AI training drills.
## Each script picks a deterministic action for a unit, enabling repeatable training scenarios
## where the LLM-controlled side learns against predictable opponents.

const PlanningAI = preload("res://src/battle/ai/planning_ai.gd")


static func pick_action(unit: Unit, groups: Array, script_name: String) -> Dictionary:
	match script_name:
		"fire_one_closer":
			return _fire_one_closer(unit, groups)
		"advance_straight":
			return _advance_straight(unit, groups)
		"move_to_neg11":
			return _move_to_cell(unit, Vector2i(-1, -1))
		"move_to_neg1neg2":
			return _move_to_cell(unit, Vector2i(-1, -2))
		"move_to_neg13":
			return _move_to_cell(unit, Vector2i(-1, 3))
		"move_to_neg14":
			return _move_to_cell(unit, Vector2i(-1, 4))
	return PlanningAI.pick_action(unit, groups, Callable())


## Scout fires at the hex one step closer to itself than the nearest enemy.
## Exploitable by moving diagonally — the shot always targets the straight-line approach path.
static func _fire_one_closer(unit: Unit, groups: Array) -> Dictionary:
	var options: Array = PlanningAI._collect_all_options(unit)
	var enemies: Array = PlanningAI._get_enemy_units(unit, groups)
	if enemies.is_empty():
		return _pick_rest(options)

	var nearest: Unit = _nearest_enemy(unit, enemies)
	if nearest == null:
		return _pick_rest(options)

	var target_cell: Vector2 = _one_step_toward(nearest.cell, unit.cell)

	for entry in options:
		if entry.is_move:
			continue
		var ac: ActionInstance = entry.ac
		if ac.definition == null:
			continue
		var ak: String = ac.definition.action_key
		if ak in ["rest_no_energy", "reload", "recruit_people", "recharge"]:
			continue
		if HexGrid.cell_equal(ac.end_point, target_cell):
			return entry

	return _pick_rest(options)


## Unit moves one hex straight toward the nearest enemy each turn. Uses fast_move if available.
static func _advance_straight(unit: Unit, groups: Array) -> Dictionary:
	var options: Array = PlanningAI._collect_all_options(unit)
	var enemies: Array = PlanningAI._get_enemy_units(unit, groups)
	if enemies.is_empty():
		return _pick_rest(options)

	var nearest: Unit = _nearest_enemy(unit, enemies)
	if nearest == null:
		return _pick_rest(options)

	if HexGrid.cell_equal(unit.cell, nearest.cell):
		return _pick_rest(options)

	var target_cell: Vector2 = _one_step_toward(unit.cell, nearest.cell)

	for entry in options:
		if not entry.is_move:
			continue
		if HexGrid.cell_equal(entry.ac.end_point, target_cell):
			return entry

	return _pick_rest(options)


static func _nearest_enemy(unit: Unit, enemies: Array) -> Unit:
	var best: Unit = null
	var best_dist: float = INF
	for e in enemies:
		var d: float = HexGrid.hex_distance_vec(unit.cell, e.cell)
		if d < best_dist:
			best_dist = d
			best = e
	return best


## Returns the hex one step from `from_cell` along the direct path to `to_cell`.
static func _one_step_toward(from_cell: Vector2, to_cell: Vector2) -> Vector2:
	var path: Array = HexGrid.build_path_to(
		int(from_cell.x), int(from_cell.y),
		int(to_cell.x), int(to_cell.y),
	)
	if path.size() >= 1:
		return path[0]
	return from_cell


static func _move_to_cell(unit: Unit, target: Vector2i) -> Dictionary:
	var options: Array = PlanningAI._collect_all_options(unit)
	for entry in options:
		if not entry.is_move:
			continue
		var end_point: Vector2 = entry.ac.end_point
		var q: int = int(end_point.x)
		var r: int = int(end_point.y)
		if q == target.x and r == target.y:
			return entry
	return _pick_rest(options)


static func _pick_rest(options: Array) -> Dictionary:
	for entry in options:
		if not entry.is_move and entry.ac.definition and entry.ac.definition.action_key in ["rest_no_energy", "reload"]:
			return entry
	if not options.is_empty():
		return options[0]
	return {}
