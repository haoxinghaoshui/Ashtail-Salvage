extends RefCounted
class_name Z2RunHooks

const Loot = preload("res://scripts/core/content/z2_loot_catalog.gd")
const Supply = preload("res://scripts/core/run/z2_supply_runtime.gd")
const Opening = preload("res://scripts/core/run/z2_opening_runtime.gd")

static func applies_to(context: RunContext) -> bool:
	return context != null and context.mode != &"tutorial" and context.profile_fields.get("ruleset_id", "") == "z2" and context.profile_fields.get("z2_progression_version") == 1

static func event_hooks(context: RunContext, action_id: String, enter_room: Callable) -> Dictionary:
	var stage := mini(5, int(context.z1_event_flags.get("z2_process", {}).get("altar_tier", 0)) + 1)
	var rules := Loot.process_rules(context, stage)
	var difficulty := str(context.run_start_config.get("difficulty", "normal"))
	rules["difficulty"] = "easy" if difficulty == "simple" else ("normal" if difficulty == "standard" else difficulty)
	# Inherit the existing Z1 mechanisms' ordinary damage and discrete draws.
	rules["mechanism_failure_damage_type"] = "physical"
	rules["electric_damage_type"] = "physical"
	rules["rps_reward_pool"] = range(10, 41)
	var enemies: Array = []
	for type in ["slime", "bat", "drone"]:
		for power in range(5, 21):
			enemies.append({"enemy_id": type, "original_power": power})
	rules["enemy_pool"] = enemies
	return {"action_id": action_id, "economy_catalog": Loot.economy_catalog(context), "process_rules": rules,
		"enter_room": enter_room, "consume_stage": consume_stage, "consume_income": consume_income, "consume_facts": consume_facts}

static func consume_stage(context: RunContext, fact: Dictionary) -> Dictionary:
	var payload := fact.duplicate(true)
	payload["position"] = room_position(str(fact.get("room_key", "")))
	if bool(fact.get("equipment_eligible", false)):
		var supplied := Supply.on_event(context, context.asset_ledger.get_items_by_location(&"equipped"), {
			"kind": "event_stage", "event_id": str(fact.get("equipment_key", "")), "valid": true, "noncombat": true})
		if not supplied.get("ok", false):
			return supplied
		var event := str(fact.get("event_type", ""))
		var facts: Dictionary = fact.get("facts", {})
		if event in ["mechanism", "altar", "compress", "coil"] and (not facts.get("items", []).is_empty() or not facts.get("delivery", {}).is_empty()):
			var extra := _extra_event_item(context, event, payload.position, int(facts.get("tier", 1)))
			if not extra.is_empty():
				var granted := Supply.on_event(context, context.asset_ledger.get_items_by_location(&"equipped"), {"kind": "random_reward_event", "room_id": str(fact.room_key), "ordinary_random": true, "noncombat": true, "extra_item": extra})
				if not granted.get("ok", false):
					return granted
	record(context, "event_stage_completed", payload)
	return {"ok": true}

static func consume_income(context: RunContext, _fact: Dictionary) -> Dictionary:
	return consume_new_incomes(context)

static func consume_new_incomes(context: RunContext) -> Dictionary:
	if not applies_to(context):
		return {"ok": true}
	var start := int(context.z1_event_flags.get("z2_income_cursor", 0))
	var end := context.asset_ledger.settlement_log.size()
	for index in range(start, end):
		var entry: Dictionary = context.asset_ledger.settlement_log[index]
		if str(entry.get("type", "")) != "currency_delta" or str(entry.get("currency_id", "")) != "black_coin" or int(entry.get("amount", 0)) <= 0:
			continue
		var result := opening_hook(context, {"kind": "black_income", "fact_id": "income:%d" % index, "actual": true,
			"ledger_index": index, "gross": int(entry.amount)})
		if not result.get("ok", false):
			return result
	context.z1_event_flags["z2_income_cursor"] = context.asset_ledger.settlement_log.size()
	context.asset_ledger.sync_compat_fields(context)
	return {"ok": true}

static func opening_hook(context: RunContext, fact: Dictionary) -> Dictionary:
	if not applies_to(context) or context.z1_event_flags.get("z2_opening", {}).is_empty():
		return {"ok": true, "applied": false}
	return Opening.execute(context, "hook", {"action_id": "opening:" + str(fact.fact_id), "fact": fact})

