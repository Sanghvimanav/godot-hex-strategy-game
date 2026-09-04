extends RefCounted
class_name PureStateCounterfactualSuite
## Curated decision states for policy-conditional candidate-plan evaluation.
##
## A benchmark job is a decision, not a game. It fixes the state, perspective,
## candidate proposal budget, opponent-plan mixture, and continuation mixture so
## regenerated targets remain comparable within a rules version.

const PureStateSelfPlaySuite = preload("res://src/simulation/pure_state_self_play_suite.gd")
const PureStateCounterfactualReviewSuite = preload("res://src/simulation/pure_state_counterfactual_review_suite.gd")

const SUITE_VERSION := 1
const OPPONENT_MIXTURE_VERSION := "starter_opponent_mixture_v1"
const CONTINUATION_MIXTURE_VERSION := "starter_continuation_mixture_v1"

const OPPONENT_PROFILES := [
	{
		"profile_id": "proposal_fast",
		"max_actions_per_unit": 3,
		"max_plans": 2,
		"preserve_intent_diversity": false,
		"weight": 0.5,
	},
	{
		"profile_id": "proposal_balanced",
		"max_actions_per_unit": 8,
		"max_plans": 4,
		"preserve_intent_diversity": true,
		"weight": 0.5,
	},
]

const CONTINUATION_PROFILES := [
	{
		"profile_id": "search_fast_2x2",
		"max_turns": 6,
		"max_actions_per_unit": 8,
		"own_max_plans": 2,
		"opponent_max_plans": 2,
		"weight": 0.5,
	},
	{
		"profile_id": "search_balanced_4x4",
		"max_turns": 8,
		"max_actions_per_unit": 8,
		"own_max_plans": 4,
		"opponent_max_plans": 4,
		"weight": 0.5,
	},
]


static func available_presets() -> Array[String]:
	return ["smoke", "starter", "human_review"]


static func get_preset(preset_name: String, rules_version: String = "unknown") -> Array:
	match preset_name:
		"smoke":
			var smoke_job := _make_job(
				"cf-baneling-finish-zerg", "baneling_finish", "zerg", "terran", 2, rules_version
			)
			var smoke_config: Dictionary = smoke_job.get("config", {})
			smoke_config["opponent_mixture_version"] = "smoke_opponent_1x1_v1"
			smoke_config["opponent_profiles"] = [{
				"profile_id": "smoke_proposal_1x1",
				"max_actions_per_unit": 3,
				"max_plans": 1,
				"preserve_intent_diversity": false,
				"weight": 1.0,
			}]
			smoke_config["continuation_mixture_version"] = "smoke_continuation_1x1_v1"
			smoke_config["continuation_profiles"] = [{
				"profile_id": "smoke_search_1x1",
				"max_turns": 2,
				"max_actions_per_unit": 3,
				"own_max_plans": 1,
				"opponent_max_plans": 1,
				"weight": 1.0,
			}]
			return [smoke_job]
		"human_review":
			return PureStateCounterfactualReviewSuite.get_jobs(rules_version)
		"starter":
			return [
				_make_job("cf-collapse-zerg", "collapse", "zerg", "terran", 6, rules_version),
				_make_job("cf-baneling-finish-zerg", "baneling_finish", "zerg", "terran", 6, rules_version),
				_make_job("cf-marine-spread-terran", "marine_spread", "terran", "zerg", 6, rules_version),
			]
	return []


static func _make_job(
	decision_id: String,
	scenario_id: String,
	perspective_group: String,
	opponent_group: String,
	own_max_plans: int,
	rules_version: String
) -> Dictionary:
	var state := PureStateSelfPlaySuite.build_state(scenario_id)
	state["scenario_id"] = "counterfactual_%s" % scenario_id
	return {
		"decision_id": decision_id,
		"scenario_id": scenario_id,
		"perspective_group": perspective_group,
		"opponent_group": opponent_group,
		"state": state,
		"config": {
			"rules_version": rules_version,
			"own_max_actions_per_unit": 8,
			"own_max_plans": own_max_plans,
			"opponent_mixture_version": OPPONENT_MIXTURE_VERSION,
			"opponent_profiles": OPPONENT_PROFILES.duplicate(true),
			"continuation_mixture_version": CONTINUATION_MIXTURE_VERSION,
			"continuation_profiles": CONTINUATION_PROFILES.duplicate(true),
			"separation_z": 1.96,
			"include_states": true,
		},
	}
