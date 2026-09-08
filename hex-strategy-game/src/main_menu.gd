extends Control
## Main menu for multiplayer testing. Run the project twice: first window choose "Host server", second choose "Join game".

@onready var host_btn: Button = $VBox/HostButton
@onready var join_btn: Button = $VBox/JoinButton
@onready var single_btn: Button = $VBox/SinglePlayerButton

func _ready() -> void:
	if host_btn:
		host_btn.pressed.connect(_on_host_pressed)
	if join_btn:
		join_btn.pressed.connect(_on_join_pressed)
	if single_btn:
		single_btn.pressed.connect(_on_single_pressed)
	var arena_btn := Button.new()
	arena_btn.name = "ArenaPlaytestButton"
	arena_btn.text = "Arena Playtest"
	arena_btn.tooltip_text = "Play official Arena seeds yourself against the handwritten GameplayAI."
	arena_btn.custom_minimum_size.y = 44
	$VBox.add_child(arena_btn)
	arena_btn.pressed.connect(_on_arena_playtest_pressed)


func _on_host_pressed() -> void:
	get_tree().change_scene_to_file("res://src/server/game_server.tscn")


func _on_join_pressed() -> void:
	get_tree().change_scene_to_file("res://src/multiplayer/multiplayer_lobby.tscn")


func _on_single_pressed() -> void:
	get_tree().change_scene_to_file("res://src/battle/scenario_picker.tscn")


func _on_arena_playtest_pressed() -> void:
	get_tree().change_scene_to_file("res://src/battle/arena_playtest_picker.tscn")
