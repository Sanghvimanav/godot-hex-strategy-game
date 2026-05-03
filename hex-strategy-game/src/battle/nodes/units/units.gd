class_name UnitsContainer
extends Node2D

const BattlePhase = preload("res://src/battle/battle_phase.gd")
const TurnExecutor = preload("res://src/battle/turn_executor.gd")
const TurnExecutionCore = preload("res://src/battle/turn_execution_core.gd")
const LlmPlanningSnapshot = preload("res://src/llm_ai/llm_planning_snapshot.gd")
const LlmPlanningPrompts = preload("res://src/llm_ai/llm_planning_prompts.gd")
const LlmPlanningResponseParser = preload("res://src/llm_ai/llm_planning_response_parser.gd")
const LlmPlanningPayloadLog = preload("res://src/llm_ai/llm_planning_payload_log.gd")
const DrillScriptAI = preload("res://src/battle/ai/drill_script_ai.gd")
const UNIT_SCENE := preload("res://src/unit/unit.tscn")
const MAX_REPLAY_TURN_HISTORY: int = 8

var groups: Array = []
var ai_group_names: Array[String] = []
## Drill training: group_name -> script_name. These groups are auto-planned by DrillScriptAI.
var drill_scripted_groups: Dictionary = {}
## Local human seat: faction group name. In multiplayer, only this group's units are controlled.
## In single-player, set to the human faction so fog-of-war and resource UI match that seat (same as MP).
var multiplayer_my_group: String = ""
var battle_phase: BattlePhase.Phase = BattlePhase.Phase.PLANNING
var planning_unit_index: int = 0
var current_unit: Unit
var current_acs: Array  # Array of { ac: ActionInstance, is_move: bool }
var selected_action_key: String = ""
var turn_number: int = 1

var last_turn_recording: Dictionary = {}  # { actions: [], died_ids: [], summary: [] }
var replay_turn_history: Array = []  # [{ turn: int, recording: Dictionary }]
## Every executed turn for the whole match (not capped); used for post-game LLM. Replay UI still uses replay_turn_history (last MAX_REPLAY_TURN_HISTORY).
var match_full_turn_history: Array = []

## Phase 2 LLM: legal option tables for current planning phase (unit_id -> Array of {ac, is_move}).
var _llm_option_tables: Dictionary = {}
var _llm_http: HTTPRequest
var _llm_openai: LlmOpenAiClient
var _llm_batch_running: bool = false
var _llm_batch_generation: int = 0
## Drill LLM-vs-LLM: separate HTTP node, client, and state so both batches can run concurrently.
var _drill_llm_http: HTTPRequest
var _drill_llm_openai: LlmOpenAiClient
var _drill_llm_running: bool = false
var _drill_llm_group_planned: Dictionary = {}  # group_name -> bool
## Responses API only: last successful response id for previous_response_id chaining across planning turns.
var _llm_previous_response_id: String = ""
## Set true when at least one AI action was applied from a validated LLM choice this match (Phase 3 gate).
var match_had_llm_validated_plan: bool = false
## Cached AI FOV and unit IDs from start of planning phase — stored with recordings for history filtering.
var _planning_phase_ai_fov: Dictionary = {}
var _planning_phase_ai_unit_ids: Array = []
## Enemy intel for LLM: initial count from scenario config, plus running kill tally.
var _ai_initial_enemy_count: int = 0
var _ai_confirmed_enemy_kills: int = 0
var _ai_killed_enemy_ids: Dictionary = {}
## Last-known enemy positions per perspective group. Keys: group_name -> {unit_id -> {cell, name, def_path, turn_seen}}.
## Initialized from scenario starting positions; updated each planning turn when enemies are visible.
var _ai_last_known_enemies: Dictionary = {}

func _ready() -> void:
	_llm_http = HTTPRequest.new()
	_llm_http.name = "LlmHttpRequest"
	add_child(_llm_http)
	_drill_llm_http = HTTPRequest.new()
	_drill_llm_http.name = "DrillLlmHttpRequest"
	add_child(_drill_llm_http)
	_llm_openai = LlmOpenAiClient.new()
	_drill_llm_openai = LlmOpenAiClient.new()
	_refresh_groups()
	EventBus.execute_turn_requested.connect(_on_execute_turn_requested)
	EventBus.replay_turn_requested.connect(_on_replay_turn_requested)
	EventBus.unit_pick_requested.connect(_on_unit_pick_requested)
	EventBus.action_key_selected.connect(_on_action_key_selected)
	EventBus.llm_retry_requested.connect(_on_llm_retry_requested)

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
	if _llm_batch_running:
		return
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


## Populate _ai_last_known_enemies from scenario starting positions so every group
## has a starting picture of where all other groups' units begin.
func _init_last_known_enemies() -> void:
	_ai_last_known_enemies.clear()
	var all_group_names: Array[String] = []
	for g in groups:
		all_group_names.append(str(g.name))
	for observer_name in all_group_names:
		var known: Dictionary = {}
		for g in groups:
			if str(g.name) == observer_name:
				continue
			for child in g.get_children():
				if not (child is Unit and child.is_active):
					continue
				var u: Unit = child
				var uid: int = LlmPlanningSnapshot._stable_unit_id(u)
				var ability_keys: Array = []
				if u.def:
					for ak in u.def.ability_action_keys:
						ability_keys.append(str(ak))
				known[uid] = {
					"cell": Vector2(u.cell.x, u.cell.y),
					"name": u.def.name if u.def else "unit",
					"def_path": u.def.resource_path if u.def else "",
					"health": u.health,
					"max_health": u.max_health,
					"ability_action_keys": ability_keys,
					"turn_seen": 0,
				}
		_ai_last_known_enemies[observer_name] = known


## Update last-known positions for a given observer group from a list of currently visible enemies.
## Called by the snapshot builder when computing visibility.
func update_last_known_enemies_for_group(observer_group: String, visible_enemies: Array) -> void:
	if not _ai_last_known_enemies.has(observer_group):
		_ai_last_known_enemies[observer_group] = {}
	var known: Dictionary = _ai_last_known_enemies[observer_group]
	for entry in visible_enemies:
		if not (entry is Dictionary):
			continue
		var uid: int = int(entry.get("unit_id", 0))
		if uid == 0:
			continue
		var cell_arr: Array = entry.get("cell", []) as Array
		var upd: Dictionary = {
			"cell": Vector2(int(cell_arr[0]) if cell_arr.size() >= 1 else 0,
							int(cell_arr[1]) if cell_arr.size() >= 2 else 0),
			"name": str(entry.get("name", "unit")),
			"def_path": str(entry.get("def", "")),
			"health": int(entry.get("health", 0)),
			"max_health": int(entry.get("max_health", 0)),
			"turn_seen": turn_number,
		}
		var vis_keys: Array = entry.get("ability_action_keys", []) as Array
		if not vis_keys.is_empty():
			upd["ability_action_keys"] = vis_keys
		known[uid] = upd


## Returns last-known enemy entries that are NOT in the currently visible set.
func get_nonvisible_known_enemies(observer_group: String, visible_unit_ids: Dictionary) -> Array:
	var result: Array = []
	var known: Dictionary = _ai_last_known_enemies.get(observer_group, {})
	for uid in known:
		if visible_unit_ids.has(uid):
			continue
		var entry: Dictionary = known[uid]
		var out_entry: Dictionary = {
			"unit_id": int(uid),
			"cell": [int(entry.cell.x), int(entry.cell.y)],
			"name": str(entry.get("name", "unit")),
			"def": str(entry.get("def_path", "")),
			"health": int(entry.get("health", 0)),
			"max_health": int(entry.get("max_health", 0)),
			"turn_last_seen": int(entry.get("turn_seen", 0)),
			"source": "last_known",
		}
		var stored_keys: Array = entry.get("ability_action_keys", []) as Array
		if not stored_keys.is_empty():
			out_entry["ability_action_keys"] = stored_keys
		result.append(out_entry)
	return result


func _apply_effects_from_state(unit: Unit, effects_data: Array) -> void:
	unit.active_effects.clear()
	for effect_dict in effects_data:
		if effect_dict is Dictionary:
			unit.active_effects.append(UnitEffect.from_dict(effect_dict))

