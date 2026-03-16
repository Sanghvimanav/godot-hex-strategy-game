extends Control
## Multiplayer lobby: connect to ENet server, send username, create or join game, receive game_state.
## Run this scene as main (or from a menu) while the server runs from game_server.tscn in another instance.

@onready var status_label: Label = $VBox/StatusLabel
@onready var connected_players_label: Label = $VBox/ConnectedPlayersLabel
@onready var connect_panel: PanelContainer = $VBox/ConnectPanel
@onready var host_edit: LineEdit = $VBox/ConnectPanel/Margin/VBox/HostEdit
@onready var port_edit: LineEdit = $VBox/ConnectPanel/Margin/VBox/PortEdit
@onready var connect_btn: Button = $VBox/ConnectPanel/Margin/VBox/ConnectButton
@onready var username_panel: PanelContainer = $VBox/UsernamePanel
@onready var username_edit: LineEdit = $VBox/UsernamePanel/Margin/VBox/UsernameEdit
@onready var username_ok: Button = $VBox/UsernamePanel/Margin/VBox/OKButton
@onready var lobby_panel: PanelContainer = $VBox/LobbyPanel
@onready var create_btn: Button = $VBox/LobbyPanel/Margin/VBox/CreateButton
@onready var scenario_option: OptionButton = $VBox/LobbyPanel/Margin/VBox/ScenarioOption
@onready var games_list_container: VBoxContainer = $VBox/LobbyPanel/Margin/VBox/GamesListContainer
@onready var game_panel: PanelContainer = $VBox/GamePanel
@onready var game_code_label: Label = $VBox/GamePanel/Margin/VBox/GameCodeLabel
@onready var game_roster_label: Label = $VBox/GamePanel/Margin/VBox/GameRosterLabel
@onready var game_state_label: Label = $VBox/GamePanel/Margin/VBox/GameStateLabel
@onready var launch_battle_btn: Button = $VBox/GamePanel/Margin/VBox/LaunchBattleButton
@onready var waiting_for_host_label: Label = $VBox/GamePanel/Margin/VBox/WaitingForHostLabel
@onready var edit_custom_btn: Button = $VBox/LobbyPanel/Margin/VBox/EditCustomButton
@onready var custom_builder_popup: CustomScenarioBuilderPopup = $custom_builder_popup

var _gs: Node
var _is_host: bool = false
var _my_group: String = ""
var _current_state: Dictionary = {}
var _suppress_scenario_option_signal: bool = false

func _ready() -> void:
	_gs = get_node_or_null("/root/GameServer")
	if _gs == null:
		status_label.text = "Error: GameServer not found"
		return
	_is_host = get_tree().current_scene.has_node("CanvasLayer/ShareLabel")
	if _is_host:
		_setup_host()
		if _gs.has_method("start_server"):
			var share_label: Node = get_node_or_null("CanvasLayer/ShareLabel")
			_gs.start_server(share_label)
	else:
		_setup_client()


func _setup_host() -> void:
	if not _gs.has_signal("host_message_received"):
		status_label.text = "Error: GameServer has no host_message_received"
		return
	_gs.host_message_received.connect(_on_server_message)
	if _gs.has_signal("connected_players_changed"):
		_gs.connected_players_changed.connect(_refresh_connected_players)
	if connected_players_label:
		connected_players_label.visible = true
		_refresh_connected_players()
	if launch_battle_btn:
		launch_battle_btn.pressed.connect(_on_launch_battle_pressed)
	if create_btn:
		create_btn.pressed.connect(_on_create_pressed)
	if scenario_option:
		scenario_option.item_selected.connect(_on_scenario_option_selected)
	if edit_custom_btn:
		edit_custom_btn.pressed.connect(_on_edit_custom_pressed)
		edit_custom_btn.visible = false
	if username_ok:
		username_ok.pressed.connect(_on_username_submitted)
	if username_edit:
		username_edit.text_submitted.connect(_on_username_submitted_str)
	if custom_builder_popup and custom_builder_popup.has_signal("configuration_applied"):
		custom_builder_popup.configuration_applied.connect(_on_custom_builder_applied)
	connect_panel.visible = false
	username_panel.visible = true
	lobby_panel.visible = false
	game_panel.visible = false
	status_label.text = "You are the host. Enter your name."
	username_edit.clear()
	username_edit.grab_focus()


func _setup_client() -> void:
	if not _gs.has_signal("server_message_received"):
		status_label.text = "Error: GameServer has no server_message_received"
		return
	_gs.server_message_received.connect(_on_server_message)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	if launch_battle_btn:
		launch_battle_btn.pressed.connect(_on_launch_battle_pressed)
	if connect_btn:
		connect_btn.pressed.connect(_on_connect_pressed)
	if connected_players_label:
		connected_players_label.visible = false
	if edit_custom_btn:
		edit_custom_btn.visible = false
	connect_panel.visible = true
	username_panel.visible = false
	lobby_panel.visible = false
	game_panel.visible = false
	host_edit.text = Config.get_server_host()
	port_edit.text = str(Config.get_server_port())
	status_label.text = "Enter host address and click Connect."