static func consume_facts(context: RunContext, observation: Dictionary) -> Dictionary:
	var facts: Dictionary = observation.get("facts", {})
	var event := str(observation.get("event_type", ""))
	var pos := room_position(str(observation.get("room_key", "")))
	var payload := {"position": pos, "fact_id": str(observation.get("fact_id", "")), "event_type": event}
	payload.merge(facts.duplicate(true), true)
	record(context, "event_action_resolved", payload)
	match event:
		"clock_in":
			if int(facts.get("black_income_gross", 0)) > 0:
				payload.merge({"contract_id": str(context.run_id) + ":work:" + str(facts.get("origin_room_id", "")),
					"new_room_count": facts.get("new_rooms", []).size(), "payout": int(facts.black_income_gross)}, true)
				record(context, "work_order_paid", payload)
		"recycle":
			payload["instance_id"] = str(facts.get("item_instance_id", ""))
			payload["payout"] = int(facts.get("safe_income", 0))
			if facts.get("operation") == "take":
				record(context, "recovery_collected", payload)
			elif facts.get("operation") == "deliver" and payload.payout > 0:
				record(context, "recovery_delivered", payload)
		"dice":
			if facts.has("round"):
				payload["won"] = bool(facts.get("win", false))
				record(context, "dice_round_settled", payload)
		"altar":
			if facts.has("tier") and facts.has("payment"):
				record(context, "altar_offered", payload)
		"savings":
			if facts.has("interest"):
				payload["withdrawn"] = int(facts.get("black_income_gross", 0))
				payload["principal"] = payload.withdrawn - int(facts.interest)
				payload["transaction_id"] = str(observation.get("fact_id", ""))
				record(context, "savings_withdrawn", payload)
		"compress":
			if facts.has("consumed_instance_ids") and facts.has("delivery"):
				var inputs: Array = []
				for id in facts.consumed_instance_ids:
					inputs.append(context.asset_ledger.item_instances.get(str(id), {}).duplicate(true))
				payload.merge({"inputs": inputs, "output": facts.delivery.duplicate(true)}, true)
				record(context, "compression_completed", payload)
		"cage":
			if facts.get("combat_requested", false):
				var forced := opening_hook(context, {"kind": "forced_cage", "event_id": "cage", "fact_id": str(observation.fact_id), "actual": true, "pos": pos})
				if not forced.get("ok", false):
					return forced
	if int(facts.get("power_gain", 0)) != 0:
		record(context, "power_changed", {"position": pos, "power": context.power})
	var deliveries: Array = facts.get("items", []).duplicate(true)
	if facts.get("delivery") is Dictionary:
		deliveries.append(facts.delivery)
	for item: Dictionary in deliveries:
		if str(item.get("location_state", "")) == "inventory":
			record(context, "item_picked_up", {"position": pos, "item": item.duplicate(true), "event_type": event})
	return {"ok": true}

static func _extra_event_item(context: RunContext, event: String, pos: Vector2i, stage: int) -> Dictionary:
	var equipped := context.asset_ledger.get_items_by_location(&"equipped")
	if not equipped.any(func(item: Dictionary) -> bool: return str(item.get("item_id", "")) == "eq_old_work_badge"):
		return {}
	var channel: String = {"mechanism": "mechanism_success", "altar": "altar", "compress": "compression", "coil": "search"}.get(event, "")
	var entries := Loot.candidates(channel, context.run_start_config.get("profile_fields", {}).get("content_eligibility", {}), str(context.run_start_config.get("map_config_id", "")), stage)
	var pool: Array = []
	var total := 0.0
	for entry: Dictionary in entries:
		var item := Loot.definition(str(entry.item_id))
		if str(item.get("item_type", "")) not in ["collectible", "equipment", "consumable"] or item.get("is_unique", false):
			continue
		var weight := float(entry.get("roll_weight", 0))
		if weight > 0.0:
			total += weight
			pool.append({"item": item, "weight": weight})
	if pool.is_empty():
		return {}
	var rng := RandomNumberGenerator.new()
	rng.seed = context.seed_value + (event + ":" + context.cell_key(pos) + ":badge").hash()
	var ticket := rng.randf() * total
	for entry: Dictionary in pool:
		ticket -= float(entry.weight)
		if ticket < 0.0:
			return entry.item.duplicate(true)
	return pool.back().item.duplicate(true)

static func after_action(context: RunContext, before: Dictionary, action_id: String) -> Dictionary:
	if not applies_to(context) or not context.run_active:
		return {"ok": true}
	var incomes := consume_new_incomes(context)
	if not incomes.get("ok", false):
		return incomes
	var previous: Dictionary = before.get("data", {})
	if int(previous.get("power", context.power)) != context.power:
		record(context, "power_changed", {"position": context.get_current_pos(), "power": context.power})
	var opening: Dictionary = context.z1_event_flags.get("z2_opening", {})
	if opening.is_empty():
		return {"ok": true}
	var selected := str(opening.get("selected", ""))
	if selected == "status_clear" and int(opening.get("effect_state", {}).get("uses", 0)) == 0:
		var temporary_types := {}
		for status: Dictionary in context.temporary_statuses:
			if str(status.get("type", "")) in ["temporary_buff", "temporary_debuff"] and str(status.get("phase", "ended")) != "ended" and str(status.get("temporary_type", "")) != "":
				temporary_types[str(status.temporary_type)] = true
		if temporary_types.size() >= 3:
			var changed := opening_hook(context, {"kind": "statuses_changed", "fact_id": action_id + ":statuses", "actual": true})
			if not changed.get("ok", false):
				return changed
	if selected == "forced_cash" and before.get("components", {}).get("asset_ledger", {}).get("item_instances", {}) != context.asset_ledger.item_instances:
		var changed := opening_hook(context, {"kind": "inventory_changed", "fact_id": action_id + ":inventory", "actual": true})
		if not changed.get("ok", false):
			return changed
		return consume_new_incomes(context)
	return {"ok": true}

static func room_position(key: String) -> Vector2i:
	return Vector2i(int(key.get_slice(",", 0)), int(key.get_slice(",", 1)))

static func record(context: RunContext, event: String, payload: Dictionary) -> void:
	context.record_event(StringName(event), str(context.active_command.get("command_id", "")), &"player", "z2_run_hooks", payload)
