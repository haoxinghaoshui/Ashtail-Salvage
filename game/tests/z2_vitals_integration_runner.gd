extends SceneTree

const Effects = preload("res://scripts/core/run/run_effect_applier.gd")
const Context = preload("res://scripts/core/run/run_context.gd")
const Rooms = preload("res://scripts/core/run/room_resolver.gd")
const Combat = preload("res://scripts/core/run/combat_state.gd")
const Snapshot = preload("res://scripts/core/run/run_state_snapshot.gd")
var failures: Array[String] = []
var checks := 0
var effects_api = Effects.new()


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_legacy_pressure_and_terminal()
	_test_protocol_entry()
	var context = _context()
	var fields: Array = []
	for property in context.get_property_list():
		fields.append(str(property.name))
	var ready := true
	for name in ["shield", "vitals_counters", "vitals_modifiers", "temporary_statuses"]:
		_check(fields.has(name), "context_has_" + name)
		ready = ready and fields.has(name)
	for name in ["capture_vitals", "install_vitals", "apply_damage_packet", "apply_heal_packet", "apply_pressure_packet", "advance_statuses"]:
		_check(effects_api.has_method(name), "public_api_" + name)
		ready = ready and effects_api.has_method(name)
	if ready:
		_test_packets_and_legacy_paths()
		_test_rollback_reset_and_snapshot()
		_test_status_accumulation()
		_test_lethal_mine_and_runtime_facts()
		_test_invalid_mine_is_atomic()
	for failure in failures:
		print("Z2_VITALS_INTEGRATION_CASE_FAIL " + failure)
	print("Z2_VITALS_INTEGRATION=%s checks=%d failures=%d" % ["PASS" if failures.is_empty() else "FAIL", checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _context():
	var context = Context.new()
	RunStateMachine.new().start_demo_run(context)
	context.z1_event_flags.enabled = false
	return context


func _call(method: String, args: Array) -> Dictionary:
	return effects_api.callv(method, args)


func _check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)


func _last_fact(context, kind: String) -> Dictionary:
	var events: Array = context.run_event_log.snapshot()
	for index in range(events.size() - 1, -1, -1):
		if str(events[index].event_type) == kind:
			return events[index].payload
	return {}


func _test_legacy_pressure_and_terminal() -> void:
	var context = _context()
	Effects.apply_effects(context, [Effects.effect_protocol_pressure_delta(20, "literal_source")])
	_check(context.pressure == 15, "legacy_pressure_uses_per_packet_cap15")
	context = _context()
	context.hp = 1
	Effects.apply_effects(context, [Effects.effect_hp_delta(-5, "original_lethal_source"), Effects.effect_protocol_pressure_delta(12, "after_lethal"), Effects.effect(Effects.EFFECT_EVENT_MARK_COMPLETED, "last_event", {"position": context.get_current_pos()})])
	_check(context.failed and int(context.result_snapshot.get("pressure", -1)) == 12, "parent_deferred_terminal_keeps_later_pressure")
	_check(_last_fact(context, "run_failed").get("reason") == "original_lethal_source", "original_lethal_reason_survives_batch")
	_check(_last_fact(context, "vitals_damage").get("actual") == 1, "overkill_records_actual_hp_loss")


func _enter(context, pos: Vector2i, room_type: StringName = &"Normal") -> Dictionary:
	context.truth_map.set_room_type(pos, room_type)
	context.player_pos = pos
	context.current_pos = pos
	return Rooms.new().enter_room(context)


func _test_protocol_entry() -> void:
	for fixture in [["simple", 80, 99], ["normal", 60, 99], ["standard", 80, 98], ["hard", 40, 99], ["hell", 20, 99], ["hell", 100, 96], ["normal", 79, 99]]:
		var context = _context()
		context.run_start_config = {"difficulty": StringName(fixture[0]), "selected_difficulty": &"simple"}
		context.pressure = fixture[1]
		context.protocol_level = ProtocolService.level_for_pressure(context.pressure)
		var result := _enter(context, Vector2i(2, 3))
		_check(result.ok and context.hp == fixture[2], "first_entry_pre_pressure_cost_%s_%d" % [fixture[0], fixture[1]])
		var hp: int = context.hp
		var pressure: int = context.pressure
		_enter(context, Vector2i(2, 3))
		_check(context.hp == hp and context.pressure == pressure, "revisit_free_%s_%d" % [fixture[0], fixture[1]])
	var context = _context()
	context.run_start_config = {"selected_difficulty": &"hard"}
	context.pressure = 80
	context.protocol_level = 1
	_enter(context, Vector2i(2, 3))
	_check(context.hp == 97, "selected_difficulty_fallback_uses_actual_string")
	context = _context()
	context.hp = 1
	context.pressure = 80
	context.protocol_level = 1
	context.run_start_config = {"difficulty": &"simple"}
	_enter(context, Vector2i(2, 3))
	_check(context.failed and context.hp == 0 and context.result_snapshot.get("pressure") == 82, "exploration_is_lethal_damage_and_room_pressure_precedes_terminal")
	_check(context.explored_cells.has(context.cell_key(Vector2i(2, 3))), "lethal_entry_records_exploration")


func _test_packets_and_legacy_paths() -> void:
	var context = _context()
	context.shield = 5
	context.vitals_counters = {"block": 1}
	context.vitals_modifiers = {"damage": {"flat_blocks": [{"amount": 2, "counter_key": "block"}]}}
	var result := _call("apply_damage_packet", [context, {"amount": 10, "source_id": "contact"}])
	_check(result.ok and context.hp == 97 and context.shield == 0 and context.vitals_counters.block == 0, "packet_installs_damage_shield_and_counter_before_next_hit")
	_check(result.facts.nominal == 10 and result.facts.actual == 3 and result.facts.absorbed == 5, "packet_nominal_actual_and_absorbed")
	_check(_last_fact(context, "vitals_damage").get("source_id") == "contact", "packet_source_fact_logged")
	context.shield = 20
	context.vitals_modifiers.damage.flat_blocks = [{"amount": 99}]
	result = _call("apply_damage_packet", [context, {"amount": 7, "damage_type": "dot", "source_id": "bleed"}])
	_check(result.ok and context.hp == 90 and context.shield == 20, "dot_bypasses_shield_and_physical_modifiers")
	Effects.apply_effects(context, [Effects.effect_hp_delta(-30, "mine")])
	_check(context.hp == 80 and context.shield == 0, "legacy_mine_classified_without_physical_block")
	context.hp = 10
	context.max_hp = 200
	context.vitals_modifiers.heal = {"base_multiplier": 2.0, "bonus_rate": 0.2, "reduction_multiplier": 0.5}
	Effects.apply_effects(context, [Effects.effect_hp_delta(50, "consumable_heal")])
	_check(context.hp == 65 and _last_fact(context, "vitals_heal").get("actual") == 55, "legacy_heal_uses_same_base_bonuses")
	context.vitals_modifiers.heal.flat_bonus = 10
	Effects.apply_effects(context, [Effects.effect_hp_delta(0, "no_hp_change_event")])
	_check(context.hp == 65 and _last_fact(context, "vitals_heal").get("actual") == 0, "zero_legacy_hp_delta_does_not_invent_bonus_healing")
	context.pressure = 0
	context.protocol_pressure_reduce = 2
	context.vitals_modifiers.pressure = {"percent_reductions": [{"rate": 0.25}], "flat_reductions": [{"amount": 5}]}
	result = _call("apply_pressure_packet", [context, {"amount": 20, "source_id": "combat"}])
	_check(context.pressure == 8 and result.facts.actual == 8, "generic_and_legacy_pressure_modifiers_once")
	context.hp = 1
	result = _call("apply_damage_packet", [context, {"amount": 4, "damage_type": "dot", "source_id": "late_dot"}])
	_check(result.ok and context.hp == 0 and context.run_active and not context.failed, "packet_api_never_finalizes_terminal")
	context = _context()
	context.hp = 2
	context.shield = 99
	result = _call("apply_damage_packet", [context, {"amount": 3, "damage_type": "exploration", "source_id": "room_exploration"}])
	_check(result.ok and context.hp == 0 and context.shield == 99 and result.facts.damage_type == "exploration", "exploration_direct_hp_not_payment_or_shield")
	context.hp = 2
	context.vitals_counters = {"life": 1}
	context.vitals_modifiers = {"damage": {"survivals": [{"source_id": "life_talent", "kind": "talent", "counter_key": "life", "hp": 1}]}}
	result = _call("apply_damage_packet", [context, {"amount": 3, "damage_type": "exploration", "source_id": "room_exploration"}])
	_check(result.ok and context.hp == 1 and context.shield == 99 and context.vitals_counters.life == 0 and result.facts.survival_source == "life_talent", "involuntary_exploration_can_use_survival_and_keeps_own_type")
	context = _context()
	context.shield = 40
	_check(Combat.take_mine_hit(context) == 0 and context.hp == 100 and context.shield == 10, "legacy_combat_mine_returns_actual_loss")
	context.mine_immunity = 1
	Combat.take_mine_hit(context)
	_check(context.mine_immunity == 0 and context.shield == 10, "existing_mine_immunity_retained_once")


func _test_rollback_reset_and_snapshot() -> void:
	var context = _context()
	context.shield = 12
	context.vitals_counters = {"a": 2}
	context.vitals_modifiers = {"damage": {"flat_blocks": [{"amount": 3, "counter_key": "a"}]}}
	context.temporary_statuses = [{"id": "b", "type": "temporary_buff", "temporary_type": "regen", "phase": "active", "remaining": 3.0, "heal_remainder": 0.25}]
	var before := Snapshot.capture_context(context)
	var failed := Effects.apply_effects(context, [Effects.effect_hp_delta(-20, "hit"), Effects.effect(&"bad_vitals_effect", "bad")])
	_check(not failed.ok and Snapshot.capture_context(context) == before, "parent_batch_rollback_preserves_new_fields_and_fact_log")
	var preview := Effects.effect_hp_delta(-20, "preview_hit")
	preview.read_only_preview = true
	Effects.apply_effects(context, [preview])
	_check(Snapshot.capture_context(context) == before, "parent_preview_preserves_new_state_and_facts")
	var captured := _call("capture_vitals", [context])
	captured.counters.a = 99
	captured.statuses[0].heal_remainder = 0.9
	_check(context.vitals_counters.a == 2 and context.temporary_statuses[0].heal_remainder == 0.25, "capture_vitals_is_detached")
	var decoded: Dictionary = Snapshot.decode(JSON.parse_string(JSON.stringify(Snapshot.encode(before))))
	context.shield = 0
	Snapshot.install_context(context, decoded)
	_check(Snapshot.capture_context(context) == before, "new_fields_and_fractional_remainder_exact_snapshot_roundtrip")
	context.reset()
	_check(context.shield == 0 and context.vitals_counters.is_empty() and context.vitals_modifiers.is_empty() and context.temporary_statuses.is_empty(), "all_new_fields_reset_each_run")


func _test_status_accumulation() -> void:
	var context = _context()
	context.hp = 50
	context.shield = 20
	context.temporary_statuses = [{"id": "bleed", "type": "temporary_debuff", "temporary_type": "bleed", "phase": "waiting", "start_trigger": "attack", "remaining": 1.0, "dot_per_second": 3.0}]
	var result := _call("advance_statuses", [context, 5.0, {}])
	_check(result.ok and not result.changed and not result.durability_required and context.hp == 50, "waiting_does_not_tick_or_accumulate")
	result = _call("advance_statuses", [context, 0.25, {"kind": "attack"}])
	_check(result.durability_required and context.hp == 50 and context.temporary_statuses[0].dot_remainder == 0.75, "activation_durable_fraction_saved_without_rounding_damage_up")
	result = _call("advance_statuses", [context, 0.25, {}])
	_check(context.hp == 49 and context.shield == 20 and context.temporary_statuses[0].dot_remainder == 0.5 and result.durability_required, "fractional_dot_accumulates_and_bypasses_shield")
	var checkpoint := Snapshot.capture_context(context)
	_call("advance_statuses", [context, 0.5, {}])
	_check(context.hp == 47 and context.temporary_statuses[0].phase == "ended", "status_expiry_applies_only_active_interval")
	Snapshot.install_context(context, checkpoint)
	_call("advance_statuses", [context, 0.5, {}])
	_check(context.hp == 47, "restored_fraction_replays_exactly")
	context.temporary_statuses = [{"id": "regen", "type": "temporary_buff", "temporary_type": "regen", "phase": "active", "remaining": 2.0, "heal_per_second": 2.0}]
	result = _call("advance_statuses", [context, 0.25, {"kind": "map"}])
	_check(result.changed and not result.durability_required and context.hp == 47, "timer_fraction_only_change_not_per_frame_durable")
	_call("advance_statuses", [context, 0.25, {"kind": "settings"}])
	_check(context.hp == 48, "ordinary_menu_status_heals_keep_running")
	var frozen := Snapshot.capture_context(context)
	result = _call("advance_statuses", [context, 100.0, {"offline": true}])
	_check(not result.changed and Snapshot.capture_context(context) == frozen, "offline_freezes_every_status_and_remainder")
	context.temporary_statuses.append({"id": "bad", "type": "temporary_buff", "temporary_type": "bad", "phase": "active", "heal_per_second": -1.0})
	frozen = Snapshot.capture_context(context)
	result = _call("advance_statuses", [context, 1.0, {}])
	_check(not result.ok and Snapshot.capture_context(context) == frozen, "invalid_later_status_rolls_back_prior_hp_timer_and_logs")


func _test_lethal_mine_and_runtime_facts() -> void:
	var context = _context()
	context.hp = 1
	context.run_start_config = {"difficulty": &"simple"}
	_enter(context, Vector2i(2, 3), &"Mine")
	_check(context.failed and context.pressure == 12 and context.result_snapshot.get("pressure") == 12, "lethal_mine_keeps_explore_and_mine_pressure")
	_check(int(context.run_stats.get("mine_hits", 0)) == 1 and context.truth_map.is_triggered(Vector2i(2, 3)), "lethal_mine_records_trigger_and_count_before_terminal")
	_check(_last_fact(context, "run_failed").get("reason") == "mine", "mine_original_reason_retained")
	var failed_at := -1
	var pressure_at := -1
	for event in context.run_event_log.snapshot():
		if str(event.event_type) == "run_failed":
			failed_at = int(event.sequence)
		if str(event.event_type) == "vitals_pressure":
			pressure_at = int(event.sequence)
	_check(pressure_at >= 0 and failed_at > pressure_at, "all_room_vitals_facts_precede_terminal_event")
	context = _context()
	_enter(context, Vector2i(2, 3), &"Monster")
	context.shield = 8
	var result := Rooms.new().apply_runtime_combat_damage(context, {"damage": 10, "pressure_delta": 4, "damage_kind": "contact", "source_id": "enemy"})
	_check(result.ok and result.damage == 2 and context.run_stats.get("combat_damage") == 2, "legacy_runtime_bridge_statistics_use_actual_loss")


func _test_invalid_mine_is_atomic() -> void:
	var context = _context()
	var pos := Vector2i(2, 3)
	context.truth_map.set_room_type(pos, &"Mine")
	context.player_pos = pos
	context.current_pos = pos
	context.vitals_modifiers = {"damage": {"flat_blocks": "invalid_modifier_array"}}
	context.mine_immunity = 1
	var before := Snapshot.capture_context(context)
	var result := Rooms.new().enter_room(context)
	_check(not result.ok and Snapshot.capture_context(context) == before, "invalid_mine_damage_rejects_room_and_restores_immunity_pressure_markers_logs")
