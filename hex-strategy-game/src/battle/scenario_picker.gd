extends CanvasLayer
## Scenario selection UI shown at game start. Pick a scenario and start battle.

@onready var main_list: VBoxContainer = $panel/margin/vbox/columns/main_column/main_list
@onready var debug_list: VBoxContainer = $panel/margin/vbox/columns/debug_column/debug_list
@onready var start_btn: Button = $panel/margin/vbox/start_btn

func _ready() -> void:
	_rebuild_buttons()
	if start_btn:
		start_btn.pressed.connect(_on_start_pressed)

func _rebuild_buttons() -> void:
	if not main_list or not debug_list:
		return
	for c in main_list.get_children():
		c.queue_free()
	for c in debug_list.get_children():
		c.queue_free()
	var by_category: Dictionary = Scenarios.get_scenarios_by_category()
	for s in by_category.main:
		_add_scenario_button(main_list, s)
	for s in by_category.debug:
		_add_scenario_button(debug_list, s)

func _add_scenario_button(container: VBoxContainer, s: Dictionary) -> void:
	var btn := Button.new()
	btn.text = s.display_name
	btn.toggle_mode = true
	btn.button_group = _get_button_group()
	if s.id == Scenarios.selected_scenario_id:
		btn.button_pressed = true
	btn.pressed.connect(_on_scenario_pressed.bind(s.id))
	container.add_child(btn)

var _btn_group: ButtonGroup
func _get_button_group() -> ButtonGroup:
	if _btn_group == null:
		_btn_group = ButtonGroup.new()
	return _btn_group

func _on_scenario_pressed(id: String) -> void:
	Scenarios.select_scenario(id)

func _on_start_pressed() -> void:
	get_tree().change_scene_to_file("res://src/battle/battle.tscn")
