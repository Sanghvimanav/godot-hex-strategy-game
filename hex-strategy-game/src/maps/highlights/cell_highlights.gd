extends Node2D

const HIGHLIGHT_STROKE_ONLY = preload('res://src/maps/highlights/cell_highlight_stroke_only.png')
const HIGHLIGHT_FILL = preload('res://src/maps/highlights/cell_highlight_no_stroke.png')

@onready var paths_fill: Node2D = $paths_fill
@onready var paths_highlights: Node2D = $paths
@onready var attacks_highlights: Node2D = $attacks
@onready var selected_unit_highlight: Node2D = $selected_unit

var mouse_highlight: Polygon2D

func _ready() -> void:
	# Replace square sprite with hex-shaped highlight
	var old_sprite: Sprite2D = $mouse_highlight
	old_sprite.queue_free()
	mouse_highlight = Polygon2D.new()
	mouse_highlight.color = Color(1, 0.875, 0.5, 0.6)
	mouse_highlight.z_index = 10  ## Above units so selector stays visible when hovering
	add_child(mouse_highlight)
	EventBus.show_move_acs.connect(_on_show_move_acs)
	EventBus.show_attack_acs.connect(_on_show_attack_acs)
	EventBus.show_move_path.connect(_on_show_move_path)
	EventBus.show_selected_unit_cell.connect(_on_show_selected_unit_cell)

func _process(_delta: float) -> void:
	var cell := Navigation.world_to_cell(get_global_mouse_position())
	mouse_highlight.visible = Navigation.is_valid_cell(cell)
	if mouse_highlight.visible:
		var snapped_pos := Navigation.snap_to_tile(get_global_mouse_position())
		mouse_highlight.global_position = snapped_pos
	var radius: float = HexGrid.tile_radius * 1.05
	mouse_highlight.polygon = HexGrid.polygon_points_hex(0, 0, radius, 0.0)

func _on_show_attack_acs(acs: Array, _from_cell: Vector2 = Vector2.ZERO) -> void:
	_clear_highlight_children(attacks_highlights)
	_draw_selectable_endpoints(acs, attacks_highlights, Color(1.0, 0.5, 0.0, 0.5), Color(1.0, 0.5, 0.0, 1.0), true, true)

func _on_show_move_acs(acs: Array) -> void:
	_clear_highlight_children(paths_highlights)
	_draw_selectable_endpoints(acs, paths_highlights, Color(0.0, 0.75, 1.0, 0.35), Color(0.0, 0.75, 1.0, 1.0), false, true)

func _clear_highlight_children(parent: Node2D) -> void:
	for child in parent.get_children():
		child.queue_free()

## Shared selectable-tile renderer for both move and attack options.
func _draw_selectable_endpoints(acs: Array, parent: Node2D, fill_color: Color, stroke_color: Color, draw_fill: bool, draw_stroke: bool) -> void:
	var seen_cells: Dictionary = {}
	for ac in acs:
		if ac == null:
			continue
		var cell: Vector2 = ac.end_point
		if not Navigation.is_valid_cell(cell):
			continue
		var cell_key := HexGrid.get_cell_key(int(cell.x), int(cell.y))
		if seen_cells.has(cell_key):
			continue
		seen_cells[cell_key] = true
		var world_pos: Vector2 = Navigation.cell_to_world(cell)
		if draw_fill:
			add_hex_highlight(fill_color, world_pos, parent, HIGHLIGHT_FILL)
		if draw_stroke:
			add_hex_highlight(stroke_color, world_pos, parent, HIGHLIGHT_STROKE_ONLY)

func _on_show_selected_unit_cell(cell: Variant) -> void:
	for child in selected_unit_highlight.get_children():
		child.queue_free()
	if cell != null and Navigation.is_valid_cell(cell):
		add_hex_highlight(Color(1.0, 0.9, 0.2, 1.0), Navigation.cell_to_world(cell), selected_unit_highlight, HIGHLIGHT_STROKE_ONLY)

func _on_show_move_path(ac: ActionInstance, from_cell: Vector2 = Vector2.ZERO) -> void:
	for child in paths_fill.get_children():
		child.queue_free()
	
	if ac:
		for cell in ac.path:
			if Navigation.is_valid_cell(cell):
				add_hex_highlight(Color(0.0, 0.5, 1.0, 0.5), Navigation.cell_to_world(cell), paths_fill, HIGHLIGHT_FILL)
		# AoE tiles shown on hover (attack targets only)
		var config: Dictionary = Actions.get_action_config(ac.definition.action_key) if ac.definition else {}
		var aoe: Dictionary = config.get("area_of_effect", {})
		if not aoe.is_empty() and Navigation.is_valid_cell(from_cell):
			var aoe_cells: Array = HexGrid.get_aoe_tiles(from_cell, ac.end_point, aoe)
			for aoe_cell in aoe_cells:
				if Navigation.is_valid_cell(aoe_cell):
					add_hex_highlight(Color(1.0, 0.75, 0.15, 0.55), Navigation.cell_to_world(aoe_cell), paths_fill, HIGHLIGHT_FILL)
					add_hex_highlight(Color(1.0, 0.85, 0.2, 1.0), Navigation.cell_to_world(aoe_cell), paths_fill, HIGHLIGHT_STROKE_ONLY)

func add_hex_highlight(color: Color, pos: Vector2, parent: Node, tex: Texture) -> void:
	var radius: float = HexGrid.tile_radius * 1.05  ## Slightly larger so highlight sits on top of tile
	var points := HexGrid.polygon_points_hex(pos.x, pos.y, radius, 0.0)
	if tex == HIGHLIGHT_STROKE_ONLY:
		var line := Line2D.new()
		var closed := PackedVector2Array(points)
		closed.append(points[0])
		line.points = closed
		line.width = 2.0
		line.default_color = color
		line.z_index = 0  ## Above tiles (-2), below units (1)
		parent.add_child(line)
	else:
		var poly := Polygon2D.new()
		poly.polygon = points
		poly.color = color
		poly.z_index = 0  ## Above tiles (-2), below units (1)
		parent.add_child(poly)
