extends RefCounted
## Picks actions for AI-controlled units. Works with any unit type.
## Zerglings: only attack when 3+ zerglings or 1 zergling + 1 baneling within 2 tiles of player.
## When holding, zerglings spread out in the 2-tile ring around the player.

## Returns {ac: ActionInstance, is_move: bool} or null if no valid action.
static func pick_action(unit: Unit, groups: Array, get_units_at_cell: Callable) -> Dictionary:
	if unit == null or not is_instance_valid(unit):
		return {}
	var options: Array = _collect_all_options(unit)
	if options.is_empty():
		return {}
	var enemies: Array = _get_enemy_units(unit, groups)
	# Prefer attack that hits an enemy
	for entry in options:
		if not entry.is_move:
			var action_key: String = entry.ac.definition.action_key if entry.ac.definition else ""
			# Banelings only explode when on the same tile as an enemy
			if action_key == "explode":
				if _enemy_on_same_tile(entry.ac.unit, enemies):
					return entry
			elif _action_hits_enemy(entry.ac, enemies):
				return entry
	# Immobile units: Rest/Recharge when no attack would hit (avoid firing at empty hexes).
	if unit.def != null and unit.def.move_action_keys.is_empty():
		for entry in options:
			if entry.is_move:
				continue
			var ak: String = entry.ac.definition.action_key if entry.ac.definition else ""
			if ak in ["reload", "rest_no_energy", "recharge"]:
				return entry
	# Move selection: zergling-specific logic when 2 tiles away
	if _is_zergling(unit):
		var entry = _pick_zergling_move(unit, options, enemies, groups)
		if not entry.is_empty():
			return entry
	# Fester: consume on village, spawn when ready, move to village, avoid enemies
	if _is_fester(unit):
		var entry = _pick_fester_action(unit, options, enemies, groups)
		if not entry.is_empty():
			return entry
	# Default: prefer move toward nearest enemy; when equidistant, pick randomly
	var best_moves: Array = []
	var best_dist := INF
	for entry in options:
		if entry.is_move:
			var d := _dist_to_nearest_enemy(entry.ac.end_point, enemies)
			if d < best_dist:
				best_dist = d
				best_moves = [entry]
			elif d == best_dist:
				best_moves.append(entry)
	if not best_moves.is_empty():
		return best_moves[randi_range(0, best_moves.size() - 1)]
	# Fallback: first option (e.g. Rest)
	return options[0]

static func _collect_all_options(unit: Unit) -> Array:
	var result: Array = []
	if unit == null or not is_instance_valid(unit):
		return []
	var db = unit.abilities_db
	if db == null:
		return []
	for key in unit.def.get_move_action_keys_resolved():
		result.append_array(db.get_options_for_action_key(key))
	for key in unit.def.get_ability_action_keys_resolved():
		result.append_array(db.get_options_for_action_key(key))
	return result

static func _get_enemy_units(unit: Unit, groups: Array) -> Array:
	var my_group: Node = unit.get_parent()
	var enemies: Array = []
	for group in groups:
		if group == my_group:
			continue
		for child in group.get_children():
			if child is Unit and child.is_active:
				enemies.append(child)
	return enemies

static func _enemy_on_same_tile(unit: Unit, enemies: Array) -> bool:
	for e in enemies:
		if HexGrid.cell_equal(e.cell, unit.cell):
			return true
	return false

static func _action_hits_enemy(ac: ActionInstance, enemies: Array) -> bool:
	var full_path: Array = ac.path + [ac.end_point]
	for e in enemies:
		for cell in full_path:
			if HexGrid.cell_equal(e.cell, cell):
				return true
	# Check AoE (for targeted attacks with area_of_effect)
	var config: Dictionary = Actions.get_action_config(ac.definition.action_key) if ac.definition else {}
	var aoe: Dictionary = config.get("area_of_effect", {})
	if not aoe.is_empty():
		var from_cell: Vector2 = ac.unit.cell
		var aoe_cells: Array = HexGrid.get_aoe_tiles(from_cell, ac.end_point, aoe)
		for aoe_cell in aoe_cells:
			for e in enemies:
				if HexGrid.cell_equal(e.cell, aoe_cell):
					return true
	return false

static func _dist_to_nearest_enemy(cell: Vector2, enemies: Array) -> float:
	if enemies.is_empty():
		return INF
	var min_d := INF
	for e in enemies:
		var d := HexGrid.hex_distance_vec(cell, e.cell)
		if d < min_d:
			min_d = d
	return float(min_d)

