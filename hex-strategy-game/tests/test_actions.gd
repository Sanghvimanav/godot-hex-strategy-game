extends RefCounted
## Tests for Actions (action configs, get_action_type, phase order, energy_consumption/recharge).

static func run_all(tests: Node) -> bool:
	var ok := true
	ok = _test_actions_static_callable_on_script(tests) and ok
	ok = _test_action_types(tests) and ok
	ok = _test_action_order_phase_order(tests) and ok
	ok = _test_energy_and_recharge_config(tests) and ok
	ok = _test_reload_recharge_slow_ability(tests) and ok
	ok = _test_attack_support_ability_types(tests) and ok
	ok = _test_scout_attack_ray_range_and_pattern(tests) and ok
	ok = _test_scout_attack_ray_energy_cost(tests) and ok
	ok = _test_scout_visibility_range(tests) and ok
	ok = _test_medic_definition_stats_and_actions(tests) and ok
	ok = _test_zerg_vs_terran_includes_medic(tests) and ok
	ok = _test_zerg_vs_terran_v2_scenario_exists(tests) and ok
	ok = _test_campaign_opening_scenario_exists(tests) and ok
	ok = _test_excavator_debug_scenario_exists(tests) and ok
	ok = _test_medic_heal_debug_scenario_exists(tests) and ok
	ok = _test_fester_debug_scenario_exists(tests) and ok
	ok = _test_shardling_debug_scenario_exists(tests) and ok
	ok = _test_spire_debug_scenario_exists(tests) and ok
	ok = _test_mountain_debug_scenario_exists(tests) and ok
	ok = _test_extract_tile_action_config(tests) and ok
	ok = _test_recruit_people_action_config(tests) and ok
	ok = _test_spawn_scout_action_config(tests) and ok
	ok = _test_campaign_baneling_breach_scenario_exists(tests) and ok
	ok = _test_drill_llm_vs_llm_scenario_exists(tests) and ok
	return ok

## Ensures get_action_type and get_action_config stay static so scripts can call them without preloading (avoids parser error).
static func _test_actions_static_callable_on_script(tests: Node) -> bool:
	tests._log("test_actions: get_action_type/get_action_config callable on script class (static)")
	var Script = load("res://src/global/actions.gd") as GDScript
	if Script.get_action_type("attack_short") != "ability":
		tests._fail("Script.get_action_type should work (static); got %s" % Script.get_action_type("attack_short"))
		return false
	if Script.get_action_config("reload").get("type", "") != "slow ability":
		tests._fail("Script.get_action_config should work (static)")
		return false
	tests._pass("Actions static callable on script class")
	return true

static func _test_action_types(tests: Node) -> bool:
	tests._log("test_actions: get_action_type")
	if Actions.get_action_type("attack_short") != "ability":
		tests._fail("attack_short type should be ability, got %s" % Actions.get_action_type("attack_short"))
		return false
	if Actions.get_action_type("attack_passive") != "fast ability":
		tests._fail("attack_passive type should be fast ability, got %s" % Actions.get_action_type("attack_passive"))
		return false
	if Actions.get_action_type("explode") != "slow ability":
		tests._fail("explode type should be slow ability, got %s" % Actions.get_action_type("explode"))
		return false
	if Actions.get_action_type("heal_adjacent") != "ability":
		tests._fail("heal_adjacent type should be ability")
		return false
	if Actions.get_action_type("reload") != "slow ability":
		tests._fail("reload type should be slow ability, got %s" % Actions.get_action_type("reload"))
		return false
	if Actions.get_action_type("move_short") != "move":
		tests._fail("move_short type should be move")
		return false
	tests._pass("get_action_type")
	return true

static func _test_action_order_phase_order(tests: Node) -> bool:
	tests._log("test_actions: ACTION_ORDER has fast ability before move")
	var order: Array = Actions.ACTION_ORDER
	var idx_fast_ability := order.find("fast ability")
	var idx_move := order.find("move")
	var idx_ability := order.find("ability")
	if idx_fast_ability < 0 or idx_move < 0 or idx_ability < 0:
		tests._fail("ACTION_ORDER missing phase")
		return false
	if idx_fast_ability >= idx_move:
		tests._fail("fast ability should come before move (fast ability=%d move=%d)" % [idx_fast_ability, idx_move])
		return false
	if idx_move >= idx_ability:
		tests._fail("move should come before ability")
		return false
	tests._pass("ACTION_ORDER phase order")
	return true

