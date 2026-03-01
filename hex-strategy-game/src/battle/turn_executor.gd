class_name TurnExecutor
extends RefCounted
## Unified turn execution pipeline. Processes actions by type in ACTION_ORDER.
## Used for both live execution and replay. Add new action types by extending
## _get_handler_for_type and implementing the handler.

## Use TurnExecutionCore as single source for action type constants.
const MOVE_TYPES: Array[String] = TurnExecutionCore.MOVE_TYPES
const ABILITY_TYPES: Array[String] = TurnExecutionCore.ABILITY_TYPES
const SPAWN_TYPES: Array[String] = TurnExecutionCore.SPAWN_TYPES
const ATTACK_TIMEOUT: float = 5.0
const HEAL_EFFECT_SCENE := preload("res://src/unit/art/effects/heal_effect.tscn")
const UNIT_SCENE := preload("res://src/unit/unit.tscn")

## Execution context passed through the pipeline.
## apply_damage: if false, animations only (replay mode)
## recording: { actions: [], died_ids: [], summary: [], applied_effects: [] } - built during execution
## phase_callback: optional; called after each action-type phase (e.g. to refresh fog during replay)
class ExecutionContext:
	var groups: Array
	var apply_damage: bool
	var recording: Dictionary
	var damage_by_id: Dictionary = {}
	var applied_damage_by_id: Dictionary = {}  ## Damage already applied this turn (so we apply after each attack phase)
	var get_units_at_cell: Callable
	var tree: SceneTree
	var phase_callback: Callable = Callable()

	func _init(p_groups: Array, p_apply_damage: bool, p_recording: Dictionary, p_get_units: Callable, p_tree: SceneTree) -> void:
		groups = p_groups
		apply_damage = p_apply_damage
		recording = p_recording
		get_units_at_cell = p_get_units
		tree = p_tree

## Runs the pipeline. actions_by_type: { type -> [{unit, ac, is_move}] }
## Records to ctx.recording when apply_damage is true.
## Damage is applied after each attack phase so units that die cannot perform later actions.
static func run_pipeline(actions_by_type: Dictionary, ctx: ExecutionContext) -> void:
	for action_type in Actions.ACTION_ORDER:
		var entries: Array = actions_by_type[action_type] if actions_by_type.has(action_type) else []
		if not entries.is_empty():
			print("[EXEC] pipeline processing: ", action_type, " count=", entries.size())
		var filtered: Array = []
		for entry in entries:
			if not _valid_unit(entry.unit):
				continue  # Dead units do not get to act
			if action_type in entry.unit.get_disabled_action_types():
				continue
			filtered.append(entry)
		if filtered.is_empty():
			continue
		var handler := _get_handler_for_type(action_type)
		if handler.is_valid():
			await handler.call(action_type, filtered, ctx)
			print("[EXEC] pipeline done with ", action_type)
			# Apply damage after each ability phase so units that die are skipped in later phases
			if action_type in ABILITY_TYPES and ctx.apply_damage:
				print("[DAMAGE] before _apply_accumulated_damage, damage_by_id size=%d keys=%s" % [ctx.damage_by_id.size(), ctx.damage_by_id.keys()])
				_apply_accumulated_damage(ctx)
			if ctx.phase_callback.is_valid():
				ctx.phase_callback.call()

## Returns the list of cells to check for damage. Uses TurnExecutionCore so targeting matches server.
static func get_damage_cells(attacker_cell: Vector2, ac: ActionInstance, config: Dictionary) -> Array:
	var cells: Array = TurnExecutionCore.get_damage_cells_for_config(
		int(attacker_cell.x), int(attacker_cell.y), ac.path, ac.end_point, config
	)
	var out: Array = []
	for c in cells:
		out.append(Vector2(c.x, c.y))
	return out

## Returns Callable for the given action type, or invalid for no-op types.
static func _get_handler_for_type(action_type: String) -> Callable:
	if action_type in MOVE_TYPES:
		return _handle_moves
	if action_type in ABILITY_TYPES:
		return _handle_abilities
	if action_type in SPAWN_TYPES:
		return _handle_spawn
	# extract: no-op
	return Callable()

