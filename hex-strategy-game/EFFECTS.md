# Unit effects

Effects are single-turn or multi-turn statuses on a unit (stun, heal over time, movement buff, etc.). They live on `Unit.active_effects`, are ticked at **end of turn**, and are saved/restored for replay and undo.

## Effect kinds (`UnitEffect.Kind`)

- **Stun** – Disables all actions for the duration. Used by attacks with `stun_duration` in `actions.gd`. Newly applied stun is queued for the next turn (`pending_first_tick`), so same-turn actions still resolve; each later end-of-turn tick decrements duration.
- **HealOverTime** – Each tick, heals the unit by `params.heal_per_turn` (capped at max health), then decrements duration. Add via abilities/support that push `UnitEffect.new(UnitEffect.Kind.HealOverTime, turns, { "heal_per_turn": 1 })` and `unit.add_effect(effect)`.
- **MovementBuff** – `params.move_bonus` (e.g. +1) is summed in `unit.get_move_range_bonus()`. To make it change move range, move definition resolution would need to take the unit and add this bonus when building move paths (not yet wired).

## Lifecycle

- **Applied** – When an action applies an effect (e.g. Hydralisk attack applies Stun), the effect is added to the unit and, when `apply_damage` is true, appended to `recording.applied_effects` for replay. Newly applied effects skip the same-turn end tick once.
- **Tick** – In `_finish_turn_after_execution`, every active unit has `tick_effects()` called: duration is decremented, expired effects removed, and HealOverTime applies its heal. Effects applied during that execution consume a one-time "pending first tick" flag instead of decrementing immediately.
- **Save/restore** – `before_state[uid].effects` is an array of effect dicts (`to_dict()`). Restore uses `UnitEffect.from_dict()` and `restore_state(..., effects_data)`. Replay reapplies `applied_effects` after applying damage so stun/effects match the executed turn.

## Adding new effect types

1. Add a value to `UnitEffect.Kind` in `effect.gd`.
2. In `to_dict()` / `from_dict()` handle the new kind name.
3. In `Unit.tick_effects()` apply the effect (e.g. heal, or do nothing for passive buffs).
4. Where relevant, use the effect in game logic (e.g. `get_disabled_action_types()` for Stun, `get_move_range_bonus()` for MovementBuff).
