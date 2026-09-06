extends RefCounted
class_name PureStateCounterfactualCuratedSuite
## Hand-authored, named choices for benchmarking strategic behavior.
##
## Each case keeps the situation and candidate choices mechanically coherent.
## Candidate quality is determined by policy-conditional rollouts, not labels.

const TurnExecutionCore = preload("res://src/battle/turn_execution_core.gd")

const SUITE_VERSION := 7
const OPPONENT_MIXTURE_VERSION := "scenario_curated_responses_v7"
const CONTINUATION_MIXTURE_VERSION := "scenario_curated_continuation_1x1_2x2_v5"

const CONTINUATION_PROFILES := [
	{
		"profile_id": "curated_fast_1x1",
		"max_turns": 3,
		"max_actions_per_unit": 5,
		"own_max_plans": 1,
		"opponent_max_plans": 1,
		"weight": 0.5,
	},
	{
		"profile_id": "curated_balanced_2x2",
		"max_turns": 4,
		"max_actions_per_unit": 8,
		"own_max_plans": 2,
		"opponent_max_plans": 2,
		"weight": 0.5,
	},
]


static func get_jobs(rules_version: String = "unknown") -> Array:
	return [
		_sacrifice_job(rules_version),
		_stacked_sacrifice_job(rules_version),
		_preservation_job(rules_version),
		_spreading_job(rules_version),
		_coordinated_commitment_job(rules_version),
	]


static func _sacrifice_job(rules_version: String) -> Dictionary:
	var state := _state("counterfactual_curated_sacrifice", 4, [
		_group("terran", [
			_unit(1, "marine", [1, 0], 2),
			_unit(2, "marine", [0, 1], 2),
			_unit(3, "marine", [2, 0]),
		]),
		_group("zerg", [
			_unit(4, "baneling", [0, 0]),
			_unit(5, "zergling", [-1, 0]),
			_unit(6, "zergling", [-1, 1]),
		]),
	])
	return _job(
		"curated-sacrifice-baneling",
		"sacrifice",
		"Because the Baneling explodes in the slow-ability phase, should Zerg detonate against two adjacent weakened Marines that can move outward beyond the blast radius, reposition it, or preserve it?",
		state,
		"zerg",
		"terran",
		[
			_candidate("explode_now", "Explode now", "Commit to a slow-phase explosion that kills weakened Marines only if they remain within the center-plus-adjacent blast area.", [
				_action(4, "explode", [0, 0]),
				_action(5, "fast_move", [0, 0]),
				_action(6, "reload", [-1, 1]),
			]),
			_candidate("preserve_and_pressure", "Preserve and pressure", "Keep the Baneling alive while the Zerglings pressure the weakened Marines' starting cells.", [
				_action(4, "reload", [0, 0]),
				_action(5, "fast_move", [1, 0]),
				_action(6, "fast_move", [0, 1]),
			]),
			_candidate("withdraw_baneling", "Withdraw Baneling", "Move the Baneling away and preserve all three attackers for a later engagement.", [
				_action(4, "move_short", [-1, 0]),
				_action(5, "reload", [-1, 0]),
				_action(6, "reload", [-1, 1]),
			]),
		],
		[
			# Escaping the slow blast is the strongest Marine stress response here.
			_opponent("weakened_marines_hold", 0.1, [
				_action(1, "attack_short", [0, 0]),
				_action(2, "attack_short", [0, 0]),
				_action(3, "move_short", [1, 0]),
			]),
			_opponent("weak_marines_escape_blast", 0.65, [
				# From distance one, a normal one-hex move can reach distance two
				# before the Baneling's slow explosion resolves.
				_action(1, "move_short", [2, -1]),
				_action(2, "move_short", [-1, 2]),
				_action(3, "attack_short", [1, 0]),
			]),
			_opponent("healthy_marine_reinforces", 0.25, [
				_action(1, "attack_short", [0, 0]),
				_action(2, "attack_short", [0, 0]),
				_action(3, "move_short", [1, 0]),
			]),
		],
		rules_version
	)


