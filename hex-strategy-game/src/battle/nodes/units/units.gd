class_name UnitsContainer
extends Node2D

const BattlePhase = preload("res://src/battle/battle_phase.gd")
const TurnExecutor = preload("res://src/battle/turn_executor.gd")
const TurnExecutionCore = preload("res://src/battle/turn_execution_core.gd")
const PlanningAI = preload("res://src/battle/ai/planning_ai.gd")
const UNIT_SCENE := preload("res://src/unit/unit.tscn")

var groups: Array = []
var ai_group_names: Array[String] = []
## In multiplayer, only units in this group can be controlled (e.g. "player" or "opponent").
var multiplayer_my_group: String = ""
var battle_phase: BattlePhase.Phase = BattlePhase.Phase.PLANNING
var planning_unit_index: int = 0
var current_unit: Unit
var current_acs: Array  # Array of { ac: ActionInstance, is_move: bool }
var selected_action_key: String = ""
var turn_number: int = 1

var last_turn_recording: Dictionary = {}  # { actions: [], died_ids: [], summary: [] }

func _ready() -> void:
	_refresh_groups()
	EventBus.execute_turn_requested.connect(_on_execute_turn_requested)
	EventBus.replay_turn_requested.connect(_on_replay_turn_requested)
	EventBus.unit_pick_requested.connect(_on_unit_pick_requested)
	EventBus.action_key_selected.connect(_on_action_key_selected)

func _on_action_key_selected(action_key: String) -> void:
	selected_action_key = action_key
	_build_combined_acs()
	# Auto-commit if exactly one option and it's a self-target (e.g. Rest) - no tile click needed
	if current_unit and current_acs.size() == 1:
		var entry = current_acs[0]
		if HexGrid.cell_equal(entry.ac.end_point, current_unit.cell):
			_store_planned_action(current_unit, entry.ac, entry.is_move)
			_advance_planning()
			selected_action_key = ""
			EventBus.action_key_selected.emit("")

func _on_execute_turn_requested() -> void:
	if battle_phase != BattlePhase.Phase.PLANNING or not _all_units_have_planned_action():
		return
	if MultiplayerState.is_multiplayer:
		_submit_actions_to_server()
		return
	_execute_planned_actions()

func _refresh_groups() -> void:
	groups.clear()
	for child in get_children():
		groups.append(child)

## Apply a scenario: clear group children and spawn units from scenario spec.
func apply_scenario(scenario: Dictionary) -> void:
	if scenario.is_empty():
		return
	ai_group_names.clear()
	var randomize_pos: bool = scenario.get("randomize_positions", false)
	for group_spec in scenario.get("groups", []):
		var group_name: String = group_spec.get("name", "")
		if group_spec.get("ai", false):
			ai_group_names.append(group_name)
		var group_node := get_node_or_null(group_name)
		if group_node == null:
			group_node = Node2D.new()
			group_node.name = group_name
			group_node.y_sort_enabled = true
			add_child(group_node)
		group_node.set_meta("resource_inventory", group_spec.get("resources", {}).duplicate(true))
		for c in group_node.get_children():
			group_node.remove_child(c)
			c.queue_free()
		var units_list: Array = group_spec.get("units", [])
		var cell_pool: Array = group_spec.get("cell_pool", [])
		if randomize_pos and cell_pool.size() >= units_list.size():
			cell_pool = cell_pool.duplicate()
			cell_pool.shuffle()
		for i in units_list.size():
			var u_spec = units_list[i]
			var def_path: String = u_spec.get("def_path", "") if u_spec is Dictionary else ""
			if def_path.is_empty():
				continue
			var cell: Vector2i
			if randomize_pos and i < cell_pool.size():
				cell = cell_pool[i] if cell_pool[i] is Vector2i else Vector2i(cell_pool[i].x, cell_pool[i].y)
			elif u_spec is Dictionary and u_spec.has("cell"):
				cell = u_spec.get("cell", Vector2i.ZERO)
			else:
				cell = Vector2i.ZERO
			var def: UnitDefinition = load(def_path) as UnitDefinition
			if def == null:
				continue
			var unit: Unit = UNIT_SCENE.instantiate() as Unit
			unit.def = def
			unit.starting_cell = cell
			group_node.add_child(unit)
	_refresh_groups()

## Build board from server game state (multiplayer). Sets unit_id on each unit for submit_actions.
func apply_multiplayer_state(state: Dictionary) -> void:
	if state.is_empty():
		return
	ai_group_names.clear()
	for g in state.get("groups", []):
		var group_name: String = str(g.get("name", ""))
		if g.get("ai", false):
			ai_group_names.append(group_name)
		var group_node := get_node_or_null(group_name)
		if group_node == null:
			group_node = Node2D.new()
			group_node.name = group_name
			group_node.y_sort_enabled = true
			add_child(group_node)
		group_node.set_meta("resource_inventory", g.get("resources", {}).duplicate(true))
		for c in group_node.get_children():
			group_node.remove_child(c)
			c.queue_free()
		for u_spec in g.get("units", []):
			var def_path: String = str(u_spec.get("def_path", ""))
			if def_path.is_empty():
				continue
			var cell_arr: Array = u_spec.get("cell", [0, 0])
			var cell: Vector2i = Vector2i(int(cell_arr[0]), int(cell_arr[1])) if cell_arr.size() >= 2 else Vector2i.ZERO
			var def: UnitDefinition = load(def_path) as UnitDefinition
			if def == null:
				continue
			var unit: Unit = UNIT_SCENE.instantiate() as Unit
			unit.def = def
			unit.starting_cell = cell
			unit.max_health = int(u_spec.get("max_health", def.max_health))
			unit.health = int(u_spec.get("health", unit.max_health))
			unit.max_energy = int(u_spec.get("max_energy", def.max_energy))
			unit.energy = int(u_spec.get("energy", unit.max_energy))
			unit.set_meta("unit_id", int(u_spec.get("unit_id", 0)))
			group_node.add_child(unit)
	_refresh_groups()

