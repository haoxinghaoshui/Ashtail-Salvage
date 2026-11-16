extends RefCounted
class_name RunInventory

# Legacy validation markers kept while G8 delegates rewards to RunRuleService:
# mini(4
# mini(11
# context.carried_items.append_array


static func setup_stats(context: RunContext) -> void:
	if context == null:
		return
	if context.asset_ledger != null:
		context.asset_ledger.run_id = String(context.run_id)
	context.run_stats = {
		"moves": 0,
		"searched_rooms": 0,
		"chest_rooms": 0,
		"mine_hits": 0,
		"mine_immunity_used": 0,
		"monsters_defeated": 0,
		"monster_power_bonus": 0,
		"combat_damage": 0,
		"events_completed": 0,
		"events_trader": 0,
		"events_dice": 0,
		"events_altar": 0,
		"events_trap": 0,
		"turns": 0,
		"map_open_count": 0,
		"flags_placed": 0,
	}


static func apply_equipment_change(context: RunContext, result: Dictionary) -> void:
	if context == null or not bool(result.get("ok", false)):
		return
	var deltas := {}
	for change in result.get("equipment_changes", []):
		var item: Dictionary = change.get("item", {})
		var direction := int(StringName(change.get("to", &"")) == RunAssetLedger.LOCATION_EQUIPPED) - int(StringName(change.get("from", &"")) == RunAssetLedger.LOCATION_EQUIPPED)
		var kind := String(item.get("effect_kind", ""))
		deltas[kind] = int(deltas.get(kind, 0)) + direction * int(item.get("effect_amount", 0))
	# Apply a same-slot exchange as one aggregate change, then clamp HP once.
	# Retain the contribution below the floor so re-equipping cannot refund a
	# permanent max-HP payment made while the equipment was worn.
	var raw_max_hp := context.max_hp - context.max_hp_equipment_floor_debt + int(deltas.get("max_hp", 0))
	context.max_hp = maxi(1, raw_max_hp)
	context.max_hp_equipment_floor_debt = maxi(0, 1 - raw_max_hp)
	context.hp = mini(context.hp, context.max_hp)
	context.power += int(deltas.get("power", 0))
	context.mine_dmg_reduce += int(deltas.get("mine_damage_reduce", 0))
	context.protocol_pressure_reduce += int(deltas.get("protocol_pressure_reduce", 0))
	context.search_reward_bonus += int(deltas.get("search_reward", 0))
	context.scan_hint_bonus += int(deltas.get("scan_hint", 0))


static func claim_departure_shield(ledger: RunAssetLedger, current_run_id: String) -> int:
	if ledger == null or current_run_id.is_empty():
		return 0
	var granted := 0
	for item in ledger.get_items_by_location(RunAssetLedger.LOCATION_EQUIPPED):
		if not bool(item.get("carry_in_equipment", false)) or String(item.get("effect_kind", "")) != "departure_shield":
			continue
		var counters: Dictionary = item.get("counters", {}).duplicate(true)
		if String(counters.get("departure_shield_run_id", "")) == current_run_id:
			continue
		granted += maxi(0, int(item.get("effect_amount", 0)))
		counters["departure_shield_run_id"] = current_run_id
		ledger.item_instances[String(item["instance_id"])]["counters"] = counters
	return granted


static func record_move(context: RunContext) -> void:
	if context == null:
		return
	context.turn += 1
	context.run_stats["moves"] = int(context.run_stats.get("moves", 0)) + 1
	context.run_stats["turns"] = context.turn


static func add_search_reward(context: RunContext, pos: Vector2i, adjacent_mines: int, is_chest: bool) -> Dictionary:
	if context == null:
		return {"ok": false}
	var reward := RunRuleService.apply_search_reward(context, pos, adjacent_mines, is_chest)
	if not reward.get("ok", false):
		return reward
	if is_chest:
		context.run_stats["chest_rooms"] = int(context.run_stats.get("chest_rooms", 0)) + 1
	context.run_stats["searched_rooms"] = int(context.run_stats.get("searched_rooms", 0)) + 1
	return reward


static func get_reward_summary(context: RunContext) -> Dictionary:
	if context == null:
		return {}
	return {
		"pending_gold": context.pending_gold,
		"safe_gold": context.safe_gold,
		"parts": context.parts,
		"carried_items": context.carried_items.size(),
		"stats": context.run_stats.duplicate(true),
	}


static func get_carried_item_value(context: RunContext) -> int:
	if context == null:
		return 0
	if context.asset_ledger != null:
		var ledger_total := 0
		for item in context.asset_ledger.get_inventory_and_equipped_items(false):
			ledger_total += int(item.get("base_value", item.get("value", 0)))
		return ledger_total
	var total := 0
	for item in context.carried_items:
		total += int(item.get("value", 0))
	return total


static func build_failure_salvage(context: RunContext) -> Dictionary:
	if context == null:
		return {}
	if context.asset_ledger != null:
		return context.asset_ledger.build_failure_preview()
	var salvaged_item: Dictionary = {}
	var best_value := -1
	for item in context.carried_items:
		var value := int(item.get("value", 0))
		if value > best_value:
			best_value = value
			salvaged_item = item.duplicate(true)
	return {
		"safe_gold": context.safe_gold,
		"pending_gold_lost": context.pending_gold,
		"lost_parts": context.parts,
		"lost_item_count": context.carried_items.size(),
		"lost_item_value": get_carried_item_value(context),
		"salvaged_item": salvaged_item,
		"salvaged_item_count": 0 if salvaged_item.is_empty() else 1,
	}
