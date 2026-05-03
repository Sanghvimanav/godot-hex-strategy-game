extends Node
## Headless entry: dump LLM planning snapshots + metrics for a scenario (no API calls).
## Run: godot --headless --path hex-strategy-game res://tools/headless_planning_pipeline.tscn -- --scenario=drill_llm_vs_llm_scouts_zergling --out=user://pipeline_out
## Args after `--` are read from OS.get_cmdline_user_args() (not get_cmdline_args()).

const _Harness := preload("res://tools/headless_planning_harness.gd")


func _ready() -> void:
	call_deferred("_run_pipeline")


func _run_pipeline() -> void:
	var args: Dictionary = _parse_cmdline_kv()
	var scenario_id: String = str(args.get("scenario", "drill_llm_vs_llm_scouts_zergling"))
	var out_dir: String = str(args.get("out", "user://llm_planning_pipeline"))
	var perspectives_arg: String = str(args.get("perspectives", "all"))

	if Scenarios.get_scenario_by_id(scenario_id).is_empty():
		push_error("Unknown scenario: %s" % scenario_id)
		get_tree().quit(1)
		return

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out_dir))

	var root: Node2D = _Harness.build_battle_root()
	get_tree().root.add_child(root)
	await get_tree().process_frame
	await get_tree().process_frame

	var units: UnitsContainer = _Harness.setup_scenario_on_tree(root, scenario_id)
	await get_tree().process_frame

	var groups: Array[String] = _Harness.list_llm_perspectives(units)
	if groups.is_empty():
		for g in units.groups:
			groups.append(str(g.name))

	var want: Array[String] = []
	if perspectives_arg == "all" or perspectives_arg.is_empty():
		want = groups
	else:
		for p in perspectives_arg.split(",", false):
			var s: String = p.strip_edges()
			if not s.is_empty():
				want.append(s)

	var summary: Dictionary = {
		"scenario_id": scenario_id,
		"turn": units.turn_number,
		"out_dir": out_dir,
		"perspectives": {},
	}

	for gname in want:
		if not gname in groups:
			push_warning("Skipping unknown perspective: %s (available: %s)" % [gname, groups])
			continue
		var snap: Dictionary = _Harness.snapshot_for_group(units, gname)
		var fname: String = "snapshot_turn_%d_%s.json" % [units.turn_number, gname]
		var path: String = out_dir.path_join(fname)
		_write_json(path, snap)
		summary["perspectives"][gname] = _Harness.metrics_from_snapshot(snap)
		print("[pipeline] wrote %s" % path)

	var summary_path: String = out_dir.path_join("summary.json")
	_write_json(summary_path, summary)
	print("[pipeline] wrote %s" % summary_path)

	root.queue_free()
	await get_tree().process_frame
	get_tree().quit(0)


func _parse_cmdline_kv() -> Dictionary:
	var result: Dictionary = {}
	## Args after `--` are exposed via get_cmdline_user_args() (not included in get_cmdline_args()).
	var raw: PackedStringArray = OS.get_cmdline_user_args()
	if raw.is_empty():
		raw = OS.get_cmdline_args()
	var i := 0
	while i < raw.size():
		var a: String = str(raw[i]).strip_edges()
		if a.is_empty():
			i += 1
			continue
		if a.begins_with("--"):
			a = a.substr(2)
		if a.contains("="):
			var parts: PackedStringArray = a.split("=", true, 1)
			result[parts[0]] = parts[1]
		else:
			var next_val: String = ""
			if i + 1 < raw.size() and not str(raw[i + 1]).begins_with("-"):
				next_val = str(raw[i + 1]).strip_edges()
				i += 1
			result[a] = next_val if not next_val.is_empty() else "true"
		i += 1
	return result


func _write_json(path: String, data: Dictionary) -> void:
	var abs_path: String = ProjectSettings.globalize_path(path)
	var f: FileAccess = FileAccess.open(abs_path, FileAccess.WRITE)
	if f == null:
		push_error("Cannot write %s" % abs_path)
		return
	f.store_string(JSON.stringify(data, "  "))
	f.close()
