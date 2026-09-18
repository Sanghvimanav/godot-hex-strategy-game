extends Node

const PureStateSelfPlaySuite = preload("res://src/simulation/pure_state_self_play_suite.gd")
const PureStateLegalActions = preload("res://src/simulation/pure_state_legal_actions.gd")
const PureStateSimulator = preload("res://src/simulation/pure_state_simulator.gd")
const PureStateNeuralEvaluator = preload("res://src/simulation/pure_state_neural_evaluator.gd")
const PureStateJointPolicy = preload("res://src/simulation/pure_state_joint_policy.gd")

const ROTATIONS := [0, 1, 2, 3, 4, 5]

func _ready() -> void:
    call_deferred("_run")

func _run() -> void:
    var args := _parse_cmdline_kv()
    var checkpoint := str(args.get("checkpoint", ""))
    var out_path := str(args.get("out", "user://mcts_rollout_q_diagnostic.json"))
    if checkpoint.is_empty():
        push_error("--checkpoint is required")
        get_tree().quit(1)
        return

    var rotations: Array = []
    for rotation_variant in ROTATIONS:
        var rotation := int(rotation_variant)
        rotations.append(_analyze_rotation(rotation, checkpoint))

    var report := {
        "experiment": "mcts_rollout_q_decomposition_v1",
        "checkpoint": checkpoint,
        "rotations": rotations,
        "overall": _aggregate(rotations),
        "notes": {
            "action_order": ["fast move", "fast ability", "move", "ability", "slow move", "slow ability", "spawn"],
            "synthetic_damage_test": "same state and positions; only zerg health changes from 3 to 2",
            "response_matrix": "one real simultaneous turn for every marine attack_short x every zerg planning response including hold",
        },
    }
    var file := FileAccess.open(out_path, FileAccess.WRITE)
    if file == null:
        push_error("Could not open " + out_path)
        get_tree().quit(1)
        return
    file.store_string(JSON.stringify(report, "  ") + "\n")
    file.close()
    print(JSON.stringify(report))
    PureStateJointPolicy.shutdown()
    PureStateNeuralEvaluator.shutdown()
    get_tree().quit(0)

func _analyze_rotation(rotation: int, checkpoint: String) -> Dictionary:
    var state := _contact_state(rotation)
    var marine := _first_unit(state, "terran")
    var zerg := _first_unit(state, "zerg")
    var base_eval := _value(state, checkpoint)

    var damaged_state := state.duplicate(true)
    var damaged_zerg := _first_unit(damaged_state, "zerg")
    damaged_zerg["health"] = maxi(0, int(damaged_zerg.get("health", 3)) - 1)
    var damaged_eval := _value(damaged_state, checkpoint)

    var marine_actions: Array = []
    for action_variant in PureStateLegalActions.get_legal_actions(state, int(marine.get("unit_id", -1))):
        if action_variant is Dictionary and str((action_variant as Dictionary).get("action_key", "")) == "attack_short":
            marine_actions.append((action_variant as Dictionary).duplicate(true))

    var zerg_responses := _planning_actions(state, zerg)
    var response_probs := _policy_probabilities(state, "zerg", "terran", zerg_responses, checkpoint)

    var rows: Array = []
    for attack_variant in marine_actions:
        var attack: Dictionary = attack_variant
        for response_index in range(zerg_responses.size()):
            var response: Dictionary = zerg_responses[response_index]
            var submitted_zerg: Array = []
            if str(response.get("action_key", "")) != "<hold>":
                submitted_zerg.append(response.duplicate(true))
            var sim := PureStateSimulator.simulate_turn(
                state,
                {
                    "terran": [attack.duplicate(true)],
                    "zerg": submitted_zerg,
                }
            )
            var next_state: Dictionary = (sim.get("next_state", {}) as Dictionary).duplicate(true)
            next_state["turn_index"] = int(state.get("turn_index", 0)) + 1
            var next_zerg := _first_unit(next_state, "zerg")
            var next_marine := _first_unit(next_state, "terran")
            var zerg_hp := int(next_zerg.get("health", 0)) if not next_zerg.is_empty() else 0
            var marine_hp := int(next_marine.get("health", 0)) if not next_marine.is_empty() else 0
            var next_eval := _value(next_state, checkpoint)
            rows.append({
                "attack_end": (attack.get("end_point", []) as Array).duplicate(),
                "response_action_key": str(response.get("action_key", "")),
                "response_end": (response.get("end_point", []) as Array).duplicate(),
                "response_probability": float(response_probs[response_index]) if response_index < response_probs.size() else 0.0,
                "zerg_start_hp": int(zerg.get("health", 0)),
                "zerg_end_hp": zerg_hp,
                "zerg_damage": int(zerg.get("health", 0)) - zerg_hp,
                "marine_start_hp": int(marine.get("health", 0)),
                "marine_end_hp": marine_hp,
                "marine_damage": int(marine.get("health", 0)) - marine_hp,
                "immediate_value": next_eval,
            })

    return {
        "rotation": rotation,
        "marine_cell": (marine.get("cell", []) as Array).duplicate(),
        "zerg_cell": (zerg.get("cell", []) as Array).duplicate(),
        "base_value": base_eval,
        "synthetic_minus_1hp_value": damaged_eval,
        "synthetic_damage_value_delta": damaged_eval - base_eval,
        "zerg_response_count": zerg_responses.size(),
        "response_probabilities": _response_prob_summary(zerg_responses, response_probs),
        "matrix": rows,
        "matrix_summary": _matrix_summary(rows),
    }

