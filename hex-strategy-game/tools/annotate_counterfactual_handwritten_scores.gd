extends SceneTree
## Annotate counterfactual sample states with scores from the real PureStateEvaluator.
## Python ranking metrics consume only these annotations for real gameplay states.

const PureStateEvaluator = preload("res://src/simulation/pure_state_evaluator.gd")

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 2:
		push_error("usage: -- <candidates.jsonl> <annotated.jsonl>")
		quit(2)
		return
	var input_path := str(args[0])
	var output_path := str(args[1])
	var input := FileAccess.open(input_path, FileAccess.READ)
	if input == null:
		push_error("cannot open input: %s" % input_path)
		quit(2)
		return
	var output := FileAccess.open(output_path, FileAccess.WRITE)
	if output == null:
		push_error("cannot open output: %s" % output_path)
		quit(2)
		return

	var fingerprint := _evaluator_fingerprint()
	var rows := 0
	var states := 0
	while not input.eof_reached():
		var line := input.get_line().strip_edges()
		if line.is_empty():
			continue
		var row_variant = JSON.parse_string(line)
		if not (row_variant is Dictionary):
			continue
		var row: Dictionary = row_variant
		var perspective := str(row.get("perspective_group", ""))
		var samples_variant = row.get("samples", [])
		if samples_variant is Array:
			var samples: Array = samples_variant
			for index in range(samples.size()):
				var sample_variant = samples[index]
				if not (sample_variant is Dictionary):
					continue
				var sample: Dictionary = sample_variant
				var state_variant = sample.get("state_after_first_turn", {})
				if not (state_variant is Dictionary):
					continue
				var state: Dictionary = state_variant
				state["_godot_handwritten_evaluator_score"] = PureStateEvaluator.evaluate(state, perspective)
				sample["state_after_first_turn"] = state
				samples[index] = sample
				states += 1
			row["samples"] = samples
		row["handwritten_evaluator_fingerprint"] = fingerprint
		output.store_line(JSON.stringify(row))
		rows += 1

	input.close()
	output.close()
	print("annotated %d rows / %d states; fingerprint=%s" % [rows, states, fingerprint])
	quit(0)


func _evaluator_fingerprint() -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	for path in [
		"res://src/simulation/pure_state_evaluator.gd",
		"res://src/simulation/pure_state_command_hex_rules.gd",
	]:
		var file := FileAccess.open(path, FileAccess.READ)
		if file == null:
			continue
		ctx.update(file.get_buffer(file.get_length()))
		file.close()
	return ctx.finish().hex_encode()
