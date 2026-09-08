extends "res://src/battle/nodes/units/units.gd"
## Thin compatibility layer for interactive Arena playtests. Normal single-player,
## drills, LLM play, multiplayer, and replay behavior continue through the base
## UnitsContainer unchanged.


func apply_scenario(scenario: Dictionary) -> void:
	var arena_variant = scenario.get("arena_playtest", {})
	var arena_enabled := arena_variant is Dictionary and bool((arena_variant as Dictionary).get("enabled", false))
	set_meta("arena_playtest_enabled", arena_enabled)
	super(scenario)
	if arena_enabled:
		_restore_stable_unit_ids(scenario)


func _should_run_llm_batch_for_sp() -> bool:
	if bool(get_meta("arena_playtest_enabled", false)):
		return false
	return super()


func _restore_stable_unit_ids(scenario: Dictionary) -> void:
	# apply_scenario spawns in scenario order. Preserve the Arena IDs so GUI actions,
	# pure-state actions, traces, and future training examples all share one identity.
	for group_variant in scenario.get("groups", []):
		if not (group_variant is Dictionary):
			continue
		var group_spec: Dictionary = group_variant
		var group_node := get_node_or_null(str(group_spec.get("name", "")))
		if group_node == null:
			continue
		var live_units: Array = []
		for child in group_node.get_children():
			if child is Unit:
				live_units.append(child)
		var unit_specs: Array = group_spec.get("units", [])
		var count := mini(live_units.size(), unit_specs.size())
		for index in range(count):
			var spec_variant = unit_specs[index]
			if not (spec_variant is Dictionary):
				continue
			var spec: Dictionary = spec_variant
			if spec.has("unit_id"):
				(live_units[index] as Unit).set_meta("unit_id", int(spec.get("unit_id", 0)))
