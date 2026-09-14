extends Node
## Diagnostic for directional generalization of the learned joint-plan policy.
##
## IMPORTANT: engine mechanics are used only after the policy has scored actions to
## label whether an action would hit an enemy. No hit/AOE/damage features are added
## to the policy request. The model receives the exact same state/action inputs as
## normal gameplay.

const PureStateSelfPlaySuite = preload("res://src/simulation/pure_state_self_play_suite.gd")
const PureStateLegalActions = preload("res://src/simulation/pure_state_legal_actions.gd")
const PureStateJointPolicy = preload("res://src/simulation/pure_state_joint_policy.gd")
const TurnExecutionCore = preload("res://src/battle/turn_execution_core.gd")

const SEEN_ROTATIONS := [0, 2, 4]
const HELD_OUT_ROTATIONS := [1, 3, 5]
const ROTATIONS := [0, 1, 2, 3, 4, 5]
const FAMILIES := [
	[1, 1],
	[1, 2],
	[2, 1],
	[2, 2],
	[3, 3],
	[4, 4],
]


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var args := _parse_cmdline_kv()
	var checkpoint := str(args.get("checkpoint", ""))
	var out_path := str(args.get("out", "user://spatial_policy_rotation_diagnostic.json"))
	if checkpoint.is_empty():
		push_error("--checkpoint is required")
		get_tree().quit(1)
		return

	var rows: Array = []
	var ok := true
	for family_variant in FAMILIES:
		var family: Array = family_variant
		var marines := int(family[0])
		var zerglings := int(family[1])
		for rotation_variant in ROTATIONS:
			var rotation := int(rotation_variant)
			var state := _contact_state(marines, zerglings, rotation)
			var terran := _find_group(state, "terran")
			if terran.is_empty() or (terran.get("units", []) as Array).is_empty():
				ok = false
				continue
			var actor: Dictionary = (terran.get("units", []) as Array)[0]
			var unit_id := int(actor.get("unit_id", -1))
			var legal := PureStateLegalActions.get_legal_actions(state, unit_id)
			legal.append({
				"unit_id": unit_id,
				"action_key": "<hold>",
				"path": [],
				"end_point": (actor.get("cell", [0, 0]) as Array).duplicate(),
			})
			var response := PureStateJointPolicy.score_actions(
				state,
				"terran",
				"zerg",
				[],
				legal,
				{"checkpoint_path": checkpoint}
			)
			if not bool(response.get("ok", false)):
				push_error("Policy scoring failed for rotation %d: %s" % [rotation, str(response)])
				ok = false
				continue
			var scores: Array = response.get("scores", [])
			if scores.size() != legal.size():
				push_error("Score/action count mismatch for rotation %d" % rotation)
				ok = false
				continue
			rows.append(_summarize_decision(state, actor, legal, scores, marines, zerglings, rotation))

	var report := {
		"experiment": "spatial_policy_rotation_diagnostic_v1",
		"checkpoint": checkpoint,
		"model_inputs_changed": false,
		"explicit_action_mechanics_added_to_model": false,
		"diagnostic_labels_use_engine_resolution_after_scoring": true,
		"seen_rotations": SEEN_ROTATIONS,
		"held_out_rotations": HELD_OUT_ROTATIONS,
		"families": FAMILIES,
		"rows": rows,
		"by_rotation": _aggregate_by_rotation(rows),
		"seen_vs_held_out": {
			"seen": _aggregate_rows(_filter_rotations(rows, SEEN_ROTATIONS)),
			"held_out": _aggregate_rows(_filter_rotations(rows, HELD_OUT_ROTATIONS)),
		},
	}
	var wrote := _write_json(out_path, report)
	print(JSON.stringify(report))
	PureStateJointPolicy.shutdown()
	get_tree().quit(0 if ok and wrote else 1)


