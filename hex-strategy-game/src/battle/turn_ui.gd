extends CanvasLayer

@onready var execute_button: Button = $turn_panel/vbox/execute_button
@onready var replay_button: Button = $turn_panel/vbox/replay_button
@onready var turn_label: Label = $turn_panel/vbox/turn_label
@onready var scenarios_button: Button = $turn_panel/vbox/scenarios_button
@onready var resources_label: Label = $resources_panel/margin/vbox/resources_label
@onready var hovered_tile_label: Label = $resources_panel/margin/vbox/hovered_tile_label

var _units_node: UnitsContainer
var _hex_map_node: Node

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
	if info.is_empty():
		hovered_tile_label.text = "Hover [%d,%d]: no resource" % [cell_i.x, cell_i.y]
		return
	var rtype: String = str(info.get("resource_type", "resource"))
	var amount: int = int(info.get("amount", 0))
	var max_amount: int = int(info.get("max_amount", 0))
	hovered_tile_label.text = "Hover [%d,%d]: %s %d/%d" % [cell_i.x, cell_i.y, rtype, amount, max_amount]