static func _test_energy_and_recharge_config(tests: Node) -> bool:
	tests._log("test_actions: energy_consumption and recharge config keys")
	var c: Dictionary = Actions.get_action_config("reload")
	if not c.get("energy_consumption", 999) == -1:
		tests._fail("reload should have energy_consumption=-1, got %s" % c.get("energy_consumption", 999))
		return false
	c = Actions.get_action_config("heal_adjacent")
	if not c.has("recharge"):
		tests._fail("heal_adjacent should have recharge key")
		return false
	if c.get("recharge", -1) != 0:
		tests._fail("heal_adjacent recharge should be 0")
		return false
	c = Actions.get_action_config("support_adjacent")
	if c.get("recharge", -1) != 1:
		tests._fail("support_adjacent recharge should be 1")
		return false
	tests._pass("energy_consumption and recharge")
	return true

static func _test_reload_recharge_slow_ability(tests: Node) -> bool:
	tests._log("test_actions: reload and recharge are slow ability")
	if Actions.get_action_type("recharge") != "slow ability":
		tests._fail("recharge should be slow ability")
		return false
	tests._pass("reload/recharge slow ability")
	return true

static func _test_attack_support_ability_types(tests: Node) -> bool:
	tests._log("test_actions: attack and support map to ability phases")
	if Actions.get_action_type("attack_hydralisk") != "ability":
		tests._fail("attack_hydralisk should be ability")
		return false
	if Actions.get_action_type("resupply_adjacent") != "ability":
		tests._fail("resupply_adjacent should be ability")
		return false
	tests._pass("attack/support ability types")
	return true

static func _test_scout_attack_ray_range_and_pattern(tests: Node) -> bool:
	tests._log("test_actions: scout attack_ray uses target-only range 1-2")
	var c: Dictionary = Actions.get_action_config("attack_ray")
	if c.get("pattern", "") != "target":
		tests._fail("attack_ray should use pattern=target, got %s" % c.get("pattern", ""))
		return false
	if int(c.get("min_range", -1)) != 1:
		tests._fail("attack_ray min_range should be 1, got %s" % c.get("min_range", -1))
		return false
	if int(c.get("max_range", -1)) != 2:
		tests._fail("attack_ray max_range should be 2, got %s" % c.get("max_range", -1))
		return false
	tests._pass("scout attack_ray uses target-only range 1-2")
	return true

static func _test_scout_attack_ray_energy_cost(tests: Node) -> bool:
	tests._log("test_actions: marine/scout primary attacks and definitions use no energy")
	var ray: Dictionary = Actions.get_action_config("attack_ray")
	if int(ray.get("energy_consumption", -1)) != 0:
		tests._fail("attack_ray energy_consumption should be 0, got %s" % ray.get("energy_consumption", -1))
		return false
	var short: Dictionary = Actions.get_action_config("attack_short")
	if int(short.get("energy_consumption", -1)) != 0:
		tests._fail("attack_short energy_consumption should be 0, got %s" % short.get("energy_consumption", -1))
		return false
	var scout_def := load("res://src/unit/definitions/scout.tres")
	var marine_def := load("res://src/unit/definitions/marine.tres")
	var scout_u: UnitDefinition = scout_def as UnitDefinition
	var marine_u: UnitDefinition = marine_def as UnitDefinition
	if scout_u == null or marine_u == null:
		tests._fail("scout and marine definitions should load")
		return false
	if scout_u.max_energy != 0:
		tests._fail("scout max_energy should be 0, got %s" % scout_u.max_energy)
		return false
	if marine_u.max_energy != 0:
		tests._fail("marine max_energy should be 0, got %s" % marine_u.max_energy)
		return false
	tests._pass("marine and scout attacks are free; units have no energy pool")
	return true

static func _test_scout_visibility_range(tests: Node) -> bool:
	tests._log("test_actions: scout has sight_range 3")
	var scout_def := load("res://src/unit/definitions/scout.tres")
	if scout_def == null:
		tests._fail("scout.tres should load")
		return false
	var scout_sight_range: int = int(scout_def.get("sight_range"))
	if scout_sight_range != 3:
		tests._fail("scout sight_range should be 3, got %s" % scout_sight_range)
		return false
	tests._pass("scout has sight_range 3")
	return true

