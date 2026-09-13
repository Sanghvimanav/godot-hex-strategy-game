extends Node
## Integration smoke check using a training capture and a proposal checkpoint.
const NeuralPlans = preload("res://src/simulation/pure_state_neural_plans.gd")
const JointPolicy = preload("res://src/simulation/pure_state_joint_policy.gd")
const LegalActions = preload("res://src/simulation/pure_state_legal_actions.gd")

func _ready() -> void:
	var args := {}
	for arg in OS.get_cmdline_user_args():
		var parts := arg.split("=", true, 1)
		if parts.size() == 2:
			args[parts[0].trim_prefix("--")] = parts[1]
	var file := FileAccess.open(str(args.get("decisions", "")), FileAccess.READ)
	if file == null:
		get_tree().quit(1)
		return
	var row: Dictionary = JSON.parse_string(file.get_line())
	var state: Dictionary = row["starting_state"]
	var plans := NeuralPlans.get_candidate_plans(state, row["perspective_group"], row["opponent_group"], 8, 4, {"checkpoint_path": args.get("checkpoint", "")})
	var valid := not plans.is_empty()
	for plan in plans:
		for action in plan["actions"]:
			valid = valid and LegalActions.get_legal_actions(state, int(action["unit_id"])).has(action)
	print("[learned-proposals] plans=%d legal=%s runtime_error=%s" % [plans.size(), str(valid), JointPolicy.last_error()])
	JointPolicy.shutdown()
	get_tree().quit(0 if valid else 1)
