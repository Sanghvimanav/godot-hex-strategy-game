class_name UnitEffect
extends RefCounted
## Single-turn or multi-turn effect on a unit (stun, heal over time, movement buff, etc.).
## Duration is in turns remaining; tick_effects() decrements each turn.

enum Kind {
	Stun,
	HealOverTime,
	MovementBuff,
}

var kind: Kind
var duration: int
var params: Dictionary
## True when applied during the current execution turn.
## End-of-turn ticking consumes this flag first so duration starts next turn.
var pending_first_tick: bool = false

func _init(p_kind: Kind = Kind.Stun, p_duration: int = 1, p_params: Dictionary = {}) -> void:
	kind = p_kind
	duration = p_duration
	params = p_params

## Serialize for save/replay. Kind as string for readability.
func to_dict() -> Dictionary:
	var kind_name := ""
	match kind:
		Kind.Stun: kind_name = "Stun"
		Kind.HealOverTime: kind_name = "HealOverTime"
		Kind.MovementBuff: kind_name = "MovementBuff"
	return { "kind": kind_name, "duration": duration, "params": params.duplicate() }

static func from_dict(d: Dictionary) -> UnitEffect:
	var k := Kind.Stun
	match d.get("kind", "Stun"):
		"HealOverTime": k = Kind.HealOverTime
		"MovementBuff": k = Kind.MovementBuff
		_: k = Kind.Stun
	return UnitEffect.new(k, int(d.get("duration", 1)), d.get("params", {}).duplicate())