static func _test_medic_definition_stats_and_actions(tests: Node) -> bool:
	tests._log("test_actions: medic unit has requested terran stats and loadout")
	var medic_def := load("res://src/unit/definitions/medic.tres")
	if medic_def == null:
		tests._fail("medic.tres should load")
		return false
	if int(medic_def.get("faction")) != 2:
		tests._fail("medic faction should be Terran (2)")
		return false
	if int(medic_def.get("max_health")) != 2:
		tests._fail("medic max_health should be 2")
		return false
	if int(medic_def.get("max_energy")) != 4:
		tests._fail("medic max_energy should be 4")
		return false
	var move_keys_variant = medic_def.get("move_action_keys")
	var move_keys: Array = move_keys_variant if move_keys_variant is Array else []
	if move_keys.size() != 2 or "move_short" not in move_keys or "reload" not in move_keys:
		tests._fail("medic move_action_keys should include only move_short and reload, got %s" % move_keys)
		return false
	var ability_keys_variant = medic_def.get("ability_action_keys")
	var ability_keys: Array = ability_keys_variant if ability_keys_variant is Array else []
	if ability_keys.size() != 1 or str(ability_keys[0]) != "heal_adjacent":
		tests._fail("medic ability_action_keys should be [heal_adjacent], got %s" % ability_keys)
		return false
	tests._pass("medic unit has requested terran stats and loadout")
	return true

static func _test_zerg_vs_terran_includes_medic(tests: Node) -> bool:
	tests._log("test_actions: zerg_vs_terran scenario includes terran medic")
	var scenario: Dictionary = Scenarios.get_scenario_by_id("zerg_vs_terran")
	if scenario.is_empty():
		tests._fail("zerg_vs_terran scenario should exist")
		return false
	var has_player_medic := false
	for g in scenario.get("groups", []):
		if str(g.get("name", "")) != "terran":
			continue
		for u in g.get("units", []):
			if str(u.get("def_path", "")) == "res://src/unit/definitions/medic.tres":
				has_player_medic = true
				break
	if not has_player_medic:
		tests._fail("zerg_vs_terran should include a player medic")
		return false
	tests._pass("zerg_vs_terran scenario includes terran medic")
	return true

static func _test_zerg_vs_terran_v2_scenario_exists(tests: Node) -> bool:
	tests._log("test_actions: zerg_vs_terran_v2 has base+marine+scout vs zergling+fester")
	var scenario: Dictionary = Scenarios.get_scenario_by_id("zerg_vs_terran_v2")
	if scenario.is_empty():
		tests._fail("zerg_vs_terran_v2 scenario should exist")
		return false
	var has_base := false
	var has_marine := false
	var has_scout := false
	var has_zergling := false
	var has_fester := false
	for g in scenario.get("groups", []):
		var group_name: String = str(g.get("name", ""))
		var units: Array = g.get("units", [])
		if group_name == "terran":
			for u in units:
				var def: String = str(u.get("def_path", ""))
				if def == "res://src/unit/definitions/terran_base.tres" or def == "res://src/unit/definitions/infantry_camp.tres":
					has_base = true
				elif def == "res://src/unit/definitions/marine.tres":
					has_marine = true
				elif def == "res://src/unit/definitions/scout.tres":
					has_scout = true
		if group_name == "zerg" and bool(g.get("ai", false)):
			for u in units:
				var def: String = str(u.get("def_path", ""))
				if def == "res://src/unit/definitions/zergling.tres":
					has_zergling = true
				elif def == "res://src/unit/definitions/fester.tres":
					has_fester = true
	if not has_base:
		tests._fail("zerg_vs_terran_v2 should include player terran base")
		return false
	if not has_marine:
		tests._fail("zerg_vs_terran_v2 should include player marine")
		return false
	if not has_scout:
		tests._fail("zerg_vs_terran_v2 should include player scout")
		return false
	if not has_zergling:
		tests._fail("zerg_vs_terran_v2 should include opponent zergling")
		return false
	if not has_fester:
		tests._fail("zerg_vs_terran_v2 should include opponent fester")
		return false
	tests._pass("zerg_vs_terran_v2 has base+marine+scout vs zergling+fester")
	return true

