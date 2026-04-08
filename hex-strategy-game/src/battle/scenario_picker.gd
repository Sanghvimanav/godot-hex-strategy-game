extends CanvasLayer
## Scenario selection UI shown at game start. Pick a scenario and start battle.

@onready var main_list: VBoxContainer = $center/panel/margin/vbox/columns/main_column/main_list
@onready var campaign_list: VBoxContainer = $center/panel/margin/vbox/columns/campaign_column/campaign_list
@onready var debug_list: VBoxContainer = $center/panel/margin/vbox/columns/debug_column/debug_list
@onready var start_btn: Button = $center/panel/margin/vbox/start_btn

@onready var llm_base_url: LineEdit = $center/panel/margin/vbox/llm_base_row/llm_base_url
@onready var llm_model: LineEdit = $center/panel/margin/vbox/llm_model_row/llm_model
@onready var llm_api_key: LineEdit = $center/panel/margin/vbox/llm_key_row/llm_api_key
@onready var llm_planning_max_tokens: SpinBox = $center/panel/margin/vbox/llm_max_tokens_row/llm_planning_max_tokens
@onready var llm_mode: OptionButton = $center/panel/margin/vbox/llm_api_mode_row/llm_mode
@onready var llm_reasoning_effort: OptionButton = $center/panel/margin/vbox/llm_reasoning_row/llm_reasoning_effort
@onready var llm_save_btn: Button = $center/panel/margin/vbox/llm_btn_row/llm_save_btn
@onready var llm_test_btn: Button = $center/panel/margin/vbox/llm_btn_row/llm_test_btn
@onready var llm_cancel_btn: Button = $center/panel/margin/vbox/llm_btn_row/llm_cancel_btn
@onready var llm_status: Label = $center/panel/margin/vbox/llm_status
@onready var llm_http: HTTPRequest = $LlmHttpRequest

var _llm_settings: LlmAiSettings
var _llm_client: LlmOpenAiClient
var _llm_post_game: LlmPostGame = LlmPostGame.new()


func _ready() -> void:
	_llm_settings = LlmAiSettings.new()
	_llm_client = LlmOpenAiClient.new()
	_llm_settings.load_from_disk()
	_setup_llm_mode_options()
	_apply_llm_settings_to_ui()
	llm_status.text = "LLM: configure and Save, or Test API (chat: 60s timeout; responses: 120s)."

	_rebuild_buttons()
	if start_btn:
		start_btn.pressed.connect(_on_start_pressed)
	call_deferred("_run_post_game_if_pending")
	if llm_save_btn:
		llm_save_btn.pressed.connect(_on_llm_save_pressed)
	if llm_test_btn:
		llm_test_btn.pressed.connect(_on_llm_test_pressed)
	if llm_cancel_btn:
		llm_cancel_btn.pressed.connect(_on_llm_cancel_pressed)
	if llm_mode:
		llm_mode.item_selected.connect(_on_llm_mode_selected)


func _setup_llm_mode_options() -> void:
	if llm_mode:
		llm_mode.clear()
		llm_mode.add_item("chat/completions", 0)
		llm_mode.add_item("responses (thinking)", 1)
	if llm_reasoning_effort:
		llm_reasoning_effort.clear()
		for e in _llm_effort_strings():
			llm_reasoning_effort.add_item(e)


func _llm_effort_strings() -> Array:
	return ["none", "minimal", "low", "medium", "high", "xhigh"]


func _effort_index(effort: String) -> int:
	var e := effort.strip_edges().to_lower()
	var opts := _llm_effort_strings()
	for i in range(opts.size()):
		if opts[i] == e:
			return i
	return 3


func _effort_from_ui() -> String:
	if llm_reasoning_effort == null:
		return "medium"
	var i: int = llm_reasoning_effort.selected
	var opts := _llm_effort_strings()
	if i < 0 or i >= opts.size():
		return "medium"
	return opts[i]


func _on_llm_mode_selected(_idx: int) -> void:
	_llm_refresh_reasoning_row_enabled()


func _llm_refresh_reasoning_row_enabled() -> void:
	if llm_reasoning_effort:
		llm_reasoning_effort.disabled = llm_mode != null and llm_mode.selected == 0


