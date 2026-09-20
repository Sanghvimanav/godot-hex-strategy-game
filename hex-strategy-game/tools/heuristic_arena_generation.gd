extends Node
## Fresh randomized arena-state training against a frozen handwritten champion.
##
## Each generated arena state is played twice with the neural direct policy on
## opposite factions. Policy targets come only from the neural side's sampled
## actions and final game outcome. No MCTS/search supervision is used.

const GameplayAI = preload("res://src/battle/ai/gameplay_ai.gd")
const PureStateArenaSuite = preload("res://src/simulation/pure_state_arena_suite.gd")
const PureStateGameRollout = preload("res://src/simulation/pure_state_game_rollout.gd")
const PureStateJointPolicy = preload("res://src/simulation/pure_state_joint_policy.gd")
const PureStateTrainingData = preload("res://src/simulation/pure_state_training_data.gd")


func _ready() -> void:
    call_deferred("_run")


func _run() -> void:
    var args := _parse_cmdline_kv()
    var checkpoint := str(args.get("checkpoint", ""))
    var out_dir := str(args.get("out", "user://heuristic_arena_generation"))
    var base_games := maxi(1, int(args.get("base-games", "84")))
    var generation := int(args.get("generation", "0"))
    var shard_index := int(args.get("shard-index", "0"))
    var seed_base := int(args.get("seed-base", "7100000"))
    var temperature := maxf(0.0, float(args.get("temperature", "1.0")))
    var map_profile := str(args.get("map-profile", PureStateArenaSuite.DEFAULT_MAP_PROFILE))
    var champion_profile := str(args.get("champion-profile", "balanced"))

    if checkpoint.is_empty():
        push_error("--checkpoint is required")
        get_tree().quit(1)
        return
    if map_profile not in PureStateArenaSuite.available_map_profiles():
        push_error("Unknown map profile: " + map_profile)
        get_tree().quit(1)
        return

    var heuristic_settings := PureStateArenaSuite.agent_settings(
        champion_profile,
        GameplayAI.EVALUATOR_HANDWRITTEN
    )
    if heuristic_settings.is_empty():
        push_error("Unknown champion profile: " + champion_profile)
        get_tree().quit(1)
        return

    var policy_rows: Array = []
    var value_examples: Array = []
    var games: Array = []
    var counts := {"win": 0, "loss": 0, "draw": 0, "unresolved": 0, "failed": 0}
    var family_counts: Dictionary = {}
    var faction_counts: Dictionary = {}

    for base_index in range(base_games):
        # 7919 is coprime to the eight arena families, so adjacent examples cycle
        # across families while still getting independent variation/rotation seeds.
        var scenario_seed := seed_base + base_index * 7919
        var jobs := PureStateArenaSuite.build_generated_pair_jobs(
            scenario_seed,
            "training",
            map_profile
        )
        for job_variant in jobs:
            if not (job_variant is Dictionary):
                counts["failed"] = int(counts["failed"]) + 1
                continue
            var job: Dictionary = job_variant
            var neural_group := str(job.get("challenger_group", ""))
            var opponent_group := str(job.get("champion_group", ""))
            var unique_game_id := "g%d-shard%d-%s" % [
                generation,
                shard_index,
                str(job.get("game_id", "")),
            ]
            var direct_settings := GameplayAI.direct_neural_settings(
                checkpoint,
                temperature,
                seed_base + base_index * 1009 + (1 if neural_group == "zerg" else 0)
            )
            var terran_settings := direct_settings if neural_group == "terran" else heuristic_settings
            var zerg_settings := direct_settings if neural_group == "zerg" else heuristic_settings
            var rollout := PureStateGameRollout.play_game_with_settings(
                (job.get("state", {}) as Dictionary).duplicate(true),
                "terran",
                "zerg",
                terran_settings,
                zerg_settings,
                int(job.get("max_turns", 12)),
                true,
                ""
            )
            var valid := bool(rollout.get("valid", false))
            var status := str(rollout.get("status", ""))
            var winner := str(rollout.get("winner", ""))
            var outcome := _outcome_for(valid, status, winner, neural_group)
            var bucket := _outcome_bucket(valid, status, outcome)
            counts[bucket] = int(counts.get(bucket, 0)) + 1

            var family := str(job.get("base_scenario_id", "unknown"))
            if not family_counts.has(family):
                family_counts[family] = {"win": 0, "loss": 0, "draw": 0, "unresolved": 0, "failed": 0}
            family_counts[family][bucket] = int(family_counts[family][bucket]) + 1
            if not faction_counts.has(neural_group):
                faction_counts[neural_group] = {"win": 0, "loss": 0, "draw": 0, "unresolved": 0, "failed": 0}
            faction_counts[neural_group][bucket] = int(faction_counts[neural_group][bucket]) + 1

            if valid:
                for turn_variant in rollout.get("history", []):
                    if not (turn_variant is Dictionary):
                        continue
                    var turn: Dictionary = turn_variant
                    var prefix_key := neural_group + "_policy_prefix_rows"
                    for row_variant in turn.get(prefix_key, []):
                        if not (row_variant is Dictionary):
                            continue
                        var row: Dictionary = (row_variant as Dictionary).duplicate(true)
                        row["game_id"] = unique_game_id
                        row["generation"] = generation
                        row["shard_index"] = shard_index
                        row["turn_index"] = int(turn.get("turn", 1)) - 1
                        row["scenario_id"] = str((job.get("state", {}) as Dictionary).get("scenario_id", ""))
                        row["scenario_seed"] = scenario_seed
                        row["base_scenario_id"] = family
                        row["rotation_steps"] = int(job.get("rotation_steps", 0))
                        row["outcome"] = outcome
                        policy_rows.append(row)

                var built := PureStateTrainingData.build_examples_from_rollout(
                    rollout,
                    "terran",
                    "zerg",
                    unique_game_id,
                    {
                        "dataset": "heuristic_arena_generations_v2",
                        "generation": generation,
                        "shard_index": shard_index,
                        "scenario_seed": scenario_seed,
                        "base_scenario_id": family,
                        "rotation_steps": int(job.get("rotation_steps", 0)),
                        "map_profile": map_profile,
                        "reward_discount": 1.0,
                        "label_unresolved_as_draw": true,
                        "training_opponent": "frozen_handwritten",
                        "policy_source": "direct_neural",
                        "mcts_used": false,
                    }
                )
                for example_variant in built.get("examples", []):
                    if (
                        example_variant is Dictionary
                        and str((example_variant as Dictionary).get("perspective_group", "")) == neural_group
                    ):
                        value_examples.append((example_variant as Dictionary).duplicate(true))

            games.append({
                "game_id": unique_game_id,
                "generation": generation,
                "shard_index": shard_index,
                "scenario_seed": scenario_seed,
                "base_scenario_id": family,
                "rotation_steps": int(job.get("rotation_steps", 0)),
                "neural_group": neural_group,
                "opponent_group": opponent_group,
                "valid": valid,
                "status": status,
                "winner": winner,
                "neural_outcome": outcome,
                "turns_played": int(rollout.get("turns_played", 0)),
                "termination_reason": str(rollout.get("termination_reason", "")),
            })

    var abs_out := ProjectSettings.globalize_path(out_dir)
    if DirAccess.make_dir_recursive_absolute(abs_out) != OK:
        push_error("Unable to create output directory: " + abs_out)
        PureStateJointPolicy.shutdown()
        get_tree().quit(1)
        return

    var manifest := {
        "experiment": "heuristic_arena_generations_v2",
        "generation": generation,
        "shard_index": shard_index,
        "base_states": base_games,
        "actual_games": games.size(),
        "mirrored_roles": true,
        "state_source": "generated_arena_states",
        "map_profile": map_profile,
        "champion_profile": champion_profile,
        "neural_action_selection": "direct_autoregressive_policy",
        "opponent": "frozen_handwritten",
        "mcts_used": false,
        "temperature": temperature,
        "counts": counts,
        "family_counts": family_counts,
        "faction_counts": faction_counts,
        "policy_steps": policy_rows.size(),
        "value_examples": value_examples.size(),
    }
    var ok := _write_json(out_dir.path_join("manifest.json"), manifest)
    ok = _write_jsonl(out_dir.path_join("games.jsonl"), games) and ok
    ok = _write_jsonl(out_dir.path_join("policy_steps.jsonl"), policy_rows) and ok
    ok = _write_jsonl(out_dir.path_join("value_examples.jsonl"), value_examples) and ok
    print(JSON.stringify(manifest))
    PureStateJointPolicy.shutdown()
    get_tree().quit(0 if ok and int(counts["failed"]) == 0 else 1)


