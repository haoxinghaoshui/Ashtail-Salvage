extends RefCounted
class_name RunEffectApplier

# M2 effect-first runtime boundary.
# Gameplay-facing state changes pass through this helper or the existing
# RunAssetEffectHandler so UI messages correspond to real run state changes.

const EFFECT_HP_DELTA := &"hp_delta"
const EFFECT_PROTOCOL_PRESSURE_DELTA := &"protocol_pressure_delta"
const EFFECT_PENDING_GOLD_DELTA := &"pending_gold_delta"
const EFFECT_SAFE_GOLD_DELTA := &"safe_gold_delta"
const EFFECT_GROUND_LOOT_ADD := &"ground_loot_add"
const EFFECT_GROUND_LOOT_REMOVE := &"ground_loot_remove"
const EFFECT_BACKPACK_ITEM_ADD := &"backpack_item_add"
const EFFECT_BACKPACK_ITEM_REMOVE := &"backpack_item_remove"
const EFFECT_ROOM_MARK_EXPLORED := &"room_mark_explored"
const EFFECT_ROOM_MARK_CLEARED := &"room_mark_cleared"
const EFFECT_EVENT_MARK_COMPLETED := &"event_mark_completed"
const EFFECT_MONSTER_MARK_DEFEATED := &"monster_mark_defeated"
const EFFECT_MINE_MARK_TRIGGERED := &"mine_mark_triggered"
const EFFECT_RUN_FAIL := &"run_fail"
const EFFECT_RUN_EXTRACT := &"run_extract"
const EFFECT_DEBUG_MARKER := &"debug_marker"

const RunStateMachineScript := preload("res://scripts/core/run/run_state_machine.gd")
const Z1SupplyRules := preload("res://scripts/core/run/z1_supply_rule_service.gd")
const StateSnapshotScript := preload("res://scripts/core/run/run_state_snapshot.gd")
const VitalsScript := preload("res://scripts/core/run/run_vitals_resolver.gd")
const StatusScript := preload("res://scripts/core/run/run_status_service.gd")


static func effect(effect_type: StringName, source: String, payload: Dictionary = {}, target: Variant = null) -> Dictionary:
	return {
		"type": effect_type,
		"source": source,
		"target": target,
		"payload": payload.duplicate(true),
		"read_only_preview": false,
	}


static func effect_hp_delta(amount: int, reason: String) -> Dictionary:
	return effect(EFFECT_HP_DELTA, reason, {"amount": amount, "reason": reason})


static func effect_protocol_pressure_delta(amount: int, reason: String) -> Dictionary:
	return effect(EFFECT_PROTOCOL_PRESSURE_DELTA, reason, {"amount": amount, "reason": reason})


static func effect_room_mark_explored(pos: Vector2i, reason: String = "room_enter") -> Dictionary:
	return effect(EFFECT_ROOM_MARK_EXPLORED, reason, {"position": pos}, pos)


static func effect_mine_mark_triggered(pos: Vector2i) -> Dictionary:
	return effect(EFFECT_MINE_MARK_TRIGGERED, "mine_triggered", {"position": pos}, pos)


static func apply_effects(context: RunContext, effects: Array, runtime_authority = null) -> Dictionary:
	if context == null:
		return {"ok": false, "reason": "no_active_run", "effect_results": []}
	var before := StateSnapshotScript.capture_context(context)
	var preview := false
	var terminal_effect: Dictionary = {}
	var effect_results: Array[Dictionary] = []
	var produced_transactions: Array = []
	var ok := true
	var reason := ""
	var lethal_reason := "hp_depleted"
	var facts: Array = []
	for raw_effect in effects:
		var effect_dict: Dictionary = _dictionary(raw_effect)
		var effect_type := StringName(effect_dict.get("type", &""))
		preview = preview or bool(effect_dict.get("read_only_preview", false))
		if effect_type in [EFFECT_RUN_FAIL, EFFECT_RUN_EXTRACT]:
			terminal_effect = effect_dict
			continue
		var hp_before := context.hp
		var result := _apply_one(context, effect_type, effect_dict, runtime_authority)
		if hp_before > 0 and context.hp <= 0:
			lethal_reason = str(_dictionary(effect_dict.get("payload", {})).get("reason", effect_dict.get("source", "hp_depleted")))
		if not _dictionary(result.get("facts", {})).is_empty():
			facts.append(result.facts.duplicate(true))
		effect_results.append(result)
		produced_transactions.append_array(_array(result.get("produced_transactions", [])))
		if not bool(result.get("ok", true)):
			ok = false
			reason = String(result.get("reason", effect_type))
			break
	if not ok or preview:
		StateSnapshotScript.install_context(context, before)
		produced_transactions.clear()
		facts.clear()
	elif not terminal_effect.is_empty():
		_apply_one(context, StringName(terminal_effect["type"]), terminal_effect, runtime_authority)
	elif context.hp <= 0 and context.run_active and not context.failed:
		_apply_run_fail(context, {"reason": lethal_reason}, runtime_authority)
	return {
		"ok": ok,
		"reason": reason,
		"facts": facts,
		"effect_results": effect_results,
		"produced_transactions": produced_transactions,
		"transactions": produced_transactions,
		"last_result": effect_results[effect_results.size() - 1] if not effect_results.is_empty() else {},
	}