## Apply a scenario: clear group children and spawn units from scenario spec.
func apply_scenario(scenario: Dictionary) -> void:
	if scenario.is_empty():
		return
	ai_group_names.clear()
	drill_scripted_groups.clear()
	var drill_config: Dictionary = scenario.get("drill", {})
	if not drill_config.is_empty():
		var scripted: Dictionary = drill_config.get("scripted_groups", {})
		for gname in scripted:
			drill_scripted_groups[str(gname)] = str(scripted[gname])
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
			if u_spec is Dictionary:
				if u_spec.has("health"):
					unit.health = clampi(int(u_spec.get("health", unit.max_health)), 0, unit.max_health)
					if unit.health_bar:
						unit.health_bar.update_value(unit.health)
				if u_spec.has("energy") and unit.max_energy > 0:
					unit.energy = clampi(int(u_spec.get("energy", unit.max_energy)), 0, unit.max_energy)
					if unit.energy_bar and unit.max_energy > 0:
						unit.energy_bar.update_value(unit.energy)
	_refresh_groups()
	_ai_initial_enemy_count = 0
	for group in groups:
		if group.name in ai_group_names:
			continue
		for child in group.get_children():
			if child is Unit:
				_ai_initial_enemy_count += 1
	_init_last_known_enemies()

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
			_apply_effects_from_state(unit, u_spec.get("effects", []))
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
			var effects_data: Array = u_spec.get("effects", [])
			var found: bool = false
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
				_apply_effects_from_state(child, effects_data)
				found = true
				break
			if not found:
				var def_path: String = str(u_spec.get("def_path", ""))
				if not def_path.is_empty():
					var def: UnitDefinition = load(def_path) as UnitDefinition
					if def != null:
						var unit: Unit = UNIT_SCENE.instantiate() as Unit
						unit.def = def
						unit.starting_cell = cell
						unit.health = int(u_spec.get("health", def.max_health))
						unit.max_health = int(u_spec.get("max_health", def.max_health))
						unit.energy = int(u_spec.get("energy", 0))
						unit.max_energy = int(u_spec.get("max_energy", def.max_energy))
						unit.set_meta("unit_id", unit_id)
						_apply_effects_from_state(unit, effects_data)
						group_node.add_child(unit)
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
	match_had_llm_validated_plan = false
	_llm_previous_response_id = ""
	_drill_llm_group_planned.clear()
	battle_phase = BattlePhase.Phase.PLANNING
	_clear_all_planned_actions()
	last_turn_recording = {}
	replay_turn_history.clear()
	match_full_turn_history.clear()
	_ai_confirmed_enemy_kills = 0
	_ai_killed_enemy_ids.clear()
	EventBus.turn_changed.emit(turn_number)
	EventBus.replay_available_changed.emit(false)
	EventBus.replay_history_changed.emit([], 0)
	_begin_planning()

func get_active_units() -> Array[Unit]:
	var units: Array[Unit] = []
	var filter_by_seat := MultiplayerState.is_multiplayer and not multiplayer_my_group.is_empty()
	for group in groups:
		if filter_by_seat and str(group.name) != multiplayer_my_group:
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

func _get_unit_stable_id(u: Unit) -> int:
	if not (is_instance_valid(u) and u is Unit):
		return 0
	if u.has_meta("unit_id"):
		return int(u.get_meta("unit_id"))
	return u.get_instance_id()

func _find_unit_by_stable_id(unit_id: int) -> Unit:
	if unit_id <= 0:
		return null
	for u in get_all_units():
		if not (is_instance_valid(u) and u is Unit):
			continue
		if _get_unit_stable_id(u) == unit_id:
			return u
	return null

func _build_unit_snapshot(u: Unit) -> Dictionary:
	var snapshot: Dictionary = {
		"unit_id": _get_unit_stable_id(u),
		"cell": u.cell,
		"health": u.health,
		"group_name": u.get_parent().name if u.get_parent() else "",
		"def_path": u.def.resource_path if u.def else "",
		"max_health": u.max_health,
		"max_energy": u.max_energy,
		"unit_name": u.def.name if u.def else "Unit",
	}
	if u.max_energy > 0:
		snapshot["energy"] = u.energy
	var effects_data: Array = []
	for e in u.active_effects:
		if e is UnitEffect:
			effects_data.append(e.to_dict())
	snapshot["effects"] = effects_data
	return snapshot

func _resolve_unit_for_replay_id(raw_id: int) -> Unit:
	var stable_match: Unit = _find_unit_by_stable_id(raw_id)
	if stable_match != null:
		return stable_match
	var legacy = instance_from_id(raw_id)
	if is_instance_valid(legacy) and legacy is Unit:
		return legacy
	return null

func _cell_to_array(value: Variant, fallback: Vector2 = Vector2.ZERO) -> Array:
	if value is Vector2:
		return [int(value.x), int(value.y)]
	if value is Vector2i:
		return [int(value.x), int(value.y)]
	if value is Array and value.size() >= 2:
		return [int(value[0]), int(value[1])]
	return [int(fallback.x), int(fallback.y)]

func _cell_to_vector2(value: Variant, fallback: Vector2 = Vector2.ZERO) -> Vector2:
	var arr: Array = _cell_to_array(value, fallback)
	return Vector2(int(arr[0]), int(arr[1]))

func _path_to_cell_arrays(path_spec: Array) -> Array:
	var out: Array = []
	for p in path_spec:
		out.append(_cell_to_array(p))
	return out

func _path_to_vector2(path_spec: Array) -> Array[Vector2]:
	var out: Array[Vector2] = []
	for p in path_spec:
		out.append(_cell_to_vector2(p))
	return out

func _serialize_recording_actions(recording_actions: Array) -> Array:
	var serialized: Array = []
	for action in recording_actions:
		if not (action is Dictionary):
			continue
		var atype: String = str(action.get("type", ""))
		if atype.is_empty():
			continue
		var unit_id: int = int(action.get("unit_id", -1))
		var unit = action.get("unit")
		if unit_id <= 0 and is_instance_valid(unit) and unit is Unit:
			unit_id = _get_unit_stable_id(unit)
		if unit_id <= 0:
			continue
		var unit_for_meta: Unit = unit if (is_instance_valid(unit) and unit is Unit) else _resolve_unit_for_replay_id(unit_id)
		var out: Dictionary = {
			"type": atype,
			"unit_id": unit_id,
		}
		if is_instance_valid(unit_for_meta) and unit_for_meta is Unit and unit_for_meta.def:
			out["unit_name"] = unit_for_meta.def.name
		var ac = action.get("ac")
		var action_key: String = str(action.get("action_key", ""))
		var action_name: String = str(action.get("action_name", ""))
		if ac is ActionInstance:
			if ac.definition:
				action_key = ac.definition.action_key
				action_name = ac.definition.display_name if ac.definition.display_name else action_name
			out["path"] = _path_to_cell_arrays(ac.path)
			out["end_point"] = _cell_to_array(ac.end_point)
		if atype == "move":
			var move_path: Array = action.get("path", [])
			if move_path.is_empty() and out.has("path") and out.has("end_point"):
				var fallback_path: Array = (out["path"] as Array).duplicate()
				fallback_path.append(out["end_point"])
				move_path = fallback_path
			out["path"] = _path_to_cell_arrays(move_path)
			if out["path"].is_empty():
				continue
		else:
			if not action_key.is_empty():
				out["action_key"] = action_key
			if action_name.is_empty() and not action_key.is_empty():
				var cfg: Dictionary = Actions.get_action_config(action_key)
				action_name = str(cfg.get("name", "Action"))
			if not action_name.is_empty():
				out["action_name"] = action_name
			if not out.has("path") and action.has("path"):
				out["path"] = _path_to_cell_arrays(action.get("path", []))
			if not out.has("end_point") and action.has("end_point"):
				out["end_point"] = _cell_to_array(action.get("end_point"))
		if action.has("is_passive"):
			out["is_passive"] = bool(action.get("is_passive", false))
		elif is_instance_valid(unit_for_meta) and unit_for_meta is Unit and not action_key.is_empty() and unit_for_meta.def:
			out["is_passive"] = action_key in unit_for_meta.def.passive_action_keys
		if atype == "spawn":
			out["spawned_unit_id"] = int(action.get("spawned_unit_id", 0))
			out["spawn_path"] = str(action.get("spawn_path", ""))
			if action.has("cell"):
				out["cell"] = _cell_to_array(action.get("cell"))
			elif out.has("end_point"):
				out["cell"] = out["end_point"]
		serialized.append(out)
	return serialized

func _convert_damage_by_instance_to_stable(damage_by_instance: Dictionary) -> Dictionary:
	var converted: Dictionary = {}
	for id_key in damage_by_instance:
		var instance_id: int = int(id_key)
		var stable_id: int = instance_id
		var unit = instance_from_id(instance_id)
		if is_instance_valid(unit) and unit is Unit:
			stable_id = _get_unit_stable_id(unit)
		converted[stable_id] = int(converted.get(stable_id, 0)) + int(damage_by_instance[id_key])
	return converted

func _convert_instance_ids_to_stable_ids(ids: Array) -> Array:
	var converted: Array = []
	for raw_id in ids:
		var instance_id: int = int(raw_id)
		var stable_id: int = instance_id
		var unit = instance_from_id(instance_id)
		if is_instance_valid(unit) and unit is Unit:
			stable_id = _get_unit_stable_id(unit)
		if stable_id not in converted:
			converted.append(stable_id)
	return converted

