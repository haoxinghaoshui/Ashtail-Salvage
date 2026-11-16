extends RefCounted
class_name Z2QuestFacts

# Adapt committed runtime snapshots to z2_goals. No conditions or rewards here.
# Local RunEventLog.sequence is preserved; the departure base owns global time.
static func build(meta: Dictionary, snapshot: Dictionary) -> Dictionary:
	var result := _dict(snapshot.get("RunResult", snapshot.get("run_result", snapshot)))
	var settlement := _dict(snapshot.get("settlement", result.get("settlement", {})))
	if settlement.get("finalized") != true:
		return {"ok": false, "status": "quest_settlement_not_finalized"}
	var terminal := _dict(settlement.get("terminal_facts", {}))
	var start := _dict(result.get("run_start_config", terminal.get("run_start_config", {}))).duplicate(true)
	var profile := _dict(start.get("profile_fields", {}))
	if not profile.has("z2_fact_sequence_base"):
		return {"ok": false, "status": "quest_departure_sequence_base_missing"}
	var base := int(profile.z2_fact_sequence_base)
	var run_id := str(result.get("run_id", snapshot.get("run_id", terminal.get("run_id", ""))))
	var result_id := str(snapshot.get("result_id", result.get("result_id", "")))
	var source := _array(result.get("run_events", terminal.get("run_events", [])))
	if run_id.is_empty() or result_id.is_empty() or source.is_empty() or base < 0:
		return {"ok": false, "status": "quest_source_identity_missing"}
	var reservation := _dict(_dict(meta.get("z2_quest_departures", {})).get(run_id, {}))
	if reservation.is_empty() or int(reservation.get("base", -1)) != base or int(reservation.get("departure_sequence", -1)) != base + 1:
		return {"ok": false, "status": "quest_departure_not_reserved"}
	if start.has("departure_sequence") and int(start.departure_sequence) != base + 1:
		return {"ok": false, "status": "quest_departure_sequence_conflict"}
	var events: Array[Dictionary] = []
	var ids := {}
	var kinds := {}
	var previous := 0
	var before := _dict(terminal.get("items_before_settlement", {}))
	for raw in source:
		if not raw is Dictionary or int(raw.get("sequence", 0)) != previous + 1 or not raw.get("payload") is Dictionary:
			return {"ok": false, "status": "quest_run_event_gap"}
		previous = int(raw.sequence)
		var id := str(raw.get("event_id", ""))
		if id.is_empty() or ids.has(id):
			return {"ok": false, "status": "quest_event_identity_conflict"}
		ids[id] = true
		if raw.has("global_sequence") and int(raw.global_sequence) != base + previous:
			return {"ok": false, "status": "quest_global_sequence_mismatch"}
		var event: Dictionary = raw.duplicate(true)
		event["global_sequence"] = base + previous
		var payload: Dictionary = event.payload
		if payload.has("position"):
			payload.position = _position(payload.position)
		if event.event_type == "vitals_pressure" and not payload.has("origin"):
			var origin := str(payload.get("source_id", event.get("source", "")))
			if payload.get("source_kind", "") in ["event", "consumable"]:
				payload["origin"] = str(payload.source_kind)
			elif origin.begins_with("event") or origin.begins_with("z2_economy") or origin.begins_with("z2_mechanism"):
				payload["origin"] = "event"
			elif origin.begins_with("consumable") or _dict(before.get(origin, {})).get("item_type") == "consumable" or before.values().any(func(item: Dictionary) -> bool: return item.get("item_id", "") == origin and item.get("item_type", "") == "consumable"):
				payload["origin"] = "consumable"
		if event.event_type == "event_option_selected":
			_project_economy(event, before)
		kinds[str(event.event_type)] = true
		events.append(event)
	if events[0].event_type != "run_started" or not events[0].payload.get("position") is Vector2i or previous <= 1:
		return {"ok": false, "status": "quest_run_start_missing"}
	var stats := _dict(result.get("run_stats", terminal.get("run_stats", {})))
	if not stats.has("mine_hits"):
		return {"ok": false, "status": "quest_mine_evidence_missing"}
	if not start.has("opening_effect") and start.has("opening_effect_id") and start.has("opening_effect_batch"):
		start["opening_effect"] = {"id": str(start.opening_effect_id), "batch": int(start.opening_effect_batch)}
	var facts := {
		"run_id": run_id, "finalized": true, "ending": str(settlement.get("outcome", "")),
		"mode": str(result.get("mode", "standard")), "debug_used": bool(result.get("debug_used", result.get("debug_command_used", false))),
		"run_start_config": start, "run_events": events, "run_stats": stats.duplicate(true),
		"departure_sequence": base + 1, "settlement_sequence": base + previous,
		"warehouse_items": _array(settlement.get("warehouse_items", [])).duplicate(true),
		"items_before_settlement": before.duplicate(true),
		"capacity_before_settlement": _dict(terminal.get("capacity_before_settlement", {})).duplicate(true),
		"exits": _positions(_array(terminal.get("exits", []))),
	}
	for pair in [["hp", "hp"], ["max_hp", "max_hp"], ["stress", "pressure"], ["power", "power"], ["starting_power", "starting_power"], ["starting_pressure", "starting_pressure"]]:
		if terminal.has(pair[0]) or result.has(pair[1]):
			facts[pair[1]] = terminal.get(pair[0], result.get(pair[1]))
	if terminal.has("hidden_exits_at_start"):
		facts["hidden_exits_at_start"] = _positions(_array(terminal.hidden_exits_at_start))
	elif start.has("hidden_exits_at_start"):
		facts["hidden_exits_at_start"] = _positions(_array(start.hidden_exits_at_start))
	# Actual converted gold, not the pre-conversion black-coin count or safe income.
	if _dict(settlement.get("currency_delta", {})).has("gold_coin"):
		facts["black_coin_gold"] = int(settlement.currency_delta.gold_coin)
	if terminal.has("consumable_evidence_complete") or terminal.has("consumable_facts_complete"):
		facts["consumable_evidence_complete"] = terminal.get("consumable_evidence_complete", terminal.get("consumable_facts_complete", false))
	var missing: Array[String] = []
	for pair in [["manual_flag_changed", "M02/A25"], ["consumable_used", "S01"], ["mine_triggered", "A13/A14"], ["power_changed", "A02_peak"], ["work_order_paid", "S06"], ["recovery_delivered", "S08"], ["compression_completed", "S09"], ["altar_offered", "A15"], ["dice_round_settled", "A16"]]:
		if not kinds.has(pair[0]):
			missing.append(pair[1])
	if not facts.get("consumable_evidence_complete", stats.has("consumables_used")):
		missing.append("A20")
	return {"ok": true, "facts": facts, "result_id": result_id, "run_id": run_id, "missing_fact_goal_ids": missing}

