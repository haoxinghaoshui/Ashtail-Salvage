extends RefCounted
class_name G41InRunRuntime

const CombatSimulationScript := preload("res://scripts/gameplay/combat/g41_combat_simulation.gd")
const DeterministicRngScript := preload("res://scripts/gameplay/combat/g41_deterministic_rng.gd")
const MonsterCatalogScript := preload("res://scripts/gameplay/combat/g41_monster_catalog.gd")
const Z2Talents := preload("res://scripts/core/progression/z2_talent_runtime.gd")
const Supplies := preload("res://scripts/core/run/z2_supply_runtime.gd")
const Opening := preload("res://scripts/core/run/z2_opening_runtime.gd")
const FieldWeapons := preload("res://scripts/gameplay/combat/field_weapons.gd")

var runtime_controller
var context: RunContext
var command_bus: CommandBus
var simulation: G41CombatSimulation
var current_room_key: String = ""
var encounter_ordinals: Dictionary = {}
var recent_domain_events: Array[Dictionary] = []
var paused: bool = false
var field_weapons := FieldWeapons.initial_state()
var _flee_authorized: bool = false
var flee_authorized: bool:
	get:
		return _flee_authorized
	set(value):
		# The parent sets this inside the durable flee action, before capture.
		if value and not _flee_authorized:
			_supply_lifecycle("retreat")
		_flee_authorized = value


func export_transaction_state() -> Dictionary:
	return {
		"simulation": null if simulation == null else simulation.export_transaction_state(),
		"current_room_key": current_room_key,
		"encounter_ordinals": encounter_ordinals.duplicate(true),
		"recent_domain_events": recent_domain_events.duplicate(true),
		"paused": paused,
		"flee_authorized": flee_authorized,
		"field_weapons": field_weapons.duplicate(true),
	}


func import_transaction_state(state: Dictionary) -> void:
	current_room_key = String(state.get("current_room_key", ""))
	encounter_ordinals = state.get("encounter_ordinals", {}).duplicate(true)
	recent_domain_events.assign(state.get("recent_domain_events", []).duplicate(true))
	paused = bool(state.get("paused", false))
	field_weapons = state.get("field_weapons", FieldWeapons.initial_state()).duplicate(true)
	# Context already contains the saved statuses; installation is not a retreat.
	_flee_authorized = bool(state.get("flee_authorized", false))
	if state.get("simulation") == null:
		simulation = null
	else:
		if simulation == null:
			simulation = CombatSimulationScript.new() as G41CombatSimulation
		simulation.import_transaction_state(state["simulation"])
	_bind_hit_resolver()


func validate_transaction_state(state: Dictionary) -> bool:
	var required := {"simulation": TYPE_DICTIONARY, "current_room_key": TYPE_STRING, "encounter_ordinals": TYPE_DICTIONARY, "recent_domain_events": TYPE_ARRAY, "paused": TYPE_BOOL, "flee_authorized": TYPE_BOOL}
	if state.has("field_weapons"):
		required["field_weapons"] = TYPE_DICTIONARY
		if not FieldWeapons.valid(state["field_weapons"]):
			return false
	if state.size() != required.size() or not CombatSimulationScript.valid_transaction_value(state):
		return false
	for field in required:
		if not state.has(field):
			return false
		if field == "simulation" and state[field] == null:
			continue
		if typeof(state[field]) != required[field]:
			return false
	for room_key in state.encounter_ordinals:
		if not room_key is String or room_key.is_empty() or not state.encounter_ordinals[room_key] is int or state.encounter_ordinals[room_key] < 1:
			return false
	if not CombatSimulationScript.valid_event_records(state.recent_domain_events):
		return false
	if state.simulation == null:
		return true
	var validator := simulation if simulation != null else CombatSimulationScript.new() as G41CombatSimulation
	return validator.validate_transaction_state(state.simulation)


