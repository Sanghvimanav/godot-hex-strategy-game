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
	# Scout energy debug: Scout vs Marine at Shoot range (distance 2)
	available_scenarios.append({
		"id": "scout_debug",
		"display_name": "Scout Debug (Scout vs Marine)",
		"groups": [
			{"name": "player", "units": [
				{"def_path": "res://src/unit/definitions/scout.tres", "cell": Vector2i(0, 0)},
			]},
			{"name": "opponent", "ai": true, "units": [
				{"def_path": "res://src/unit/definitions/marine.tres", "cell": Vector2i(2, 0)},
			]},
		]
	})
	# Resupply + shoot debug: base is off-origin to catch absolute-target support bugs.
	available_scenarios.append({
		"id": "resupply_shoot_debug",
		"display_name": "Resupply Shoot Debug (Base+Scout off-origin)",
		"groups": [
			{"name": "player", "units": [
				{"def_path": "res://src/unit/definitions/terran_base.tres", "cell": Vector2i(2, 1), "energy": 5},
				{"def_path": "res://src/unit/definitions/scout.tres", "cell": Vector2i(3, 1)},
			]},
			{"name": "opponent", "ai": true, "units": [
				{"def_path": "res://src/unit/definitions/marine.tres", "cell": Vector2i(5, 1)},
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
	# Medic heal debug: one-turn GUI check where Marine is attacked and healed in the same turn.
	available_scenarios.append({
		"id": "medic_heal_debug",
		"display_name": "Medic Heal Debug (Heal + Incoming Damage)",
		"groups": [
			{"name": "player", "units": [
				{"def_path": "res://src/unit/definitions/medic.tres", "cell": Vector2i(0, 0), "energy": 4},
				{"def_path": "res://src/unit/definitions/marine.tres", "cell": Vector2i(1, 0), "health": 3, "energy": 4},
			]},
			{"name": "opponent", "ai": true, "units": [
				# Placed at distance 2 from the Marine so AI Hydralisk can damage Marine this turn.
				{"def_path": "res://src/unit/definitions/hydralisk.tres", "cell": Vector2i(-1, 1)},
			]},
		]
	})
	# Excavator debug: Excavator on crystal tile to test mine + resupply
	available_scenarios.append({
		"id": "excavator_debug",
		"display_name": "Excavator Debug (Mine + Resupply)",
		"groups": [
			{"name": "player", "units": [
				{"def_path": "res://src/unit/definitions/excavator.tres", "cell": Vector2i(0, 0), "energy": 3},
				{"def_path": "res://src/unit/definitions/scout.tres", "cell": Vector2i(1, 0), "energy": 1},
			]},
			{"name": "opponent", "ai": true, "units": [
				{"def_path": "res://src/unit/definitions/zergling.tres", "cell": Vector2i(-3, 2)},
			]},
		],
		"tile_resources": _crystal_tile_resources([Vector2i(0, 0)], 2),
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
	# Shardling debug: mine crystals, rest, evolve to Baneling (3 people, 1 crystal) or Hydralisk (2 people, 2 crystals)
	available_scenarios.append({
		"id": "shardling_debug",
		"display_name": "Shardling Debug (Mine + Evolve)",
		"groups": [
			{"name": "player", "resources": {"crystal": 5, "people": 5}, "units": [
				{"def_path": "res://src/unit/definitions/shardling.tres", "cell": Vector2i(0, 0)},
			]},
			{"name": "opponent", "ai": true, "units": [
				{"def_path": "res://src/unit/definitions/zergling.tres", "cell": Vector2i(-3, 2)},
			]},
		],
		"tile_resources": _crystal_tile_resources([Vector2i(0, 0)], 5),
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
	# Scout recruit test: gather crystals + people, then unlock base scout spawn (3 people) or infantry camp (5 crystals).
	available_scenarios.append({
		"id": "scout_recruit_test",
		"display_name": "Scout Recruit Test (Crystal + Village -> Base Spawn)",
		"groups": [
			{"name": "player", "resources": {"crystal": 0, "people": 0}, "units": [
				{"def_path": "res://src/unit/definitions/terran_base.tres", "cell": Vector2i(0, 0)},
				{"def_path": "res://src/unit/definitions/scout.tres", "cell": Vector2i(1, 0)},
				{"def_path": "res://src/unit/definitions/excavator.tres", "cell": Vector2i(-1, 0)},
			]},
			{"name": "opponent", "ai": true, "units": [
				{"def_path": "res://src/unit/definitions/zergling.tres", "cell": Vector2i(-4, 4)},
			]},
		],
		"tile_resources": _merge_tile_resources(
			_crystal_tile_resources([Vector2i(-1, 0), Vector2i(2, 0)], 5),
			_village_tile_resources([Vector2i(1, 0), Vector2i(-1, 1)], 10),
		),
	})
	# Stun debug: verify stun is shown on the next planning turn and after replay.
	available_scenarios.append({
		"id": "stun_replay_debug",
		"display_name": "Stun Replay Debug (Base vs Hydralisk)",
		"groups": [
			{"name": "player", "units": [
				{"def_path": "res://src/unit/definitions/terran_base.tres", "cell": Vector2i(0, 0)},
			]},
			{"name": "opponent", "ai": true, "units": [
				{"def_path": "res://src/unit/definitions/hydralisk.tres", "cell": Vector2i(2, 0)},
			]},
		]
	})
	# Zerg vs Terran v2: Terran Base + Marine + Scout + Excavator vs Zergling + Spawning Pool at opposite ends
	available_scenarios.append({
		"id": "zerg_vs_terran_v2",
		"display_name": "Zerg vs Terran v2",
		"groups": [
			{"name": "player", "resources": {"crystal": 0, "people": 0}, "units": [
				{"def_path": "res://src/unit/definitions/terran_base.tres", "cell": Vector2i(4, 0)},
				{"def_path": "res://src/unit/definitions/marine.tres", "cell": Vector2i(3, 0)},
				{"def_path": "res://src/unit/definitions/scout.tres", "cell": Vector2i(4, 1)},
				{"def_path": "res://src/unit/definitions/excavator.tres", "cell": Vector2i(3, 1)},
			]},
			{"name": "opponent", "ai": true, "resources": {"people": 0}, "units": [
				{"def_path": "res://src/unit/definitions/zergling.tres", "cell": Vector2i(-4, 1)},
				{"def_path": "res://src/unit/definitions/fester.tres", "cell": Vector2i(-3, 1)},
			]},
		],
		"tile_resources": _merge_tile_resources(
			_crystal_tile_resources([
				Vector2i(3, 0), Vector2i(-3, 0), Vector2i(0, 3), Vector2i(0, -3),
				Vector2i(2, -2), Vector2i(-2, 2),
			], 20),
			_village_tile_resources([
				Vector2i(2, 2), Vector2i(-2, -2), Vector2i(3, -1), Vector2i(-3, 1),
			], 10),
		),
	})
	# Zerg vs Terran: Base + 2 Marines + Scout + Medic vs 5 Zerglings + Baneling + Hydralisk (randomized positions)
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
					{"def_path": "res://src/unit/definitions/medic.tres"},
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
					{"def_path": "res://src/unit/definitions/hydralisk.tres"},
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
		], 10),
	})
	# Fester debug: Fester on village to test consume (2→1 people, +1 heal) and spawn zergling (3 people, 3 HP)
	available_scenarios.append({
		"id": "fester_debug",
		"display_name": "Fester Debug (Consume + Spawn Zergling)",
		"groups": [
			{"name": "player", "resources": {"people": 0}, "units": [
				{"def_path": "res://src/unit/definitions/fester.tres", "cell": Vector2i(0, 0), "health": 6},
			]},
			{"name": "opponent", "ai": true, "units": [
				{"def_path": "res://src/unit/definitions/marine.tres", "cell": Vector2i(-3, 2)},
			]},
		],
		"tile_resources": _village_tile_resources([Vector2i(0, 0)], 10),
	})

func select_scenario(id: String) -> void:
	selected_scenario_id = id

## Returns true if scenario is a debug/test scenario (for UI grouping).
func is_debug_scenario(s: Dictionary) -> bool:
	var id: String = str(s.get("id", ""))
	return "_debug" in id or "_test" in id

## Returns main scenarios (non-debug) and debug scenarios as separate arrays.
func get_scenarios_by_category() -> Dictionary:
	var main: Array[Dictionary] = []
	var debug: Array[Dictionary] = []
	for s in available_scenarios:
		if is_debug_scenario(s):
			debug.append(s)
		else:
			main.append(s)
	return {"main": main, "debug": debug}

func get_selected_scenario() -> Dictionary:
	return get_scenario_by_id(selected_scenario_id)

func _default_tile_resources() -> Dictionary:
	return {}

## Returns random village tiles for zerg_vs_terran. Excludes unit cell pools. Map is radius 6 for this scenario.
func _random_village_tiles_for_zerg_vs_terran() -> Dictionary:
	const HEX_RADIUS := 6
	const NUM_VILLAGES := 5
	const VILLAGE_AMOUNT := 10
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

func _crystal_tile_resources(cells: Array, amount_per_tile: int = 20) -> Dictionary:
	var crystal: Dictionary = {}
	var capped_amount: int = maxi(1, amount_per_tile)
	var crystal_color: Color = Color(0.25, 0.45, 1.0)
	for raw_cell in cells:
		var cell: Vector2i = Vector2i.ZERO
		if raw_cell is Vector2i:
			cell = raw_cell
		elif raw_cell is Vector2:
			cell = Vector2i(int(raw_cell.x), int(raw_cell.y))
		elif raw_cell is Array and raw_cell.size() >= 2:
			cell = Vector2i(int(raw_cell[0]), int(raw_cell[1]))
		var key := HexGrid.get_cell_key(cell.x, cell.y)
		crystal[key] = { amount = capped_amount, max_amount = capped_amount, resource_type = "crystal", resource_color = crystal_color }
	return crystal

func _village_tile_resources(cells: Array, amount_per_village: int = 10) -> Dictionary:
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

func _with_village_resources(cells: Array, amount_per_village: int = 10) -> Dictionary:
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