static func apply_damage(context: RunContext, amount: int, reason: String = "", runtime_authority = null) -> int:
	var damage := maxi(0, amount)
	var source := reason if reason != "" else "damage"
	var result := apply_effects(context, [effect(EFFECT_HP_DELTA, source, {"amount": -damage, "reason": source, "damage_type": _legacy_damage_type(source)})], runtime_authority)
	return int(result.get("last_result", {}).get("facts", {}).get("actual_hp_loss", 0)) if bool(result.get("ok", false)) else 0


static func capture_vitals(context: RunContext) -> Dictionary:
	if context == null:
		return {}
	return {"hp": context.hp, "max_hp": context.max_hp, "shield": context.shield,
		"pressure": context.pressure, "protocol_level": context.protocol_level,
		"counters": context.vitals_counters.duplicate(true), "statuses": context.temporary_statuses.duplicate(true),
		"modifiers": context.vitals_modifiers.duplicate(true)}


static func install_vitals(context: RunContext, state: Dictionary) -> void:
	context.hp = int(state.hp)
	context.max_hp = int(state.max_hp)
	context.shield = int(state.get("shield", 0))
	context.pressure = int(state.get("pressure", 0))
	context.protocol_level = int(state.get("protocol_level", ProtocolService.level_for_pressure(context.pressure)))
	context.vitals_counters = _dictionary(state.get("counters", {}))
	context.temporary_statuses = _array(state.get("statuses", []))
	context.vitals_modifiers = _dictionary(state.get("modifiers", context.vitals_modifiers))


static func apply_damage_packet(context: RunContext, packet: Dictionary) -> Dictionary:
	return _apply_packet(context, packet, "damage")


static func apply_heal_packet(context: RunContext, packet: Dictionary) -> Dictionary:
	return _apply_packet(context, packet, "heal")


static func apply_pressure_packet(context: RunContext, packet: Dictionary) -> Dictionary:
	return _apply_packet(context, packet, "pressure")


static func _apply_packet(context: RunContext, packet: Dictionary, kind: String) -> Dictionary:
	if context == null:
		return {"ok": false, "reason": "no_active_run", "state": {}, "facts": {}}
	if is_z2_run(context) and context.run_active and context.hp > 0 and not context.failed and not context.extracted and not context.abandoned:
		# Validate the original packet before the supply composer reads its arrays.
		# This preview is pure; only the composed packet below is installed.
		var checked := _resolve_packet(context, capture_vitals(context), packet, kind)
		if not bool(checked.ok):
			return checked
		var routed := packet.duplicate(true)
		if kind == "damage" and not routed.has("damage_type"):
			routed.damage_type = _legacy_damage_type(str(routed.get("reason", routed.get("source_id", kind))))
		if kind == "pressure" and not routed.has("source_kind"):
			var source := str(routed.get("reason", routed.get("source_id", "")))
			if source.begins_with("combat"):
				routed.source_kind = "combat"
			elif source in ["event_trap", "event_mechanism", "mechanism"]:
				routed.source_kind = "mechanism"
		# Runtime load avoids a mutual preload: supplies use our final Vitals entry.
		var supplies: Script = load("res://scripts/core/run/z2_supply_runtime.gd")
		var result: Dictionary = supplies.on_event(context, supplies.equipped_items(context), {"kind": kind, "packet": routed})
		if bool(result.get("ok", false)):
			result["state"] = capture_vitals(context)
		return result
	return apply_vitals_packet(context, packet, kind)


