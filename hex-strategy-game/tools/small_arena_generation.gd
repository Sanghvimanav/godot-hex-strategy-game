extends Node
## Generate radius-one Marine-vs-Zergling direct-policy games against the frozen heuristic.
##
## Each seeded start is mirrored so the neural policy plays both factions. Training
## samples from the direct autoregressive policy; evaluation uses greedy argmax.

const GameplayAI = preload("res://src/battle/ai/gameplay_ai.gd")
const PureStateGameRollout = preload("res://src/simulation/pure_state_game_rollout.gd")
const PureStateJointPolicy = preload("res://src/simulation/pure_state_joint_policy.gd")
const PureStateSmallArenaSuite = preload("res://src/simulation/pure_state_small_arena_suite.gd")
const PureStateTrainingData = preload("res://src/simulation/pure_state_training_data.gd")


func _ready() -> void:
    call_deferred("_run")


func _run() -> void:
    var args := _parse_cmdline_kv()
    var checkpoint := str(args.get("checkpoint", ""))
    var out_dir := str(args.get("out", "user://small_arena_generation"))
    var base_games := maxi(1, int(args.get("base-games", "84")))
    var generation := int(args.get("generation", "0"))
    var shard_index := int(args.get("shard-index", "0"))
    var seed_base := int(args.get("seed-base", "8100000"))
    var temperature := maxf(0.0, float(args.get("temperature", "1.0")))
    var record_training := _parse_bool(args.get("record-training", "true"))
    var max_turns := maxi(1, int(args.get("max-turns", str(PureStateSmallArenaSuite.DEFAULT_MAX_TURNS))))

    if checkpoint.is_empty():
        push_error("--checkpoint is required")
        get_tree().quit(1)
        return

    var heuristic_settings := GameplayAI.handwritten_settings(8, 4, 8, 4)
    var policy_rows: Array = []
    var value_examples: Array = []
    var games: Array = []
    var counts := {"win": 0, "loss": 0, "draw": 0, "unresolved": 0, "failed": 0}
    var matchup_counts: Dictionary = {}
    var faction_counts: Dictionary = {}

    for base_index in range(base_games):
        var scenario_seed := seed_base + base_index * 7919
        var state := PureStateSmallArenaSuite.build_state(scenario_seed, max_turns)
        var small_meta: Dictionary = state.get("small_arena", {})
        var matchup := str(small_meta.get("matchup", "unknown"))
        var layout_signature := PureStateSmallArenaSuite.layout_signature(state)

        for role_index in range(2):
            var neural_group := "terran" if role_index == 0 else "zerg"
            var opponent_group := "zerg" if neural_group == "terran" else "terran"
            var game_seed := seed_base + base_index * 1009 + role_index * 1000003
            var direct_settings := GameplayAI.direct_neural_settings(
                checkpoint,
                temperature,
                game_seed
            )
            var terran_settings := direct_settings if neural_group == "terran" else heuristic_settings
            var zerg_settings := direct_settings if neural_group == "zerg" else heuristic_settings
            var rollout := PureStateGameRollout.play_game_with_settings(
                state.duplicate(true),
                "terran",
                "zerg",
                terran_settings,
                zerg_settings,
                max_turns,
                true,
                ""
            )

            var valid := bool(rollout.get("valid", false))
            var status := str(rollout.get("status", ""))
            var winner := str(rollout.get("winner", ""))
            var outcome := _outcome_for(valid, status, winner, neural_group)
            var bucket := _outcome_bucket(valid, status, outcome)
            counts[bucket] = int(counts.get(bucket, 0)) + 1

            if not matchup_counts.has(matchup):
                matchup_counts[matchup] = {"win": 0, "loss": 0, "draw": 0, "unresolved": 0, "failed": 0}
            matchup_counts[matchup][bucket] = int(matchup_counts[matchup][bucket]) + 1
            if not faction_counts.has(neural_group):
                faction_counts[neural_group] = {"win": 0, "loss": 0, "draw": 0, "unresolved": 0, "failed": 0}
            faction_counts[neural_group][bucket] = int(faction_counts[neural_group][bucket]) + 1

            var game_id := "g%d-shard%d-b%d-%s" % [
                generation,
                shard_index,
                base_index,
                neural_group,
            ]

            if valid and record_training:
                for turn_variant in rollout.get("history", []):
                    if not (turn_variant is Dictionary):
                        continue
                    var turn: Dictionary = turn_variant
                    var prefix_key := neural_group + "_policy_prefix_rows"
                    for row_variant in turn.get(prefix_key, []):
                        if not (row_variant is Dictionary):
                            continue
                        var row: Dictionary = (row_variant as Dictionary).duplicate(true)
                        row["game_id"] = game_id
                        row["generation"] = generation
                        row["shard_index"] = shard_index
                        row["turn_index"] = int(turn.get("turn", 1)) - 1
                        row["scenario_id"] = "small_arena_" + matchup
                        row["scenario_seed"] = scenario_seed
                        row["matchup"] = matchup
                        row["layout_signature"] = layout_signature
                        row["outcome"] = outcome
                        policy_rows.append(row)

                var built := PureStateTrainingData.build_examples_from_rollout(
                    rollout,
                    "terran",
                    "zerg",
                    game_id,
                    {
                        "dataset": "small_arena_generations_v3",
                        "generation": generation,
                        "shard_index": shard_index,
                        "scenario_seed": scenario_seed,
                        "matchup": matchup,
                        "layout_signature": layout_signature,
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
                "game_id": game_id,
                "generation": generation,
                "shard_index": shard_index,
                "scenario_seed": scenario_seed,
                "scenario_id": "small_arena_" + matchup,
                "matchup": matchup,
                "layout_signature": layout_signature,
                "rotation_steps": int(small_meta.get("rotation_steps", 0)),
                "jitter_steps": int(small_meta.get("jitter_steps", 0)),
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
        "experiment": "small_arena_generations_v3",
        "generation": generation,
        "shard_index": shard_index,
        "base_states": base_games,
        "actual_games": games.size(),
        "mirrored_roles": true,
        "hex_radius": 1,
        "allowed_unit_types": ["marine", "zergling"],
        "matchup_distribution": {
            "3v3": 0.80,
            "2v2": 0.10,
            "3v2": 0.05,
            "2v3": 0.05,
        },
        "max_turns": max_turns,
        "state_source": "seeded_radius_one_formation_jitter",
        "neural_action_selection": "direct_autoregressive_policy",
        "opponent": "frozen_handwritten",
        "mcts_used": false,
        "temperature": temperature,
        "record_training": record_training,
        "counts": counts,
        "matchup_counts": matchup_counts,
        "faction_counts": faction_counts,
        "policy_steps": policy_rows.size(),
        "value_examples": value_examples.size(),
        "games": games,
    }

    var ok := _write_json(out_dir.path_join("manifest.json"), manifest)
    ok = _write_jsonl(out_dir.path_join("games.jsonl"), games) and ok
    if record_training:
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


func _parse_bool(value: Variant) -> bool:
    return str(value).strip_edges().to_lower() in ["1", "true", "yes", "on"]


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