## Update unit positions and stats from server state (after turn execution). Remove dead units. Then start next planning.
func apply_server_state(state: Dictionary) -> void:
	var groups_ser: Array = state.get("groups", [])
	for g in groups_ser:
		var group_name: String = str(g.get("name", ""))
		var group_node = get_node_or_null(group_name)
		if group_node == null:
			continue
		group_node.set_meta("resource_inventory", g.get("resources", {}).duplicate(true))
		var live_ids: Array[int] = []
		for u_spec in g.get("units", []):
			var unit_id: int = int(u_spec.get("unit_id", 0))
			live_ids.append(unit_id)
			var cell_arr: Array = u_spec.get("cell", [0, 0])
			var cell: Vector2i = Vector2i(int(cell_arr[0]), int(cell_arr[1])) if cell_arr.size() >= 2 else Vector2i.ZERO
			var health: int = int(u_spec.get("health", 0))
			var energy: int = int(u_spec.get("energy", 0))
			for child in group_node.get_children():
				if not child is Unit:
					continue
				if not child.has_meta("unit_id") or child.get_meta("unit_id") != unit_id:
					continue
				child.global_position = Navigation.cell_to_world(Vector2(cell.x, cell.y), true)
				child.health = health
				child.energy = energy
				if child.energy_bar and child.max_energy > 0:
					child.energy_bar.update_value(energy)
				break
		# Remove units no longer in server state (dead)
		var to_remove: Array[Node] = []
		for child in group_node.get_children():
			if not child is Unit:
				continue
			if not child.has_meta("unit_id"):
				continue
			var uid: int = child.get_meta("unit_id")
			if uid not in live_ids:
				to_remove.append(child)
		for node in to_remove:
			node.queue_free()
	var hex_map_for_resources = get_parent().get_node_or_null("hex_map")
	if hex_map_for_resources and hex_map_for_resources.has_method("apply_tile_resource_state"):
		var tile_resources = state.get("tile_resources", {})
		if tile_resources is Dictionary and not tile_resources.is_empty():
			hex_map_for_resources.apply_tile_resource_state(tile_resources)
	turn_number = int(state.get("turn", 1))
	EventBus.turn_changed.emit(turn_number)
	_clear_all_planned_actions()
	# Refresh fog from current unit positions (per-player vision in multiplayer).
	var hex_map_node = get_parent().get_node_or_null("hex_map")
	if hex_map_node and hex_map_node.has_method("refresh_fog"):
		hex_map_node.refresh_fog()
	_begin_planning()

func _submit_actions_to_server() -> void:
	var actions: Array = []
	for u in get_active_units():
		if u.planned_action == null:
			continue
		var ac = u.planned_action
		var unit_id: int = u.get_meta("unit_id", 0) if u.has_meta("unit_id") else 0
		var action_key: String = ac.definition.action_key if ac.definition else ""
		var path_arr: Array = []
		for p in ac.path:
			path_arr.append([int(p.x), int(p.y)])
		# Server expects path to include end cell for move actions (full_path = path + [end], full_path.size() == build_path_to.size() + 1).
		var atype: String = Actions.get_action_type(action_key) if action_key else ""
		if atype in ["fast move", "move", "slow move"]:
			path_arr.append([int(ac.end_point.x), int(ac.end_point.y)])
		var end_arr: Array = [int(ac.end_point.x), int(ac.end_point.y)]
		actions.append({ unit_id = unit_id, action_key = action_key, path = path_arr, end_point = end_arr })
	var gs = get_node_or_null("/root/GameServer")
	if gs == null:
		return
	var msg: Dictionary = { type = "submit_actions", actions = actions }
	if MultiplayerState.is_host:
		if gs.has_method("receive_host_packet"):
			gs.receive_host_packet(msg)
	else:
		gs.server_receive_packet.rpc_id(1, msg)
	# Button stays disabled until server sends game_state (turn executed)

func start_battle() -> void:
	turn_number = 1
	battle_phase = BattlePhase.Phase.PLANNING
	_clear_all_planned_actions()
	last_turn_recording = {}
	EventBus.turn_changed.emit(turn_number)
	EventBus.replay_available_changed.emit(false)
	_begin_planning()

func get_active_units() -> Array[Unit]:
	var units: Array[Unit] = []
	for group in groups:
		if not multiplayer_my_group.is_empty() and group.name != multiplayer_my_group:
			continue
		for child in group.get_children():
			if child is Unit and child.is_active:
				units.append(child)
	return units

func get_all_units() -> Array[Unit]:
	var units: Array[Unit] = []
	for group in groups:
		for child in group.get_children():
			if child is Unit:
				units.append(child)
	return units

func _clear_all_planned_actions() -> void:
	for u in get_active_units():
		u.planned_action = null