func _refresh_connected_players() -> void:
	if not connected_players_label or not _gs.has_method("get_connected_players"):
		return
	var players: Array = _gs.get_connected_players()
	var lines: Array[String] = []
	lines.append("Connected (%d):" % players.size())
	for p in players:
		var pid: int = p.player_id
		var name_str: String = str(p.get("username", "(no name)"))
		lines.append("  %d: %s" % [pid, name_str])
	connected_players_label.text = "\n".join(lines)


func _on_connection_failed() -> void:
	status_label.text = "Connection failed. Is the server running? Check host and port."
	connect_panel.visible = true
	username_panel.visible = false


func _on_connect_pressed() -> void:
	var host: String = host_edit.text.strip_edges()
	var port_str: String = port_edit.text.strip_edges()
	if host.is_empty():
		host = "127.0.0.1"
	if port_str.is_empty():
		port_str = str(Config.get_server_port())
	var port: int = int(port_str)
	if port <= 0:
		port = Config.get_server_port()
	connect_panel.visible = false
	status_label.text = "Connecting to %s:%d..." % [host, port]
	var err: Error = _gs.join_server(host, port)
	if err != OK:
		status_label.text = "Connect failed: %s" % error_string(err)
		connect_panel.visible = true


func _on_connected_to_server() -> void:
	status_label.text = "Connected. Enter your name."
	username_panel.visible = true
	username_edit.clear()
	username_edit.grab_focus()
	if username_ok:
		username_ok.pressed.connect(_on_username_submitted)
	if username_edit:
		username_edit.text_submitted.connect(_on_username_submitted_str)


func _on_username_submitted() -> void:
	_send_username(username_edit.text.strip_edges() if username_edit.text.strip_edges() else "Player")


func _on_username_submitted_str(_txt: String) -> void:
	_send_username(username_edit.text.strip_edges() if username_edit.text.strip_edges() else "Player")


func _send_packet(msg: Dictionary) -> void:
	if _is_host and _gs.has_method("receive_host_packet"):
		_gs.receive_host_packet(msg)
	else:
		_gs.server_receive_packet.rpc_id(1, msg)


func _send_username(name_str: String) -> void:
	if name_str.is_empty():
		name_str = "Player"
	_send_packet({ type = "username", username = name_str })
	status_label.text = "Sent username, waiting for welcome..."
	username_panel.visible = false


func _on_server_message(obj: Dictionary) -> void:
	var msg_type: String = str(obj.get("type", ""))
	match msg_type:
		"welcome":
			status_label.text = "Welcome. Create or join a game."
			lobby_panel.visible = true
			if create_btn:
				create_btn.visible = _is_host
			if scenario_option:
				scenario_option.visible = _is_host
				if _is_host:
					_populate_scenario_option()
			_update_custom_builder_controls()
		"lobby":
			_populate_games_list(obj.get("games", []))
		"game_created":
			_my_group = str(obj.get("your_group", ""))
			game_code_label.text = "Game code: %s (share this to join)" % str(obj.get("short_code", ""))
			lobby_panel.visible = false
			game_panel.visible = true
			status_label.text = "Waiting for opponent..."
			_update_game_ui_for_host_or_client()
			_update_roster_from_state(_current_state)
		"game_joined":
			_my_group = str(obj.get("your_group", ""))
			game_code_label.text = "Joined game."
			lobby_panel.visible = false
			game_panel.visible = true
			status_label.text = "In game."
			_update_game_ui_for_host_or_client()
			_update_roster_from_state(_current_state)
		"game_state":
			var state = obj.get("state", {})
			if state is Dictionary:
				_current_state = state
				_update_game_state_label(state)
				_update_roster_from_state(state)
			var turn_result = obj.get("turn_result")
			if turn_result:
				game_state_label.text = game_state_label.text + "\nTurn executed."
		"player_actions_received":
			var state = obj.get("state", {})
			if state is Dictionary:
				_current_state = state
				_update_game_state_label(state)
				_update_roster_from_state(state)
		"launch_battle":
			var state = obj.get("state", {})
			if state is Dictionary:
				MultiplayerState.pending_battle_state = state
				MultiplayerState.is_multiplayer = true
				MultiplayerState.is_host = _is_host
				MultiplayerState.my_group = _my_group
				Scenarios.selected_scenario_id = str(state.get("scenario_id", "default"))
			get_tree().change_scene_to_file("res://src/battle/battle.tscn")
		"game_over":
			game_state_label.text = str(obj.get("message", "Game over."))
			if launch_battle_btn:
				launch_battle_btn.visible = false
		"error":
			status_label.text = str(obj.get("message", "Error"))


