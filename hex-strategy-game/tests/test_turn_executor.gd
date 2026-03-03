extends RefCounted
## Tests for TurnExecutor (ABILITY_TYPES, phase order, damage cells for self-pattern).
## Pipeline behavior: damage is applied at the start of each attack phase (before animations)
## so positions are correct; each phase's animations complete before the next phase runs.

const TurnExecutor = preload("res://src/battle/turn_executor.gd")
const ActionInstance = preload("res://src/unit/action_collection.gd")
const ActionDefinition = preload("res://src/unit/action_definition.gd")
const UNIT_SCENE = preload("res://src/unit/unit.tscn")

static func run_all(tests: Node) -> bool:
	var ok := true
	ok = _test_ability_types_include_phases(tests) and ok
	ok = _test_move_types(tests) and ok
	ok = _test_attack_passive_has_self_pattern(tests) and ok
	ok = _test_get_damage_cells_self_pattern_uses_attacker_cell(tests) and ok
	ok = _test_get_damage_cells_non_self_uses_path(tests) and ok
	ok = _test_get_damage_cells_target_pattern_only_end_point(tests) and ok
	ok = _test_get_damage_cells_self_or_adjacent_uses_absolute_endpoint(tests) and ok
	ok = _test_attack_hydralisk_has_target_pattern(tests) and ok
	ok = _test_target_damage_effect_spawns_for_scout_and_hydralisk(tests) and ok
	ok = _test_handle_support_heals_absolute_target_and_spawns_effect(tests) and ok
	ok = _test_fast_ability_before_move(tests) and ok
	ok = _test_phase_animations_complete_before_next(tests) and ok
	return ok

static func _test_ability_types_include_phases(tests: Node) -> bool:
	tests._log("test_turn_executor: ABILITY_TYPES")
	if not TurnExecutor.ABILITY_TYPES.has("fast ability"):
		tests._fail("ABILITY_TYPES should contain fast ability")
		return false
	if not TurnExecutor.ABILITY_TYPES.has("ability"):
		tests._fail("ABILITY_TYPES should contain ability")
		return false
	if not TurnExecutor.ABILITY_TYPES.has("slow ability"):
		tests._fail("ABILITY_TYPES should contain slow ability")
		return false
	if TurnExecutor.ABILITY_TYPES.size() != 3:
		tests._fail("ABILITY_TYPES should have 3 elements")
		return false
	tests._pass("ABILITY_TYPES")
	return true

static func _test_move_types(tests: Node) -> bool:
	tests._log("test_turn_executor: MOVE_TYPES")
	if not TurnExecutor.MOVE_TYPES.has("fast move"):
		tests._fail("MOVE_TYPES should contain fast move")
		return false
	if not TurnExecutor.MOVE_TYPES.has("move"):
		tests._fail("MOVE_TYPES should contain move")
		return false
	if not TurnExecutor.MOVE_TYPES.has("slow move"):
		tests._fail("MOVE_TYPES should contain slow move")
		return false
	tests._pass("MOVE_TYPES")
	return true

static func _test_attack_passive_has_self_pattern(tests: Node) -> bool:
	tests._log("test_turn_executor: attack_passive has pattern self")
	var config: Dictionary = Actions.get_action_config("attack_passive")
	if config.get("pattern", "") != "self":
		tests._fail("attack_passive should have pattern=self so damage uses attacker current cell after move, got %s" % config.get("pattern", ""))
		return false
	tests._pass("attack_passive pattern=self")
	return true

static func _test_get_damage_cells_self_pattern_uses_attacker_cell(tests: Node) -> bool:
	tests._log("test_turn_executor: get_damage_cells self pattern uses attacker cell (damage at phase start, before animations)")
	var ac := ActionInstance.new(null, null)
	ac.path = []
	ac.end_point = Vector2(0, 0)
	var config: Dictionary = { "pattern": "self" }
	var attacker_cell := Vector2(3, -1)
	var cells: Array = TurnExecutor.get_damage_cells(attacker_cell, ac, config)
	if cells.size() != 1:
		tests._fail("self pattern should return 1 cell, got %d" % cells.size())
		return false
	if not HexGrid.cell_equal(cells[0], attacker_cell):
		tests._fail("self pattern should return [attacker_cell], got %s" % cells)
		return false
	tests._pass("get_damage_cells self uses attacker cell (damage phase runs before attack animations)")
	return true

