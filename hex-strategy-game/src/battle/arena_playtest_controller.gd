extends Node2D
class_name ArenaPlaytestController
## Interactive bridge between the existing battle UI and the canonical pure-state
## Arena AI. GameplayAI variants are computed at planning-start from an immutable
## pre-turn state. The LLM variant reuses the existing batch planner, whose snapshot
## is likewise created before the human can commit the simultaneous turn.

const GameplayAI = preload("res://src/battle/ai/gameplay_ai.gd")
const PureStateArenaSuite = preload("res://src/simulation/pure_state_arena_suite.gd")
const PureStateCommandHexRules = preload("res://src/simulation/pure_state_command_hex_rules.gd")
const PureStateSimulator = preload("res://src/simulation/pure_state_simulator.gd")
const PureStateNeuralEvaluator = preload("res://src/simulation/pure_state_neural_evaluator.gd")
const ArenaPlaytestData = preload("res://src/battle/arena_playtest_data.gd")
const ArenaPlaytestScenario = preload("res://src/battle/arena_playtest_scenario.gd")
const LlmAiSettings = preload("res://src/llm_ai/llm_settings.gd")

var _units: UnitsContainer
var _hex_map: Node
var _arena_config: Dictionary = {}
var _human_group := ""
var _ai_group := ""
var _ai_variant := ArenaPlaytestScenario.DEFAULT_AI_VARIANT
var _ai_settings: Dictionary = {}
var _current_state: Dictionary = {}
var _command_hexes: Dictionary = {}
var _command_occupants: Dictionary = {}
var _history: Array = []
var _game_id := ""
var _finished := false

var _planned_turn_number := -1
var _pending_state_before: Dictionary = {}
var _pending_ai_decision: Dictionary = {}
var _pending_player_actions: Dictionary = {}
var _pending_simulation: Dictionary = {}
var _pending_ready := false

var _hud_canvas: CanvasLayer
var _hud_label: Label
var _finish_canvas: CanvasLayer


static func configure_map_for_scenario(hex_map: Node, units: Node, scenario: Dictionary) -> void:
	var config_variant = scenario.get("arena_playtest", {})
	if not (config_variant is Dictionary) or not bool((config_variant as Dictionary).get("enabled", false)):
		return
	if hex_map == null or not scenario.has("hex_radius"):
		return
	var radius := maxi(1, int(scenario.get("hex_radius", 5)))
	hex_map.set("hex_radius", radius)
	if hex_map.has_method("_build_grid"):
		hex_map.call("_build_grid")
	if hex_map.has_method("_draw_hexes"):
		hex_map.call("_draw_hexes")
	var grid_variant = hex_map.get("grid")
	if grid_variant is Dictionary and units != null and units.has_method("get_active_units"):
		Navigation.init_level_hex(grid_variant as Dictionary, Callable(units, "get_active_units"))
	if hex_map.has_method("_refresh_fog"):
		hex_map.call_deferred("_refresh_fog")