static func _is_zergling(unit: Unit) -> bool:
	return unit.def != null and unit.def.name == "Zergling"

static func _is_baneling(unit: Unit) -> bool:
	return unit.def != null and unit.def.name == "Baneling"

static func _is_fester(unit: Unit) -> bool:
	return unit.def != null and unit.def.name == "Fester"

static func _get_allies(unit: Unit, groups: Array) -> Array:
	var my_group: Node = unit.get_parent()
	for group in groups:
		if group == my_group:
			var allies: Array = []
			for child in group.get_children():
				if child is Unit and child.is_active and child != unit:
					allies.append(child)
			return allies
	return []

## Cells at distance 1 or 2 from any enemy.
static func _cells_within_2_of_enemies(enemies: Array) -> Dictionary:
	var zone: Dictionary = {}
	if enemies.is_empty():
		return zone
	for e in enemies:
		var ec: Vector2 = e.cell
		for dist in [1, 2]:
			var ring := HexGrid.get_hexes_at_distance(int(ec.x), int(ec.y), dist)
			for v in ring:
				var key := "%d,%d" % [v.x, v.y]
				zone[key] = Vector2(v.x, v.y)
	return zone

static func _cell_in_zone(cell: Vector2, zone: Dictionary) -> bool:
	var key := "%d,%d" % [int(cell.x), int(cell.y)]
	return zone.has(key)

## Count zerglings and banelings in the 2-tile zone around enemies (excluding unit).
static func _count_allies_in_zone(unit: Unit, allies: Array, zone: Dictionary) -> Dictionary:
	var n_zerg := 0
	var n_baneling := 0
	for a in allies:
		if not _cell_in_zone(a.cell, zone):
			continue
		if _is_zergling(a):
			n_zerg += 1
		elif _is_baneling(a):
			n_baneling += 1
	return {"zerg": n_zerg, "baneling": n_baneling}

## Count allies at a specific cell (for spread-out scoring).
static func _count_allies_at_cell(cell: Vector2, allies: Array, unit: Unit) -> int:
	var count := 0
	for a in allies:
		if a == unit:
			continue
		if HexGrid.cell_equal(a.cell, cell):
			count += 1
	return count

static func _pick_zergling_move(unit: Unit, options: Array, enemies: Array, groups: Array) -> Dictionary:
	var move_options: Array = []
	for entry in options:
		if entry.is_move:
			move_options.append(entry)
	if move_options.is_empty():
		return {}
	var allies: Array = _get_allies(unit, groups)
	var zone: Dictionary = _cells_within_2_of_enemies(enemies)
	var counts: Dictionary = _count_allies_in_zone(unit, allies, zone)
	var n_zerg: int = counts.get("zerg", 0)
	var n_baneling: int = counts.get("baneling", 0)
	# Condition to allow attack (move to dist 1): 3+ zerg in zone, or 1 zerg + 1 baneling
	# This zergling moving in adds 1 zerg, so we need: n_zerg >= 2 OR n_baneling >= 1
	var may_attack := n_zerg >= 2 or n_baneling >= 1
	var cur_dist := _dist_to_nearest_enemy(unit.cell, enemies)
	if cur_dist <= 1:
		# Already adjacent; use default behavior (closest move - might be Rest)
		return {}
	# cur_dist >= 2
	var moves_to_attack: Array = []  # Moves that put us at dist 1
	var moves_to_spread: Array = []  # Moves that keep us at dist 2 (spread in ring)
	for entry in move_options:
		var d := _dist_to_nearest_enemy(entry.ac.end_point, enemies)
		if d == 1:
			moves_to_attack.append(entry)
		elif d == 2:
			moves_to_spread.append(entry)
	if may_attack and not moves_to_attack.is_empty():
		return moves_to_attack[randi_range(0, moves_to_attack.size() - 1)]
	# Hold back: prefer spread moves (at dist 2) with fewer allies at that cell
	if not moves_to_spread.is_empty():
		var best: Array = []
		var best_allies := INF
		for entry in moves_to_spread:
			var ep: Vector2 = entry.ac.end_point
			var n_at := _count_allies_at_cell(ep, allies, unit)
			if n_at < best_allies:
				best_allies = n_at
				best = [entry]
			elif n_at == best_allies:
				best.append(entry)
		if not best.is_empty():
			return best[randi_range(0, best.size() - 1)]
	# No spread moves (e.g. already at dist 2, all moves go to 1 or 3): pick Rest if available
	for entry in options:
		if not entry.is_move and entry.ac.definition and entry.ac.definition.action_key in ["reload", "rest_no_energy"]:
			return entry
	# Fall through to default
	return {}