static func _handle_abilities(action_type: String, entries: Array, ctx: ExecutionContext) -> void:
	var reload_entries: Array = []
	var support_entries: Array = []
	var attack_entries: Array = []
	for entry in entries:
		var ac: ActionInstance = entry.ac
		var action_key: String = ac.definition.action_key if ac.definition else ""
		if action_key in ["reload", "recharge"]:
			reload_entries.append(entry)
		elif action_key in ["heal_adjacent", "support_adjacent", "resupply_adjacent"]:
			support_entries.append(entry)
		else:
			attack_entries.append(entry)
	if not reload_entries.is_empty():
		await _handle_reload.call(action_type, reload_entries, ctx)
	if not support_entries.is_empty():
		_handle_support(action_type, support_entries, ctx)
	if not attack_entries.is_empty():
		await _handle_attacks.call(action_type, attack_entries, ctx)

static func _handle_reload(_action_type: String, entries: Array, ctx: ExecutionContext) -> void:
	for entry in entries:
		var u = entry.unit
		if not _valid_unit(u):
			continue
		if ctx.apply_damage:
			ctx.recording.actions.append({ "type": _action_type, "unit": u, "unit_id": _recording_unit_id(u), "ac": entry.ac })
			var ac: ActionInstance = entry.ac
			if ac != null and ac.definition != null and u.max_energy > 0:
				var config: Dictionary = Actions.get_action_config(ac.definition.action_key)
				var power: int = int(config["energy_consumption"]) if config.has("energy_consumption") else 0
				var gain: int = 0
				if power < 0:
					gain = -power
				elif ac.definition.action_key == "recharge":
					gain = 1
				if gain > 0:
					u.energy = mini(u.energy + gain, u.max_energy)
					if u.energy_bar:
						u.energy_bar.update_value(u.energy)
		await ctx.tree.process_frame

static func _handle_support(_action_type: String, entries: Array, ctx: ExecutionContext) -> void:
	for entry in entries:
		var supporter = entry.unit
		if not _valid_unit(supporter):
			continue
		var ac: ActionInstance = entry.ac
		var config: Dictionary = Actions.get_action_config(ac.definition.action_key) if ac.definition else {}
		var power: int = int(config["energy_consumption"]) if config.has("energy_consumption") else 0
		if ctx.apply_damage and power > 0 and supporter.max_energy > 0 and supporter.energy > 0:
			supporter.energy -= power
			if supporter.energy_bar:
				supporter.energy_bar.update_value(supporter.energy)
		var heal_amount: int = int(config["heal_amount"]) if config.has("heal_amount") else 1
		var recharge: int = int(config["recharge"]) if config.has("recharge") else 1
		var supporter_group: Node = supporter.get_parent()
		# Use shared targeting resolution so support/heal matches server/core behavior.
		var target_cells: Array = TurnExecutionCore.get_damage_cells_for_config(
			int(supporter.cell.x),
			int(supporter.cell.y),
			ac.path if ac else [],
			ac.end_point if ac else supporter.cell,
			config
		)
		for raw_cell in target_cells:
			var target_cell: Vector2 = Vector2(int(raw_cell.x), int(raw_cell.y))
			var units_at: Array = ctx.get_units_at_cell.call(target_cell)
			for target in units_at:
				if not is_instance_valid(target) or not target is Unit:
					continue
				if target.get_parent() != supporter_group:
					continue
				if not target.is_active:
					continue
				if ctx.apply_damage:
					target.health = mini(target.health + heal_amount, target.max_health)
					if target.health_bar:
						target.health_bar.update_value(target.health)
					if target.max_energy > 0 and recharge > 0:
						target.energy = mini(target.energy + recharge, target.max_energy)
						if target.energy_bar:
							target.energy_bar.update_value(target.energy)
				if heal_amount > 0:
					var effect: Node2D = HEAL_EFFECT_SCENE.instantiate()
					target.add_child(effect)
		if ctx.apply_damage:
			ctx.recording.actions.append({ "type": _action_type, "unit": supporter, "unit_id": _recording_unit_id(supporter), "ac": ac })