static func _project_economy(event: Dictionary, items: Dictionary) -> void:
	var result := _dict(event.payload.get("result", {}))
	if result.get("ok") != true:
		return
	var facts := _dict(result.get("facts", {}))
	var kind := str(facts.get("event_type", result.get("event_type", "")))
	if kind == "savings" and facts.has("interest"):
		var deposit := _dict(facts.get("deposit", {}))
		if deposit.has("deposit_id") and deposit.has("principal") and facts.has("black_income_gross"):
			event.event_type = "savings_withdrawn"
			event.payload = {"transaction_id": str(deposit.deposit_id), "principal": int(deposit.principal), "withdrawn": int(facts.black_income_gross)}
	elif kind == "compress" and facts.get("consumed_instance_ids") is Array:
		var inputs: Array = []
		for id in facts.consumed_instance_ids:
			inputs.append(_dict(items.get(str(id), {})).duplicate(true))
		event.event_type = "compression_completed"
		event.payload = {"inputs": inputs, "output": _dict(facts.get("delivery", {})).duplicate(true)}
		# Pickup must be a real separately committed item_picked_up event. No synthetic sequence.

static func _position(value: Variant) -> Variant:
	if value is Vector2i:
		return value
	if value is Dictionary and value.has("x") and value.has("y"):
		return Vector2i(int(value.x), int(value.y))
	if value is Array and value.size() == 2:
		return Vector2i(int(value[0]), int(value[1]))
	return value

static func _positions(values: Array) -> Array:
	var result: Array = []
	for value in values:
		result.append(_position(value))
	return result

static func _dict(value: Variant) -> Dictionary:
	return value if value is Dictionary else {}

static func _array(value: Variant) -> Array:
	return value if value is Array else []
