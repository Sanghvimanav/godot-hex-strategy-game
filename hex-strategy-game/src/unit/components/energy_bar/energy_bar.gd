extends Node2D
## Blue energy squares displayed below the health bar. Used by Scouts and other energy-based units.

const BOX_SIZE: Vector2 = Vector2(4, 4)
const SPACING: int = 1
const Y: int = -26  ## Above health bar (health at Y=-21)

@export var OUTLINE_COLOR: Color = Color('#1a3a5c')
@export var FILL_COLOR: Color = Color('#4a90d9')
@export var EMPTY_COLOR: Color = Color('#251d22')

var max_value: int
var value: int

func _draw() -> void:
	var total_width = (BOX_SIZE.x * max_value) + (SPACING * (max_value - 1))
	var x = -total_width / 2.0
	for i in max_value:
		draw_rect(Rect2(Vector2(x, Y), BOX_SIZE), OUTLINE_COLOR, true)
		var fill = FILL_COLOR if value > i else EMPTY_COLOR
		draw_rect(Rect2(Vector2(x + 1, Y + 1), BOX_SIZE - Vector2(2, 2)), fill, true)
		x += BOX_SIZE.x + SPACING

func init(v: int, max_v: int) -> void:
	max_value = max_v
	value = v
	queue_redraw()

func update_value(v: int) -> void:
	value = v
	queue_redraw()
