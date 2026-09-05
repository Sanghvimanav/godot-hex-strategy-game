extends RefCounted
class_name PureStateEvaluator
## Lightweight, explainable evaluator for simulated pure-state positions.
##
## This is intentionally separate from PureStatePlans proposal scoring:
## proposal scores decide which plans are worth simulating, while this evaluator
## scores the resulting state after simulation. A learned value model can replace
## or augment this implementation later without changing the simulator/search API.

const PureStateCommandHexRules = preload("res://src/simulation/pure_state_command_hex_rules.gd")

const TERMINAL_WEIGHT := 100000.0
const UNIT_COUNT_WEIGHT := 100.0
const HEALTH_WEIGHT := 10.0
const RESOURCE_WEIGHT := 2.0
const ENERGY_WEIGHT := 1.0


static func evaluate(game_state: Dictionary, group_name: String) -> float:
	return float(evaluate_breakdown(game_state, group_name).get("total", 0.0))


## Returns both the scalar value and the components that produced it so search,
## tests, and developer tooling can inspect why one state outranks another.
static func evaluate_breakdown(game_state: Dictionary, group_name: String) -> Dictionary:
	var own_group := _find_group(game_state, group_name)
	if own_group.is_empty():
		return {
			"valid": false,
			"total": 0.0,
			"terminal": 0.0,
			"unit_count": 0.0,
			"health": 0.0,
			"resources": 0.0,
			"energy": 0.0,
			"objective": 0.0,
		}

	var own := _group_totals(own_group)
	var enemies := {
		"units": 0,
		"health": 0,
		"resources": 0.0,
		"energy": 0,
	}
	var enemy_group_count := 0
	for group_variant in game_state.get("groups", []):
		if not (group_variant is Dictionary):
			continue
		var group: Dictionary = group_variant
		if str(group.get("name", "")) == group_name:
			continue
		enemy_group_count += 1
		var totals := _group_totals(group)
		enemies["units"] = int(enemies["units"]) + int(totals["units"])
		enemies["health"] = int(enemies["health"]) + int(totals["health"])
		enemies["resources"] = float(enemies["resources"]) + float(totals["resources"])
		enemies["energy"] = int(enemies["energy"]) + int(totals["energy"])

	var terminal_component := 0.0
	if enemy_group_count > 0:
		if int(own["units"]) > 0 and int(enemies["units"]) == 0:
			terminal_component = TERMINAL_WEIGHT
		elif int(own["units"]) == 0 and int(enemies["units"]) > 0:
			terminal_component = -TERMINAL_WEIGHT

	var unit_component := float(int(own["units"]) - int(enemies["units"])) * UNIT_COUNT_WEIGHT
	var health_component := float(int(own["health"]) - int(enemies["health"])) * HEALTH_WEIGHT
	var resource_component := (float(own["resources"]) - float(enemies["resources"])) * RESOURCE_WEIGHT
	var energy_component := float(int(own["energy"]) - int(enemies["energy"])) * ENERGY_WEIGHT
	var objective_component := PureStateCommandHexRules.objective_score(game_state, group_name)
	var total := terminal_component + unit_component + health_component + resource_component + energy_component + objective_component

	return {
		"valid": true,
		"total": total,
		"terminal": terminal_component,
		"unit_count": unit_component,
		"health": health_component,
		"resources": resource_component,
		"energy": energy_component,
		"objective": objective_component,
		"friendly_units": int(own["units"]),
		"enemy_units": int(enemies["units"]),
		"friendly_health": int(own["health"]),
		"enemy_health": int(enemies["health"]),
		"friendly_resources": float(own["resources"]),
		"enemy_resources": float(enemies["resources"]),
		"friendly_energy": int(own["energy"]),
		"enemy_energy": int(enemies["energy"]),
	}


static func _find_group(game_state: Dictionary, group_name: String) -> Dictionary:
	for group_variant in game_state.get("groups", []):
		if group_variant is Dictionary and str(group_variant.get("name", "")) == group_name:
			return group_variant
	return {}


static func _group_totals(group: Dictionary) -> Dictionary:
	var alive_units := 0
	var health := 0
	var energy := 0
	for unit_variant in group.get("units", []):
		if not (unit_variant is Dictionary):
			continue
		var unit: Dictionary = unit_variant
		var unit_health := int(unit.get("health", 0))
		if unit_health <= 0:
			continue
		alive_units += 1
		health += unit_health
		energy += maxi(0, int(unit.get("energy", 0)))
	return {
		"units": alive_units,
		"health": health,
		"resources": _resource_total(group.get("resources", {})),
		"energy": energy,
	}


static func _resource_total(resources_variant: Variant) -> float:
	if not (resources_variant is Dictionary):
		return 0.0
	var total := 0.0
	var resources: Dictionary = resources_variant
	for value in resources.values():
		if value is int or value is float:
			total += float(value)
	return total
