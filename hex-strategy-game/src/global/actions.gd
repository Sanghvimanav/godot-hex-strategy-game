extends Node
## Central registry of action definitions, similar to server3.js ACTIONS.
## Maps action keys (e.g. 'move_short') to hex grid ActionDefinitions.
## Unit definitions reference action keys; this file generates the concrete paths.
##
## IMPORTANT: get_action_config() and get_action_type() are static. Call them as
##   Actions.get_action_config(key)  or  Actions.get_action_type(key)
## using the global "Actions" autoload (do NOT preload this script and use that as Actions).

## Set to true to print a one-time message when the Actions autoload is ready (helps diagnose class vs instance calls).
const DEBUG_ACTIONS_AUTOLOAD := false

const HexGridType = preload("res://src/global/hex_grid.gd")
const ActionDefinition = preload("res://src/unit/action_definition.gd")

## Action configs: key, type, name, minRange, maxRange, etc.
const ACTION_CONFIGS: Dictionary = {
	"move_short": {
		key = "move_short",
		type = "move",
		name = "Move",
		min_range = 1,
		max_range = 1,
		color = "#0000FF",
		energy_consumption = 0,
	},
	"move_long": {
		key = "move_long",
		type = "move",
		name = "Dash",
		min_range = 2,
		max_range = 2,
		color = "#0000FF",
		energy_consumption = 2,
	},
	"fast_move": {
		key = "fast_move",
		type = "fast move",
		name = "Fast Move",
		min_range = 1,
		max_range = 1,
		color = "#0000FF",
		energy_consumption = 0,
	},
	"slow_move": {
		key = "slow_move",
		type = "slow move",
		name = "Slow Move",
		min_range = 1,
		max_range = 1,
		color = "#0000FF",
		energy_consumption = 0,
	},
	"attack_short": {
		key = "attack_short",
		type = "ability",
		name = "Attack",
		min_range = 1,
		max_range = 1,
		color = "#FF0000",
		energy_consumption = 1,
		area_of_effect = {
			directions = [2],  # Relative direction from attack direction (server3: directions: [2])
			distance = 1,
		},
	},
	"attack_long": {
		key = "attack_long",
		type = "ability",
		name = "Long Attack",
		min_range = 2,
		max_range = 2,
		color = "#FF0000",
		energy_consumption = 2,
	},
	"attack_viper": {
		key = "attack_viper",
		type = "ability",
		name = "Parasitic Bite",
		pattern = "target",
		min_range = 2,
		max_range = 2,
		color = "#9C27B0",
		energy_consumption = 0,
		damage = 1,
		stun_duration = 1,
	},
	"attack_ray": {
		key = "attack_ray",
		type = "ability",
		name = "Shoot",
		pattern = "target",
		min_range = 2,
		max_range = 3,
		color = "#FF0000",
		energy_consumption = 2,
	},
	"attack_area_adjacent": {
		key = "attack_area_adjacent",
		type = "ability",
		name = "Flame Burst",
		pattern = "area_adjacent",
		color = "#FF6600",
		energy_consumption = 2,
	},
	"attack_passive": {
		key = "attack_passive",
		type = "fast ability",
		name = "Passive Attack",
		pattern = "self",
		color = "#FF4444",
		energy_consumption = 0,
	},
	"attack_passive_normal": {
		key = "attack_passive_normal",
		type = "ability",
		name = "Passive Attack (Normal)",
		pattern = "self",
		color = "#FF4444",
		energy_consumption = 0,
	},
	"explode": {
		key = "explode",
		type = "slow ability",
		name = "Explode",
		pattern = "area_adjacent",
		color = "#FF69B4",
		energy_consumption = 0,
		damage = 2,
		self_damage = true,  # Baneling dies when exploding
	},
	"reload": {
		key = "reload",
		type = "slow ability",
		name = "Rest",
		min_range = 0,
		max_range = 0,
		color = "#9C27B0",
		energy_consumption = -1,
	},
	"support_adjacent": {
		key = "support_adjacent",
		type = "ability",
		name = "Resupply",
		pattern = "self",
		color = "#4CAF50",
		energy_consumption = 0,
		heal_amount = 1,
		recharge = 1,
	},
	"heal_adjacent": {
		key = "heal_adjacent",
		type = "ability",
		name = "Heal",
		pattern = "self_or_adjacent",
		color = "#81C784",
		energy_consumption = 1,
		heal_amount = 1,
		recharge = 0,
	},
	"resupply_adjacent": {
		key = "resupply_adjacent",
		type = "ability",
		name = "Resupply",
		pattern = "self_or_adjacent",
		color = "#64B5F6",
		energy_consumption = 1,
		heal_amount = 0,
		recharge = 1,
	},
	"recharge": {
		key = "recharge",
		type = "slow ability",
		name = "Recharge",
		min_range = 0,
		max_range = 0,
		color = "#9C27B0",
		energy_consumption = -1,
	},
	"extract_tile": {
		key = "extract_tile",
		type = "extract",
		name = "Extract",
		pattern = "self",
		min_range = 0,
		max_range = 0,
		color = "#FBC02D",
		energy_consumption = 0,
		tile_resource_depletion = 1,
	},
}

