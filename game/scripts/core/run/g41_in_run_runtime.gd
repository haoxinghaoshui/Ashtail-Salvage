extends RefCounted
class_name G41InRunRuntime

const CombatSimulationScript := preload("res://scripts/gameplay/combat/g41_combat_simulation.gd")
const DeterministicRngScript := preload("res://scripts/gameplay/combat/g41_deterministic_rng.gd")
const MonsterCatalogScript := preload("res://scripts/gameplay/combat/g41_monster_catalog.gd")

var runtime_controller
var context: RunContext
var command_bus: CommandBus
var simulation: G41CombatSimulation
var current_room_key: String = ""
var encounter_ordinals: Dictionary = {}
var recent_domain_events: Array[Dictionary] = []
var paused: bool = false
var flee_authorized: bool = false


func export_transaction_state() -> Dictionary:
	return {
		"simulation": null if simulation == null else simulation.export_transaction_state(),
		"current_room_key": current_room_key,
		"encounter_ordinals": encounter_ordinals.duplicate(true),
		"recent_domain_events": recent_domain_events.duplicate(true),
		"paused": paused,
		"flee_authorized": flee_authorized,
	}


func import_transaction_state(state: Dictionary) -> void:
	current_room_key = String(state.get("current_room_key", ""))
	encounter_ordinals = state.get("encounter_ordinals", {}).duplicate(true)
	recent_domain_events.assign(state.get("recent_domain_events", []).duplicate(true))
	paused = bool(state.get("paused", false))
	flee_authorized = bool(state.get("flee_authorized", false))
	if state.get("simulation") == null:
		simulation = null
	else:
		if simulation == null:
			simulation = CombatSimulationScript.new() as G41CombatSimulation
		simulation.import_transaction_state(state["simulation"])
	_bind_hit_resolver()


func validate_transaction_state(state: Dictionary) -> bool:
	var required := {"simulation": TYPE_DICTIONARY, "current_room_key": TYPE_STRING, "encounter_ordinals": TYPE_DICTIONARY, "recent_domain_events": TYPE_ARRAY, "paused": TYPE_BOOL, "flee_authorized": TYPE_BOOL}
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
	simulation = null
	current_room_key = ""
	encounter_ordinals.clear()
	recent_domain_events.clear()
	paused = false
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
	if stepping.tick_index == 1:
		var started: Dictionary = runtime_controller.advance_simulation_time(0.0, {"kind": "combat_start", "encounter_id": stepping.encounter_id})
		if not bool(started.get("ok", false)):
			return started
		payload["durability_required"] = bool(payload["durability_required"]) or bool(started.get("durability_required", false))
	var begins_attack := (
		stepping.attack_queued
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


func _resolve_combat_hit(packet: Dictionary) -> Dictionary:
	if runtime_controller == null or not runtime_controller.has_method("apply_combat_hit"):
		return {"ok": false, "reason": "combat_hit_resolver_unavailable"}
	return runtime_controller.apply_combat_hit(packet)


func _context_shield() -> int:
	var value: Variant = context.get("shield")
	return 0 if value == null else int(value)


func request_attack(requested_facing: Vector2 = Vector2.ZERO) -> Dictionary:
	if simulation == null or not simulation.active:
		return {"ok": false, "reason": &"combat_not_active"}
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
	for event in events:
		var event_copy := event.duplicate(true)
		recent_domain_events.append(event_copy)
		if recent_domain_events.size() > 32:
			recent_domain_events.pop_front()
		var result := {"ok": true}
		# Damage has already been resolved synchronously by the parent. These
		# events are committed facts, never a second request to deduct HP.
		match StringName(event.get("event_type", &"")):
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
	if context.failed:
		return {"ok": true}
	# Damage is committed first. This fallback covers zero-HP projections that
	# were already synchronized by another authoritative effect.
	return command_bus.dispatch(&"resolve_runtime_combat_defeat", {
		"source": "g41_combat_simulation",
		"combat_tick": int(event.get("tick", 0)),
	})