static func _stacked_sacrifice_job(rules_version: String) -> Dictionary:
	var state := _state("counterfactual_curated_sacrifice_stacked", 4, [
		_group("terran", [
			# Both weakened Marines begin on the Baneling's tile. A one-hex
			# move still ends inside the center-plus-adjacent blast ring.
			_unit(1, "marine", [0, 0], 2),
			_unit(2, "marine", [0, 0], 2),
		]),
		_group("zerg", [
			_unit(4, "baneling", [0, 0]),
			_unit(5, "zergling", [-1, 0]),
			_unit(6, "zergling", [-1, 1]),
		]),
	])
	return _job(
		"curated-sacrifice-baneling-stacked",
		"sacrifice_stacked",
		"Two weakened Marines share the Baneling's tile. Because a one-hex move still leaves them inside its blast radius, should Zerg take the guaranteed terminal trade now, preserve the Baneling, or withdraw it?",
		state,
		"zerg",
		"terran",
		[
			_candidate("explode_now_stacked", "Explode while stacked", "Detonate on the shared tile; movement cannot save either weakened Marine.", [
				_action(4, "explode", [0, 0]),
				_action(5, "reload", [-1, 0]),
				_action(6, "reload", [-1, 1]),
			]),
			_candidate("preserve_stacked", "Preserve the Baneling", "Do not detonate despite already having both remaining Marines trapped within one-move blast range.", [
				_action(4, "reload", [0, 0]),
				_action(5, "reload", [-1, 0]),
				_action(6, "reload", [-1, 1]),
			]),
			_candidate("withdraw_stacked", "Withdraw the Baneling", "Move the Baneling away before the slow phase and give up the guaranteed two-Marine finish.", [
				_action(4, "move_short", [0, -1]),
				_action(5, "reload", [-1, 0]),
				_action(6, "reload", [-1, 1]),
			]),
		],
		[
			_opponent("stacked_marines_hold", 0.4, [
				_action(1, "rest_no_energy", [0, 0]),
				_action(2, "rest_no_energy", [0, 0]),
			]),
			_opponent("stacked_marines_step_out", 0.3, [
				_action(1, "move_short", [1, -1]),
				_action(2, "move_short", [-1, 1]),
			]),
			_opponent("stacked_marines_split_edges", 0.3, [
				_action(1, "move_short", [1, 0]),
				_action(2, "move_short", [0, 1]),
			]),
		],
		rules_version
	)


static func _preservation_job(rules_version: String) -> Dictionary:
	var state := _state("counterfactual_curated_preservation", 4, [
		_group("terran", [
			# One adjacent Zergling can hit in the fast phase, but cannot kill
			# the Scout before its normal move and the Medic's normal heal.
			_unit(1, "scout", [0, 0], 2),
			_unit(2, "marine", [-1, 0]),
			_unit(3, "medic", [-1, 1]),
		]),
		_group("zerg", [
			_unit(4, "zergling", [1, 0]),
			_unit(5, "zergling", [2, -1]),
			# The Hydralisk starts exactly two hexes from the Scout. Staying at
			# [0,0] remains in Needle Spine range; retreating to [-1,1] breaks it.
			_unit(6, "hydralisk", [2, 0]),
		]),
	])
	return _job(
		"curated-preserve-wounded-scout",
		"preservation",
		"After one survivable fast hit, should the wounded Scout retreat out of Hydralisk range and receive healing, remain exposed while being healed, or retreat without spending Medic energy?",
		state,
		"terran",
		"zerg",
		[
			_candidate("evacuate_and_heal", "Evacuate and heal", "Take the survivable fast hit, move the Scout behind the line and out of Needle Spine range, then heal its destination.", [
				_action(1, "move_short", [-1, 1]),
				_action(2, "attack_short", [0, 0]),
				_action(3, "heal_adjacent", [-1, 1]),
			]),
			_candidate("shoot_and_heal_in_place", "Shoot and heal in place", "Keep the Scout at [0,0] to fire while the Medic heals it, leaving it in Hydralisk range.", [
				_action(1, "attack_ray", [1, 0]),
				_action(2, "attack_short", [0, 0]),
				_action(3, "heal_adjacent", [0, 0]),
			]),
			_candidate("withdraw_without_heal", "Withdraw without healing", "Move the Scout out of ranged pressure but save the Medic's energy instead of restoring the wounded unit.", [
				_action(1, "move_short", [-1, 1]),
				_action(2, "move_short", [0, 0]),
				_action(3, "reload", [-1, 1]),
			]),
		],
		[
			_opponent("rush_and_hydra_covers_scout_cell", 0.5, [
				_action(4, "fast_move", [0, 0]),
				_action(5, "fast_move", [1, -1]),
				_action(6, "attack_hydralisk", [0, 0]),
			]),
			_opponent("advance_and_hydra_covers_scout_cell", 0.3, [
				_action(4, "fast_move", [0, -1]),
				_action(5, "fast_move", [1, -1]),
				_action(6, "attack_hydralisk", [0, 0]),
			]),
			_opponent("hold_and_reload", 0.2, [
				_action(4, "reload", [1, 0]),
				_action(5, "reload", [2, -1]),
				_action(6, "reload", [2, 0]),
			]),
		],
		rules_version
	)


