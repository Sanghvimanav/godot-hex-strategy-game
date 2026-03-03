class_name CustomScenarioBuilderPopup
extends CanvasLayer

signal configuration_applied

@onready var backdrop: ColorRect = $backdrop
@onready var terran_list: VBoxContainer = $panel/margin/vbox/columns/terran_column/scroll/list
@onready var zerg_list: VBoxContainer = $panel/margin/vbox/columns/zerg_column/scroll/list
@onready var reset_btn: Button = $panel/margin/vbox/buttons/reset_btn
@onready var cancel_btn: Button = $panel/margin/vbox/buttons/cancel_btn
@onready var apply_btn: Button = $panel/margin/vbox/buttons/apply_btn

var _terran_spinboxes: Dictionary = {}
var _zerg_spinboxes: Dictionary = {}
var _rows_built: bool = false

func _ready() -> void:
	if backdrop:
		backdrop.gui_input.connect(_on_backdrop_gui_input)
	if reset_btn:
		reset_btn.pressed.connect(_on_reset_pressed)
	if cancel_btn:
		cancel_btn.pressed.connect(_on_cancel_pressed)
	if apply_btn:
		apply_btn.pressed.connect(_on_apply_pressed)
	_build_rows_if_needed()
	visible = false

func open_builder() -> void:
	_build_rows_if_needed()
	_sync_spinboxes_from_counts(Scenarios.get_custom_scenario_counts())
	visible = true

func close_builder() -> void:
	visible = false

func _build_rows_if_needed() -> void:
	if _rows_built:
		return
	_build_rows_for_faction("terran", terran_list, _terran_spinboxes)
	_build_rows_for_faction("zerg", zerg_list, _zerg_spinboxes)
	_rows_built = true

func _build_rows_for_faction(faction_key: String, container: VBoxContainer, spinbox_map: Dictionary) -> void:
	for child in container.get_children():
		child.queue_free()
	spinbox_map.clear()
	for entry in Scenarios.get_custom_scenario_unit_counts_for_faction(faction_key):
		var def_path: String = str(entry.get("def_path", ""))
		if def_path.is_empty():
			continue
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var label := Label.new()
		label.text = str(entry.get("name", def_path))
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		row.add_child(label)
		var spin := SpinBox.new()
		spin.min_value = 0
		spin.max_value = 30
		spin.step = 1
		spin.rounded = true
		spin.value = int(entry.get("count", 0))
		spin.custom_minimum_size = Vector2(90, 0)
		row.add_child(spin)
		container.add_child(row)
		spinbox_map[def_path] = spin

func _sync_spinboxes_from_counts(counts: Dictionary) -> void:
	_sync_faction_spinboxes("terran", _terran_spinboxes, counts.get("terran", {}))
	_sync_faction_spinboxes("zerg", _zerg_spinboxes, counts.get("zerg", {}))

func _sync_faction_spinboxes(_faction_key: String, spinbox_map: Dictionary, faction_counts: Dictionary) -> void:
	if not (faction_counts is Dictionary):
		return
	for def_path in spinbox_map:
		var spin: SpinBox = spinbox_map[def_path] as SpinBox
		if spin == null:
			continue
		spin.value = maxi(0, int(faction_counts.get(def_path, 0)))

func _collect_counts_from_spinboxes() -> Dictionary:
	return {
		"terran": _collect_counts_for_faction(_terran_spinboxes),
		"zerg": _collect_counts_for_faction(_zerg_spinboxes),
	}

func _collect_counts_for_faction(spinbox_map: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for def_path in spinbox_map:
		var spin: SpinBox = spinbox_map[def_path] as SpinBox
		if spin == null:
			continue
		out[def_path] = maxi(0, int(spin.value))
	return out

func _on_reset_pressed() -> void:
	_sync_spinboxes_from_counts(Scenarios.get_default_custom_scenario_counts())

func _on_cancel_pressed() -> void:
	close_builder()

func _on_apply_pressed() -> void:
	Scenarios.set_custom_scenario_counts(_collect_counts_from_spinboxes())
	configuration_applied.emit()
	close_builder()

func _on_backdrop_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		close_builder()
