extends Control
## Lightweight launcher for playing the official fast Arena seeds by hand.

const ArenaPlaytestScenario = preload("res://src/battle/arena_playtest_scenario.gd")
const PureStateArenaSuite = preload("res://src/simulation/pure_state_arena_suite.gd")
const PureStateNeuralEvaluator = preload("res://src/simulation/pure_state_neural_evaluator.gd")
const LlmAiSettings = preload("res://src/llm_ai/llm_settings.gd")

var _seed_option: OptionButton
var _side_option: OptionButton
var _variant_option: OptionButton
var _profile_option: OptionButton
var _detail_label: Label


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_build_ui()
	_refresh_details()


func _build_ui() -> void:
	var background := ColorRect.new()
	background.color = Color(0.055, 0.065, 0.08, 1.0)
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(background)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(720, 680)
	center.add_child(panel)
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 32)
	margin.add_theme_constant_override("margin_right", 32)
	margin.add_theme_constant_override("margin_top", 28)
	margin.add_theme_constant_override("margin_bottom", 28)
	panel.add_child(margin)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 14)
	margin.add_child(vbox)

	var title := Label.new()
	title.text = "Arena Playtest"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 30)
	vbox.add_child(title)
	var intro := Label.new()
	intro.text = "Play one side of the real AI Arena against Handwritten search, Neural-guided search, or the existing LLM planner. Every opponent starts from the same hidden pre-turn state, so it cannot react to choices you have already made."
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	intro.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(intro)

	_seed_option = _add_labeled_option(vbox, "Arena seed")
	for seed in ArenaPlaytestScenario.available_seeds():
		var state := PureStateArenaSuite.build_generated_state(seed, ArenaPlaytestScenario.DEFAULT_PRESET, PureStateArenaSuite.DEFAULT_MAP_PROFILE)
		var metadata: Dictionary = state.get("arena_metadata", {}) as Dictionary
		var family := str(metadata.get("base_scenario_id", "arena")).replace("_", " ").capitalize()
		_seed_option.add_item("%s — seed %d" % [family, seed])
		_seed_option.set_item_metadata(_seed_option.item_count - 1, seed)
	_seed_option.item_selected.connect(func(_idx: int) -> void: _refresh_details())

	_side_option = _add_labeled_option(vbox, "Your faction")
	_side_option.add_item("Terran")
	_side_option.set_item_metadata(0, "terran")
	_side_option.add_item("Zerg")
	_side_option.set_item_metadata(1, "zerg")
	_side_option.item_selected.connect(func(_idx: int) -> void: _refresh_details())

	_variant_option = _add_labeled_option(vbox, "AI variant")
	_variant_option.add_item("Handwritten")
	_variant_option.set_item_metadata(0, ArenaPlaytestScenario.AI_VARIANT_HANDWRITTEN)
	_variant_option.add_item("Neural")
	_variant_option.set_item_metadata(1, ArenaPlaytestScenario.AI_VARIANT_NEURAL)
	_variant_option.add_item("LLM")
	_variant_option.set_item_metadata(2, ArenaPlaytestScenario.AI_VARIANT_LLM)
	_variant_option.select(0)
	_variant_option.item_selected.connect(func(_idx: int) -> void: _refresh_details())

	_profile_option = _add_labeled_option(vbox, "Search profile (Handwritten / Neural)")
	for profile in ArenaPlaytestScenario.available_agent_profiles():
		_profile_option.add_item(profile.capitalize())
		_profile_option.set_item_metadata(_profile_option.item_count - 1, profile)
	_profile_option.select(0)
	_profile_option.item_selected.connect(func(_idx: int) -> void: _refresh_details())

	_detail_label = Label.new()
	_detail_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_detail_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_detail_label.custom_minimum_size.y = 118
	vbox.add_child(_detail_label)

	var data_note := Label.new()
	data_note.text = "After each match, Godot saves a full turn trace, human-policy demonstrations, and terminal value examples under user://arena_playtests/. Turn-limit games are kept as policy data but are not given speculative value labels."
	data_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(data_note)

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(spacer)
	var button_row := HBoxContainer.new()
	button_row.alignment = BoxContainer.ALIGNMENT_CENTER
	button_row.add_theme_constant_override("separation", 14)
	vbox.add_child(button_row)
	var back := Button.new()
	back.text = "Back"
	back.custom_minimum_size = Vector2(130, 44)
	button_row.add_child(back)
	back.pressed.connect(func() -> void: get_tree().change_scene_to_file("res://src/main_menu.tscn"))
	var start := Button.new()
	start.text = "Start Arena Match"
	start.custom_minimum_size = Vector2(220, 44)
	start.theme_type_variation = &"PrimaryButton"
	button_row.add_child(start)
	start.pressed.connect(_on_start_pressed)


func _add_labeled_option(parent: VBoxContainer, label_text: String) -> OptionButton:
	var label := Label.new()
	label.text = label_text
	parent.add_child(label)
	var option := OptionButton.new()
	option.custom_minimum_size.y = 42
	parent.add_child(option)
	return option


