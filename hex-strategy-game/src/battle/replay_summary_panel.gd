extends PanelContainer
## Shows selected replay turn actions, including dead units.

@onready var title_label: Label = $margin/vbox/title
@onready var lines_container: VBoxContainer = $margin/vbox/lines

func _agent_debug_log(hypothesis_id: String, location: String, message: String, data: Dictionary = {}) -> void:
	var file := FileAccess.open("/opt/cursor/logs/debug.log", FileAccess.READ_WRITE)
	if file == null:
		file = FileAccess.open("/opt/cursor/logs/debug.log", FileAccess.WRITE_READ)
	if file == null:
		return
	file.seek_end()
	file.store_line(JSON.stringify({
		"hypothesisId": hypothesis_id,
		"location": location,
		"message": message,
		"data": data,
		"timestamp": int(Time.get_unix_time_from_system() * 1000.0)
	}))
	file.close()

func _ready() -> void:
	EventBus.show_replay_summary.connect(_on_show_replay_summary)
	EventBus.replay_finished.connect(_on_replay_finished)
	EventBus.turn_changed.connect(_on_turn_changed)
	hide()

func _on_show_replay_summary(lines: Array, title: String) -> void:
	#region agent log
	_agent_debug_log("H5", "replay_summary_panel.gd:_on_show_replay_summary", "Replay summary panel received signal", {
		"title": title,
		"line_count": lines.size()
	})
	#endregion
	title_label.text = title
	for c in lines_container.get_children():
		c.queue_free()
	for line in lines:
		var s := str(line)
		var lbl := Label.new()
		lbl.text = s
		if s.length() > 0 and not s.begins_with("  "):
			lbl.add_theme_font_size_override("font_size", 14)
			lbl.add_theme_color_override("font_color", Color(0.95, 0.95, 0.95))
		lines_container.add_child(lbl)
	show()

func _on_replay_finished() -> void:
	#region agent log
	_agent_debug_log("H6", "replay_summary_panel.gd:_on_replay_finished", "Replay finished received; keeping summary visible", {
		"visible_before": visible,
		"visible_after": visible
	})
	#endregion

func _on_turn_changed(_turn_number: int) -> void:
	hide()