static func _handle_spawn(action_type: String, entries: Array, ctx: ExecutionContext) -> void:
	for entry in entries:
		var spawner = entry.unit
		if not _valid_unit(spawner):
			continue
		var spawn_data: Dictionary = entry.get("spawn_data", {})
		if spawn_data.is_empty():
			continue
		var spawn_path: String = str(spawn_data.get("spawn_path", ""))
		if spawn_path.is_empty():
			continue
		var cell_val = spawn_data.get("cell", spawner.cell)
		var spawn_cell: Vector2 = spawner.cell
		if cell_val is Vector2:
			spawn_cell = cell_val
		elif cell_val is Array and cell_val.size() >= 2:
			spawn_cell = Vector2(int(cell_val[0]), int(cell_val[1]))
		var spawned_unit_id: int = int(spawn_data.get("spawned_unit_id", 0))
		var action_key: String = entry.ac.definition.action_key if entry.get("ac") and entry.ac.definition else "spawn_zergling"
		var config: Dictionary = Actions.get_action_config(action_key)
		var power: int = int(config.get("energy_consumption", 0))
		if ctx.apply_damage and power > 0 and spawner.max_energy > 0:
			spawner.energy = maxi(0, spawner.energy - power)
			if spawner.energy_bar:
				spawner.energy_bar.update_value(spawner.energy)
		var def: Resource = load(spawn_path) as UnitDefinition
		if def == null:
			continue
		var new_unit: Unit = UNIT_SCENE.instantiate() as Unit
		new_unit.def = def
		new_unit.starting_cell = Vector2i(int(spawn_cell.x), int(spawn_cell.y))
		new_unit.set_meta("unit_id", spawned_unit_id)
		var group_node: Node = spawner.get_parent()
		if group_node != null:
			group_node.add_child(new_unit)
		if ctx.apply_damage:
			ctx.recording.actions.append({ "type": action_type, "unit": spawner, "unit_id": _recording_unit_id(spawner), "ac": entry.get("ac"), "spawned_unit_id": spawned_unit_id, "spawn_path": spawn_path, "cell": spawn_cell })

static func _handle_moves(action_type: String, entries: Array, ctx: ExecutionContext) -> void:
	for entry in entries:
		var u = entry.unit
		if not _valid_unit(u) or not entry.is_move:
			print("[EXEC] _handle_moves skip unit or not move")
			continue
		var ac: ActionInstance = entry.ac
		print("[EXEC] _handle_moves moving ", u.def.name)
		var from_cell: Vector2 = u.cell
		u.move_along_path(ac.path + [ac.end_point])
		await u.movement_complete
		if ctx.apply_damage:
			ctx.recording.actions.append({ "type": "move", "unit": u, "unit_id": _recording_unit_id(u), "from_cell": from_cell, "path": ac.path + [ac.end_point] })