func setup(scenario: Dictionary, units: UnitsContainer, hex_map: Node) -> bool:
	var config_variant = scenario.get("arena_playtest", {})
	if not (config_variant is Dictionary):
		return false
	_arena_config = (config_variant as Dictionary).duplicate(true)
	if not bool(_arena_config.get("enabled", false)):
		return false
	_units = units
	_hex_map = hex_map
	_human_group = _find_group_name(scenario, false)
	_ai_group = _find_group_name(scenario, true)
	if _human_group.is_empty() or _ai_group.is_empty() or _human_group == _ai_group:
		return false

	_ai_variant = str(_arena_config.get("ai_variant", _arena_config.get("evaluator", ArenaPlaytestScenario.DEFAULT_AI_VARIANT)))
	if _ai_variant not in ArenaPlaytestScenario.available_ai_variants():
		return false
	if _ai_variant == ArenaPlaytestScenario.AI_VARIANT_LLM:
		var llm_settings := LlmAiSettings.new()
		llm_settings.load_from_disk()
		if not llm_settings.has_configured_key() or llm_settings.model.strip_edges().is_empty():
			return false
		_ai_settings = _llm_settings_metadata(llm_settings)
		_arena_config["llm_model"] = llm_settings.model.strip_edges()
		_arena_config["llm_prompt_version"] = llm_settings.planning_prompt_version
	else:
		var evaluator := GameplayAI.EVALUATOR_NEURAL if _ai_variant == ArenaPlaytestScenario.AI_VARIANT_NEURAL else GameplayAI.EVALUATOR_HANDWRITTEN
		_ai_settings = PureStateArenaSuite.agent_settings(
			str(_arena_config.get("agent_profile", "fast")),
			evaluator
		)
		if _ai_settings.is_empty():
			return false
		if _ai_variant == ArenaPlaytestScenario.AI_VARIANT_NEURAL:
			var checkpoint_path := str(_arena_config.get("neural_checkpoint_path", PureStateNeuralEvaluator.DEFAULT_CHECKPOINT_PATH))
			if checkpoint_path.is_empty() or not FileAccess.file_exists(checkpoint_path):
				return false
			var evaluator_settings: Dictionary = (_ai_settings.get("evaluator_settings", {}) as Dictionary).duplicate(true)
			evaluator_settings["checkpoint_path"] = checkpoint_path
			_ai_settings["evaluator_settings"] = evaluator_settings

	var initial_variant = _arena_config.get("initial_state", {})
	if not (initial_variant is Dictionary) or (initial_variant as Dictionary).is_empty():
		return false
	_current_state = (initial_variant as Dictionary).duplicate(true)
	_command_hexes = PureStateCommandHexRules.ensure_command_hexes(_current_state, _human_group, _ai_group)
	_command_occupants = PureStateCommandHexRules.initial_occupants(
		_current_state,
		_human_group,
		_ai_group,
		_command_hexes
	)
	_game_id = "arena-playtest-s%d-%s-%s-%d" % [
		int(_arena_config.get("scenario_seed", 0)),
		_human_group,
		_ai_variant,
		int(Time.get_unix_time_from_system()),
	]

	EventBus.planning_started.connect(_on_planning_started)
	EventBus.planning_complete.connect(_on_planning_complete)
	EventBus.turn_changed.connect(_on_turn_changed)
	_build_hud()
	_draw_command_hex_markers()
	_update_hud(1)
	return true


func _exit_tree() -> void:
	if EventBus.planning_started.is_connected(_on_planning_started):
		EventBus.planning_started.disconnect(_on_planning_started)
	if EventBus.planning_complete.is_connected(_on_planning_complete):
		EventBus.planning_complete.disconnect(_on_planning_complete)
	if EventBus.turn_changed.is_connected(_on_turn_changed):
		EventBus.turn_changed.disconnect(_on_turn_changed)


func _on_planning_started() -> void:
	if _finished or _units == null:
		return
	var live_turn := int(_units.turn_number)
	# Single-player currently begins planning once from the animation path and once
	# from its authoritative state resync. GameplayAI variants reuse their exact
	# hidden choice. The LLM batch path may be restarted by UnitsContainer, but its
	# snapshot is still the same untouched start-of-turn scene.
	if live_turn == _planned_turn_number:
		if _ai_variant != ArenaPlaytestScenario.AI_VARIANT_LLM and not _pending_ai_decision.is_empty():
			_apply_ai_actions_to_scene(_pending_ai_decision.get("actions", []) as Array)
		return

	_planned_turn_number = live_turn
	_pending_ready = false
	_pending_player_actions.clear()
	_pending_simulation.clear()
	_pending_state_before = _current_state.duplicate(true)
	_pending_state_before["command_hexes"] = _command_hexes.duplicate(true)
	_pending_ai_decision.clear()

	if _ai_variant == ArenaPlaytestScenario.AI_VARIANT_LLM:
		# ArenaUnitsContainer enables the existing deferred single-player LLM batch
		# immediately after this planning_started signal returns. Do not run a second
		# planner here; capture its validated live submission in planning_complete.
		_update_hud(live_turn)
		return

	_pending_ai_decision = GameplayAI.choose_actions(
		_pending_state_before,
		_ai_group,
		_human_group,
		_ai_settings
	)
	if not bool(_pending_ai_decision.get("valid", false)):
		_finish_session("search_failed", "", "ai_search_failed", _current_state)
		return
	if not _apply_ai_actions_to_scene(_pending_ai_decision.get("actions", []) as Array):
		_finish_session("search_failed", "", "live_action_mapping_failed", _current_state)
		return
	_update_hud(live_turn)