static func _test_campaign_opening_scenario_exists(tests: Node) -> bool:
	tests._log("test_actions: campaign_opening is in campaign category with stacked scouts, difficulty-scaled zerglings, and mountains on x = -1")
	var by_category: Dictionary = Scenarios.get_scenarios_by_category()
	var campaign_template: Dictionary = {}
	var in_campaign := false
	for entry in by_category.get("campaign", []):
		if str(entry.get("id", "")) == "campaign_opening":
			in_campaign = true
			campaign_template = entry
			break
	if not in_campaign:
		tests._fail("campaign_opening should be categorized as campaign")
		return false
	if not bool(campaign_template.get("supports_campaign_difficulty", false)):
		tests._fail("campaign_opening should support campaign difficulty")
		return false
	var counts: Dictionary = campaign_template.get("campaign_zergling_counts", {})
	if int(counts.get("easy", -1)) != 2 or int(counts.get("medium", -1)) != 3 or int(counts.get("hard", -1)) != 4:
		tests._fail("campaign_opening should define zergling counts easy=2 medium=3 hard=4")
		return false
	var saved_diff: String = Scenarios.campaign_difficulty
	Scenarios.set_campaign_difficulty("medium")
	var scenario: Dictionary = Scenarios.get_scenario_by_id("campaign_opening")
	if scenario.is_empty():
		tests._fail("campaign_opening scenario should exist")
		Scenarios.set_campaign_difficulty(saved_diff)
		return false
	var desc: String = str(scenario.get("description", "")).strip_edges()
	if desc.is_empty():
		tests._fail("campaign_opening should define a description (win conditions for both sides)")
		Scenarios.set_campaign_difficulty(saved_diff)
		return false
	var desc_lower := desc.to_lower()
	if not ("mountain" in desc_lower and "scout" in desc_lower):
		tests._fail("campaign_opening description should mention mountains and scouts")
		Scenarios.set_campaign_difficulty(saved_diff)
		return false
	for entry in by_category.get("campaign", []):
		var d: String = str(entry.get("description", "")).strip_edges()
		if d.is_empty():
			tests._fail("campaign scenario %s must include a non-empty description" % entry.get("id", ""))
			Scenarios.set_campaign_difficulty(saved_diff)
			return false
	var total_zerglings := 0
	var left_zerglings := 0
	var total_scout := 0
	var right_scout := 0
	var total_marines := 0
	var right_marines := 0
	var total_mountains := 0
	var has_player_anchor := false
	var player_anchor := Vector2i.ZERO
	var has_zerg_stack_anchor := false
	var zerg_stack_anchor := Vector2i.ZERO
	var expected_mountain_cells: Array[Vector2i] = [Vector2i(-1, -2), Vector2i(-1, 0), Vector2i(-1, 2)]
	var mountain_cells_found: Dictionary = {}
	for g in scenario.get("groups", []):
		var group_name: String = str(g.get("name", ""))
		for u in g.get("units", []):
			var def_path: String = str(u.get("def_path", ""))
			var cell_variant: Variant = u.get("cell", Vector2i.ZERO)
			var cell := Vector2i.ZERO
			if cell_variant is Vector2i:
				cell = cell_variant
			elif cell_variant is Vector2:
				cell = Vector2i(int(cell_variant.x), int(cell_variant.y))
			if group_name == "terran":
				if not has_player_anchor:
					player_anchor = cell
					has_player_anchor = true
				elif cell != player_anchor:
					tests._fail("campaign_opening player units should all share the same spawn tile")
					Scenarios.set_campaign_difficulty(saved_diff)
					return false
			elif group_name == "zerg":
				if def_path == "res://src/unit/definitions/zergling.tres":
					if not has_zerg_stack_anchor:
						zerg_stack_anchor = cell
						has_zerg_stack_anchor = true
					elif cell != zerg_stack_anchor:
						tests._fail("campaign_opening zerglings should all share the same spawn tile")
						Scenarios.set_campaign_difficulty(saved_diff)
						return false
				elif def_path == "res://src/unit/definitions/mountain.tres":
					total_mountains += 1
					var key := "%d,%d" % [cell.x, cell.y]
					mountain_cells_found[key] = true
			if def_path == "res://src/unit/definitions/zergling.tres":
				total_zerglings += 1
				if cell.x < 0:
					left_zerglings += 1
			elif def_path == "res://src/unit/definitions/scout.tres":
				total_scout += 1
				if cell.x > 0:
					right_scout += 1
			elif def_path == "res://src/unit/definitions/marine.tres":
				total_marines += 1
				if cell.x > 0:
					right_marines += 1
	if total_zerglings != 3 or left_zerglings != 3:
		tests._fail("campaign_opening on medium should include 3 zerglings on the left side")
		Scenarios.set_campaign_difficulty(saved_diff)
		return false
	for pair in [["easy", 2], ["medium", 3], ["hard", 4]]:
		Scenarios.set_campaign_difficulty(pair[0])
		var scn: Dictionary = Scenarios.get_scenario_by_id("campaign_opening")
		var nz := 0
		for g2 in scn.get("groups", []):
			for u2 in g2.get("units", []):
				if str(u2.get("def_path", "")) == "res://src/unit/definitions/zergling.tres":
					nz += 1
		if nz != pair[1]:
			tests._fail("campaign_opening on %s should have %d zerglings, got %d" % [pair[0], pair[1], nz])
			Scenarios.set_campaign_difficulty(saved_diff)
			return false
	Scenarios.set_campaign_difficulty(saved_diff)
	if total_mountains != 3:
		tests._fail("campaign_opening should include 3 mountains")
		return false
	for ec in expected_mountain_cells:
		var ek := "%d,%d" % [ec.x, ec.y]
		if not mountain_cells_found.get(ek, false):
			tests._fail("campaign_opening mountains should include a unit at cell %s" % ek)
			return false
	if total_scout != 3 or right_scout != 3:
		tests._fail("campaign_opening should include 3 scouts on the right side")
		return false
	if total_marines != 0 or right_marines != 0:
		tests._fail("campaign_opening should include no marines")
		return false
	if not has_player_anchor or not has_zerg_stack_anchor:
		tests._fail("campaign_opening should define player spawn and zergling stack anchors")
		return false
	if player_anchor.x <= 0 or zerg_stack_anchor.x >= 0:
		tests._fail("campaign_opening anchors should be on opposite sides (player right, zerg stack left)")
		return false
	if player_anchor.x != -zerg_stack_anchor.x or player_anchor.y != zerg_stack_anchor.y:
		tests._fail("campaign_opening player and zerg stack anchors should be mirrored across the board center")
		return false
	tests._pass("campaign_opening scenario is categorized with 3 stacked scouts, difficulty zerglings, mountains on (-1,-2) (-1,0) (-1,2)")
	return true

