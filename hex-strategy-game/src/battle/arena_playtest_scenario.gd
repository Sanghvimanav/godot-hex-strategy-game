extends RefCounted
class_name ArenaPlaytestScenario
## Adapts the canonical pure-state Arena suite into the existing local battle scene.
## The pure-state starting state is preserved verbatim in arena_playtest metadata so
## the interactive controller and training exporter can stay aligned with headless Arena.

const PureStateArenaSuite = preload("res://src/simulation/pure_state_arena_suite.gd")

const DEFAULT_PRESET := "fast"
const DEFAULT_AGENT_PROFILE := "fast"
const DEFAULT_EVALUATOR := "handwritten"


static func available_seeds() -> Array[int]:
	var seeds: Array[int] = []
	for raw_seed in PureStateArenaSuite.FAST_SEEDS:
		seeds.append(int(raw_seed))
	return seeds


static func available_agent_profiles() -> Array[String]:
	return ["fast", "balanced", "wide", "broad"]


static func build(
	scenario_seed: int,
	human_group: String = "terran",
	agent_profile: String = DEFAULT_AGENT_PROFILE,
	map_profile: String = PureStateArenaSuite.DEFAULT_MAP_PROFILE,
	preset: String = DEFAULT_PRESET
) -> Dictionary:
	if human_group not in ["terran", "zerg"]:
		return {}
	if agent_profile not in available_agent_profiles():
		return {}
	if map_profile not in PureStateArenaSuite.available_map_profiles():
		return {}

	var pure_state := PureStateArenaSuite.build_generated_state(scenario_seed, preset, map_profile)
	if pure_state.is_empty():
		return {}
	var arena_metadata: Dictionary = (pure_state.get("arena_metadata", {}) as Dictionary).duplicate(true)
	var family := str(arena_metadata.get("base_scenario_id", "arena"))
	var max_turns := int(PureStateArenaSuite.FAMILY_MAX_TURNS.get(family, 10)) + PureStateArenaSuite.ARENA_TURN_ALLOWANCE
	var live_groups: Array = []
	for group_variant in pure_state.get("groups", []):
		if not (group_variant is Dictionary):
			continue
		var pure_group: Dictionary = group_variant
		var group_name := str(pure_group.get("name", ""))
		var live_group := {
			"name": group_name,
			"ai": group_name != human_group,
			"resources": (pure_group.get("resources", {}) as Dictionary).duplicate(true),
			"units": [],
		}
		for unit_variant in pure_group.get("units", []):
			if not (unit_variant is Dictionary):
				continue
			var unit_spec: Dictionary = (unit_variant as Dictionary).duplicate(true)
			unit_spec["cell"] = _cell_to_vector2i(unit_spec.get("cell", [0, 0]))
			live_group.units.append(unit_spec)
		live_groups.append(live_group)

	var scenario_id := "arena_playtest_s%d_%s" % [scenario_seed, agent_profile]
	return {
		"id": scenario_id,
		"display_name": "Arena: %s — seed %d" % [_pretty_family(family), scenario_seed],
		"category": "arena",
		"description": (
			"Human vs canonical GameplayAI with the handwritten evaluator (%s profile). "
			+ "Win by elimination or by occupying the enemy command hex through one complete turn. "
			+ "The AI chooses from the same hidden pre-turn state as you. Playtest traces and training-ready examples are saved locally."
		) % agent_profile,
		"hex_radius": int(pure_state.get("hex_radius", 5)),
		"groups": live_groups,
		"tile_resources": (pure_state.get("tile_resources", {}) as Dictionary).duplicate(true),
		"arena_playtest": {
			"enabled": true,
			"preset": preset,
			"suite_version": PureStateArenaSuite.SUITE_VERSION,
			"scenario_seed": scenario_seed,
			"base_scenario_id": family,
			"map_profile": map_profile,
			"agent_profile": agent_profile,
			"evaluator": DEFAULT_EVALUATOR,
			"max_turns": max_turns,
			"arena_metadata": arena_metadata,
			"initial_state": pure_state.duplicate(true),
		},
	}


static func _cell_to_vector2i(value: Variant) -> Vector2i:
	if value is Vector2i:
		return value
	if value is Vector2:
		return Vector2i(int(value.x), int(value.y))
	if value is Array and value.size() >= 2:
		return Vector2i(int(value[0]), int(value[1]))
	return Vector2i.ZERO


static func _pretty_family(value: String) -> String:
	return value.replace("_", " ").capitalize()