func _unhandled_input(event: InputEvent) -> void:
	if battle_phase == BattlePhase.Phase.EXECUTING:
		return

	if event is InputEventMouseMotion:
		var cell = Navigation.world_to_cell(get_global_mouse_position())
		var match_ac = null
		for entry in current_acs:
			if HexGrid.cell_equal(cell, entry.ac.end_point):
				match_ac = entry.ac
				break
		var from_cell := current_unit.cell if current_unit else Vector2.ZERO
		EventBus.show_move_path.emit(match_ac, from_cell)

	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var cell = Navigation.world_to_cell(get_global_mouse_position())
		for entry in current_acs:
			if HexGrid.cell_equal(cell, entry.ac.end_point):
				_store_planned_action(current_unit, entry.ac, entry.is_move)
				_advance_planning()
				return
		# No action selected: allow clicking a unit to select it for planning
		if selected_action_key.is_empty():
			var units_at_cell = _get_units_at_cell_for_planning(cell)
			if units_at_cell.size() > 1:
				EventBus.show_units_panel.emit(units_at_cell)
			elif units_at_cell.size() == 1:
				EventBus.show_units_panel.emit([])  # Hide unit selector when picking single unit
				_select_unit_for_planning(units_at_cell[0])
				return
			else:
				EventBus.show_units_panel.emit([])  # Hide unit selector when clicking off (empty tile)

	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER:
			if _all_units_have_planned_action():
				_execute_planned_actions()
		elif event.keycode == KEY_TAB:
			_cycle_planning_unit(1 if not event.shift_pressed else -1)

func _store_planned_action(unit: Unit, ac: ActionInstance, is_move: bool) -> void:
	unit.planned_action = ac
	unit.planned_action_is_move = is_move

func _all_units_have_planned_action() -> bool:
	var active = get_active_units()
	if active.is_empty():
		return false
	for u in active:
		if u.planned_action == null:
			return false
	return true

func _begin_planning() -> void:
	battle_phase = BattlePhase.Phase.PLANNING
	_clear_all_planned_actions()
	planning_unit_index = 0
	EventBus.planning_started.emit()
	_select_planning_unit()

func _get_unit_at_cell(cell: Vector2) -> Unit:
	var units = _get_units_at_cell_for_planning(cell)
	return units[0] if units.size() > 0 else null

## Returns all active units at cell (player + opponent) for planning/selection.
func _get_units_at_cell_for_planning(cell: Vector2) -> Array:
	var result: Array = []
	for u in get_active_units():
		if HexGrid.cell_equal(u.cell, cell):
			result.append(u)
	return result

func _select_unit_for_planning(unit: Unit) -> void:
	var active = get_active_units()
	var idx = active.find(unit)
	if idx >= 0:
		planning_unit_index = idx
		_select_planning_unit()
		if _all_units_have_planned_action():
			EventBus.planning_complete.emit()

func _cycle_planning_unit(delta: int) -> void:
	var active = get_active_units()
	if active.is_empty():
		return
	planning_unit_index = wrapi(planning_unit_index + delta, 0, active.size())
	_select_planning_unit()
	if _all_units_have_planned_action():
		EventBus.planning_complete.emit()

func _advance_planning() -> void:
	var active = get_active_units()
	if active.is_empty():
		return
	# Find next unit without a planned action (wrap from current index)
	var start_idx := planning_unit_index + 1
	for i in active.size():
		var idx := (start_idx + i) % active.size()
		if active[idx].planned_action == null:
			planning_unit_index = idx
			_select_planning_unit()
			return
		# All units have planned actions - clear highlights before completing
		current_unit = null
		current_acs = []
		selected_action_key = ""
		EventBus.unit_selected_for_planning.emit(null)
		_update_highlights()
		EventBus.planning_complete.emit()

func _select_planning_unit() -> void:
	var active = get_active_units()
	if active.is_empty():
		current_unit = null
		current_acs = []
		selected_action_key = ""
		_update_highlights()
		EventBus.unit_selected_for_planning.emit(null)
		return
	current_unit = active[planning_unit_index]
	var unit_group_name: String = current_unit.get_parent().name if current_unit.get_parent() else ""
	if unit_group_name in ai_group_names:
		_run_ai_planning()
		return
	selected_action_key = ""
	EventBus.unit_selected_for_planning.emit(current_unit)
	_build_combined_acs()

func _run_ai_planning() -> void:
	var entry = PlanningAI.pick_action(current_unit, groups, _get_units_at_cell_for_planning)
	if entry.is_empty():
		# No valid action (shouldn't happen) - pick Rest if available
		var options = current_unit.abilities_db.get_options_for_action_key("reload")
		if options.is_empty():
			for key in current_unit.def.move_action_keys:
				options = current_unit.abilities_db.get_options_for_action_key(key)
				if not options.is_empty():
					break
		if not options.is_empty():
			entry = options[0]
	if not entry.is_empty():
		_store_planned_action(current_unit, entry.ac, entry.is_move)
	_advance_planning()

func _build_combined_acs() -> void:
	current_acs = []
	if current_unit == null:
		_update_highlights()
		return
	# Only show options when an action is selected
	if not selected_action_key.is_empty():
		var options = current_unit.abilities_db.get_options_for_action_key(selected_action_key)
		current_acs.assign(options)
	_update_highlights()