static func _test_excavator_debug_scenario_exists(tests: Node) -> bool:
	tests._log("test_actions: excavator_debug has excavator on crystal tile")
	var scenario: Dictionary = Scenarios.get_scenario_by_id("excavator_debug")
	if scenario.is_empty():
		tests._fail("excavator_debug scenario should exist")
		return false
	var has_excavator := false
	var has_crystal := false
	for g in scenario.get("groups", []):
		if str(g.get("name", "")) == "terran":
			for u in g.get("units", []):
				if str(u.get("def_path", "")) == "res://src/unit/definitions/excavator.tres":
					has_excavator = true
					break
	var tile_resources: Dictionary = scenario.get("tile_resources", {})
	for key in tile_resources:
		var entry = tile_resources[key]
		if entry is Dictionary and str(entry.get("resource_type", "")) == "crystal":
			has_crystal = true
			break
	if not has_excavator:
		tests._fail("excavator_debug should include player excavator")
		return false
	if not has_crystal:
		tests._fail("excavator_debug should include crystal tile")
		return false
	tests._pass("excavator_debug has excavator on crystal tile")
	return true

static func _test_medic_heal_debug_scenario_exists(tests: Node) -> bool:
	tests._log("test_actions: medic_heal_debug includes medic, damaged marine, and attacking hydralisk")
	var scenario: Dictionary = Scenarios.get_scenario_by_id("medic_heal_debug")
	if scenario.is_empty():
		tests._fail("medic_heal_debug scenario should exist")
		return false
	var has_medic := false
	var has_damaged_marine := false
	var has_ai_hydralisk := false
	for g in scenario.get("groups", []):
		var group_name: String = str(g.get("name", ""))
		var units: Array = g.get("units", [])
		if group_name == "terran":
			for u in units:
				if str(u.get("def_path", "")) == "res://src/unit/definitions/medic.tres":
					has_medic = true
				if str(u.get("def_path", "")) == "res://src/unit/definitions/marine.tres" and int(u.get("health", 0)) == 3:
					has_damaged_marine = true
		if group_name == "zerg" and bool(g.get("ai", false)):
			for u in units:
				if str(u.get("def_path", "")) == "res://src/unit/definitions/hydralisk.tres":
					has_ai_hydralisk = true
	if not has_medic:
		tests._fail("medic_heal_debug should include a player medic")
		return false
	if not has_damaged_marine:
		tests._fail("medic_heal_debug should include a marine with starting health 3")
		return false
	if not has_ai_hydralisk:
		tests._fail("medic_heal_debug should include an AI hydralisk attacker")
		return false
	tests._pass("medic_heal_debug includes medic, damaged marine, and attacking hydralisk")
	return true

static func _test_fester_debug_scenario_exists(tests: Node) -> bool:
	tests._log("test_actions: fester_debug scenario exists")
	var scenario: Dictionary = Scenarios.get_scenario_by_id("fester_debug")
	if scenario.is_empty():
		tests._fail("fester_debug scenario should exist")
		return false
	var has_fester := false
	for g in scenario.get("groups", []):
		for u in g.get("units", []):
			if str(u.get("def_path", "")) == "res://src/unit/definitions/fester.tres":
				has_fester = true
				break
	if not has_fester:
		tests._fail("fester_debug should include Fester unit")
		return false
	var tile_resources: Dictionary = scenario.get("tile_resources", {})
	if tile_resources.is_empty():
		tests._fail("fester_debug should have village tile for consume")
		return false
	tests._pass("fester_debug scenario exists")
	return true

