extends Node
## Multiplayer game server using ENet (Godot MultiplayerAPI).
## Phase 1: one game, create_game / join_game, turn execution, broadcast state.
## Run this scene to host. Clients connect via ENet and send protocol messages via server_receive_packet().
## On client, connect to server_message_received to handle incoming messages.

signal server_message_received(obj: Dictionary)
## Emitted when the host (player 1) should receive a message; used when host is also a player.
signal host_message_received(obj: Dictionary)
## Emitted when the list of connected players (or their names) changes. Host can use get_connected_players().
signal connected_players_changed()

const PORT := 8081
const MAX_CLIENTS := 16
const HOST_PEER_ID := 0  # Sentinel: host has no real peer, we use 0 and deliver via signal

var _peer  # ENetMultiplayerPeer
var _next_player_id: int = 1
var _next_unit_id: int = 1
var _next_game_id: int = 1
var _peer_id_to_player_id: Dictionary = {}
var _player_id_to_peer_id: Dictionary = {}
var _player_id_to_username: Dictionary = {}
var _games: Dictionary = {}
var _short_code_to_game_id: Dictionary = {}
var _player_game_id: Dictionary = {}

func _ready() -> void:
	# Server is started by the host scene via start_server(). Clients use join_server().
	pass


## Call from the host scene (e.g. lobby _setup_host) to start listening. Pass ShareLabel to show IP.
func start_server(share_label: Node = null) -> void:
	if _peer != null:
		return
	_peer = ENetMultiplayerPeer.new()
	var err: int = _peer.create_server(PORT, MAX_CLIENTS)
	if err != OK:
		push_error("Server failed to listen on port %d: %s" % [PORT, error_string(err)])
		return
	multiplayer.multiplayer_peer = _peer
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	print("Hex strategy game server (ENet) listening on port %d" % PORT)
	if share_label is Label:
		var local_ip: String = _get_local_ip()
		share_label.text = "Share with friend:\n%s:%d\n\n(Port 8081 must be open if they're on another network)" % [local_ip, PORT]
	register_host_player()


func _get_local_ip() -> String:
	var addrs: PackedStringArray = IP.get_local_addresses()
	for a in addrs:
		if not a.begins_with("127.") and not a.begins_with("::"):
			return a
	return "127.0.0.1"


## Register the host as player 1 so they can use the lobby UI in the same process.
func register_host_player() -> void:
	_peer_id_to_player_id[HOST_PEER_ID] = 1
	_player_id_to_peer_id[1] = HOST_PEER_ID
	_next_player_id = 2
	print("Host registered as player 1")
	connected_players_changed.emit()


## Returns an array of { player_id: int, username: String } for all connected players (including host).
func get_connected_players() -> Array:
	var out: Array = []
	for player_id in _player_id_to_peer_id:
		var name_str: String = _player_id_to_username.get(player_id, "")
		if name_str.is_empty():
			name_str = "(no name)" if player_id != 1 else "(host)"
		out.append({ player_id = player_id, username = name_str })
	out.sort_custom(func(a, b): return a.player_id < b.player_id)
	return out


## Host sends a packet locally (no RPC). Call from lobby when host is also a player.
func receive_host_packet(msg: Dictionary) -> void:
	_handle_message_dict(1, msg)


## Call from a client scene to connect to a host. Use server_receive_packet.rpc_id(1, msg) to send.
func join_server(host: String = "127.0.0.1", port: int = PORT) -> Error:
	if _peer != null:
		return ERR_ALREADY_IN_USE
	_peer = ENetMultiplayerPeer.new()
	var err: int = _peer.create_client(host, port)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = _peer
	print("ENet client connecting to %s:%d" % [host, port])
	return OK


