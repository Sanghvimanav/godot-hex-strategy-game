extends CanvasLayer
## Scenario selection UI shown at game start. Pick a scenario and start battle.

@onready var main_list: VBoxContainer = $center/panel/margin/vbox/columns/main_column/main_card/main_card_margin/main_card_inner/main_list
@onready var campaign_list: VBoxContainer = $center/panel/margin/vbox/columns/campaign_column/campaign_card/campaign_card_margin/campaign_card_inner/campaign_list
@onready var campaign_difficulty_row: HBoxContainer = $center/panel/margin/vbox/columns/campaign_column/campaign_difficulty_row
@onready var campaign_difficulty_option: OptionButton = $center/panel/margin/vbox/columns/campaign_column/campaign_difficulty_row/campaign_difficulty_option
@onready var team_selection_row: HBoxContainer = $center/panel/margin/vbox/columns/campaign_column/team_selection_row
@onready var team_selection_option: OptionButton = $center/panel/margin/vbox/columns/campaign_column/team_selection_row/team_selection_option
@onready var drill_list: VBoxContainer = $center/panel/margin/vbox/columns/drill_column/drill_card/drill_card_margin/drill_card_inner/drill_list
@onready var debug_list: VBoxContainer = $center/panel/margin/vbox/columns/debug_column/debug_card/debug_card_margin/debug_card_inner/debug_list
@onready var scenario_objective_label: Label = $center/panel/margin/vbox/objective_strip/objective_margin/scenario_objective_label
@onready var objective_strip: PanelContainer = $center/panel/margin/vbox/objective_strip
@onready var llm_settings_btn: Button = $center/panel/margin/vbox/actions_row/llm_settings_btn
@onready var ai_learnings_btn: Button = $center/panel/margin/vbox/actions_row/ai_learnings_btn
@onready var eval_leaderboard_btn: Button = $center/panel/margin/vbox/actions_row/eval_leaderboard_btn
@onready var start_btn: Button = $center/panel/margin/vbox/actions_row/start_btn
@onready var post_game_status: Label = $center/panel/margin/vbox/post_game_status
@onready var llm_http: HTTPRequest = $LlmHttpRequest

var _llm_settings: LlmAiSettings
var _llm_client: LlmOpenAiClient
var _llm_post_game: LlmPostGame = LlmPostGame.new()


func _ready() -> void:
	_llm_settings = LlmAiSettings.new()
	_llm_client = LlmOpenAiClient.new()
	_llm_settings.load_from_disk()

	_setup_campaign_difficulty_option()
	if campaign_difficulty_option:
		campaign_difficulty_option.custom_minimum_size.y = 36
	if team_selection_option:
		team_selection_option.custom_minimum_size.y = 36
	_rebuild_buttons()
	if start_btn:
		start_btn.pressed.connect(_on_start_pressed)
	if llm_settings_btn:
		llm_settings_btn.pressed.connect(_on_llm_settings_pressed)
	if ai_learnings_btn:
		ai_learnings_btn.pressed.connect(_on_ai_learnings_pressed)
	if eval_leaderboard_btn:
		eval_leaderboard_btn.pressed.connect(_on_eval_leaderboard_pressed)
	call_deferred("_run_post_game_if_pending")
	if campaign_difficulty_option:
		campaign_difficulty_option.item_selected.connect(_on_campaign_difficulty_selected)
	if team_selection_option:
		team_selection_option.item_selected.connect(_on_team_selected)


func _on_llm_settings_pressed() -> void:
	get_tree().change_scene_to_file("res://src/battle/llm_settings_page.tscn")


func _on_eval_leaderboard_pressed() -> void:
	get_tree().change_scene_to_file("res://src/battle/eval_leaderboard_page.tscn")