static func _test_shardling_debug_scenario_exists(tests: Node) -> bool:
	tests._log("test_actions: shardling_debug has Shardling on crystal tile with resources for evolve")
	var scenario: Dictionary = Scenarios.get_scenario_by_id("shardling_debug")
	if scenario.is_empty():
		tests._fail("shardling_debug scenario should exist")
		return false
	var has_shardling := false
	var has_crystal := false
	var has_resources := false
	for g in scenario.get("groups", []):
		if str(g.get("name", "")) == "terran":
			for u in g.get("units", []):
				if str(u.get("def_path", "")) == "res://src/unit/definitions/shardling.tres":
					has_shardling = true
			var res: Dictionary = g.get("resources", {})
			if int(res.get("crystal", 0)) >= 1 and int(res.get("people", 0)) >= 2:
				has_resources = true
	var tile_resources: Dictionary = scenario.get("tile_resources", {})
	for key in tile_resources:
		var entry = tile_resources[key]
		if entry is Dictionary and str(entry.get("resource_type", "")) == "crystal":
			has_crystal = true
			break
	if not has_shardling:
		tests._fail("shardling_debug should include player Shardling")
		return false
	if not has_crystal:
		tests._fail("shardling_debug should include crystal tile for mining")
		return false
	if not has_resources:
		tests._fail("shardling_debug should give player resources for evolve (people + crystal)")
		return false
	tests._pass("shardling_debug has Shardling on crystal tile with resources for evolve")
	return true

static func _test_spire_debug_scenario_exists(tests: Node) -> bool:
	tests._log("test_actions: spire_debug has Spire vs Marine at range 2")
	var scenario: Dictionary = Scenarios.get_scenario_by_id("spire_debug")
	if scenario.is_empty():
		tests._fail("spire_debug scenario should exist")
		return false
	var has_spire := false
	var has_marine := false
	var spire_cell := Vector2i.ZERO
	var marine_cell := Vector2i.ZERO
	for g in scenario.get("groups", []):
		var gn: String = str(g.get("name", ""))
		for u in g.get("units", []):
			var dp: String = str(u.get("def_path", ""))
			var cv: Variant = u.get("cell", Vector2i.ZERO)
			var cell := Vector2i.ZERO
			if cv is Vector2i:
				cell = cv
			elif cv is Vector2:
				cell = Vector2i(int(cv.x), int(cv.y))
			if gn == "terran" and dp == "res://src/unit/definitions/spire.tres":
				has_spire = true
				spire_cell = cell
			elif gn == "zerg" and dp == "res://src/unit/definitions/marine.tres":
				has_marine = true
				marine_cell = cell
	if not has_spire or not has_marine:
		tests._fail("spire_debug should include player Spire and opponent Marine")
		return false
	if spire_cell != Vector2i(0, 0) or marine_cell != Vector2i(2, 0):
		tests._fail("spire_debug should place Spire at (0,0) and Marine at (2,0)")
		return false
	tests._pass("spire_debug has Spire and Marine for range-2 check")
	return true

static func _test_mountain_debug_scenario_exists(tests: Node) -> bool:
	tests._log("test_actions: mountain_debug has Scout vs Mountain at range 2")
	var scenario: Dictionary = Scenarios.get_scenario_by_id("mountain_debug")
	if scenario.is_empty():
		tests._fail("mountain_debug scenario should exist")
		return false
	var has_mountain := false
	var has_scout := false
	var mountain_cell := Vector2i.ZERO
	var scout_cell := Vector2i.ZERO
	for g in scenario.get("groups", []):
		var gn: String = str(g.get("name", ""))
		for u in g.get("units", []):
			var dp: String = str(u.get("def_path", ""))
			var cv: Variant = u.get("cell", Vector2i.ZERO)
			var cell := Vector2i.ZERO
			if cv is Vector2i:
				cell = cv
			elif cv is Vector2:
				cell = Vector2i(int(cv.x), int(cv.y))
			if gn == "terran" and dp == "res://src/unit/definitions/scout.tres":
				has_scout = true
				scout_cell = cell
			elif gn == "zerg" and dp == "res://src/unit/definitions/mountain.tres":
				has_mountain = true
				mountain_cell = cell
	if not has_mountain or not has_scout:
		tests._fail("mountain_debug should include player Scout and opponent Mountain")
		return false
	if scout_cell != Vector2i(0, 0) or mountain_cell != Vector2i(2, 0):
		tests._fail("mountain_debug should place Scout at (0,0) and Mountain at (2,0)")
		return false
	tests._pass("mountain_debug has Scout and Mountain for range-2 check")
	return true