# Final low-level entry for an already supply-composed packet. Never routes back
# through Z2SupplyRuntime; numerical rules still live only in RunVitalsResolver.
static func apply_vitals_packet(context: RunContext, packet: Dictionary, kind: String) -> Dictionary:
	if context == null or kind not in ["damage", "heal", "pressure"]:
		return {"ok": false, "reason": "invalid_vitals_target", "state": {}, "facts": {}}
	var result := _resolve_packet(context, capture_vitals(context), packet, kind)
	if bool(result.ok):
		install_vitals(context, result.state)
		_record_vitals(context, kind, result.facts)
	return result


static func is_z2_run(context: RunContext) -> bool:
	return context != null and str(context.profile_fields.get("ruleset_id", "")) == "z2" and context.profile_fields.get("z2_progression_version") == 1


static func _resolve_packet(context: RunContext, state: Dictionary, packet: Dictionary, kind: String) -> Dictionary:
	if not context.vitals_modifiers.get(kind, {}) is Dictionary:
		return {"ok": false, "reason": "invalid_vitals_modifiers", "state": state, "facts": {}}
	var composed := _dictionary(context.vitals_modifiers.get(kind, {}))
	composed.merge(packet.duplicate(true), true)
	composed.source_id = str(packet.get("source_id", packet.get("reason", kind)))
	var result: Dictionary
	match kind:
		"damage":
			var damage_type := str(composed.get("damage_type", _legacy_damage_type(str(composed.get("reason", composed.source_id)))))
			# Exploration is an involuntary HP loss; reuse DOT's shield-bypass path.
			composed.damage_type = "dot" if damage_type == "exploration" else damage_type
			result = VitalsScript.resolve_damage(state, composed)
			if bool(result.ok):
				result.facts.damage_type = damage_type
				result.facts.actual = result.facts.actual_hp_loss
		"heal":
			result = VitalsScript.resolve_heal(state, composed)
			if bool(result.ok):
				result.facts.actual = result.facts.actual_heal
		"pressure":
			if not composed.get("flat_reductions", []) is Array:
				return {"ok": false, "reason": "invalid_packet", "state": state, "facts": {}}
			var reductions := _array(composed.get("flat_reductions", []))
			if not is_z2_run(context):
				if context.protocol_pressure_reduce > 0:
					reductions.append({"amount": context.protocol_pressure_reduce})
				if context.asset_ledger != null:
					var legacy := Z1SupplyRules.pressure_reduction(context, str(composed.get("reason", composed.source_id)))
					if legacy > 0:
						reductions.append({"amount": legacy})
			composed.flat_reductions = reductions
			result = VitalsScript.resolve_pressure(state, composed)
			if bool(result.ok):
				result.facts.actual = result.facts.actual_pressure_delta
	if bool(result.ok):
		result.facts.nominal = composed.amount
		result.facts.kind = kind
	return result


static func _legacy_damage_type(reason: String) -> String:
	if reason in ["mine", "mine_triggered"]:
		return "mine"
	if reason == "dot" or reason.ends_with("_dot"):
		return "dot"
	if reason in ["altar", "event_altar"]:
		return "hp_payment"
	return "physical"


static func _record_vitals(context: RunContext, kind: String, facts: Dictionary) -> void:
	context.record_event(StringName("vitals_" + kind), str(context.active_command.get("command_id", "")),
		StringName(context.active_command.get("actor_id", &"player")), str(facts.get("source_id", kind)), facts)