## Processing order: moves, then abilities by speed (fast / normal / slow), then spawn/extract.
const ACTION_ORDER: Array[String] = [
	"fast move", "fast ability", "move", "ability", "slow move", "slow ability",
	"spawn", "extract"
]

func _ready() -> void:
	if DEBUG_ACTIONS_AUTOLOAD:
		print("[Actions] Autoload ready. Use global 'Actions' (autoload) for get_action_config/get_action_type; do not preload this script.")

## Call this from any script to verify how Actions is resolved: Engine.has_singleton("Actions") and tree has /root/Actions.
static func debug_actions_source() -> String:
	return "Use the global autoload 'Actions' (from project.godot). get_action_config() and get_action_type() are static and can be called as Actions.get_action_config(key). Do not use: const Actions = preload(\"res://src/global/actions.gd\")"

static func get_action_config(action_key: String) -> Dictionary:
	return ACTION_CONFIGS.get(action_key, {})

## Returns phase name for pipeline ordering (fast ability, ability, slow ability, move, etc.).
static func get_action_type(action_key: String) -> String:
	return get_action_config(action_key).get("type", "")

## Returns definitions for passive actions (attack types only).
func get_passive_definitions_for_action(action_key: String) -> Array[ActionDefinition]:
	var config = ACTION_CONFIGS.get(action_key)
	if config == null:
		push_warning("Unknown action key: %s" % action_key)
		return []
	var atype: String = config.get("type", "")
	if atype in ["fast ability", "ability", "slow ability"]:
		return get_ability_definitions_for_action(action_key)
	push_warning("Action %s is not a passive ability type: %s" % [action_key, atype])
	return []

## Returns ActionDefinition resources for move actions (used for movement phase).
## Rest/recharge (slow ability) are also offered via move_action_keys and return self-target definitions here.
func get_move_definitions_for_action(action_key: String) -> Array[ActionDefinition]:
	var config = ACTION_CONFIGS.get(action_key)
	if config == null:
		push_warning("Unknown action key: %s" % action_key)
		return []
	var atype: String = config.get("type", "")
	if action_key in ["reload", "recharge"]:
		var result: Array[ActionDefinition] = _build_self_definitions(config.get("name", "Rest"))
		for ad in result:
			ad.action_key = action_key
		return result
	if atype != "move" and atype != "fast move" and atype != "slow move":
		push_warning("Action %s is not a move type" % action_key)
		return []
	var min_r: int = config.get("min_range", 1)
	var max_r: int = config.get("max_range", 1)
	var result_arr: Array[ActionDefinition] = _build_move_definitions(min_r, max_r, config.get("name", "Move"))
	for ad in result_arr:
		ad.action_key = action_key
	return result_arr

## Returns ActionDefinition resources for ability actions (attack, support, rest).
func get_ability_definitions_for_action(action_key: String) -> Array[ActionDefinition]:
	var config = ACTION_CONFIGS.get(action_key)
	if config == null:
		push_warning("Unknown action key: %s" % action_key)
		return []
	var atype: String = config.get("type", "")
	if action_key in ["reload", "recharge"]:
		var result: Array[ActionDefinition] = _build_self_definitions(config.get("name", "Rest"))
		for ad in result:
			ad.action_key = action_key
		return result
	if action_key in ["heal_adjacent", "support_adjacent", "resupply_adjacent"]:
		var pattern: String = config.get("pattern", "self")
		var result: Array[ActionDefinition] = []
		if pattern == "self_or_adjacent":
			result = _build_self_or_adjacent_definitions(config.get("name", "Support"))
		else:
			result = _build_self_definitions(config.get("name", "Resupply"))
		for ad in result:
			ad.action_key = action_key
		return result
	if atype == "extract":
		var extract_defs: Array[ActionDefinition] = _build_self_definitions(config.get("name", "Extract"))
		for ad in extract_defs:
			ad.action_key = action_key
		return extract_defs
	if atype not in ["fast ability", "ability", "slow ability"]:
		push_warning("Action %s is not an ability type (got %s)" % [action_key, atype])
		return []
	var result: Array[ActionDefinition] = []
	if config.get("pattern", "") == "area_adjacent":
		result = _build_area_adjacent_definitions(config.get("name", "Attack"))
	elif config.get("pattern", "") == "self":
		result = _build_self_definitions(config.get("name", "Attack"))
	elif config.get("pattern", "") == "ray":
		var min_r: int = config.get("min_range", 1)
		var max_r: int = config.get("max_range", 1)
		result = _build_ray_ability_definitions(min_r, max_r, config.get("name", "Attack"))
	else:
		var min_r: int = config.get("min_range", 1)
		var max_r: int = config.get("max_range", 1)
		result = _build_ability_definitions(min_r, max_r, config.get("name", "Attack"))
	for ad in result:
		ad.action_key = action_key
	return result