static func _test_extract_tile_action_config(tests: Node) -> bool:
	tests._log("test_actions: extract_tile action exists and uses ability type")
	var c: Dictionary = Actions.get_action_config("extract_tile")
	if c.is_empty():
		tests._fail("extract_tile config should exist")
		return false
	if c.get("type", "") != "ability":
		tests._fail("extract_tile type should be ability, got %s" % c.get("type", ""))
		return false
	if int(c.get("tile_resource_depletion", 0)) != 1:
		tests._fail("extract_tile should deplete 1 resource per use")
		return false
	tests._pass("extract_tile action config")
	return true

static func _test_recruit_people_action_config(tests: Node) -> bool:
	tests._log("test_actions: recruit_people action exists and extracts people")
	var c: Dictionary = Actions.get_action_config("recruit_people")
	if c.is_empty():
		tests._fail("recruit_people config should exist")
		return false
	if c.get("type", "") != "ability":
		tests._fail("recruit_people type should be ability, got %s" % c.get("type", ""))
		return false
	if c.get("name", "") != "Recruit":
		tests._fail("recruit_people display name should be Recruit")
		return false
	var allowed = c.get("allowed_resource_types", [])
	if not (allowed is Array) or "people" not in allowed:
		tests._fail("recruit_people should allow extracting people only")
		return false
	tests._pass("recruit_people action config")
	return true

static func _test_spawn_scout_action_config(tests: Node) -> bool:
	tests._log("test_actions: spawn_scout action requires 3 people and spawns scout")
	var c: Dictionary = Actions.get_action_config("spawn_scout")
	if c.is_empty():
		tests._fail("spawn_scout config should exist")
		return false
	if c.get("type", "") != "spawn":
		tests._fail("spawn_scout type should be spawn")
		return false
	if c.get("spawn_unit", "") != "res://src/unit/definitions/scout.tres":
		tests._fail("spawn_scout should spawn scout unit")
		return false
	if c.get("required_group_resource_type", "") != "people":
		tests._fail("spawn_scout should require people resource type")
		return false
	if int(c.get("required_group_resource_amount", 0)) != 3:
		tests._fail("spawn_scout should require exactly 3 people")
		return false
	tests._pass("spawn_scout action config")
	return true

static func _test_campaign_baneling_breach_scenario_exists(tests: Node) -> bool:
	tests._log("test_actions: campaign_baneling_breach has infantry camp + 2 marines + 2 scouts vs difficulty-scaled banelings + zerglings")
	var by_category: Dictionary = Scenarios.get_scenarios_by_category()
	var in_campaign := false
	var campaign_template: Dictionary = {}
	for entry in by_category.get("campaign", []):
		if str(entry.get("id", "")) == "campaign_baneling_breach":
			in_campaign = true
			campaign_template = entry
			break
	if not in_campaign:
		tests._fail("campaign_baneling_breach should be categorized as campaign")
		return false
	if not bool(campaign_template.get("supports_campaign_difficulty", false)):
		tests._fail("campaign_baneling_breach should support campaign difficulty")
		return false
	var desc: String = str(campaign_template.get("description", "")).strip_edges()
	if desc.is_empty():
		tests._fail("campaign_baneling_breach should define a description")
		return false
	var desc_lower := desc.to_lower()
	if not ("baneling" in desc_lower and "infantry camp" in desc_lower):
		tests._fail("campaign_baneling_breach description should mention banelings and infantry camp")
		return false
	var saved_diff: String = Scenarios.campaign_difficulty
	var expected: Dictionary = {
		"easy": {"zerglings": 2, "banelings": 1},
		"medium": {"zerglings": 3, "banelings": 1},
		"hard": {"zerglings": 4, "banelings": 2},
	}
	for diff in expected:
		Scenarios.set_campaign_difficulty(diff)
		var scenario: Dictionary = Scenarios.get_scenario_by_id("campaign_baneling_breach")
		if scenario.is_empty():
			tests._fail("campaign_baneling_breach should exist")
			Scenarios.set_campaign_difficulty(saved_diff)
			return false
		var nz := 0
		var nb := 0
		var has_camp := false
		var marine_count := 0
		var scout_count := 0
		for g in scenario.get("groups", []):
			var gn: String = str(g.get("name", ""))
			for u in g.get("units", []):
				var dp: String = str(u.get("def_path", ""))
				if gn == "terran":
					if dp == "res://src/unit/definitions/infantry_camp.tres":
						has_camp = true
					elif dp == "res://src/unit/definitions/marine.tres":
						marine_count += 1
					elif dp == "res://src/unit/definitions/scout.tres":
						scout_count += 1
				elif gn == "zerg":
					if dp == "res://src/unit/definitions/zergling.tres":
						nz += 1
					elif dp == "res://src/unit/definitions/baneling.tres":
						nb += 1
		if not has_camp:
			tests._fail("campaign_baneling_breach should include a player infantry camp")
			Scenarios.set_campaign_difficulty(saved_diff)
			return false
		if marine_count != 2:
			tests._fail("campaign_baneling_breach should include 2 player marines, got %d" % marine_count)
			Scenarios.set_campaign_difficulty(saved_diff)
			return false
		if scout_count != 2:
			tests._fail("campaign_baneling_breach should include 2 player scouts, got %d" % scout_count)
			Scenarios.set_campaign_difficulty(saved_diff)
			return false
		var ez: int = expected[diff]["zerglings"]
		var eb: int = expected[diff]["banelings"]
		if nz != ez:
			tests._fail("campaign_baneling_breach on %s should have %d zerglings, got %d" % [diff, ez, nz])
			Scenarios.set_campaign_difficulty(saved_diff)
			return false
		if nb != eb:
			tests._fail("campaign_baneling_breach on %s should have %d banelings, got %d" % [diff, eb, nb])
			Scenarios.set_campaign_difficulty(saved_diff)
			return false
	Scenarios.set_campaign_difficulty(saved_diff)
	tests._pass("campaign_baneling_breach has infantry camp + 2 marines + 2 scouts vs difficulty-scaled banelings + zerglings")
	return true


