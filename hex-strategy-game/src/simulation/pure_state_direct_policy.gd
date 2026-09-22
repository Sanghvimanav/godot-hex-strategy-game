extends RefCounted
class_name PureStateDirectPolicy
## Direct autoregressive neural policy with no search.
##
## At each unit prefix, enumerate the complete legal action set plus an explicit hold,
## score every candidate with the learned joint-plan policy, then sample (training)
## or argmax (evaluation). The simulator remains responsible for all mechanics.

const PureStateLegalActions = preload("res://src/simulation/pure_state_legal_actions.gd")
const PureStateJointPolicy = preload("res://src/simulation/pure_state_joint_policy.gd")


static func choose_plan(
    state: Dictionary,
    group_name: String,
    opponent_group: String,
    checkpoint_path: String,
    seed: int,
    temperature: float = 1.0
) -> Dictionary:
    if checkpoint_path.is_empty():
        return {"valid": false, "error": "checkpoint_required", "actions": [], "prefix_rows": []}
    var units := _alive_units(state, group_name)
    var rng := RandomNumberGenerator.new()
    rng.seed = seed
    var prefix: Array = []
    var submitted: Array = []
    var rows: Array = []

    for unit_variant in units:
        var unit: Dictionary = unit_variant
        var candidates := _planning_actions(state, unit)
        if candidates.is_empty():
            continue
        var scored := PureStateJointPolicy.score_actions(
            state,
            group_name,
            opponent_group,
            prefix,
            candidates,
            {"checkpoint_path": checkpoint_path}
        )
        if not bool(scored.get("ok", false)):
            return {
                "valid": false,
                "error": str(scored.get("error", "policy_scoring_failed")),
                "actions": [],
                "prefix_rows": rows,
            }
        var scores: Array = scored.get("scores", [])
        if scores.size() != candidates.size():
            return {"valid": false, "error": "score_count_mismatch", "actions": [], "prefix_rows": rows}
        var probabilities := _probabilities(scores, temperature)
        var selected_index := _select_index(probabilities, scores, temperature, rng)
        var selected: Dictionary = (candidates[selected_index] as Dictionary).duplicate(true)
        rows.append({
            "state": state.duplicate(true),
            "perspective_group": group_name,
            "opponent_group": opponent_group,
            "prefix_actions": prefix.duplicate(true),
            "candidate_actions": candidates.duplicate(true),
            "selected_index": selected_index,
            "behavior_probability": float(probabilities[selected_index]),
            "policy_entropy": _entropy(probabilities),
        })
        prefix.append(selected.duplicate(true))
        if str(selected.get("action_key", "")) != "<hold>":
            submitted.append(selected.duplicate(true))

    return {
        "valid": true,
        "error": "",
        "actions": submitted,
        "prefix_rows": rows,
    }


static func _alive_units(state: Dictionary, group_name: String) -> Array:
    var result: Array = []
    for group_variant in state.get("groups", []):
        if not (group_variant is Dictionary):
            continue
        var group: Dictionary = group_variant
        if str(group.get("name", "")) != group_name:
            continue
        for unit_variant in group.get("units", []):
            if unit_variant is Dictionary and int((unit_variant as Dictionary).get("health", 0)) > 0:
                result.append((unit_variant as Dictionary).duplicate(true))
    result.sort_custom(func(a, b): return int(a.get("unit_id", -1)) < int(b.get("unit_id", -1)))
    return result


static func _planning_actions(state: Dictionary, unit: Dictionary) -> Array:
    var seen: Dictionary = {}
    var actions: Array = []
    for action_variant in PureStateLegalActions.get_legal_actions(state, int(unit.get("unit_id", -1))):
        if not (action_variant is Dictionary):
            continue
        var action: Dictionary = (action_variant as Dictionary).duplicate(true)
        var signature := _signature(action)
        if seen.has(signature):
            continue
        seen[signature] = true
        actions.append(action)
    var cell_variant = unit.get("cell", [0, 0])
    var cell: Array = (cell_variant as Array).duplicate() if cell_variant is Array else [0, 0]
    var hold := {
        "unit_id": int(unit.get("unit_id", -1)),
        "action_key": "<hold>",
        "path": [],
        "end_point": cell,
    }
    var hold_signature := _signature(hold)
    if not seen.has(hold_signature):
        actions.append(hold)
    actions.sort_custom(func(a, b): return _signature(a) < _signature(b))
    return actions


static func _probabilities(scores: Array, temperature: float) -> Array:
    if scores.is_empty():
        return []
    if temperature <= 0.0:
        var best := _argmax(scores)
        var deterministic: Array = []
        for i in range(scores.size()):
            deterministic.append(1.0 if i == best else 0.0)
        return deterministic
    var maximum := -INF
    for score_variant in scores:
        maximum = maxf(maximum, float(score_variant) / temperature)
    var result: Array = []
    var total := 0.0
    for score_variant in scores:
        var value := exp(float(score_variant) / temperature - maximum)
        result.append(value)
        total += value
    total = maxf(total, 1e-12)
    for i in range(result.size()):
        result[i] = float(result[i]) / total
    return result


static func _select_index(
    probabilities: Array,
    scores: Array,
    temperature: float,
    rng: RandomNumberGenerator
) -> int:
    if temperature <= 0.0:
        return _argmax(scores)
    var draw := rng.randf()
    var cumulative := 0.0
    for i in range(probabilities.size()):
        cumulative += float(probabilities[i])
        if draw <= cumulative:
            return i
    return probabilities.size() - 1


static func _argmax(values: Array) -> int:
    var best_index := 0
    var best_value := -INF
    for i in range(values.size()):
        var value := float(values[i])
        if value > best_value:
            best_value = value
            best_index = i
    return best_index


static func _entropy(probabilities: Array) -> float:
    var result := 0.0
    for probability_variant in probabilities:
        var probability := float(probability_variant)
        if probability > 0.0:
            result -= probability * log(probability)
    return result


static func _signature(action: Dictionary) -> String:
    return "%d|%s|%s|%s" % [
        int(action.get("unit_id", -1)),
        str(action.get("action_key", "")),
        str(action.get("end_point", [])),
        str(action.get("path", [])),
    ]