func _on_planning_complete() -> void:
	if _finished or _units == null or _pending_state_before.is_empty():
		return
	var submitted := _units._build_player_actions_from_units(_pending_state_before)
	if not submitted.has(_human_group) or not submitted.has(_ai_group):
		return
	_pending_player_actions = submitted.duplicate(true)
	if _ai_variant == ArenaPlaytestScenario.AI_VARIANT_LLM:
		var submitted_ai_actions: Array = (_pending_player_actions.get(_ai_group, []) as Array).duplicate(true)
		_pending_ai_decision = {
			"valid": true,
			"error": "",
			"actions": submitted_ai_actions,
			"policy": "llm_batch",
			"evaluator": "llm",
			"settings": _ai_settings.duplicate(true),
			"diagnostics": {
				"source": "existing_single_player_llm_batch",
				"validated_llm_plan_seen_in_match": bool(_units.match_had_llm_validated_plan),
			},
		}
	_pending_simulation = PureStateSimulator.simulate_turn(_pending_state_before, _pending_player_actions)
	var next_state_variant = _pending_simulation.get("next_state", {})
	if not (next_state_variant is Dictionary) or (next_state_variant as Dictionary).is_empty():
		_finish_session("simulation_failed", "", "pure_state_simulation_failed", _current_state)
		return
	_pending_ready = true


func _on_turn_changed(new_turn: int) -> void:
	if _finished:
		return
	if not _pending_ready:
		_update_hud(new_turn)
		return
	# turn_changed is emitted after the submitted turn has resolved. Commit the
	# already-computed pure-state result; duplicate turn_changed events are ignored
	# because _pending_ready is cleared here.
	_commit_pending_turn()


func _commit_pending_turn() -> void:
	if not _pending_ready:
		return
	_pending_ready = false
	var state_after: Dictionary = (_pending_simulation.get("next_state", {}) as Dictionary).duplicate(true)
	state_after["command_hexes"] = _command_hexes.duplicate(true)
	var capture := PureStateCommandHexRules.capture_after_complete_turn(
		state_after,
		_human_group,
		_ai_group,
		_command_hexes,
		_command_occupants
	)
	var capture_completed: Dictionary = (capture.get("completed", {}) as Dictionary).duplicate(true)
	_command_occupants = (capture.get("occupants", {}) as Dictionary).duplicate(true)
	var human_actions: Array = (_pending_player_actions.get(_human_group, []) as Array).duplicate(true)
	var ai_actions: Array = (_pending_ai_decision.get("actions", []) as Array).duplicate(true)
	var turn_record := {
		"turn": _history.size() + 1,
		"state_before": _pending_state_before.duplicate(true),
		"state_after": state_after.duplicate(true),
		"human_actions": human_actions,
		"ai_actions": ai_actions,
		"submitted_actions": _pending_player_actions.duplicate(true),
		"execution": (_pending_simulation.get("recording", {}) as Dictionary).duplicate(true),
		"command_hexes": _command_hexes.duplicate(true),
		"command_hex_occupants_after": _command_occupants.duplicate(true),
		"command_hex_capture_completed": capture_completed,
		"ai_variant": _ai_variant,
		"ai_policy": str(_pending_ai_decision.get("policy", "")),
		"ai_evaluator": str(_pending_ai_decision.get("evaluator", "")),
		"ai_settings": (_pending_ai_decision.get("settings", {}) as Dictionary).duplicate(true),
		"ai_diagnostics": (_pending_ai_decision.get("diagnostics", {}) as Dictionary).duplicate(true),
	}
	_history.append(turn_record)
	_current_state = state_after

	var human_captured := bool(capture_completed.get(_human_group, false))
	var ai_captured := bool(capture_completed.get(_ai_group, false))
	if human_captured and ai_captured:
		_finish_session("terminal", "", "simultaneous_command_hex_capture", state_after)
		return
	var outcome := _elimination_outcome(state_after)
	if bool(outcome.get("terminal", false)):
		_finish_session("terminal", str(outcome.get("winner", "")), "elimination", state_after)
		return
	if human_captured:
		_finish_session("terminal", _human_group, "command_hex_capture", state_after)
		return
	if ai_captured:
		_finish_session("terminal", _ai_group, "command_hex_capture", state_after)
		return
	if _history.size() >= int(_arena_config.get("max_turns", 12)):
		_finish_session("turn_limit", "", "turn_limit", state_after)
		return
	_update_hud(_history.size() + 1)