func _update_highlights() -> void:
	EventBus.show_move_path.emit(null, Vector2.ZERO)
	if current_unit != null:
		EventBus.show_selected_unit_cell.emit(current_unit.cell)
	else:
		EventBus.show_selected_unit_cell.emit(null)
	if current_acs.is_empty():
		EventBus.show_move_acs.emit([])
		EventBus.show_attack_acs.emit([], Vector2.ZERO)
		return
	var move_acs: Array = []
	var attack_acs: Array = []
	for entry in current_acs:
		if entry.is_move:
			move_acs.append(entry.ac)
		else:
			attack_acs.append(entry.ac)
	EventBus.show_move_acs.emit(move_acs)
	EventBus.show_attack_acs.emit(attack_acs, current_unit.cell)

func _finish_turn_after_execution() -> void:
	print("[EXEC] _finish_turn_after_execution START turn=", turn_number)
	for u in get_all_units():
		if is_instance_valid(u) and u is Unit and u.is_active:
			u.tick_effects()
	# Refresh fog of war after units have moved
	var hex_map_node = get_parent().get_node_or_null("hex_map")
	if hex_map_node and hex_map_node.has_method("refresh_fog"):
		hex_map_node.refresh_fog()
	_clear_all_planned_actions()
	turn_number += 1
	print("[EXEC] _finish_turn_after_execution DONE, starting turn ", turn_number)
	EventBus.turn_changed.emit(turn_number)
	EventBus.replay_available_changed.emit(true)
	_begin_planning()

## Build dictionary game_state from live Unit nodes for TurnExecutionCore.
## Assigns unit_id = instance_id on units that don't have it (SP).
func _build_game_state_from_scene() -> Dictionary:
	var groups_arr: Array = []
	for group in groups:
		if not group is Node2D:
			continue
		var g_dict: Dictionary = {
			"name": group.name,
			"ai": group.name in ai_group_names,
			"units": [],
			"resources": {}
		}
		if group.has_meta("resource_inventory"):
			var inv = group.get_meta("resource_inventory")
			if inv is Dictionary:
				g_dict["resources"] = inv.duplicate(true)
		for child in group.get_children():
			if not child is Unit:
				continue
			var u: Unit = child
			if not u.has_meta("unit_id"):
				u.set_meta("unit_id", u.get_instance_id())
			var unit_id: int = u.get_meta("unit_id")
			var cell_arr: Array = [u.cell.x, u.cell.y]
			g_dict.units.append({
				"unit_id": unit_id,
				"def_path": u.def.resource_path if u.def else "",
				"cell": cell_arr,
				"health": u.health,
				"max_health": u.max_health,
				"energy": u.energy,
				"max_energy": u.max_energy,
				"is_active": u.is_active
			})
		groups_arr.append(g_dict)
	var out_state: Dictionary = { "groups": groups_arr }
	var hex_map_node = get_parent().get_node_or_null("hex_map")
	if hex_map_node and hex_map_node.has_method("get_tile_resource_state"):
		out_state["tile_resources"] = hex_map_node.get_tile_resource_state()
	return out_state

## Build player_actions from planned actions and passives for all groups.
func _build_player_actions_from_units(game_state: Dictionary) -> Dictionary:
	var player_actions: Dictionary = {}
	for group in groups:
		if not group is Node2D:
			continue
		var gname: String = group.name
		player_actions[gname] = []
		for child in group.get_children():
			if not child is Unit or not child.is_active:
				continue
			var u: Unit = child
			var unit_id: int = u.get_meta("unit_id", u.get_instance_id()) if u.has_meta("unit_id") else u.get_instance_id()
			if u.planned_action != null:
				var ac: ActionInstance = u.planned_action
				var action_key: String = ac.definition.action_key if ac.definition else ""
				var path_arr: Array = []
				for p in ac.path:
					path_arr.append([int(p.x), int(p.y)])
				var end_arr: Array = [int(ac.end_point.x), int(ac.end_point.y)]
				var atype: String = Actions.get_action_type(action_key) if action_key else ""
				if atype in ["fast move", "move", "slow move"]:
					path_arr.append(end_arr)
				player_actions[gname].append({
					"unit_id": unit_id,
					"action_key": action_key,
					"path": path_arr,
					"end_point": end_arr
				})
	return player_actions

func _execute_planned_actions() -> void:
	print("[EXEC] _execute_planned_actions START")
	battle_phase = BattlePhase.Phase.EXECUTING
	EventBus.unit_selected_for_planning.emit(null)
	EventBus.show_selected_unit_cell.emit(null)
	EventBus.show_move_path.emit(null, Vector2.ZERO)
	EventBus.show_move_acs.emit([])
	var game_state := _build_game_state_from_scene()
	var player_actions := _build_player_actions_from_units(game_state)
	var recording := TurnExecutionCore.execute_turn(game_state, player_actions)
	await play_resolved_turn(recording, game_state)
	for u in get_all_units():
		if is_instance_valid(u) and u is Unit and u.is_active:
			u.tick_effects()
	var state := game_state.duplicate()
	state["turn"] = turn_number
	apply_server_state(state)
	print("[EXEC] SP turn execution DONE")