func _update_game_ui_for_host_or_client() -> void:
	if launch_battle_btn:
		launch_battle_btn.visible = _is_host
	if waiting_for_host_label:
		waiting_for_host_label.visible = not _is_host


func _update_roster_from_state(state: Dictionary) -> void:
	if not game_roster_label:
		return
	var roster: Array = state.get("roster", [])
	if roster.is_empty():
		game_roster_label.text = "Players in this game: (loading...)"
		return
	var lines: Array[String] = ["Players in this game:"]
	for r in roster:
		var group_name: String = str(r.get("group", ""))
		var username: String = str(r.get("username", "(waiting...)"))
		var suffix: String = " (you)" if group_name == _my_group else ""
		lines.append("  %s: %s%s" % [group_name, username, suffix])
	game_roster_label.text = "\n".join(lines)


func _update_game_state_label(state: Dictionary) -> void:
	var phase: String = str(state.get("phase", ""))
	var turn: int = int(state.get("turn", 0))
	var groups: Array = state.get("groups", [])
	var group_names: Array = []
	for g in groups:
		group_names.append(str(g.get("name", "")))
	game_state_label.text = "Turn %d | Phase: %s | Groups: %s" % [turn, phase, ", ".join(group_names)]


func _populate_scenario_option() -> void:
	if not scenario_option:
		return
	_suppress_scenario_option_signal = true
	scenario_option.clear()
	var scenarios: Array[Dictionary] = Scenarios.get_multiplayer_scenarios()
	for i in scenarios.size():
		var s: Dictionary = scenarios[i]
		scenario_option.add_item(str(s.get("display_name", s.get("id", "?"))), i)
		scenario_option.set_item_metadata(i, s.get("id", ""))
	scenario_option.selected = 0
	_suppress_scenario_option_signal = false
	_update_custom_builder_controls()

func _on_scenario_option_selected(_index: int) -> void:
	if _suppress_scenario_option_signal:
		return
	_update_custom_builder_controls()
	if _is_host and _is_custom_scenario_selected():
		_open_custom_builder()

func _is_custom_scenario_selected() -> bool:
	return Scenarios.is_custom_scenario_id(_get_selected_scenario_id())

func _on_edit_custom_pressed() -> void:
	_open_custom_builder()

func _open_custom_builder() -> void:
	if not _is_host:
		return
	if custom_builder_popup and custom_builder_popup.has_method("open_builder"):
		custom_builder_popup.open_builder()

func _on_custom_builder_applied() -> void:
	if status_label:
		status_label.text = "Custom scenario updated."

func _update_custom_builder_controls() -> void:
	var has_option: bool = scenario_option != null
	var should_show: bool = _is_host and has_option and scenario_option.visible and _is_custom_scenario_selected()
	if edit_custom_btn:
		edit_custom_btn.visible = should_show

func _get_selected_scenario_id() -> String:
	if not scenario_option or scenario_option.selected < 0:
		return "default"
	var id_str: String = str(scenario_option.get_item_metadata(scenario_option.selected))
	if not id_str.is_empty():
		return id_str
	var scenarios: Array[Dictionary] = Scenarios.get_multiplayer_scenarios()
	var idx: int = scenario_option.selected
	if idx >= 0 and idx < scenarios.size():
		return str(scenarios[idx].get("id", "default"))
	return "default"

func _on_create_pressed() -> void:
	var scenario_id: String = _get_selected_scenario_id()
	_send_packet({ type = "create_game", scenario_id = scenario_id })
	status_label.text = "Creating game..."


func _populate_games_list(games: Array) -> void:
	if not games_list_container:
		return
	for c in games_list_container.get_children():
		c.queue_free()
	for g in games:
		var count: int = int(g.get("player_count", 0))
		var game_max: int = int(g.get("max_players", 2))
		if game_max < 1:
			game_max = 2
		if count >= game_max:
			continue
		var game_id: String = str(g.get("game_id", ""))
		if game_id.is_empty():
			continue
		var scenario_id: String = str(g.get("scenario_id", "?"))
		var btn := Button.new()
		btn.text = "Join: %s (%d/%d players)" % [scenario_id, count, game_max]
		btn.pressed.connect(_on_join_game_pressed.bind(game_id))
		games_list_container.add_child(btn)


func _on_join_game_pressed(game_id: String) -> void:
	_send_packet({ type = "join_game", game_id = game_id })
	status_label.text = "Joining..."


func _on_launch_battle_pressed() -> void:
	_send_packet({ type = "launch_battle" })
