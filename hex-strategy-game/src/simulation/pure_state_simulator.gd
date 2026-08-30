extends RefCounted
class_name PureStateSimulator
## Data-only simulation entry point for hypothetical turn evaluation.
##
## TurnExecutionCore mutates the supplied dictionary state while resolving a turn.
## This wrapper deep-copies both state and submitted actions first so callers can
## safely branch many candidate simulations from the same source position.

const TurnExecutionCore = preload("res://src/battle/turn_execution_core.gd")


## Resolves one simultaneous turn without mutating either input.
## Returns { next_state: Dictionary, recording: Dictionary }.
static func simulate_turn(game_state: Dictionary, player_actions: Dictionary) -> Dictionary:
	var next_state: Dictionary = game_state.duplicate(true)
	var actions_copy: Dictionary = player_actions.duplicate(true)
	var recording: Dictionary = TurnExecutionCore.execute_turn(next_state, actions_copy)
	return {
		"next_state": next_state,
		"recording": recording,
	}