static func _spreading_job(rules_version: String) -> Dictionary:
	var state := _state("counterfactual_curated_spreading", 4, [
		_group("terran", [
			# The Baneling is already on top of M1. All three Marines are at two
			# health, so any Marine left in the blast dies when it detonates.
			_unit(1, "marine", [0, 0], 2),
			_unit(2, "marine", [-1, 0], 2),
			_unit(3, "marine", [0, -1], 2),
		]),
		_group("zerg", [
			_unit(4, "zergling", [2, -1]),
			_unit(5, "zergling", [2, -2]),
			_unit(6, "baneling", [0, 0]),
		]),
	])
	return _job(
		"curated-spread-marine-screen",
		"spreading",
		"A Baneling shares M1's tile and will detonate after normal movement. Can the other two Marines escape the blast into mutually supporting hexes instead of splitting toward the waiting Zerglings or leaving a Marine inside the blast?",
		state,
		"terran",
		"zerg",
		[
			_candidate("supporting_spread", "Supporting spread", "Accept M1's loss while M2 and M3 move outside the blast to adjacent hexes that can support each other against the Zergling flank.", [
				_action(1, "rest_no_energy", [0, 0]),
				_action(2, "move_short", [-1, -1]),
				_action(3, "move_short", [0, -2]),
			]),
			_candidate("wide_split_toward_zerglings", "Wide split toward the flank", "Both exposed Marines escape the Baneling, but M3 moves toward the Zergling approach and becomes isolated from M2.", [
				_action(1, "rest_no_energy", [0, 0]),
				_action(2, "move_short", [-2, 0]),
				_action(3, "move_short", [1, -2]),
			]),
			_candidate("leave_one_in_blast", "Leave one in the blast", "Move only M2 to safety while M3 remains adjacent to the Baneling and dies with M1 if it explodes.", [
				_action(1, "rest_no_energy", [0, 0]),
				_action(2, "move_short", [-1, -1]),
				_action(3, "rest_no_energy", [0, -1]),
			]),
		],
		[
			_opponent("explode_and_stack_flank", 0.5, [
				# The pair stacks at [1,-1]. From there they are two hexes from
				# either supporting-spread survivor but one from the isolated M3.
				_action(4, "fast_move", [1, -1]),
				_action(5, "fast_move", [1, -1]),
				_action(6, "explode", [0, 0]),
			]),
			_opponent("explode_and_split_flank", 0.3, [
				_action(4, "fast_move", [1, 0]),
				_action(5, "fast_move", [1, -1]),
				_action(6, "explode", [0, 0]),
			]),
			_opponent("explode_while_zerglings_hold", 0.2, [
				_action(4, "reload", [2, -1]),
				_action(5, "reload", [2, -2]),
				_action(6, "explode", [0, 0]),
			]),
		],
		rules_version
	)


