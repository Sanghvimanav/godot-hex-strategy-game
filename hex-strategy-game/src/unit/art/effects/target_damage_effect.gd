extends Node2D
## One-shot target tile damage VFX for Scout/Hydralisk attacks.

@onready var sprite: AnimatedSprite2D = $sprite

func _ready() -> void:
	sprite.animation_finished.connect(_on_animation_finished)
	sprite.play("default")

func _on_animation_finished() -> void:
	queue_free()
