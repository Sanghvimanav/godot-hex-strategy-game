extends Node2D

@onready var hex_map: Node2D = %hex_map
@onready var units: UnitsContainer = %units
@onready var camera: Camera2D = $Camera2D

const ArenaPlaytestController = preload("res://src/battle/arena_playtest_controller.gd")
const SCROLL_SPEED := 200.0
const ZOOM_MIN := 1.5
const ZOOM_MAX := 4.0
const ZOOM_STEP := 0.1

var _panning := false
var _arena_playtest_controller: ArenaPlaytestController

func _ready() -> void:
	# Navigation is initialized by hex_map._ready() (runs before units)
	if MultiplayerState.is_multiplayer and not MultiplayerState.pending_battle_state.is_empty():
		var pending_resources = MultiplayerState.pending_battle_state.get("tile_resources", {})
		if pending_resources is Dictionary and not pending_resources.is_empty() and hex_map and hex_map.has_method("apply_tile_resource_state"):
			hex_map.apply_tile_resource_state(pending_resources)
		units.apply_multiplayer_state(MultiplayerState.pending_battle_state)
		units.multiplayer_my_group = MultiplayerState.my_group
		units.start_battle()
		var gs: Node = get_node_or_null("/root/GameServer")
		if gs != null and gs.has_signal("host_message_received"):
			if MultiplayerState.is_host:
				gs.host_message_received.connect(_on_game_server_message)
			elif gs.has_signal("server_message_received"):
				gs.server_message_received.connect(_on_game_server_message)
	else:
		var scenario := Scenarios.get_selected_scenario()
		if not scenario.is_empty():
			var arena_config_variant = scenario.get("arena_playtest", {})
			var arena_enabled := arena_config_variant is Dictionary and bool((arena_config_variant as Dictionary).get("enabled", false))
			if arena_enabled:
				# Arena map profiles use the exact compact radius from the benchmark.
				# Configure Navigation before spawning units so their scene positions are
				# derived from the same board geometry as pure-state search.
				ArenaPlaytestController.configure_map_for_scenario(hex_map, units, scenario)
			var scenario_resources = scenario.get("tile_resources", {})
			if scenario_resources is Dictionary and not scenario_resources.is_empty() and hex_map and hex_map.has_method("apply_tile_resource_state"):
				hex_map.apply_tile_resource_state(scenario_resources)
			units.apply_scenario(scenario)
			if arena_enabled:
				_arena_playtest_controller = ArenaPlaytestController.new()
				_arena_playtest_controller.name = "ArenaPlaytestController"
				add_child(_arena_playtest_controller)
				if not _arena_playtest_controller.setup(scenario, units, hex_map):
					push_error("Failed to initialize Arena playtest controller")
		units.multiplayer_my_group = Scenarios.get_human_group_name_for_local_battle()
		units.start_battle()

func _on_game_server_message(obj: Dictionary) -> void:
	var msg_type: String = str(obj.get("type", ""))
	if msg_type == "game_state":
		var state: Dictionary = obj.get("state", {})
		if state.is_empty():
			return
		var turn_result: Dictionary = obj.get("turn_result", {})
		if MultiplayerState.is_multiplayer and not turn_result.is_empty():
			units.play_resolved_turn(turn_result, state)
		else:
			units.apply_server_state(state)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_zoom_camera(1)
			get_viewport().set_input_as_handled()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_zoom_camera(-1)
			get_viewport().set_input_as_handled()
		elif event.button_index == MOUSE_BUTTON_MIDDLE:
			_panning = event.pressed
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _panning:
		camera.position -= event.relative / camera.zoom.x
		get_viewport().set_input_as_handled()
	elif event is InputEventKey:
		if event.pressed:
			var delta := Vector2.ZERO
			if event.keycode in [KEY_W, KEY_UP]:
				delta.y = -1
			elif event.keycode in [KEY_S, KEY_DOWN]:
				delta.y = 1
			elif event.keycode in [KEY_A, KEY_LEFT]:
				delta.x = -1
			elif event.keycode in [KEY_D, KEY_RIGHT]:
				delta.x = 1
			if delta != Vector2.ZERO:
				camera.position += delta * SCROLL_SPEED
				get_viewport().set_input_as_handled()

func _zoom_camera(direction: int) -> void:
	var target := camera.zoom.x + direction * ZOOM_STEP
	target = clampf(target, ZOOM_MIN, ZOOM_MAX)
	camera.zoom = Vector2(target, target)
