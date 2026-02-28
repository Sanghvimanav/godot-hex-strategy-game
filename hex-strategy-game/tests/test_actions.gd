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
	ok = _test_ghost_attack_ray_range_and_pattern(tests) and ok
	ok = _test_extract_tile_action_config(tests) and ok
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

static func _test_ghost_attack_ray_range_and_pattern(tests: Node) -> bool:
	tests._log("test_actions: ghost attack_ray uses target-only range 2-3")
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
	tests._pass("ghost attack_ray uses target-only range 2-3")
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
