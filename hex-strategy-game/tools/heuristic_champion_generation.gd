extends Node
## Generate direct-policy neural-vs-frozen-handwritten games.
##
## Every base start is mirrored: neural Terran vs handwritten Zerg, then handwritten
## Terran vs neural Zerg. The neural side samples directly from its policy during
## training and uses argmax during evaluation. No MCTS/search target supervises the
## neural policy.

const GameplayAI = preload("res://src/battle/ai/gameplay_ai.gd")
const PureStateDirectPolicy = preload("res://src/simulation/pure_state_direct_policy.gd")
const PureStateSelfPlaySuite = preload("res://src/simulation/pure_state_self_play_suite.gd")
const PureStateSimulator = preload("res://src/simulation/pure_state_simulator.gd")
const PureStateTrainingData = preload("res://src/simulation/pure_state_training_data.gd")
const PureStateJointPolicy = preload("res://src/simulation/pure_state_joint_policy.gd")

const SCENARIOS := [
    {"id": "basic_1", "marines": 1, "zerglings": 2, "max_turns": 3, "turn_limit_winner": "terran"},
    {"id": "basic_2", "marines": 3, "zerglings": 2, "max_turns": 8, "turn_limit_winner": "zerg"},
    {"id": "basic_3", "marines": 2, "zerglings": 4, "max_turns": 4, "turn_limit_winner": "terran"},
]


func _ready() -> void:
    call_deferred("_run")


func _run() -> void:
    var args := _parse_cmdline_kv()
    var checkpoint := str(args.get("checkpoint", ""))
    var out_dir := str(args.get("out", "user://heuristic_champion_generation"))
    var base_games := maxi(1, int(args.get("base-games", "18")))
    var generation := int(args.get("generation", "0"))
    var seed_base := int(args.get("seed-base", "610000"))
    var temperature := maxf(0.0, float(args.get("temperature", "1.0")))
    var record_training := _parse_bool(args.get("record-training", "true"))
    if checkpoint.is_empty():
        push_error("--checkpoint is required")
        get_tree().quit(1)
        return

    var policy_rows: Array = []
    var value_examples: Array = []
    var games: Array = []
    var counts := {"win": 0, "loss": 0, "draw": 0, "failed": 0}
    var by_rotation: Dictionary = {}
    var by_scenario: Dictionary = {}

    for base_index in range(base_games):
        var scenario_index := posmod(seed_base + base_index, SCENARIOS.size())
        var rotation := posmod(seed_base + base_index * 5, 6)
        var scenario: Dictionary = SCENARIOS[scenario_index]
        for role_index in range(2):
            var neural_group := "terran" if role_index == 0 else "zerg"
            var opponent_group := "zerg" if neural_group == "terran" else "terran"
            var game_seed := seed_base + base_index * 1009 + role_index * 1000003
            var state := PureStateSelfPlaySuite.basic_state(
                int(scenario["marines"]),
                int(scenario["zerglings"]),
                rotation,
                int(scenario["max_turns"]),
                str(scenario["turn_limit_winner"]),
                false
            )
            state["turn_index"] = 0
            state["scenario_id"] = str(scenario["id"])
            var game_id := "g%d-b%d-r%d-%s" % [generation, base_index, rotation, neural_group]
            var result := _play_game(
                state,
                neural_group,
                opponent_group,
                checkpoint,
                game_seed,
                int(scenario["max_turns"]),
                str(scenario["turn_limit_winner"]),
                temperature,
                record_training,
                game_id,
                generation,
                rotation,
                str(scenario["id"])
            )
            games.append(result["summary"])
            if bool(result.get("valid", false)):
                var outcome := float(result.get("neural_outcome", 0.0))
                if outcome > 0.0:
                    counts["win"] = int(counts["win"]) + 1
                elif outcome < 0.0:
                    counts["loss"] = int(counts["loss"]) + 1
                else:
                    counts["draw"] = int(counts["draw"]) + 1
                if record_training:
                    policy_rows.append_array((result.get("policy_rows", []) as Array).duplicate(true))
                    value_examples.append_array((result.get("value_examples", []) as Array).duplicate(true))
            else:
                counts["failed"] = int(counts["failed"]) + 1

            var rkey := str(rotation)
            if not by_rotation.has(rkey):
                by_rotation[rkey] = {"win": 0, "loss": 0, "draw": 0, "failed": 0}
            _bump(by_rotation[rkey], result)

            var skey := str(scenario["id"])
            if not by_scenario.has(skey):
                by_scenario[skey] = {"win": 0, "loss": 0, "draw": 0, "failed": 0}
            _bump(by_scenario[skey], result)

    var abs_out := ProjectSettings.globalize_path(out_dir)
    if DirAccess.make_dir_recursive_absolute(abs_out) != OK:
        push_error("Unable to create output directory: " + abs_out)
        PureStateJointPolicy.shutdown()
        get_tree().quit(1)
        return

    var actual_games := games.size()
    var decisive := int(counts["win"]) + int(counts["loss"])
    var manifest := {
        "experiment": "heuristic_champion_generations_v1",
        "generation": generation,
        "base_games": base_games,
        "actual_games": actual_games,
        "mirrored_roles": true,
        "all_six_rotations": true,
        "scenarios": ["basic_1", "basic_2", "basic_3"],
        "neural_action_selection": "direct_autoregressive_policy",
        "opponent": "frozen_handwritten",
        "mcts_used": false,
        "temperature": temperature,
        "record_training": record_training,
        "counts": counts,
        "decisive_games": decisive,
        "neural_decisive_win_rate": float(counts["win"]) / float(decisive) if decisive > 0 else 0.0,
        "policy_steps": policy_rows.size(),
        "value_examples": value_examples.size(),
        "by_rotation": by_rotation,
        "by_scenario": by_scenario,
    }
    var ok := _write_json(out_dir.path_join("manifest.json"), manifest)
    ok = _write_jsonl(out_dir.path_join("games.jsonl"), games) and ok
    if record_training:
        ok = _write_jsonl(out_dir.path_join("policy_steps.jsonl"), policy_rows) and ok
        ok = _write_jsonl(out_dir.path_join("value_examples.jsonl"), value_examples) and ok

    print(JSON.stringify(manifest))
    PureStateJointPolicy.shutdown()
    get_tree().quit(0 if ok else 1)