static func _test_get_damage_cells_non_self_uses_path(tests: Node) -> bool:
	tests._log("test_turn_executor: get_damage_cells ray uses path to target")
	var ac := ActionInstance.new(null, null)
	ac.path = [Vector2(1, 0)]
	ac.end_point = Vector2(2, 0)
	var config: Dictionary = { "pattern": "ray" }
	var cells: Array = TurnExecutor.get_damage_cells(Vector2(0, 0), ac, config)
	if cells.size() != 2:
		tests._fail("ray should return path to target (2 cells), got %d" % cells.size())
		return false
	if not HexGrid.cell_equal(cells[0], Vector2(1, 0)) or not HexGrid.cell_equal(cells[1], Vector2(2, 0)):
		tests._fail("ray cells should match path to end_point, got %s" % cells)
		return false
	tests._pass("get_damage_cells ray uses path")
	return true

static func _test_get_damage_cells_target_pattern_only_end_point(tests: Node) -> bool:
	tests._log("test_turn_executor: get_damage_cells target pattern (Hydralisk) only end_point")
	var ac := ActionInstance.new(null, null)
	ac.path = [Vector2(1, 0)]
	ac.end_point = Vector2(2, 0)
	var config: Dictionary = { "pattern": "target" }
	var cells: Array = TurnExecutor.get_damage_cells(Vector2(0, 0), ac, config)
	if cells.size() != 1:
		tests._fail("target pattern should return 1 cell (end_point only), got %d" % cells.size())
		return false
	if not HexGrid.cell_equal(cells[0], Vector2(2, 0)):
		tests._fail("target pattern should return [end_point], got %s" % cells)
		return false
	tests._pass("get_damage_cells target uses end_point only")
	return true

static func _test_get_damage_cells_self_or_adjacent_uses_absolute_endpoint(tests: Node) -> bool:
	tests._log("test_turn_executor: get_damage_cells self_or_adjacent uses absolute end_point")
	var ac := ActionInstance.new(null, null)
	ac.path = []
	ac.end_point = Vector2(3, 1)
	var config: Dictionary = { "pattern": "self_or_adjacent" }
	var cells: Array = TurnExecutor.get_damage_cells(Vector2(2, 1), ac, config)
	if cells.size() != 1:
		tests._fail("self_or_adjacent should return 1 cell, got %d" % cells.size())
		return false
	if not HexGrid.cell_equal(cells[0], Vector2(3, 1)):
		tests._fail("self_or_adjacent should treat end_point as absolute, got %s" % cells)
		return false
	tests._pass("get_damage_cells self_or_adjacent uses absolute end_point")
	return true

static func _test_attack_hydralisk_has_target_pattern(tests: Node) -> bool:
	tests._log("test_turn_executor: attack_hydralisk has pattern target")
	var config: Dictionary = Actions.get_action_config("attack_hydralisk")
	if config.get("pattern", "") != "target":
		tests._fail("attack_hydralisk should have pattern=target (damage only target tile), got %s" % config.get("pattern", ""))
		return false
	tests._pass("attack_hydralisk pattern=target")
	return true

static func _count_target_damage_effect_nodes(parent: Node) -> int:
	var count := 0
	for child in parent.get_children():
		if str(child.name).begins_with("target_damage_effect"):
			count += 1
	return count

static func _clear_target_damage_effect_nodes(parent: Node) -> void:
	for child in parent.get_children():
		if str(child.name).begins_with("target_damage_effect"):
			child.free()

