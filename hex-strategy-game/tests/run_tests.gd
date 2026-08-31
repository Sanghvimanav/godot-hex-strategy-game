extends Node
## Test runner: runs all test modules and exits with 0 on success, 1 on failure.
## Run with: godot --headless --path hex-strategy-game res://tests/test_runner.tscn

var _fail_count: int = 0
var _pass_count: int = 0

func _ready() -> void:
	print("Running tests...")
	var TestActions = load("res://tests/test_actions.gd") as GDScript
	var TestHexGrid = load("res://tests/test_hex_grid.gd") as GDScript
	var TestTurnExecutor = load("res://tests/test_turn_executor.gd") as GDScript
	var TestEventBus = load("res://tests/test_event_bus.gd") as GDScript
	var TestTurnExecutionCore = load("res://tests/test_turn_execution_core.gd") as GDScript
	var TestPureStateSimulator = load("res://tests/test_pure_state_simulator.gd") as GDScript
	var TestPureStateLegalActions = load("res://tests/test_pure_state_legal_actions.gd") as GDScript
	var TestPureStatePlans = load("res://tests/test_pure_state_plans.gd") as GDScript
	var TestPureStateEvaluator = load("res://tests/test_pure_state_evaluator.gd") as GDScript
	var TestPureStateOneTurnSearch = load("res://tests/test_pure_state_one_turn_search.gd") as GDScript
	var TestOneTurnSearchBaselines = load("res://tests/test_one_turn_search_baselines.gd") as GDScript
	var TestPureStateOpponentResponseSearch = load("res://tests/test_pure_state_opponent_response_search.gd") as GDScript
	var TestOpponentResponseRetreat = load("res://tests/test_opponent_response_retreat.gd") as GDScript
	var TestServerTurnExecutor = load("res://tests/test_server_turn_executor.gd") as GDScript
	var TestUnifiedPipeline = load("res://tests/test_unified_pipeline.gd") as GDScript
	var TestStunEffects = load("res://tests/test_stun_effects.gd") as GDScript
	var TestReplayRestore = load("res://tests/test_replay_restore.gd") as GDScript
	var TestLlmPlanning = load("res://tests/test_llm_planning.gd") as GDScript
	var TestLlmLearningsIngest = load("res://tests/test_llm_learnings_ingest.gd") as GDScript
	var TestLlmPlanningRecentTurns = load("res://tests/test_llm_planning_recent_turns.gd") as GDScript
	var TestLlmPostGame = load("res://tests/test_llm_post_game.gd") as GDScript
	var TestHeadlessPlanningHarness = load("res://tests/test_headless_planning_harness.gd") as GDScript

	if not TestActions.run_all(self):
		_fail_count += 1
	else:
		_pass_count += 1
	if not TestHexGrid.run_all(self):
		_fail_count += 1
	else:
		_pass_count += 1
	if not TestTurnExecutor.run_all(self):
		_fail_count += 1
	else:
		_pass_count += 1
	if not TestEventBus.run_all(self):
		_fail_count += 1
	else:
		_pass_count += 1
	if not TestTurnExecutionCore.run_all(self):
		_fail_count += 1
	else:
		_pass_count += 1
	if not TestPureStateSimulator.run_all(self):
		_fail_count += 1
	else:
		_pass_count += 1
	if not TestPureStateLegalActions.run_all(self):
		_fail_count += 1
	else:
		_pass_count += 1
	if not TestPureStatePlans.run_all(self):
		_fail_count += 1
	else:
		_pass_count += 1
	if not TestPureStateEvaluator.run_all(self):
		_fail_count += 1
	else:
		_pass_count += 1
	if not TestPureStateOneTurnSearch.run_all(self):
		_fail_count += 1
	else:
		_pass_count += 1
	if not TestOneTurnSearchBaselines.run_all(self):
		_fail_count += 1
	else:
		_pass_count += 1
	if not TestPureStateOpponentResponseSearch.run_all(self):
		_fail_count += 1
	else:
		_pass_count += 1
	if not TestOpponentResponseRetreat.run_all(self):
		_fail_count += 1
	else:
		_pass_count += 1
	if not TestServerTurnExecutor.run_all(self):
		_fail_count += 1
	else:
		_pass_count += 1
	if not TestUnifiedPipeline.run_all(self):
		_fail_count += 1
	else:
		_pass_count += 1
	if not TestStunEffects.run_all(self):
		_fail_count += 1
	else:
		_pass_count += 1
	if not TestReplayRestore.run_all(self):
		_fail_count += 1
	else:
		_pass_count += 1
	if not TestLlmPlanning.run_all(self):
		_fail_count += 1
	else:
		_pass_count += 1
	if not TestLlmLearningsIngest.run_all(self):
		_fail_count += 1
	else:
		_pass_count += 1
	if not TestLlmPlanningRecentTurns.run_all(self):
		_fail_count += 1
	else:
		_pass_count += 1
	if not TestLlmPostGame.run_all(self):
		_fail_count += 1
	else:
		_pass_count += 1
	if not TestHeadlessPlanningHarness.run_all(self):
		_fail_count += 1
	else:
		_pass_count += 1

	print("")
	print("Result: %d passed, %d failed" % [_pass_count, _fail_count])
	var exit_code := 1 if _fail_count > 0 else 0
	# Delay quit so output is flushed
	await get_tree().create_timer(0.1).timeout
	get_tree().quit(exit_code)

func _log(msg: String) -> void:
	print("  %s" % msg)

func _pass(msg: String) -> void:
	print("  [PASS] %s" % msg)

func _fail(msg: String) -> void:
	print("  [FAIL] %s" % msg)