func _record_turn_before_execution() -> void:
	last_turn_recording = { "actions": [], "died_ids": [], "summary": [], "before_state": {}, "damage_causers": {}, "applied_effects": [] }
	var active = get_active_units()
	for u in active:
		var s: Dictionary = { "cell": u.cell, "health": u.health }
		if u.max_energy > 0:
			s["energy"] = u.energy
		var effects_data: Array = []
		for e in u.active_effects:
			if e is UnitEffect:
				effects_data.append(e.to_dict())
		s["effects"] = effects_data
		last_turn_recording.before_state[u.get_instance_id()] = s
	for u in active:
		if not u.is_active:
			continue
		if u.planned_action != null:
			var ac: ActionInstance = u.planned_action
			var action_name: String = ac.definition.display_name if ac.definition.display_name else "Action"
			var atype: String = Actions.get_action_type(ac.definition.action_key) if ac.definition else ""
			last_turn_recording.summary.append({ "unit_name": u.def.name, "action_name": action_name, "instance_id": u.get_instance_id(), "action_type": atype })
		for def in u.def.get_passive_ability_definitions_resolved():
			var action_name: String = def.display_name if def.display_name else "Passive"
			var atype: String = Actions.get_action_type(def.action_key)
			last_turn_recording.summary.append({ "unit_name": u.def.name, "action_name": action_name, "instance_id": u.get_instance_id(), "action_key": def.action_key, "is_passive": true, "action_type": atype })

func _filter_passive_summary_entries() -> void:
	var causers: Dictionary = last_turn_recording.get("damage_causers", {})
	var filtered: Array = []
	for entry in last_turn_recording.summary:
		if entry.get("is_passive", false):
			var key := "%d_%s" % [entry.instance_id, entry.get("action_key", "")]
			if not causers.get(key, false):
				continue
		filtered.append(entry)
	last_turn_recording.summary = filtered

func _on_unit_pick_requested(unit: Unit) -> void:
	_select_unit_for_planning(unit)

func _on_replay_turn_requested() -> void:
	if battle_phase != BattlePhase.Phase.PLANNING or last_turn_recording.is_empty():
		return
	var summary_lines: Array = []
	var died_ids: Array = last_turn_recording.get("died_ids", [])
	var summary: Array = last_turn_recording.get("summary", [])
	var before_state: Dictionary = last_turn_recording.get("before_state", {})
	var damage_by_id: Dictionary = last_turn_recording.get("damage_by_id", {})

	for action_type in Actions.ACTION_ORDER:
		var entries_in_phase: Array = []
		for entry in summary:
			if entry.get("action_type", "") == action_type:
				entries_in_phase.append(entry)
		if entries_in_phase.is_empty():
			continue
		summary_lines.append("")
		summary_lines.append(_phase_display_name(action_type))
		for entry in entries_in_phase:
			var suffix := " (eliminated)" if entry.instance_id in died_ids else ""
			summary_lines.append("  %s: %s%s" % [entry.unit_name, entry.action_name, suffix])

	summary_lines.append("")
	summary_lines.append("Units damaged")
	if damage_by_id.is_empty():
		summary_lines.append("  None")
	else:
		for uid in damage_by_id:
			var start_hp: int = before_state.get(uid, {}).get("health", 0)
			var damage: int = damage_by_id[uid]
			var end_hp: int = mini(maxi(start_hp - damage, 0), 999)
			var unit_name: String = "Unit"
			var unit = instance_from_id(uid as int)
			if is_instance_valid(unit) and unit is Unit:
				unit_name = unit.def.name
			var elim := " (eliminated)" if end_hp <= 0 else ""
			summary_lines.append("  %s: %d HP → %d (-%d)%s" % [unit_name, start_hp, end_hp, damage, elim])

	if summary_lines.size() > 0 and summary_lines[0] == "":
		summary_lines.remove_at(0)
	EventBus.show_replay_summary.emit(summary_lines)
	_replay_last_turn()

func _phase_display_name(action_type: String) -> String:
	if action_type.is_empty():
		return "Other"
	var parts: PackedStringArray = action_type.split(" ")
	for i in parts.size():
		if parts[i].length() > 0:
			parts[i] = parts[i].left(1).to_upper() + parts[i].substr(1)
	return " ".join(parts)

func _replay_last_turn() -> void:
	battle_phase = BattlePhase.Phase.EXECUTING
	EventBus.unit_selected_for_planning.emit(null)
	EventBus.show_selected_unit_cell.emit(null)
	EventBus.show_move_path.emit(null, Vector2.ZERO)
	_restore_before_state(last_turn_recording.get("before_state", {}))
	var hex_map_node = get_parent().get_node_or_null("hex_map")
	var actions_by_type := _build_replay_actions_by_type(last_turn_recording.get("actions", []))
	var ctx := TurnExecutor.ExecutionContext.new(
		groups,
		false,
		{},
		_get_units_at_cell_for_planning,
		get_tree()
	)
	if hex_map_node and hex_map_node.has_method("refresh_fog"):
		ctx.phase_callback = hex_map_node.refresh_fog
	await TurnExecutor.run_pipeline(actions_by_type, ctx)
	var damage_by_id: Dictionary = last_turn_recording.get("damage_by_id", {})
	for uid_key in damage_by_id:
		var uid: int = int(uid_key)
		var unit = instance_from_id(uid)
		if is_instance_valid(unit):
			var dmg: int = int(damage_by_id[uid_key])
			unit.health -= dmg
			if unit.health_bar:
				unit.health_bar.update_value(unit.health)
	var applied_effects: Array = last_turn_recording.get("applied_effects", [])
	for entry in applied_effects:
		var unit = instance_from_id(entry.get("unit_id", 0) as int)
		if is_instance_valid(unit) and unit is Unit:
			var eff := UnitEffect.from_dict(entry.get("effect", {}))
			unit.add_effect(eff)
	var units_that_will_die: Array = []
	for uid in damage_by_id:
		var unit = instance_from_id(uid as int)
		if is_instance_valid(unit) and unit.health <= 0:
			units_that_will_die.append(unit)
	var to_await := units_that_will_die.filter(func(u): return is_instance_valid(u))
	if not to_await.is_empty():
		var completed_arr := [0]
		var total := to_await.size()
		for unit in to_await:
			unit.death_animation_complete.connect(func(): completed_arr[0] += 1, CONNECT_ONE_SHOT)
		var timeout := get_tree().create_timer(5.0)
		while completed_arr[0] < total:
			await get_tree().process_frame
			if timeout.time_left <= 0:
				for u in to_await:
					if is_instance_valid(u):
						u.visible = false
				break
	await get_tree().process_frame
	battle_phase = BattlePhase.Phase.PLANNING
	if hex_map_node and hex_map_node.has_method("refresh_fog"):
		hex_map_node.refresh_fog()
	EventBus.replay_finished.emit()