## Converts a Scenarios.available_scenarios entry to server format.
## Uses shared scenarios; forces ai=false for all groups (multiplayer); handles randomize_positions.
func _scenario_to_server_format(s: Dictionary) -> Dictionary:
	var groups_ser: Array = []
	var randomize_pos: bool = s.get("randomize_positions", false)
	for g in s.get("groups", []):
		var units_list: Array = g.get("units", [])
		var cell_pool: Array = g.get("cell_pool", [])
		if randomize_pos and cell_pool.size() >= units_list.size():
			cell_pool = cell_pool.duplicate()
			cell_pool.shuffle()
		var units_ser: Array = []
		for i in units_list.size():
			var u_spec: Dictionary = units_list[i]
			var cell: Array
			if randomize_pos and i < cell_pool.size():
				var v = cell_pool[i]
				cell = [int(v.x), int(v.y)] if v is Vector2i else [int(v[0]), int(v[1])]
			elif u_spec.has("cell"):
				var c = u_spec.cell
				cell = [int(c.x), int(c.y)] if c is Vector2i else [int(c[0]), int(c[1])]
			else:
				cell = [0, 0]
			units_ser.append({ def_path = u_spec.def_path, cell = cell })
		groups_ser.append({
			name = g.name,
			ai = false,
			units = units_ser,
			resources = g.get("resources", {}).duplicate(true)
		})
	return {
		id = s.id,
		display_name = s.display_name,
		groups = groups_ser,
		tile_resources = s.get("tile_resources", {}).duplicate(true)
	}

func _get_scenario_for_multiplayer(scenario_id: String) -> Dictionary:
	var s: Dictionary = Scenarios.get_scenario_by_id(scenario_id)
	if s.is_empty():
		s = Scenarios.available_scenarios[0] if Scenarios.available_scenarios.size() > 0 else {}
	return _scenario_to_server_format(s)


func _generate_short_code() -> String:
	var chars := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	var code := ""
	for i in 6:
		code += chars[randi() % chars.length()]
	return code


func _serialize_game_state(game: Dictionary) -> Dictionary:
	var groups_ser: Array = []
	for g in game.groups:
		groups_ser.append({
			name = g.name,
			ai = g.get("ai", false),
			player_id = g.get("player_id"),
			units = g.units.duplicate(true),
			resources = g.get("resources", {}).duplicate(true)
		})
	return {
		game_id = game.game_id,
		short_code = game.short_code,
		scenario_id = game.scenario_id,
		phase = game.phase,
		turn = game.turn,
		groups = groups_ser,
		tile_resources = game.get("tile_resources", {}).duplicate(true),
		player_actions = game.player_actions.duplicate(true),
		roster = _build_roster(game)
	}


func _build_roster(game: Dictionary) -> Array:
	var roster: Array = []
	for g in game.groups:
		var pid = g.get("player_id")
		var group_name: String = str(g.get("name", ""))
		if pid != null:
			var username: String = _player_id_to_username.get(pid, "(no name)")
			if pid == 1:
				username = username + " (host)"
			roster.append({ group = group_name, username = username })
		else:
			roster.append({ group = group_name, username = "(waiting...)" })
	return roster


## Automatically assign any connected, game-less players to open human groups in this game.
func _auto_fill_game_with_waiting_players(game: Dictionary) -> void:
	var waiting: Array = []
	for player_id in _player_id_to_peer_id:
		if _player_game_id.get(player_id, "") == "":
			waiting.append(player_id)
	if waiting.is_empty():
		return
	waiting.sort()

	var assigned: Array = []
	var idx := 0
	for g in game.groups:
		if g.get("ai", false):
			continue
		if g.get("player_id") != null:
			continue
		if idx >= waiting.size():
			break
		var pid: int = waiting[idx]
		g.player_id = pid
		_player_game_id[pid] = game.game_id
		assigned.append({ player_id = pid, group = g.name })
		idx += 1

	for entry in assigned:
		var pid: int = entry.player_id
		var gname: String = entry.group
		_send_to_player(pid, {
			type = "game_joined",
			game_id = game.game_id,
			your_group = gname,
			scenario_id = game.scenario_id
		})

	if assigned.size() > 0:
		game.status = "playing"
		game.phase = "planning"
		_broadcast_to_game(game, { type = "game_state", state = _serialize_game_state(game) })


