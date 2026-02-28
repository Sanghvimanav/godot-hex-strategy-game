extends Node
## Scenario registry and selection. Used for quick debug setups and future multiplayer.
## Select a scenario before loading battle; battle reads selected_scenario_id and applies it.

var selected_scenario_id: String = "default"
var available_scenarios: Array[Dictionary] = []

func _ready() -> void:
	_build_scenarios()

func _build_scenarios() -> void:
	available_scenarios.clear()
	# Default: Knight, Scout, Mage vs Zergling (matches current battle.tscn layout)
	available_scenarios.append({
		"id": "default",
		"display_name": "Default (Knight, Scout, Mage vs Zergling)",
		"groups": [
			{
				"name": "player",
				"units": [
					{"def_path": "res://src/unit/definitions/knight.tres", "cell": Vector2i(1, 0)},
					{"def_path": "res://src/unit/definitions/scout.tres", "cell": Vector2i(0, 1)},
					{"def_path": "res://src/unit/definitions/mage.tres", "cell": Vector2i(0, 0)},
				]
			},
		{
			"name": "opponent",
			"ai": true,
			"units": [
				{"def_path": "res://src/unit/definitions/zergling.tres", "cell": Vector2i(-1, 1)},
			]
		},
		]
	})
	# Scout energy debug: just Scout vs Zergling
	available_scenarios.append({
		"id": "scout_debug",
		"display_name": "Scout Debug (Scout vs Zergling)",
		"groups": [
			{"name": "player", "units": [
				{"def_path": "res://src/unit/definitions/scout.tres", "cell": Vector2i(0, 0)},
			]},
			{"name": "opponent", "ai": true, "units": [
				{"def_path": "res://src/unit/definitions/zergling.tres", "cell": Vector2i(-1, 1)},
			]},
		]
	})
	# Zergling vs Zergling
	available_scenarios.append({
		"id": "zerg_vs_zerg",
		"display_name": "Zergling vs Zergling",
		"groups": [
			{"name": "player", "units": [
				{"def_path": "res://src/unit/definitions/zergling.tres", "cell": Vector2i(1, 0)},
			]},
			{"name": "opponent", "ai": true, "units": [
				{"def_path": "res://src/unit/definitions/zergling.tres", "cell": Vector2i(-1, 1)},
			]},
		]
	})
	# Marine debug: Marine vs Zergling (attack_short + AoE)
	available_scenarios.append({
		"id": "marine_debug",
		"display_name": "Marine Debug (Marine vs Zergling)",
		"groups": [
			{"name": "player", "units": [
				{"def_path": "res://src/unit/definitions/marine.tres", "cell": Vector2i(0, 0)},
			]},
			{"name": "opponent", "ai": true, "units": [
				{"def_path": "res://src/unit/definitions/zergling.tres", "cell": Vector2i(-1, 1)},
			]},
		]
	})
	# Baneling debug: Baneling vs Marines (test explode)
	available_scenarios.append({
		"id": "baneling_debug",
		"display_name": "Baneling Debug (Baneling vs 2 Marines)",
		"groups": [
			{"name": "player", "units": [
				{"def_path": "res://src/unit/definitions/baneling.tres", "cell": Vector2i(0, 0)},
			]},
			{"name": "opponent", "ai": true, "units": [
				{"def_path": "res://src/unit/definitions/marine.tres", "cell": Vector2i(-1, 1)},
				{"def_path": "res://src/unit/definitions/marine.tres", "cell": Vector2i(-2, 0)},
			]},
		]
	})
	# Terran with Base: Base + Marine + Scout vs Zerglings (base heals/resupplies adjacent)
	available_scenarios.append({
		"id": "terran_with_base",
		"display_name": "Terran with Base (Base + Marine + Scout vs Zerglings)",
		"groups": [
			{"name": "player", "units": [
				{"def_path": "res://src/unit/definitions/terran_base.tres", "cell": Vector2i(0, 0)},
				{"def_path": "res://src/unit/definitions/marine.tres", "cell": Vector2i(1, 0)},
				{"def_path": "res://src/unit/definitions/scout.tres", "cell": Vector2i(0, 1)},
			]},
			{"name": "opponent", "ai": true, "units": [
				{"def_path": "res://src/unit/definitions/zergling.tres", "cell": Vector2i(-1, 1)},
				{"def_path": "res://src/unit/definitions/zergling.tres", "cell": Vector2i(-2, 0)},
			]},
		]
	})
	# Scout recruit test: gather people from villages, then unlock base scout spawn.
	available_scenarios.append({
		"id": "scout_recruit_test",
		"display_name": "Scout Recruit Test (Village -> Base Spawn)",
		"groups": [
			{"name": "player", "units": [
				{"def_path": "res://src/unit/definitions/terran_base.tres", "cell": Vector2i(0, 0)},
				{"def_path": "res://src/unit/definitions/scout.tres", "cell": Vector2i(1, 0)},
			]},
			{"name": "opponent", "ai": true, "units": [
				{"def_path": "res://src/unit/definitions/zergling.tres", "cell": Vector2i(-4, 4)},
			]},
		],
		"tile_resources": _with_village_resources([
			Vector2i(1, 0),
			Vector2i(2, 0),
			Vector2i(-1, 1),
		], 5),
	})
	# Stun debug: verify stun is shown on the next planning turn and after replay.
	available_scenarios.append({
		"id": "stun_replay_debug",
		"display_name": "Stun Replay Debug (Base vs Viper)",
		"groups": [
			{"name": "player", "units": [
				{"def_path": "res://src/unit/definitions/terran_base.tres", "cell": Vector2i(0, 0)},
			]},
			{"name": "opponent", "ai": true, "units": [
				{"def_path": "res://src/unit/definitions/viper.tres", "cell": Vector2i(2, 0)},
			]},
		]
	})
	# Zerg vs Terran: Base + 2 Marines + Scout vs 5 Zerglings + Baneling (randomized positions)
	available_scenarios.append({
		"id": "zerg_vs_terran",
		"display_name": "Zerg vs Terran",
		"randomize_positions": true,
		"groups": [
			{
				"name": "player",
				"units": [
					{"def_path": "res://src/unit/definitions/terran_base.tres"},
					{"def_path": "res://src/unit/definitions/marine.tres"},
					{"def_path": "res://src/unit/definitions/marine.tres"},
					{"def_path": "res://src/unit/definitions/scout.tres"},
				],
				"cell_pool": [
					Vector2i(0, 0), Vector2i(0, 1), Vector2i(0, 2), Vector2i(0, 3), Vector2i(0, 4), Vector2i(0, 5),
					Vector2i(1, -5), Vector2i(1, -4), Vector2i(1, -3), Vector2i(1, -2), Vector2i(1, -1), Vector2i(1, 0),
					Vector2i(1, 1), Vector2i(1, 2), Vector2i(1, 3), Vector2i(1, 4),
					Vector2i(2, -5), Vector2i(2, -4), Vector2i(2, -3), Vector2i(2, -2), Vector2i(2, -1), Vector2i(2, 0),
					Vector2i(2, 1), Vector2i(2, 2), Vector2i(2, 3),
					Vector2i(3, -5), Vector2i(3, -4), Vector2i(3, -3), Vector2i(3, -2), Vector2i(3, -1), Vector2i(3, 0),
					Vector2i(3, 1), Vector2i(3, 2),
					Vector2i(4, -5), Vector2i(4, -4), Vector2i(4, -3), Vector2i(4, -2), Vector2i(4, -1), Vector2i(4, 0), Vector2i(4, 1),
					Vector2i(5, -5), Vector2i(5, -4), Vector2i(5, -3), Vector2i(5, -2), Vector2i(5, -1), Vector2i(5, 0),
				],
			},
			{
				"name": "opponent",
				"ai": true,
				"units": [
					{"def_path": "res://src/unit/definitions/zergling.tres"},
					{"def_path": "res://src/unit/definitions/zergling.tres"},
					{"def_path": "res://src/unit/definitions/zergling.tres"},
					{"def_path": "res://src/unit/definitions/zergling.tres"},
					{"def_path": "res://src/unit/definitions/zergling.tres"},
					{"def_path": "res://src/unit/definitions/baneling.tres"},
					{"def_path": "res://src/unit/definitions/viper.tres"},
				],
				"cell_pool": [
					Vector2i(-5, 0), Vector2i(-5, 1), Vector2i(-5, 2), Vector2i(-5, 3), Vector2i(-5, 4), Vector2i(-5, 5),
					Vector2i(-4, -1), Vector2i(-4, 0), Vector2i(-4, 1), Vector2i(-4, 2), Vector2i(-4, 3), Vector2i(-4, 4), Vector2i(-4, 5),
					Vector2i(-3, -2), Vector2i(-3, -1), Vector2i(-3, 0), Vector2i(-3, 1), Vector2i(-3, 2), Vector2i(-3, 3), Vector2i(-3, 4), Vector2i(-3, 5),
					Vector2i(-2, -3), Vector2i(-2, -2), Vector2i(-2, -1), Vector2i(-2, 0), Vector2i(-2, 1), Vector2i(-2, 2), Vector2i(-2, 3), Vector2i(-2, 4), Vector2i(-2, 5),
					Vector2i(-1, -4), Vector2i(-1, -3), Vector2i(-1, -2), Vector2i(-1, -1), Vector2i(-1, 0), Vector2i(-1, 1), Vector2i(-1, 2), Vector2i(-1, 3), Vector2i(-1, 4), Vector2i(-1, 5),
					Vector2i(0, -5), Vector2i(0, -4), Vector2i(0, -3), Vector2i(0, -2), Vector2i(0, -1),
				],
			},
		],
		"tile_resources": _with_village_resources([
			Vector2i(-3, 1),
			Vector2i(-1, 2),
			Vector2i(1, -2),
			Vector2i(3, -2),
		], 5),
	})
	# Spawning Pool: Pool + 2 Zerglings vs Marine (test spawn)
	available_scenarios.append({
		"id": "spawning_pool",
		"display_name": "Spawning Pool (Pool + Zerglings vs Marine)",
		"groups": [
			{"name": "player", "units": [
				{"def_path": "res://src/unit/definitions/spawning_pool.tres", "cell": Vector2i(0, 0)},
				{"def_path": "res://src/unit/definitions/zergling.tres", "cell": Vector2i(1, 0)},
			]},
			{"name": "opponent", "ai": true, "units": [
				{"def_path": "res://src/unit/definitions/marine.tres", "cell": Vector2i(-1, 1)},
			]},
		],
	})
	# 1v1 Knight
	available_scenarios.append({
		"id": "knight_1v1",
		"display_name": "1v1 Knight vs Mage",
		"groups": [
			{"name": "player", "units": [
				{"def_path": "res://src/unit/definitions/knight.tres", "cell": Vector2i(1, 0)},
			]},
			{"name": "opponent", "ai": true, "units": [
				{"def_path": "res://src/unit/definitions/mage.tres", "cell": Vector2i(-1, 1)},
			]},
		]
	})

