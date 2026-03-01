extends CanvasLayer
const BattlePhase = preload("res://src/battle/battle_phase.gd")

@onready var execute_button: Button = $turn_panel/vbox/execute_button
@onready var replay_button: Button = $turn_panel/vbox/replay_button
@onready var replay_turn_picker: OptionButton = $turn_panel/vbox/replay_turn_picker
@onready var turn_label: Label = $turn_panel/vbox/turn_label
@onready var scenarios_button: Button = $turn_panel/vbox/scenarios_button
@onready var resources_label: Label = $resources_panel/margin/vbox/resources_label
@onready var hovered_tile_label: Label = $resources_panel/margin/vbox/hovered_tile_label

var _units_node: UnitsContainer
var _hex_map_node: Node
var _replay_turn_numbers: Array[int] = []
var _selected_replay_turn: int = 0
var _replay_available: bool = false
var _replay_in_progress: bool = false
var _updating_replay_picker: bool = false

func _ready() -> void:
	execute_button.pressed.connect(_on_execute_pressed)
	execute_button.disabled = true
	if MultiplayerState.is_multiplayer:
		execute_button.text = "Submit"
	if scenarios_button:
		scenarios_button.pressed.connect(_on_scenarios_pressed)
		if MultiplayerState.is_multiplayer:
			scenarios_button.visible = false
	if replay_button:
		replay_button.pressed.connect(_on_replay_pressed)
	if replay_turn_picker:
		replay_turn_picker.item_selected.connect(_on_replay_turn_selected)
		replay_turn_picker.disabled = true
	EventBus.planning_started.connect(_on_planning_started)
	EventBus.planning_complete.connect(_on_planning_complete)
	EventBus.turn_changed.connect(_on_turn_changed)
	EventBus.replay_available_changed.connect(_on_replay_available_changed)
	EventBus.replay_history_changed.connect(_on_replay_history_changed)
	EventBus.replay_finished.connect(_on_replay_finished)
	EventBus.tile_resource_changed.connect(_on_tile_resource_changed)
	_units_node = get_parent().get_node_or_null("units") as UnitsContainer
	_hex_map_node = get_parent().get_node_or_null("hex_map")
	_update_replay_controls()
	_update_resource_inventory()
	_update_hovered_tile_resource()
	set_process(true)

func _on_turn_changed(turn_number: int) -> void:
	if turn_label:
		turn_label.text = "Turn %d" % turn_number
	_update_resource_inventory()

func _on_planning_started() -> void:
	execute_button.disabled = true
	if MultiplayerState.is_multiplayer:
		execute_button.text = "Submit"
	_update_replay_controls()
	_update_resource_inventory()

func _on_planning_complete() -> void:
	execute_button.disabled = false

func _on_execute_pressed() -> void:
	EventBus.execute_turn_requested.emit()
	execute_button.disabled = true
	_update_replay_controls()
	if MultiplayerState.is_multiplayer:
		execute_button.text = "Waiting for other players..."

func _on_replay_pressed() -> void:
	var turn_to_replay: int = _selected_replay_turn
	if turn_to_replay <= 0 and not _replay_turn_numbers.is_empty():
		turn_to_replay = _replay_turn_numbers[_replay_turn_numbers.size() - 1]
	var is_planning: bool = _units_node != null and _units_node.battle_phase == BattlePhase.Phase.PLANNING
	if not is_planning:
		_replay_in_progress = false
		_update_replay_controls()
		return
	EventBus.replay_turn_requested.emit(turn_to_replay)
	_replay_in_progress = true
	_update_replay_controls()

func _on_replay_finished() -> void:
	_replay_in_progress = false
	_update_replay_controls()

func _on_replay_available_changed(available: bool) -> void:
	_replay_available = available
	_update_replay_controls()

func _on_replay_history_changed(turn_numbers: Array, selected_turn: int) -> void:
	_replay_turn_numbers.clear()
	for raw_turn in turn_numbers:
		_replay_turn_numbers.append(int(raw_turn))
	var fallback_turn: int = _replay_turn_numbers[_replay_turn_numbers.size() - 1] if not _replay_turn_numbers.is_empty() else 0
	_selected_replay_turn = selected_turn if selected_turn > 0 else fallback_turn
	if replay_turn_picker:
		_updating_replay_picker = true
		replay_turn_picker.clear()
		for turn_number in _replay_turn_numbers:
			replay_turn_picker.add_item("Turn %d" % turn_number)
		var selected_index: int = _replay_turn_numbers.find(_selected_replay_turn)
		if selected_index < 0 and not _replay_turn_numbers.is_empty():
			selected_index = _replay_turn_numbers.size() - 1
			_selected_replay_turn = _replay_turn_numbers[selected_index]
		if selected_index >= 0:
			replay_turn_picker.select(selected_index)
		_updating_replay_picker = false
	_update_replay_controls()

