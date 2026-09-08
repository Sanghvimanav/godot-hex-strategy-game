extends RefCounted
class_name ArenaPlaytestScenario
## Adapts the canonical pure-state Arena suite into the existing local battle scene.
## The pure-state starting state is preserved verbatim in arena_playtest metadata so
## the interactive controller and training exporter can stay aligned with headless Arena.

const PureStateArenaSuite = preload("res://src/simulation/pure_state_arena_suite.gd")
const PureStateNeuralEvaluator = preload("res://src/simulation/pure_state_neural_evaluator.gd")
const PureStateCommandHexRules = preload("res://src/simulation/pure_state_command_hex_rules.gd")

const DEFAULT_PRESET := "fast"
const DEFAULT_AGENT_PROFILE := "fast"
const AI_VARIANT_HANDWRITTEN := "handwritten"
const AI_VARIANT_NEURAL := "neural"
const AI_VARIANT_LLM := "llm"
const DEFAULT_AI_VARIANT := AI_VARIANT_HANDWRITTEN
const DEFAULT_EVALUATOR := AI_VARIANT_HANDWRITTEN


static func available_seeds() -> Array[int]:
	var seeds: Array[int] = []
	for raw_seed in PureStateArenaSuite.FAST_SEEDS:
		seeds.append(int(raw_seed))
	return seeds


static func available_agent_profiles() -> Array[String]:
	return ["fast", "balanced", "wide", "broad"]


static func available_ai_variants() -> Array[String]:
	return [AI_VARIANT_HANDWRITTEN, AI_VARIANT_NEURAL, AI_VARIANT_LLM]


static func build(
	scenario_seed: int,
	human_group: String = "terran",
	agent_profile: String = DEFAULT_AGENT_PROFILE,
	map_profile: String = PureStateArenaSuite.DEFAULT_MAP_PROFILE,
	preset: String = DEFAULT_PRESET,
	ai_variant: String = DEFAULT_AI_VARIANT,
	neural_checkpoint_path: String = PureStateNeuralEvaluator.DEFAULT_CHECKPOINT_PATH
) -> Dictionary:
	if human_group not in ["terran", "zerg"]:
		return {}
	if agent_profile not in available_agent_profiles():
		return {}
	if map_profile not in PureStateArenaSuite.available_map_profiles():
		return {}
	if ai_variant not in available_ai_variants():
		return {}
	if ai_variant == AI_VARIANT_NEURAL and neural_checkpoint_path.strip_edges().is_empty():
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

	# Compute the same objective coordinates the live/headless controllers will use,
	# but do it on a duplicate so initial_state remains the verbatim generated Arena
	# state. Including the coordinates in the scenario description also gives the
	# existing LLM snapshot an explicit target instead of only the abstract rule.
	var ai_group := "zerg" if human_group == "terran" else "terran"
	var objective_state: Dictionary = pure_state.duplicate(true)
	var command_hexes := PureStateCommandHexRules.ensure_command_hexes(objective_state, human_group, ai_group)
	var command_hex_text := "Terran command hex: %s. Zerg command hex: %s." % [
		str(command_hexes.get("terran", [])),
		str(command_hexes.get("zerg", [])),
	]

	var evaluator := ai_variant if ai_variant != AI_VARIANT_LLM else AI_VARIANT_LLM
	var scenario_id := "arena_playtest_s%d_%s_%s" % [scenario_seed, ai_variant, agent_profile]
	var variant_description := "canonical GameplayAI with the handwritten evaluator (%s profile)" % agent_profile
	if ai_variant == AI_VARIANT_NEURAL:
		variant_description = "canonical GameplayAI with the neural evaluator (%s profile)" % agent_profile
	elif ai_variant == AI_VARIANT_LLM:
		variant_description = "the existing single-player LLM planner"
	return {
		"id": scenario_id,
		"display_name": "Arena: %s — seed %d" % [_pretty_family(family), scenario_seed],
		"category": "arena",
		"description": (
			"Human vs %s. "
			+ "Win by elimination or by occupying the enemy command hex through one complete turn. %s "
			+ "The same living unit must remain on the enemy command hex from the start through the end of a complete resolved turn. "
			+ "The AI chooses from the same hidden pre-turn state as you. Playtest traces and training-ready examples are saved locally."
		) % [variant_description, command_hex_text],
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
			"ai_variant": ai_variant,
			"agent_profile": agent_profile,
			"search_profile_applies": ai_variant != AI_VARIANT_LLM,
			"evaluator": evaluator,
			"neural_checkpoint_path": neural_checkpoint_path if ai_variant == AI_VARIANT_NEURAL else "",
			"command_hexes_preview": command_hexes.duplicate(true),
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