## Fester AI: consume on village, spawn when ready, move to village, avoid enemies.
static func _pick_fester_action(unit: Unit, options: Array, enemies: Array, groups: Array) -> Dictionary:
	# 1. Consume when on village with 2+ people
	if _cell_has_village_with_people(unit.cell, 2):
		for entry in options:
			if not entry.is_move and entry.ac.definition and entry.ac.definition.action_key == "consume":
				return entry
	# 2. Spawn zergling when has 3+ people and 4+ HP (need >3 HP to survive the 3 HP cost)
	var people: int = _get_group_people(unit)
	if people >= 3 and unit.health >= 4:
		for entry in options:
			if not entry.is_move and entry.ac.definition and entry.ac.definition.action_key == "spawn_fester_zergling":
				return entry
	# 2b. Spawn Shardling when 3+ people and 5+ HP (need >4 HP to survive the 4 HP cost)
	if people >= 3 and unit.health >= 5:
		for entry in options:
			if not entry.is_move and entry.ac.definition and entry.ac.definition.action_key == "spawn_shardling":
				return entry
	# 3. Move toward nearest village with 2+ people, staying away from enemies (min dist 2)
	var villages: Array = _get_village_cells_with_people(2)
	if not villages.is_empty():
		var min_enemy_dist := 2
		var best_moves: Array = []
		var best_village_dist := INF
		for entry in options:
			if not entry.is_move:
				continue
			var dest: Vector2 = entry.ac.end_point
			var enemy_d: float = _dist_to_nearest_enemy(dest, enemies)
			if enemy_d < min_enemy_dist:
				continue  # Don't move too close to enemies
			var village_d: float = _dist_to_nearest_cell(dest, villages)
			if village_d < best_village_dist:
				best_village_dist = village_d
				best_moves = [entry]
			elif village_d == best_village_dist:
				best_moves.append(entry)
		if not best_moves.is_empty():
			return best_moves[randi_range(0, best_moves.size() - 1)]
	# 4. If on village but can't consume (e.g. only 1 left), or nowhere to go: move away from enemies or Rest
	var cur_enemy_d: float = _dist_to_nearest_enemy(unit.cell, enemies)
	if cur_enemy_d < 2:
		# Too close to enemies - move away
		var move_options: Array = []
		for entry in options:
			if entry.is_move:
				var d := _dist_to_nearest_enemy(entry.ac.end_point, enemies)
				if d > cur_enemy_d:
					move_options.append(entry)
		if not move_options.is_empty():
			return move_options[randi_range(0, move_options.size() - 1)]
	# 5. Rest as fallback
	for entry in options:
		if not entry.is_move and entry.ac.definition and entry.ac.definition.action_key in ["reload", "rest_no_energy"]:
			return entry
	return {}

static func _cell_has_village_with_people(cell: Vector2, min_amount: int) -> bool:
	var key := HexGrid.get_cell_key(int(cell.x), int(cell.y))
	if not Navigation.grid.has(key):
		return false
	var tile: Dictionary = Navigation.grid[key]
	if str(tile.get("resource_type", "")) != "people":
		return false
	return int(tile.get("resource_amount", 0)) >= min_amount

static func _get_village_cells_with_people(min_amount: int) -> Array:
	var result: Array = []
	for key in Navigation.grid:
		var tile: Dictionary = Navigation.grid[key]
		if str(tile.get("resource_type", "")) != "people":
			continue
		if int(tile.get("resource_amount", 0)) < min_amount:
			continue
		if tile.has("q") and tile.has("r"):
			result.append(Vector2(tile.q, tile.r))
		else:
			var parts: Array = key.split(",")
			if parts.size() >= 2:
				result.append(Vector2(int(parts[0]), int(parts[1])))
	return result

static func _get_group_people(unit: Unit) -> int:
	var group_node: Node = unit.get_parent()
	if group_node == null or not group_node.has_meta("resource_inventory"):
		return 0
	var inv = group_node.get_meta("resource_inventory")
	if not (inv is Dictionary):
		return 0
	return int(inv.get("people", 0))

static func _dist_to_nearest_cell(cell: Vector2, targets: Array) -> float:
	if targets.is_empty():
		return INF
	var min_d := INF
	for t in targets:
		var d: float
		if t is Vector2:
			d = HexGrid.hex_distance_vec(cell, t)
		elif t is Vector2i:
			d = HexGrid.hex_distance_vec(cell, Vector2(t.x, t.y))
		else:
			continue
		if d < min_d:
			min_d = d
	return float(min_d)