func _selected_variant() -> String:
	if _variant_option == null or _variant_option.item_count == 0:
		return ArenaPlaytestScenario.DEFAULT_AI_VARIANT
	return str(_variant_option.get_item_metadata(_variant_option.selected))


func _refresh_details() -> void:
	if _detail_label == null or _seed_option == null or _seed_option.item_count == 0:
		return
	var seed := int(_seed_option.get_item_metadata(_seed_option.selected))
	var state := PureStateArenaSuite.build_generated_state(seed, ArenaPlaytestScenario.DEFAULT_PRESET, PureStateArenaSuite.DEFAULT_MAP_PROFILE)
	var metadata: Dictionary = state.get("arena_metadata", {}) as Dictionary
	var family := str(metadata.get("base_scenario_id", "arena")).replace("_", " ").capitalize()
	var profile := "fast"
	if _profile_option != null and _profile_option.item_count > 0:
		profile = str(_profile_option.get_item_metadata(_profile_option.selected))
	var variant := _selected_variant()
	if _profile_option != null:
		_profile_option.disabled = variant == ArenaPlaytestScenario.AI_VARIANT_LLM
	var max_turns := int(PureStateArenaSuite.FAMILY_MAX_TURNS.get(str(metadata.get("base_scenario_id", "")), 10)) + PureStateArenaSuite.ARENA_TURN_ALLOWANCE
	var opponent_detail := "Handwritten GameplayAI • %s search" % profile
	var readiness := ""
	if variant == ArenaPlaytestScenario.AI_VARIANT_NEURAL:
		opponent_detail = "Neural-guided GameplayAI • %s search" % profile
		if not FileAccess.file_exists(PureStateNeuralEvaluator.DEFAULT_CHECKPOINT_PATH):
			readiness = "\nNeural checkpoint missing: %s" % PureStateNeuralEvaluator.DEFAULT_CHECKPOINT_PATH
	elif variant == ArenaPlaytestScenario.AI_VARIANT_LLM:
		var settings := LlmAiSettings.new()
		settings.load_from_disk()
		var model_name := settings.model.strip_edges()
		opponent_detail = "Existing LLM planner • %s" % (model_name if not model_name.is_empty() else "model not configured")
		if not settings.has_configured_key():
			readiness = "\nLLM API key is not configured in the existing LLM AI settings."
		elif model_name.is_empty():
			readiness = "\nLLM model is not configured in the existing LLM AI settings."
	_detail_label.text = "%s • radius %d • up to %d turns\nOpponent: %s%s\nWin by elimination or by keeping one of your units on the enemy command hex across a complete resolved turn." % [
		family,
		int(state.get("hex_radius", 5)),
		max_turns,
		opponent_detail,
		readiness,
	]


func _on_start_pressed() -> void:
	if _seed_option == null or _seed_option.item_count == 0:
		return
	var seed := int(_seed_option.get_item_metadata(_seed_option.selected))
	var human_group := str(_side_option.get_item_metadata(_side_option.selected))
	var profile := str(_profile_option.get_item_metadata(_profile_option.selected))
	var variant := _selected_variant()
	if variant == ArenaPlaytestScenario.AI_VARIANT_NEURAL and not FileAccess.file_exists(PureStateNeuralEvaluator.DEFAULT_CHECKPOINT_PATH):
		_detail_label.text = "Neural cannot start because the checkpoint is missing:\n%s" % PureStateNeuralEvaluator.DEFAULT_CHECKPOINT_PATH
		return
	if variant == ArenaPlaytestScenario.AI_VARIANT_LLM:
		var settings := LlmAiSettings.new()
		settings.load_from_disk()
		if not settings.has_configured_key() or settings.model.strip_edges().is_empty():
			_detail_label.text = "LLM cannot start yet. Configure both the API key and model in the existing LLM AI settings, then return here."
			return
	var scenario := ArenaPlaytestScenario.build(
		seed,
		human_group,
		profile,
		PureStateArenaSuite.DEFAULT_MAP_PROFILE,
		ArenaPlaytestScenario.DEFAULT_PRESET,
		variant,
		PureStateNeuralEvaluator.DEFAULT_CHECKPOINT_PATH
	)
	if scenario.is_empty():
		_detail_label.text = "Could not build that Arena scenario."
		return
	# Keep the existing Scenarios singleton as the handoff into battle.gd rather
	# than adding another global game-mode registry.
	for index in range(Scenarios.available_scenarios.size() - 1, -1, -1):
		var existing_variant = Scenarios.available_scenarios[index]
		if existing_variant is Dictionary and str((existing_variant as Dictionary).get("id", "")).begins_with("arena_playtest_"):
			Scenarios.available_scenarios.remove_at(index)
	Scenarios.available_scenarios.append(scenario)
	Scenarios.select_scenario(str(scenario.get("id", "")))
	Scenarios.set_player_group(human_group)
	get_tree().change_scene_to_file("res://src/battle/battle.tscn")