func _on_ai_learnings_pressed() -> void:
	var path := LlmLearningsIngest.canonical_learnings_path()
	var content := ""
	if FileAccess.file_exists(path):
		content = FileAccess.get_file_as_string(path).strip_edges()
	if content.is_empty():
		content = "(No AI learnings saved yet.\nPlay matches with an LLM API key configured to generate learnings.)"

	var overlay := ColorRect.new()
	overlay.color = Color(0, 0, 0, 0.6)
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(overlay)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(center)

	var panel := PanelContainer.new()
	panel.theme_type_variation = &"UiMainCard"
	panel.custom_minimum_size = Vector2(700, 500)
	center.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 24)
	margin.add_theme_constant_override("margin_right", 24)
	margin.add_theme_constant_override("margin_top", 22)
	margin.add_theme_constant_override("margin_bottom", 22)
	panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 14)
	margin.add_child(vbox)

	var title := Label.new()
	title.text = "AI Learnings"
	title.theme_type_variation = &"UiHeading"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	var subtitle := Label.new()
	subtitle.text = LlmLearningsIngest.canonical_learnings_path()
	subtitle.theme_type_variation = &"UiHint"
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(subtitle)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroll)

	var text_label := RichTextLabel.new()
	text_label.bbcode_enabled = false
	text_label.text = content
	text_label.fit_content = true
	text_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text_label.selection_enabled = true
	text_label.add_theme_font_size_override("normal_font_size", 13)
	scroll.add_child(text_label)

	var btn_row := HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_END
	btn_row.add_theme_constant_override("separation", 12)
	vbox.add_child(btn_row)

	var clear_btn := Button.new()
	clear_btn.text = "Clear All Learnings"
	clear_btn.custom_minimum_size.y = 38
	clear_btn.tooltip_text = "Delete all saved AI learnings from disk."
	btn_row.add_child(clear_btn)

	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.theme_type_variation = &"PrimaryButton"
	close_btn.custom_minimum_size = Vector2(100, 38)
	btn_row.add_child(close_btn)

	close_btn.pressed.connect(overlay.queue_free)
	overlay.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.pressed:
			overlay.queue_free()
	)
	clear_btn.pressed.connect(func() -> void:
		var result := LlmLearningsIngest.clear_saved_learnings_from_disk()
		var n: int = int(result.get("deleted_count", 0))
		text_label.text = "(Cleared %d file(s). No AI learnings on disk.)" % n
	)


func _setup_campaign_difficulty_option() -> void:
	if campaign_difficulty_option == null:
		return
	campaign_difficulty_option.clear()
	campaign_difficulty_option.add_item("Easy", 0)
	campaign_difficulty_option.add_item("Medium", 1)
	campaign_difficulty_option.add_item("Hard", 2)
	_sync_campaign_difficulty_option_from_scenarios()


func _campaign_difficulty_option_index(diff: String) -> int:
	match Scenarios.normalize_campaign_difficulty(diff):
		"easy":
			return 0
		"hard":
			return 2
		_:
			return 1


func _sync_campaign_difficulty_option_from_scenarios() -> void:
	if campaign_difficulty_option:
		campaign_difficulty_option.select(_campaign_difficulty_option_index(Scenarios.campaign_difficulty))


func _refresh_campaign_difficulty_row() -> void:
	var show_row := Scenarios.scenario_supports_campaign_difficulty(Scenarios.selected_scenario_id)
	if campaign_difficulty_row:
		campaign_difficulty_row.visible = show_row
	if campaign_difficulty_option:
		campaign_difficulty_option.disabled = not show_row
	if show_row:
		_sync_campaign_difficulty_option_from_scenarios()


func _on_campaign_difficulty_selected(idx: int) -> void:
	var d := "medium"
	match idx:
		0:
			d = "easy"
		2:
			d = "hard"
	Scenarios.set_campaign_difficulty(d)


func _refresh_team_selection_row() -> void:
	var group_names := Scenarios.get_group_names_for_scenario(Scenarios.selected_scenario_id)
	var show_row := group_names.size() >= 2
	if team_selection_row:
		team_selection_row.visible = show_row
	if not show_row or team_selection_option == null:
		return
	team_selection_option.clear()
	for i in group_names.size():
		team_selection_option.add_item(_format_group_name(group_names[i]), i)
	var current := Scenarios.player_group_name
	if current.is_empty():
		team_selection_option.select(0)
	else:
		var found := false
		for i in group_names.size():
			if group_names[i] == current:
				team_selection_option.select(i)
				found = true
				break
		if not found:
			team_selection_option.select(0)


func _format_group_name(group_name: String) -> String:
	return group_name.capitalize()


func _on_team_selected(idx: int) -> void:
	var group_names := Scenarios.get_group_names_for_scenario(Scenarios.selected_scenario_id)
	if idx >= 0 and idx < group_names.size():
		Scenarios.set_player_group(group_names[idx])


func _rebuild_buttons() -> void:
	if not main_list or not campaign_list or not debug_list:
		return
	for c in main_list.get_children():
		c.queue_free()
	for c in campaign_list.get_children():
		c.queue_free()
	if drill_list:
		for c in drill_list.get_children():
			c.queue_free()
	for c in debug_list.get_children():
		c.queue_free()
	var by_category: Dictionary = Scenarios.get_scenarios_by_category()
	for s in by_category.get("campaign", []):
		if _should_show_scenario_in_menu(s):
			_add_scenario_button(campaign_list, s)
	for s in by_category.get("main", []):
		if _should_show_scenario_in_menu(s):
			_add_scenario_button(main_list, s)
	if drill_list:
		for s in by_category.get("drill", []):
			if _should_show_scenario_in_menu(s):
				_add_scenario_button(drill_list, s)
	for s in by_category.get("debug", []):
		if _should_show_scenario_in_menu(s):
			_add_scenario_button(debug_list, s)
	_refresh_scenario_objective_label()
	_refresh_campaign_difficulty_row()
	_refresh_team_selection_row()


