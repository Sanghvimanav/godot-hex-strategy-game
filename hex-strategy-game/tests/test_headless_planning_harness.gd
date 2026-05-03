extends RefCounted

const _Harness := preload("res://tools/headless_planning_harness.gd")


static func run_all(tests: Node) -> bool:
	var ok := true
	ok = _test_metrics_from_snapshot_fake(tests) and ok
	ok = _test_harness_drill_snapshot_sync(tests) and ok
	return ok


static func _test_metrics_from_snapshot_fake(tests: Node) -> bool:
	tests._log("test_headless_planning_harness: metrics_from_snapshot synthetic")
	var fake: Dictionary = {
		"scenario_id": "test",
		"turn": 1,
		"ai_units": [{
			"unit_id": 1,
			"name": "Zergling",
			"cell": [3, 0],
			"legal_options": [
				{"incoming_damage_if_enemies_hold_and_shoot_end": 2},
				{"incoming_damage_if_enemies_hold_and_shoot_end": 0},
			],
		}],
		"enemy_reaction_candidates": [{}, {}],
	}
	var m: Dictionary = _Harness.metrics_from_snapshot(fake)
	if int(m.get("enemy_reaction_candidate_count", 0)) != 2:
		tests._fail("enemy_reaction_candidate_count")
		return false
	var per: Array = m.get("ai_units", []) as Array
	if per.size() != 1:
		tests._fail("per_unit size")
		return false
	var first: Dictionary = per[0]
	if int(first.get("min_incoming_damage_across_legal_options", -1)) != 0:
		tests._fail("min incoming")
		return false
	if int(first.get("max_incoming_damage_across_legal_options", -1)) != 2:
		tests._fail("max incoming")
		return false
	tests._pass("metrics_from_snapshot synthetic")
	return true


static func _test_harness_drill_snapshot_sync(tests: Node) -> bool:
	tests._log("test_headless_planning_harness: drill snapshot sync")
	var root: Node2D = _Harness.build_battle_root()
	tests.add_child(root)
	var units: UnitsContainer = _Harness.setup_scenario_on_tree(root, "drill_llm_vs_llm_scouts_zergling")
	var perspectives: Array[String] = _Harness.list_llm_perspectives(units)
	if perspectives.size() < 2:
		tests._fail("expected terran + zerg perspectives, got %s" % perspectives)
		root.queue_free()
		return false
	var zerg_snap: Dictionary = _Harness.snapshot_for_group(units, "zerg")
	if zerg_snap.is_empty():
		tests._fail("zerg snapshot empty")
		root.queue_free()
		return false
	if not zerg_snap.has("enemy_reaction_candidates"):
		tests._fail("missing enemy_reaction_candidates")
		root.queue_free()
		return false
	var eulo: Array = zerg_snap.get("enemy_units_legal_options", []) as Array
	if eulo.is_empty():
		tests._fail("expected enemy_units_legal_options for zerg perspective")
		root.queue_free()
		return false
	var first_enemy: Dictionary = eulo[0]
	var elo: Array = first_enemy.get("legal_options", []) as Array
	if elo.is_empty():
		tests._fail("enemy legal_options should be non-empty")
		root.queue_free()
		return false
	var terran_snap: Dictionary = _Harness.snapshot_for_group(units, "terran")
	if (terran_snap.get("ai_units", []) as Array).is_empty():
		tests._fail("terran snapshot ai_units empty")
		root.queue_free()
		return false
	root.queue_free()
	tests._pass("drill snapshot sync")
	return true