## Builds actions_by_type from recorded actions so replay uses the same run_pipeline as live execution.
func _build_replay_actions_by_type(recording_actions: Array) -> Dictionary:
	var actions_by_type: Dictionary = {}
	for t in Actions.ACTION_ORDER:
		actions_by_type[t] = []
	for action in recording_actions:
		var atype: String = action.get("type", "")
		if atype.is_empty():
			continue
		# Map legacy recording types to phase names
		if atype == "attack" or atype == "support":
			atype = "ability"
		elif atype == "fast attack":
			atype = "fast ability"
		elif atype == "slow attack":
			atype = "slow ability"
		elif atype == "reload":
			atype = "slow ability"
		var u = action.get("unit")
		if not is_instance_valid(u) or not u is Unit:
			continue
		var entry: Dictionary = { "unit": u, "is_move": (atype == "move") }
		if atype == "move":
			var path: Array = action.get("path", [])
			if path.is_empty():
				continue
			var ac := ActionInstance.new(null, u)
			ac.path = path.slice(0, path.size() - 1)
			ac.end_point = path[path.size() - 1]
			entry["ac"] = ac
		else:
			entry["ac"] = action.get("ac")
			if entry["ac"] == null and action.get("type", "") == "reload":
				var defs: Array = Actions.get_ability_definitions_for_action("reload")
				if not defs.is_empty():
					entry["ac"] = defs[0].to_action_instance(u)
			if entry["ac"] == null:
				continue
		if not actions_by_type.has(atype):
			actions_by_type[atype] = []
		actions_by_type[atype].append(entry)
	return actions_by_type

func _restore_before_state(before_state: Dictionary) -> void:
	for uid in before_state:
		var unit = instance_from_id(uid as int)
		if is_instance_valid(unit) and unit is Unit:
			var s: Dictionary = before_state[uid]
			var energy_val: int = s.get("energy", -1)
			var effects_data: Array = s.get("effects", [])
			unit.restore_state(s.cell, s.health, energy_val, effects_data)

## Restore to start of last turn (for future undo). Same as replay restore but without re-executing.
func undo_last_turn() -> void:
	if last_turn_recording.is_empty():
		return
	_restore_before_state(last_turn_recording.get("before_state", {}))
	for u in get_all_units():
		u.planned_action = null

func _run_planned_actions_phase3() -> void:
	print("[EXEC] _run_planned_actions_phase3 START")
	var actions_by_type := _collect_actions(get_active_units())
	var ctx := TurnExecutor.ExecutionContext.new(
		groups,
		true,
		last_turn_recording,
		_get_units_at_cell_for_planning,
		get_tree()
	)
	await TurnExecutor.run_pipeline(actions_by_type, ctx)
	print("[EXEC] pipeline DONE")

	# Damage was already applied after each attack phase in the pipeline; died_ids populated there
	last_turn_recording["damage_by_id"] = ctx.damage_by_id.duplicate()
	_filter_passive_summary_entries()
	var units_that_will_die: Array = []
	for u in get_all_units():
		if u.health <= 0:
			units_that_will_die.append(u)

	var to_await := units_that_will_die.filter(func(u): return is_instance_valid(u))
	if not to_await.is_empty():
		var completed_arr := [0]
		var total := to_await.size()
		for unit in to_await:
			unit.death_animation_complete.connect(func(): completed_arr[0] += 1, CONNECT_ONE_SHOT)
		var timeout := get_tree().create_timer(5.0)
		while completed_arr[0] < total:
			await get_tree().process_frame
			if timeout.time_left <= 0:
				for u in to_await:
					if is_instance_valid(u):
						u.visible = false
				break
	print("[EXEC] death anims DONE")
	await get_tree().process_frame
	print("[EXEC] after process_frame")
	var active := get_active_units()
	print("[EXEC] clearing planned_action for ", active.size(), " units")
	for u in active:
		u.planned_action = null
	print("[EXEC] planned_action cleared")

