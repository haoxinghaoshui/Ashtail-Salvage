extends RefCounted
class_name Z1SupplyRuleService

static func consumption_block(context: RunContext, item: Dictionary) -> String:
	match str(item.get("effect_kind", "")):
		"heal_below_half":
			if context.hp * 2 >= context.max_hp:
				return "requires_below_half_hp"
		"scan_two_away":
			if range_powder_target(context) == Vector2i(-999, -999):
				return "no_unknown_room_two_away"
	return ""


static func range_powder_target(context: RunContext) -> Vector2i:
	if context.truth_map == null or context.intel_map == null:
		return Vector2i(-999, -999)
	for delta in [Vector2i.UP, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT]:
		var target: Vector2i = context.get_current_pos() + delta * 2
		if not context.is_inside(target):
			continue
		var known := context.intel_map.get_cell_info(target)
		if not bool(known.get("revealed", false)) and not bool(known.get("scanned", false)):
			return target
	return Vector2i(-999, -999)


static func apply_range_powder(context: RunContext) -> Dictionary:
	var target := range_powder_target(context)
	if target == Vector2i(-999, -999):
		return {"ok": false, "reason": "no_unknown_room_two_away"}
	context.intel_map.reveal_cell(target, context.truth_map)
	var cell := context.intel_map.get_cell_info(target)
	var report := {"target": target, "room_type": cell["room_type"], "adjacent_mines": cell["adjacent_mines"]}
	context.record_event(&"consumable_range_scan", str(context.active_command.get("command_id", "")), &"player", "consumable", report)
	report["ok"] = true
	report["effect_results"] = []
	return report


static func exchange_material(context: RunContext, instance_id: String, purpose: StringName) -> Dictionary:
	var item_ids: Array = []
	var amount := 0
	match purpose:
		&"inspection":
			item_ids = ["sp_inspection_calibration_plate", "mon_old_gear_set"]
			amount = 5
		&"transit":
			item_ids = ["sp_transit_lead_seal"]
			amount = 10
		_:
			return {"ok": false, "reason": "unknown_material_exchange"}
	var validation := _validate_material(context, instance_id, item_ids)
	if not bool(validation.get("ok", false)):
		return validation
	var result := _deliver(context, instance_id, str(validation["item"]["item_id"]), str(purpose))
	if not bool(result.get("ok", false)):
		return result
	context.asset_ledger.add_currency(RunAssetLedger.CURRENCY_SAFE_YIELD, amount, str(purpose))
	context.asset_ledger.sync_compat_fields(context)
	if context.transaction_log != null:
		context.transaction_log.record_transaction(str(context.active_command.get("command_id", "")), "z1_exchange:" + instance_id, &"player", str(purpose), &"material_safe_yield", {}, {}, {RunAssetLedger.CURRENCY_SAFE_YIELD: amount})
	result["safe_yield_delta"] = amount
	return result


static func use_reset_spring(context: RunContext, instance_id: String, base_threshold: int) -> Dictionary:
	var validation := _validate_material(context, instance_id, ["sp_reset_spring"])
	if not bool(validation.get("ok", false)):
		return validation
	var threshold := maxi(0, base_threshold - 3)
	if base_threshold <= 0 or context.power < threshold:
		return {"ok": false, "reason": "insufficient_power", "threshold": threshold}
	var result := _deliver(context, instance_id, "sp_reset_spring", "mechanism")
	result["threshold"] = threshold
	result["threshold_reduction"] = base_threshold - threshold
	return result


static func use_valve_core(context: RunContext, instance_id: String, base_hp_cost: int) -> Dictionary:
	var validation := _validate_material(context, instance_id, ["sp_depressurized_valve_core"])
	if not bool(validation.get("ok", false)):
		return validation
	var hp_cost := maxi(0, base_hp_cost - 5)
	if base_hp_cost <= 0 or context.hp <= hp_cost:
		return {"ok": false, "reason": "insufficient_hp", "hp_cost": hp_cost}
	var result := _deliver(context, instance_id, "sp_depressurized_valve_core", "altar")
	result["hp_cost"] = hp_cost
	result["hp_cost_reduction"] = base_hp_cost - hp_cost
	return result


static func pressure_reduction(context: RunContext, reason: String) -> int:
	if not (reason.begins_with("combat") or reason in ["event_trap", "event_mechanism", "mechanism"]):
		return 0
	var result := 0
	for item in context.asset_ledger.get_items_by_location(RunAssetLedger.LOCATION_EQUIPPED):
		if str(item.get("effect_kind", "")) == "combat_mechanism_pressure_reduce":
			result += maxi(0, int(item.get("effect_amount", 0)))
	return result


static func _validate_material(context: RunContext, instance_id: String, allowed_ids: Array) -> Dictionary:
	if context == null or context.asset_ledger == null or not context.run_active or context.failed or context.extracted or context.abandoned:
		return {"ok": false, "reason": "no_active_run"}
	var item: Dictionary = context.asset_ledger.item_instances.get(instance_id, {})
	if item.is_empty() or StringName(item.get("location_state", &"")) != RunAssetLedger.LOCATION_INVENTORY:
		return {"ok": false, "reason": "item_not_in_inventory"}
	if not allowed_ids.has(str(item.get("item_id", ""))):
		return {"ok": false, "reason": "wrong_delivery_item"}
	return {"ok": true, "item": item.duplicate(true)}


static func _deliver(context: RunContext, instance_id: String, item_id: String, purpose: String) -> Dictionary:
	var result := context.asset_ledger.deliver_inventory_item(instance_id, item_id, purpose)
	if not bool(result.get("ok", false)):
		return result
	context.asset_ledger.sync_compat_fields(context)
	context.record_event(&"material_delivered", str(context.active_command.get("command_id", "")), &"player", purpose, {"instance_id": instance_id, "item_id": item_id})
	if context.transaction_log != null:
		result["transaction"] = context.transaction_log.record_transaction(str(context.active_command.get("command_id", "")), "z1_delivery:" + instance_id, &"player", purpose, &"deliver_inventory_item", {}, {}, {}, [{"instance_id": instance_id, "item_id": item_id, "from": &"inventory", "to": &"consumed"}])
	return result