func _on_replay_turn_selected(index: int) -> void:
	if _updating_replay_picker:
		return
	if index < 0 or index >= _replay_turn_numbers.size():
		return
	_selected_replay_turn = _replay_turn_numbers[index]
	_update_replay_controls()

func _update_replay_controls() -> void:
	var has_history: bool = not _replay_turn_numbers.is_empty()
	var is_planning: bool = true
	if _units_node != null:
		is_planning = _units_node.battle_phase == BattlePhase.Phase.PLANNING
	if replay_button:
		replay_button.disabled = (not _replay_available) or (not has_history) or _replay_in_progress or (not is_planning)
	if replay_turn_picker:
		replay_turn_picker.disabled = (not has_history) or _replay_in_progress or (not is_planning)

func _on_tile_resource_changed(_q: int, _r: int, _resource_type: String, _amount: int, _max_amount: int, _reason: String) -> void:
	_update_hovered_tile_resource()

func _on_scenarios_pressed() -> void:
	get_tree().change_scene_to_file("res://src/battle/scenario_picker.tscn")

func _process(_delta: float) -> void:
	_update_hovered_tile_resource()

func _update_resource_inventory() -> void:
	if resources_label == null:
		return
	var inventory: Dictionary = _get_player_resource_inventory()
	if inventory.is_empty():
		resources_label.text = "None"
		return
	var keys: Array = inventory.keys()
	keys.sort()
	var lines: Array[String] = []
	for key in keys:
		lines.append("%s: %d" % [str(key).capitalize(), int(inventory.get(key, 0))])
	resources_label.text = "\n".join(lines)

func _get_player_resource_inventory() -> Dictionary:
	if _units_node == null:
		return {}
	var group_name := _units_node.multiplayer_my_group
	if group_name.is_empty():
		if _units_node.groups.is_empty():
			return {}
		group_name = str(_units_node.groups[0].name)
	for g in _units_node.groups:
		if str(g.name) != group_name:
			continue
		if g.has_meta("resource_inventory"):
			var data = g.get_meta("resource_inventory")
			if data is Dictionary:
				return data.duplicate(true)
		return {}
	return {}

func _update_hovered_tile_resource() -> void:
	if hovered_tile_label == null:
		return
	if _hex_map_node == null or not _hex_map_node.has_method("get_resource_info_at_cell"):
		hovered_tile_label.text = "Hover: n/a"
		return
	var scene = get_tree().current_scene
	if not (scene is Node2D):
		hovered_tile_label.text = "Hover: n/a"
		return
	var mouse_world: Vector2 = scene.get_global_mouse_position()
	var cell: Vector2 = Navigation.world_to_cell(mouse_world)
	var cell_i := Vector2i(int(cell.x), int(cell.y))
	if not Navigation.is_valid_cell(cell):
		hovered_tile_label.text = "Hover: out of map"
		return
	var info: Dictionary = _hex_map_node.get_resource_info_at_cell(cell_i)
	var lines: Array[String] = [_build_hovered_resource_line(cell_i, info)]
	var units_at_cell: Array = _get_visible_units_at_hovered_cell(cell_i)
	if units_at_cell.is_empty():
		lines.append("Units: none")
	else:
		lines.append("Units (%d):" % units_at_cell.size())
		for unit in units_at_cell:
			lines.append("- %s" % _format_hovered_unit_line(unit))
	hovered_tile_label.text = "\n".join(lines)

func _build_hovered_resource_line(cell_i: Vector2i, info: Dictionary) -> String:
	if info.is_empty():
		return "Hover [%d,%d]: no resource" % [cell_i.x, cell_i.y]
	var rtype: String = str(info.get("resource_type", "resource"))
	var amount: int = int(info.get("amount", 0))
	var max_amount: int = int(info.get("max_amount", 0))
	if rtype == "people":
		return "Hover [%d,%d]: village people %d/%d" % [cell_i.x, cell_i.y, amount, max_amount]
	return "Hover [%d,%d]: %s %d/%d" % [cell_i.x, cell_i.y, rtype, amount, max_amount]

func _get_visible_units_at_hovered_cell(cell_i: Vector2i) -> Array:
	var result: Array = []
	if _units_node == null:
		return result
	var all_units: Array[Unit] = _units_node.get_all_units()
	for unit in all_units:
		if not is_instance_valid(unit) or not unit.is_active or not unit.visible:
			continue
		var unit_cell := unit.cell
		if int(unit_cell.x) == cell_i.x and int(unit_cell.y) == cell_i.y:
			result.append(unit)
	return result

func _format_hovered_unit_line(unit: Unit) -> String:
	var unit_name: String = unit.def.name if unit.def else "Unit"
	var group_name: String = unit.get_parent().name if unit.get_parent() else "?"
	var energy_now: int = unit.energy if unit.max_energy > 0 else 0
	var energy_max: int = unit.max_energy if unit.max_energy > 0 else 0
	return "[%s] %s HP %d/%d E %d/%d" % [group_name, unit_name, unit.health, unit.max_health, energy_now, energy_max]