func _contact_state(rotation: int) -> Dictionary:
    var state := PureStateSelfPlaySuite.basic_state(1, 1, 0, 8, "", false)
    var zerg := _first_unit(state, "zerg")
    zerg["cell"] = [0, 0]
    state = PureStateSelfPlaySuite.rotate_state(state, rotation)
    state["turn_index"] = 1
    state["scenario_id"] = "mcts_rollout_q_diag_r%d" % rotation
    return state

func _planning_actions(state: Dictionary, unit: Dictionary) -> Array:
    var result: Array = []
    var seen: Dictionary = {}
    for action_variant in PureStateLegalActions.get_legal_actions(state, int(unit.get("unit_id", -1))):
        if not (action_variant is Dictionary):
            continue
        var action: Dictionary = (action_variant as Dictionary).duplicate(true)
        var sig := _signature(action)
        if not seen.has(sig):
            seen[sig] = true
            result.append(action)
    var cell: Array = unit.get("cell", [0, 0])
    var hold := {
        "unit_id": int(unit.get("unit_id", -1)),
        "action_key": "<hold>",
        "path": [],
        "end_point": cell.duplicate(),
    }
    if not seen.has(_signature(hold)):
        result.append(hold)
    return result

func _policy_probabilities(state: Dictionary, group_name: String, opponent_name: String, actions: Array, checkpoint: String) -> Array:
    var scored := PureStateJointPolicy.score_actions(
        state, group_name, opponent_name, [], actions, {"checkpoint_path": checkpoint}
    )
    if not bool(scored.get("ok", false)):
        var uniform := 1.0 / float(maxi(1, actions.size()))
        return Array(actions.map(func(_x): return uniform))
    return _softmax(scored.get("scores", []))

func _value(state: Dictionary, checkpoint: String) -> float:
    var e := PureStateNeuralEvaluator.evaluate_breakdown(
        state, "terran", "zerg", {"checkpoint_path": checkpoint}
    )
    if not bool(e.get("valid", false)):
        return NAN
    return float(e.get("model_value", 0.0))

func _matrix_summary(rows: Array) -> Dictionary:
    var by_attack: Dictionary = {}
    for row_variant in rows:
        var row: Dictionary = row_variant
        var key := str(row.get("attack_end", []))
        if not by_attack.has(key):
            by_attack[key] = {
                "attack_end": row.get("attack_end", []),
                "responses": 0,
                "damage_responses": 0,
                "sum_damage": 0.0,
                "sum_value": 0.0,
                "weighted_damage": 0.0,
                "weighted_value": 0.0,
                "weight": 0.0,
                "hold_damage": NAN,
                "hold_value": NAN,
            }
        var item: Dictionary = by_attack[key]
        item["responses"] = int(item["responses"]) + 1
        var damage := float(row.get("zerg_damage", 0))
        if damage > 0.0:
            item["damage_responses"] = int(item["damage_responses"]) + 1
        item["sum_damage"] = float(item["sum_damage"]) + damage
        item["sum_value"] = float(item["sum_value"]) + float(row.get("immediate_value", 0.0))
        var w := float(row.get("response_probability", 0.0))
        item["weighted_damage"] = float(item["weighted_damage"]) + w * damage
        item["weighted_value"] = float(item["weighted_value"]) + w * float(row.get("immediate_value", 0.0))
        item["weight"] = float(item["weight"]) + w
        if str(row.get("response_action_key", "")) == "<hold>":
            item["hold_damage"] = damage
            item["hold_value"] = float(row.get("immediate_value", 0.0))
        by_attack[key] = item

    var result: Array = []
    for key_variant in by_attack.keys():
        var item: Dictionary = by_attack[key_variant]
        var n := float(maxi(1, int(item["responses"])))
        var w := maxf(1e-12, float(item["weight"]))
        result.append({
            "attack_end": item["attack_end"],
            "response_count": int(item["responses"]),
            "damage_response_rate": float(item["damage_responses"]) / n,
            "uniform_mean_damage": float(item["sum_damage"]) / n,
            "uniform_mean_immediate_value": float(item["sum_value"]) / n,
            "policy_weighted_mean_damage": float(item["weighted_damage"]) / w,
            "policy_weighted_mean_immediate_value": float(item["weighted_value"]) / w,
            "hold_damage": item["hold_damage"],
            "hold_immediate_value": item["hold_value"],
        })
    result.sort_custom(func(a, b): return str(a.get("attack_end", [])) < str(b.get("attack_end", [])))
    return {"attacks": result}