func _convert_damage_causers_to_stable(causers: Dictionary) -> Dictionary:
	var converted: Dictionary = {}
	for raw_key in causers:
		var key_str: String = str(raw_key)
		var sep_idx: int = key_str.find("_")
		if sep_idx <= 0:
			converted[key_str] = bool(causers[raw_key])
			continue
		var raw_id: int = int(key_str.substr(0, sep_idx))
		var action_key: String = key_str.substr(sep_idx + 1)
		var stable_id: int = raw_id
		var unit = instance_from_id(raw_id)
		if is_instance_valid(unit) and unit is Unit:
			stable_id = _get_unit_stable_id(unit)
		converted["%d_%s" % [stable_id, action_key]] = bool(causers[raw_key])
	return converted

func _convert_applied_effects_to_stable(applied_effects: Array) -> Array:
	var converted: Array = []
	for raw_entry in applied_effects:
		if not (raw_entry is Dictionary):
			continue
		var entry: Dictionary = raw_entry.duplicate(true)
		var raw_id: int = int(entry.get("unit_id", 0))
		if raw_id > 0:
			var stable_id: int = raw_id
			var unit = instance_from_id(raw_id)
			if is_instance_valid(unit) and unit is Unit:
				stable_id = _get_unit_stable_id(unit)
			entry["unit_id"] = stable_id
		converted.append(entry)
	return converted

func _clear_all_planned_actions() -> void:
	_llm_option_tables.clear()
	for u in get_active_units():
		u.planned_action = null


func _should_run_llm_batch_for_sp() -> bool:
	if MultiplayerState.is_multiplayer:
		return false
	if ai_group_names.is_empty():
		return false
	var settings := LlmAiSettings.new()
	settings.load_from_disk()
	return settings.has_configured_key()


func _get_planning_units_ordered() -> Array[Unit]:
	var active: Array[Unit] = get_active_units()
	var human_first: Array[Unit] = []
	var ai_list: Array[Unit] = []
	for u in active:
		var gname: String = u.get_parent().name if u.get_parent() else ""
		if gname in ai_group_names:
			ai_list.append(u)
		else:
			human_first.append(u)
	var out: Array[Unit] = []
	out.append_array(human_first)
	out.append_array(ai_list)
	return out


func _apply_llm_choice_map(action_request_by_unit_id: Dictionary, legacy_option_index_by_unit_id: Dictionary = {}) -> Dictionary:
	var any_llm := false
	var partial := false
	for u in get_active_units():
		if not (is_instance_valid(u) and u is Unit and u.is_active):
			continue
		var gname: String = u.get_parent().name if u.get_parent() else ""
		if gname not in ai_group_names:
			continue
		var uid: int = _get_unit_stable_id(u)
		var opts: Array = _llm_option_tables.get(uid, []) as Array
		var idx: int = -1
		if action_request_by_unit_id.has(uid):
			idx = _resolve_option_index_from_action_request(opts, action_request_by_unit_id.get(uid, {}) as Dictionary)
		elif legacy_option_index_by_unit_id.has(uid):
			idx = int(legacy_option_index_by_unit_id[uid])
		else:
			partial = true
			continue
		if idx < 0 or idx >= opts.size():
			partial = true
			continue
		var raw: Variant = opts[idx]
		if typeof(raw) != TYPE_DICTIONARY:
			partial = true
			continue
		var entry: Dictionary = raw
		var ac: ActionInstance = entry.get("ac") as ActionInstance
		if ac == null:
			partial = true
			continue
		_store_planned_action(u, ac, bool(entry.get("is_move", false)))
		any_llm = true
	return { "any_llm": any_llm, "partial": partial }


func _resolve_option_index_from_action_request(opts: Array, request: Dictionary) -> int:
	if request.is_empty():
		return -1
	var req_key: String = str(request.get("action_key", "")).strip_edges()
	var req_cell: Array = request.get("target_cell", []) as Array
	if req_key.is_empty() or req_cell.size() < 2:
		return -1
	var rq: int = int(req_cell[0])
	var rr: int = int(req_cell[1])
	var best_i: int = 1_000_000
	var best_idx: int = -1
	for opt_idx in range(opts.size()):
		var raw: Variant = opts[opt_idx]
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var entry: Dictionary = raw
		var ac: ActionInstance = entry.get("ac") as ActionInstance
		if ac == null or ac.definition == null:
			continue
		if str(ac.definition.action_key) != req_key:
			continue
		var ex: int = int(ac.end_point.x)
		var ey: int = int(ac.end_point.y)
		if ex != rq or ey != rr:
			continue
		var oi: int = int(entry.get("i", opt_idx))
		if oi < 0:
			continue
		if oi < best_i:
			best_i = oi
			best_idx = oi
	return best_idx


func _debug_print_llm_chosen_actions(by_unit_id: Dictionary) -> void:
	if not OS.is_debug_build():
		return
	for u in get_active_units():
		if not (is_instance_valid(u) and u is Unit and u.is_active):
			continue
		var gname: String = u.get_parent().name if u.get_parent() else ""
		if gname not in ai_group_names:
			continue
		var uid: int = _get_unit_stable_id(u)
		if not by_unit_id.has(uid):
			continue
		var idx: int = int(by_unit_id[uid])
		var uname: String = u.def.name if u.def else "unit"
		var opts: Array = _llm_option_tables.get(uid, []) as Array
		if idx < 0 or idx >= opts.size():
			print("[LLM action] unit_id=%d (%s) option_index=%d — invalid index (fallback will apply)" % [uid, uname, idx])
			continue
		var raw: Variant = opts[idx]
		if typeof(raw) != TYPE_DICTIONARY:
			print("[LLM action] unit_id=%d (%s) option_index=%d — bad option entry" % [uid, uname, idx])
			continue
		var entry: Dictionary = raw
		var ac: ActionInstance = entry.get("ac") as ActionInstance
		var is_move: bool = bool(entry.get("is_move", false))
		if ac == null or ac.definition == null:
			print("[LLM action] unit_id=%d (%s) option_index=%d — missing ActionInstance" % [uid, uname, idx])
			continue
		var ak: String = str(ac.definition.action_key)
		var ex := int(ac.end_point.x)
		var ey := int(ac.end_point.y)
		print(
			"[LLM action] unit_id=%d (%s) option_index=%d %s end=[%d,%d] move=%s"
			% [uid, uname, idx, ak, ex, ey, str(is_move)]
		)


func _log_llm_failure_result(http_result: Dictionary) -> void:
	var err: String = str(http_result.get("error", "?"))
	var detail: String = str(http_result.get("detail", "")).strip_edges()
	print("[LLM] request failed: error=%s" % err)
	if not detail.is_empty():
		print("[LLM] detail: %s" % detail)
	if http_result.has("http_status"):
		print("[LLM] http_status: %s" % str(http_result.get("http_status")))
	if http_result.has("result_code"):
		print("[LLM] result_code: %s" % str(http_result.get("result_code")))
	var snip: String = str(http_result.get("body_snippet", "")).strip_edges()
	if not snip.is_empty():
		print("[LLM] body_snippet: %s" % snip)


func _log_llm_usage(tag: String, http_result: Dictionary) -> void:
	var usage: Dictionary = http_result.get("usage", {}) as Dictionary
	if usage.is_empty():
		return
	var parts: Array[String] = []
	for k in usage.keys():
		parts.append("%s=%s" % [str(k), str(usage[k])])
	print("[%s] usage: %s" % [tag, ", ".join(parts)])


func _planning_api_call(
	client: LlmOpenAiClient,
	http: HTTPRequest,
	settings: LlmAiSettings,
	system_prompt: String,
	user_json: String,
	previous_response_id: String = "",
) -> Dictionary:
	if settings.use_responses_api:
		return await client.responses_create(
			http,
			settings.get_effective_base_url(),
			settings.api_key,
			settings.model,
			system_prompt,
			user_json,
			settings.reasoning_effort,
			settings.planning_max_tokens,
			previous_response_id,
		)
	var messages: Array = [
		{"role": "system", "content": system_prompt},
		{"role": "user", "content": user_json},
	]
	return await client.chat_completions(
		http,
		settings.get_effective_base_url(),
		settings.api_key,
		settings.model,
		messages,
		LlmOpenAiClient.Profile.PLANNING,
		settings.planning_max_tokens,
	)


