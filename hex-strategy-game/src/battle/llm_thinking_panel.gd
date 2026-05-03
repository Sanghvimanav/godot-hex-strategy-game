extends PanelContainer
## Displays the LLM's chain-of-thought reasoning (thinking tokens from the model),
## plus the parsed opponent prediction and reasoning summary fields.
## Toggled via a button in turn_panel; auto-updates each planning phase.

@onready var title_label: Label = $margin/vbox/header/title
@onready var close_button: Button = $margin/vbox/header/close_button
@onready var entries_container: VBoxContainer = $margin/vbox/scroll/entries

var _entries: Array[Dictionary] = []


func _ready() -> void:
	EventBus.llm_thinking_updated.connect(_on_llm_thinking_updated)
	EventBus.planning_started.connect(_on_planning_started)
	close_button.pressed.connect(func(): hide())
	hide()


func toggle() -> void:
	visible = not visible


func _on_planning_started() -> void:
	_entries.clear()
	_rebuild_ui()


func _on_llm_thinking_updated(source: String, thinking: String, opponent_prediction: String, reasoning_summary: String) -> void:
	_entries.append({
		"source": source,
		"thinking": thinking,
		"opponent_prediction": opponent_prediction,
		"reasoning_summary": reasoning_summary,
	})
	_rebuild_ui()
	if not visible:
		show()


func _rebuild_ui() -> void:
	for c in entries_container.get_children():
		c.queue_free()
	if _entries.is_empty():
		var empty_lbl := Label.new()
		empty_lbl.theme_type_variation = "UiHint"
		empty_lbl.text = "Waiting for LLM response…"
		entries_container.add_child(empty_lbl)
		return
	for i in _entries.size():
		var entry: Dictionary = _entries[i]
		if i > 0:
			entries_container.add_child(HSeparator.new())
		_add_entry(entry)


func _add_entry(entry: Dictionary) -> void:
	var source: String = str(entry.get("source", "ai"))
	var label_text: String = "AI" if source == "ai" else source.replace("drill:", "Drill: ").capitalize()

	var source_lbl := Label.new()
	source_lbl.theme_type_variation = "UiFormLabel"
	source_lbl.text = label_text
	entries_container.add_child(source_lbl)

	var thinking: String = str(entry.get("thinking", ""))
	if not thinking.is_empty():
		_add_section("Chain of Thought", thinking)

	var op: String = str(entry.get("opponent_prediction", ""))
	if not op.is_empty():
		_add_section("Opponent Prediction", op)

	var rs: String = str(entry.get("reasoning_summary", ""))
	if not rs.is_empty():
		_add_section("Reasoning", rs)

	if thinking.is_empty() and op.is_empty() and rs.is_empty():
		var none_lbl := Label.new()
		none_lbl.theme_type_variation = "UiHint"
		none_lbl.text = "(no thinking data returned by model)"
		entries_container.add_child(none_lbl)


func _add_section(heading_text: String, body_text: String) -> void:
	var heading := Label.new()
	heading.theme_type_variation = "UiFormLabel"
	heading.text = heading_text
	entries_container.add_child(heading)
	var body := Label.new()
	body.text = body_text
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.theme_type_variation = "UiHint"
	entries_container.add_child(body)
