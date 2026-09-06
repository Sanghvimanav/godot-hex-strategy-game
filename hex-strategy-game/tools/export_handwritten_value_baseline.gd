extends SceneTree
## Export scores from the real PureStateEvaluator for held-out examples.
##
## This script exists so Python training/metrics never need a second evaluator
## implementation. The output includes a fingerprint derived from the evaluator
## source plus the command-objective rules that materially affect its score.

const PureStateEvaluator = preload("res://src/simulation/pure_state_evaluator.gd")

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 2:
		push_error("usage: -- <examples.jsonl> <baseline.json>")
		quit(2)
		return
	var input_path := str(args[0])
	var output_path := str(args[1])
	var input := FileAccess.open(input_path, FileAccess.READ)
	if input == null:
		push_error("cannot open input: %s" % input_path)
		quit(2)
		return
	var scores: Array = []
	while not input.eof_reached():
		var line := input.get_line().strip_edges()
		if line.is_empty():
			continue
		var example_variant = JSON.parse_string(line)
		if not (example_variant is Dictionary):
			continue
		var example: Dictionary = example_variant
		if bool(example.get("terminal", false)):
			continue
		var state_variant = example.get("state", {})
		if not (state_variant is Dictionary):
			continue
		var perspective := str(example.get("perspective_group", ""))
		scores.append(PureStateEvaluator.evaluate(state_variant, perspective))
	input.close()

	var fingerprint := _evaluator_fingerprint()
	var payload := {
		"evaluator_fingerprint": fingerprint,
		"scores": scores,
	}
	var output := FileAccess.open(output_path, FileAccess.WRITE)
	if output == null:
		push_error("cannot open output: %s" % output_path)
		quit(2)
		return
	output.store_string(JSON.stringify(payload, "  "))
	output.close()
	print("exported %d handwritten scores; fingerprint=%s" % [scores.size(), fingerprint])
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