static func advance_statuses(context: RunContext, delta: float, trigger: Dictionary) -> Dictionary:
	if context == null:
		return {"ok": false, "reason": "no_active_run", "facts": {}, "changed": false, "durability_required": false}
	var before := capture_vitals(context)
	# Validate every optional periodic field before producing any candidate effect.
	for status in context.temporary_statuses:
		if not status is Dictionary:
			return _status_failure(before, "invalid_status")
		for key in ["dot_per_second", "heal_per_second", "dot_remainder", "heal_remainder"]:
			var value: Variant = status.get(key, 0.0)
			if not (value is int or value is float) or not is_finite(float(value)) or float(value) < 0.0 or (key.ends_with("remainder") and float(value) >= 1.0):
				return _status_failure(before, "invalid_periodic_status")
	var result := StatusScript.advance(before, delta, trigger)
	if not bool(result.ok):
		return _status_failure(before, str(result.reason))
	var candidate: Dictionary = result.state
	var routed_before := {}
	var route_supplies := is_z2_run(context)
	var facts: Dictionary = result.facts
	facts.packets = []
	var durable: bool = not facts.started.is_empty() or not facts.ended.is_empty() or not facts.hits_consumed.is_empty()
	for status in candidate.statuses:
		var seconds := float(facts.active_seconds.get(str(status.id), 0.0))
		if seconds <= 0.0:
			continue
		for periodic_kind in ["dot", "heal"]:
			var rate := float(status.get(periodic_kind + "_per_second", 0.0))
			if rate <= 0.0:
				continue
			var remainder_key: String = periodic_kind + "_remainder"
			var accrued := float(status.get(remainder_key, 0.0)) + rate * seconds
			var units := floori(accrued + 0.000000001)
			status[remainder_key] = maxf(0.0, accrued - float(units))
			if units <= 0:
				continue
			var packet := {"amount": units, "source_id": str(status.get("source_id", status.id)), "damage_type": "dot"}
			var packet_kind := "damage" if periodic_kind == "dot" else "heal"
			var applied: Dictionary
			if route_supplies:
				if routed_before.is_empty():
					routed_before = StateSnapshotScript.capture_context(context)
				install_vitals(context, candidate)
				applied = _apply_packet(context, packet, packet_kind)
			else:
				applied = _resolve_packet(context, candidate, packet, packet_kind)
			if not bool(applied.ok):
				if not routed_before.is_empty():
					StateSnapshotScript.install_context(context, routed_before)
				return _status_failure(before, str(applied.reason))
			# Preserve the status array being advanced while installing candidate resource fields.
			var statuses: Array = candidate.statuses
			candidate = applied.state
			candidate.statuses = statuses
			facts.packets.append(applied.facts)
			durable = durable or int(applied.facts.actual) != 0 or not _dictionary(applied.facts.get("consumed_counters", {})).is_empty()
	var changed := candidate != before
	if changed:
		install_vitals(context, candidate)
	if not route_supplies:
		for fact in facts.packets:
			_record_vitals(context, str(fact.kind), fact)
	if durable:
		context.record_event(&"status_advanced", str(context.active_command.get("command_id", "")), &"player", "simulation_time", facts)
	return {"ok": true, "reason": "", "state": candidate, "facts": facts, "changed": changed, "durability_required": durable}


static func _status_failure(state: Dictionary, reason: String) -> Dictionary:
	return {"ok": false, "reason": reason, "state": state.duplicate(true), "facts": {}, "changed": false, "durability_required": false}


static func _apply_one(context: RunContext, effect_type: StringName, effect_dict: Dictionary, runtime_authority = null) -> Dictionary:
	var payload: Dictionary = _dictionary(effect_dict.get("payload", {}))
	if not payload.has("source_id"):
		payload.source_id = str(effect_dict.get("source", payload.get("reason", "")))
	match effect_type:
		EFFECT_HP_DELTA:
			return _apply_hp_delta(context, payload, runtime_authority)
		EFFECT_PROTOCOL_PRESSURE_DELTA:
			return _apply_pressure_delta(context, payload)
		EFFECT_PENDING_GOLD_DELTA:
			return _apply_currency_delta(context, RunAssetLedger.CURRENCY_BLACK, payload, effect_dict)
		EFFECT_SAFE_GOLD_DELTA:
			return _apply_currency_delta(context, RunAssetLedger.CURRENCY_GOLD, payload, effect_dict)
		EFFECT_GROUND_LOOT_ADD:
			return _apply_item_add(context, RunAssetLedger.LOCATION_ROOM_FLOOR, payload, effect_dict)
		EFFECT_BACKPACK_ITEM_ADD:
			return _apply_item_add(context, RunAssetLedger.LOCATION_INVENTORY, payload, effect_dict)
		EFFECT_GROUND_LOOT_REMOVE, EFFECT_BACKPACK_ITEM_REMOVE:
			return _apply_item_remove(context, payload, effect_dict)
		EFFECT_ROOM_MARK_EXPLORED:
			return _mark_room_state(context, payload, "explored")
		EFFECT_ROOM_MARK_CLEARED:
			return _mark_room_state(context, payload, "cleared")
		EFFECT_EVENT_MARK_COMPLETED:
			return _mark_event_completed(context, payload)
		EFFECT_MONSTER_MARK_DEFEATED:
			return _mark_room_state(context, payload, "monster_defeated")
		EFFECT_MINE_MARK_TRIGGERED:
			return _mark_room_state(context, payload, "mine_triggered")
		EFFECT_RUN_FAIL:
			return _apply_run_fail(context, payload, runtime_authority)
		EFFECT_RUN_EXTRACT:
			return _apply_run_extract(context, runtime_authority)
		EFFECT_DEBUG_MARKER:
			return _apply_debug_marker(context, payload)
	return _result(effect_type, false, "unknown_effect_type", {}, {})