func _broadcast_to_game(game: Dictionary, msg: Dictionary) -> void:
	var player_ids: Array = []
	for g in game.groups:
		var pid = g.get("player_id")
		if pid != null:
			player_ids.append(pid)
	# Send to remote clients first; then deliver to host. Otherwise the host's
	# scene change on launch_battle would leave the tree before RPCs reach clients.
	for pid in player_ids:
		var peer_id: int = _player_id_to_peer_id.get(pid, -1)
		if peer_id > 0:
			client_receive_message.rpc_id(peer_id, msg)
	for pid in player_ids:
		var peer_id: int = _player_id_to_peer_id.get(pid, -1)
		if peer_id == HOST_PEER_ID:
			host_message_received.emit(msg)
			break


func _send_to_player(player_id: int, msg: Dictionary) -> void:
	var peer_id: int = _player_id_to_peer_id.get(player_id, -1)
	if peer_id == HOST_PEER_ID:
		host_message_received.emit(msg)
		return
	if peer_id < 0:
		return
	client_receive_message.rpc_id(peer_id, msg)


func _all_human_groups_ready(game: Dictionary) -> bool:
	print("[READY_CHECK] game_id=%s" % game.game_id)
	for group in game.groups:
		if group.get("ai", false):
			continue
		var gname: String = str(group.get("name", ""))
		var active_units: Array = group.units.filter(func(u): return u.get("health", 0) > 0)
		var actions: Array = game.player_actions.get(gname, [])
		var ready: bool = true
		if not active_units.is_empty() and actions.is_empty():
			ready = false
		print("  group=%s active_units=%d actions=%d ready=%s" % [gname, active_units.size(), actions.size(), str(ready)])
		if not ready:
			return false
	return true


func _on_peer_connected(peer_id: int) -> void:
	var player_id: int = _next_player_id
	_next_player_id += 1
	_peer_id_to_player_id[peer_id] = player_id
	_player_id_to_peer_id[player_id] = peer_id
	print("Client connected (peer %d) -> player %d" % [peer_id, player_id])
	connected_players_changed.emit()


func _on_peer_disconnected(peer_id: int) -> void:
	var player_id: int = _peer_id_to_player_id.get(peer_id, -1)
	_peer_id_to_player_id.erase(peer_id)
	if player_id >= 0:
		_player_id_to_peer_id.erase(player_id)
		_player_id_to_username.erase(player_id)
	var gid: String = _player_game_id.get(player_id, "")
	if gid != "":
		_player_game_id.erase(player_id)
	print("Client disconnected (peer %d, player %d)" % [peer_id, player_id])
	connected_players_changed.emit()


## Called by clients to send a protocol message (create_game, join_game, submit_actions, etc.)
@rpc("any_peer", "reliable")
func server_receive_packet(msg: Dictionary) -> void:
	var peer_id: int = multiplayer.get_remote_sender_id()
	var player_id: int = _peer_id_to_player_id.get(peer_id, -1)
	if player_id < 0:
		return
	_handle_message_dict(player_id, msg)


## Called on clients when server sends a message. Emits server_message_received so UI can react.
@rpc("authority", "reliable")
func client_receive_message(obj: Dictionary) -> void:
	server_message_received.emit(obj)