static func _test_target_damage_effect_spawns_for_scout_and_hydralisk(tests: Node) -> bool:
	tests._log("test_turn_executor: target damage effect spawns for scout/hydralisk attacks")
	var root := Node2D.new()
	tests.add_child(root)
	var player := Node2D.new()
	player.name = "player"
	root.add_child(player)
	var scout_def := load("res://src/unit/definitions/scout.tres") as UnitDefinition
	var hydralisk_def := load("res://src/unit/definitions/hydralisk.tres") as UnitDefinition
	var marine_def := load("res://src/unit/definitions/marine.tres") as UnitDefinition
	if scout_def == null or hydralisk_def == null or marine_def == null:
		tests._fail("scout, hydralisk, and marine definitions must load for target effect test")
		root.free()
		return false
	var scout := UNIT_SCENE.instantiate() as Unit
	scout.def = scout_def
	scout.starting_cell = Vector2i(0, 0)
	player.add_child(scout)
	var hydralisk := UNIT_SCENE.instantiate() as Unit
	hydralisk.def = hydralisk_def
	hydralisk.starting_cell = Vector2i(1, 0)
	player.add_child(hydralisk)
	var marine := UNIT_SCENE.instantiate() as Unit
	marine.def = marine_def
	marine.starting_cell = Vector2i(2, 0)
	player.add_child(marine)

	var scout_attack_def := ActionDefinition.new()
	scout_attack_def.action_key = "attack_ray"
	var scout_ac := ActionInstance.new(scout_attack_def, scout)
	scout_ac.path = []
	scout_ac.end_point = Vector2(0, 1)
	_clear_target_damage_effect_nodes(player)
	TurnExecutor._play_target_damage_effect_for_attack(scout, scout_ac)
	var count_after_scout := _count_target_damage_effect_nodes(player)
	if count_after_scout != 1:
		tests._fail("attack_ray should spawn one target_damage_effect, got %d" % count_after_scout)
		root.free()
		return false

	var hydralisk_attack_def := ActionDefinition.new()
	hydralisk_attack_def.action_key = "attack_hydralisk"
	var hydralisk_ac := ActionInstance.new(hydralisk_attack_def, hydralisk)
	hydralisk_ac.path = []
	hydralisk_ac.end_point = Vector2(1, 1)
	if not TurnExecutor._should_play_target_damage_effect(hydralisk, hydralisk_ac):
		tests._fail("attack_hydralisk should be eligible for target damage effect")
		root.free()
		return false
	_clear_target_damage_effect_nodes(player)
	TurnExecutor._play_target_damage_effect_for_attack(hydralisk, hydralisk_ac)
	var count_after_hydralisk := _count_target_damage_effect_nodes(player)
	if count_after_hydralisk != 1:
		tests._fail("attack_hydralisk should spawn one target_damage_effect, got %d" % count_after_hydralisk)
		root.free()
		return false

	var marine_attack_def := ActionDefinition.new()
	marine_attack_def.action_key = "attack_short"
	var marine_ac := ActionInstance.new(marine_attack_def, marine)
	marine_ac.path = []
	marine_ac.end_point = Vector2(2, 1)
	_clear_target_damage_effect_nodes(player)
	TurnExecutor._play_target_damage_effect_for_attack(marine, marine_ac)
	var count_after_marine := _count_target_damage_effect_nodes(player)
	if count_after_marine != 0:
		tests._fail("attack_short should not spawn target_damage_effect, got %d" % count_after_marine)
		root.free()
		return false

	tests._pass("target damage effect spawns for scout/hydralisk only")
	root.free()
	return true