static func _apply_hp_delta(context: RunContext, payload: Dictionary, _runtime_authority = null) -> Dictionary:
	var before := capture_vitals(context)
	var amount := int(payload.get("amount", 0))
	var packet := payload.duplicate(true)
	packet.amount = absi(amount)
	if amount == 0:
		# Legacy zero deltas are no-ops, not a new healing source for flat bonuses.
		packet.flat_bonus = 0
	var applied := apply_damage_packet(context, packet) if amount < 0 or payload.has("damage_type") else apply_heal_packet(context, packet)
	return _result(EFFECT_HP_DELTA, bool(applied.ok), str(applied.reason), before,
		{"hp": context.hp, "amount": amount, "facts": applied.facts, "fail_result": {}})


static func _apply_pressure_delta(context: RunContext, payload: Dictionary) -> Dictionary:
	var before := {"pressure": context.pressure, "protocol_level": context.protocol_level}
	var applied := apply_pressure_packet(context, payload)
	return _result(EFFECT_PROTOCOL_PRESSURE_DELTA, bool(applied.ok), str(applied.reason), before,
		{"pressure": context.pressure, "protocol_level": context.protocol_level, "changed": before.protocol_level != context.protocol_level,
		"penalty": false, "facts": applied.facts})


static func _apply_currency_delta(context: RunContext, currency_id: StringName, payload: Dictionary, effect_dict: Dictionary) -> Dictionary:
	var amount := int(payload.get("amount", 0))
	var asset_effect := _asset_effect(
		RunAssetEffectHandler.EFFECT_ADD_CURRENCY,
		String(effect_dict.get("source", "run_effect_applier")),
		effect_dict.get("target", context.get_current_pos()),
		{"currency_id": currency_id, "amount": amount}
	)
	var applied := RunAssetEffectHandler.apply_effects(context, [asset_effect])
	return _result(StringName(effect_dict.get("type", &"currency_delta")), bool(applied.get("ok", false)), String(applied.get("reason", "")), {}, applied)


static func _apply_item_add(context: RunContext, preferred_location: StringName, payload: Dictionary, effect_dict: Dictionary) -> Dictionary:
	var item_defs: Array = _array(payload.get("item_defs", []))
	if item_defs.is_empty() and payload.has("item_def"):
		item_defs = [_dictionary(payload.get("item_def", {}))]
	var asset_effect := _asset_effect(
		RunAssetEffectHandler.EFFECT_ADD_REWARD_ITEMS,
		String(effect_dict.get("source", "run_effect_applier")),
		effect_dict.get("target", context.get_current_pos()),
		{"item_defs": item_defs, "preferred_location": preferred_location, "room_pos": context.get_current_pos()}
	)
	var applied := RunAssetEffectHandler.apply_effects(context, [asset_effect])
	return _result(StringName(effect_dict.get("type", &"item_add")), bool(applied.get("ok", false)), String(applied.get("reason", "")), {}, applied)