func _outcome_for(valid: bool, status: String, winner: String, neural_group: String) -> float:
    if not valid or status != "terminal" or winner.is_empty():
        return 0.0
    return 1.0 if winner == neural_group else -1.0


func _outcome_bucket(valid: bool, status: String, outcome: float) -> String:
    if not valid:
        return "failed"
    if status == "turn_limit":
        return "unresolved"
    if outcome > 0.0:
        return "win"
    if outcome < 0.0:
        return "loss"
    return "draw"


func _write_json(path: String, value: Variant) -> bool:
    var file := FileAccess.open(path, FileAccess.WRITE)
    if file == null:
        push_error("Unable to write " + path)
        return false
    file.store_string(JSON.stringify(value, "  ") + "\n")
    file.close()
    return true


func _write_jsonl(path: String, rows: Array) -> bool:
    var lines := PackedStringArray()
    for row_variant in rows:
        if row_variant is Dictionary:
            lines.append(JSON.stringify(row_variant))
    var file := FileAccess.open(path, FileAccess.WRITE)
    if file == null:
        push_error("Unable to write " + path)
        return false
    file.store_string("\n".join(lines) + ("\n" if not lines.is_empty() else ""))
    file.close()
    return true


func _parse_cmdline_kv() -> Dictionary:
    var result := {}
    var raw := OS.get_cmdline_user_args()
    if raw.is_empty():
        raw = OS.get_cmdline_args()
    var i := 0
    while i < raw.size():
        var arg := str(raw[i]).strip_edges()
        if arg.begins_with("--"):
            arg = arg.substr(2)
        if arg.contains("="):
            var parts := arg.split("=", true, 1)
            result[parts[0]] = parts[1]
        elif not arg.is_empty():
            var next_value := ""
            if i + 1 < raw.size() and not str(raw[i + 1]).begins_with("-"):
                next_value = str(raw[i + 1]).strip_edges()
                i += 1
            result[arg] = next_value if not next_value.is_empty() else "true"
        i += 1
    return result
