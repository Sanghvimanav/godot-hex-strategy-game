extends RefCounted
## Shared continuation helper for policy-aligned value supervision.
##
## Existing ranking labels continue with handwritten-vs-handwritten play. This
## helper additionally supports neural-vs-handwritten and neural self-play so a
## leaf can be labeled under the policy that will actually control it later.

const GameplayAI = preload("res://src/battle/ai/gameplay_ai.gd")
const PureStateGameRollout = preload("res://src/simulation/pure_state_game_rollout.gd")
const PureStateCommandHexRules = preload("res://src/simulation/pure_state_command_hex_rules.gd")

const POLICY_HANDWRITTEN := "handwritten"
const POLICY_NEURAL_VS_HANDWRITTEN := "neural_vs_handwritten"
const POLICY_NEURAL_SELF_PLAY := "neural_self_play"

const OUTCOME_PAIR_WEIGHT := 1.0
const FASTER_WIN_PAIR_WEIGHT := 0.25


func continue_candidate(
	decision: Dictionary,
	candidate_index: int,
	response_index: int,
	continuation_turn_cap: int,
	continuation_policy: String,
	neural_checkpoint: String
) -> Dictionary:
	var candidates_variant: Variant = decision.get("candidates", [])
	if not (candidates_variant is Array):
		return {"valid": false, "error": "invalid_candidates"}
	var candidates: Array = candidates_variant as Array
	if candidate_index < 0 or candidate_index >= candidates.size():
		return {"valid": false, "error": "invalid_candidate_index"}
	var candidate_variant: Variant = candidates[candidate_index]
	if not (candidate_variant is Dictionary):
		return {"valid": false, "error": "invalid_candidate"}
	var candidate: Dictionary = candidate_variant as Dictionary
	var response: Dictionary = _response_by_index(candidate, response_index)
	if response.is_empty():
		return {"valid": false, "error": "missing_response"}

	var perspective_group: String = str(decision.get("perspective_group", ""))
	var opponent_group: String = str(decision.get("opponent_group", ""))
	var starting_variant: Variant = decision.get("starting_state", {})
	var leaf_variant: Variant = response.get("state_after_first_turn", {})
	if not (starting_variant is Dictionary) or not (leaf_variant is Dictionary):
		return {"valid": false, "error": "missing_branch_state"}
	var starting_state: Dictionary = (starting_variant as Dictionary).duplicate(true)
	var leaf_state: Dictionary = (leaf_variant as Dictionary).duplicate(true)

	var source: Dictionary = {}
	var source_variant: Variant = decision.get("source", {})
	if source_variant is Dictionary:
		source = source_variant as Dictionary
	var source_max_turns: int = int(source.get("max_turns", PureStateGameRollout.DEFAULT_MAX_TURNS))
	var decision_turn_index: int = int(decision.get("turn_index", 0))
	# Preserve the historical sibling-label horizon so handwritten and neural
	# continuation pairs remain directly comparable.
	var full_remaining_turns: int = maxi(0, source_max_turns - decision_turn_index)
	var remaining_turns: int = full_remaining_turns
	if continuation_turn_cap > 0:
		remaining_turns = mini(remaining_turns, continuation_turn_cap)
	var truncated: bool = remaining_turns < full_remaining_turns
	var turn_limit_winner: String = str(source.get("turn_limit_winner", ""))
	var rollout_turn_limit_winner: String = "" if truncated else turn_limit_winner

	var budget: Dictionary = {}
	var budget_variant: Variant = decision.get("budget", {})
	if budget_variant is Dictionary:
		budget = budget_variant as Dictionary
	return continue_from_leaf(
		starting_state,
		leaf_state,
		perspective_group,
		opponent_group,
		remaining_turns,
		budget,
		rollout_turn_limit_winner,
		continuation_policy,
		neural_checkpoint
	)