func _aggregate(rotations: Array) -> Dictionary:
    var synthetic_delta := 0.0
    var synthetic_n := 0
    var all_attack_rows: Array = []
    for rotation_variant in rotations:
        var rotation: Dictionary = rotation_variant
        var d := float(rotation.get("synthetic_damage_value_delta", NAN))
        if is_finite(d):
            synthetic_delta += d
            synthetic_n += 1
        var summary: Dictionary = rotation.get("matrix_summary", {})
        for attack_variant in summary.get("attacks", []):
            all_attack_rows.append(attack_variant)
    var hold_values_damage: Array = []
    var hold_values_miss: Array = []
    var weighted_damage: Array = []
    var weighted_value: Array = []
    for row_variant in all_attack_rows:
        var row: Dictionary = row_variant
        var hd := float(row.get("hold_damage", NAN))
        var hv := float(row.get("hold_immediate_value", NAN))
        if is_finite(hd) and is_finite(hv):
            if hd > 0.0:
                hold_values_damage.append(hv)
            else:
                hold_values_miss.append(hv)
        weighted_damage.append(float(row.get("policy_weighted_mean_damage", 0.0)))
        weighted_value.append(float(row.get("policy_weighted_mean_immediate_value", 0.0)))
    return {
        "mean_synthetic_minus_1hp_value_delta": synthetic_delta / float(maxi(1, synthetic_n)),
        "mean_hold_value_when_attack_damages": _mean(hold_values_damage),
        "mean_hold_value_when_attack_misses": _mean(hold_values_miss),
        "hold_damage_value_margin": _mean(hold_values_damage) - _mean(hold_values_miss),
        "policy_weighted_attack_damage_range": [_min(weighted_damage), _max(weighted_damage)],
        "policy_weighted_immediate_value_range": [_min(weighted_value), _max(weighted_value)],
    }

func _response_prob_summary(actions: Array, probs: Array) -> Array:
    var result: Array = []
    for i in range(actions.size()):
        var action: Dictionary = actions[i]
        result.append({
            "action_key": str(action.get("action_key", "")),
            "end_point": (action.get("end_point", []) as Array).duplicate(),
            "probability": float(probs[i]) if i < probs.size() else 0.0,
        })
    return result

func _first_unit(state: Dictionary, group_name: String) -> Dictionary:
    for group_variant in state.get("groups", []):
        if group_variant is Dictionary and str((group_variant as Dictionary).get("name", "")) == group_name:
            var units: Array = (group_variant as Dictionary).get("units", [])
            if not units.is_empty() and units[0] is Dictionary:
                return units[0] as Dictionary
    return {}

func _softmax(scores: Array) -> Array:
    if scores.is_empty():
        return []
    var maximum := -INF
    for score_variant in scores:
        maximum = maxf(maximum, float(score_variant))
    var out: Array = []
    var total := 0.0
    for score_variant in scores:
        var v := exp(float(score_variant) - maximum)
        out.append(v)
        total += v
    for i in range(out.size()):
        out[i] = float(out[i]) / maxf(total, 1e-12)
    return out

func _signature(action: Dictionary) -> String:
    return "%s|%s|%s" % [str(action.get("unit_id", -1)), str(action.get("action_key", "")), str(action.get("end_point", []))]

func _mean(values: Array) -> float:
    if values.is_empty():
        return NAN
    var total := 0.0
    for v in values:
        total += float(v)
    return total / float(values.size())

func _min(values: Array) -> float:
    if values.is_empty():
        return NAN
    var result := INF
    for v in values:
        result = minf(result, float(v))
    return result

func _max(values: Array) -> float:
    if values.is_empty():
        return NAN
    var result := -INF
    for v in values:
        result = maxf(result, float(v))
    return result

func _parse_cmdline_kv() -> Dictionary:
    var result: Dictionary = {}
    for raw in OS.get_cmdline_user_args():
        var s := str(raw)
        if not s.begins_with("--"):
            continue
        var body := s.substr(2)
        var p := body.find("=")
        if p < 0:
            result[body] = "true"
        else:
            result[body.substr(0, p)] = body.substr(p + 1)
    return result
