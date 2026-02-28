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
	ok = _test_extract_tile_action_config(tests) and ok
	ok = _test_recruit_people_action_config(tests) and ok
	ok = _test_spawn_scout_action_config(tests) and ok
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
	if Actions.get_action_type("attack_viper") != "ability":
		tests._fail("attack_viper should be ability")
		return false
	if Actions.get_action_type("resupply_adjacent") != "ability":
		tests._fail("resupply_adjacent should be ability")
		return false
	tests._pass("attack/support ability types")
	return true

static func _test_scout_attack_ray_range_and_pattern(tests: Node) -> bool:
	tests._log("test_actions: scout attack_ray uses target-only range 2-3")
	var c: Dictionary = Actions.get_action_config("attack_ray")
	if c.get("pattern", "") != "target":
		tests._fail("attack_ray should use pattern=target, got %s" % c.get("pattern", ""))
		return false
	if int(c.get("min_range", -1)) != 2:
		tests._fail("attack_ray min_range should be 2, got %s" % c.get("min_range", -1))
		return false
	if int(c.get("max_range", -1)) != 3:
		tests._fail("attack_ray max_range should be 3, got %s" % c.get("max_range", -1))
		return false
	tests._pass("scout attack_ray uses target-only range 2-3")
	return true

static func _test_scout_attack_ray_energy_cost(tests: Node) -> bool:
	tests._log("test_actions: scout attack_ray costs 1 energy")
	var c: Dictionary = Actions.get_action_config("attack_ray")
	if int(c.get("energy_consumption", -1)) != 1:
		tests._fail("attack_ray energy_consumption should be 1, got %s" % c.get("energy_consumption", -1))
		return false
	tests._pass("scout attack_ray costs 1 energy")
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
		if str(g.get("name", "")) != "player":
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

static func _test_extract_tile_action_config(tests: Node) -> bool:
	tests._log("test_actions: extract_tile action exists and uses extract type")
	var c: Dictionary = Actions.get_action_config("extract_tile")
	if c.is_empty():
		tests._fail("extract_tile config should exist")
		return false
	if c.get("type", "") != "extract":
		tests._fail("extract_tile type should be extract, got %s" % c.get("type", ""))
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
	if c.get("type", "") != "extract":
		tests._fail("recruit_people type should be extract, got %s" % c.get("type", ""))
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
	tests._log("test_actions: spawn_scout action requires people and spawns scout")
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
	if int(c.get("required_group_resource_amount", 0)) != 5:
		tests._fail("spawn_scout should require exactly 5 people")
		return false
	tests._pass("spawn_scout action config")
	return true