func _should_show_scenario_in_menu(s: Dictionary) -> bool:
	var sid: String = str(s.get("id", ""))
	return not sid.begins_with("eval_")


func _refresh_scenario_objective_label() -> void:
	if scenario_objective_label == null:
		return
	var s: Dictionary = Scenarios.get_scenario_by_id(Scenarios.selected_scenario_id)
	var txt: String = str(s.get("description", "")).strip_edges()
	scenario_objective_label.text = txt
	var has_txt := not txt.is_empty()
	scenario_objective_label.visible = has_txt
	if objective_strip:
		objective_strip.visible = has_txt

func _add_scenario_button(container: VBoxContainer, s: Dictionary) -> void:
	var btn := Button.new()
	btn.text = s.display_name
	btn.toggle_mode = true
	btn.button_group = _get_button_group()
	if s.id == Scenarios.selected_scenario_id:
		btn.button_pressed = true
	btn.pressed.connect(_on_scenario_pressed.bind(s.id))
	var desc: String = str(s.get("description", "")).strip_edges()
	if not desc.is_empty():
		btn.tooltip_text = desc
	btn.theme_type_variation = "ScenarioToggle"
	btn.custom_minimum_size.y = 42
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	container.add_child(btn)

var _btn_group: ButtonGroup
func _get_button_group() -> ButtonGroup:
	if _btn_group == null:
		_btn_group = ButtonGroup.new()
	return _btn_group


func _on_scenario_pressed(id: String) -> void:
	Scenarios.select_scenario(id)
	_refresh_scenario_objective_label()
	_refresh_campaign_difficulty_row()
	_refresh_team_selection_row()

func _on_start_pressed() -> void:
	get_tree().change_scene_to_file("res://src/battle/battle.tscn")


func _run_post_game_if_pending() -> void:
	if not LlmPostGame.has_pending():
		return
	if post_game_status:
		post_game_status.text = "Post-game: analysing match…"
	var result: Dictionary = await _llm_post_game.run_session_async(llm_http, _llm_settings, _llm_client)
	if bool(result.get("skipped", false)):
		return
	if bool(result.get("needs_review", false)):
		if post_game_status:
			post_game_status.text = ""
		_show_post_game_review(result)
		return
	var msg: String = str(result.get("message", ""))
	if post_game_status and not msg.is_empty():
		post_game_status.text = msg
	EventBus.post_game_learning_message.emit(msg)


var _review_distilled: String = ""
var _review_session_md: String = ""
var _review_match_summary: Dictionary = {}
var _review_overlay: ColorRect