func bind(next_runtime_controller) -> void:
	runtime_controller = next_runtime_controller
	context = null if runtime_controller == null else runtime_controller.context
	command_bus = null if runtime_controller == null else runtime_controller.command_bus
	_bind_hit_resolver()


func reset() -> void:
	if _z2_supply_enabled() and bool(Supplies.snapshot(context).state.combat_active):
		_supply_lifecycle("combat_ended")
	simulation = null
	current_room_key = ""
	encounter_ordinals.clear()
	recent_domain_events.clear()
	paused = false
	field_weapons = FieldWeapons.initial_state()
	flee_authorized = false


func sync_room(player_local_pos: Vector2) -> void:
	if context == null or not context.run_active or context.truth_map == null:
		reset()
		return
	var next_room_key := context.cell_key(context.get_current_pos())
	if next_room_key != current_room_key:
		simulation = null
		current_room_key = next_room_key
		flee_authorized = false
	if (context.current_room_type != &"Monster" and not _cage_active()) or context.truth_map.is_cleared(context.get_current_pos()):
		simulation = null
		return
	# A successful explicit flee ends this room's simulation before the room
	# transition is committed.  Keep that authorization stable until the
	# authoritative room key changes so a failed transition cannot restart the
	# encounter or charge the flee cost a second time.
	if flee_authorized:
		simulation = null
		return
	if simulation == null:
		_start_current_encounter(player_local_pos)
	elif simulation.active:
		simulation.sync_player_durable_stats(context.hp, context.max_hp, context.power, _context_shield())


func set_paused(next_paused: bool) -> void:
	paused = next_paused
	if simulation != null:
		simulation.set_paused(next_paused)


func advance_frame(delta: float, move_input: Vector2, aim_input: Vector2) -> Dictionary:
	if simulation == null:
		return build_read_only_snapshot()
	# Storage failures freeze inputs and accumulated wall time until the parent
	# clears its persistence barrier. Retained pre-step debt can then be retried.
	if runtime_controller != null and not runtime_controller.persistence_error.is_empty():
		var blocked := build_read_only_snapshot()
		blocked["step_result"] = {"ok": false, "reason": "persistence_retry_required"}
		return blocked
	simulation.set_paused(paused)
	simulation.set_player_input(move_input, aim_input)
	var stepping := simulation
	var outcome := {}
	stepping.advance_frame(delta, func() -> Dictionary:
		outcome["result"] = _commit_fixed_step(stepping)
		return outcome["result"]
	)
	if context == null or not context.run_active:
		reset()
	var snapshot := build_read_only_snapshot()
	if outcome.has("result"):
		snapshot["step_result"] = outcome["result"]
	return snapshot


func _commit_fixed_step(stepping: G41CombatSimulation) -> Dictionary:
	if simulation != stepping or runtime_controller == null:
		return {"ok": false, "reason": "combat_runtime_unavailable"}
	var next_tick := stepping.tick_index + 1
	var payload := {
		"encounter_id": stepping.encounter_id,
		"combat_tick": next_tick,
		"combat_seed": stepping.encounter_seed,
		"durability_required": false,
	}
	var action_id := "combat:%s:tick:%d" % [stepping.encounter_id, next_tick]
	return runtime_controller.execute_atomic_operation(
		&"combat_fixed_step", payload, Callable(self, "_run_fixed_step").bind(stepping, payload), action_id
	)


func _run_fixed_step(stepping: G41CombatSimulation, payload: Dictionary) -> Dictionary:
	var advanced := stepping.advance_pending_step(Callable(self, "_advance_step_time").bind(stepping, payload))
	if not bool(advanced.get("ok", false)):
		return advanced
	var events := stepping.drain_events()
	payload["durability_required"] = bool(payload.get("durability_required", false)) or not events.is_empty()
	var consumed := _consume_domain_events(events)
	consumed["facts"] = events
	consumed["durability_required"] = payload["durability_required"]
	return consumed


