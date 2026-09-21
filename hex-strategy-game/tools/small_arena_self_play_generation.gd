extends Node
## Radius-one current-policy self-play for Marines vs Zerglings.
## Both factions use the same checkpoint. Training rows are captured for both sides.

const GameplayAI = preload("res://src/battle/ai/gameplay_ai.gd")
const PureStateGameRollout = preload("res://src/simulation/pure_state_game_rollout.gd")
const PureStateJointPolicy = preload("res://src/simulation/pure_state_joint_policy.gd")
const PureStateSmallArenaSelfPlaySuite = preload("res://src/simulation/pure_state_small_arena_self_play_suite.gd")
const PureStateTrainingData = preload("res://src/simulation/pure_state_training_data.gd")


func _ready() -> void:
    call_deferred("_run")


func _run() -> void:
    var args := _parse_cmdline_kv()
    var checkpoint := str(args.get("checkpoint", ""))
    var out_dir := str(args.get("out", "user://small_arena_self_play"))
    var game_count := maxi(1, int(args.get("game-count", "80")))
    var generation := int(args.get("generation", "1"))
    var shard_index := int(args.get("shard-index", "0"))
    var seed_base := int(args.get("seed-base", "12100000"))
    var temperature := maxf(0.0, float(args.get("temperature", "1.0")))
    var max_turns := maxi(1, int(args.get("max-turns", str(PureStateSmallArenaSelfPlaySuite.DEFAULT_MAX_TURNS))))

    if checkpoint.is_empty():
        push_error("--checkpoint is required")
        get_tree().quit(1)
        return

    var policy_rows: Array = []
    var value_examples: Array = []
    var games: Array = []
    var counts := {"terran": 0, "zerg": 0, "draw": 0, "unresolved": 0, "failed": 0}
    var matchup_counts: Dictionary = {}

    for game_index in range(game_count):
        var scenario_seed := seed_base + game_index * 7919
        var state := PureStateSmallArenaSelfPlaySuite.build_state(scenario_seed, max_turns)
        var meta: Dictionary = state.get("small_arena", {})
        var matchup := str(meta.get("matchup", "unknown"))
        var layout_signature := PureStateSmallArenaSelfPlaySuite.layout_signature(state)
        var terran_settings := GameplayAI.direct_neural_settings(
            checkpoint, temperature, seed_base + game_index * 1009 + 17
        )
        var zerg_settings := GameplayAI.direct_neural_settings(
            checkpoint, temperature, seed_base + game_index * 1009 + 100003
        )
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
        var bucket := "failed"
        if valid:
            if status == "turn_limit":
                bucket = "unresolved"
            elif winner == "terran" or winner == "zerg":
                bucket = winner
            else:
                bucket = "draw"
        counts[bucket] = int(counts.get(bucket, 0)) + 1
        if not matchup_counts.has(matchup):
            matchup_counts[matchup] = {"terran": 0, "zerg": 0, "draw": 0, "unresolved": 0, "failed": 0}
        matchup_counts[matchup][bucket] = int(matchup_counts[matchup][bucket]) + 1

        var game_id := "selfplay-g%d-shard%d-b%d" % [generation, shard_index, game_index]

        if valid:
            for turn_variant in rollout.get("history", []):
                if not (turn_variant is Dictionary):
                    continue
                var turn: Dictionary = turn_variant
                for perspective_group in ["terran", "zerg"]:
                    var prefix_key := perspective_group + "_policy_prefix_rows"
                    var outcome := _outcome_for(winner, status, perspective_group)
                    for row_variant in turn.get(prefix_key, []):
                        if not (row_variant is Dictionary):
                            continue
                        var row: Dictionary = (row_variant as Dictionary).duplicate(true)
                        row["game_id"] = game_id
                        row["generation"] = generation
                        row["shard_index"] = shard_index
                        row["turn_index"] = int(turn.get("turn", 1)) - 1
                        row["scenario_id"] = "small_selfplay_" + matchup
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
                    "dataset": "small_arena_self_play_v4",
                    "generation": generation,
                    "shard_index": shard_index,
                    "scenario_seed": scenario_seed,
                    "matchup": matchup,
                    "layout_signature": layout_signature,
                    "reward_discount": 1.0,
                    "label_unresolved_as_draw": true,
                    "training_opponent": "current_policy_self_play",
                    "policy_source": "direct_neural_both_factions",
                    "mcts_used": false,
                }
            )
            for example_variant in built.get("examples", []):
                if example_variant is Dictionary:
                    value_examples.append((example_variant as Dictionary).duplicate(true))

        games.append({
            "game_id": game_id,
            "generation": generation,
            "shard_index": shard_index,
            "scenario_seed": scenario_seed,
            "scenario_id": "small_selfplay_" + matchup,
            "matchup": matchup,
            "layout_signature": layout_signature,
            "rotation_steps": int(meta.get("rotation_steps", 0)),
            "jitter_steps": int(meta.get("jitter_steps", 0)),
            "valid": valid,
            "status": status,
            "winner": winner,
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
        "experiment": "small_arena_self_play_v4",
        "generation": generation,
        "shard_index": shard_index,
        "games": game_count,
        "hex_radius": 1,
        "allowed_unit_types": ["marine", "zergling"],
        "matchup_distribution": {"3v3": 0.80, "2v3": 0.10, "1v2": 0.10},
        "max_turns": max_turns,
        "training_opponent": "current_policy_self_play",
        "same_checkpoint_both_factions": true,
        "neural_action_selection": "direct_autoregressive_policy",
        "mcts_used": false,
        "temperature": temperature,
        "counts": counts,
        "matchup_counts": matchup_counts,
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


func _outcome_for(winner: String, status: String, perspective_group: String) -> float:
    if status == "turn_limit" or winner.is_empty():
        return 0.0
    return 1.0 if winner == perspective_group else -1.0


func _write_json(path: String, value: Variant) -> bool:
    var file := FileAccess.open(path, FileAccess.WRITE)
    if file == null:
        return false
    file.store_string(JSON.stringify(value, "  ") + "\n")
    file.close()
    return true


func _write_jsonl(path: String, rows: Array) -> bool:
    var file := FileAccess.open(path, FileAccess.WRITE)
    if file == null:
        return false
    for row_variant in rows:
        if row_variant is Dictionary:
            file.store_line(JSON.stringify(row_variant))
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
