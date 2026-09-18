extends Node
## Diagnostic-only trace of policy prior -> PUCT visits -> rollout Q on the
## permanent six-rotation Marine targeting contact state. No mechanics features are
## supplied to the network; engine mechanics are used only after search to label
## which attack directions directly/indirectly hit the stationary contact target.

const PureStateSelfPlaySuite = preload("res://src/simulation/pure_state_self_play_suite.gd")
const PureStateAutoregressivePUCT = preload("res://src/simulation/pure_state_autoregressive_puct.gd")
const TurnExecutionCore = preload("res://src/battle/turn_execution_core.gd")
const PureStateJointPolicy = preload("res://src/simulation/pure_state_joint_policy.gd")

const ROTATIONS := [0, 1, 2, 3, 4, 5]

func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	var args := _parse_cmdline_kv()
	var checkpoint := str(args.get("checkpoint", ""))
	var out_path := str(args.get("out", "user://mcts_targeting_trace.json"))
	var repeats := maxi(1, int(args.get("repeats", "6")))
	var simulations := maxi(1, int(args.get("simulations", "40")))
	var rollout_depth := maxi(1, int(args.get("rollout-depth", "2")))
	var c_puct := float(args.get("puct-c", "1.5"))
	var seed_base := int(args.get("seed-base", "730000"))
	if checkpoint.is_empty():
		push_error("--checkpoint is required")
		get_tree().quit(1)
		return

	var rows: Array = []
	var ok := true
	for rotation_variant in ROTATIONS:
		var rotation := int(rotation_variant)
		var state := _contact_state(rotation)
		for repeat_index in range(repeats):
			var seed := seed_base + rotation * 1000 + repeat_index
			var result := PureStateAutoregressivePUCT.choose_plan(
				state,
				"terran",
				"zerg",
				checkpoint,
				{
					"puct_simulations": simulations,
					"puct_c": c_puct,
					"rollout_depth": rollout_depth,
					"seed": seed,
				}
			)
			if not bool(result.get("valid", false)):
				push_error("PUCT failed rotation=%d repeat=%d: %s" % [rotation, repeat_index, str(result)])
				ok = false
				continue
			var targets: Array = result.get("prefix_targets", [])
			if targets.is_empty():
				push_error("No prefix targets rotation=%d repeat=%d" % [rotation, repeat_index])
				ok = false
				continue
			var target: Dictionary = targets[0]
			rows.append(_summarize_target(state, target, rotation, repeat_index, seed))

	var report := {
		"experiment": "mcts_targeting_trace_v1",
		"checkpoint": checkpoint,
		"repeats_per_rotation": repeats,
		"simulations_requested": simulations,
		"rollout_depth": rollout_depth,
		"puct_c": c_puct,
		"explicit_action_mechanics_added_to_model": false,
		"rows": rows,
		"by_rotation": _aggregate_by_rotation(rows),
		"overall": _aggregate_rows(rows),
	}
	var wrote := _write_json(out_path, report)
	print(JSON.stringify(report))
	PureStateJointPolicy.shutdown()
	get_tree().quit(0 if ok and wrote else 1)

func _contact_state(rotation: int) -> Dictionary:
	var state := PureStateSelfPlaySuite.basic_state(1, 1, 0, 8, "", false)
	var zerg := _find_group(state, "zerg")
	for unit_variant in zerg.get("units", []):
		if unit_variant is Dictionary:
			(unit_variant as Dictionary)["cell"] = [0, 0]
	state = PureStateSelfPlaySuite.rotate_state(state, rotation)
	state["turn_index"] = 1
	state["scenario_id"] = "mcts_targeting_trace_r%d" % rotation
	return state