func _build_move_definitions(min_range: int, max_range: int, display_name: String = "") -> Array[ActionDefinition]:
	var result: Array[ActionDefinition] = []
	for dist in range(min_range, max_range + 1):
		var hexes := HexGridType.get_hexes_at_distance(0, 0, dist)
		for hex in hexes:
			var path: Array = HexGridType.build_path_to(0, 0, hex.x, hex.y)
			if path.is_empty():
				continue
			var ad := ActionDefinition.new()
			ad.display_name = display_name
			ad.path = path.slice(0, path.size() - 1)
			ad.end_point = path[path.size() - 1]
			result.append(ad)
	return result

func _build_ability_definitions(min_range: int, max_range: int, display_name: String = "") -> Array[ActionDefinition]:
	var result: Array[ActionDefinition] = []
	for dist in range(min_range, max_range + 1):
		var hexes := HexGridType.get_hexes_at_distance(0, 0, dist)
		for hex in hexes:
			var path: Array = HexGridType.build_path_to(0, 0, hex.x, hex.y)
			if path.is_empty():
				continue
			var ad := ActionDefinition.new()
			ad.display_name = display_name
			ad.path = path.slice(0, path.size() - 1)
			ad.end_point = path[path.size() - 1]
			result.append(ad)
	return result

## Ray attack: 6 definitions, one per axial direction. Path extends radially from origin.
func _build_ray_ability_definitions(min_range: int, max_range: int, display_name: String = "") -> Array[ActionDefinition]:
	var result: Array[ActionDefinition] = []
	for d in HexGridType.AXIAL_DIRECTIONS:
		var path: Array[Vector2] = []
		for step in range(1, max_range):
			path.append(Vector2(d.x * step, d.y * step))
		var ad := ActionDefinition.new()
		ad.display_name = display_name
		ad.path = path
		ad.end_point = Vector2(d.x * max_range, d.y * max_range)
		result.append(ad)
	return result

## Self-target: hits only the unit's own cell (the tile it ends on).
func _build_self_definitions(display_name: String = "") -> Array[ActionDefinition]:
	var ad := ActionDefinition.new()
	ad.display_name = display_name
	ad.path = []
	ad.end_point = Vector2(0, 0)
	return [ad]

## Area attack hitting all 6 adjacent hexes. end_point = (0,0) so target is self (click mage to activate).
func _build_area_adjacent_definitions(display_name: String = "") -> Array[ActionDefinition]:
	var ad := ActionDefinition.new()
	ad.display_name = display_name
	ad.path = []
	for d in HexGridType.AXIAL_DIRECTIONS:
		ad.path.append(Vector2(d.x, d.y))
	ad.end_point = Vector2(0, 0)  # Target is self - player clicks mage to activate
	return [ad]

## Support (heal/resupply): target is self (all adjacent) or one adjacent cell. 7 options total.
func _build_self_or_adjacent_definitions(display_name: String = "") -> Array[ActionDefinition]:
	var result: Array[ActionDefinition] = []
	var self_ad := ActionDefinition.new()
	self_ad.display_name = display_name
	self_ad.path = []
	self_ad.end_point = Vector2(0, 0)
	result.append(self_ad)
	for d in HexGridType.AXIAL_DIRECTIONS:
		var ad := ActionDefinition.new()
		ad.display_name = display_name
		ad.path = []
		ad.end_point = Vector2(d.x, d.y)
		result.append(ad)
	return result
