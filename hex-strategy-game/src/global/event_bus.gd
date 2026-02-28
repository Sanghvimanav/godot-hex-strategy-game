extends Node
## Event bus: signals are emitted from other scripts (units, UI). Suppress unused_signal in this file.
@warning_ignore_start("unused_signal")
signal show_move_acs(acs)
signal show_attack_acs(acs, from_cell)
signal show_move_path(ac, from_cell)
signal show_selected_unit_cell(cell)
signal planning_started
signal planning_complete
signal execute_turn_requested
signal replay_turn_requested
signal unit_selected_for_planning(unit)
signal unit_pick_requested(unit)
signal show_units_panel(units: Array)
signal show_replay_summary(lines: Array)
signal action_key_selected(action_key)
signal turn_changed(turn_number)
signal replay_available_changed(available: bool)
signal replay_finished
## Resource events: supports unit-driven and scripted/environmental depletion.
signal tile_resource_deplete_requested(q: int, r: int, amount: int, reason: String)
signal tile_resource_changed(q: int, r: int, resource_type: String, amount: int, max_amount: int, reason: String)
signal tile_resource_depleted(q: int, r: int, resource_type: String, reason: String)
@warning_ignore_restore("unused_signal")