func _contact_state(marines: int, zerglings: int, rotation: int) -> Dictionary:
	# Start from the real radius-one curriculum state, but move the Zerg stack one
	# hex toward Terran so attack_short has a direct-hit direction. This isolates
	# directional grounding from multi-turn search and preserves the same unit defs.
	var state := PureStateSelfPlaySuite.basic_state(marines, zerglings, 0, 8, "", false)
	var zerg := _find_group(state, "zerg")
	for unit_variant in zerg.get("units", []):
		if unit_variant is Dictionary:
			(unit_variant as Dictionary)["cell"] = [0, 0]
	state = PureStateSelfPlaySuite.rotate_state(state, rotation)
	state["turn_index"] = 1
	state["scenario_id"] = "rotation_diag_m%d_z%d_r%d" % [marines, zerglings, rotation]
	return state


func _summarize_decision(
	state: Dictionary,
	actor: Dictionary,
	legal: Array,
	scores: Array,
	marines: int,
	zerglings: int,
	rotation: int
) -> Dictionary:
	var maximum := -INF
	for score_variant in scores:
		maximum = maxf(maximum, float(score_variant))
	var normalizer := 0.0
	for score_variant in scores:
		normalizer += exp(float(score_variant) - maximum)

	var ranked: Array = []
	for i in range(legal.size()):
		var action: Dictionary = legal[i]
		var probability := exp(float(scores[i]) - maximum) / maxf(normalizer, 1e-12)
		var labels := _label_action(state, actor, action)
		ranked.append({
			"action": action.duplicate(true),
			"score": float(scores[i]),
			"probability": probability,
			"is_attack_short": str(action.get("action_key", "")) == "attack_short",
			"direct_target_hits_enemy": bool(labels.get("direct_target_hits_enemy", false)),
			"damage_footprint_hits_enemy": bool(labels.get("damage_footprint_hits_enemy", false)),
			"damage_cells": labels.get("damage_cells", []),
		})
	ranked.sort_custom(func(a, b): return float(a.get("score", 0.0)) > float(b.get("score", 0.0)))

	var attack_ranked: Array = []
	for row_variant in ranked:
		if row_variant is Dictionary and bool((row_variant as Dictionary).get("is_attack_short", false)):
			attack_ranked.append(row_variant)

	var best_direct_rank := _first_true_rank(ranked, "direct_target_hits_enemy")
	var best_footprint_rank := _first_true_rank(ranked, "damage_footprint_hits_enemy")
	var best_direct_attack_rank := _first_true_rank(attack_ranked, "direct_target_hits_enemy")
	var best_footprint_attack_rank := _first_true_rank(attack_ranked, "damage_footprint_hits_enemy")
	var direct_probability_mass := _probability_mass(ranked, "direct_target_hits_enemy")
	var footprint_probability_mass := _probability_mass(ranked, "damage_footprint_hits_enemy")
	var attack_probability_mass := 0.0
	var direct_attack_probability_mass := 0.0
	var footprint_attack_probability_mass := 0.0
	for row_variant in attack_ranked:
		var row: Dictionary = row_variant
		var p := float(row.get("probability", 0.0))
		attack_probability_mass += p
		if bool(row.get("direct_target_hits_enemy", false)):
			direct_attack_probability_mass += p
		if bool(row.get("damage_footprint_hits_enemy", false)):
			footprint_attack_probability_mass += p

	var best_direct_score := _best_true_score(ranked, "direct_target_hits_enemy")
	var best_miss_attack_score := _best_false_attack_score(attack_ranked, "damage_footprint_hits_enemy")
	var top: Dictionary = ranked[0] if not ranked.is_empty() else {}
	var top_attack: Dictionary = attack_ranked[0] if not attack_ranked.is_empty() else {}
	return {
		"family": "m%d_z%d" % [marines, zerglings],
		"marines": marines,
		"zerglings": zerglings,
		"rotation": rotation,
		"split": "seen" if rotation in SEEN_ROTATIONS else "held_out",
		"actor_cell": (actor.get("cell", []) as Array).duplicate(),
		"legal_action_count": legal.size(),
		"attack_short_count": attack_ranked.size(),
		"top1_action_key": str(top.get("action", {}).get("action_key", "")) if top.has("action") else "",
		"top1_direct_hit": bool(top.get("direct_target_hits_enemy", false)),
		"top1_footprint_hit": bool(top.get("damage_footprint_hits_enemy", false)),
		"top1_attack_direct_hit": bool(top_attack.get("direct_target_hits_enemy", false)),
		"top1_attack_footprint_hit": bool(top_attack.get("damage_footprint_hits_enemy", false)),
		"best_direct_hit_overall_rank": best_direct_rank,
		"best_footprint_hit_overall_rank": best_footprint_rank,
		"best_direct_hit_attack_rank": best_direct_attack_rank,
		"best_footprint_hit_attack_rank": best_footprint_attack_rank,
		"direct_hit_probability_mass": direct_probability_mass,
		"footprint_hit_probability_mass": footprint_probability_mass,
		"attack_probability_mass": attack_probability_mass,
		"direct_hit_probability_given_attack": direct_attack_probability_mass / maxf(attack_probability_mass, 1e-12),
		"footprint_hit_probability_given_attack": footprint_attack_probability_mass / maxf(attack_probability_mass, 1e-12),
		"best_direct_hit_minus_best_miss_attack_logit": best_direct_score - best_miss_attack_score if is_finite(best_direct_score) and is_finite(best_miss_attack_score) else null,
		"ranked_actions": ranked,
	}


