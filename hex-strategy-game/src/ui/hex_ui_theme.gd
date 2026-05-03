extends Node
## Applies the shared UI theme to the root viewport so all Control nodes inherit it.

const _BUILDER := preload("res://src/ui/hex_ui_theme_builder.gd")


func _ready() -> void:
	get_tree().root.theme = _BUILDER.build()