func _apply_llm_settings_to_ui() -> void:
	if llm_base_url:
		llm_base_url.text = _llm_settings.base_url
	if llm_model:
		llm_model.text = _llm_settings.model
	if llm_api_key:
		llm_api_key.text = _llm_settings.api_key
	if llm_planning_max_tokens:
		llm_planning_max_tokens.value = _llm_settings.planning_max_tokens
	if llm_mode:
		llm_mode.select(1 if _llm_settings.use_responses_api else 0)
	if llm_reasoning_effort:
		llm_reasoning_effort.select(_effort_index(_llm_settings.reasoning_effort))
	_llm_refresh_reasoning_row_enabled()


func _read_llm_ui_into_settings() -> void:
	if llm_base_url:
		_llm_settings.base_url = llm_base_url.text
	if llm_model:
		_llm_settings.model = llm_model.text
	if llm_api_key:
		_llm_settings.api_key = llm_api_key.text
	if llm_planning_max_tokens:
		_llm_settings.planning_max_tokens = int(llm_planning_max_tokens.value)
	if llm_mode:
		_llm_settings.use_responses_api = llm_mode.selected == 1
	if llm_reasoning_effort:
		_llm_settings.reasoning_effort = _effort_from_ui()


func _on_llm_save_pressed() -> void:
	_read_llm_ui_into_settings()
	var err: Error = _llm_settings.save_to_disk()
	if err == OK:
		llm_status.text = "Saved to %s." % LlmAiSettings.USER_CONFIG_PATH
	else:
		llm_status.text = "Save failed (error %d)." % err


func _on_llm_cancel_pressed() -> void:
	if _llm_client and llm_http:
		_llm_client.cancel_inflight(llm_http)
	llm_status.text = "Cancel requested (in-flight request aborted)."


func _on_llm_test_pressed() -> void:
	if not _llm_client or not llm_http:
		return
	_read_llm_ui_into_settings()
	if not _llm_settings.has_configured_key():
		llm_status.text = "Error: set API key first."
		return
	if llm_model and llm_model.text.strip_edges().is_empty():
		llm_status.text = "Error: set model id first."
		return
	llm_test_btn.disabled = true
	var result: Dictionary
	if _llm_settings.use_responses_api:
		llm_status.text = "Requesting responses…"
		result = await _llm_client.responses_create(
			llm_http,
			_llm_settings.get_effective_base_url(),
			_llm_settings.api_key,
			_llm_settings.model,
			"Reply with one short line.",
			"ping",
			_effort_from_ui(),
			min(int(_llm_settings.planning_max_tokens), 4096),
		)
	else:
		llm_status.text = "Requesting chat/completions…"
		var messages: Array = [{"role": "user", "content": "ping"}]
		result = await _llm_client.chat_completions(
			llm_http,
			_llm_settings.get_effective_base_url(),
			_llm_settings.api_key,
			_llm_settings.model,
			messages,
			LlmOpenAiClient.Profile.PLANNING,
			_llm_settings.planning_max_tokens,
		)
	llm_test_btn.disabled = false
	if result.get("ok", false):
		var content: String = str(result.get("content", "")).strip_edges()
		if content.length() > 160:
			content = content.substr(0, 160) + "…"
		llm_status.text = "OK: %s" % content
	else:
		var reason: String = str(result.get("error", "unknown"))
		var http_st = result.get("http_status", null)
		var snip: String = str(result.get("body_snippet", ""))
		var detail: String = str(result.get("detail", ""))
		var extra := ""
		if not snip.is_empty():
			extra = " %s" % snip
		elif not detail.is_empty():
			extra = " %s" % detail
		if http_st != null:
			llm_status.text = "Error: %s (HTTP %s)%s" % [reason, str(http_st), extra]
		else:
			llm_status.text = "Error: %s.%s" % [reason, extra]


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


func _run_post_game_if_pending() -> void:
	if not LlmPostGame.has_pending():
		return
	llm_status.text = "Post-game: saving AI learnings…"
	var result: Dictionary = await _llm_post_game.run_session_async(llm_http, _llm_settings, _llm_client)
	if bool(result.get("skipped", false)):
		return
	var msg: String = str(result.get("message", ""))
	if not msg.is_empty():
		llm_status.text = msg
		EventBus.post_game_learning_message.emit(msg)
