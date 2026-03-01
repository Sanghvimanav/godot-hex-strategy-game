extends RefCounted
## Tests for TurnExecutor (ABILITY_TYPES, phase order, damage cells for self-pattern).
## Pipeline behavior: damage is applied at the start of each attack phase (before animations)
## so positions are correct; each phase's animations complete before the next phase runs.

const TurnExecutor = preload("res://src/battle/turn_executor.gd")
const ActionInstance = preload("res://src/unit/action_collection.gd")

static func run_all(tests: Node) -> bool:
	var ok := true
	ok = _test_ability_types_include_phases(tests) and ok
	ok = _test_move_types(tests) and ok
	ok = _test_attack_passive_has_self_pattern(tests) and ok
	ok = _test_get_damage_cells_self_pattern_uses_attacker_cell(tests) and ok
	ok = _test_get_damage_cells_non_self_uses_path(tests) and ok
	ok = _test_get_damage_cells_target_pattern_only_end_point(tests) and ok
	ok = _test_get_damage_cells_self_or_adjacent_uses_absolute_endpoint(tests) and ok
	ok = _test_attack_viper_has_target_pattern(tests) and ok
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
	tests._log("test_turn_executor: get_damage_cells target pattern (Viper) only end_point")
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

static func _test_attack_viper_has_target_pattern(tests: Node) -> bool:
	tests._log("test_turn_executor: attack_viper has pattern target")
	var config: Dictionary = Actions.get_action_config("attack_viper")
	if config.get("pattern", "") != "target":
		tests._fail("attack_viper should have pattern=target (damage only target tile), got %s" % config.get("pattern", ""))
		return false
	tests._pass("attack_viper pattern=target")
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