func _play_game(
    initial_state: Dictionary,
    neural_group: String,
    opponent_group: String,
    checkpoint: String,
    game_seed: int,
    max_turns: int,
    turn_limit_winner: String,
    temperature: float,
    record_training: bool,
    game_id: String,
    generation: int,
    rotation: int,
    scenario_id: String
) -> Dictionary:
    var state := initial_state.duplicate(true)
    var history: Array = []
    var raw_policy_rows: Array = []
    var winner := ""
    var valid := true
    var termination_reason := ""
    var heuristic_settings := GameplayAI.handwritten_settings(8, 4, 8, 4)

    for turn_index in range(max_turns):
        state["turn_index"] = turn_index
        var neural := PureStateDirectPolicy.choose_plan(
            state,
            neural_group,
            opponent_group,
            checkpoint,
            game_seed + turn_index * 97,
            temperature
        )
        var heuristic := GameplayAI.choose_actions(
            state,
            opponent_group,
            neural_group,
            heuristic_settings
        )
        if not bool(neural.get("valid", false)) or not bool(heuristic.get("valid", false)):
            valid = false
            termination_reason = "decision_failed"
            break
        var neural_actions: Array = (neural.get("actions", []) as Array).duplicate(true)
        var heuristic_actions: Array = (heuristic.get("actions", []) as Array).duplicate(true)
        var submitted := {}
        submitted[neural_group] = neural_actions
        submitted[opponent_group] = heuristic_actions
        var simulation := PureStateSimulator.simulate_turn(state, submitted)
        var next_state_variant = simulation.get("next_state", {})
        if not (next_state_variant is Dictionary) or (next_state_variant as Dictionary).is_empty():
            valid = false
            termination_reason = "simulation_failed"
            break
        var next_state: Dictionary = (next_state_variant as Dictionary).duplicate(true)
        next_state["turn_index"] = turn_index + 1
        history.append({
            "turn": turn_index + 1,
            "state_before": state.duplicate(true),
            "state_after": next_state.duplicate(true),
            neural_group + "_actions": neural_actions,
            opponent_group + "_actions": heuristic_actions,
        })
        if record_training:
            for row_variant in neural.get("prefix_rows", []):
                if not (row_variant is Dictionary):
                    continue
                var row: Dictionary = (row_variant as Dictionary).duplicate(true)
                row["game_id"] = game_id
                row["generation"] = generation
                row["turn_index"] = turn_index
                row["rotation_steps"] = rotation
                row["scenario_id"] = scenario_id
                raw_policy_rows.append(row)
        state = next_state
        var terminal := _elimination_winner(state, neural_group, opponent_group)
        if bool(terminal.get("terminal", false)):
            winner = str(terminal.get("winner", ""))
            termination_reason = "elimination"
            break

    if valid and winner.is_empty():
        winner = turn_limit_winner
        termination_reason = "turn_limit_adjudication"

    var outcome := _outcome_for(winner, neural_group)
    var policy_rows: Array = []
    for row_variant in raw_policy_rows:
        if row_variant is Dictionary:
            var row: Dictionary = (row_variant as Dictionary).duplicate(true)
            row["outcome"] = outcome
            policy_rows.append(row)

    var value_examples: Array = []
    if valid and record_training:
        var rollout := {
            "valid": true,
            "status": "terminal",
            "winner": winner,
            "termination_reason": termination_reason,
            "turns_played": history.size(),
            "final_state": state.duplicate(true),
            "history": history.duplicate(true),
            "max_non_progress_streak": 0,
        }
        var built := PureStateTrainingData.build_examples_from_rollout(
            rollout,
            neural_group,
            opponent_group,
            game_id,
            {
                "dataset": "heuristic_champion_generations_v1",
                "generation": generation,
                "rotation_steps": rotation,
                "scenario_id": scenario_id,
                "reward_discount": 1.0,
                "label_unresolved_as_draw": true,
                "training_opponent": "frozen_handwritten",
                "policy_source": "direct_neural",
                "mcts_used": false,
            }
        )
        for example_variant in built.get("examples", []):
            if example_variant is Dictionary and str((example_variant as Dictionary).get("perspective_group", "")) == neural_group:
                value_examples.append((example_variant as Dictionary).duplicate(true))

    return {
        "valid": valid,
        "neural_outcome": outcome if valid else 0.0,
        "policy_rows": policy_rows,
        "value_examples": value_examples,
        "summary": {
            "game_id": game_id,
            "generation": generation,
            "rotation_steps": rotation,
            "scenario_id": scenario_id,
            "neural_group": neural_group,
            "opponent_group": opponent_group,
            "valid": valid,
            "winner": winner,
            "neural_outcome": outcome if valid else 0.0,
            "turns_played": history.size(),
            "termination_reason": termination_reason,
        },
    }


