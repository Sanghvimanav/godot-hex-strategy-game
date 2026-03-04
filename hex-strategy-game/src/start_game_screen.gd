extends Control

@onready var start_button: Button = $CenterContainer/VBox/StartButton


func _ready() -> void:
	start_button.pressed.connect(_on_start_button_pressed)


func _on_start_button_pressed() -> void:
	get_tree().change_scene_to_file("res://src/main_menu.tscn")
