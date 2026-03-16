extends PanelContainer
## Action selector UI for the current unit. Shows action buttons; selecting one
## filters the board options to that action only (strategy_game_v8 style).

@onready var unit_label: Label = $margin/vbox/unit_label
@onready var effects_label: Label = $margin/vbox/effects_label
@onready var move_buttons: HFlowContainer = $margin/vbox/move_group/buttons
@onready var ability_buttons: HFlowContainer = $margin/vbox/ability_group/buttons
@onready var passive_list: VBoxContainer = $margin/vbox/passive_group/passive_list
@onready var show_all_btn: Button = $margin/vbox/show_all_btn

var _current_unit: Unit
var _selected_action_key: String = ""

func _ready() -> void:
	EventBus.unit_selected_for_planning.connect(_on_unit_selected)
	show_all_btn.pressed.connect(_on_show_all_pressed)
	hide()

func _on_unit_selected(unit: Unit) -> void:
	_current_unit = unit
	_selected_action_key = ""
	_update_display()

func _update_display() -> void:
	if _current_unit == null:
		hide()
		return
	show()
	var hp_text := "%s (%d/%d HP)" % [_current_unit.def.name, _current_unit.health, _current_unit.max_health]
	if _current_unit.max_energy > 0:
		hp_text += "  %d/%d E" % [_current_unit.energy, _current_unit.max_energy]
	unit_label.text = hp_text
	effects_label.text = "Effects: %s" % _current_unit.get_effects_display_text()
	show_all_btn.visible = not _selected_action_key.is_empty()
	_rebuild_buttons()

func _rebuild_buttons() -> void:
	_clear_buttons(move_buttons)
	_clear_buttons(ability_buttons)
	for c in passive_list.get_children():
		c.queue_free()
	if _current_unit == null:
		return
	var def: UnitDefinition = _current_unit.def
	for key in def.get_move_action_keys_resolved():
		var availability: Dictionary = _current_unit.abilities_db.get_action_availability(key)
		_add_action_button(
			move_buttons,
			key,
			true,
			bool(availability.get("available", false)),
			str(availability.get("reason", ""))
		)
	for key in def.get_ability_action_keys_resolved():
		var availability: Dictionary = _current_unit.abilities_db.get_action_availability(key)
		_add_action_button(
			ability_buttons,
			key,
			false,
			bool(availability.get("available", false)),
			str(availability.get("reason", ""))
		)
	for key in def.passive_action_keys:
		var config: Dictionary = Actions.get_action_config(key)
		var name_str: String = config.get("name", key)
		var info := Label.new()
		info.text = "  • %s" % name_str
		info.add_theme_font_size_override("font_size", 12)
		info.add_theme_color_override("font_color", Color(0.75, 0.75, 0.75))
		passive_list.add_child(info)

func _clear_buttons(container: Control) -> void:
	for c in container.get_children():
		c.queue_free()

func _add_action_button(parent: Control, action_key: String, _is_move: bool, is_available: bool, unavailable_reason: String) -> void:
	var config: Dictionary = Actions.ACTION_CONFIGS.get(action_key, {})
	var name_str: String = config.get("name", action_key)
	var color_hex: String = config.get("color", "#888888")
	var btn := Button.new()
	btn.text = name_str
	btn.custom_minimum_size = Vector2(90, 36)
	btn.pressed.connect(_on_action_pressed.bind(action_key))
	btn.disabled = not is_available
	if btn.disabled:
		btn.tooltip_text = unavailable_reason if not unavailable_reason.is_empty() else "Unavailable right now"
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(color_hex)
	bg.corner_radius_top_left = 4
	bg.corner_radius_top_right = 4
	bg.corner_radius_bottom_right = 4
	bg.corner_radius_bottom_left = 4
	btn.add_theme_stylebox_override("normal", bg)
	var disabled_bg := StyleBoxFlat.new()
	disabled_bg.bg_color = Color(color_hex).darkened(0.45)
	disabled_bg.corner_radius_top_left = 4
	disabled_bg.corner_radius_top_right = 4
	disabled_bg.corner_radius_bottom_right = 4
	disabled_bg.corner_radius_bottom_left = 4
	btn.add_theme_stylebox_override("disabled", disabled_bg)
	btn.add_theme_color_override("font_color", Color.WHITE)
	btn.add_theme_color_override("font_disabled_color", Color(0.8, 0.8, 0.8))
	var planned_key: String = ""
	if _current_unit and _current_unit.planned_action and _current_unit.planned_action.definition:
		planned_key = _current_unit.planned_action.definition.action_key
	var is_planned_action: bool = (action_key == planned_key)
	var border_color: Color = Color.TRANSPARENT
	if is_planned_action:
		border_color = Color(0.2, 0.9, 0.2)
	elif action_key == _selected_action_key and is_available:
		border_color = Color.WHITE
	if border_color != Color.TRANSPARENT:
		var sel := StyleBoxFlat.new()
		sel.bg_color = Color(color_hex).lightened(0.1) if action_key == _selected_action_key and is_available else Color(color_hex)
		sel.corner_radius_top_left = 4
		sel.corner_radius_top_right = 4
		sel.corner_radius_bottom_right = 4
		sel.corner_radius_bottom_left = 4
		sel.border_width_left = 2
		sel.border_width_right = 2
		sel.border_width_top = 2
		sel.border_width_bottom = 2
		sel.border_color = border_color
		btn.add_theme_stylebox_override("normal", sel)
	if is_planned_action:
		var planned_disabled := StyleBoxFlat.new()
		planned_disabled.bg_color = Color(color_hex).darkened(0.45)
		planned_disabled.corner_radius_top_left = 4
		planned_disabled.corner_radius_top_right = 4
		planned_disabled.corner_radius_bottom_right = 4
		planned_disabled.corner_radius_bottom_left = 4
		planned_disabled.border_width_left = 2
		planned_disabled.border_width_right = 2
		planned_disabled.border_width_top = 2
		planned_disabled.border_width_bottom = 2
		planned_disabled.border_color = Color(0.2, 0.9, 0.2)
		btn.add_theme_stylebox_override("disabled", planned_disabled)
	parent.add_child(btn)

func _on_action_pressed(action_key: String) -> void:
	if _selected_action_key == action_key:
		_selected_action_key = ""
	else:
		_selected_action_key = action_key
	show_all_btn.visible = not _selected_action_key.is_empty()
	EventBus.action_key_selected.emit(_selected_action_key)
	_rebuild_buttons()

func _on_show_all_pressed() -> void:
	_selected_action_key = ""
	show_all_btn.visible = false
	EventBus.action_key_selected.emit("")
	_rebuild_buttons()