func _label_action(state: Dictionary, actor: Dictionary, action: Dictionary) -> Dictionary:
	var action_key := str(action.get("action_key", ""))
	if action_key != "attack_short":
		return {
			"direct_target_hits_enemy": false,
			"damage_footprint_hits_enemy": false,
			"damage_cells": [],
		}
	var config: Dictionary = Actions.get_action_config(action_key)
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
		if not (unit_variant is Dictionary):
			continue
		var unit: Dictionary = unit_variant
		if int(unit.get("health", 0)) <= 0:
			continue
		var cell: Array = unit.get("cell", [0, 0])
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
		result[str(rotation)] = _aggregate_rows(_filter_rotations(rows, [rotation]))
	return result


func _aggregate_rows(rows: Array) -> Dictionary:
	if rows.is_empty():
		return {"rows": 0}
	var top1_direct := 0
	var top1_footprint := 0
	var top1_attack_direct := 0
	var top1_attack_footprint := 0
	var direct_mass := 0.0
	var footprint_mass := 0.0
	var direct_given_attack := 0.0
	var footprint_given_attack := 0.0
	var direct_rank_sum := 0.0
	var direct_rank_count := 0
	var margin_sum := 0.0
	var margin_count := 0
	for row_variant in rows:
		var row: Dictionary = row_variant
		if bool(row.get("top1_direct_hit", false)):
			top1_direct += 1
		if bool(row.get("top1_footprint_hit", false)):
			top1_footprint += 1
		if bool(row.get("top1_attack_direct_hit", false)):
			top1_attack_direct += 1
		if bool(row.get("top1_attack_footprint_hit", false)):
			top1_attack_footprint += 1
		direct_mass += float(row.get("direct_hit_probability_mass", 0.0))
		footprint_mass += float(row.get("footprint_hit_probability_mass", 0.0))
		direct_given_attack += float(row.get("direct_hit_probability_given_attack", 0.0))
		footprint_given_attack += float(row.get("footprint_hit_probability_given_attack", 0.0))
		var rank := int(row.get("best_direct_hit_attack_rank", 0))
		if rank > 0:
			direct_rank_sum += rank
			direct_rank_count += 1
		var margin = row.get("best_direct_hit_minus_best_miss_attack_logit", null)
		if margin is float or margin is int:
			margin_sum += float(margin)
			margin_count += 1
	var n := float(rows.size())
	return {
		"rows": rows.size(),
		"top1_direct_hit_rate": top1_direct / n,
		"top1_footprint_hit_rate": top1_footprint / n,
		"top1_attack_direct_hit_rate": top1_attack_direct / n,
		"top1_attack_footprint_hit_rate": top1_attack_footprint / n,
		"mean_direct_hit_probability_mass": direct_mass / n,
		"mean_footprint_hit_probability_mass": footprint_mass / n,
		"mean_direct_hit_probability_given_attack": direct_given_attack / n,
		"mean_footprint_hit_probability_given_attack": footprint_given_attack / n,
		"mean_best_direct_hit_attack_rank": direct_rank_sum / maxf(float(direct_rank_count), 1.0),
		"mean_direct_hit_vs_miss_attack_logit_margin": margin_sum / maxf(float(margin_count), 1.0),
	}


