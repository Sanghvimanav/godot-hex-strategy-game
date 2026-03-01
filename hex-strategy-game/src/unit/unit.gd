class_name Unit
extends Node2D
## Uses global Actions autoload for ACTION_ORDER etc. (do not preload actions.gd here).

signal movement_complete
signal attack_beginning(ac)
signal attack_complete
signal death_animation_complete

@export var def: UnitDefinition
## Hex coordinate (q, r) for starting position. Use (-9999, -9999) to use scene position.
@export var starting_cell: Vector2i = Vector2i(-9999, -9999)
@export var move_speed_per_cell: float = 0.15
@export var flash_color: Color = Color('#b76954')

@onready var abilities_db: Node = %abilities_db
@onready var sprite: AnimatedSprite2D = %sprite
@onready var health_bar: Node2D = %health_bar
@onready var energy_bar: Node2D = %energy_bar
var _planned_checkmark: Label

var cell: Vector2:
	get:
		return Navigation.world_to_cell(global_position)

var max_health: int = 2
var health: int = 2: set = _set_health
var flash_tween: Tween
var max_energy: int = 0
var energy: int = 0

## Active status effects (Stun, HealOverTime, MovementBuff, etc.). Ticked at end of turn.
var active_effects: Array = []

var is_active: bool:
	get:
		return health > 0

## Assigned during planning phase. Null until assigned.
var _planned_action_backing: ActionInstance = null
var planned_action: ActionInstance:
	get: return _planned_action_backing
	set(v):
		_planned_action_backing = v
		if _planned_checkmark:
			_planned_checkmark.visible = (v != null)
var planned_action_is_move: bool = false

func _ready() -> void:
	if starting_cell.x != -9999 or starting_cell.y != -9999:
		global_position = Navigation.cell_to_world(Vector2(starting_cell.x, starting_cell.y), true)
	else:
		global_position = Navigation.snap_to_tile(global_position, true)
	abilities_db.unit = self
	if def.max_health > 0:
		max_health = def.max_health
		health = max_health
	if health_bar:
		health_bar.init(health, max_health)
	max_energy = def.max_energy
	energy = def.start_energy if def.start_energy >= 0 else max_energy
	if energy_bar:
		energy_bar.visible = max_energy > 0
		if max_energy > 0:
			energy_bar.init(energy, max_energy)
	_setup_planned_checkmark()
	_init_def()

func _setup_planned_checkmark() -> void:
	_planned_checkmark = Label.new()
	_planned_checkmark.text = "✓"
	_planned_checkmark.add_theme_font_size_override("font_size", 18)
	_planned_checkmark.add_theme_color_override("font_color", Color(0.2, 0.9, 0.2))
	_planned_checkmark.position = Vector2(12, -28)
	_planned_checkmark.visible = false
	_planned_checkmark.z_index = 2
	add_child(_planned_checkmark)

func _init_def() -> void:
	sprite.sprite_frames = def.frames
	sprite.scale = def.sprite_scale
	sprite.position += def.sprite_offset
	sprite.play()
	
	for component in def.type_components:
		var comp = component.instantiate() as UnitTypeComponent
		add_child(comp)
		comp.unit = self

func attack(ac: ActionInstance, play_animation: bool = true) -> void:
	var is_passive := ac.definition and ac.definition.action_key in def.passive_action_keys
	if not is_passive and max_energy > 0 and energy > 0:
		energy -= 1
		if energy_bar:
			energy_bar.update_value(energy)
	attack_beginning.emit(ac)
	if play_animation:
		sprite.play('attack')
		if ac.end_point.x < cell.x:
			sprite.flip_h = true
		elif ac.end_point.x > cell.x:
			sprite.flip_h = false
		await sprite.animation_finished
	attack_complete.emit()
	if play_animation:
		sprite.play('idle')

func move_along_path(path: Array) -> void:
	if path.is_empty():
		movement_complete.emit()
		return
	var move_tween = create_tween()
	move_tween.set_ease(Tween.EASE_OUT)
	move_tween.set_trans(Tween.TRANS_CUBIC)
	for pcell in path:
		move_tween.tween_property(
			self,
			'global_position',
			Navigation.cell_to_world(pcell, true),
			move_speed_per_cell
		)
		if pcell.x < cell.x:
			sprite.flip_h = true
		elif pcell.x > cell.x:
			sprite.flip_h = false
	await move_tween.finished
	movement_complete.emit()