static func _coordinated_commitment_job(rules_version: String) -> Dictionary:
	var state := _state("counterfactual_curated_coordinated_commitment", 4, [
		_group("terran", [
			# Any Zergling that breaches the center next turn can wipe the stack
			# with its fast passive attack, so every Marine starts at one health.
			_unit(1, "marine", [0, 0], 1),
			_unit(2, "marine", [0, 0], 1),
			_unit(3, "marine", [0, 0], 1),
		]),
		_group("zerg", [
			# Four one-health attackers can all reach distinct adjacent arrival
			# hexes this turn. One east-facing Marine shot covers two arrivals.
			_unit(4, "zergling", [2, 0], 1),
			_unit(5, "zergling", [2, -2], 1),
			_unit(6, "zergling", [-2, 0], 1),
			_unit(7, "zergling", [0, 2], 1),
		]),
	])
	return _job(
		"curated-coordinate-fire-lanes",
		"coordinated_commitment",
		"Four one-health Zerglings converge on a one-health Marine stack. Can Terran coordinate three AoE shots to cover all four arrivals instead of overcommitting the formation to one flank or leaving a lane uncovered?",
		state,
		"terran",
		"zerg",
		[
			_candidate("cover_all_four_with_aoe", "Cover all four with AoE", "Use the east shot's side splash to kill two arrivals, then assign the other Marines to west and north so all four Zerglings die this turn.", [
				_action(1, "attack_short", [1, 0]),
				_action(2, "attack_short", [-1, 0]),
				_action(3, "attack_short", [0, 1]),
			]),
			_candidate("commit_east_flank", "Commit the east flank", "Shift the entire Marine formation into the eastern lane, crushing the local pair through same-cell passive fire but abandoning west and north coverage.", [
				_action(1, "move_short", [1, 0]),
				_action(2, "move_short", [1, -1]),
				_action(3, "move_short", [1, 0]),
			]),
			_candidate("cover_three_leave_north", "Cover three and leave north", "Kill the east pair and west attacker but waste the third shot on west, leaving the northern Zergling alive to breach the stack next turn.", [
				_action(1, "attack_short", [1, 0]),
				_action(2, "attack_short", [-1, 0]),
				_action(3, "attack_short", [-1, 0]),
			]),
		],
		[
			_opponent("four_angle_advance", 0.6, [
				_action(4, "fast_move", [1, 0]),
				_action(5, "fast_move", [1, -1]),
				_action(6, "fast_move", [-1, 0]),
				_action(7, "fast_move", [0, 1]),
			]),
			_opponent("east_pair_commit_others_feint", 0.2, [
				_action(4, "fast_move", [1, 0]),
				_action(5, "fast_move", [1, -1]),
				_action(6, "fast_move", [-2, 1]),
				_action(7, "fast_move", [-1, 2]),
			]),
			_opponent("zerg_delays", 0.2, [
				_action(4, "reload", [2, 0]),
				_action(5, "reload", [2, -2]),
				_action(6, "reload", [-2, 0]),
				_action(7, "reload", [0, 2]),
			]),
		],
		rules_version
	)


static func _job(
	decision_id: String,
	behavior_id: String,
	scenario_prompt: String,
	state: Dictionary,
	perspective_group: String,
	opponent_group: String,
	candidates: Array,
	opponent_samples: Array,
	rules_version: String
) -> Dictionary:
	return {
		"decision_id": decision_id,
		"scenario_id": str(state.get("scenario_id", decision_id)),
		"behavior_id": behavior_id,
		"scenario_prompt": scenario_prompt,
		"perspective_group": perspective_group,
		"opponent_group": opponent_group,
		"state": state,
		"config": {
			"rules_version": rules_version,
			"own_candidates": candidates,
			"opponent_mixture_version": OPPONENT_MIXTURE_VERSION,
			"opponent_samples": opponent_samples,
			"continuation_mixture_version": CONTINUATION_MIXTURE_VERSION,
			"continuation_profiles": CONTINUATION_PROFILES.duplicate(true),
			"separation_z": 1.96,
			"include_states": true,
		},
	}


static func _candidate(candidate_id: String, label: String, description: String, actions: Array) -> Dictionary:
	return {
		"candidate_id": candidate_id,
		"candidate_label": label,
		"candidate_description": description,
		"actions": actions,
	}


static func _opponent(sample_id: String, weight: float, actions: Array) -> Dictionary:
	return {
		"sample_id": sample_id,
		"profile_id": "scenario_curated_response",
		"weight": weight,
		"actions": actions,
	}


static func _action(unit_id: int, action_key: String, end_point: Array) -> Dictionary:
	var path: Array = []
	if action_key in ["fast_move", "move_short"]:
		path = [end_point.duplicate()]
	return {
		"unit_id": unit_id,
		"action_key": action_key,
		"path": path,
		"end_point": end_point.duplicate(),
	}


static func _state(scenario_id: String, hex_radius: int, groups: Array) -> Dictionary:
	return {
		"scenario_id": scenario_id,
		"hex_radius": hex_radius,
		"groups": groups,
		"tile_resources": {},
	}


static func _group(group_name: String, units: Array) -> Dictionary:
	return {"name": group_name, "resources": {}, "units": units}


static func _unit(unit_id: int, unit_type: String, cell: Array, health_override: int = -1) -> Dictionary:
	var def_path := "res://src/unit/definitions/%s.tres" % unit_type
	var def_dict := TurnExecutionCore.get_unit_def(def_path)
	var max_health := int(def_dict.get("max_health", 2))
	var max_energy := int(def_dict.get("max_energy", 0))
	var health := max_health if health_override < 0 else health_override
	return {
		"unit_id": unit_id,
		"def_path": def_path,
		"cell": cell.duplicate(),
		"health": health,
		"max_health": max_health,
		"energy": int(def_dict.get("start_energy", max_energy)),
		"max_energy": max_energy,
		"effects": [],
		"is_active": true,
	}
