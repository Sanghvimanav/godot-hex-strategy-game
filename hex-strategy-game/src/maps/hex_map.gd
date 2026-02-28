extends Node2D
## Hex map: defines walkable hex grid and draws hex tiles.
## Replaces square TileMap for hexagonal gameplay.

const TileResourceConfig = preload("res://src/maps/resources/tile_resource_config.gd")

@export_range(8, 96, 2) var spacing: int = 24  ## Distance between hex centers
@export_range(4, 64, 1) var tile_radius: float = 12  ## Visual size of each hex (radius from center to corner)
## Hexagon radius: board includes all hexes within this distance from center (0,0). 5 = 5 tiles across.
@export var hex_radius: int = 5
@export var hex_color: Color = Color(0.2, 0.5, 0.2)
@export var hex_color_alt: Color = Color(0.25, 0.55, 0.25)
@export var color_variation: float = 0.12  ## Random hue/sat offset per tile
## Finite resources configured per tile. These tiles are color-tinted and can be depleted.
@export var resource_tiles: Array[TileResourceConfig] = []
@export_range(0.0, 1.0, 0.05) var resource_tint_strength: float = 0.75
@export var default_depleted_resource_color: Color = Color(0.35, 0.35, 0.35)

var grid: Dictionary = {}  # "q,r" -> { q, r, is_solid, resource_type, resource_amount, resource_max_amount, resource_color, resource_depleted_color }
var _hex_nodes: Dictionary = {}
var _hex_base_colors: Dictionary = {}  # "q,r" -> Color, for fog dimming
var _bounds: Dictionary = {}

func _ready() -> void:
	HexGrid.spacing = spacing
	HexGrid.tile_radius = tile_radius
	_build_grid()
	_draw_hexes()
	if not EventBus.tile_resource_deplete_requested.is_connected(_on_tile_resource_deplete_requested):
		EventBus.tile_resource_deplete_requested.connect(_on_tile_resource_deplete_requested)
	# Init Navigation before units run (hex_map is first child, units later)
	var units_node = get_parent().get_node_or_null("units")
	if units_node and units_node.has_method("get_active_units"):
		Navigation.init_level_hex(grid, units_node.get_active_units)
	# Fog of war: refresh once units are in place (deferred)
	call_deferred("_refresh_fog")

func _exit_tree() -> void:
	if EventBus.tile_resource_deplete_requested.is_connected(_on_tile_resource_deplete_requested):
		EventBus.tile_resource_deplete_requested.disconnect(_on_tile_resource_deplete_requested)

func _build_grid() -> void:
	grid.clear()
	for q in range(-hex_radius, hex_radius + 1):
		for r in range(-hex_radius, hex_radius + 1):
			if HexGrid.hex_distance(0, 0, q, r) <= hex_radius:
				var key := HexGrid.get_cell_key(q, r)
				grid[key] = {
					q = q,
					r = r,
					is_solid = false,
					resource_type = "",
					resource_amount = 0,
					resource_max_amount = 0,
					resource_color = Color(0.92, 0.74, 0.2),
					resource_depleted_color = default_depleted_resource_color
				}
	_apply_resource_tiles()
	_bounds = HexGrid.calculate_map_bounds(grid)

func _draw_hexes() -> void:
	for c in get_children():
		c.queue_free()
	_hex_nodes.clear()
	_hex_base_colors.clear()
	
	z_index = -2  ## Tiles draw below highlights
	var min_x: float = _bounds.min_x
	var min_y: float = _bounds.min_y
	for key in grid:
		var tile = grid[key]
		var pos := HexGrid.hex_to_pixel(tile.q, tile.r, min_x, min_y, 0.0)
		var poly := Polygon2D.new()
		poly.polygon = HexGrid.polygon_points_hex(pos.x, pos.y, tile_radius, 0.0)
		var tile_color := _compute_tile_color(tile)
		poly.color = tile_color
		_hex_base_colors[key] = tile_color
		add_child(poly)
		_hex_nodes[key] = poly

func _apply_resource_tiles() -> void:
	for cfg in resource_tiles:
		if cfg == null:
			continue
		var key := HexGrid.get_cell_key(int(cfg.cell.x), int(cfg.cell.y))
		if not grid.has(key):
			continue
		var tile: Dictionary = grid[key]
		var max_amount := maxi(0, int(cfg.amount))
		tile.resource_type = cfg.resource_type
		tile.resource_amount = max_amount
		tile.resource_max_amount = max_amount
		tile.resource_color = cfg.resource_color
		tile.resource_depleted_color = cfg.depleted_color
		grid[key] = tile

func _compute_terrain_color(tile: Dictionary) -> Color:
	var is_alt: bool = (int(tile.q) + int(tile.r)) % 2 == 0
	var base: Color = hex_color if is_alt else hex_color_alt
	var seed_val: int = int(tile.q) * 7919 + int(tile.r) * 7877
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val
	var r := clampf(base.r + (rng.randf() - 0.5) * color_variation, 0.0, 1.0)
	var g := clampf(base.g + (rng.randf() - 0.5) * color_variation, 0.0, 1.0)
	var b := clampf(base.b + (rng.randf() - 0.5) * color_variation, 0.0, 1.0)
	return Color(r, g, b)