## Build summary entries from pipeline recording.actions for replay display.
func _build_summary_from_recording_actions(recording_actions: Array) -> Array:
	var summary: Array = []
	for action in recording_actions:
		if not action is Dictionary:
			continue
		var u = action.get("unit")
		if not is_instance_valid(u) or not u is Unit:
			continue
		var atype: String = str(action.get("type", ""))
		var action_name: String = "Action"
		var action_key: String = ""
		var is_passive: bool = false
		var ac = action.get("ac")
		if ac is ActionInstance and ac.definition:
			action_name = ac.definition.display_name if ac.definition.display_name else "Action"
			action_key = ac.definition.action_key
			is_passive = action_key in u.def.passive_action_keys if u.def else false
		elif action.has("action_key"):
			action_key = str(action.get("action_key", ""))
			var cfg: Dictionary = Actions.get_action_config(action_key)
			action_name = cfg.get("name", "Action")
		elif atype == "move":
			action_name = "Move"
		var entry: Dictionary = {
			"unit_name": u.def.name if u.def else "Unit",
			"action_name": action_name,
			"instance_id": u.get_instance_id(),
			"action_type": atype
		}
		if is_passive:
			entry["is_passive"] = true
			entry["action_key"] = action_key
		summary.append(entry)
	return summary

## Build actions_by_type directly from server turn_result (dictionary recording) for multiplayer animation.
func _build_actions_by_type_from_server(turn_result: Dictionary) -> Dictionary:
	var actions_by_type: Dictionary = {}
	for t in Actions.ACTION_ORDER:
		actions_by_type[t] = []
	# Map unit_id -> Unit node using multiplayer unit_id meta set in apply_multiplayer_state
	var id_to_unit: Dictionary = {}
	for u in get_all_units():
		if u.has_meta("unit_id"):
			id_to_unit[int(u.get_meta("unit_id"))] = u
	var server_actions: Array = []
	if turn_result.has("actions"):
		server_actions = turn_result["actions"]
	for a in server_actions:
		if not (a is Dictionary):
			continue
		var atype: String = str(a.get("type", ""))
		if atype.is_empty():
			continue
		var uid: int = int(a.get("unit_id", -1))
		var unit = id_to_unit.get(uid)
		if unit == null:
			continue
		var entry: Dictionary = { "unit": unit, "is_move": (atype == "move") }
		if atype == "move":
			var path_spec: Array = a.get("path", [])
			var cells: Array[Vector2] = []
			for c in path_spec:
				if c is Array and c.size() >= 2:
					cells.append(Vector2(int(c[0]), int(c[1])))
			if cells.size() < 2:
				continue
			var ac := ActionInstance.new(null, unit)
			ac.path = cells.slice(0, cells.size() - 1)
			ac.end_point = cells[cells.size() - 1]
			entry["ac"] = ac
		else:
			var action_key: String = str(a.get("action_key", ""))
			if action_key.is_empty():
				continue
			var src = a.get("ac", {})
			var path_spec: Array = []
			var end_spec = null
			if src is Dictionary:
				if src.has("path"):
					path_spec = src["path"]
				if src.has("end_point"):
					end_spec = src["end_point"]
			if end_spec == null:
				end_spec = a.get("end_point", [0, 0])
			if path_spec.is_empty():
				path_spec = a.get("path", [])
			var ac_inst := ActionInstance.new(null, unit)
			var defs: Array = Actions.get_ability_definitions_for_action(action_key)
			if not defs.is_empty():
				ac_inst.definition = defs[0]
			var cells: Array[Vector2] = []
			for c in path_spec:
				if c is Array and c.size() >= 2:
					cells.append(Vector2(int(c[0]), int(c[1])))
			ac_inst.path = cells
			if end_spec is Array and end_spec.size() >= 2:
				ac_inst.end_point = Vector2(int(end_spec[0]), int(end_spec[1]))
			else:
				ac_inst.end_point = unit.cell
			entry["ac"] = ac_inst
		if not actions_by_type.has(atype):
			actions_by_type[atype] = []
		actions_by_type[atype].append(entry)
	return actions_by_type