func _handle_message_dict(player_id: int, msg: Dictionary) -> void:
	var msg_type: String = str(msg.get("type", ""))
	match msg_type:
		"username":
			_player_id_to_username[player_id] = str(msg.get("username", "Player"))
			connected_players_changed.emit()
			_send_to_player(player_id, {
				type = "welcome",
				player_id = player_id,
				session_id = "sess_%d_%d" % [player_id, Time.get_ticks_msec()],
				message = "Connected. Use create_game or join_game."
			})
			var games_list: Array = []
			for gid in _games:
				var game = _games[gid]
				if game.get("game_id"):
					var count: int = 0
					var max_players: int = 0
					for g in game.groups:
						if not g.get("ai", false):
							max_players += 1
							if g.get("player_id") != null:
								count += 1
					games_list.append({
						game_id = game.game_id,
						short_code = game.short_code,
						scenario_id = game.scenario_id,
						player_count = count,
						max_players = max_players,
						status = game.get("status", "")
					})
			_send_to_player(player_id, { type = "lobby", games = games_list })
		"create_game":
			if player_id != 1:
				_send_to_player(player_id, { type = "error", message = "Only the host can create a game" })
				return
			if _player_game_id.get(player_id, "") != "":
				_send_to_player(player_id, { type = "error", message = "Already in a game" })
				return
			var scenario_id: String = str(msg.get("scenario_id", "default"))
			var game: Dictionary = _create_game(scenario_id, player_id)
			_player_game_id[player_id] = game.game_id
			_send_to_player(player_id, {
				type = "game_created",
				game_id = game.game_id,
				short_code = game.short_code,
				scenario_id = game.scenario_id,
				your_group = game.groups[0].name
			})
			_send_to_player(player_id, { type = "game_state", state = _serialize_game_state(game) })
			_auto_fill_game_with_waiting_players(game)
		"join_game":
			if _player_game_id.get(player_id, "") != "":
				_send_to_player(player_id, { type = "error", message = "Already in a game" })
				return
			var game_id_or_code: String = str(msg.get("game_id", msg.get("short_code", "")))
			var gid: String = _short_code_to_game_id.get(game_id_or_code, game_id_or_code)
			var game = _games.get(gid)
			if game == null:
				_send_to_player(player_id, { type = "error", message = "Game not found" })
				return
			var open_group = null
			for g in game.groups:
				if not g.get("ai", false) and g.get("player_id") == null:
					open_group = g
					break
			if open_group == null:
				_send_to_player(player_id, { type = "error", message = "Game is full" })
				return
			open_group.player_id = player_id
			_player_game_id[player_id] = game.game_id
			game.status = "playing"
			game.phase = "planning"
			_send_to_player(player_id, {
				type = "game_joined",
				game_id = game.game_id,
				your_group = open_group.name,
				scenario_id = game.scenario_id
			})
			_broadcast_to_game(game, { type = "game_state", state = _serialize_game_state(game) })
		"submit_actions":
			var gid: String = _player_game_id.get(player_id, "")
			if gid == "":
				_send_to_player(player_id, { type = "error", message = "Not in a game" })
				return
			var game = _games.get(gid)
			if game == null:
				return
			var my_group = null
			for g in game.groups:
				if g.get("player_id") == player_id:
					my_group = g
					break
			if my_group == null:
				_send_to_player(player_id, { type = "error", message = "No group assigned" })
				return
			var actions: Array = msg.get("actions", []) if msg.get("actions") is Array else []
			print("[SUBMIT] player_id=%d group=%s actions=%d" % [player_id, str(my_group.name), actions.size()])
			for action in actions:
				var result: Dictionary = ServerTurnExecutor.validate_action(game, action, my_group.name)
				if not result.get("valid", false):
					print("[SUBMIT] invalid action for group %s: %s" % [str(my_group.name), str(result.get("error", "Invalid action"))])
					_send_to_player(player_id, { type = "error", message = result.get("error", "Invalid action") })
					return
			game.player_actions[my_group.name] = actions
			print("[SUBMIT] stored actions for group=%s, total_groups_with_actions=%d" % [str(my_group.name), game.player_actions.size()])
			_broadcast_to_game(game, {
				type = "player_actions_received",
				group = my_group.name,
				state = _serialize_game_state(game)
			})
			if _all_human_groups_ready(game):
				print("[TURN] all human groups ready; executing turn for game_id=%s turn=%d" % [game.game_id, game.turn])
				game.phase = "executing"
				var turn_result: Dictionary = ServerTurnExecutor.execute_turn(game, game.player_actions)
				game.turn += 1
				game.phase = "planning"
				game.player_actions = {}
				var winner: String = ServerTurnExecutor.check_win_condition(game)
				_broadcast_to_game(game, {
					type = "game_state",
					state = _serialize_game_state(game),
					turn_result = turn_result
				})
				if winner != "":
					_broadcast_to_game(game, {
						type = "game_over",
						winner = winner,
						message = "%s wins!" % winner
					})
				else:
					var any_alive: bool = false
					for g in game.groups:
						if g.get("ai", false):
							continue
						for u in g.units:
							if u.get("health", 0) > 0:
								any_alive = true
								break
					if not any_alive:
						_broadcast_to_game(game, {
							type = "game_over",
							winner = null,
							message = "Draw!"
						})
		"restart":
			var gid: String = _player_game_id.get(player_id, "")
			if gid == "":
				return
			var game = _games.get(gid)
			if game == null:
				return
			var scenario: Dictionary = _get_scenario_for_multiplayer(game.scenario_id)
			game.phase = "planning"
			game.turn = 1
			game.player_actions = {}
			game.tile_resources = scenario.get("tile_resources", {}).duplicate(true)
			var uid := 1
			for gi in game.groups.size():
				var g = game.groups[gi]
				var g_spec = scenario.groups[gi]
				g.resources = g_spec.get("resources", {}).duplicate(true)
				g.units.clear()
				for u_spec in g_spec.units:
					var def_path: String = u_spec.get("def_path", "")
					var cell: Array = u_spec.get("cell", [0, 0])
					var def_dict: Dictionary = TurnExecutionCore.get_unit_def(def_path)
					var max_h: int = def_dict.get("max_health", 2)
					var max_e: int = def_dict.get("max_energy", 0)
					var start_e: int = def_dict.get("start_energy", max_e) if max_e > 0 else 0
					g.units.append({
						unit_id = uid,
						def_path = def_path,
						cell = [int(cell[0]), int(cell[1])],
						health = max_h,
						max_health = max_h,
						energy = start_e,
						max_energy = max_e,
						is_active = true
					})
					uid += 1
			_next_unit_id = maxi(_next_unit_id, uid)
			_broadcast_to_game(game, { type = "game_state", state = _serialize_game_state(game) })
		"launch_battle":
			if player_id != 1:
				_send_to_player(player_id, { type = "error", message = "Only the host can start the game" })
				return
			var gid: String = _player_game_id.get(player_id, "")
			if gid == "":
				_send_to_player(player_id, { type = "error", message = "Not in a game" })
				return
			var game = _games.get(gid)
			if game == null:
				return
			_broadcast_to_game(game, { type = "launch_battle", state = _serialize_game_state(game) })
		_:
			_send_to_player(player_id, { type = "error", message = "Unknown message type: %s" % msg_type })