func _advance_step_time(stepping: G41CombatSimulation, payload: Dictionary) -> Dictionary:
	advance_field_reload(stepping.FIXED_STEP)
	if stepping.tick_index == 1:
		var supply_started := _supply_lifecycle("combat_started")
		if not bool(supply_started.get("ok", false)):
			return supply_started
		payload["durability_required"] = bool(payload["durability_required"]) or bool(supply_started.get("durability_required", false))
		var started: Dictionary = runtime_controller.advance_simulation_time(0.0, {"kind": "combat_start", "encounter_id": stepping.encounter_id})
		if not bool(started.get("ok", false)):
			return started
		payload["durability_required"] = bool(payload["durability_required"]) or bool(started.get("durability_required", false))
	var begins_attack := (
		stepping.attack_queued
		and stepping.is_player_attack_allowed()
		and StringName(stepping.player.get("state", &"idle")) in [&"idle", &"move"]
		and float(stepping.player.get("attack_cooldown", 0.0)) <= stepping.FIXED_STEP + stepping.EPSILON
	)
	var result: Dictionary = runtime_controller.advance_simulation_time(stepping.FIXED_STEP, {
		"kind": "attack" if begins_attack else "combat_tick", "combat_tick": stepping.tick_index,
	})
	if bool(result.get("ok", false)):
		stepping.sync_player_durable_stats(context.hp, context.max_hp, context.power, _context_shield())
		payload["durability_required"] = bool(payload["durability_required"]) or bool(result.get("durability_required", false))
	return result


func _bind_hit_resolver() -> void:
	if simulation != null:
		simulation.hit_resolver = Callable(self, "_resolve_combat_hit") if runtime_controller != null else Callable()
		simulation.attack_allowed_query = Callable(self, "_opening_attack_allowed") if context != null else Callable()
		var supply_enabled := runtime_controller != null and _z2_supply_enabled()
		simulation.attack_started_resolver = Callable(self, "_on_actual_attack_started") if supply_enabled else Callable()
		simulation.attack_power_resolver = Callable(self, "_resolve_attack_power") if supply_enabled else Callable()


func _z2_supply_enabled() -> bool:
	return context != null and str(context.profile_fields.get("ruleset_id", "")) == "z2" and context.profile_fields.get("z2_progression_version") == 1


func _supply_lifecycle(kind: String) -> Dictionary:
	if not _z2_supply_enabled():
		return {"ok": true, "durability_required": false}
	var before := Supplies.snapshot(context)
	var result := Supplies.on_event(context, Supplies.equipped_items(context), {"kind": kind, "actual": true})
	result["durability_required"] = Supplies.snapshot(context) != before
	return result


func _on_actual_attack_started() -> Dictionary:
	return _supply_lifecycle("first_attack")


func _opening_attack_allowed() -> bool:
	return bool(Opening.public_state(context).attack_allowed)


func _resolve_attack_power(base_power: int) -> int:
	return Supplies.attack_power(context, base_power)


func _resolve_combat_hit(packet: Dictionary) -> Dictionary:
	if runtime_controller == null or not runtime_controller.has_method("apply_combat_hit"):
		return {"ok": false, "reason": "combat_hit_resolver_unavailable"}
	return runtime_controller.apply_combat_hit(packet)


func _context_shield() -> int:
	var value: Variant = context.get("shield")
	return 0 if value == null else int(value)


func equip_field_weapon(weapon: StringName) -> Dictionary:
	if weapon not in [FieldWeapons.AXE, FieldWeapons.RIFLE, FieldWeapons.SCATTER] or _weapon_busy():
		return {"ok": false, "message": "当前无法切换武器。"}
	if weapon == field_weapons["selected"]:
		return {"ok": true, "message": "当前 · " + ("战斧" if weapon == FieldWeapons.AXE else _ammo_label(weapon))}
	return runtime_controller.execute_atomic_operation(&"field_weapon_equip", {"weapon": weapon}, func() -> Dictionary:
		field_weapons["selected"] = weapon
		var label := "战斧" if weapon == FieldWeapons.AXE else _ammo_label(weapon)
		return {"ok": true, "message": "已切换 · " + label}
	)


