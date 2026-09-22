extends Node
## Fixed-seed evaluation of a neural checkpoint against the frozen handwritten heuristic
## on the radius-one Marine/Zergling self-play curriculum.

const GameplayAI = preload("res://src/battle/ai/gameplay_ai.gd")
const PureStateGameRollout = preload("res://src/simulation/pure_state_game_rollout.gd")
const PureStateJointPolicy = preload("res://src/simulation/pure_state_joint_policy.gd")
const PureStateSmallArenaSelfPlaySuiteV5 = preload("res://src/simulation/pure_state_small_arena_self_play_suite_v5.gd")


func _ready() -> void:
    call_deferred("_run")


func _run() -> void:
    var args := _parse_cmdline_kv()
    var checkpoint := str(args.get("checkpoint", ""))
    var out_dir := str(args.get("out", "user://small_arena_self_play_eval"))
    var base_games := maxi(1, int(args.get("base-games", "20")))
    var generation := int(args.get("generation", "0"))
    var shard_index := int(args.get("shard-index", "0"))
    var seed_base := int(args.get("seed-base", "13100000"))
    var max_turns := maxi(1, int(args.get("max-turns", str(PureStateSmallArenaSelfPlaySuiteV5.DEFAULT_MAX_TURNS))))

    if checkpoint.is_empty():
        push_error("--checkpoint is required")
        get_tree().quit(1)
        return

    var heuristic_settings := GameplayAI.handwritten_settings(8, 4, 8, 4)
    var games: Array = []
    var counts := {"win": 0, "loss": 0, "draw": 0, "unresolved": 0, "failed": 0}
    var matchup_counts: Dictionary = {}
    var faction_counts: Dictionary = {}

    for base_index in range(base_games):
        var scenario_seed := seed_base + base_index * 7919
        var state := PureStateSmallArenaSelfPlaySuiteV5.build_state(scenario_seed, max_turns)
        var meta: Dictionary = state.get("small_arena", {})
        var matchup := str(meta.get("matchup", "unknown"))
        var layout_signature := PureStateSmallArenaSelfPlaySuiteV5.layout_signature(state)

        for role_index in range(2):
            var neural_group := "terran" if role_index == 0 else "zerg"
            var direct_settings := GameplayAI.direct_neural_settings(
                checkpoint, 0.0, seed_base + base_index * 1009 + role_index * 1000003
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
            var outcome := 0.0
            if valid and status != "turn_limit" and not winner.is_empty():
                outcome = 1.0 if winner == neural_group else -1.0

            var bucket := "failed"
            if valid:
                if status == "turn_limit":
                    bucket = "unresolved"
                elif outcome > 0.0:
                    bucket = "win"
                elif outcome < 0.0:
                    bucket = "loss"
                else:
                    bucket = "draw"
            counts[bucket] = int(counts.get(bucket, 0)) + 1

            if not matchup_counts.has(matchup):
                matchup_counts[matchup] = {"win": 0, "loss": 0, "draw": 0, "unresolved": 0, "failed": 0}
            matchup_counts[matchup][bucket] = int(matchup_counts[matchup][bucket]) + 1
            if not faction_counts.has(neural_group):
                faction_counts[neural_group] = {"win": 0, "loss": 0, "draw": 0, "unresolved": 0, "failed": 0}
            faction_counts[neural_group][bucket] = int(faction_counts[neural_group][bucket]) + 1

            games.append({
                "game_id": "eval-g%d-s%d-b%d-%s" % [generation, shard_index, base_index, neural_group],
                "generation": generation,
                "shard_index": shard_index,
                "scenario_seed": scenario_seed,
                "matchup": matchup,
                "layout_signature": layout_signature,
                "neural_group": neural_group,
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
        "experiment": "small_arena_self_play_v5_balanced_eval",
        "generation": generation,
        "shard_index": shard_index,
        "base_states": base_games,
        "actual_games": games.size(),
        "hex_radius": 1,
        "allowed_unit_types": ["marine", "zergling"],
        "matchup_distribution": "uniform_1to3_marines_vs_1to4_zerglings",
        "opponent": "frozen_handwritten",
        "temperature": 0.0,
        "counts": counts,
        "matchup_counts": matchup_counts,
        "faction_counts": faction_counts,
        "games": games,
    }
    var ok := _write_json(out_dir.path_join("manifest.json"), manifest)
    ok = _write_jsonl(out_dir.path_join("games.jsonl"), games) and ok
    print(JSON.stringify(manifest))
    PureStateJointPolicy.shutdown()
    get_tree().quit(0 if ok and int(counts["failed"]) == 0 else 1)


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