func select_scenario(id: String) -> void:
	selected_scenario_id = id

func get_selected_scenario() -> Dictionary:
	return get_scenario_by_id(selected_scenario_id)

func _default_tile_resources() -> Dictionary:
	return {}

## Returns random village tiles for zerg_vs_terran. Excludes unit cell pools.
func _random_village_tiles_for_zerg_vs_terran() -> Dictionary:
	const HEX_RADIUS := 5
	const NUM_VILLAGES := 5
	const VILLAGE_AMOUNT := 3
	var excluded: Dictionary = {}
	for g in [{
		"cell_pool": [
			Vector2i(0, 0), Vector2i(0, 1), Vector2i(0, 2), Vector2i(0, 3), Vector2i(0, 4), Vector2i(0, 5),
			Vector2i(1, -5), Vector2i(1, -4), Vector2i(1, -3), Vector2i(1, -2), Vector2i(1, -1), Vector2i(1, 0),
			Vector2i(1, 1), Vector2i(1, 2), Vector2i(1, 3), Vector2i(1, 4),
			Vector2i(2, -5), Vector2i(2, -4), Vector2i(2, -3), Vector2i(2, -2), Vector2i(2, -1), Vector2i(2, 0),
			Vector2i(2, 1), Vector2i(2, 2), Vector2i(2, 3),
			Vector2i(3, -5), Vector2i(3, -4), Vector2i(3, -3), Vector2i(3, -2), Vector2i(3, -1), Vector2i(3, 0),
			Vector2i(3, 1), Vector2i(3, 2),
			Vector2i(4, -5), Vector2i(4, -4), Vector2i(4, -3), Vector2i(4, -2), Vector2i(4, -1), Vector2i(4, 0), Vector2i(4, 1),
			Vector2i(5, -5), Vector2i(5, -4), Vector2i(5, -3), Vector2i(5, -2), Vector2i(5, -1), Vector2i(5, 0),
		],
	}, {
		"cell_pool": [
			Vector2i(-5, 0), Vector2i(-5, 1), Vector2i(-5, 2), Vector2i(-5, 3), Vector2i(-5, 4), Vector2i(-5, 5),
			Vector2i(-4, -1), Vector2i(-4, 0), Vector2i(-4, 1), Vector2i(-4, 2), Vector2i(-4, 3), Vector2i(-4, 4), Vector2i(-4, 5),
			Vector2i(-3, -2), Vector2i(-3, -1), Vector2i(-3, 0), Vector2i(-3, 1), Vector2i(-3, 2), Vector2i(-3, 3), Vector2i(-3, 4), Vector2i(-3, 5),
			Vector2i(-2, -3), Vector2i(-2, -2), Vector2i(-2, -1), Vector2i(-2, 0), Vector2i(-2, 1), Vector2i(-2, 2), Vector2i(-2, 3), Vector2i(-2, 4), Vector2i(-2, 5),
			Vector2i(-1, -4), Vector2i(-1, -3), Vector2i(-1, -2), Vector2i(-1, -1), Vector2i(-1, 0), Vector2i(-1, 1), Vector2i(-1, 2), Vector2i(-1, 3), Vector2i(-1, 4), Vector2i(-1, 5),
			Vector2i(0, -5), Vector2i(0, -4), Vector2i(0, -3), Vector2i(0, -2), Vector2i(0, -1),
		],
	}]:
		for c in g.cell_pool:
			excluded[HexGrid.get_cell_key(c.x, c.y)] = true
	var candidates: Array[Vector2i] = []
	for q in range(-HEX_RADIUS, HEX_RADIUS + 1):
		for r in range(-HEX_RADIUS, HEX_RADIUS + 1):
			if HexGrid.hex_distance(0, 0, q, r) > HEX_RADIUS:
				continue
			if excluded.has(HexGrid.get_cell_key(q, r)):
				continue
			candidates.append(Vector2i(q, r))
	if candidates.size() < NUM_VILLAGES:
		return {}
	candidates.shuffle()
	var out: Dictionary = {}
	for i in mini(NUM_VILLAGES, candidates.size()):
		var c: Vector2i = candidates[i]
		out[HexGrid.get_cell_key(c.x, c.y)] = { amount = VILLAGE_AMOUNT, max_amount = VILLAGE_AMOUNT, resource_type = "village" }
	return out

