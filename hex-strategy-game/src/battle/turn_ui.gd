extends CanvasLayer

@onready var execute_button: Button = $turn_panel/vbox/execute_button
@onready var replay_button: Button = $turn_panel/vbox/replay_button
@onready var turn_label: Label = $turn_panel/vbox/turn_label
@onready var scenarios_button: Button = $turn_panel/vbox/scenarios_button
@onready var resources_panel: PanelContainer = $resources_panel
@onready var resources_label: Label = $resources_panel/margin/vbox/resources_label
@onready var hovered_tile_label: Label = $resources_panel/margin/vbox/hovered_tile_label

var _units_node: UnitsContainer
var _hex_map_node: Node
var _resources_panel_base_height := 0.0

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
		replay_button.disabled = true
	EventBus.planning_started.connect(_on_planning_started)
	EventBus.planning_complete.connect(_on_planning_complete)
	EventBus.turn_changed.connect(_on_turn_changed)
	EventBus.replay_available_changed.connect(_on_replay_available_changed)
	EventBus.replay_finished.connect(_on_replay_finished)
	EventBus.tile_resource_changed.connect(_on_tile_resource_changed)
	_units_node = get_parent().get_node_or_null("units") as UnitsContainer
	_hex_map_node = get_parent().get_node_or_null("hex_map")
	_resources_panel_base_height = resources_panel.offset_bottom - resources_panel.offset_top
	_update_resource_inventory()
	_update_hovered_tile_resource()
	_fit_resources_panel_to_content()
	set_process(true)

func _on_turn_changed(turn_number: int) -> void:
	if turn_label:
		turn_label.text = "Turn %d" % turn_number
	_update_resource_inventory()

func _on_planning_started() -> void:
	execute_button.disabled = true
	if MultiplayerState.is_multiplayer:
		execute_button.text = "Submit"
	_update_resource_inventory()

func _on_planning_complete() -> void:
	execute_button.disabled = false

func _on_execute_pressed() -> void:
	EventBus.execute_turn_requested.emit()
	execute_button.disabled = true
	if MultiplayerState.is_multiplayer:
		execute_button.text = "Waiting for other players..."

func _on_replay_pressed() -> void:
	EventBus.replay_turn_requested.emit()
	if replay_button:
		replay_button.disabled = true

func _on_replay_finished() -> void:
	if replay_button:
		replay_button.disabled = false

func _on_replay_available_changed(available: bool) -> void:
	if replay_button:
		replay_button.disabled = not available

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
	var next_text := "None"
	if inventory.is_empty():
		if resources_label.text != next_text:
			resources_label.text = next_text
			_fit_resources_panel_to_content()
		return
	var keys: Array = inventory.keys()
	keys.sort()
	var lines: Array[String] = []
	for key in keys:
		lines.append("%s: %d" % [str(key).capitalize(), int(inventory.get(key, 0))])
	next_text = "\n".join(lines)
	if resources_label.text != next_text:
		resources_label.text = next_text
		_fit_resources_panel_to_content()

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
	var next_text := "Hover: n/a"
	if _hex_map_node == null or not _hex_map_node.has_method("get_resource_info_at_cell"):
		if hovered_tile_label.text != next_text:
			hovered_tile_label.text = next_text
			_fit_resources_panel_to_content()
		return
	var scene = get_tree().current_scene
	if not (scene is Node2D):
		if hovered_tile_label.text != next_text:
			hovered_tile_label.text = next_text
			_fit_resources_panel_to_content()
		return
	var mouse_world: Vector2 = scene.get_global_mouse_position()
	var cell: Vector2 = Navigation.world_to_cell(mouse_world)
	var cell_i := Vector2i(int(cell.x), int(cell.y))
	if not Navigation.is_valid_cell(cell):
		next_text = "Hover: out of map"
		if hovered_tile_label.text != next_text:
			hovered_tile_label.text = next_text
			_fit_resources_panel_to_content()
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
	next_text = "\n".join(lines)
	if hovered_tile_label.text != next_text:
		hovered_tile_label.text = next_text
		_fit_resources_panel_to_content()

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

func _fit_resources_panel_to_content() -> void:
	if resources_panel == null:
		return
	var min_height := resources_panel.get_combined_minimum_size().y
	var desired_height: float = max(_resources_panel_base_height, min_height)
	var current_height := resources_panel.offset_bottom - resources_panel.offset_top
	if is_equal_approx(current_height, desired_height):
		return
	# Keep bottom edge fixed and grow upward when content needs more height.
	resources_panel.offset_top = resources_panel.offset_bottom - desired_height