func _summarize_target(state: Dictionary, target: Dictionary, rotation: int, repeat_index: int, seed: int) -> Dictionary:
	var terran := _find_group(state, "terran")
	var actor: Dictionary = (terran.get("units", []) as Array)[0]
	var attacks: Array = []
	for edge_variant in target.get("visit_distribution", []):
		if not (edge_variant is Dictionary):
			continue
		var edge: Dictionary = edge_variant
		var action: Dictionary = edge.get("action", {})
		if str(action.get("action_key", "")) != "attack_short":
			continue
		var labels := _label_action(state, actor, action)
		attacks.append({
			"end_point": (action.get("end_point", []) as Array).duplicate(),
			"direct_target_hits_enemy": bool(labels.get("direct_target_hits_enemy", false)),
			"damage_footprint_hits_enemy": bool(labels.get("damage_footprint_hits_enemy", false)),
			"damage_cells": labels.get("damage_cells", []),
			"prior": float(edge.get("prior", 0.0)),
			"visits": int(edge.get("visits", 0)),
			"visit_probability": float(edge.get("probability", 0.0)),
			"q": float(edge.get("q", 0.0)),
		})
	attacks.sort_custom(func(a, b): return str(a.get("end_point", [])) < str(b.get("end_point", [])))
	return {
		"rotation": rotation,
		"repeat": repeat_index,
		"seed": seed,
		"actor_cell": (actor.get("cell", []) as Array).duplicate(),
		"legal_action_count": int(target.get("legal_action_count", 0)),
		"exposure_coverage": float(target.get("exposure_coverage", 0.0)),
		"visit_coverage": float(target.get("visit_coverage", 0.0)),
		"puct_simulations_run": int(target.get("puct_simulations_run", 0)),
		"forced_coverage_visits": int(target.get("forced_coverage_visits", 0)),
		"post_coverage_puct_visits": int(target.get("post_coverage_puct_visits", 0)),
		"mcts_vs_prior_kl": float(target.get("mcts_vs_prior_kl", 0.0)),
		"attacks": attacks,
	}

func _label_action(state: Dictionary, actor: Dictionary, action: Dictionary) -> Dictionary:
	var config: Dictionary = Actions.get_action_config("attack_short")
	var actor_cell: Array = actor.get("cell", [0, 0])
	var aq := int(actor_cell[0])
	var ar := int(actor_cell[1])
	var end_point = action.get("end_point", actor_cell)
	var path: Array = action.get("path", [])
	var target_cells: Array = TurnExecutionCore.get_damage_cells_for_config(aq, ar, path, end_point, config)
	if config.has("area_of_effect"):
		var aoe_cells: Array = HexGrid.get_aoe_tiles(Vector2(aq, ar), Vector2(_cell_q(end_point), _cell_r(end_point)), config.area_of_effect)
		for cell_variant in aoe_cells:
			var cell := Vector2i(int(cell_variant.x), int(cell_variant.y))
			if cell not in target_cells:
				target_cells.append(cell)
	var enemy_cells: Dictionary = {}
	var zerg := _find_group(state, "zerg")
	for unit_variant in zerg.get("units", []):
		if unit_variant is Dictionary and int((unit_variant as Dictionary).get("health", 0)) > 0:
			var cell: Array = (unit_variant as Dictionary).get("cell", [0, 0])
			enemy_cells["%d,%d" % [int(cell[0]), int(cell[1])]] = true
	var direct_key := "%d,%d" % [_cell_q(end_point), _cell_r(end_point)]
	var damage_hit := false
	var serialized_cells: Array = []
	for cell_variant in target_cells:
		var q := int(cell_variant.x)
		var r := int(cell_variant.y)
		serialized_cells.append([q, r])
		if enemy_cells.has("%d,%d" % [q, r]):
			damage_hit = true
	return {
		"direct_target_hits_enemy": enemy_cells.has(direct_key),
		"damage_footprint_hits_enemy": damage_hit,
		"damage_cells": serialized_cells,
	}

func _aggregate_by_rotation(rows: Array) -> Dictionary:
	var result: Dictionary = {}
	for rotation_variant in ROTATIONS:
		var rotation := int(rotation_variant)
		var selected: Array = []
		for row_variant in rows:
			if row_variant is Dictionary and int((row_variant as Dictionary).get("rotation", -1)) == rotation:
				selected.append(row_variant)
		result[str(rotation)] = _aggregate_rows(selected)
	return result

