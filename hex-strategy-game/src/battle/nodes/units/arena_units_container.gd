extends "res://src/battle/nodes/units/units.gd"
## Thin compatibility layer for interactive Arena playtests. Normal single-player,
## drills, LLM play, multiplayer, and replay behavior continue through the base
## UnitsContainer unchanged.


func apply_scenario(scenario: Dictionary) -> void:
	var arena_variant = scenario.get("arena_playtest", {})
	var arena_enabled := arena_variant is Dictionary and bool((arena_variant as Dictionary).get("enabled", false))
	set_meta("arena_playtest_enabled", arena_enabled)
	set_meta("arena_playtest_ai_variant", str((arena_variant as Dictionary).get("ai_variant", "handwritten")) if arena_variant is Dictionary else "handwritten")
	super(scenario)
	if arena_enabled:
		_restore_stable_unit_ids(scenario)


func _should_run_llm_batch_for_sp() -> bool:
	if _arena_enabled():
		# Reuse the existing single-player batch LLM planner only for the explicit
		# LLM Arena variant. Handwritten and neural variants are planned by the
		# Arena controller through GameplayAI instead.
		return _arena_ai_variant() == "llm" and super()
	return super()


func _get_planning_units_ordered() -> Array:
	var ordered: Array = super()
	if not _arena_enabled():
		return ordered
	var filtered: Array = []
	for unit_variant in ordered:
		if unit_variant is Unit and not _is_forced_no_action(unit_variant as Unit):
			filtered.append(unit_variant)
	return filtered


func _all_units_have_planned_action() -> bool:
	if not _arena_enabled():
		return super()
	var active := _get_planning_units_ordered()
	# The pure-state planner treats an all-stunned living side as one forced empty
	# plan. Let the GUI execute that same empty submission instead of deadlocking.
	if active.is_empty():
		return not get_active_units().is_empty()
	for unit_variant in active:
		if unit_variant is Unit and (unit_variant as Unit).planned_action == null:
			return false
	return true


func _select_planning_unit() -> void:
	if _arena_enabled() and _get_planning_units_ordered().is_empty() and not get_active_units().is_empty():
		current_unit = null
		current_acs = []
		selected_action_key = ""
		_update_highlights()
		EventBus.unit_selected_for_planning.emit(null)
		EventBus.planning_complete.emit()
		return
	super()


func _arena_enabled() -> bool:
	return bool(get_meta("arena_playtest_enabled", false))


func _arena_ai_variant() -> String:
	return str(get_meta("arena_playtest_ai_variant", "handwritten"))


func _is_forced_no_action(unit: Unit) -> bool:
	var disabled: Array = unit.get_disabled_action_types()
	return not disabled.is_empty() and disabled.size() >= Actions.ACTION_ORDER.size()


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
