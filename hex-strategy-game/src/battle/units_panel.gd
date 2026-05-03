extends PanelContainer
## Units panel: when multiple player units are on the same hex, shows a list to pick which to plan for.
## Hovering a unit shows that unit's action menu in a panel below.
## Uses global Actions autoload (do not preload actions.gd here).

@onready var title_label: Label = $margin/vbox/title
@onready var units_list: VBoxContainer = $margin/vbox/units_list
@onready var hover_panel: PanelContainer = $margin/vbox/hover_panel
@onready var hover_vbox: VBoxContainer = $margin/vbox/hover_panel/hover_margin/hover_vbox
@onready var hover_hide_timer: Timer = $hover_hide_timer

func _ready() -> void:
	EventBus.show_units_panel.connect(_on_show_units_panel)
	EventBus.planning_started.connect(_on_planning_started)
	hover_hide_timer.timeout.connect(_on_hover_hide_timer_timeout)
	hover_panel.mouse_entered.connect(_on_hover_panel_mouse_entered)
	hover_panel.mouse_exited.connect(_on_hover_panel_mouse_exited)
	hide()

func _on_planning_started() -> void:
	hide()
	hover_panel.visible = false

func _on_show_units_panel(units: Array) -> void:
	if units.is_empty():
		hide()
		hover_panel.visible = false
		return
	title_label.text = "Select unit at hex (%d, %d)" % [int(units[0].cell.x), int(units[0].cell.y)]
	for c in units_list.get_children():
		c.queue_free()
	hover_panel.visible = false
	for u in units:
		var btn := Button.new()
		var text := "%s (%d/%d HP)" % [u.def.name, u.health, u.max_health]
		if u.max_energy > 0:
			text += "  %d/%d E" % [u.energy, u.max_energy]
		if not u.active_effects.is_empty():
			text += "  [%s]" % u.get_effects_display_text()
		btn.text = text
		btn.pressed.connect(_on_unit_picked.bind(u))
		btn.mouse_entered.connect(_on_unit_button_mouse_entered.bind(u, btn))
		btn.mouse_exited.connect(_on_unit_button_mouse_exited)
		units_list.add_child(btn)
	show()

func _on_unit_button_mouse_entered(unit: Unit, _btn: Control) -> void:
	hover_hide_timer.stop()
	_build_hover_content(unit)
	hover_panel.visible = true

func _on_unit_button_mouse_exited() -> void:
	hover_hide_timer.start()

func _on_hover_panel_mouse_entered() -> void:
	hover_hide_timer.stop()

func _on_hover_panel_mouse_exited() -> void:
	hover_hide_timer.start()

func _on_hover_hide_timer_timeout() -> void:
	hover_panel.visible = false

func _build_hover_content(unit: Unit) -> void:
	for c in hover_vbox.get_children():
		c.queue_free()
	var def: UnitDefinition = unit.def
	var top := Label.new()
	var hp_text := "%s (%d/%d HP)" % [def.name, unit.health, unit.max_health]
	if unit.max_energy > 0:
		hp_text += "  %d/%d E" % [unit.energy, unit.max_energy]
	top.text = hp_text
	top.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	top.theme_type_variation = "UiFormLabel"
	hover_vbox.add_child(top)
	var effects_lbl := Label.new()
	effects_lbl.text = "Effects: %s" % unit.get_effects_display_text()
	effects_lbl.theme_type_variation = "UiHint"
	hover_vbox.add_child(effects_lbl)
	var move_lbl := Label.new()
	move_lbl.text = "Move: %s" % _format_action_keys(def.move_action_keys)
	move_lbl.theme_type_variation = "UiHint"
	hover_vbox.add_child(move_lbl)
	var ability_lbl := Label.new()
	ability_lbl.text = "Abilities: %s" % _format_action_keys(def.ability_action_keys)
	ability_lbl.theme_type_variation = "UiHint"
	hover_vbox.add_child(ability_lbl)
	if def.passive_action_keys.size() > 0:
		var passive_lbl := Label.new()
		passive_lbl.text = "Passives: %s" % _format_action_keys(def.passive_action_keys)
		passive_lbl.theme_type_variation = "UiHint"
		hover_vbox.add_child(passive_lbl)

func _format_action_keys(keys: Array) -> String:
	if keys.is_empty():
		return "—"
	var names: Array[String] = []
	for key in keys:
		var config: Dictionary = Actions.get_action_config(key)
		names.append(config.get("name", key))
	return ", ".join(names)

func _on_unit_picked(unit: Unit) -> void:
	hide()
	EventBus.unit_pick_requested.emit(unit)