func _compute_tile_color(tile: Dictionary) -> Color:
	var terrain: Color = _compute_terrain_color(tile)
	var max_amount: int = int(tile.get("resource_max_amount", 0))
	if max_amount <= 0:
		return terrain
	var amount: int = clampi(int(tile.get("resource_amount", 0)), 0, max_amount)
	var resource_color: Color = tile.get("resource_color", Color(0.92, 0.74, 0.2))
	var depleted_color: Color = tile.get("resource_depleted_color", default_depleted_resource_color)
	var rich_color: Color = terrain.lerp(resource_color, resource_tint_strength)
	var fill_ratio: float = float(amount) / float(max_amount)
	return depleted_color.lerp(rich_color, fill_ratio)

func _refresh_tile_visual(key: String) -> void:
	if not grid.has(key):
		return
	var tile: Dictionary = grid[key]
	var tile_color: Color = _compute_tile_color(tile)
	_hex_base_colors[key] = tile_color
	if _hex_nodes.has(key):
		var poly: Polygon2D = _hex_nodes[key]
		poly.color = tile_color

func has_resource_at_cell(cell: Vector2i) -> bool:
	var key := HexGrid.get_cell_key(int(cell.x), int(cell.y))
	if not grid.has(key):
		return false
	return int(grid[key].get("resource_max_amount", 0)) > 0

func get_resource_amount_at_cell(cell: Vector2i) -> int:
	var key := HexGrid.get_cell_key(int(cell.x), int(cell.y))
	if not grid.has(key):
		return 0
	return int(grid[key].get("resource_amount", 0))

## Returns {} for non-resource cells, otherwise { resource_type, amount, max_amount }.
func get_resource_info_at_cell(cell: Vector2i) -> Dictionary:
	var key := HexGrid.get_cell_key(int(cell.x), int(cell.y))
	if not grid.has(key):
		return {}
	var tile: Dictionary = grid[key]
	var max_amount: int = int(tile.get("resource_max_amount", 0))
	if max_amount <= 0:
		return {}
	return {
		resource_type = str(tile.get("resource_type", "")),
		amount = clampi(int(tile.get("resource_amount", 0)), 0, max_amount),
		max_amount = max_amount
	}

func deplete_resource_at(q: int, r: int, amount: int = 1, reason: String = "event") -> int:
	return deplete_resource_at_cell(Vector2i(q, r), amount, reason)

## Depletes a tile's finite resource and updates visuals. Returns amount actually consumed.
func deplete_resource_at_cell(cell: Vector2i, amount: int = 1, reason: String = "event") -> int:
	if amount <= 0:
		return 0
	var key := HexGrid.get_cell_key(int(cell.x), int(cell.y))
	if not grid.has(key):
		return 0
	var tile: Dictionary = grid[key]
	var max_amount: int = int(tile.get("resource_max_amount", 0))
	if max_amount <= 0:
		return 0
	var current_amount: int = clampi(int(tile.get("resource_amount", 0)), 0, max_amount)
	if current_amount <= 0:
		return 0
	var consumed: int = mini(current_amount, amount)
	tile.resource_amount = current_amount - consumed
	grid[key] = tile
	_refresh_tile_visual(key)
	EventBus.tile_resource_changed.emit(int(tile.q), int(tile.r), str(tile.resource_type), int(tile.resource_amount), max_amount, reason)
	if current_amount > 0 and int(tile.resource_amount) <= 0:
		EventBus.tile_resource_depleted.emit(int(tile.q), int(tile.r), str(tile.resource_type), reason)
	return consumed

## Serializes finite tile resources as "q,r" -> { amount, max_amount, resource_type }.
func get_tile_resource_state() -> Dictionary:
	var state: Dictionary = {}
	for key in grid:
		var tile: Dictionary = grid[key]
		var max_amount: int = int(tile.get("resource_max_amount", 0))
		if max_amount <= 0:
			continue
		state[key] = {
			amount = clampi(int(tile.get("resource_amount", 0)), 0, max_amount),
			max_amount = max_amount,
			resource_type = str(tile.get("resource_type", ""))
		}
	return state