## Animate a resolved turn using TurnExecutor and store recording for replay.
## Used by both single-player (core-produced recording) and multiplayer (server turn_result).
## final_state is the authoritative state after this turn (used for turn number and optional resync).
func play_resolved_turn(turn_result: Dictionary, final_state: Dictionary) -> void:
	if turn_result.is_empty():
		# Fallback: just snap to server state if we somehow have no recording.
		if not final_state.is_empty():
			apply_server_state(final_state)
		return
	print("[EXEC] play_resolved_turn START")
	# Snapshot before_state for replay/undo (same shape as _record_turn_before_execution, but includes all units).
	var before_state: Dictionary = {}
	for u in get_all_units():
		if not (is_instance_valid(u) and u is Unit):
			continue
		var s: Dictionary = { "cell": u.cell, "health": u.health }
		if u.max_energy > 0:
			s["energy"] = u.energy
		var effects_data: Array = []
		for e in u.active_effects:
			if e is UnitEffect:
				effects_data.append(e.to_dict())
		s["effects"] = effects_data
		before_state[u.get_instance_id()] = s

	var actions_by_type := _build_actions_by_type_from_server(turn_result)
	var recording := { "actions": [], "died_ids": [], "summary": [], "damage_causers": {}, "applied_effects": [] }
	var ctx := TurnExecutor.ExecutionContext.new(
		groups,
		true,
		recording,
		_get_units_at_cell_for_planning,
		get_tree()
	)
	var hex_map_node = get_parent().get_node_or_null("hex_map")
	if hex_map_node and hex_map_node.has_method("refresh_fog"):
		ctx.phase_callback = hex_map_node.refresh_fog

	battle_phase = BattlePhase.Phase.EXECUTING
	EventBus.unit_selected_for_planning.emit(null)
	EventBus.show_selected_unit_cell.emit(null)
	EventBus.show_move_path.emit(null, Vector2.ZERO)
	EventBus.show_move_acs.emit([])

	await TurnExecutor.run_pipeline(actions_by_type, ctx)
	print("[EXEC] pipeline DONE")

	# Store recording for replay: add before_state, damage_by_id, and summary.
	recording["before_state"] = before_state
	recording["damage_by_id"] = ctx.damage_by_id.duplicate()
	recording["summary"] = _build_summary_from_recording_actions(recording["actions"])
	last_turn_recording = recording
	_filter_passive_summary_entries()

	# Death animations (mirrors _run_planned_actions_phase3).
	var units_that_will_die: Array = []
	for u in get_all_units():
		if u.health <= 0:
			units_that_will_die.append(u)
	var to_await := units_that_will_die.filter(func(u): return is_instance_valid(u))
	if not to_await.is_empty():
		var completed_arr := [0]
		var total := to_await.size()
		for unit in to_await:
			unit.death_animation_complete.connect(func(): completed_arr[0] += 1, CONNECT_ONE_SHOT)
		var timeout := get_tree().create_timer(5.0)
		while completed_arr[0] < total:
			await get_tree().process_frame
			if timeout.time_left <= 0:
				for u in to_await:
					if is_instance_valid(u):
						u.visible = false
				break
	print("[EXEC] death anims DONE")
	await get_tree().process_frame

	# Turn bookkeeping and fog refresh.
	if not final_state.is_empty() and final_state.has("turn"):
		turn_number = int(final_state["turn"])
	else:
		turn_number += 1
	EventBus.turn_changed.emit(turn_number)
	if not final_state.is_empty() and final_state.has("tile_resources") and hex_map_node and hex_map_node.has_method("apply_tile_resource_state"):
		var tile_resources = final_state.get("tile_resources", {})
		if tile_resources is Dictionary and not tile_resources.is_empty():
			hex_map_node.apply_tile_resource_state(tile_resources)
	if hex_map_node and hex_map_node.has_method("refresh_fog"):
		hex_map_node.refresh_fog()
	_clear_all_planned_actions()
	battle_phase = BattlePhase.Phase.PLANNING
	EventBus.replay_available_changed.emit(true)
	_begin_planning()

## Collects planned + passive actions from units, grouped by type.
func _collect_actions(active: Array) -> Dictionary:
	var actions_by_type: Dictionary = {}
	for t in Actions.ACTION_ORDER:
		actions_by_type[t] = []
	for u in active:
		if not u.is_active:
			continue
		if u.planned_action != null:
			var ac: ActionInstance = u.planned_action
			var key: String = ac.definition.action_key if ac.definition else ""
			var atype: String = Actions.get_action_type(key)
			if not atype.is_empty():
				actions_by_type[atype] = actions_by_type.get(atype, []) + [{"unit": u, "ac": ac, "is_move": u.planned_action_is_move}]
		for def in u.def.get_passive_ability_definitions_resolved():
			var pac: ActionInstance = def.to_action_instance(u)
			var patype: String = Actions.get_action_type(def.action_key)
			if not patype.is_empty():
				actions_by_type[patype] = actions_by_type.get(patype, []) + [{"unit": u, "ac": pac, "is_move": false}]
	return actions_by_type

## Execute an arbitrary turn spec. Use for replays, tests, or custom scenarios.
## spec: { units: Array, positions: Dictionary, actions: Dictionary }
##   positions: optional, unit_id -> Vector2 cell. Units teleported before execution.
##   actions: optional, pre-built actions_by_type. If empty, uses units' planned_action + passives.
func execute_turn_spec(spec: Dictionary) -> Dictionary:
	var units: Array = spec.get("units", [])
	var positions: Dictionary = spec.get("positions", {})
	var actions_by_type: Dictionary = spec.get("actions", {})
	if actions_by_type.is_empty():
		actions_by_type = _collect_actions(units)
	for u in units:
		var uid = u.get_instance_id()
		if positions.has(uid):
			u.global_position = Navigation.cell_to_world(positions[uid], true)
	var recording := { "actions": [], "died_ids": [], "summary": [] }
	var ctx := TurnExecutor.ExecutionContext.new(
		groups,
		true,
		recording,
		_get_units_at_cell_for_planning,
		get_tree()
	)
	await TurnExecutor.run_pipeline(actions_by_type, ctx)
	# Damage already applied after each attack phase in pipeline; died_ids populated there
	var units_that_will_die: Array = []
	for u in units:
		if u.health <= 0:
			units_that_will_die.append(u)
	var to_await := units_that_will_die.filter(func(u): return is_instance_valid(u))
	if not to_await.is_empty():
		var completed_arr := [0]
		var total := to_await.size()
		for unit in to_await:
			unit.death_animation_complete.connect(func(): completed_arr[0] += 1, CONNECT_ONE_SHOT)
		while completed_arr[0] < total:
			await get_tree().process_frame
	await get_tree().process_frame
	for u in units:
		u.planned_action = null
	return recording