func _aggregate_rows(rows: Array) -> Dictionary:
	var direct_prior := 0.0
	var direct_visit := 0.0
	var direct_q := 0.0
	var best_miss_q := 0.0
	var direct_q_margin := 0.0
	var direct_top_visit := 0
	var direct_top_q := 0
	var footprint_top_visit := 0
	var n := 0
	for row_variant in rows:
		if not (row_variant is Dictionary):
			continue
		var attacks: Array = (row_variant as Dictionary).get("attacks", [])
		if attacks.is_empty():
			continue
		var attack_prior_total := 0.0
		var attack_visit_total := 0.0
		var direct_edge: Dictionary = {}
		var best_miss := -INF
		var top_visit_edge: Dictionary = attacks[0]
		var top_q_edge: Dictionary = attacks[0]
		for attack_variant in attacks:
			var attack: Dictionary = attack_variant
			attack_prior_total += float(attack.get("prior", 0.0))
			attack_visit_total += float(attack.get("visits", 0))
			if bool(attack.get("direct_target_hits_enemy", false)):
				direct_edge = attack
			elif not bool(attack.get("damage_footprint_hits_enemy", false)):
				best_miss = maxf(best_miss, float(attack.get("q", 0.0)))
			if int(attack.get("visits", 0)) > int(top_visit_edge.get("visits", 0)):
				top_visit_edge = attack
			if float(attack.get("q", 0.0)) > float(top_q_edge.get("q", 0.0)):
				top_q_edge = attack
		if direct_edge.is_empty():
			continue
		n += 1
		direct_prior += float(direct_edge.get("prior", 0.0)) / maxf(attack_prior_total, 1e-12)
		direct_visit += float(direct_edge.get("visits", 0)) / maxf(attack_visit_total, 1e-12)
		direct_q += float(direct_edge.get("q", 0.0))
		if is_finite(best_miss):
			best_miss_q += best_miss
			direct_q_margin += float(direct_edge.get("q", 0.0)) - best_miss
		if bool(top_visit_edge.get("direct_target_hits_enemy", false)):
			direct_top_visit += 1
		if bool(top_visit_edge.get("damage_footprint_hits_enemy", false)):
			footprint_top_visit += 1
		if bool(top_q_edge.get("direct_target_hits_enemy", false)):
			direct_top_q += 1
	if n == 0:
		return {"rows": 0}
	var nf := float(n)
	return {
		"rows": n,
		"mean_direct_prior_given_attack": direct_prior / nf,
		"mean_direct_visit_share_given_attack": direct_visit / nf,
		"mean_direct_q": direct_q / nf,
		"mean_best_complete_miss_q": best_miss_q / nf,
		"mean_direct_q_minus_best_complete_miss_q": direct_q_margin / nf,
		"direct_is_top_visit_rate": float(direct_top_visit) / nf,
		"footprint_hit_is_top_visit_rate": float(footprint_top_visit) / nf,
		"direct_is_top_q_rate": float(direct_top_q) / nf,
	}

func _find_group(state: Dictionary, group_name: String) -> Dictionary:
	for group_variant in state.get("groups", []):
		if group_variant is Dictionary and str((group_variant as Dictionary).get("name", "")) == group_name:
			return group_variant
	return {}

func _cell_q(value: Variant) -> int:
	if value is Array and (value as Array).size() > 0:
		return int(value[0])
	if value is Vector2 or value is Vector2i:
		return int(value.x)
	return 0

func _cell_r(value: Variant) -> int:
	if value is Array and (value as Array).size() > 1:
		return int(value[1])
	if value is Vector2 or value is Vector2i:
		return int(value.y)
	return 0

func _parse_cmdline_kv() -> Dictionary:
	var result: Dictionary = {}
	for raw in OS.get_cmdline_user_args():
		var text := str(raw)
		if not text.begins_with("--"):
			continue
		var body := text.substr(2)
		var split := body.find("=")
		if split < 0:
			result[body] = "true"
		else:
			result[body.substr(0, split)] = body.substr(split + 1)
	return result

func _write_json(path: String, payload: Dictionary) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("Could not open %s" % path)
		return false
	file.store_string(JSON.stringify(payload, "  ") + "\n")
	file.close()
	return true
