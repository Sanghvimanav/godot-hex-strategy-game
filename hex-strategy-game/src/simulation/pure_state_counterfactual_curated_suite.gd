extends RefCounted
class_name PureStateCounterfactualCuratedSuite
## Hand-authored, named choices for benchmarking strategic behavior.
##
## Each case keeps the situation and candidate choices mechanically coherent.
## Candidate quality is determined by policy-conditional rollouts, not labels.

const TurnExecutionCore = preload("res://src/battle/turn_execution_core.gd")

const SUITE_VERSION := 4
const OPPONENT_MIXTURE_VERSION := "scenario_curated_responses_v4"
const CONTINUATION_MIXTURE_VERSION := "scenario_curated_continuation_1x1_2x2_v4"

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
		_preservation_job(rules_version),
		_spreading_job(rules_version),
		_retreat_job(rules_version),
		_trapped_unit_job(rules_version),
		_coordinated_commitment_job(rules_version),
		_production_pressure_job(rules_version),
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
		"Because the Baneling explodes in the slow-ability phase, should Zerg detonate against two adjacent weakened Marines despite possible disengagement, reposition it, or preserve it?",
		state,
		"zerg",
		"terran",
		[
			_candidate("explode_now", "Explode now", "Commit to a slow-phase explosion that kills weakened Marines only if they remain adjacent.", [
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
			_opponent("weakened_marines_hold", 0.4, [
				_action(1, "attack_short", [0, 0]),
				_action(2, "attack_short", [0, 0]),
				_action(3, "move_short", [1, 0]),
			]),
			_opponent("weak_marines_disengage", 0.3, [
				_action(1, "move_short", [1, -1]),
				_action(2, "move_short", [-1, 1]),
				_action(3, "attack_short", [1, 0]),
			]),
			_opponent("healthy_marine_reinforces", 0.3, [
				_action(1, "attack_short", [0, 0]),
				_action(2, "attack_short", [0, 0]),
				_action(3, "move_short", [1, 0]),
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
			_unit(6, "zergling", [2, 0]),
		]),
	])
	return _job(
		"curated-preserve-wounded-scout",
		"preservation",
		"After one survivable fast hit, should the wounded Scout withdraw and receive healing, remain to shoot while being healed, or withdraw without spending Medic energy?",
		state,
		"terran",
		"zerg",
		[
			_candidate("evacuate_and_heal", "Evacuate and heal", "After the fast hit, move the surviving Scout behind the line and heal its destination.", [
				_action(1, "move_short", [-1, 1]),
				_action(2, "attack_short", [0, 0]),
				_action(3, "heal_adjacent", [-1, 1]),
			]),
			_candidate("shoot_and_heal_in_place", "Shoot and heal in place", "Use the Scout's ray after the fast phase while the Medic restores it on the center cell.", [
				_action(1, "attack_ray", [1, 0]),
				_action(2, "attack_short", [0, 0]),
				_action(3, "heal_adjacent", [0, 0]),
			]),
			_candidate("withdraw_without_heal", "Withdraw without healing", "Move the Scout out and occupy its old cell with the Marine without spending Medic energy.", [
				_action(1, "move_short", [-1, 1]),
				_action(2, "move_short", [0, 0]),
				_action(3, "reload", [-1, 1]),
			]),
		],
		[
			_opponent("single_rush_scout_cell", 0.5, [
				_action(4, "fast_move", [0, 0]),
				_action(5, "fast_move", [1, -1]),
				_action(6, "fast_move", [1, 0]),
			]),
			_opponent("advance_without_contact", 0.3, [
				_action(4, "fast_move", [0, -1]),
				_action(5, "fast_move", [1, -1]),
				_action(6, "fast_move", [1, 0]),
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
			_unit(1, "marine", [0, 0]),
			_unit(2, "marine", [0, 0]),
			_unit(3, "marine", [0, 0]),
		]),
		_group("zerg", [
			_unit(4, "zergling", [2, 0]),
			_unit(5, "zergling", [2, -1]),
			_unit(6, "baneling", [1, 0]),
		]),
	])
	return _job(
		"curated-spread-marine-screen",
		"spreading",
		"With an adjacent Baneling able to explode after normal movement, should the Marines disperse out of its blast radius, hold their concentrated position, or partially spread?",
		state,
		"terran",
		"zerg",
		[
			_candidate("spread_three_hexes", "Spread across three hexes", "Move all three Marines to separate cells outside the Baneling's current adjacent blast area.", [
				_action(1, "move_short", [-1, 0]),
				_action(2, "move_short", [-1, 1]),
				_action(3, "move_short", [0, -1]),
			]),
			_candidate("hold_the_stack", "Hold the stack", "Keep concentrated passive damage on the current cell.", [
				_action(1, "rest_no_energy", [0, 0]),
				_action(2, "rest_no_energy", [0, 0]),
				_action(3, "rest_no_energy", [0, 0]),
			]),
			_candidate("two_forward_one_anchor", "Partial spread", "Move two Marines apart while leaving one Marine exposed on the original cell.", [
				_action(1, "move_short", [-1, 0]),
				_action(2, "move_short", [0, -1]),
				_action(3, "rest_no_energy", [0, 0]),
			]),
		],
		[
			_opponent("baneling_explodes_zerglings_close", 0.45, [
				_action(4, "fast_move", [1, 0]),
				_action(5, "fast_move", [1, -1]),
				_action(6, "explode", [1, 0]),
			]),
			_opponent("zerglings_converge_baneling_holds", 0.3, [
				_action(4, "fast_move", [1, 0]),
				_action(5, "fast_move", [1, 0]),
				_action(6, "reload", [1, 0]),
			]),
			_opponent("zerg_holds", 0.25, [
				_action(4, "reload", [2, 0]),
				_action(5, "reload", [2, -1]),
				_action(6, "reload", [1, 0]),
			]),
		],
		rules_version
	)


static func _retreat_job(rules_version: String) -> Dictionary:
	var state := _state("counterfactual_curated_retreat", 4, [
		_group("terran", [
			_unit(1, "marine", [0, 0], 1),
			_unit(2, "marine", [-1, 0]),
			_unit(3, "marine", [-1, 1]),
		]),
		_group("zerg", [
			# Distance two means fast move can close to attack range this turn,
			# but cannot enter [0,0] and kill the Marine before normal movement.
			_unit(4, "zergling", [2, 0]),
			_unit(5, "zergling", [2, -1]),
			_unit(6, "zergling", [3, -1]),
			_unit(7, "zergling", [2, 1]),
		]),
	])
	return _job(
		"curated-retreat-wounded-marine",
		"retreating",
		"With no Zergling able to reach its cell in the fast phase, should the wounded Marine retreat, hold the intercept tile, or fire at an advancing Zergling?",
		state,
		"terran",
		"zerg",
		[
			_candidate("retreat_behind_line", "Retreat behind the line", "Move the wounded Marine away while the healthy Marines cover both approaches.", [
				_action(1, "move_short", [-1, 1]),
				_action(2, "attack_short", [0, 0]),
				_action(3, "attack_short", [0, 0]),
			]),
			_candidate("hold_intercept", "Hold the intercept", "Stay on the likely convergence cell so passive fire triggers if Zerglings enter.", [
				_action(1, "rest_no_energy", [0, 0]),
				_action(2, "attack_short", [0, 0]),
				_action(3, "attack_short", [0, 0]),
			]),
			_candidate("counterattack", "Counterattack", "Attack the leading Zergling after it fast-moves into [1,0].", [
				_action(1, "attack_short", [1, 0]),
				_action(2, "attack_short", [0, 0]),
				_action(3, "attack_short", [0, 0]),
			]),
		],
		[
			_opponent("advance_to_front", 0.5, [
				_action(4, "fast_move", [1, 0]),
				_action(5, "fast_move", [1, -1]),
				_action(6, "fast_move", [2, -1]),
				_action(7, "fast_move", [1, 1]),
			]),
			_opponent("split_approaches", 0.3, [
				_action(4, "fast_move", [1, 0]),
				_action(5, "fast_move", [1, -1]),
				_action(6, "fast_move", [2, 0]),
				_action(7, "fast_move", [1, 1]),
			]),
			_opponent("zerg_holds", 0.2, [
				_action(4, "reload", [2, 0]),
				_action(5, "reload", [2, -1]),
				_action(6, "reload", [3, -1]),
				_action(7, "reload", [2, 1]),
			]),
		],
		rules_version
	)


static func _trapped_unit_job(rules_version: String) -> Dictionary:
	var state := _state("counterfactual_curated_trapped_unit", 4, [
		_group("terran", [
			# The Zergling is tactically surrounded by Marines with different
			# health values. Fast move plus fast passive damage can finish T1
			# before any Marine normal-phase action resolves.
			_unit(1, "marine", [1, 0], 1),
			_unit(2, "marine", [0, 1], 2),
			_unit(3, "marine", [-1, 1], 4),
			_unit(4, "marine", [-1, 0], 3),
			_unit(5, "marine", [0, -1], 4),
			_unit(7, "marine", [1, -1], 2),
		]),
		_group("zerg", [
			_unit(6, "zergling", [0, 0]),
			# Keeps the first turn nonterminal so the continuation can value
			# the trapped Zergling's final kill through later play.
			_unit(8, "zergling", [-3, 3]),
		]),
	])
	return _job(
		"curated-trapped-zergling-last-kill",
		"trapped_zergling",
		"A surrounded Zergling has one fast move before likely being destroyed. Does it identify the adjacent one-health Marine it can kill before normal actions resolve?",
		state,
		"zerg",
		"terran",
		[
			_candidate("finish_one_health_marine", "Finish the one-health Marine", "Fast-move onto T1 at [1,0]; the passive attack kills it before its normal action.", [
				_action(6, "fast_move", [1, 0]),
				_action(8, "reload", [-3, 3]),
			]),
			_candidate("hit_two_health_marine", "Hit the two-health Marine", "Fast-move onto T2 at [0,1], dealing one damage but leaving it alive for the normal phase.", [
				_action(6, "fast_move", [0, 1]),
				_action(8, "reload", [-3, 3]),
			]),
			_candidate("hit_full_health_marine", "Hit a full-health Marine", "Fast-move onto T3 at [-1,1], dealing one damage to a four-health target.", [
				_action(6, "fast_move", [-1, 1]),
				_action(8, "reload", [-3, 3]),
			]),
		],
		[
			_opponent("surrounding_marines_fire_inward", 0.45, [
				_action(1, "attack_short", [0, 0]),
				_action(2, "attack_short", [0, 0]),
				_action(3, "attack_short", [0, 0]),
				_action(4, "attack_short", [0, 0]),
				_action(5, "attack_short", [0, 0]),
				_action(7, "attack_short", [0, 0]),
			]),
			_opponent("marines_expand_the_ring", 0.35, [
				_action(1, "move_short", [2, 0]),
				_action(2, "move_short", [0, 2]),
				_action(3, "move_short", [-1, 2]),
				_action(4, "move_short", [-2, 0]),
				_action(5, "move_short", [0, -2]),
				_action(7, "move_short", [2, -2]),
			]),
			_opponent("wounded_marines_pull_back", 0.2, [
				_action(1, "move_short", [2, 0]),
				_action(2, "move_short", [0, 2]),
				_action(3, "attack_short", [0, 0]),
				_action(4, "attack_short", [0, 0]),
				_action(5, "attack_short", [0, 0]),
				_action(7, "attack_short", [0, 0]),
			]),
		],
		rules_version
	)


static func _coordinated_commitment_job(rules_version: String) -> Dictionary:
	var state := _state("counterfactual_curated_coordinated_commitment", 4, [
		_group("terran", [
			_unit(1, "marine", [0, 0]),
			_unit(2, "marine", [0, 0]),
			_unit(3, "marine", [0, 0]),
		]),
		_group("zerg", [
			# Each attacker is one hit from death, making distributed targeting
			# materially different from overkilling a single arrival tile.
			_unit(4, "zergling", [2, 0], 1),
			_unit(5, "zergling", [-2, 0], 1),
			_unit(6, "zergling", [0, 2], 1),
		]),
	])
	return _job(
		"curated-coordinate-fire-lanes",
		"coordinated_commitment",
		"Three Zerglings approach the Marine stack from different angles. Should Terran cover all three arrival tiles, concentrate fire on one angle, or cover two angles unevenly?",
		state,
		"terran",
		"zerg",
		[
			_candidate("split_three_angles", "Cover all three angles", "Assign one Marine to each distinct arrival tile.", [
				_action(1, "attack_short", [1, 0]),
				_action(2, "attack_short", [-1, 0]),
				_action(3, "attack_short", [0, 1]),
			]),
			_candidate("focus_east_angle", "Focus one angle", "Commit all three attacks to the eastern arrival tile.", [
				_action(1, "attack_short", [1, 0]),
				_action(2, "attack_short", [1, 0]),
				_action(3, "attack_short", [1, 0]),
			]),
			_candidate("cover_two_angles", "Cover two angles", "Cover east once and west twice while leaving the northern arrival tile untargeted.", [
				_action(1, "attack_short", [1, 0]),
				_action(2, "attack_short", [-1, 0]),
				_action(3, "attack_short", [-1, 0]),
			]),
		],
		[
			_opponent("three_angle_advance", 0.5, [
				_action(4, "fast_move", [1, 0]),
				_action(5, "fast_move", [-1, 0]),
				_action(6, "fast_move", [0, 1]),
			]),
			_opponent("east_and_west_commit_north_feints", 0.3, [
				_action(4, "fast_move", [1, 0]),
				_action(5, "fast_move", [-1, 0]),
				_action(6, "fast_move", [-1, 2]),
			]),
			_opponent("zerg_delays", 0.2, [
				_action(4, "reload", [2, 0]),
				_action(5, "reload", [-2, 0]),
				_action(6, "reload", [0, 2]),
			]),
		],
		rules_version
	)


static func _production_pressure_job(rules_version: String) -> Dictionary:
	var state := _state("counterfactual_curated_production_pressure", 4, [
		_group("terran", [
			_unit(1, "marine", [0, 0]),
			_unit(2, "marine", [0, -1]),
			_unit(3, "marine", [-1, 1]),
		]),
		_group_with_resources("zerg", {"people": 6}, [
			# A Fester is the existing Zerg production unit. At six people and
			# six health it can pay for two Zergling spawns if left alive.
			_unit(4, "fester", [-1, 0]),
			_unit(5, "zergling", [1, 0]),
			_unit(6, "zergling", [1, -1]),
		]),
	])
	return _job(
		"curated-attack-zerg-production-early",
		"production_pressure",
		"The Fester can convert its people stockpile and health into two additional Zerglings over successive spawn phases. Should the Marines damage the producer early enough to limit production, fight the current attackers, or disengage?",
		state,
		"terran",
		"zerg",
		[
			_candidate("focus_fester_early", "Attack the Fester early", "All three Marines damage the Fester before its spawn action, causing the first spawn's health cost to eliminate it and prevent a second spawn.", [
				_action(1, "attack_short", [-1, 0]),
				_action(2, "attack_short", [-1, 0]),
				_action(3, "attack_short", [-1, 0]),
			]),
			_candidate("fight_current_zerglings", "Fight the current attackers", "Use all three attacks on the current Zerglings and leave the producer undamaged for later spawn phases.", [
				_action(1, "attack_short", [1, 0]),
				_action(2, "attack_short", [1, -1]),
				_action(3, "attack_short", [0, 0]),
			]),
			_candidate("disengage_from_production", "Disengage", "Move away from the producer and current attackers, allowing the spawn phase to proceed.", [
				_action(1, "move_short", [0, 1]),
				_action(2, "move_short", [0, -2]),
				_action(3, "move_short", [-2, 1]),
			]),
		],
		[
			_opponent("spawn_and_rush", 0.5, [
				_action(4, "spawn_fester_zergling", [-1, 0]),
				_action(5, "fast_move", [0, 0]),
				_action(6, "fast_move", [0, -1]),
			]),
			_opponent("spawn_and_flank", 0.3, [
				_action(4, "spawn_fester_zergling", [-1, 0]),
				_action(5, "fast_move", [0, 1]),
				_action(6, "fast_move", [0, 0]),
			]),
			_opponent("delay_production", 0.2, [
				_action(4, "rest_no_energy", [-1, 0]),
				_action(5, "reload", [1, 0]),
				_action(6, "reload", [1, -1]),
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


static func _group_with_resources(group_name: String, resources: Dictionary, units: Array) -> Dictionary:
	return {"name": group_name, "resources": resources.duplicate(true), "units": units}


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