## Applies serialized tile resource state (from server/core turn resolution) to current map.
func apply_tile_resource_state(state: Dictionary) -> void:
	if state.is_empty():
		return
	for key in state:
		if not grid.has(key):
			continue
		var tile: Dictionary = grid[key]
		var entry = state[key]
		var amount: int = int(entry) if not (entry is Dictionary) else int(entry.get("amount", tile.get("resource_amount", 0)))
		var max_amount: int = int(tile.get("resource_max_amount", 0))
		if entry is Dictionary and int(entry.get("max_amount", max_amount)) > 0:
			max_amount = int(entry.get("max_amount", max_amount))
		if max_amount <= 0:
			continue
		tile.resource_max_amount = max_amount
		tile.resource_amount = clampi(amount, 0, max_amount)
		if entry is Dictionary:
			var resource_type: String = str(entry.get("resource_type", tile.get("resource_type", "")))
			if not resource_type.is_empty():
				tile.resource_type = resource_type
		grid[key] = tile
		_refresh_tile_visual(key)

func _on_tile_resource_deplete_requested(q: int, r: int, amount: int, reason: String = "event") -> void:
	deplete_resource_at(q, r, amount, reason)

## Fog of war: visible_cell_keys is a Dictionary of "q,r" -> true for hexes visible to player.
## Empty = show entire map (no fog). Call after unit placement or movement.
## Also hides enemy units whose cell is not in visible_cell_keys.
func update_fog(visible_cell_keys: Dictionary) -> void:
	if _hex_nodes.is_empty():
		return
	var no_fog: bool = visible_cell_keys.is_empty()
	for key in _hex_nodes:
		var poly: Polygon2D = _hex_nodes[key]
		var base_color: Color = _hex_base_colors[key] if _hex_base_colors.has(key) else poly.color
		if no_fog or (visible_cell_keys[key] if visible_cell_keys.has(key) else false):
			poly.color = base_color
			poly.visible = true
		else:
			# Dim tile in fog (darken and reduce saturation)
			var dimmed := base_color.darkened(0.55)
			dimmed.s = dimmed.s * 0.4
			poly.color = dimmed
			poly.visible = true
	_update_enemy_visibility(visible_cell_keys)

## Recomputes visible hexes from observer units (e.g. player marines with sight_range=2) and applies fog.
## Call after unit placement or after movement (e.g. end of turn).
func refresh_fog() -> void:
	var visible_keys := _compute_visible_cell_keys()
	update_fog(visible_keys)

func _refresh_fog() -> void:
	refresh_fog()

## Returns Dictionary "q,r" -> true for all hexes visible to any observer unit.
## Observers = current player's group (multiplayer_my_group in multiplayer, else first group).
## Uses each observer unit's def.sight_range and current position; call after placement or movement.
func _compute_visible_cell_keys() -> Dictionary:
	var result: Dictionary = {}
	var units_node = get_parent().get_node_or_null("units")
	if not units_node or not units_node.has_method("get_active_units"):
		return result
	var groups: Array = units_node.groups if "groups" in units_node else []
	if groups.is_empty():
		return result
	# Observer group: in multiplayer use multiplayer_my_group; else first group (player).
	var observer_group: Node = null
	var v = units_node.get("multiplayer_my_group")
	var my_group_name: String = "" if v == null else str(v)
	if not my_group_name.is_empty():
		for g in groups:
			if str(g.name) == my_group_name:
				observer_group = g
				break
	if observer_group == null:
		observer_group = groups[0]
	for child in observer_group.get_children():
		if not child is Unit:
			continue
		var u: Unit = child
		if not u.is_active or not u.def:
			continue
		var range_limit: int = u.def.sight_range
		if range_limit < 0:
			# Full visibility for this unit type: skip (don't contribute to fog)
			continue
		if range_limit == 0:
			continue
		var cell := u.cell
		var q := int(cell.x)
		var r := int(cell.y)
		var hexes := HexGrid.get_hexes_in_range(q, r, range_limit)
		for h in hexes:
			var key := HexGrid.get_cell_key(h.x, h.y)
			if grid.has(key):
				result[key] = true
	# No observers with sight = no fog (show full map)
	if result.is_empty():
		for k in grid:
			result[k] = true
	return result

## Hides enemy units (non-observer groups) when their cell is not in visible_cell_keys.
## Observer group = multiplayer_my_group in multiplayer, else first group. Dead units always hidden.
func _update_enemy_visibility(visible_cell_keys: Dictionary) -> void:
	var units_node = get_parent().get_node_or_null("units")
	if not units_node or "groups" not in units_node:
		return
	var groups: Array = units_node.groups
	if groups.is_empty():
		return
	var v2 = units_node.get("multiplayer_my_group")
	var my_group_name: String = "" if v2 == null else str(v2)
	var observer_group_name: String = my_group_name if not my_group_name.is_empty() else str(groups[0].name)
	var show_all: bool = visible_cell_keys.is_empty()
	for g in groups:
		if str(g.name) == observer_group_name:
			continue  # don't hide our own units
		var group_node: Node = g
		for child in group_node.get_children():
			if not child is Unit:
				continue
			var u: Unit = child
			if not u.is_active:
				u.visible = false
				continue
			var cell_key := HexGrid.get_cell_key(int(u.cell.x), int(u.cell.y))
			u.visible = show_all or (visible_cell_keys[cell_key] if visible_cell_keys.has(cell_key) else false)
