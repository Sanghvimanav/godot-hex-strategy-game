extends RefCounted
class_name ArenaPlaytestData
## Builds durable human-vs-Arena artifacts without coupling future training code to
## the interactive scene. Terminal games reuse PureStateTrainingData's value-label
## schema; every completed turn also becomes a human-policy demonstration.

const PureStateTrainingData = preload("res://src/simulation/pure_state_training_data.gd")

const MANIFEST_SCHEMA_VERSION := 1
const TRACE_SCHEMA_VERSION := 1
const POLICY_SCHEMA_VERSION := 1
const DEFAULT_OUTPUT_ROOT := "user://arena_playtests"


static func build_artifacts(
	game_id: String,
	human_group: String,
	ai_group: String,
	arena_config: Dictionary,
	history: Array,
	final_state: Dictionary,
	status: String,
	winner: String,
	termination_reason: String
) -> Dictionary:
	var source := build_source_metadata(human_group, ai_group, arena_config)
	var rollout := {
		"valid": true,
		"status": status,
		"winner": winner,
		"termination_reason": termination_reason,
		"turns_played": history.size(),
		"max_non_progress_streak": 0,
		"history": history.duplicate(true),
		"final_state": final_state.duplicate(true),
	}
	var value_result := PureStateTrainingData.build_examples_from_rollout(
		rollout,
		human_group,
		ai_group,
		game_id,
		source
	)
	var value_examples: Array = (value_result.get("examples", []) as Array).duplicate(true)
	var policy_examples := _build_human_policy_examples(
		game_id,
		human_group,
		ai_group,
		history,
		status,
		winner,
		source
	)
	var trace := {
		"trace_schema_version": TRACE_SCHEMA_VERSION,
		"game_id": game_id,
		"status": status,
		"winner": winner,
		"termination_reason": termination_reason,
		"turns_played": history.size(),
		"groups": [human_group, ai_group],
		"human_group": human_group,
		"ai_group": ai_group,
		"source": source.duplicate(true),
		"turns": history.duplicate(true),
		"final_state": final_state.duplicate(true),
	}
	var manifest := {
		"manifest_schema_version": MANIFEST_SCHEMA_VERSION,
		"game_id": game_id,
		"data_source": "human_vs_arena_ai",
		"status": status,
		"winner": winner,
		"termination_reason": termination_reason,
		"turns_played": history.size(),
		"human_group": human_group,
		"ai_group": ai_group,
		"source": source.duplicate(true),
		"value_example_count": value_examples.size(),
		"human_policy_example_count": policy_examples.size(),
		"files": {
			"trace": "trace.json",
			"value_examples": "value_examples.jsonl",
			"human_policy_examples": "human_policy_examples.jsonl",
		},
	}
	return {
		"manifest": manifest,
		"trace": trace,
		"value_examples": value_examples,
		"human_policy_examples": policy_examples,
	}


static func build_source_metadata(
	human_group: String,
	ai_group: String,
	arena_config: Dictionary
) -> Dictionary:
	var metadata: Dictionary = (arena_config.get("arena_metadata", {}) as Dictionary).duplicate(true)
	metadata.merge({
		"data_source": "human_vs_arena_ai",
		"arena_suite_version": int(arena_config.get("suite_version", 0)),
		"preset": str(arena_config.get("preset", "fast")),
		"scenario_seed": int(arena_config.get("scenario_seed", 0)),
		"base_scenario_id": str(arena_config.get("base_scenario_id", "")),
		"map_profile": str(arena_config.get("map_profile", "")),
		"ai_agent_profile": str(arena_config.get("agent_profile", "fast")),
		"ai_evaluator": str(arena_config.get("evaluator", "handwritten")),
		"human_group": human_group,
		"ai_group": ai_group,
		"godot_version": Engine.get_version_info(),
	}, true)
	return metadata


static func write_session(
	game_id: String,
	artifacts: Dictionary,
	output_root: String = DEFAULT_OUTPUT_ROOT
) -> Dictionary:
	if game_id.is_empty():
		return {"ok": false, "error": "empty_game_id"}
	var out_dir := output_root.path_join(game_id)
	var abs_out := ProjectSettings.globalize_path(out_dir)
	if DirAccess.make_dir_recursive_absolute(abs_out) != OK:
		return {"ok": false, "error": "mkdir_failed", "path": out_dir}

	var manifest_ok := _write_json(out_dir.path_join("manifest.json"), artifacts.get("manifest", {}))
	var trace_ok := _write_json(out_dir.path_join("trace.json"), artifacts.get("trace", {}))
	var value_ok := PureStateTrainingData.write_jsonl(
		out_dir.path_join("value_examples.jsonl"),
		artifacts.get("value_examples", []) as Array
	)
	var policy_ok := PureStateTrainingData.write_jsonl(
		out_dir.path_join("human_policy_examples.jsonl"),
		artifacts.get("human_policy_examples", []) as Array
	)
	var ok := manifest_ok and trace_ok and value_ok and policy_ok
	return {
		"ok": ok,
		"path": out_dir,
		"absolute_path": abs_out,
		"value_example_count": (artifacts.get("value_examples", []) as Array).size(),
		"human_policy_example_count": (artifacts.get("human_policy_examples", []) as Array).size(),
	}


static func _build_human_policy_examples(
	game_id: String,
	human_group: String,
	ai_group: String,
	history: Array,
	status: String,
	winner: String,
	source: Dictionary
) -> Array:
	var examples: Array = []
	var terminal_outcome: Variant = null
	if status == "terminal":
		terminal_outcome = _perspective_outcome(winner, human_group)
	for turn_index in range(history.size()):
		var turn_variant = history[turn_index]
		if not (turn_variant is Dictionary):
			continue
		var turn: Dictionary = turn_variant
		var state_before_variant = turn.get("state_before", null)
		if not (state_before_variant is Dictionary):
			continue
		var state_before: Dictionary = state_before_variant
		examples.append({
			"schema_version": POLICY_SCHEMA_VERSION,
			"example_type": "human_policy",
			"game_id": game_id,
			"scenario_id": str(state_before.get("scenario_id", "")),
			"turn_index": turn_index,
			"perspective_group": human_group,
			"opponent_group": ai_group,
			"chosen_actions": (turn.get("human_actions", []) as Array).duplicate(true),
			# Stored for offline analysis/counterfactual labeling only. A policy model
			# must not receive this simultaneous opponent choice as an input feature.
			"opponent_actions_for_analysis_only": (turn.get("ai_actions", []) as Array).duplicate(true),
			"terminal_outcome": terminal_outcome,
			"source": source.duplicate(true),
			"state": state_before.duplicate(true),
		})
	return examples


static func _perspective_outcome(winner: String, perspective_group: String) -> float:
	if winner.is_empty():
		return 0.0
	return 1.0 if winner == perspective_group else -1.0


static func _write_json(path: String, value: Variant) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(value, "\t") + "\n")
	file.close()
	return true