static func _test_drill_llm_vs_llm_scenario_exists(tests: Node) -> bool:
	tests._log("test_actions: drill_llm_vs_llm scenario has correct config and apply_scenario wiring")
	var scenario: Dictionary = Scenarios.get_scenario_by_id("drill_llm_vs_llm_scouts_zergling")
	if scenario.is_empty():
		tests._fail("drill_llm_vs_llm_scouts_zergling should exist")
		return false
	if str(scenario.get("category", "")) != "drill":
		tests._fail("expected category drill")
		return false
	var drill: Dictionary = scenario.get("drill", {})
	var scripted: Dictionary = drill.get("scripted_groups", {})
	if str(scripted.get("zerg", "")) != "llm_ai":
		tests._fail("expected zerg scripted_groups = llm_ai, got %s" % scripted)
		return false
	var groups: Array = scenario.get("groups", [])
	var terran_ai := false
	var zerg_ai := false
	var scout_count := 0
	var zergling_count := 0
	for g in groups:
		var gn: String = str(g.get("name", ""))
		if gn == "terran" and bool(g.get("ai", false)):
			terran_ai = true
		if gn == "zerg" and bool(g.get("ai", false)):
			zerg_ai = true
		for u in g.get("units", []):
			var dp: String = str(u.get("def_path", ""))
			if "scout" in dp:
				scout_count += 1
			elif "zergling" in dp:
				zergling_count += 1
	if not terran_ai:
		tests._fail("terran should be ai: true")
		return false
	if zerg_ai:
		tests._fail("zerg should NOT be ai: true (drill_scripted instead)")
		return false
	if scout_count != 2:
		tests._fail("expected 2 scouts, got %d" % scout_count)
		return false
	if zergling_count != 1:
		tests._fail("expected 1 zergling, got %d" % zergling_count)
		return false
	# Verify apply_scenario wires up drill_scripted_groups and planning order correctly.
	var container := UnitsContainer.new()
	tests.add_child(container)
	container.apply_scenario(scenario)
	if not container.drill_scripted_groups.has("zerg"):
		tests._fail("apply_scenario should populate drill_scripted_groups for zerg")
		container.free()
		return false
	if str(container.drill_scripted_groups["zerg"]) != "llm_ai":
		tests._fail("drill_scripted_groups zerg should be llm_ai, got %s" % container.drill_scripted_groups["zerg"])
		container.free()
		return false
	if "terran" not in container.ai_group_names:
		tests._fail("ai_group_names should contain terran")
		container.free()
		return false
	if "zerg" in container.ai_group_names:
		tests._fail("ai_group_names should NOT contain zerg (it uses drill script)")
		container.free()
		return false
	var ordered: Array = container._get_planning_units_ordered()
	if ordered.is_empty():
		tests._fail("planning units should not be empty")
		container.free()
		return false
	var first_group: String = ordered[0].get_parent().name if ordered[0].get_parent() else ""
	if first_group != "zerg":
		tests._fail("drill 'llm_ai' unit (zerg) should be first in planning order, got %s" % first_group)
		container.free()
		return false
	var last_group: String = ordered[ordered.size() - 1].get_parent().name if ordered[ordered.size() - 1].get_parent() else ""
	if last_group != "terran":
		tests._fail("primary AI unit (terran) should be last in planning order, got %s" % last_group)
		container.free()
		return false
	container.free()
	tests._pass("drill_llm_vs_llm scenario config and apply_scenario wiring correct")
	return true
