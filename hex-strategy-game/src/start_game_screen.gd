extends Control

@onready var narrative_text: Label = $CenterContainer/VBox/NarrativeText
@onready var start_button: Button = $CenterContainer/VBox/StartButton


func _ready() -> void:
	if narrative_text:
		narrative_text.text = Scenarios.get_selected_scenario_intro_text()
	if start_button:
		start_button.pressed.connect(_on_start_button_pressed)


func _on_start_button_pressed() -> void:
	get_tree().change_scene_to_file("res://src/main_menu.tscn")