func continue_from_leaf(
	starting_state: Dictionary,
	leaf_state_input: Dictionary,
	perspective_group: String,
	opponent_group: String,
	remaining_turns: int,
	budget: Dictionary,
	turn_limit_winner: String,
	continuation_policy: String,
	neural_checkpoint: String
) -> Dictionary:
	if perspective_group.is_empty() or opponent_group.is_empty() or perspective_group == opponent_group:
		return {"valid": false, "error": "invalid_groups"}
	if continuation_policy not in [
		POLICY_HANDWRITTEN,
		POLICY_NEURAL_VS_HANDWRITTEN,
		POLICY_NEURAL_SELF_PLAY,
	]:
		return {"valid": false, "error": "unsupported_continuation_policy"}
	if continuation_policy != POLICY_HANDWRITTEN and neural_checkpoint.is_empty():
		return {"valid": false, "error": "neural_checkpoint_required"}

	var leaf_state: Dictionary = leaf_state_input.duplicate(true)
	var command_hexes: Dictionary = PureStateCommandHexRules.ensure_command_hexes(
		starting_state,
		perspective_group,
		opponent_group
	)
	leaf_state["command_hexes"] = command_hexes.duplicate(true)
	var previous_occupants: Dictionary = PureStateCommandHexRules.initial_occupants(
		starting_state,
		perspective_group,
		opponent_group,
		command_hexes
	)
	var capture: Dictionary = PureStateCommandHexRules.capture_after_complete_turn(
		leaf_state,
		perspective_group,
		opponent_group,
		command_hexes,
		previous_occupants
	)
	var completed: Dictionary = {}
	var completed_variant: Variant = capture.get("completed", {})
	if completed_variant is Dictionary:
		completed = completed_variant as Dictionary
	var immediate: Dictionary = _immediate_branch_outcome(
		leaf_state,
		perspective_group,
		opponent_group,
		bool(completed.get(perspective_group, false)),
		bool(completed.get(opponent_group, false))
	)
	if bool(immediate.get("terminal", false)):
		return _continuation_result(
			true,
			true,
			true,
			str(immediate.get("winner", "")),
			str(immediate.get("termination_reason", "")),
			0,
			leaf_state,
			leaf_state,
			perspective_group,
			continuation_policy
		)

	if remaining_turns <= 0:
		var adjudicated: bool = not turn_limit_winner.is_empty()
		return _continuation_result(
			true,
			adjudicated,
			false,
			turn_limit_winner if adjudicated else "",
			"turn_limit_adjudication" if adjudicated else "turn_limit",
			0,
			leaf_state,
			leaf_state,
			perspective_group,
			continuation_policy
		)

	var max_actions: int = int(
		budget.get("max_actions_per_unit", PureStateGameRollout.DEFAULT_MAX_ACTIONS_PER_UNIT)
	)
	var own_max_plans: int = int(
		budget.get("own_max_plans", PureStateGameRollout.DEFAULT_OWN_MAX_PLANS)
	)
	var opponent_max_plans: int = int(
		budget.get("opponent_max_plans", PureStateGameRollout.DEFAULT_OPPONENT_MAX_PLANS)
	)

	var rollout: Dictionary
	if continuation_policy == POLICY_HANDWRITTEN:
		rollout = PureStateGameRollout.play_game(
			leaf_state,
			perspective_group,
			opponent_group,
			remaining_turns,
			max_actions,
			own_max_plans,
			opponent_max_plans,
			false,
			turn_limit_winner
		)
	else:
		var perspective_settings := GameplayAI.neural_settings(
			max_actions,
			own_max_plans,
			max_actions,
			opponent_max_plans,
			neural_checkpoint
		)
		var opponent_settings: Dictionary
		if continuation_policy == POLICY_NEURAL_SELF_PLAY:
			opponent_settings = GameplayAI.neural_settings(
				max_actions,
				own_max_plans,
				max_actions,
				opponent_max_plans,
				neural_checkpoint
			)
		else:
			opponent_settings = GameplayAI.handwritten_settings(
				max_actions,
				own_max_plans,
				max_actions,
				opponent_max_plans
			)
		rollout = PureStateGameRollout.play_game_with_settings(
			leaf_state,
			perspective_group,
			opponent_group,
			perspective_settings,
			opponent_settings,
			remaining_turns,
			false,
			turn_limit_winner
		)

	if not bool(rollout.get("valid", false)):
		return {"valid": false, "error": str(rollout.get("status", "continuation_failed"))}
	var status: String = str(rollout.get("status", ""))
	var winner: String = str(rollout.get("winner", ""))
	var final_state: Dictionary = leaf_state
	var final_state_variant: Variant = rollout.get("final_state", leaf_state)
	if final_state_variant is Dictionary:
		final_state = (final_state_variant as Dictionary).duplicate(true)
	return _continuation_result(
		true,
		status == "terminal",
		false,
		winner,
		str(rollout.get("termination_reason", "")),
		int(rollout.get("turns_played", 0)),
		leaf_state,
		final_state,
		perspective_group,
		continuation_policy
	)