func _create_game(scenario_id: String, host_player_id: int) -> Dictionary:
	var scenario: Dictionary = _get_scenario_for_multiplayer(scenario_id)
	var game_id := str(_next_game_id)
	_next_game_id += 1
	var short_code := _generate_short_code()
	_short_code_to_game_id[short_code] = game_id

	var groups: Array = []
	for gi in scenario.groups.size():
		var g_spec = scenario.groups[gi]
		var g: Dictionary = {
			name = g_spec.name,
			ai = g_spec.get("ai", false),
			player_id = host_player_id if gi == 0 and not g_spec.get("ai", false) else null,
			units = [],
			resources = g_spec.get("resources", {}).duplicate(true)
		}
		for u_spec in g_spec.get("units", []):
			var unit_id: int = _next_unit_id
			_next_unit_id += 1
			var def_path: String = u_spec.get("def_path", "")
			var cell: Array = u_spec.get("cell", [0, 0]) if u_spec.get("cell") else [0, 0]
			var def_dict: Dictionary = TurnExecutionCore.get_unit_def(def_path)
			var max_h: int = def_dict.get("max_health", 2)
			var max_e: int = def_dict.get("max_energy", 0)
			var start_e: int = def_dict.get("start_energy", max_e) if max_e > 0 else 0
			g.units.append({
				unit_id = unit_id,
				def_path = def_path,
				cell = [int(cell[0]), int(cell[1])],
				health = max_h,
				max_health = max_h,
				energy = start_e,
				max_energy = max_e,
				is_active = true
			})
		groups.append(g)

	var game := {
		game_id = game_id,
		short_code = short_code,
		scenario_id = scenario.id,
		phase = "planning",
		turn = 1,
		groups = groups,
		tile_resources = scenario.get("tile_resources", {}).duplicate(true),
		player_actions = {},
		status = "waiting"
	}
	_games[game_id] = game
	return game