func reload_field_weapon() -> Dictionary:
	var weapon := StringName(field_weapons["selected"])
	if weapon == FieldWeapons.AXE or _weapon_busy():
		return {"ok": false, "message": "当前无法装填。"}
	var profile: Dictionary = FieldWeapons.PROFILES[weapon]
	var key := String(weapon)
	var count := mini(int(profile["magazine"]) - int(field_weapons["magazines"][key]), int(field_weapons["reserve"]))
	if count <= 0:
		return {"ok": false, "message": "弹匣已满或备用弹不足。"}
	return runtime_controller.execute_atomic_operation(&"field_weapon_reload", {"weapon": weapon}, func() -> Dictionary:
		field_weapons["magazines"][key] += count
		field_weapons["reserve"] -= count
		field_weapons["reload"] = float(profile["reload"])
		return {"ok": true, "message": "装填 · " + _ammo_label(weapon)}
	)


func _weapon_busy() -> bool:
	return float(field_weapons["reload"]) > 0.0 or (has_active_combat()
		and (simulation.attack_queued or simulation.player.get("state") not in [&"idle", &"move"]))


func _ammo_label(weapon: StringName) -> String:
	var profile: Dictionary = FieldWeapons.PROFILES[weapon]
	return "%s %d/%d  备用 %d" % [profile["name"], field_weapons["magazines"][String(weapon)],
		profile["magazine"], field_weapons["reserve"]]


func advance_field_reload(delta: float) -> void:
	field_weapons["reload"] = maxf(0.0, float(field_weapons["reload"]) - delta)


func request_attack(requested_facing: Vector2 = Vector2.ZERO) -> Dictionary:
	if simulation == null or not simulation.active:
		return {"ok": false, "reason": &"combat_not_active"}
	if not _opening_attack_allowed():
		return {"ok": false, "reason": &"opening_attack_blocked", "status": &"attack_blocked", "message": "避战蓄势期间无法攻击，请先结束蓄势。"}
	var selected := StringName(field_weapons["selected"])
	if float(field_weapons["reload"]) > 0.0:
		return {"ok": false, "status": &"attack_blocked", "reason": &"weapon_reloading", "message": "正在装填。"}
	if selected != FieldWeapons.AXE and int(field_weapons["magazines"][String(selected)]) <= 0:
		return {"ok": false, "status": &"attack_blocked", "reason": &"magazine_empty", "message": "弹匣已空，按 R 装填。"}
	var player_state := StringName(simulation.player.get("state", &"idle"))
	var cooldown_before := float(simulation.player.get("attack_cooldown", 0.0))
	var immediate := player_state in [&"idle", &"move"] and cooldown_before <= simulation.EPSILON
	var buffer_window_open := (
		cooldown_before > simulation.EPSILON
		and cooldown_before <= simulation.PLAYER_ATTACK_BUFFER_SECONDS + simulation.EPSILON
	)
	var queued := simulation.queue_player_attack(requested_facing)
	var status := &"attack_blocked"
	if queued:
		simulation.player["field_weapon"] = selected
		status = &"attack_queued" if immediate else &"attack_buffered"
	elif (
		player_state not in [&"hurt", &"dead"]
		and cooldown_before > simulation.PLAYER_ATTACK_BUFFER_SECONDS + simulation.EPSILON
	):
		status = &"attack_cooling_down"
	return {
		"ok": queued,
		"status": status,
		"retry_after_seconds": maxf(0.0, cooldown_before - simulation.PLAYER_ATTACK_BUFFER_SECONDS),
		"buffer_window_open": buffer_window_open,
		"authority": &"G41CombatSimulation",
	}


func request_flee() -> Dictionary:
	if _cage_active():
		return {"ok": false, "reason": &"cage_locked", "message": "围笼战斗结束前无法离开。"}
	if simulation == null or not simulation.active or command_bus == null:
		return {"ok": false, "reason": &"combat_not_active"}
	return command_bus.dispatch(&"flee_runtime_combat", {
		"source": "g41_in_run_runtime",
		"combat_tick": simulation.tick_index,
		"combat_seed": simulation.encounter_seed,
	})