func compare_terminal_results(left: Dictionary, right: Dictionary) -> Dictionary:
	if not bool(left.get("labeled", false)) or not bool(right.get("labeled", false)):
		return {"preferred": false}
	var left_outcome: float = float(left.get("perspective_outcome", 0.0))
	var right_outcome: float = float(right.get("perspective_outcome", 0.0))
	if not is_equal_approx(left_outcome, right_outcome):
		return {
			"preferred": true,
			"left_better": left_outcome > right_outcome,
			"pair_kind": "outcome",
			"weight": OUTCOME_PAIR_WEIGHT,
		}
	if is_equal_approx(left_outcome, 1.0):
		var left_turns: int = int(left.get("turns_played_after_branch", 0))
		var right_turns: int = int(right.get("turns_played_after_branch", 0))
		if left_turns != right_turns:
			return {
				"preferred": true,
				"left_better": left_turns < right_turns,
				"pair_kind": "faster_win",
				"weight": FASTER_WIN_PAIR_WEIGHT,
			}
	return {"preferred": false}


func _response_by_index(candidate: Dictionary, response_index: int) -> Dictionary:
	for response_variant: Variant in candidate.get("responses", []):
		if response_variant is Dictionary and int((response_variant as Dictionary).get("response_index", -1)) == response_index:
			return response_variant as Dictionary
	return {}


func _immediate_branch_outcome(
	state: Dictionary,
	perspective_group: String,
	opponent_group: String,
	captured_by_perspective: bool,
	captured_by_opponent: bool
) -> Dictionary:
	if captured_by_perspective and captured_by_opponent:
		return {
			"terminal": true,
			"winner": "",
			"termination_reason": "simultaneous_command_hex_capture",
		}
	var perspective_alive: int = _alive_count_for_group(state, perspective_group)
	var opponent_alive: int = _alive_count_for_group(state, opponent_group)
	if perspective_alive <= 0 and opponent_alive <= 0:
		return {"terminal": true, "winner": "", "termination_reason": "elimination"}
	if perspective_alive <= 0:
		return {"terminal": true, "winner": opponent_group, "termination_reason": "elimination"}
	if opponent_alive <= 0:
		return {"terminal": true, "winner": perspective_group, "termination_reason": "elimination"}
	if captured_by_perspective:
		return {
			"terminal": true,
			"winner": perspective_group,
			"termination_reason": "command_hex_capture",
		}
	if captured_by_opponent:
		return {
			"terminal": true,
			"winner": opponent_group,
			"termination_reason": "command_hex_capture",
		}
	return {"terminal": false}


func _alive_count_for_group(state: Dictionary, group_name: String) -> int:
	for group_variant: Variant in state.get("groups", []):
		if not (group_variant is Dictionary):
			continue
		var group: Dictionary = group_variant as Dictionary
		if str(group.get("name", "")) != group_name:
			continue
		var count: int = 0
		for unit_variant: Variant in group.get("units", []):
			if unit_variant is Dictionary and int((unit_variant as Dictionary).get("health", 0)) > 0:
				count += 1
		return count
	return 0


func _continuation_result(
	valid: bool,
	labeled: bool,
	leaf_terminal: bool,
	winner: String,
	termination_reason: String,
	turns_played_after_branch: int,
	leaf_state: Dictionary,
	final_state: Dictionary,
	perspective_group: String,
	continuation_policy: String
) -> Dictionary:
	var outcome: float = 0.0
	if labeled and not winner.is_empty():
		outcome = 1.0 if winner == perspective_group else -1.0
	return {
		"valid": valid,
		"labeled": labeled,
		"leaf_terminal": leaf_terminal,
		"winner": winner,
		"perspective_outcome": outcome,
		"termination_reason": termination_reason,
		"turns_played_after_branch": turns_played_after_branch,
		"state_after_first_turn": leaf_state.duplicate(true),
		"final_state": final_state.duplicate(true),
		"continuation_policy": continuation_policy,
	}
