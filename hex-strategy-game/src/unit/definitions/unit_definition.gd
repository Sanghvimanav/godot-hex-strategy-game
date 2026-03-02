class_name UnitDefinition
extends Resource

enum Type {
	Knight,
	Scout,
	Mage,
	Rogue,
	Peasant,
	Zergling,
	TerranBase,
	Viper,
	SpawningPool,
	Excavator,
	InfantryCamp
}

## Faction for team identity, ally/enemy rules, and future content. Used alongside group assignment.
enum Faction {
	None,
	Zerg,
	Terran
}

@export var name: String
@export var type: Type
@export var faction: Faction = Faction.None
@export var frames: SpriteFrames
## Scale for the unit sprite (e.g. 0.25 for 128x128 sprites to match 32x32 size)
@export var sprite_scale: Vector2 = Vector2.ONE
## Offset for the sprite position (positive Y = down)
@export var sprite_offset: Vector2 = Vector2.ZERO
@export var type_components: Array[PackedScene] = []
## Action keys from Actions registry (e.g. ["move_short"]). Used when move_definitions is empty.
@export var move_action_keys: Array[String] = []
## Action keys from Actions registry for abilities. Used when ability_definitions is empty.
@export var ability_action_keys: Array[String] = []
## Passive action keys - auto-executed each turn in addition to planned action (e.g. attack_passive).
@export var passive_action_keys: Array[String] = []
## Max health (0 = use default 2). Override per unit type.
@export var max_health: int = 0
## Max energy (0 = no energy bar). Scouts and similar units use energy for attacks.
@export var max_energy: int = 0
## Starting energy (-1 = use max_energy). Use 0 for base so it must recharge before healing.
@export var start_energy: int = -1
## Fog of war: hexes visible within this many steps. -1 = full visibility (no fog), 0 = no sight, >0 = sight range.
@export var sight_range: int = -1
## Explicit move definitions. Ignored if move_action_keys is not empty.
@export var move_definitions: Array[ActionDefinition] = []
## Explicit ability definitions. Ignored if ability_action_keys is not empty.
@export var ability_definitions: Array[ActionDefinition] = []

func get_move_definitions_resolved() -> Array[ActionDefinition]:
	if move_action_keys.size() > 0:
		var result: Array[ActionDefinition] = []
		for key in move_action_keys:
			result.append_array(Actions.get_move_definitions_for_action(key))
		return result
	return move_definitions

func get_ability_definitions_resolved() -> Array[ActionDefinition]:
	if ability_action_keys.size() > 0:
		var result: Array[ActionDefinition] = []
		for key in ability_action_keys:
			result.append_array(Actions.get_ability_definitions_for_action(key))
		return result
	return ability_definitions

func get_passive_ability_definitions_resolved() -> Array[ActionDefinition]:
	if passive_action_keys.size() > 0:
		var result: Array[ActionDefinition] = []
		for key in passive_action_keys:
			result.append_array(Actions.get_passive_definitions_for_action(key))
		return result
	return []