func _elimination_winner(state: Dictionary, group_a: String, group_b: String) -> Dictionary:
    var alive_a := _alive_count(state, group_a)
    var alive_b := _alive_count(state, group_b)
    if alive_a <= 0 and alive_b <= 0:
        return {"terminal": true, "winner": ""}
    if alive_a <= 0:
        return {"terminal": true, "winner": group_b}
    if alive_b <= 0:
        return {"terminal": true, "winner": group_a}
    return {"terminal": false, "winner": ""}


func _alive_count(state: Dictionary, group_name: String) -> int:
    for group_variant in state.get("groups", []):
        if group_variant is Dictionary and str((group_variant as Dictionary).get("name", "")) == group_name:
            var count := 0
            for unit_variant in (group_variant as Dictionary).get("units", []):
                if unit_variant is Dictionary and int((unit_variant as Dictionary).get("health", 0)) > 0:
                    count += 1
            return count
    return 0


func _outcome_for(winner: String, neural_group: String) -> float:
    if winner.is_empty():
        return 0.0
    return 1.0 if winner == neural_group else -1.0


func _bump(bucket: Dictionary, result: Dictionary) -> void:
    if not bool(result.get("valid", false)):
        bucket["failed"] = int(bucket["failed"]) + 1
        return
    var outcome := float(result.get("neural_outcome", 0.0))
    if outcome > 0.0:
        bucket["win"] = int(bucket["win"]) + 1
    elif outcome < 0.0:
        bucket["loss"] = int(bucket["loss"]) + 1
    else:
        bucket["draw"] = int(bucket["draw"]) + 1


func _write_json(path: String, value: Variant) -> bool:
    var file := FileAccess.open(path, FileAccess.WRITE)
    if file == null:
        push_error("Unable to write " + path)
        return false
    file.store_string(JSON.stringify(value, "  ") + "\n")
    file.close()
    return true


func _write_jsonl(path: String, rows: Array) -> bool:
    var lines: PackedStringArray = []
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