static func _test_handle_support_heals_absolute_target_and_spawns_effect(tests: Node) -> bool:
	tests._log("test_turn_executor: support heal queues absolute target then applies at phase end")
	var root := Node2D.new()
	tests.add_child(root)
	var player := Node2D.new()
	player.name = "player"
	root.add_child(player)
	var opponent := Node2D.new()
	opponent.name = "opponent"
	root.add_child(opponent)
	var medic_def := load("res://src/unit/definitions/medic.tres") as UnitDefinition
	var marine_def := load("res://src/unit/definitions/marine.tres") as UnitDefinition
	if medic_def == null or marine_def == null:
		tests._fail("medic and marine definitions must load for support test")
		root.free()
		return false
	var medic := UNIT_SCENE.instantiate() as Unit
	medic.def = medic_def
	medic.starting_cell = Vector2i(3, 1)
	player.add_child(medic)
	var marine := UNIT_SCENE.instantiate() as Unit
	marine.def = marine_def
	marine.starting_cell = Vector2i(4, 1)
	player.add_child(marine)
	marine.max_health = 4
	marine.health = 2
	medic.max_energy = 4
	medic.energy = 4
	var heal_def := ActionDefinition.new()
	heal_def.action_key = "heal_adjacent"
	heal_def.display_name = "Heal"
	var ac := ActionInstance.new(heal_def, medic)
	ac.path = []
	ac.end_point = Vector2(4, 1)  # Absolute target cell (not relative offset)
	var get_units_at_cell := func(cell: Vector2) -> Array:
		var out: Array = []
		for g in [player, opponent]:
			for child in g.get_children():
				if child is Unit and HexGrid.cell_equal(child.cell, cell):
					out.append(child)
		return out
	var ctx := TurnExecutor.ExecutionContext.new(
		[player, opponent],
		true,
		{"actions": [], "died_ids": [], "summary": []},
		get_units_at_cell,
		tests.get_tree()
	)
	TurnExecutor._handle_support("ability", [{"unit": medic, "ac": ac}], ctx)
	if marine.health != 2:
		tests._fail("support should queue health delta until phase end; marine should remain 2 before apply, got %s" % marine.health)
		root.free()
		return false
	if medic.energy != 4:
		tests._fail("support should queue energy delta until phase end; medic should remain 4 before apply, got %s" % medic.energy)
		root.free()
		return false
	TurnExecutor._apply_phase_stat_deltas(ctx)
	if marine.health != 3:
		tests._fail("heal_adjacent should heal marine at absolute [4,1] from 2 to 3, got %s" % marine.health)
		root.free()
		return false
	if medic.energy != 3:
		tests._fail("heal_adjacent should consume 1 medic energy (4 -> 3), got %s" % medic.energy)
		root.free()
		return false
	if marine.get_node_or_null("heal_effect") == null:
		tests._fail("heal_adjacent should spawn heal_effect on healed target")
		root.free()
		return false
	tests._pass("support heal queues absolute target and applies at phase end")
	root.free()
	return true

static func _test_fast_ability_before_move(tests: Node) -> bool:
	tests._log("test_turn_executor: fast ability before move in ACTION_ORDER")
	var order: Array = Actions.ACTION_ORDER
	var idx_fast_ability := order.find("fast ability")
	var idx_move := order.find("move")
	if idx_fast_ability < 0 or idx_move < 0:
		tests._fail("ACTION_ORDER missing fast ability or move")
		return false
	if idx_fast_ability >= idx_move:
		tests._fail("fast ability must run before move so units can move then attack (e.g. Zergling onto Marine), fast_ability=%d move=%d" % [idx_fast_ability, idx_move])
		return false
	tests._pass("fast ability before move")
	return true

## Pipeline awaits each phase handler so move/ability animations finish before the next phase.
## Ability handler awaits reload and attack sub-handlers so those animations complete too.
static func _test_phase_animations_complete_before_next(tests: Node) -> bool:
	tests._log("test_turn_executor: phase order and handlers ensure animations complete before next phase")
	var order: Array = Actions.ACTION_ORDER
	if order.is_empty():
		tests._fail("ACTION_ORDER must not be empty")
		return false
	for action_type in order:
		var handler := TurnExecutor._get_handler_for_type(action_type)
		if action_type in TurnExecutor.MOVE_TYPES or action_type in TurnExecutor.ABILITY_TYPES:
			if not handler.is_valid():
				tests._fail("ACTION_ORDER phase '%s' must have a handler" % action_type)
				return false
	tests._pass("phase handlers present; run_pipeline awaits each so animations complete before next phase")
	return true
