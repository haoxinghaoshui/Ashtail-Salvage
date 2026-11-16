extends RefCounted

const Facts := preload("res://scripts/core/progression/z2_goals/goal_run_facts.gd")


static func advance(id: String, progress: int, evidence: Dictionary, run: Dictionary, facts: Dictionary) -> int:
	var size := int(run.size)
	var success := bool(run.success)
	match id:
		"M01":
			return 1
		"M02":
			return int(run.flags_before_safe_room >= 3)
		"M03":
			var counts: Dictionary = evidence.get_or_add("entries", {})
			for kind in ["Event", "Monster", "Chest"]:
				counts[kind] = int(counts.get(kind, 0)) + int(run.room_counts[kind])
			return int(counts.Event >= 3 and counts.Monster >= 3 and counts.Chest >= 3)
		"M05":
			return int(success and run.equipment_ids.size() >= 3)
		"M06":
			return int((size >= 10 or run.map_id == "classic_7x7_normal") and run.visited_hidden_exit)
		"M07":
			return progress + int(success)
		"M08":
			return progress + int(run.collectible_value)
		"M09":
			return int(success and size >= 10 and run.searches.size() >= 10)
		"M10":
			return int(success and size >= 10 and run.clears.size() >= 3)
		"M11":
			return int(success and size == 13)
		"M12":
			return int(success and size >= 10 and not run.opening_id.is_empty())
		"M13":
			return int(success and _count_collectibles(run.carried_collectibles, 4) >= 3)
		"M14":
			return int(success and size == 13 and run.all_exits_visited)
		"M15":
			return int(success and _count_collectibles(run.carried_collectibles, 6) >= 2)
		"S01":
			return int(run.effective_supply)
		"S02":
			return progress + int(run.actual_pressure_relief)
		"S03":
			for item_id in evidence.get("purchased_instance_ids", {}):
				if run.start_ids.has(item_id):
					return 1
			return progress
		"S04":
			return int(not run.opening_id.is_empty())
		"S05":
			return int(_changed_equipment(evidence, run.worn))
		"S06":
			return int(run.work_paid)
		"S08":
			return int(run.recovery_transfer)
		"S09":
			return int(run.compression_picked_up)
		"S10":
			return int(run.consignment_delivered)
		"A01":
			return int(size >= 10 and run.mine_hits == 0)
		"A02":
			return maxi(progress, run.peak_power)
		"A03":
			return int(size >= 10 and run.visited.size() == size * size)
		"A04":
			return int(success and _both_capacities_full(Facts.dictionary(facts.get("capacity_before_settlement"))))
		"A05":
			var converted := maxi(0, int(facts.get("black_coin_gold", 0))) if success else 0
			return maxi(progress, converted + int(run.collectible_value))
		"A06":
			return int(success and run.rooms_after_full_pressure >= 10)
		"A07":
			return int(success and run.shield_absorbed >= 100)
		"A08":
			return progress + int(run.room_counts.Event)
		"A09":
			return progress + int(run.room_counts.Monster)
		"A10":
			return progress + int(run.room_counts.Chest)
		"A11":
			return int(success and int(facts.get("pressure", -1)) == 0)
		"A12":
			var max_hp := int(facts.get("max_hp", 0))
			return int(success and run.map_id == "classic_13x13_hell" and max_hp > 0 and int(facts.get("hp", -1)) == max_hp)
		"A13":
			return int(run.first_move.get("mine_hit", false))
		"A14":
			return int(run.best_mine_streak >= 5)
		"A15":
			return int(run.altar_tiers.values().has(5))
		"A16":
			for rounds: Dictionary in run.dice_rounds.values():
				if rounds.get(1) == true and rounds.get(2) == true and rounds.get(3) == true:
					return 1
			return progress
		"A17":
			return maxi(progress, run.best_interest)
		"A18":
			var collection: Dictionary = evidence.get_or_add("collection", {})
			collection.merge(run.registered, false)
			return int(collection.size() >= 20 and _all_tiers(collection.values()))
		"A19":
			return int(success and size >= 10 and run.worn_known and run.worn.is_empty()
				and Facts.entries(run.start.get("selected_equipment_ids")).is_empty() and _half_map(run))
		"A20":
			return int(success and size == 13 and run.consumable_evidence_complete and not run.consumable_used and _half_map(run))
		"A21":
			return int(success and run.cage_won)
		"A22":
			var tiers: Array = []
			for item: Dictionary in run.arrived_collectibles:
				tiers.append(Facts.item_tier(item))
			return int(success and _all_tiers(tiers))
		"A23":
			var hp := int(facts.get("hp", 0))
			var max_hp := int(facts.get("max_hp", 0))
			return int(success and size >= 10 and _half_map(run) and hp > 0 and hp * 10 <= max_hp)
		"A24":
			return int(success and _distinct_openings(evidence, run))
		"A25":
			return int(success and size >= 10 and run.correct_flags.size() >= 10 and not run.current_flags.values().has(false))
	return progress


static func _changed_equipment(evidence: Dictionary, worn: Array) -> bool:
	var previous: Dictionary = evidence.get_or_add("equipment_by_slot", {})
	var current := {}
	for raw in worn:
		var item := Facts.dictionary(raw)
		var slot := str(item.get("equipment_slot", ""))
		var item_id := str(item.get("item_id", ""))
		if slot.is_empty() or item_id.is_empty() or str(item.get("item_type", "")) != "equipment":
			continue
		current[slot] = item_id
	for slot in current:
		if previous.has(slot) and previous[slot] != current[slot]:
			return true
	previous.merge(current, false)
	return false


static func _distinct_openings(evidence: Dictionary, run: Dictionary) -> bool:
	var effect_id := str(run.opening_id)
	if effect_id.is_empty():
		return false
	var by_size: Dictionary = evidence.get_or_add("openings_by_size", {})
	var used: Dictionary = by_size.get_or_add(str(run.size), {})
	used[effect_id] = true
	var sevens := Facts.dictionary(by_size.get("7"))
	var tens := Facts.dictionary(by_size.get("10"))
	var thirteens := Facts.dictionary(by_size.get("13"))
	for easy in sevens:
		for medium in tens:
			if medium == easy:
				continue
			for large in thirteens:
				if large != easy and large != medium:
					return true
	return false


static func _both_capacities_full(capacity: Dictionary) -> bool:
	var bag := int(capacity.get("capacity", 0))
	var supply := int(capacity.get("equipment_capacity", 0))
	return bag > 0 and supply > 0 and int(capacity.get("used", -1)) == bag and int(capacity.get("equipment_used", -1)) == supply


static func _half_map(run: Dictionary) -> bool:
	return run.visited.size() * 2 >= int(run.size) * int(run.size)


static func _count_collectibles(items: Array, minimum_tier: int) -> int:
	var count := 0
	for item: Dictionary in items:
		count += int(Facts.item_tier(item) >= minimum_tier)
	return count


static func _all_tiers(tiers: Array) -> bool:
	for tier in range(1, 7):
		if not tiers.has(tier):
			return false
	return true
