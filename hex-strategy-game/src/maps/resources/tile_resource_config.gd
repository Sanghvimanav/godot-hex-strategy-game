class_name TileResourceConfig
extends Resource

## Inspector-configurable finite resource state for a single hex tile.
@export var cell: Vector2i = Vector2i.ZERO
@export var resource_type: String = "ore"
@export_range(0, 999, 1) var amount: int = 3
@export var resource_color: Color = Color(0.92, 0.74, 0.2)
@export var depleted_color: Color = Color(0.35, 0.35, 0.35)