func _apply_ai_actions_to_scene(actions: Array) -> bool:
	if _units == null:
		return false
	var applied := 0
	for action_variant in actions:
		if not (action_variant is Dictionary):
			continue
		var action: Dictionary = action_variant
		var unit_id := int(action.get("unit_id", -1))
		var unit: Unit = _units._find_unit_by_stable_id(unit_id)
		if unit == null or not unit.is_active:
			return false
		var action_key := str(action.get("action_key", ""))
		var target := _cell_to_vector2(action.get("end_point", [0, 0]))
		var options: Array = unit.abilities_db.get_options_for_action_key(action_key)
		var matched := false
		for option_variant in options:
			if not (option_variant is Dictionary):
				continue
			var option: Dictionary = option_variant
			var ac: ActionInstance = option.get("ac") as ActionInstance
			if ac == null or ac.definition == null:
				continue
			if str(ac.definition.action_key) != action_key:
				continue
			if not HexGrid.cell_equal(ac.end_point, target):
				continue
			_units._store_planned_action(unit, ac, bool(option.get("is_move", false)))
			matched = true
			applied += 1
			break
		if not matched:
			push_error("Arena playtest could not map AI action for unit %d: %s -> %s" % [unit_id, action_key, str(target)])
			return false
	return applied == actions.size()


func _finish_session(status: String, winner: String, termination_reason: String, final_state: Dictionary) -> void:
	if _finished:
		return
	_finished = true
	var artifacts := ArenaPlaytestData.build_artifacts(
		_game_id,
		_human_group,
		_ai_group,
		_arena_config,
		_history,
		final_state,
		status,
		winner,
		termination_reason
	)
	var write_result := ArenaPlaytestData.write_session(_game_id, artifacts)
	_show_finish_overlay(status, winner, termination_reason, write_result)


func _elimination_outcome(state: Dictionary) -> Dictionary:
	var human_alive := _living_count(state, _human_group)
	var ai_alive := _living_count(state, _ai_group)
	if human_alive <= 0 and ai_alive <= 0:
		return {"terminal": true, "winner": ""}
	if human_alive <= 0:
		return {"terminal": true, "winner": _ai_group}
	if ai_alive <= 0:
		return {"terminal": true, "winner": _human_group}
	return {"terminal": false, "winner": ""}


func _living_count(state: Dictionary, group_name: String) -> int:
	for group_variant in state.get("groups", []):
		if not (group_variant is Dictionary):
			continue
		var group: Dictionary = group_variant
		if str(group.get("name", "")) != group_name:
			continue
		var count := 0
		for unit_variant in group.get("units", []):
			if unit_variant is Dictionary and int((unit_variant as Dictionary).get("health", 0)) > 0:
				count += 1
		return count
	return 0


func _find_group_name(scenario: Dictionary, ai: bool) -> String:
	for group_variant in scenario.get("groups", []):
		if not (group_variant is Dictionary):
			continue
		var group: Dictionary = group_variant
		if bool(group.get("ai", false)) == ai:
			return str(group.get("name", ""))
	return ""


func _llm_settings_metadata(settings: RefCounted) -> Dictionary:
	return {
		"policy": "llm_batch",
		"evaluator": "llm",
		"model": str(settings.get("model")),
		"base_url": str(settings.call("get_effective_base_url")),
		"use_responses_api": bool(settings.get("use_responses_api")),
		"reasoning_effort": str(settings.get("reasoning_effort")),
		"planning_max_tokens": int(settings.get("planning_max_tokens")),
		"planning_prompt_version": str(settings.get("planning_prompt_version")),
		"use_two_call_planning": bool(settings.get("use_two_call_planning")),
	}


func _opponent_label() -> String:
	if _ai_variant == ArenaPlaytestScenario.AI_VARIANT_LLM:
		return "LLM/%s" % str(_ai_settings.get("model", "configured model"))
	return "%s/%s" % [_ai_variant, str(_arena_config.get("agent_profile", "fast"))]


func _build_hud() -> void:
	_hud_canvas = CanvasLayer.new()
	_hud_canvas.layer = 20
	add_child(_hud_canvas)
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER_TOP)
	panel.position = Vector2(-290, 8)
	panel.custom_minimum_size = Vector2(580, 0)
	_hud_canvas.add_child(panel)
	_hud_label = Label.new()
	_hud_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hud_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	panel.add_child(_hud_label)