func _filter_rotations(rows: Array, rotations: Array) -> Array:
	var result: Array = []
	for row_variant in rows:
		if row_variant is Dictionary and int((row_variant as Dictionary).get("rotation", -1)) in rotations:
			result.append(row_variant)
	return result


func _first_true_rank(rows: Array, key: String) -> int:
	for i in range(rows.size()):
		var row_variant = rows[i]
		if row_variant is Dictionary and bool((row_variant as Dictionary).get(key, false)):
			return i + 1
	return 0


func _probability_mass(rows: Array, key: String) -> float:
	var total := 0.0
	for row_variant in rows:
		if row_variant is Dictionary and bool((row_variant as Dictionary).get(key, false)):
			total += float((row_variant as Dictionary).get("probability", 0.0))
	return total


func _best_true_score(rows: Array, key: String) -> float:
	var best := -INF
	for row_variant in rows:
		if row_variant is Dictionary and bool((row_variant as Dictionary).get(key, false)):
			best = maxf(best, float((row_variant as Dictionary).get("score", -INF)))
	return best


func _best_false_attack_score(rows: Array, key: String) -> float:
	var best := -INF
	for row_variant in rows:
		if not (row_variant is Dictionary):
			continue
		var row: Dictionary = row_variant
		if bool(row.get("is_attack_short", false)) and not bool(row.get(key, false)):
			best = maxf(best, float(row.get("score", -INF)))
	return best


func _find_group(state: Dictionary, group_name: String) -> Dictionary:
	for group_variant in state.get("groups", []):
		if group_variant is Dictionary and str((group_variant as Dictionary).get("name", "")) == group_name:
			return group_variant as Dictionary
	return {}


func _cell_q(value: Variant) -> int:
	if value is Array and (value as Array).size() >= 1:
		return int(value[0])
	if value is Vector2 or value is Vector2i:
		return int(value.x)
	return 0


func _cell_r(value: Variant) -> int:
	if value is Array and (value as Array).size() >= 2:
		return int(value[1])
	if value is Vector2 or value is Vector2i:
		return int(value.y)
	return 0


func _write_json(path: String, value: Variant) -> bool:
	var abs_path := ProjectSettings.globalize_path(path)
	var base_dir := abs_path.get_base_dir()
	if DirAccess.make_dir_recursive_absolute(base_dir) != OK:
		push_error("Unable to create output directory: %s" % base_dir)
		return false
	var file := FileAccess.open(abs_path, FileAccess.WRITE)
	if file == null:
		push_error("Unable to write %s" % abs_path)
		return false
	file.store_string(JSON.stringify(value, "  ") + "\n")
	file.close()
	return true


func _parse_cmdline_kv() -> Dictionary:
	var result: Dictionary = {}
	var raw: PackedStringArray = OS.get_cmdline_user_args()
	if raw.is_empty():
		raw = OS.get_cmdline_args()
	var i := 0
	while i < raw.size():
		var arg := str(raw[i]).strip_edges()
		if arg.begins_with("--"):
			arg = arg.substr(2)
		if arg.contains("="):
			var parts := arg.split("=", true, 1)
			result[parts[0]] = parts[1]
		elif not arg.is_empty():
			var next_value := ""
			if i + 1 < raw.size() and not str(raw[i + 1]).begins_with("-"):
				next_value = str(raw[i + 1]).strip_edges()
				i += 1
			result[arg] = next_value if not next_value.is_empty() else "true"
		i += 1
	return result
