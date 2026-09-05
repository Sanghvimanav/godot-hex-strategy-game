extends Node
## Scenario registry and selection. Used for quick debug setups and future multiplayer.
## Select a scenario before loading battle; battle reads selected_scenario_id and applies it.
##
## Campaign scenarios (category == "campaign") should set "description" to a short win-condition blurb
## for each side (neutral wording — no assumed human seat) and for LLM/classic AI context.

var selected_scenario_id: String = "default"
var available_scenarios: Array[Dictionary] = []
## For scenarios with supports_campaign_difficulty: easy / medium / hard (default medium).
var campaign_difficulty: String = "medium"
## Which group the human player controls ("" = first non-AI group, the default).
var player_group_name: String = ""

const _ZERGLING_DEF_PATH := "res://src/unit/definitions/zergling.tres"
const _BANELING_DEF_PATH := "res://src/unit/definitions/baneling.tres"

func _ready() -> void:
	_build_scenarios()

func _build_scenarios() -> void:
	available_scenarios.clear()
	# Default: Marine, Scout, Mage vs Zergling (matches current battle.tscn layout)
	available_scenarios.append({
		"id": "default",
		"display_name": "Default (Marine, Scout, Mage vs Zergling)",
		"groups": [
			{
				"name": "terran",
				"units": [
					{"def_path": "res://src/unit/definitions/marine.tres", "cell": Vector2i(1, 0)},
					{"def_path": "res://src/unit/definitions/scout.tres", "cell": Vector2i(0, 1)},
					{"def_path": "res://src/unit/definitions/mage.tres", "cell": Vector2i(0, 0)},
				]
			},
		{
			"name": "zerg",
			"ai": true,
			"units": [
				{"def_path": "res://src/unit/definitions/zergling.tres", "cell": Vector2i(-1, 1)},
			]
		},
		]
	})
	# Campaign 1: Terran scouts vs a zergling stack (count by difficulty) and three mountains on column x = -1.
	available_scenarios.append({
		"id": "campaign_opening",
		"display_name": "Campaign 1 (3 Scouts vs Zerglings + 3 Mountains)",
		"category": "campaign",
		"supports_campaign_difficulty": true,
		"campaign_zergling_stack_cell": Vector2i(-4, 0),
		"campaign_zergling_counts": {"easy": 2, "medium": 3, "hard": 4},
		"description": "Terran side: destroy all three Mountains with Scouts — they sit on column x = -1 as static Zerg holdings (no ranged threat, but they block the objective). Zerg side: protect the Mountains; stop the Scouts from tearing them down while zerglings engage. Standard elimination still ends the match when one side has no units left.",
		"groups": [
			{"name": "terran", "units": [
				{"def_path": "res://src/unit/definitions/scout.tres", "cell": Vector2i(4, 0)},
				{"def_path": "res://src/unit/definitions/scout.tres", "cell": Vector2i(4, 0)},
				{"def_path": "res://src/unit/definitions/scout.tres", "cell": Vector2i(4, 0)},
			]},
			{"name": "zerg", "ai": true, "units": [
				{"def_path": "res://src/unit/definitions/mountain.tres", "cell": Vector2i(-1, -2)},
				{"def_path": "res://src/unit/definitions/mountain.tres", "cell": Vector2i(-1, 0)},
				{"def_path": "res://src/unit/definitions/mountain.tres", "cell": Vector2i(-1, 2)},
			]},
		]
	})
	# Campaign 2: Defend the Infantry Camp with Marines and Scouts against Banelings + Zerglings.
	available_scenarios.append({
		"id": "campaign_baneling_breach",
		"display_name": "Campaign 2 (Defend Infantry Camp vs Banelings)",
		"category": "campaign",
		"supports_campaign_difficulty": true,
		"description": "Terran side: keep the Infantry Camp alive. Marines suit close-range firepower; Scouts suit long-range sniping. Spread units — a single Baneling explosion hits all 6 adjacent hexes for 2 damage and will shred a cluster. Zerg side: rush the Infantry Camp; detonate Banelings into groups of Terran units.",
		"campaign_ai_units_by_difficulty": {
			"easy": [
				{"def_path": _ZERGLING_DEF_PATH, "cell": Vector2i(-4, 0)},
				{"def_path": _ZERGLING_DEF_PATH, "cell": Vector2i(-4, 0)},
				{"def_path": _BANELING_DEF_PATH, "cell": Vector2i(-3, 0)},
			],
			"medium": [
				{"def_path": _ZERGLING_DEF_PATH, "cell": Vector2i(-4, 0)},
				{"def_path": _ZERGLING_DEF_PATH, "cell": Vector2i(-4, 0)},
				{"def_path": _ZERGLING_DEF_PATH, "cell": Vector2i(-4, 0)},
				{"def_path": _BANELING_DEF_PATH, "cell": Vector2i(-3, 0)},
			],
			"hard": [
				{"def_path": _ZERGLING_DEF_PATH, "cell": Vector2i(-4, 0)},
				{"def_path": _ZERGLING_DEF_PATH, "cell": Vector2i(-4, 0)},
				{"def_path": _ZERGLING_DEF_PATH, "cell": Vector2i(-4, 0)},
				{"def_path": _ZERGLING_DEF_PATH, "cell": Vector2i(-4, 0)},
				{"def_path": _BANELING_DEF_PATH, "cell": Vector2i(-3, 0)},
				{"def_path": _BANELING_DEF_PATH, "cell": Vector2i(-3, 0)},
			],
		},
		"groups": [
			{"name": "terran", "units": [
				{"def_path": "res://src/unit/definitions/infantry_camp.tres", "cell": Vector2i(4, 0)},
				{"def_path": "res://src/unit/definitions/marine.tres", "cell": Vector2i(2, 0)},
				{"def_path": "res://src/unit/definitions/marine.tres", "cell": Vector2i(2, 1)},
				{"def_path": "res://src/unit/definitions/scout.tres", "cell": Vector2i(3, -1)},
				{"def_path": "res://src/unit/definitions/scout.tres", "cell": Vector2i(3, 1)},
			]},
			{"name": "zerg", "ai": true, "units": []},
		]
	})
	# Scout debug: Scout vs Marine at Shoot range (distance 2)
	available_scenarios.append({
		"id": "scout_debug",
		"display_name": "Scout Debug (Scout vs Marine)",
		"groups": [
			{"name": "terran", "units": [
				{"def_path": "res://src/unit/definitions/scout.tres", "cell": Vector2i(0, 0)},
			]},
			{"name": "zerg", "ai": true, "units": [
				{"def_path": "res://src/unit/definitions/marine.tres", "cell": Vector2i(2, 0)},
			]},
		]
	})
	# Resupply + shoot debug: base is off-origin to catch absolute-target support bugs.
	available_scenarios.append({
		"id": "resupply_shoot_debug",
		"display_name": "Resupply Shoot Debug (Base+Scout off-origin)",
		"groups": [
			{"name": "terran", "units": [
				{"def_path": "res://src/unit/definitions/terran_base.tres", "cell": Vector2i(2, 1), "energy": 5},
				{"def_path": "res://src/unit/definitions/scout.tres", "cell": Vector2i(3, 1)},
			]},
			{"name": "zerg", "ai": true, "units": [
				{"def_path": "res://src/unit/definitions/marine.tres", "cell": Vector2i(5, 1)},
			]},
		]
	})
	# Zergling vs Zergling
	available_scenarios.append({
		"id": "zerg_vs_zerg",
		"display_name": "Zergling vs Zergling",
		"groups": [
			{"name": "terran", "units": [
				{"def_path": "res://src/unit/definitions/zergling.tres", "cell": Vector2i(1, 0)},
			]},
			{"name": "zerg", "ai": true, "units": [
				{"def_path": "res://src/unit/definitions/zergling.tres", "cell": Vector2i(-1, 1)},
			]},
		]
	})
	# Mountain debug: immobile objective structure (scout in shooting range, one-turn damage check).
	available_scenarios.append({
		"id": "mountain_debug",
		"display_name": "Mountain Debug (Scout vs Mountain at range 2)",
		"groups": [
			{"name": "terran", "units": [
				{"def_path": "res://src/unit/definitions/scout.tres", "cell": Vector2i(0, 0)},
			]},
			{"name": "zerg", "ai": true, "units": [
				{"def_path": "res://src/unit/definitions/mountain.tres", "cell": Vector2i(2, 0)},
			]},
		]
	})
	# Spire debug: immobile tower vs Marine at range 2 (one-turn damage check).
	available_scenarios.append({
		"id": "spire_debug",
		"display_name": "Spire Debug (Spire vs Marine at range 2)",
		"groups": [
			{"name": "terran", "units": [
				{"def_path": "res://src/unit/definitions/spire.tres", "cell": Vector2i(0, 0)},
			]},
			{"name": "zerg", "ai": true, "units": [
				{"def_path": "res://src/unit/definitions/marine.tres", "cell": Vector2i(2, 0)},
			]},
		]
	})
	# Marine debug: Marine vs Zergling (attack_short + AoE)
	available_scenarios.append({
		"id": "marine_debug",
		"display_name": "Marine Debug (Marine vs Zergling)",
		"groups": [
			{"name": "terran", "units": [
				{"def_path": "res://src/unit/definitions/marine.tres", "cell": Vector2i(0, 0)},
			]},
			{"name": "zerg", "ai": true, "units": [
				{"def_path": "res://src/unit/definitions/zergling.tres", "cell": Vector2i(-1, 1)},
			]},
		]
	})
	# Medic heal debug: one-turn GUI check where Marine is attacked and healed in the same turn.
	available_scenarios.append({
		"id": "medic_heal_debug",
		"display_name": "Medic Heal Debug (Heal + Incoming Damage)",
		"groups": [
			{"name": "terran", "units": [
				{"def_path": "res://src/unit/definitions/medic.tres", "cell": Vector2i(0, 0), "energy": 4},
				{"def_path": "res://src/unit/definitions/marine.tres", "cell": Vector2i(1, 0), "health": 3},
			]},
			{"name": "zerg", "ai": true, "units": [
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
			{"name": "terran", "units": [
				{"def_path": "res://src/unit/definitions/excavator.tres", "cell": Vector2i(0, 0), "energy": 3},
				{"def_path": "res://src/unit/definitions/scout.tres", "cell": Vector2i(1, 0)},
			]},
			{"name": "zerg", "ai": true, "units": [
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
			{"name": "terran", "units": [
				{"def_path": "res://src/unit/definitions/baneling.tres", "cell": Vector2i(0, 0)},
			]},
			{"name": "zerg", "ai": true, "units": [
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
			{"name": "terran", "resources": {"crystal": 5, "people": 5}, "units": [
				{"def_path": "res://src/unit/definitions/shardling.tres", "cell": Vector2i(0, 0)},
			]},
			{"name": "zerg", "ai": true, "units": [
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
			{"name": "terran", "units": [
				{"def_path": "res://src/unit/definitions/terran_base.tres", "cell": Vector2i(0, 0)},
				{"def_path": "res://src/unit/definitions/marine.tres", "cell": Vector2i(1, 0)},
				{"def_path": "res://src/unit/definitions/scout.tres", "cell": Vector2i(0, 1)},
			]},
			{"name": "zerg", "ai": true, "units": [
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
			{"name": "terran", "resources": {"crystal": 0, "people": 0}, "units": [
				{"def_path": "res://src/unit/definitions/terran_base.tres", "cell": Vector2i(0, 0)},
				{"def_path": "res://src/unit/definitions/scout.tres", "cell": Vector2i(1, 0)},
				{"def_path": "res://src/unit/definitions/excavator.tres", "cell": Vector2i(-1, 0)},
			]},
			{"name": "zerg", "ai": true, "units": [
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
			{"name": "terran", "units": [
				{"def_path": "res://src/unit/definitions/terran_base.tres", "cell": Vector2i(0, 0)},
			]},
			{"name": "zerg", "ai": true, "units": [
				{"def_path": "res://src/unit/definitions/hydralisk.tres", "cell": Vector2i(2, 0)},
			]},
		]
	})
	# Zerg vs Terran v2: Terran Base + Marine + Scout + Excavator vs Zergling + Spawning Pool at opposite ends
	available_scenarios.append({
		"id": "zerg_vs_terran_v2",
		"display_name": "Zerg vs Terran v2",
		"groups": [
			{"name": "terran", "resources": {"crystal": 0, "people": 0}, "units": [
				{"def_path": "res://src/unit/definitions/terran_base.tres", "cell": Vector2i(4, 0)},
				{"def_path": "res://src/unit/definitions/marine.tres", "cell": Vector2i(3, 0)},
				{"def_path": "res://src/unit/definitions/scout.tres", "cell": Vector2i(4, 1)},
				{"def_path": "res://src/unit/definitions/excavator.tres", "cell": Vector2i(3, 1)},
			]},
			{"name": "zerg", "ai": true, "resources": {"people": 0}, "units": [
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
				"name": "terran",
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
				"name": "zerg",
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
			{"name": "terran", "resources": {"people": 0}, "units": [
				{"def_path": "res://src/unit/definitions/fester.tres", "cell": Vector2i(0, 0), "health": 6},
			]},
			{"name": "zerg", "ai": true, "units": [
				{"def_path": "res://src/unit/definitions/marine.tres", "cell": Vector2i(-3, 2)},
			]},
		],
		"tile_resources": _village_tile_resources([Vector2i(0, 0)], 10),
	})

	# --- AI Training Drills ---
	# Eval 1: phase/timing fast-move contact check (AI = Zerg).
	available_scenarios.append({
		"id": "eval_phase_fastmove_contact_zergling_vs_scout",
		"display_name": "Eval: Fast Move Contact (Zergling vs Scout)",
		"category": "drill",
		"description": "AI controls a Zergling at [1,0] vs a Scout at [0,0]. Goal: fast-move onto [0,0] to damage Scout and stay inside Scout minimum range.",
		"groups": [
			{"name": "terran", "units": [
				{"def_path": "res://src/unit/definitions/scout.tres", "cell": Vector2i(0, 0)},
			]},
			{"name": "zerg", "ai": true, "units": [
				{"def_path": _ZERGLING_DEF_PATH, "cell": Vector2i(1, 0)},
			]},
		]
	})
	# Eval 2: same as Eval 1 but zergling starts on a different adjacent hex to
	# validate axial-coordinate handling (-1,1 is adjacent to 0,0).
	available_scenarios.append({
		"id": "eval_phase_fastmove_contact_zergling_vs_scout_neg11",
		"display_name": "Eval: Fast Move Contact (Zergling -1,1 vs Scout)",
		"category": "drill",
		"description": "AI controls a Zergling at [-1,1] vs a Scout at [0,0]. Goal: fast-move onto [0,0] to damage Scout and stay inside Scout minimum range.",
		"groups": [
			{"name": "terran", "units": [
				{"def_path": "res://src/unit/definitions/scout.tres", "cell": Vector2i(0, 0)},
			]},
			{"name": "zerg", "ai": true, "units": [
				{"def_path": _ZERGLING_DEF_PATH, "cell": Vector2i(-1, 1)},
			]},
		]
	})
	# Eval 2b: same as Eval 1 but zergling starts at 1 HP to validate commit
	# behavior under immediate survival pressure.
	available_scenarios.append({
		"id": "eval_phase_fastmove_contact_zergling_vs_scout_hp1",
		"display_name": "Eval: Fast Move Contact (Zergling HP 1)",
		"category": "drill",
		"description": "AI controls a 1-HP Zergling at [1,0] vs a Scout at [0,0]. Goal: fast-move onto [0,0] to damage Scout and deny further scout shots.",
		"groups": [
			{"name": "terran", "units": [
				{"def_path": "res://src/unit/definitions/scout.tres", "cell": Vector2i(0, 0)},
			]},
			{"name": "zerg", "ai": true, "units": [
				{"def_path": _ZERGLING_DEF_PATH, "cell": Vector2i(1, 0), "health": 1},
			]},
		]
	})
	# Eval 2c: same contact pattern but one hex farther, with zergling at 2 HP.
	# The correct first step is to fast-move from [2,0] to [1,0].
	available_scenarios.append({
		"id": "eval_phase_fastmove_stepin_zergling_vs_scout_hp2",
		"display_name": "Eval: Fast Move Step-In (Zergling HP 2)",
		"category": "drill",
		"description": "AI controls a 2-HP Zergling at [2,0] vs a Scout at [0,0]. Goal: fast-move to [1,0] to preserve contact tempo.",
		"groups": [
			{"name": "terran", "units": [
				{"def_path": "res://src/unit/definitions/scout.tres", "cell": Vector2i(0, 0)},
			]},
			{"name": "zerg", "ai": true, "units": [
				{"def_path": _ZERGLING_DEF_PATH, "cell": Vector2i(2, 0), "health": 2},
			]},
		]
	})
	# Eval 3: same tactical check far from origin to validate axial coordinate
	# handling away from center.
	available_scenarios.append({
		"id": "eval_phase_fastmove_contact_zergling_vs_scout_far",
		"display_name": "Eval: Fast Move Contact (Far Coordinates)",
		"category": "drill",
		"description": "AI controls a Zergling at [4,-2] vs a Scout at [3,-2]. Goal: fast-move onto [3,-2] to damage Scout and stay inside Scout minimum range.",
		"groups": [
			{"name": "terran", "units": [
				{"def_path": "res://src/unit/definitions/scout.tres", "cell": Vector2i(3, -2)},
			]},
			{"name": "zerg", "ai": true, "units": [
				{"def_path": _ZERGLING_DEF_PATH, "cell": Vector2i(4, -2)},
			]},
		]
	})
	# Eval 4: multi-unit phase/timing check. Four Zerglings should collapse onto one
	# Marine tile immediately. Zergling passive is fast ability; Marine passive is
	# normal ability, so Marine should be removed before its passive can resolve.
	available_scenarios.append({
		"id": "eval_phase_4zerglings_focus_marine",
		"display_name": "Eval: 4 Zerglings Focus Marine",
		"category": "drill",
		"description": "AI controls 4 Zerglings stacked at [0,1] vs one Marine at [-1,2]. Goal: all Zerglings fast-move onto [-1,2].",
		"groups": [
			{"name": "terran", "units": [
				{"def_path": "res://src/unit/definitions/marine.tres", "cell": Vector2i(-1, 2)},
			]},
			{"name": "zerg", "ai": true, "units": [
				{"def_path": _ZERGLING_DEF_PATH, "cell": Vector2i(0, 1)},
				{"def_path": _ZERGLING_DEF_PATH, "cell": Vector2i(0, 1)},
				{"def_path": _ZERGLING_DEF_PATH, "cell": Vector2i(0, 1)},
				{"def_path": _ZERGLING_DEF_PATH, "cell": Vector2i(0, 1)},
			]},
		]
	})
	# Eval 5: prediction shot test. Terran AI has 3 Scouts stacked on [0,0] and
	# Zergling starts on [2,0]. Expected predictive fire tile is [1,0].
	available_scenarios.append({
		"id": "eval_prediction_3scouts_vs_zergling_shoot_10",
		"display_name": "Eval: 3 Scouts Predictive Shot [1,0]",
		"category": "drill",
		"description": "AI controls 3 Scouts at [0,0] vs one Zergling at [2,0]. Expected predictive attack target is [1,0].",
		"drill": {
			"scripted_groups": {"zerg": "advance_straight"},
		},
		"groups": [
			{"name": "terran", "ai": true, "units": [
				{"def_path": "res://src/unit/definitions/scout.tres", "cell": Vector2i(0, 0)},
				{"def_path": "res://src/unit/definitions/scout.tres", "cell": Vector2i(0, 0)},
				{"def_path": "res://src/unit/definitions/scout.tres", "cell": Vector2i(0, 0)},
			]},
			{"name": "zerg", "units": [
				{"def_path": _ZERGLING_DEF_PATH, "cell": Vector2i(2, 0)},
			]},
		]
	})
	# Eval 6: zergling close-in under uncertain scout targeting. Scout at [0,0] can
	# damage one-step-closer tiles; zergling should still commit to a valid landing
	# hex that pressures the scout.
	available_scenarios.append({
		"id": "eval_zergling_commit_two_landing_hexes",
		"display_name": "Eval: Zergling Commit (Two Landing Hexes)",
		"category": "drill",
		"description": "AI controls a Zergling at [-1,2] vs a Scout at [0,0]. Scout fires one-step-closer; valid zergling commitments are [-1,1] or [0,1].",
		"drill": {
			"scripted_groups": {"terran": "fire_one_closer"},
		},
		"groups": [
			{"name": "terran", "units": [
				{"def_path": "res://src/unit/definitions/scout.tres", "cell": Vector2i(0, 0)},
			]},
			{"name": "zerg", "ai": true, "units": [
				{"def_path": _ZERGLING_DEF_PATH, "cell": Vector2i(-1, 2)},
			]},
		]
	})
	# Eval 7: target prioritization with mixed enemies. Scout should shoot moving
	# zergling threat at [3,-3] instead of mountain.
	available_scenarios.append({
		"id": "eval_scout_prioritize_zergling_over_mountain",
		"display_name": "Eval: Scout Prioritize Zergling Over Mountain",
		"category": "drill",
		"description": "AI controls a Scout at [1,-3]. Enemy Mountain at [2,-2] rests; Zergling at [4,-3] advances to [3,-3]. Scout should attack [3,-3].",
		"drill": {
			"scripted_groups": {"zerg": "advance_straight"},
		},
		"groups": [
			{"name": "terran", "ai": true, "units": [
				{"def_path": "res://src/unit/definitions/scout.tres", "cell": Vector2i(1, -3)},
			]},
			{"name": "zerg", "units": [
				{"def_path": "res://src/unit/definitions/mountain.tres", "cell": Vector2i(2, -2)},
				{"def_path": _ZERGLING_DEF_PATH, "cell": Vector2i(4, -3)},
			]},
		]
	})
	# Eval 8A: marine AOE branch check where zergling deterministically moves to
	# [-1,-1]. Marine should attack [-1,-1].
	available_scenarios.append({
		"id": "eval_marine_aoe_branch_zerg_to_neg11",
		"display_name": "Eval: Marine AOE Branch (Zerg -> [-1,-1])",
		"category": "drill",
		"description": "AI controls a Marine at [-2,-1]. Scripted Zergling at [0,-2] moves to [-1,-1]. Marine should attack [-1,-1] to damage via AOE.",
		"drill": {
			"scripted_groups": {"zerg": "move_to_neg11"},
		},
		"groups": [
			{"name": "terran", "ai": true, "units": [
				{"def_path": "res://src/unit/definitions/marine.tres", "cell": Vector2i(-2, -1)},
			]},
			{"name": "zerg", "units": [
				{"def_path": _ZERGLING_DEF_PATH, "cell": Vector2i(0, -2)},
			]},
		]
	})
	# Eval 8B: marine AOE branch check where zergling deterministically moves to
	# [-1,-2]. Marine should still attack [-1,-1] to damage via AOE.
	available_scenarios.append({
		"id": "eval_marine_aoe_branch_zerg_to_neg1neg2",
		"display_name": "Eval: Marine AOE Branch (Zerg -> [-1,-2])",
		"category": "drill",
		"description": "AI controls a Marine at [-2,-1]. Scripted Zergling at [0,-2] moves to [-1,-2]. Marine should attack [-1,-1] to damage via AOE.",
		"drill": {
			"scripted_groups": {"zerg": "move_to_neg1neg2"},
		},
		"groups": [
			{"name": "terran", "ai": true, "units": [
				{"def_path": "res://src/unit/definitions/marine.tres", "cell": Vector2i(-2, -1)},
			]},
			{"name": "zerg", "units": [
				{"def_path": _ZERGLING_DEF_PATH, "cell": Vector2i(0, -2)},
			]},
		]
	})
	# Eval 9: retreat timing check. A single Zergling should retreat out of Marine
	# threat range while stacked Marines target the old tile.
	available_scenarios.append({
		"id": "eval_phase_zergling_retreat_vs_3marines",
		"display_name": "Eval: Zergling Retreat vs 3 Marines",
		"category": "drill",
		"description": "AI controls one Zergling at [-3,2] vs three Marines at [-2,1]. Zergling should retreat to [-4,3], [-4,2], or [-3,3] while Marines pressure [-3,2].",
		"groups": [
			{"name": "terran", "units": [
				{"def_path": "res://src/unit/definitions/marine.tres", "cell": Vector2i(-2, 1)},
				{"def_path": "res://src/unit/definitions/marine.tres", "cell": Vector2i(-2, 1)},
				{"def_path": "res://src/unit/definitions/marine.tres", "cell": Vector2i(-2, 1)},
			]},
			{"name": "zerg", "ai": true, "units": [
				{"def_path": _ZERGLING_DEF_PATH, "cell": Vector2i(-3, 2)},
			]},
		]
	})
	# Eval 10: multi-unit timing check. Four Zerglings should collapse onto stacked
	# Marines at [-2,1] to win via fast-phase passive damage ordering.
	available_scenarios.append({
		"id": "eval_phase_4zerglings_collapse_3marines",
		"display_name": "Eval: 4 Zerglings Collapse 3 Marines",
		"category": "drill",
		"description": "AI controls four Zerglings at [-3,2] vs three Marines at [-2,1]. Goal: all Zerglings fast-move onto [-2,1] to kill Marines before Marine normal-phase passive resolves.",
		"groups": [
			{"name": "terran", "units": [
				{"def_path": "res://src/unit/definitions/marine.tres", "cell": Vector2i(-2, 1)},
				{"def_path": "res://src/unit/definitions/marine.tres", "cell": Vector2i(-2, 1)},
				{"def_path": "res://src/unit/definitions/marine.tres", "cell": Vector2i(-2, 1)},
			]},
			{"name": "zerg", "ai": true, "units": [
				{"def_path": _ZERGLING_DEF_PATH, "cell": Vector2i(-3, 2)},
				{"def_path": _ZERGLING_DEF_PATH, "cell": Vector2i(-3, 2)},
				{"def_path": _ZERGLING_DEF_PATH, "cell": Vector2i(-3, 2)},
				{"def_path": _ZERGLING_DEF_PATH, "cell": Vector2i(-3, 2)},
			]},
		]
	})
	# Eval 11: decisive Baneling sacrifice. Explode kills both 2-HP Marines,
	# while a surviving Zergling prevents the self-sacrifice from producing a draw.
	available_scenarios.append({
		"id": "eval_baneling_explode_vs_2marines_hp2",
		"display_name": "Eval: Baneling Explode vs 2 Marines (HP 2)",
		"category": "drill",
		"description": "AI controls a Baneling stacked with two 2-HP Marines on [0,0] plus a safe Zergling. Goal: explode for an immediate Zerg win.",
		"groups": [
			{"name": "terran", "units": [
				{"def_path": "res://src/unit/definitions/marine.tres", "cell": Vector2i(0, 0), "health": 2},
				{"def_path": "res://src/unit/definitions/marine.tres", "cell": Vector2i(0, 0), "health": 2},
			]},
			{"name": "zerg", "ai": true, "units": [
				{"def_path": "res://src/unit/definitions/baneling.tres", "cell": Vector2i(0, 0)},
				{"def_path": _ZERGLING_DEF_PATH, "cell": Vector2i(4, 0)},
			]},
		]
	})
	# Eval 12: no-friendly-fire targeting check. Zergling at [-1,2] moves to [-1,3];
	# scout at [-1,4] should still shoot [-1,3] even though a friendly scout is there.
	available_scenarios.append({
		"id": "eval_scout_no_ff_stepin_to_friendly_tile",
		"display_name": "Eval: Scout No-FF Step-In to Friendly Tile",
		"category": "drill",
		"description": "AI controls Scouts at [-1,4] and [-1,3]. Scripted 1-HP Zergling moves from [-1,2] to [-1,3]. Scout should target [-1,3].",
		"drill": {
			"scripted_groups": {"zerg": "move_to_neg13"},
		},
		"groups": [
			{"name": "terran", "ai": true, "units": [
				{"def_path": "res://src/unit/definitions/scout.tres", "cell": Vector2i(-1, 4)},
				{"def_path": "res://src/unit/definitions/scout.tres", "cell": Vector2i(-1, 3)},
			]},
			{"name": "zerg", "units": [
				{"def_path": _ZERGLING_DEF_PATH, "cell": Vector2i(-1, 2), "health": 1},
			]},
		]
	})
	# Eval 13: no-friendly-fire crossfire check. Zergling starts at [-1,3] and moves
	# to [-1,4]; scout should target the other scout tile [-1,4] to secure the kill.
	available_scenarios.append({
		"id": "eval_scout_no_ff_crossfire_other_scout_tile",
		"display_name": "Eval: Scout No-FF Crossfire Other Scout Tile",
		"category": "drill",
		"description": "AI controls Scouts at [-1,3] and [-1,4]. Scripted 1-HP Zergling moves from [-1,3] to [-1,4]. Scout should target [-1,4].",
		"drill": {
			"scripted_groups": {"zerg": "move_to_neg14"},
		},
		"groups": [
			{"name": "terran", "ai": true, "units": [
				{"def_path": "res://src/unit/definitions/scout.tres", "cell": Vector2i(-1, 3)},
				{"def_path": "res://src/unit/definitions/scout.tres", "cell": Vector2i(-1, 4)},
			]},
			{"name": "zerg", "units": [
				{"def_path": _ZERGLING_DEF_PATH, "cell": Vector2i(-1, 3), "health": 1},
			]},
		]
	})

	# Drill 1: Zergling vs Scout (AI = Zerg). Scripted scout fires at the hex one step
	# closer to itself than the zergling. The AI should reason about HP math and close distance.
	available_scenarios.append({
		"id": "drill_zergling_vs_scout",
		"display_name": "Drill: Zergling vs Scout",
		"category": "drill",
		"description": "AI controls a Zergling vs one Scout on [0,0]. Goal: kill the Scout quickly.",
		"drill": {
			"scripted_groups": {"terran": "fire_one_closer"},
			"expected_outcome": "win",
			"par_turns": 4,
		},
		"groups": [
			{"name": "terran", "units": [
				{"def_path": "res://src/unit/definitions/scout.tres", "cell": Vector2i(0, 0)},
			]},
			{"name": "zerg", "ai": true, "units": [
				{"def_path": _ZERGLING_DEF_PATH, "cell": Vector2i(3, 0)},
			]},
		]
	})
	# Drill 2: 2 Scouts vs Zergling (AI = Terran). Scripted zergling advances in a straight
	# line via fast_move. AI should anticipate where the zergling will be after fast_move resolves.
	available_scenarios.append({
		"id": "drill_scouts_vs_zergling",
		"display_name": "Drill: 2 Scouts vs Zergling",
		"category": "drill",
		"description": "AI controls two Scouts on the same tile. A Zergling starts 3 tiles away. Goal: kill the Zergling before it kills you.",
		"drill": {
			"scripted_groups": {"zerg": "advance_straight"},
			"expected_outcome": "win",
			"par_turns": 2,
		},
		"groups": [
			{"name": "terran", "ai": true, "units": [
				{"def_path": "res://src/unit/definitions/scout.tres", "cell": Vector2i(0, 0)},
				{"def_path": "res://src/unit/definitions/scout.tres", "cell": Vector2i(0, 0)},
			]},
			{"name": "zerg", "units": [
				{"def_path": _ZERGLING_DEF_PATH, "cell": Vector2i(3, 0)},
			]},
		]
	})
	# Drill 3: 2 Scouts vs Zergling + Mountain (AI = Terran). Zergling advances straight;
	# Mountain sits at range 2. AI needs to prioritize targets and manage timing.
	available_scenarios.append({
		"id": "drill_scouts_vs_zergling_mountain",
		"display_name": "Drill: 2 Scouts vs Zergling + Mountain",
		"category": "drill",
		"description": "AI controls two Scouts. A Zergling starts 3 tiles away advancing straight; a Mountain sits at range 2 between the sides. Goal: eliminate all enemies quickly",
		"drill": {
			"scripted_groups": {"zerg": "advance_straight"},
			"expected_outcome": "win",
			"par_turns": 5,
			"excellent_turns": 4,
		},
		"groups": [
			{"name": "terran", "ai": true, "units": [
				{"def_path": "res://src/unit/definitions/scout.tres", "cell": Vector2i(0, 0)},
				{"def_path": "res://src/unit/definitions/scout.tres", "cell": Vector2i(0, 0)},
			]},
			{"name": "zerg", "units": [
				{"def_path": _ZERGLING_DEF_PATH, "cell": Vector2i(3, 0)},
				{"def_path": "res://src/unit/definitions/mountain.tres", "cell": Vector2i(2, 0)},
			]},
		]
	})
	# Drill 4: LLM vs LLM — same setup as Drill 2 but both sides are LLM-controlled.
	available_scenarios.append({
		"id": "drill_llm_vs_llm_scouts_zergling",
		"display_name": "Drill: LLM vs LLM (Scouts vs Zergling)",
		"category": "drill",
		"description": "Both sides controlled by the LLM. Terran has two Scouts at (0,0). Zerg has a Zergling at (3,0). Each side plans independently.",
		"drill": {
			"scripted_groups": {"zerg": "llm_ai"},
			"expected_outcome": "win",
			"par_turns": 2,
		},
		"groups": [
			{"name": "terran", "ai": true, "units": [
				{"def_path": "res://src/unit/definitions/scout.tres", "cell": Vector2i(0, 0)},
				{"def_path": "res://src/unit/definitions/scout.tres", "cell": Vector2i(0, 0)},
			]},
			{"name": "zerg", "units": [
				{"def_path": _ZERGLING_DEF_PATH, "cell": Vector2i(3, 0)},
			]},
		]
	})
	# Drill 5: Zergling vs 2 Scouts (AI = Zerg). Both scouts scripted to fire_one_closer.
	# Harder than Drill 1 — the AI must close distance and survive concentrated fire from two scouts.
	available_scenarios.append({
		"id": "drill_zergling_vs_2_scouts",
		"display_name": "Drill: Zergling vs 2 Scouts",
		"category": "drill",
		"description": "AI controls a Zergling vs two Scouts stacked on [0,0]. Goal: kill both Scouts despite concentrated fire.",
		"drill": {
			"scripted_groups": {"terran": "fire_one_closer"},
			"expected_outcome": "win",
			"par_turns": 6,
		},
		"groups": [
			{"name": "terran", "units": [
				{"def_path": "res://src/unit/definitions/scout.tres", "cell": Vector2i(0, 0)},
				{"def_path": "res://src/unit/definitions/scout.tres", "cell": Vector2i(0, 0)},
			]},
			{"name": "zerg", "ai": true, "units": [
				{"def_path": _ZERGLING_DEF_PATH, "cell": Vector2i(3, 0)},
			]},
		]
	})

func select_scenario(id: String) -> void:
	selected_scenario_id = id
	player_group_name = ""


func normalize_campaign_difficulty(d: String) -> String:
	var k := d.strip_edges().to_lower()
	if k == "easy" or k == "medium" or k == "hard":
		return k
	return "medium"


func set_campaign_difficulty(d: String) -> void:
	campaign_difficulty = normalize_campaign_difficulty(d)


func set_player_group(group_name: String) -> void:
	player_group_name = group_name


## Human-controlled group for `get_selected_scenario()` (difficulty + team swap applied).
## Same seat as multiplayer `MultiplayerState.my_group`: used for fog-of-war observer and UI resources.
func get_human_group_name_for_local_battle() -> String:
	var s := get_selected_scenario()
	for g in s.get("groups", []):
		if not bool(g.get("ai", false)):
			return str(g.get("name", ""))
	var groups_arr: Array = s.get("groups", [])
	if groups_arr.size() > 0:
		return str(groups_arr[0].get("name", ""))
	return ""


func get_group_names_for_scenario(id: String) -> Array[String]:
	for s in available_scenarios:
		if str(s.get("id", "")) == id:
			var names: Array[String] = []
			for g in s.get("groups", []):
				names.append(str(g.get("name", "")))
			return names
	return []


func _default_player_group(s: Dictionary) -> String:
	for g in s.get("groups", []):
		if not bool(g.get("ai", false)):
			return str(g.get("name", ""))
	var groups: Array = s.get("groups", [])
	if groups.size() > 0:
		return str(groups[0].get("name", ""))
	return ""


func _apply_player_group_swap(s: Dictionary) -> Dictionary:
	var chosen := player_group_name
	if chosen.is_empty():
		return s
	var default_group := _default_player_group(s)
	if chosen == default_group:
		return s
	var groups: Array = s.get("groups", [])
	var has_chosen := false
	for g in groups:
		if str(g.get("name", "")) == chosen:
			has_chosen = true
			break
	if not has_chosen:
		return s
	for g in groups:
		var gname := str(g.get("name", ""))
		if gname == chosen:
			g["ai"] = false
		else:
			g["ai"] = true
	var reordered: Array = []
	for g in groups:
		if str(g.get("name", "")) == chosen:
			reordered.insert(0, g)
		else:
			reordered.append(g)
	s["groups"] = reordered
	return s


func scenario_supports_campaign_difficulty(id: String) -> bool:
	for s in available_scenarios:
		if str(s.get("id", "")) == id:
			return bool(s.get("supports_campaign_difficulty", false))
	return false


func _campaign_zergling_count_for_difficulty(s: Dictionary) -> int:
	var counts: Dictionary = s.get("campaign_zergling_counts", {})
	if counts.is_empty():
		return 0
	var key := normalize_campaign_difficulty(campaign_difficulty)
	if not counts.has(key):
		key = "medium"
	return maxi(0, int(counts.get(key, 0)))


func _vector2i_from_variant(v: Variant, fallback: Vector2i) -> Vector2i:
	if v is Vector2i:
		return v
	if v is Vector2:
		return Vector2i(int(v.x), int(v.y))
	if v is Array and v.size() >= 2:
		return Vector2i(int(v[0]), int(v[1]))
	return fallback


func _apply_campaign_difficulty_if_needed(s: Dictionary) -> Dictionary:
	if not bool(s.get("supports_campaign_difficulty", false)):
		return s
	var overrides: Dictionary = s.get("campaign_ai_units_by_difficulty", {})
	if not overrides.is_empty():
		return _apply_campaign_ai_units_override(s, overrides)
	var n: int = _campaign_zergling_count_for_difficulty(s)
	var stack_cell := _vector2i_from_variant(s.get("campaign_zergling_stack_cell", Vector2i(-4, 0)), Vector2i(-4, 0))
	var groups: Array = s.get("groups", [])
	for gi in range(groups.size()):
		var g: Dictionary = groups[gi]
		if not bool(g.get("ai", false)):
			continue
		var units: Array = g.get("units", [])
		var kept: Array = []
		for u in units:
			if not u is Dictionary:
				continue
			var ud: Dictionary = u
			if str(ud.get("def_path", "")) == _ZERGLING_DEF_PATH:
				continue
			kept.append(ud.duplicate(true))
		for _i in n:
			kept.append({"def_path": _ZERGLING_DEF_PATH, "cell": stack_cell})
		g["units"] = kept
	return s


func _apply_campaign_ai_units_override(s: Dictionary, overrides: Dictionary) -> Dictionary:
	var key := normalize_campaign_difficulty(campaign_difficulty)
	if not overrides.has(key):
		key = "medium"
	var unit_list: Array = overrides.get(key, [])
	var groups: Array = s.get("groups", [])
	for gi in range(groups.size()):
		var g: Dictionary = groups[gi]
		if not bool(g.get("ai", false)):
			continue
		var new_units: Array = []
		for u in unit_list:
			if u is Dictionary:
				new_units.append(u.duplicate(true))
		g["units"] = new_units
	return s

## Returns true if scenario is a debug/test scenario (for UI grouping).
func is_debug_scenario(s: Dictionary) -> bool:
	var id: String = str(s.get("id", ""))
	return "_debug" in id or "_test" in id

## Returns campaign, main, drill (AI training), and debug scenarios as separate arrays.
func get_scenarios_by_category() -> Dictionary:
	var campaign: Array[Dictionary] = []
	var main: Array[Dictionary] = []
	var debug: Array[Dictionary] = []
	var drill: Array[Dictionary] = []
	for s in available_scenarios:
		if is_debug_scenario(s):
			debug.append(s)
			continue
		var category: String = str(s.get("category", "main"))
		if category == "campaign":
			campaign.append(s)
		elif category == "drill":
			drill.append(s)
		else:
			main.append(s)
	return {"campaign": campaign, "main": main, "debug": debug, "drill": drill}

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
			return _apply_player_group_swap(_apply_campaign_difficulty_if_needed(_with_tile_resources(s)))
	if available_scenarios.size() > 0:
		return _apply_player_group_swap(_apply_campaign_difficulty_if_needed(_with_tile_resources(available_scenarios[0])))
	return {}

## Returns scenarios suitable for multiplayer (2+ groups).
func get_multiplayer_scenarios() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for s in available_scenarios:
		var groups: Array = s.get("groups", [])
		if groups.size() < 2:
			continue
		out.append(_apply_campaign_difficulty_if_needed(_with_tile_resources(s)))
	return out