static func _handle_attacks(action_type: String, entries: Array, ctx: ExecutionContext) -> void:
	# Resolve "self" pattern so ac has current cell for damage
	for entry in entries:
		var attacker = entry.unit
		if not _valid_unit(attacker):
			continue
		var ac: ActionInstance = entry.ac
		var ac_cfg: Dictionary = Actions.get_action_config(ac.definition.action_key) if ac.definition else {}
		if ac.definition and (ac_cfg["pattern"] if ac_cfg.has("pattern") else "") == "self":
			entry.ac = ac.definition.to_action_instance(attacker)
	# Run damage phase FIRST (before any await) so positions are from current phase only (e.g. after fast move, before move phase).
	# Otherwise the attack animation's await can let the scene advance and the move phase run, changing target positions.
	const DEBUG_DAMAGE_VERBOSE := true
	if DEBUG_DAMAGE_VERBOSE:
		for gi in ctx.groups.size():
			var g: Node = ctx.groups[gi]
			var names: Array = []
			for c in g.get_children():
				if c is Unit:
					names.append("%s@%s" % [c.def.name if c.def else "?", c.cell])
			print("[DAMAGE] group[%d] name=%s units=%s" % [gi, g.name, names])
	print("[DAMAGE] damage phase: apply_damage=%s entries=%d (before animations)" % [ctx.apply_damage, entries.size()])
	for entry in entries:
		if not ctx.apply_damage:
			continue
		var attacker = entry.unit
		var ac: ActionInstance = entry.ac
		var config: Dictionary = Actions.get_action_config(ac.definition.action_key) if ac.definition else {}
		var full_path: Array = get_damage_cells(attacker.cell, ac, config)
		var pattern_self: bool = (config["pattern"] if config.has("pattern") else "") == "self"
		var attacker_group: Node = attacker.get_parent()
		var action_key: String = ac.definition.action_key if ac.definition else ""
		var is_passive: bool = action_key in attacker.def.passive_action_keys
		var damage_amount: int = int(config["damage"]) if config.has("damage") else 1
		var dealt_damage := false
		var stun_duration: int = int(config["stun_duration"]) if config.has("stun_duration") else 0
		print("[DAMAGE] attacker=%s at %s action_key=%s full_path=%s (pattern_self=%s) damage_amount=%d" % [attacker.def.name, attacker.cell, action_key, full_path, pattern_self, damage_amount])
		for cell in full_path:
			if DEBUG_DAMAGE_VERBOSE:
				var at_cell: Array = []
				for group in ctx.groups:
					for child in group.get_children():
						if child is Unit and HexGrid.cell_equal(child.cell, cell):
							at_cell.append("%s(cell=%s)" % [child.def.name if child.def else "?", child.cell])
				print("[DAMAGE]   cell %s -> units at cell: %s" % [cell, at_cell])
			for group in ctx.groups:
				for child in group.get_children():
					if child is Unit and HexGrid.cell_equal(child.cell, cell) and child != attacker:
						var same_group: bool = child.get_parent() == attacker_group
						if DEBUG_DAMAGE_VERBOSE:
							print("[DAMAGE]     candidate %s same_group=%s -> %s" % [child.def.name if child.def else "?", same_group, "skip (ally)" if same_group else "HIT"])
						if same_group:
							continue
						dealt_damage = true
						var uid: int = child.get_instance_id()
						ctx.damage_by_id[uid] = (ctx.damage_by_id[uid] if ctx.damage_by_id.has(uid) else 0) + damage_amount
						print("[DAMAGE] hit %s at %s for %d (uid %d)" % [child.def.name, cell, damage_amount, uid])
						if stun_duration > 0:
							_apply_stun_effect(ctx, child, stun_duration)
		var aoe: Dictionary = config["area_of_effect"] if config.has("area_of_effect") else {}
		if not aoe.is_empty():
			var from_cell: Vector2 = attacker.cell
			var target_cell: Vector2 = ac.end_point
			var aoe_cells: Array = HexGrid.get_aoe_tiles(from_cell, target_cell, aoe)
			for aoe_cell in aoe_cells:
				for group in ctx.groups:
					for child in group.get_children():
						if child is Unit and HexGrid.cell_equal(child.cell, aoe_cell) and child != attacker:
							if child.get_parent() == attacker_group:
								continue
							dealt_damage = true
							var uid: int = child.get_instance_id()
							ctx.damage_by_id[uid] = (ctx.damage_by_id[uid] if ctx.damage_by_id.has(uid) else 0) + damage_amount
							print("[DAMAGE] AoE hit %s at %s for %d (uid %d)" % [child.def.name, aoe_cell, damage_amount, uid])
							if stun_duration > 0:
								_apply_stun_effect(ctx, child, stun_duration)
		if config.has("self_damage") and config["self_damage"]:
			dealt_damage = true
			var uid: int = attacker.get_instance_id()
			var self_dmg: int = int(config["self_damage_amount"]) if config.has("self_damage_amount") else 999
			ctx.damage_by_id[uid] = (ctx.damage_by_id[uid] if ctx.damage_by_id.has(uid) else 0) + self_dmg
		if ctx.apply_damage:
			var should_record := not is_passive or dealt_damage
			if should_record:
				ctx.recording.actions.append({ "type": action_type, "unit": attacker, "unit_id": _recording_unit_id(attacker), "ac": ac })
			if dealt_damage and is_passive:
				var causers: Dictionary = ctx.recording["damage_causers"] if ctx.recording.has("damage_causers") else {}
				var key := "%d_%s" % [_recording_unit_id(attacker), action_key]
				causers[key] = true
				ctx.recording["damage_causers"] = causers
	print("[DAMAGE] damage phase done, damage_by_id size=%d" % ctx.damage_by_id.size())
	if ctx.apply_damage and ctx.damage_by_id.size() > 0:
		print("[DAMAGE] applying from _handle_attacks (apply_damage=%s)" % ctx.apply_damage)
		_apply_accumulated_damage(ctx)
	# Then play attack animations (after damage so positions are correct)
	for entry in entries:
		var attacker = entry.unit
		if not _valid_unit(attacker):
			continue
		var ac: ActionInstance = entry.ac
		var action_key: String = ac.definition.action_key if ac.definition else ""
		var is_passive: bool = action_key in attacker.def.passive_action_keys
		var play_animation: bool = true
		if is_passive and not _would_attack_deal_damage(attacker, ac, ctx):
			play_animation = false
		print("[EXEC] _handle_attacks calling attack for ", attacker.def.name)
		attacker.attack(ac, play_animation)
		if play_animation:
			var done_flag: Array = [false]
			attacker.attack_complete.connect(func(): done_flag[0] = true, CONNECT_ONE_SHOT)
			var timeout := ctx.tree.create_timer(ATTACK_TIMEOUT)
			timeout.timeout.connect(func(): done_flag[0] = true, CONNECT_ONE_SHOT)
			while not done_flag[0]:
				await ctx.tree.process_frame
		print("[EXEC] _handle_attacks attack complete for ", attacker.def.name)