func get_attack_paths() -> Array:
	return abilities_db.get_attack_paths()

## Action types this unit cannot perform this turn. Stun disables all actions.
func get_disabled_action_types() -> Array:
	for e in active_effects:
		# Newly applied effects are queued for next turn via pending_first_tick.
		if e is UnitEffect and e.kind == UnitEffect.Kind.Stun and not e.pending_first_tick:
			return Actions.ACTION_ORDER.duplicate()
	return []

## Adds an effect. Newly applied effects skip the current end-of-turn decrement once.
func add_effect(effect: UnitEffect, mark_as_new: bool = true) -> void:
	if effect != null and effect.duration > 0:
		if mark_as_new:
			effect.pending_first_tick = true
		active_effects.append(effect)

## Returns a short string for UI: e.g. "Stun (1), HealOverTime (2)" or "None".
func get_effects_display_text() -> String:
	if active_effects.is_empty():
		return "None"
	var parts: Array[String] = []
	for e in active_effects:
		if not e is UnitEffect:
			continue
		var name_str := ""
		match e.kind:
			UnitEffect.Kind.Stun: name_str = "Stun"
			UnitEffect.Kind.HealOverTime: name_str = "HealOverTime"
			UnitEffect.Kind.MovementBuff: name_str = "MovementBuff"
			_: name_str = "Effect"
		parts.append("%s (%d)" % [name_str, e.duration])
	return ", ".join(parts)

## Call at end of turn: decrement duration, remove expired, apply HealOverTime etc.
## Newly applied effects skip this first tick so they are active next turn.
func tick_effects() -> void:
	var to_remove: Array = []
	for e in active_effects:
		if not e is UnitEffect:
			continue
		if e.pending_first_tick:
			e.pending_first_tick = false
			continue
		if e.kind == UnitEffect.Kind.HealOverTime:
			var heal_per_turn: int = int(e.params.get("heal_per_turn", 0))
			if heal_per_turn > 0:
				health = mini(health + heal_per_turn, max_health)
				if health_bar:
					health_bar.update_value(health)
		e.duration -= 1
		if e.duration <= 0:
			to_remove.append(e)
	for e in to_remove:
		active_effects.erase(e)

## Bonus move range from effects (e.g. MovementBuff). Summed for stacking.
func get_move_range_bonus() -> int:
	var total := 0
	for e in active_effects:
		if e is UnitEffect and e.kind == UnitEffect.Kind.MovementBuff:
			total += int(e.params.get("move_bonus", 0))
	return total

func get_move_paths() -> Array:
	return abilities_db.get_move_paths()

func _set_health(value: int) -> void:
	if value < health and value != 0:
		if flash_tween and flash_tween.is_valid():
			flash_tween.kill()
		sprite.play('hit')
		sprite.modulate = flash_color
		flash_tween = create_tween()
		flash_tween.set_ease(Tween.EASE_OUT)
		flash_tween.tween_property(sprite, 'modulate', Color.WHITE, 0.35)
		# Don't await - lets all hit animations play in parallel (damage applied in one batch)
		sprite.animation_finished.connect(func(): sprite.play('idle'), CONNECT_ONE_SHOT)
	health = value
	if health_bar:
		health_bar.update_value(health)
	if health == 0:
		sprite.play('death')
		if not sprite.animation_finished.is_connected(_on_death_finished):
			sprite.animation_finished.connect(_on_death_finished, CONNECT_ONE_SHOT)
		# Fallback: hide after delay in case death animation doesn't exist or doesn't finish
		get_tree().create_timer(2.0).timeout.connect(_on_death_finished, CONNECT_ONE_SHOT)

func _on_death_finished() -> void:
	death_animation_complete.emit()
	visible = false
	# Don't queue_free: enables replay/undo to restore state

## Restore unit for replay/undo. Sets position, health, energy, effects, and visibility.
func restore_state(target_cell: Vector2, health_val: int, energy_val: int = -1, effects_data: Array = []) -> void:
	global_position = Navigation.cell_to_world(target_cell, true)
	health = health_val
	if energy_val >= 0:
		energy = energy_val
		if energy_bar and max_energy > 0:
			energy_bar.update_value(energy)
	active_effects.clear()
	for d in effects_data:
		if d is Dictionary:
			active_effects.append(UnitEffect.from_dict(d))
	visible = true
	sprite.play("idle")
	sprite.modulate = Color.WHITE