func _village_tile_resources(cells: Array, amount_per_village: int = 5) -> Dictionary:
	var villages: Dictionary = {}
	var capped_amount: int = maxi(1, amount_per_village)
	for raw_cell in cells:
		var cell: Vector2i = Vector2i.ZERO
		if raw_cell is Vector2i:
			cell = raw_cell
		elif raw_cell is Vector2:
			cell = Vector2i(int(raw_cell.x), int(raw_cell.y))
		elif raw_cell is Array and raw_cell.size() >= 2:
			cell = Vector2i(int(raw_cell[0]), int(raw_cell[1]))
		var key := HexGrid.get_cell_key(cell.x, cell.y)
		villages[key] = { amount = capped_amount, max_amount = capped_amount, resource_type = "people" }
	return villages

func _merge_tile_resources(base: Dictionary, extra: Dictionary) -> Dictionary:
	var merged: Dictionary = base.duplicate(true)
	for key in extra:
		merged[key] = extra[key]
	return merged

func _with_village_resources(cells: Array, amount_per_village: int = 5) -> Dictionary:
	return _merge_tile_resources(_default_tile_resources(), _village_tile_resources(cells, amount_per_village))

func _with_tile_resources(s: Dictionary) -> Dictionary:
	var decorated: Dictionary = s.duplicate(true)
	if not decorated.has("tile_resources"):
		if decorated.get("id", "") == "zerg_vs_terran":
			decorated["tile_resources"] = _random_village_tiles_for_zerg_vs_terran()
		else:
			decorated["tile_resources"] = _default_tile_resources()
	return decorated

func get_scenario_by_id(id: String) -> Dictionary:
	for s in available_scenarios:
		if s.id == id:
			return _with_tile_resources(s)
	if available_scenarios.size() > 0:
		return _with_tile_resources(available_scenarios[0])
	return {}

## Returns scenarios suitable for multiplayer (2+ groups).
func get_multiplayer_scenarios() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for s in available_scenarios:
		var groups: Array = s.get("groups", [])
		if groups.size() < 2:
			continue
		out.append(_with_tile_resources(s))
	return out
