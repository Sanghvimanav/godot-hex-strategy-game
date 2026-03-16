extends CanvasLayer
## Scenario selection UI shown at game start. Pick a scenario and start battle.

@onready var main_list: VBoxContainer = $panel/margin/vbox/columns/main_column/main_list
@onready var campaign_list: VBoxContainer = $panel/margin/vbox/columns/campaign_column/campaign_list
@onready var debug_list: VBoxContainer = $panel/margin/vbox/columns/debug_column/debug_list
@onready var start_btn: Button = $panel/margin/vbox/start_btn
@onready var custom_builder_btn: Button = $panel/margin/vbox/custom_builder_btn
@onready var custom_builder_popup: CustomScenarioBuilderPopup = $custom_builder_popup

func _ready() -> void:
	_rebuild_buttons()
	if start_btn:
		start_btn.pressed.connect(_on_start_pressed)
	if custom_builder_btn:
		custom_builder_btn.pressed.connect(_on_custom_builder_pressed)
	if custom_builder_popup and custom_builder_popup.has_signal("configuration_applied"):
		custom_builder_popup.configuration_applied.connect(_on_custom_builder_applied)
	_refresh_custom_controls()

func _rebuild_buttons() -> void:
	if not main_list or not campaign_list or not debug_list:
		return
	for c in main_list.get_children():
		c.queue_free()
	for c in campaign_list.get_children():
		c.queue_free()
	for c in debug_list.get_children():
		c.queue_free()
	var by_category: Dictionary = Scenarios.get_scenarios_by_category()
	for s in by_category.get("campaign", []):
		_add_scenario_button(campaign_list, s)
	for s in by_category.get("main", []):
		_add_scenario_button(main_list, s)
	for s in by_category.get("debug", []):
		_add_scenario_button(debug_list, s)
	_refresh_custom_controls()

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
	_refresh_custom_controls()
	if Scenarios.is_custom_scenario_id(id):
		_open_custom_builder()

func _on_start_pressed() -> void:
	get_tree().change_scene_to_file("res://src/battle/battle.tscn")

func _on_custom_builder_pressed() -> void:
	_open_custom_builder()

func _on_custom_builder_applied() -> void:
	_refresh_custom_controls()

func _open_custom_builder() -> void:
	if custom_builder_popup and custom_builder_popup.has_method("open_builder"):
		custom_builder_popup.open_builder()

func _refresh_custom_controls() -> void:
	var is_custom: bool = Scenarios.is_custom_scenario_id(Scenarios.selected_scenario_id)
	if custom_builder_btn:
		custom_builder_btn.visible = is_custom
	if start_btn:
		start_btn.text = "Start Custom Battle" if is_custom else "Start Battle"