func has_active_combat() -> bool:
	return simulation != null and simulation.active


func is_door_locked() -> bool:
	return _cage_active() or (has_active_combat() and not flee_authorized)


func _cage_active() -> bool:
	return context != null and context.run_active and context.current_room_type == &"Event" and bool(EventService.cage_state(context, context.get_current_pos()).get("active", false))


func get_player_local_position(fallback: Vector2) -> Vector2:
	if simulation == null:
		return fallback
	return Vector2(simulation.player.get("pos", fallback))


func place_player_from_room_entry(player_local_pos: Vector2, entry_direction: Vector2i) -> Dictionary:
	if simulation == null or not simulation.active:
		return {
			"applied": false,
			"reason": &"combat_not_active",
			"position": player_local_pos,
		}
	return simulation.place_player_from_room_entry(
		player_local_pos,
		Vector2(entry_direction)
	)


func build_read_only_snapshot() -> Dictionary:
	var combat: Dictionary = {
		"active": false,
		"paused": paused,
		"cleared": false,
		"defeated": false,
		"player": {},
		"enemies": [],
		"projectiles": [],
		"lasers": [],
	}
	if simulation != null:
		combat = simulation.build_snapshot()
	combat["room_key"] = current_room_key
	combat["door_locked"] = is_door_locked()
	combat["flee_authorized"] = flee_authorized
	combat["cage_active"] = _cage_active()
	combat["authority"] = &"G41CombatSimulation"
	combat["fixed_hz"] = 60
	combat["recent_events"] = recent_domain_events.duplicate(true)
	combat["encounter_id"] = simulation.encounter_id if simulation != null else ""
	var selected := StringName(field_weapons["selected"])
	var input: Dictionary = combat.get("attack_input", {})
	if not input.is_empty():
		if selected != FieldWeapons.AXE:
			input["cooldown_maximum_seconds"] = float(FieldWeapons.PROFILES[selected]["cooldown"]) / Z2Talents.speed_multiplier(simulation.player.get("z2_talents", {}), "attack_speed_percent")
		if float(field_weapons["reload"]) > 0.0 or (selected != FieldWeapons.AXE and int(field_weapons["magazines"][String(selected)]) <= 0):
			input["ready"] = false
			input["buffer_window_open"] = false
	combat["field_weapons"] = field_weapons.duplicate(true)
	return combat


func _start_current_encounter(player_local_pos: Vector2) -> void:
	var ordinal := int(encounter_ordinals.get(current_room_key, 0)) + 1
	encounter_ordinals[current_room_key] = ordinal
	var room_pos := context.get_current_pos()
	var seed := DeterministicRngScript.derive_seed(context.seed_value, room_pos, ordinal)
	var monster_types := _encounter_types(
		context.seed_value,
		room_pos,
		context.current_adjacent_mines
	)
	var identity := CombatState.build_enemy_state(
		context,
		room_pos,
		context.current_adjacent_mines
	)
	if _cage_active():
		var cage := EventService.cage_state(context, room_pos)
		monster_types = [StringName(cage.get("monster_type", &"slime"))]
		var base_power := maxi(0, int(cage.get("base_power", 5)))
		identity["base_power"] = base_power
		identity["enemy_power"] = base_power
		identity["adjacent_power_bonus"] = 0
		identity["enemy_name"] = "围笼对手"
	var mother_profile := MonsterCatalogScript.runtime_profile(
		monster_types[0],
		int(identity.get("enemy_power", 0)),
		String(identity.get("enemy_name", "异常体"))
	)
	mother_profile.merge(identity, true)
	if String(monster_types[0]).begins_with("z1_monster_"):
		mother_profile["enemy_name"] = String(MonsterCatalogScript.definition(monster_types[0]).get("display_name", "异常体"))
	context.enemy_state = mother_profile.duplicate(true)
	var event_type := EventService.get_event_type(context, room_pos) if context.current_room_type == &"Event" else &""
	simulation = CombatSimulationScript.new() as G41CombatSimulation
	simulation.start({
		"seed": seed,
		"encounter_id": "%s/room:%s/encounter:%d" % [String(context.run_id), current_room_key, ordinal],
		"player_pos": player_local_pos,
		"player_facing": Vector2.RIGHT,
		"player_hp": context.hp,
		"player_max_hp": context.max_hp,
		"player_power": context.power,
		"player_shield": _context_shield(),
		"z2_talents": Z2Talents.from_context(context),
		"monster_types": monster_types,
		"enemy_profiles": [mother_profile],
		"arena_obstacles": G41WorldObjectProjection.room_solid_rects(context.current_room_type, event_type),
	})
	_bind_hit_resolver()
	simulation.set_paused(paused)
	_consume_domain_events(simulation.drain_events())