func _show_post_game_review(result: Dictionary) -> void:
	_review_distilled = str(result.get("distilled", ""))
	_review_session_md = str(result.get("session_md", ""))
	_review_match_summary = result.get("match_summary", {}) as Dictionary

	_review_overlay = ColorRect.new()
	_review_overlay.color = Color(0, 0, 0, 0.6)
	_review_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_review_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_review_overlay)

	var center_ct := CenterContainer.new()
	center_ct.set_anchors_preset(Control.PRESET_FULL_RECT)
	_review_overlay.add_child(center_ct)

	var panel := PanelContainer.new()
	panel.theme_type_variation = &"UiMainCard"
	panel.custom_minimum_size = Vector2(780, 600)
	center_ct.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 24)
	margin.add_theme_constant_override("margin_right", 24)
	margin.add_theme_constant_override("margin_top", 22)
	margin.add_theme_constant_override("margin_bottom", 22)
	panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	margin.add_child(vbox)

	var title := Label.new()
	title.text = "Post-Game Review"
	title.theme_type_variation = &"UiHeading"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	var outcome_str := str(_review_match_summary.get("ai_outcome", ""))
	var scenario_str := str(_review_match_summary.get("scenario_id", ""))
	var subtitle := Label.new()
	subtitle.text = "%s — AI %s" % [scenario_str, outcome_str]
	subtitle.theme_type_variation = &"UiHint"
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(subtitle)

	# --- Distilled learnings ---
	var distilled_label := Label.new()
	distilled_label.text = "Proposed Distilled Learnings"
	distilled_label.theme_type_variation = &"UiHint"
	vbox.add_child(distilled_label)

	var distilled_scroll := ScrollContainer.new()
	distilled_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	distilled_scroll.custom_minimum_size.y = 160
	vbox.add_child(distilled_scroll)

	var distilled_text := RichTextLabel.new()
	distilled_text.name = "DistilledText"
	distilled_text.bbcode_enabled = false
	distilled_text.text = _review_distilled
	distilled_text.fit_content = true
	distilled_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	distilled_text.selection_enabled = true
	distilled_text.add_theme_font_size_override("normal_font_size", 13)
	distilled_scroll.add_child(distilled_text)

	# --- This match learnings ---
	var session_label := Label.new()
	session_label.text = "This Match"
	session_label.theme_type_variation = &"UiHint"
	vbox.add_child(session_label)

	var session_text := RichTextLabel.new()
	session_text.bbcode_enabled = false
	session_text.text = _review_session_md
	session_text.fit_content = true
	session_text.custom_minimum_size.y = 60
	session_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	session_text.selection_enabled = true
	session_text.add_theme_font_size_override("normal_font_size", 13)
	vbox.add_child(session_text)

	# --- Human suggestions ---
	var suggest_label := Label.new()
	suggest_label.text = "Your Suggestions (optional)"
	suggest_label.theme_type_variation = &"UiHint"
	vbox.add_child(suggest_label)

	var suggest_edit := TextEdit.new()
	suggest_edit.name = "SuggestEdit"
	suggest_edit.placeholder_text = "e.g. \"Scouts should focus fire on Zerglings\" or \"The AI should not retreat when it has HP advantage\""
	suggest_edit.custom_minimum_size.y = 60
	suggest_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	suggest_edit.add_theme_font_size_override("font_size", 13)
	vbox.add_child(suggest_edit)

	# --- Feedback display (hidden until feedback is submitted) ---
	var feedback_text := RichTextLabel.new()
	feedback_text.name = "FeedbackText"
	feedback_text.bbcode_enabled = false
	feedback_text.text = ""
	feedback_text.visible = false
	feedback_text.fit_content = true
	feedback_text.custom_minimum_size.y = 0
	feedback_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	feedback_text.selection_enabled = true
	feedback_text.add_theme_font_size_override("normal_font_size", 13)
	vbox.add_child(feedback_text)

	# --- Status label ---
	var review_status := Label.new()
	review_status.name = "ReviewStatus"
	review_status.text = ""
	review_status.theme_type_variation = &"UiHint"
	review_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(review_status)

	# --- Buttons ---
	var btn_row := HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_END
	btn_row.add_theme_constant_override("separation", 12)
	vbox.add_child(btn_row)

	var feedback_btn := Button.new()
	feedback_btn.name = "FeedbackBtn"
	feedback_btn.text = "Submit Suggestions"
	feedback_btn.custom_minimum_size.y = 38
	feedback_btn.tooltip_text = "Send your suggestions to the AI for evaluation."
	btn_row.add_child(feedback_btn)

	var accept_btn := Button.new()
	accept_btn.name = "AcceptBtn"
	accept_btn.text = "Accept & Save"
	accept_btn.theme_type_variation = &"PrimaryButton"
	accept_btn.custom_minimum_size = Vector2(140, 38)
	btn_row.add_child(accept_btn)

	accept_btn.pressed.connect(func() -> void:
		LlmPostGame.save_post_game_results(
			_review_distilled,
			_review_session_md,
			str(_review_match_summary.get("scenario_id", "")),
		)
		if post_game_status:
			post_game_status.text = "AI learnings saved."
		EventBus.post_game_learning_message.emit("AI learnings saved.")
		_review_overlay.queue_free()
	)

	feedback_btn.pressed.connect(func() -> void:
		var suggestions := suggest_edit.text.strip_edges()
		if suggestions.is_empty():
			review_status.text = "Type a suggestion first."
			return
		feedback_btn.disabled = true
		accept_btn.disabled = true
		review_status.text = "Evaluating your suggestions…"
		_run_human_feedback(suggestions, distilled_text, feedback_text, review_status, feedback_btn, accept_btn)
	)


func _run_human_feedback(
	suggestions: String,
	distilled_text: RichTextLabel,
	feedback_text: RichTextLabel,
	review_status: Label,
	feedback_btn: Button,
	accept_btn: Button,
) -> void:
	var fb_result: Dictionary = await _llm_post_game.run_human_feedback_async(
		llm_http,
		_llm_settings,
		_llm_client,
		_review_distilled,
		_review_session_md,
		_review_match_summary,
		suggestions,
	)
	feedback_btn.disabled = false
	accept_btn.disabled = false

	if not bool(fb_result.get("ok", false)):
		review_status.text = str(fb_result.get("message", "Feedback failed."))
		return

	_review_distilled = str(fb_result.get("distilled", _review_distilled))
	distilled_text.text = _review_distilled

	var fb: String = str(fb_result.get("feedback", "")).strip_edges()
	if not fb.is_empty():
		feedback_text.text = fb
		feedback_text.visible = true
	review_status.text = "Suggestions evaluated — review the updated learnings above."