func _parse_prediction_hypotheses(raw: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(raw)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	var obj: Dictionary = parsed
	var arr: Array = obj.get("enemy_predictions", []) as Array
	if arr.is_empty():
		return {}
	return {"enemy_predictions": arr}


func _llm_batch_run_async(schedule_gen: int) -> void:
	if schedule_gen != _llm_batch_generation:
		return
	_llm_batch_running = true
	EventBus.llm_planning_status.emit("requesting", "Calling model…")
	var settings := LlmAiSettings.new()
	settings.load_from_disk()
	if not settings.has_configured_key():
		_llm_batch_running = false
		EventBus.llm_planning_status.emit("idle", "")
		return
	var snapshot: Dictionary = LlmPlanningSnapshot.build_for_llm(self)
	LlmPlanningPayloadLog.write_turn_if_enabled(turn_number, snapshot, settings)
	var http_result: Dictionary
	var retry_system_prompt: String = ""
	var retry_user_json: String = ""
	EventBus.llm_planning_status.emit("waiting", "Waiting for API…")
	var system_prompt: String = LlmPlanningPrompts.system_prompt_for_version(settings.planning_prompt_version)
	var use_two_call_effective: bool = settings.use_two_call_planning and LlmPlanningPrompts.supports_two_call(settings.planning_prompt_version)
	if use_two_call_effective:
		var pred_payload: Dictionary = snapshot.duplicate(true)
		LlmPlanningSnapshot.prepare_snapshot_for_prediction_api_call(pred_payload)
		var user_json := JSON.stringify(pred_payload)
		if user_json.is_empty():
			_llm_batch_running = false
			EventBus.llm_planning_status.emit("failed", "Snapshot encode failed.")
			return
		var prediction_prompt: String = LlmPlanningPrompts.prediction_only_prompt_for_version(settings.planning_prompt_version)
		var pred_result: Dictionary = await _planning_api_call(
			_llm_openai,
			_llm_http,
			settings,
			prediction_prompt,
			user_json,
			_llm_previous_response_id,
		)
		_log_llm_usage("LLM prediction", pred_result)
		var pred_raw: String = str(pred_result.get("content", ""))
		var pred_thinking: String = str(pred_result.get("thinking", ""))
		var pred_usage: Dictionary = pred_result.get("usage", {}) as Dictionary
		var pred_hyp: Dictionary = {}
		if pred_result.get("ok", false):
			pred_hyp = _parse_prediction_hypotheses(pred_raw)
		LlmPlanningPayloadLog.write_prediction_if_enabled(
			turn_number, "ai", pred_raw, pred_hyp, pred_thinking, pred_usage, settings
		)
		if OS.is_debug_build():
			if not pred_thinking.strip_edges().is_empty():
				print("[LLM prediction thinking] ", pred_thinking)
			if not pred_raw.strip_edges().is_empty():
				print("[LLM prediction content] ", pred_raw)
		var second_snapshot: Dictionary = snapshot.duplicate(true)
		if not pred_hyp.is_empty():
			second_snapshot["enemy_prediction_hypotheses"] = pred_hyp
			LlmPlanningSnapshot.apply_prediction_hypotheses_to_legal_options(second_snapshot, pred_hyp)
		var second_json: String = JSON.stringify(second_snapshot)
		retry_system_prompt = LlmPlanningPrompts.action_only_system_prompt_for_version(settings.planning_prompt_version)
		retry_user_json = second_json
		http_result = await _planning_api_call(
			_llm_openai,
			_llm_http,
			settings,
			retry_system_prompt,
			second_json,
			_llm_previous_response_id,
		)
	else:
		var user_json := JSON.stringify(snapshot)
		if user_json.is_empty():
			_llm_batch_running = false
			EventBus.llm_planning_status.emit("failed", "Snapshot encode failed.")
			return
		retry_system_prompt = system_prompt
		retry_user_json = user_json
		http_result = await _planning_api_call(
			_llm_openai,
			_llm_http,
			settings,
			system_prompt,
			user_json,
			_llm_previous_response_id,
		)
	_log_llm_usage("LLM planning", http_result)
	_llm_batch_running = false
	if schedule_gen != _llm_batch_generation:
		return
	if not http_result.get("ok", false):
		_log_llm_failure_result(http_result)
		if str(http_result.get("error", "")) != "cancelled":
			_llm_previous_response_id = ""
		EventBus.llm_planning_status.emit("failed", "LLM error: %s" % str(http_result.get("error", "?")))
		return
	var parse: Dictionary = {}
	var apply: Dictionary = {}
	var retries_used: int = 0
	while true:
		EventBus.llm_planning_status.emit("parsing", "Validating…")
		parse = LlmPlanningResponseParser.parse_json_actions(str(http_result.get("content", "")))
		if parse.get("ok", false):
			var action_req_by_id: Dictionary = parse.get("action_request_by_unit_id", {}) as Dictionary
			var legacy_by_id: Dictionary = parse.get("legacy_option_index_by_unit_id", {}) as Dictionary
			if OS.is_debug_build():
				_debug_print_llm_chosen_actions(legacy_by_id)
			apply = _apply_llm_choice_map(action_req_by_id, legacy_by_id)
			if not bool(apply.get("partial", false)):
				break
		if retries_used >= 1:
			if not parse.get("ok", false):
				print("[LLM] parse_json_actions: %s" % str(parse))
				_llm_previous_response_id = ""
				EventBus.llm_planning_status.emit("failed", "Bad JSON: %s" % str(parse.get("error", "?")))
			else:
				EventBus.llm_planning_status.emit("failed", "LLM returned invalid plans after retry.")
			return
		retries_used += 1
		EventBus.llm_planning_status.emit("retrying", "Retrying invalid actions…")
		http_result = await _planning_api_call(
			_llm_openai,
			_llm_http,
			settings,
			retry_system_prompt,
			retry_user_json,
			_llm_previous_response_id,
		)
		_log_llm_usage("LLM planning retry", http_result)
		if not http_result.get("ok", false):
			_log_llm_failure_result(http_result)
			if str(http_result.get("error", "")) != "cancelled":
				_llm_previous_response_id = ""
			EventBus.llm_planning_status.emit("failed", "LLM error: %s" % str(http_result.get("error", "?")))
			return
	if settings.use_responses_api:
		var rid: String = str(http_result.get("response_id", "")).strip_edges()
		_llm_previous_response_id = rid if not rid.is_empty() else ""
	var _thinking: String = str(http_result.get("thinking", "")).strip_edges()
	var _op: String = str(parse.get("opponent_prediction", "")).strip_edges()
	var _rs: String = str(parse.get("reasoning_summary", "")).strip_edges()
	if OS.is_debug_build():
		if not _thinking.is_empty():
			print("[LLM thinking] ", _thinking)
		if not _op.is_empty():
			print("[LLM opponent prediction] ", _op)
		if not _rs.is_empty():
			print("[LLM reasoning] ", _rs)
	if not _thinking.is_empty() or not _op.is_empty() or not _rs.is_empty():
		EventBus.llm_thinking_updated.emit("ai", _thinking, _op, _rs)
	if bool(apply.get("any_llm", false)):
		match_had_llm_validated_plan = true
	if bool(apply.get("partial", false)):
		EventBus.llm_planning_status.emit("failed", "LLM returned incomplete plans — some units missing.")
	else:
		EventBus.llm_planning_status.emit("ready", "Opponent plan ready.")
	_llm_after_batch_apply()


func _llm_after_batch_apply() -> void:
	if _all_units_have_planned_action():
		EventBus.planning_complete.emit()
	elif current_unit == null and not _drill_llm_running:
		_select_planning_unit()

func _on_llm_retry_requested() -> void:
	if battle_phase != BattlePhase.Phase.PLANNING:
		return
	if _llm_batch_running or _drill_llm_running:
		return
	if not _should_run_llm_batch_for_sp():
		return
	for u in get_active_units():
		if not (is_instance_valid(u) and u is Unit and u.is_active):
			continue
		var gname: String = u.get_parent().name if u.get_parent() else ""
		if gname in ai_group_names or drill_scripted_groups.get(gname, "") == "llm_ai":
			u.planned_action = null
	_drill_llm_group_planned.clear()
	_llm_batch_generation += 1
	var schedule_gen: int = _llm_batch_generation
	EventBus.llm_planning_status.emit("idle", "")
	call_deferred("_llm_batch_run_async", schedule_gen)

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
		var units_at_cell = _get_units_at_cell_for_planning(cell)
		var friendly_at_cell: Array = []
		for u in units_at_cell:
			var gname: String = u.get_parent().name if u.get_parent() else ""
			if gname not in ai_group_names:
				friendly_at_cell.append(u)
		# Switch units even when Move/Ability is armed (otherwise stuck after last human plans while LLM loads).
		if friendly_at_cell.size() > 1:
			EventBus.show_units_panel.emit(friendly_at_cell)
			return
		if friendly_at_cell.size() == 1:
			var picked: Unit = friendly_at_cell[0]
			if current_unit == null or picked != current_unit or not selected_action_key.is_empty():
				EventBus.show_units_panel.emit([])
				_select_unit_for_planning(picked)
				return
		# No action selected: allow clicking a unit to select it for planning
		if selected_action_key.is_empty():
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
			var can_execute: bool = _all_units_have_planned_action()
			if can_execute:
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
	_llm_openai.cancel_inflight(_llm_http)
	_drill_llm_openai.cancel_inflight(_drill_llm_http)
	_drill_llm_running = false
	_llm_batch_generation += 1
	var schedule_gen: int = _llm_batch_generation
	_drill_llm_group_planned.clear()
	_clear_all_planned_actions()
	_cache_ai_fov_for_turn()
	planning_unit_index = 0
	EventBus.planning_started.emit()
	EventBus.llm_planning_status.emit("idle", "")
	if _should_run_llm_batch_for_sp():
		call_deferred("_llm_batch_run_async", schedule_gen)
	_select_planning_unit()

## Caches AI groups' visible hexes and unit IDs at start of planning phase.
## Stored with each turn recording so LLM history can filter by what AI could observe.
func _cache_ai_fov_for_turn() -> void:
	_planning_phase_ai_fov.clear()
	_planning_phase_ai_unit_ids.clear()
	var hex_parent: Node = get_parent()
	var hex_map: Node = hex_parent.get_node_or_null("hex_map") if hex_parent else null
	if hex_map != null and hex_map.has_method("compute_visible_cell_keys_for_ai_groups"):
		_planning_phase_ai_fov = hex_map.compute_visible_cell_keys_for_ai_groups(self)
	for u in get_all_units():
		if not (is_instance_valid(u) and u is Unit and u.is_active):
			continue
		var gname: String = u.get_parent().name if u.get_parent() else ""
		if gname in ai_group_names:
			_planning_phase_ai_unit_ids.append(_get_unit_stable_id(u))

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
	var active = _get_planning_units_ordered()
	var idx = active.find(unit)
	if idx >= 0:
		planning_unit_index = idx
		_select_planning_unit()
		if _all_units_have_planned_action():
			EventBus.planning_complete.emit()

func _cycle_planning_unit(delta: int) -> void:
	var active = _get_planning_units_ordered()
	if active.is_empty():
		return
	planning_unit_index = wrapi(planning_unit_index + delta, 0, active.size())
	_select_planning_unit()
	if _all_units_have_planned_action():
		EventBus.planning_complete.emit()

func _advance_planning() -> void:
	var active = _get_planning_units_ordered()
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
	var active = _get_planning_units_ordered()
	if active.is_empty():
		current_unit = null
		current_acs = []
		selected_action_key = ""
		_update_highlights()
		EventBus.unit_selected_for_planning.emit(null)
		return
	var next_unit: Unit = active[planning_unit_index]
	var unit_group_name: String = next_unit.get_parent().name if next_unit.get_parent() else ""
	# Drill-scripted groups: auto-plan via deterministic script or secondary LLM.
	if drill_scripted_groups.has(unit_group_name):
		var script_name: String = str(drill_scripted_groups[unit_group_name])
		if script_name == "llm_ai":
			current_unit = null
			selected_action_key = ""
			EventBus.unit_selected_for_planning.emit(null)
			_run_drill_llm_planning_for(next_unit, unit_group_name)
			return
		var choice: Dictionary = DrillScriptAI.pick_action(next_unit, groups, script_name)
		if not choice.is_empty():
			_store_planned_action(next_unit, choice.ac, choice.is_move)
		_advance_planning()
		return
	# Do not assign current_unit to AI: keeps action selector, highlights, and click-to-commit on the player.
	if unit_group_name in ai_group_names:
		# Clear last human's move/ability selection so map clicks can switch units while LLM runs (see _unhandled_input).
		current_unit = null
		selected_action_key = ""
		EventBus.unit_selected_for_planning.emit(null)
		EventBus.action_key_selected.emit("")
		_run_ai_planning_for(next_unit)
		return
	current_unit = next_unit
	selected_action_key = ""
	EventBus.unit_selected_for_planning.emit(current_unit)
	_build_combined_acs()

func _run_ai_planning_for(unit: Unit) -> void:
	if _should_run_llm_batch_for_sp():
		if _llm_batch_running:
			EventBus.llm_planning_status.emit("waiting", "Waiting for opponent model…")
			while _llm_batch_running:
				await get_tree().process_frame
		if is_instance_valid(unit) and unit.planned_action != null:
			_advance_planning()
		return
	if not is_instance_valid(unit):
		return
	_advance_planning()


## Drill LLM-vs-LLM: plans an entire drill-scripted group via a secondary LLM call.
func _run_drill_llm_planning_for(unit: Unit, group_name: String) -> void:
	var gen_at_start: int = _llm_batch_generation
	if not _drill_llm_group_planned.get(group_name, false):
		if _drill_llm_running:
			EventBus.llm_planning_status.emit("waiting", "Waiting for drill LLM…")
			while _drill_llm_running:
				await get_tree().process_frame
			if gen_at_start != _llm_batch_generation:
				return
		if not _drill_llm_group_planned.get(group_name, false):
			_drill_llm_running = true
			await _drill_llm_batch_for_group(group_name)
			if gen_at_start != _llm_batch_generation:
				return
			_drill_llm_running = false
			_drill_llm_group_planned[group_name] = true
	if gen_at_start != _llm_batch_generation:
		return
	if is_instance_valid(unit) and unit.planned_action != null:
		_advance_planning()
		return
	# Fallback: if the LLM didn't produce an action, use the classic heuristic AI.
	if is_instance_valid(unit):
		var fallback: Dictionary = DrillScriptAI.pick_action(unit, groups, "advance_straight")
		if not fallback.is_empty():
			_store_planned_action(unit, fallback.ac, fallback.is_move)
	_advance_planning()


## Runs a standalone LLM batch for a drill-scripted group by temporarily swapping ai_group_names.
func _drill_llm_batch_for_group(group_name: String) -> void:
	EventBus.llm_planning_status.emit("requesting", "Calling model for %s…" % group_name)
	var settings := LlmAiSettings.new()
	settings.load_from_disk()
	if not settings.has_configured_key():
		EventBus.llm_planning_status.emit("idle", "")
		return

	# Temporarily treat only this group as AI so the snapshot is built from its perspective.
	var saved_ai := ai_group_names.duplicate()
	ai_group_names.clear()
	ai_group_names.append(group_name)
	var snapshot: Dictionary = LlmPlanningSnapshot.build_for_llm(self)
	var drill_options: Dictionary = _llm_option_tables.duplicate(true)
	ai_group_names = saved_ai
	LlmPlanningPayloadLog.write_turn_if_enabled(turn_number, snapshot, settings)

	var system_prompt: String = LlmPlanningPrompts.system_prompt_for_version(settings.planning_prompt_version)
	EventBus.llm_planning_status.emit("waiting", "Waiting for %s API…" % group_name)
	var http_result: Dictionary
	var retry_system_prompt: String = ""
	var retry_user_json: String = ""
	var use_two_call_effective: bool = settings.use_two_call_planning and LlmPlanningPrompts.supports_two_call(settings.planning_prompt_version)
	if use_two_call_effective:
		var pred_payload: Dictionary = snapshot.duplicate(true)
		LlmPlanningSnapshot.prepare_snapshot_for_prediction_api_call(pred_payload)
		var user_json := JSON.stringify(pred_payload)
		if user_json.is_empty():
			EventBus.llm_planning_status.emit("failed", "Snapshot encode failed for %s." % group_name)
			return
		var prediction_prompt: String = LlmPlanningPrompts.prediction_only_prompt_for_version(settings.planning_prompt_version)
		var pred_result: Dictionary = await _planning_api_call(
			_drill_llm_openai,
			_drill_llm_http,
			settings,
			prediction_prompt,
			user_json,
		)
		_log_llm_usage("DrillLLM prediction %s" % group_name, pred_result)
		var pred_raw: String = str(pred_result.get("content", ""))
		var pred_thinking: String = str(pred_result.get("thinking", ""))
		var pred_usage: Dictionary = pred_result.get("usage", {}) as Dictionary
		var pred_hyp: Dictionary = {}
		if pred_result.get("ok", false):
			pred_hyp = _parse_prediction_hypotheses(pred_raw)
		LlmPlanningPayloadLog.write_prediction_if_enabled(
			turn_number, "drill_" + group_name, pred_raw, pred_hyp, pred_thinking, pred_usage, settings
		)
		if OS.is_debug_build():
			if not pred_thinking.strip_edges().is_empty():
				print("[DrillLLM %s prediction thinking] %s" % [group_name, pred_thinking])
			if not pred_raw.strip_edges().is_empty():
				print("[DrillLLM %s prediction content] %s" % [group_name, pred_raw])
		var second_snapshot: Dictionary = snapshot.duplicate(true)
		if not pred_hyp.is_empty():
			second_snapshot["enemy_prediction_hypotheses"] = pred_hyp
			LlmPlanningSnapshot.apply_prediction_hypotheses_to_legal_options(second_snapshot, pred_hyp)
		var second_json: String = JSON.stringify(second_snapshot)
		retry_system_prompt = LlmPlanningPrompts.action_only_system_prompt_for_version(settings.planning_prompt_version)
		retry_user_json = second_json
		http_result = await _planning_api_call(
			_drill_llm_openai,
			_drill_llm_http,
			settings,
			retry_system_prompt,
			second_json,
		)
	else:
		var user_json := JSON.stringify(snapshot)
		if user_json.is_empty():
			EventBus.llm_planning_status.emit("failed", "Snapshot encode failed for %s." % group_name)
			return
		retry_system_prompt = system_prompt
		retry_user_json = user_json
		http_result = await _planning_api_call(
			_drill_llm_openai,
			_drill_llm_http,
			settings,
			system_prompt,
			user_json,
		)
	_log_llm_usage("DrillLLM planning %s" % group_name, http_result)
	if not http_result.get("ok", false):
		var err_msg := str(http_result.get("error", "?"))
		print("[DrillLLM] %s batch failed: %s" % [group_name, err_msg])
		EventBus.llm_planning_status.emit("failed", "Drill LLM error: %s" % err_msg)
		return

	var parse: Dictionary = {}
	var apply: Dictionary = {}
	var retries_used: int = 0
	while true:
		EventBus.llm_planning_status.emit("parsing", "Validating %s…" % group_name)
		parse = LlmPlanningResponseParser.parse_json_actions(str(http_result.get("content", "")))
		if parse.get("ok", false):
			# Apply choices: swap option tables + ai_group_names so _apply_llm_choice_map targets this group.
			var action_req_by_id: Dictionary = parse.get("action_request_by_unit_id", {}) as Dictionary
			var legacy_by_id: Dictionary = parse.get("legacy_option_index_by_unit_id", {}) as Dictionary
			var primary_options := _llm_option_tables.duplicate(true)
			_llm_option_tables = drill_options
			var saved_ai2 := ai_group_names.duplicate()
			ai_group_names.clear()
			ai_group_names.append(group_name)
			if OS.is_debug_build():
				_debug_print_llm_chosen_actions(legacy_by_id)
			apply = _apply_llm_choice_map(action_req_by_id, legacy_by_id)
			ai_group_names = saved_ai2
			_llm_option_tables = primary_options
			if not bool(apply.get("partial", false)):
				break
		if retries_used >= 1:
			if not parse.get("ok", false):
				print("[DrillLLM] %s parse failed: %s" % [group_name, str(parse)])
				EventBus.llm_planning_status.emit("failed", "Bad JSON from drill LLM.")
			else:
				EventBus.llm_planning_status.emit("failed", "Drill LLM returned invalid plans for %s." % group_name)
			return
		retries_used += 1
		EventBus.llm_planning_status.emit("retrying", "Retrying %s invalid actions…" % group_name)
		http_result = await _planning_api_call(
			_drill_llm_openai,
			_drill_llm_http,
			settings,
			retry_system_prompt,
			retry_user_json,
		)
		_log_llm_usage("DrillLLM planning retry %s" % group_name, http_result)
		if not http_result.get("ok", false):
			var retry_err := str(http_result.get("error", "?"))
			print("[DrillLLM] %s retry failed: %s" % [group_name, retry_err])
			EventBus.llm_planning_status.emit("failed", "Drill LLM error: %s" % retry_err)
			return

	var _drill_thinking: String = str(http_result.get("thinking", "")).strip_edges()
	var _drill_op: String = str(parse.get("opponent_prediction", "")).strip_edges()
	var _drill_rs: String = str(parse.get("reasoning_summary", "")).strip_edges()
	if OS.is_debug_build():
		if not _drill_thinking.is_empty():
			print("[DrillLLM %s thinking] %s" % [group_name, _drill_thinking])
		if not _drill_op.is_empty():
			print("[DrillLLM %s opponent prediction] %s" % [group_name, _drill_op])
		if not _drill_rs.is_empty():
			print("[DrillLLM %s reasoning] %s" % [group_name, _drill_rs])
	if not _drill_thinking.is_empty() or not _drill_op.is_empty() or not _drill_rs.is_empty():
		EventBus.llm_thinking_updated.emit("drill:" + group_name, _drill_thinking, _drill_op, _drill_rs)

	if bool(apply.get("any_llm", false)):
		match_had_llm_validated_plan = true

	if bool(apply.get("partial", false)):
		EventBus.llm_planning_status.emit("failed", "Drill LLM returned incomplete plans for %s." % group_name)
	else:
		EventBus.llm_planning_status.emit("ready", "%s plan ready." % group_name.capitalize())


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
	EventBus.replay_available_changed.emit(not replay_turn_history.is_empty())
	_emit_replay_history_changed()
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
			var effects_data: Array = []
			for e in u.active_effects:
				if e is UnitEffect:
					effects_data.append(e.to_dict())
			g_dict.units.append({
				"unit_id": unit_id,
				"def_path": u.def.resource_path if u.def else "",
				"cell": cell_arr,
				"health": u.health,
				"max_health": u.max_health,
				"energy": u.energy,
				"max_energy": u.max_energy,
				"is_active": u.is_active,
				"effects": effects_data
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
		var snapshot: Dictionary = _build_unit_snapshot(u)
		last_turn_recording.before_state[int(snapshot.get("unit_id", _get_unit_stable_id(u)))] = snapshot
	for u in active:
		if not u.is_active:
			continue
		if u.planned_action != null:
			var ac: ActionInstance = u.planned_action
			var action_name: String = ac.definition.display_name if ac.definition.display_name else "Action"
			var atype: String = Actions.get_action_type(ac.definition.action_key) if ac.definition else ""
			last_turn_recording.summary.append({
				"unit_name": u.def.name,
				"action_name": action_name,
				"instance_id": u.get_instance_id(),
				"unit_id": _get_unit_stable_id(u),
				"action_type": atype
			})
		for def in u.def.get_passive_ability_definitions_resolved():
			var action_name: String = def.display_name if def.display_name else "Passive"
			var atype: String = Actions.get_action_type(def.action_key)
			last_turn_recording.summary.append({
				"unit_name": u.def.name,
				"action_name": action_name,
				"instance_id": u.get_instance_id(),
				"unit_id": _get_unit_stable_id(u),
				"action_key": def.action_key,
				"is_passive": true,
				"action_type": atype
			})

func _filter_passive_summary_entries() -> void:
	var causers: Dictionary = last_turn_recording.get("damage_causers", {})
	var filtered: Array = []
	for entry in last_turn_recording.summary:
		if entry.get("is_passive", false):
			var stable_id: int = int(entry.get("unit_id", entry.get("instance_id", 0)))
			var legacy_id: int = int(entry.get("instance_id", stable_id))
			var stable_key := "%d_%s" % [stable_id, entry.get("action_key", "")]
			var legacy_key := "%d_%s" % [legacy_id, entry.get("action_key", "")]
			if not causers.get(stable_key, false) and not causers.get(legacy_key, false):
				continue
		filtered.append(entry)
	last_turn_recording.summary = filtered

func _get_replay_turn_numbers() -> Array:
	var turn_numbers: Array = []
	for entry in replay_turn_history:
		if not (entry is Dictionary):
			continue
		turn_numbers.append(int(entry.get("turn", 0)))
	return turn_numbers

func _get_replay_history_entry(requested_turn: int) -> Dictionary:
	if replay_turn_history.is_empty():
		return {}
	if requested_turn <= 0:
		return replay_turn_history[replay_turn_history.size() - 1]
	for idx in range(replay_turn_history.size() - 1, -1, -1):
		var entry: Dictionary = replay_turn_history[idx]
		if int(entry.get("turn", -1)) == requested_turn:
			return entry
	return replay_turn_history[replay_turn_history.size() - 1]

func _emit_replay_history_changed(selected_turn: int = 0) -> void:
	var turn_numbers: Array = _get_replay_turn_numbers()
	if selected_turn <= 0 and not turn_numbers.is_empty():
		selected_turn = int(turn_numbers[turn_numbers.size() - 1])
	EventBus.replay_history_changed.emit(turn_numbers, selected_turn)

func _store_replay_recording_for_turn(turn_played: int, recording: Dictionary) -> void:
	if recording.is_empty():
		return
	var cloned_recording: Dictionary = recording.duplicate(true)
	last_turn_recording = cloned_recording
	replay_turn_history.append({
		"turn": turn_played,
		"recording": cloned_recording,
		"ai_fov": _planning_phase_ai_fov.duplicate(),
		"ai_unit_ids": _planning_phase_ai_unit_ids.duplicate(),
	})
	while replay_turn_history.size() > MAX_REPLAY_TURN_HISTORY:
		replay_turn_history.remove_at(0)
	match_full_turn_history.append({
		"turn": turn_played,
		"recording": cloned_recording.duplicate(true),
	})
	var recording_died: Array = cloned_recording.get("died_ids", [])
	for raw_uid in recording_died:
		var uid: int = int(raw_uid)
		if uid in _planning_phase_ai_unit_ids:
			continue
		if _ai_killed_enemy_ids.has(uid):
			continue
		_ai_killed_enemy_ids[uid] = true
		_ai_confirmed_enemy_kills += 1
	EventBus.replay_available_changed.emit(not replay_turn_history.is_empty())
	_emit_replay_history_changed(turn_played)

func _on_unit_pick_requested(unit: Unit) -> void:
	_select_unit_for_planning(unit)

func _on_replay_turn_requested(requested_turn: int) -> void:
	if battle_phase != BattlePhase.Phase.PLANNING or replay_turn_history.is_empty():
		return
	var replay_entry: Dictionary = _get_replay_history_entry(requested_turn)
	var replay_recording: Dictionary = replay_entry.get("recording", {})
	if replay_recording.is_empty():
		return
	var replay_turn: int = int(replay_entry.get("turn", requested_turn))
	_emit_replay_history_changed(replay_turn)
	_replay_turn_recording(replay_recording, replay_turn)

func _phase_display_name(action_type: String) -> String:
	if action_type.is_empty():
		return "Other"
	var parts: PackedStringArray = action_type.split(" ")
	for i in parts.size():
		if parts[i].length() > 0:
			parts[i] = parts[i].left(1).to_upper() + parts[i].substr(1)
	return " ".join(parts)

func _resolve_replay_observer_group_name() -> String:
	if not multiplayer_my_group.is_empty():
		return multiplayer_my_group
	if groups.is_empty():
		return ""
	return str(groups[0].name)

func _collect_visible_replay_unit_ids() -> Dictionary:
	var visible_ids: Dictionary = {}
	var observer_group_name: String = _resolve_replay_observer_group_name()
	for u in get_all_units():
		if not (is_instance_valid(u) and u is Unit):
			continue
		if not u.is_active:
			continue
		var stable_id: int = _get_unit_stable_id(u)
		if stable_id <= 0:
			continue
		var unit_group_name: String = u.get_parent().name if u.get_parent() else ""
		if not observer_group_name.is_empty() and unit_group_name == observer_group_name:
			visible_ids[stable_id] = true
			continue
		if u.visible:
			visible_ids[stable_id] = true
	return visible_ids

func _is_replay_unit_visible(unit_id: int, visible_unit_ids: Dictionary) -> bool:
	if visible_unit_ids.is_empty():
		return true
	if unit_id <= 0:
		return false
	return bool(visible_unit_ids.get(unit_id, false))

func _build_replay_summary_lines(replay_recording: Dictionary, visible_unit_ids: Dictionary = {}) -> Array:
	var summary_lines: Array = []
	var died_ids: Array = replay_recording.get("died_ids", [])
	var summary: Array = replay_recording.get("summary", [])
	var before_state: Dictionary = replay_recording.get("before_state", {})
	var damage_by_id: Dictionary = replay_recording.get("damage_by_id", {})
	for action_type in Actions.ACTION_ORDER:
		var entries_in_phase: Array = []
		for raw_entry in summary:
			if not (raw_entry is Dictionary):
				continue
			var entry: Dictionary = raw_entry
			if entry.get("action_type", "") == action_type:
				entries_in_phase.append(entry)
		var visible_entries: Array = []
		for entry in entries_in_phase:
			var entry_id: int = int(entry.get("unit_id", entry.get("instance_id", -1)))
			if not _is_replay_unit_visible(entry_id, visible_unit_ids):
				continue
			visible_entries.append(entry)
		if visible_entries.is_empty():
			continue
		if entries_in_phase.is_empty():
			continue
		summary_lines.append("")
		summary_lines.append(_phase_display_name(action_type))
		for entry in visible_entries:
			var suffix: String = _build_replay_summary_entry_suffix(entry, died_ids)
			var unit_name: String = str(entry.get("unit_name", "Unit"))
			var action_name: String = str(entry.get("action_name", "Action"))
			summary_lines.append("  %s: %s%s" % [unit_name, action_name, suffix])
	summary_lines.append("")
	summary_lines.append("Units damaged")
	var has_visible_damage: bool = false
	for uid in damage_by_id:
		var stable_uid: int = int(uid)
		if not _is_replay_unit_visible(stable_uid, visible_unit_ids):
			continue
		has_visible_damage = true
		var start_hp: int = before_state.get(uid, {}).get("health", 0)
		var damage: int = damage_by_id[uid]
		var end_hp: int = mini(maxi(start_hp - damage, 0), 999)
		var unit_name: String = str(before_state.get(uid, {}).get("unit_name", "Unit"))
		var unit = _resolve_unit_for_replay_id(stable_uid)
		if is_instance_valid(unit) and unit is Unit:
			unit_name = unit.def.name
		var elim := " (eliminated)" if end_hp <= 0 else ""
		summary_lines.append("  %s: %d HP → %d (-%d)%s" % [unit_name, start_hp, end_hp, damage, elim])
	if not has_visible_damage:
		summary_lines.append("  None")
	if summary_lines.size() > 0 and summary_lines[0] == "":
		summary_lines.remove_at(0)
	return summary_lines

func _build_replay_summary_entry_suffix(entry: Dictionary, died_ids: Array) -> String:
	if bool(entry.get("cancelled", false)):
		var cancelled_reason: String = str(entry.get("cancelled_reason", ""))
		if cancelled_reason == "eliminated_before_phase":
			return " (cancelled: eliminated first)"
		return " (cancelled)"
	var entry_id: int = int(entry.get("unit_id", entry.get("instance_id", -1)))
	if entry_id in died_ids:
		return " (eliminated)"
	return ""

func _replay_turn_recording(replay_recording: Dictionary, replay_turn: int = 0) -> void:
	battle_phase = BattlePhase.Phase.EXECUTING
	EventBus.unit_selected_for_planning.emit(null)
	EventBus.show_selected_unit_cell.emit(null)
	EventBus.show_move_path.emit(null, Vector2.ZERO)
	var replay_return_state: Dictionary = _capture_replay_return_state()
	_restore_before_state(replay_recording.get("before_state", {}))
	var hex_map_node = get_parent().get_node_or_null("hex_map")
	if hex_map_node and hex_map_node.has_method("refresh_fog"):
		hex_map_node.refresh_fog()
	var visible_unit_ids: Dictionary = _collect_visible_replay_unit_ids()
	var summary_lines: Array = _build_replay_summary_lines(replay_recording, visible_unit_ids)
	var replay_title_turn: int = replay_turn if replay_turn > 0 else turn_number
	EventBus.show_replay_summary.emit(summary_lines, "Turn %d actions" % replay_title_turn)
	var actions_by_type := _build_replay_actions_by_type(replay_recording.get("actions", []))
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
	var damage_by_id: Dictionary = replay_recording.get("damage_by_id", {})
	for uid_key in damage_by_id:
		var unit = _resolve_unit_for_replay_id(int(uid_key))
		if is_instance_valid(unit):
			var dmg: int = int(damage_by_id[uid_key])
			unit.health -= dmg
			if unit.health_bar:
				unit.health_bar.update_value(unit.health)
	var applied_effects: Array = replay_recording.get("applied_effects", [])
	for entry in applied_effects:
		var unit = _resolve_unit_for_replay_id(int(entry.get("unit_id", 0)))
		if is_instance_valid(unit) and unit is Unit:
			var eff := UnitEffect.from_dict(entry.get("effect", {}))
			unit.add_effect(eff, false)
	var units_that_will_die: Array = []
	for uid in damage_by_id:
		var unit = _resolve_unit_for_replay_id(int(uid))
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
	_restore_replay_return_state(replay_return_state)
	await get_tree().process_frame
	battle_phase = BattlePhase.Phase.PLANNING
	if hex_map_node and hex_map_node.has_method("refresh_fog"):
		hex_map_node.refresh_fog()
	EventBus.replay_finished.emit()

## Snapshot of current board state so replay can return exactly to it.
func _capture_replay_return_state() -> Dictionary:
	var snapshot: Dictionary = {}
	for u in get_all_units():
		if not (is_instance_valid(u) and u is Unit):
			continue
		var s: Dictionary = {
			"cell": u.cell,
			"health": u.health,
			"visible": u.visible,
		}
		if u.max_energy > 0:
			s["energy"] = u.energy
		var effects_data: Array = []
		for e in u.active_effects:
			if e is UnitEffect:
				effects_data.append(e.to_dict())
		s["effects"] = effects_data
		snapshot[u.get_instance_id()] = s
	return snapshot

## Restores board state captured before replay and removes replay-only spawned units.
func _restore_replay_return_state(snapshot: Dictionary) -> void:
	if snapshot.is_empty():
		return
	var to_remove: Array[Node] = []
	for u in get_all_units():
		if not snapshot.has(u.get_instance_id()):
			to_remove.append(u)
	for node in to_remove:
		var parent := node.get_parent()
		if parent != null:
			parent.remove_child(node)
		node.queue_free()
	for uid in snapshot:
		var unit = instance_from_id(uid as int)
		if is_instance_valid(unit) and unit is Unit:
			var s: Dictionary = snapshot[uid]
			var energy_val: int = s.get("energy", -1)
			var effects_data: Array = s.get("effects", [])
			unit.restore_state(s.cell, s.health, energy_val, effects_data)
			unit.visible = bool(s.get("visible", true))

func _map_recorded_action_type(action_type: String) -> String:
	var atype: String = action_type
	if atype == "attack" or atype == "support":
		atype = "ability"
	elif atype == "fast attack":
		atype = "fast ability"
	elif atype == "slow attack":
		atype = "slow ability"
	elif atype in ["reload", "rest_no_energy"]:
		atype = "slow ability"
	return atype

func _build_actions_by_type_from_action_list(action_list: Array) -> Dictionary:
	var actions_by_type: Dictionary = {}
	for t in Actions.ACTION_ORDER:
		actions_by_type[t] = []
	for raw_action in action_list:
		if not (raw_action is Dictionary):
			continue
		var action: Dictionary = raw_action
		var atype: String = _map_recorded_action_type(str(action.get("type", "")))
		if atype.is_empty():
			continue
		var unit_id: int = int(action.get("unit_id", -1))
		var u = action.get("unit")
		if (not is_instance_valid(u) or not u is Unit) and unit_id > 0:
			u = _resolve_unit_for_replay_id(unit_id)
		if not is_instance_valid(u) or not u is Unit:
			continue
		var entry: Dictionary = { "unit": u, "is_move": (atype == "move") }
		if atype == "move":
			var full_path: Array[Vector2] = _path_to_vector2(action.get("path", []))
			if full_path.size() < 2:
				var legacy_ac = action.get("ac")
				if legacy_ac is ActionInstance:
					full_path = legacy_ac.path.duplicate()
					full_path.append(legacy_ac.end_point)
			if full_path.size() < 2:
				continue
			var move_ac := ActionInstance.new(null, u)
			move_ac.path = full_path.slice(0, full_path.size() - 1)
			move_ac.end_point = full_path[full_path.size() - 1]
			entry["ac"] = move_ac
		else:
			var action_key: String = str(action.get("action_key", ""))
			var legacy_ac = action.get("ac")
			if action_key.is_empty() and legacy_ac is ActionInstance and legacy_ac.definition:
				action_key = legacy_ac.definition.action_key
			if action_key.is_empty():
				continue
			var ability_ac := ActionInstance.new(null, u)
			var defs: Array = Actions.get_ability_definitions_for_action(action_key)
			if not defs.is_empty():
				ability_ac.definition = defs[0]
			var src_dict: Dictionary = legacy_ac if legacy_ac is Dictionary else {}
			var path_raw: Array = action.get("path", src_dict.get("path", []))
			var ability_path: Array[Vector2] = _path_to_vector2(path_raw)
			if ability_path.is_empty() and legacy_ac is ActionInstance:
				ability_path = legacy_ac.path.duplicate()
			ability_ac.path = ability_path
			var end_raw = action.get("end_point", src_dict.get("end_point", null))
			if end_raw != null:
				ability_ac.end_point = _cell_to_vector2(end_raw, u.cell)
			elif legacy_ac is ActionInstance:
				ability_ac.end_point = legacy_ac.end_point
			else:
				ability_ac.end_point = u.cell
			entry["ac"] = ability_ac
		if atype == "spawn":
			var spawn_path: String = str(action.get("spawn_path", ""))
			if spawn_path.is_empty():
				var spawn_cfg: Dictionary = Actions.get_action_config(str(action.get("action_key", "")))
				spawn_path = str(spawn_cfg.get("spawn_unit", ""))
			var spawn_cell_raw = action.get("cell", action.get("end_point", u.cell))
			var spawn_cell: Vector2 = _cell_to_vector2(spawn_cell_raw, u.cell)
			entry["spawn_data"] = {
				"spawned_unit_id": int(action.get("spawned_unit_id", 0)),
				"spawn_path": spawn_path,
				"cell": spawn_cell
			}
		if not actions_by_type.has(atype):
			actions_by_type[atype] = []
		actions_by_type[atype].append(entry)
	return actions_by_type

## Builds actions_by_type from recorded actions so replay uses the same run_pipeline as live execution.
func _build_replay_actions_by_type(recording_actions: Array) -> Dictionary:
	return _build_actions_by_type_from_action_list(recording_actions)

func _restore_before_state(before_state: Dictionary) -> void:
	for uid in before_state:
		var unit_id: int = int(uid)
		var s: Dictionary = before_state[uid]
		var unit: Unit = _find_unit_by_stable_id(unit_id)
		if unit == null:
			var group_name: String = str(s.get("group_name", ""))
			var def_path: String = str(s.get("def_path", ""))
			var group_node = get_node_or_null(group_name)
			var def: UnitDefinition = load(def_path) as UnitDefinition
			if group_node != null and def != null:
				unit = UNIT_SCENE.instantiate() as Unit
				unit.def = def
				var start_cell: Vector2 = s.get("cell", Vector2.ZERO)
				unit.starting_cell = Vector2i(int(start_cell.x), int(start_cell.y))
				unit.set_meta("unit_id", unit_id)
				group_node.add_child(unit)
		if is_instance_valid(unit):
			var energy_val: int = int(s.get("energy", -1))
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
	last_turn_recording["actions"] = _serialize_recording_actions(last_turn_recording.get("actions", []))
	last_turn_recording["damage_by_id"] = _convert_damage_by_instance_to_stable(ctx.damage_by_id)
	last_turn_recording["died_ids"] = _convert_instance_ids_to_stable_ids(last_turn_recording.get("died_ids", []))
	last_turn_recording["damage_causers"] = _convert_damage_causers_to_stable(last_turn_recording.get("damage_causers", {}))
	last_turn_recording["applied_effects"] = _convert_applied_effects_to_stable(last_turn_recording.get("applied_effects", []))
	_filter_passive_summary_entries()
	_store_replay_recording_for_turn(turn_number, last_turn_recording)
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
		var unit_id: int = int(action.get("unit_id", -1))
		if unit_id <= 0:
			continue
		var u: Unit = _resolve_unit_for_replay_id(unit_id)
		var atype: String = _map_recorded_action_type(str(action.get("type", "")))
		var action_name: String = str(action.get("action_name", ""))
		var action_key: String = str(action.get("action_key", ""))
		if action_name.is_empty():
			if atype == "move":
				action_name = "Move"
			elif not action_key.is_empty():
				var cfg: Dictionary = Actions.get_action_config(action_key)
				action_name = str(cfg.get("name", "Action"))
			else:
				action_name = "Action"
		var unit_name: String = str(action.get("unit_name", "Unit"))
		if is_instance_valid(u) and u is Unit and u.def:
			unit_name = u.def.name
		var is_passive: bool = bool(action.get("is_passive", false))
		if not is_passive and is_instance_valid(u) and u is Unit and u.def and not action_key.is_empty():
			is_passive = action_key in u.def.passive_action_keys
		var entry: Dictionary = {
			"unit_name": unit_name,
			"action_name": action_name,
			"instance_id": u.get_instance_id() if is_instance_valid(u) and u is Unit else unit_id,
			"unit_id": unit_id,
			"action_type": atype
		}
		if is_passive:
			entry["is_passive"] = true
			entry["action_key"] = action_key
		summary.append(entry)
	return summary

## Build actions_by_type directly from server turn_result (dictionary recording) for multiplayer animation.
func _build_actions_by_type_from_server(turn_result: Dictionary) -> Dictionary:
	var server_actions: Array = []
	if turn_result.has("actions"):
		server_actions = turn_result["actions"]
	return _build_actions_by_type_from_action_list(server_actions)

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
	var executed_turn_number: int = turn_number
	# Snapshot before_state for replay/undo (same shape as _record_turn_before_execution, but includes all units).
	var before_state: Dictionary = {}
	for u in get_all_units():
		if not (is_instance_valid(u) and u is Unit):
			continue
		var snapshot: Dictionary = _build_unit_snapshot(u)
		before_state[int(snapshot.get("unit_id", _get_unit_stable_id(u)))] = snapshot

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
	recording["actions"] = _serialize_recording_actions(recording["actions"])
	recording["before_state"] = before_state
	recording["damage_by_id"] = _convert_damage_by_instance_to_stable(ctx.damage_by_id)
	recording["died_ids"] = _convert_instance_ids_to_stable_ids(recording.get("died_ids", []))
	recording["damage_causers"] = _convert_damage_causers_to_stable(recording.get("damage_causers", {}))
	recording["applied_effects"] = _convert_applied_effects_to_stable(recording.get("applied_effects", []))
	var submitted_summary: Array = []
	for raw_entry in turn_result.get("summary", []):
		if raw_entry is Dictionary:
			submitted_summary.append((raw_entry as Dictionary).duplicate(true))
	recording["summary"] = submitted_summary if not submitted_summary.is_empty() else _build_summary_from_recording_actions(recording["actions"])
	last_turn_recording = recording
	_filter_passive_summary_entries()
	_store_replay_recording_for_turn(executed_turn_number, last_turn_recording)

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
	EventBus.replay_available_changed.emit(not replay_turn_history.is_empty())
	_emit_replay_history_changed()
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