static func _apply_stun_effect(ctx: ExecutionContext, target_unit: Unit, duration: int) -> void:
	var effect := UnitEffect.new(UnitEffect.Kind.Stun, duration, {})
	target_unit.add_effect(effect)
	if ctx.apply_damage:
		var applied: Array = ctx.recording["applied_effects"] if ctx.recording.has("applied_effects") else []
		applied.append({ "unit_id": _recording_unit_id(target_unit), "effect": effect.to_dict() })
		ctx.recording["applied_effects"] = applied

static func _valid_unit(u) -> bool:
	return is_instance_valid(u) and u.is_active

static func _recording_unit_id(unit: Unit) -> int:
	if is_instance_valid(unit) and unit.has_meta("unit_id"):
		return int(unit.get_meta("unit_id"))
	return unit.get_instance_id()

## Applies accumulated damage (since last call) to units. Call after each attack phase.
## Updates ctx.applied_damage_by_id and ctx.recording.died_ids when units die.
static func _apply_accumulated_damage(ctx: ExecutionContext) -> void:
	print("[DAMAGE] _apply_accumulated_damage called, damage_by_id size=%d" % ctx.damage_by_id.size())
	for uid in ctx.damage_by_id:
		var already_applied: int = ctx.applied_damage_by_id[uid] if ctx.applied_damage_by_id.has(uid) else 0
		var total_damage: int = ctx.damage_by_id[uid]
		var to_apply: int = total_damage - already_applied
		if to_apply <= 0:
			continue
		var unit = instance_from_id(uid)
		if not is_instance_valid(unit) or not unit is Unit:
			print("[DAMAGE] skip uid %d (invalid or not Unit)" % uid)
			continue
		var old_health: int = unit.health
		unit.health = unit.health - to_apply  # Explicit assign so setter runs
		print("[DAMAGE] applied %d to %s (uid %d) health %d -> %d" % [to_apply, unit.def.name if unit.def else "?", uid, old_health, unit.health])
		if unit.health_bar:
			unit.health_bar.update_value(unit.health)
		ctx.applied_damage_by_id[uid] = total_damage
		if ctx.apply_damage and unit.health <= 0:
			var died_ids: Array = ctx.recording["died_ids"] if ctx.recording.has("died_ids") else []
			if uid not in died_ids:
				died_ids.append(uid)
				ctx.recording["died_ids"] = died_ids

## Returns true if the attack would damage any enemy (used to skip passive attack animation when no damage).
static func _would_attack_deal_damage(attacker, ac: ActionInstance, ctx: ExecutionContext) -> bool:
	var config: Dictionary = Actions.get_action_config(ac.definition.action_key) if ac.definition else {}
	var full_path: Array = get_damage_cells(attacker.cell, ac, config)
	var attacker_group: Node = attacker.get_parent()
	for cell in full_path:
		for group in ctx.groups:
			for child in group.get_children():
				if child is Unit and HexGrid.cell_equal(child.cell, cell) and child != attacker:
					if child.get_parent() == attacker_group:
						continue
					return true
	var aoe: Dictionary = config["area_of_effect"] if config.has("area_of_effect") else {}
	if not aoe.is_empty():
		var from_cell: Vector2 = attacker.cell
		var target_cell: Vector2 = ac.end_point
		var aoe_cells: Array = HexGrid.get_aoe_tiles(from_cell, target_cell, aoe)
		for aoe_cell in aoe_cells:
			for group in ctx.groups:
				for child in group.get_children():
					if child is Unit and HexGrid.cell_equal(child.cell, aoe_cell) and child != attacker:
						if child.get_parent() == attacker_group:
							continue
						return true
	return false

## Replay is done by building actions_by_type from the recording and calling run_pipeline
## with apply_damage=false and phase_callback=refresh_fog (see units.gd _replay_last_turn).
