extends PanelContainer
## Shows selected replay turn actions, including dead units.

@onready var title_label: Label = $margin/vbox/title
@onready var lines_container: VBoxContainer = $margin/vbox/lines

func _ready() -> void:
	EventBus.show_replay_summary.connect(_on_show_replay_summary)
	EventBus.turn_changed.connect(_on_turn_changed)
	EventBus.replay_finished.connect(_on_replay_finished)
	hide()

func _on_show_replay_summary(lines: Array, title: String) -> void:
	title_label.text = title
	for c in lines_container.get_children():
		c.queue_free()
	for line in lines:
		var s := str(line)
		var lbl := Label.new()
		lbl.text = s
		if s.length() > 0 and s.begins_with("  "):
			lbl.theme_type_variation = "UiHint"
		lines_container.add_child(lbl)
	show()

func _on_turn_changed(_turn_number: int) -> void:
	hide()

func _on_replay_finished() -> void:
	hide()