static func _apply_item_remove(context: RunContext, payload: Dictionary, effect_dict: Dictionary) -> Dictionary:
	var instance_id := String(payload.get("instance_id", ""))
	var effect_type := RunAssetEffectHandler.EFFECT_PICKUP_GROUND_ITEM if StringName(effect_dict.get("type", &"")) == EFFECT_GROUND_LOOT_REMOVE else RunAssetEffectHandler.EFFECT_DROP_INVENTORY_ITEM
	var asset_effect := _asset_effect(
		effect_type,
		String(effect_dict.get("source", "run_effect_applier")),
		effect_dict.get("target", context.get_current_pos()),
		{"instance_id": instance_id, "room_pos": context.get_current_pos()}
	)
	var applied := RunAssetEffectHandler.apply_effects(context, [asset_effect])
	return _result(StringName(effect_dict.get("type", &"item_remove")), bool(applied.get("ok", false)), String(applied.get("reason", "")), {}, applied)


static func _mark_room_state(context: RunContext, payload: Dictionary, mark_type: String) -> Dictionary:
	var pos: Vector2i = payload.get("position", context.get_current_pos())
	if context.truth_map == null:
		return _result(StringName("room_mark_%s" % mark_type), false, "no_truth_map", {}, {})
	match mark_type:
		"explored":
			context.truth_map.mark_explored(pos)
			context.explored_cells[context.cell_key(pos)] = true
		"cleared", "monster_defeated":
			context.truth_map.mark_cleared(pos)
		"mine_triggered":
			context.truth_map.mark_triggered(pos)
	if context.intel_map != null:
		context.intel_map.refresh_revealed_cell(pos, context.truth_map)
	return _result(StringName("room_mark_%s" % mark_type), true, "", {"position": pos}, {"position": pos})


static func _mark_event_completed(context: RunContext, payload: Dictionary) -> Dictionary:
	var pos: Vector2i = payload.get("position", context.get_current_pos())
	context.interacted_cells[context.cell_key(pos)] = true
	return _result(EFFECT_EVENT_MARK_COMPLETED, true, "", {"position": pos}, {"position": pos})


static func _apply_run_fail(context: RunContext, payload: Dictionary, runtime_authority = null) -> Dictionary:
	var fail_reason := String(payload.get("reason", "forced_failure"))
	var transition_result: Dictionary
	if runtime_authority != null and runtime_authority.has_method("fail_run"):
		transition_result = runtime_authority.fail_run(fail_reason)
	else:
		var fallback_state_machine = RunStateMachineScript.new()
		transition_result = fallback_state_machine.fail_run(context, fail_reason)
	return _result(EFFECT_RUN_FAIL, true, "", {}, transition_result)


static func _apply_run_extract(context: RunContext, runtime_authority = null) -> Dictionary:
	var transition_result: Dictionary
	if runtime_authority != null and runtime_authority.has_method("debug_force_extract"):
		transition_result = runtime_authority.debug_force_extract()
	else:
		var fallback_state_machine = RunStateMachineScript.new()
		transition_result = fallback_state_machine.force_extract(context)
	return _result(EFFECT_RUN_EXTRACT, true, "", {}, transition_result)


static func _apply_debug_marker(context: RunContext, payload: Dictionary) -> Dictionary:
	var command := String(payload.get("command", "debug_marker"))
	var marker := context.record_debug_command(command, payload)
	return _result(EFFECT_DEBUG_MARKER, true, "", {}, marker)


static func _result(effect_type: StringName, ok: bool, reason: String, before: Dictionary, after: Dictionary) -> Dictionary:
	return {
		"ok": ok,
		"effect_type": effect_type,
		"reason": reason,
		"before": before.duplicate(true),
		"after": after.duplicate(true),
		"facts": _dictionary(after.get("facts", {})),
		"produced_transactions": _array(after.get("produced_transactions", after.get("transactions", []))),
	}


static func _asset_effect(effect_type: StringName, source: String, target: Variant, payload: Dictionary) -> Dictionary:
	return {
		"effect_id": "run_effect_%s" % String(effect_type).replace(".", "_"),
		"type": effect_type,
		"source": source,
		"target": target,
		"payload": payload.duplicate(true),
		"actor_id": &"player",
		"command_id": "",
		"rule_request_id": "run_effect_applier",
	}


static func _dictionary(value: Variant) -> Dictionary:
	if value is Dictionary:
		return value.duplicate(true)
	return {}


static func _array(value: Variant) -> Array:
	if value is Array:
		return value.duplicate(true)
	return []