func _encounter_types(
	run_seed: int,
	room_pos: Vector2i = Vector2i.ZERO,
	adjacent_mines: int = 0
) -> Array[StringName]:
	return [MonsterCatalogScript.pick_type_for_cell(run_seed, room_pos, adjacent_mines, context == null or context.mode != &"tutorial")]


func _consume_domain_events(events: Array[Dictionary]) -> Dictionary:
	var encounter := simulation.encounter_id if simulation != null else ""
	for event in events:
		var event_copy := event.duplicate(true)
		event_copy["encounter_id"] = encounter
		recent_domain_events.append(event_copy)
		if recent_domain_events.size() > 32:
			recent_domain_events.pop_front()
		var result := {"ok": true}
		# Damage has already been resolved synchronously by the parent. These
		# events are committed facts, never a second request to deduct HP.
		match StringName(event.get("event_type", &"")):
			&"player_attack_resolved":
				var weapon := String(event.get("weapon", FieldWeapons.AXE))
				if field_weapons["magazines"].has(weapon):
					field_weapons["magazines"][weapon] = maxi(0, int(field_weapons["magazines"][weapon]) - 1)
			&"combat_cleared":
				result = _commit_combat_cleared(event)
			&"player_defeated":
				result = _commit_player_defeated(event)
		if not bool(result.get("ok", false)):
			return result
	return {"ok": true}


func _commit_combat_cleared(event: Dictionary) -> Dictionary:
	var completed_simulation := simulation
	if command_bus == null or completed_simulation == null:
		return {"ok": false, "reason": "combat_runtime_unavailable"}
	if completed_simulation.reward_emitted:
		return {"ok": true}
	var ended := _supply_lifecycle("combat_ended")
	if not bool(ended.get("ok", false)):
		return ended
	var result: Dictionary = command_bus.dispatch(&"resolve_runtime_combat", {
		"source": "g41_combat_simulation",
		"combat_tick": int(event.get("tick", completed_simulation.tick_index)),
		"combat_seed": completed_simulation.encounter_seed,
		"combat_snapshot": completed_simulation.build_snapshot(),
	})
	if bool(result.get("ok", false)):
		# Resolving the room synchronously refreshes the run context and may clear
		# the runtime's current simulation. Commit against the encounter that
		# emitted the event instead of dereferencing the refreshed field.
		completed_simulation.mark_reward_committed()
	return result


func _commit_player_defeated(event: Dictionary) -> Dictionary:
	if context == null or command_bus == null:
		return {"ok": false, "reason": "combat_runtime_unavailable"}
	var ended := _supply_lifecycle("combat_ended")
	if not bool(ended.get("ok", false)):
		return ended
	if context.failed:
		return {"ok": true}
	# Damage is committed first. This fallback covers zero-HP projections that
	# were already synchronized by another authoritative effect.
	return command_bus.dispatch(&"resolve_runtime_combat_defeat", {
		"source": "g41_combat_simulation",
		"combat_tick": int(event.get("tick", 0)),
	})