func _update_hud(turn_number: int) -> void:
	if _hud_label == null:
		return
	_hud_label.text = "Arena Playtest • You: %s • AI: %s • Turn %d/%d\nEliminate the opponent or hold their command hex through one complete turn." % [
		_human_group.capitalize(),
		_opponent_label(),
		turn_number,
		int(_arena_config.get("max_turns", 12)),
	]


func _draw_command_hex_markers() -> void:
	if _hex_map == null:
		return
	for group_variant in _command_hexes.keys():
		var group_name := str(group_variant)
		var cell := _cell_to_vector2(_command_hexes.get(group_variant, [0, 0]))
		var center := Navigation.cell_to_world(cell, true)
		var line := Line2D.new()
		line.width = 2.0
		line.default_color = Color(0.35, 0.8, 1.0) if group_name == "terran" else Color(1.0, 0.55, 0.25)
		line.z_index = 3
		var points = HexGrid.polygon_points_hex(center.x, center.y, float(_hex_map.get("tile_radius")) * 0.9, 0.0)
		for point in points:
			line.add_point(point)
		if points.size() > 0:
			line.add_point(points[0])
		add_child(line)
		var label := Label.new()
		label.text = "%s CMD" % group_name.left(1).to_upper()
		label.position = center + Vector2(-18, -6)
		label.scale = Vector2(0.45, 0.45)
		label.z_index = 4
		add_child(label)


func _show_finish_overlay(status: String, winner: String, termination_reason: String, write_result: Dictionary) -> void:
	_finish_canvas = CanvasLayer.new()
	_finish_canvas.layer = 100
	add_child(_finish_canvas)
	var blocker := ColorRect.new()
	blocker.color = Color(0, 0, 0, 0.72)
	blocker.set_anchors_preset(Control.PRESET_FULL_RECT)
	blocker.mouse_filter = Control.MOUSE_FILTER_STOP
	_finish_canvas.add_child(blocker)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	blocker.add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(560, 300)
	center.add_child(panel)
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 28)
	margin.add_theme_constant_override("margin_right", 28)
	margin.add_theme_constant_override("margin_top", 24)
	margin.add_theme_constant_override("margin_bottom", 24)
	panel.add_child(margin)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 14)
	margin.add_child(vbox)
	var title := Label.new()
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 26)
	if status == "terminal" and winner == _human_group:
		title.text = "Human Victory"
	elif status == "terminal" and winner == _ai_group:
		title.text = "%s AI Victory" % _ai_variant.capitalize()
	elif status == "terminal":
		title.text = "Draw"
	elif status == "turn_limit":
		title.text = "Turn Limit — Unresolved"
	else:
		title.text = "Arena Playtest Ended"
	vbox.add_child(title)
	var detail := Label.new()
	detail.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail.text = "Reason: %s\nTurns: %d" % [termination_reason.replace("_", " "), _history.size()]
	vbox.add_child(detail)
	var data_label := Label.new()
	data_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if bool(write_result.get("ok", false)):
		data_label.text = "Saved training/evaluation data to:\n%s\n%d human-policy examples • %d value examples" % [
			str(write_result.get("absolute_path", write_result.get("path", ""))),
			int(write_result.get("human_policy_example_count", 0)),
			int(write_result.get("value_example_count", 0)),
		]
	else:
		data_label.text = "Could not write playtest data: %s" % str(write_result.get("error", "unknown error"))
	vbox.add_child(data_label)
	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.add_theme_constant_override("separation", 12)
	vbox.add_child(buttons)
	var rematch := Button.new()
	rematch.text = "Rematch"
	buttons.add_child(rematch)
	rematch.pressed.connect(func() -> void: get_tree().reload_current_scene())
	var back := Button.new()
	back.text = "Arena Picker"
	buttons.add_child(back)
	back.pressed.connect(func() -> void: get_tree().change_scene_to_file("res://src/battle/arena_playtest_picker.tscn"))


func _cell_to_vector2(value: Variant) -> Vector2:
	if value is Vector2:
		return value
	if value is Vector2i:
		return Vector2(value.x, value.y)
	if value is Array and value.size() >= 2:
		return Vector2(int(value[0]), int(value[1]))
	return Vector2.ZERO
