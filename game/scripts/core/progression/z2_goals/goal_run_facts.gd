extends RefCounted

# Summarize the committed T01 journal and T06/T14 terminal_facts once per run.
# Positions are Vector2i. Later producers supply the typed event payloads below.

const SAFE_ROOM_TYPES := ["Normal", "Event", "Monster", "Chest", "Exit"]
const NO_CELL := Vector2i(-1, -1)


static func collect(facts: Dictionary, map: Dictionary) -> Dictionary:
	var start := dictionary(facts.get("run_start_config"))
	var size := int(map.width)
	var run := {
		"size": size, "map_id": str(map.id), "success": str(facts.ending) == "success",
		"start": start, "worn": entries(start.get("selected_equipment_items")),
		"worn_known": start.get("selected_equipment_items") is Array or start.get("selected_equipment_ids") is Array,
		"start_ids": {}, "equipment_ids": {}, "opening_id": "",
		"visited": {}, "room_counts": {"Event": 0, "Monster": 0, "Chest": 0}, "spawn": NO_CELL,
		"first_move": {}, "last_entry": {}, "explorations": [], "mine_hits": 0,
		"correct_flags": {}, "current_flags": {}, "flags_before_safe_room": -1,
		"searches": {}, "clears": {}, "cage_won": false, "effective_supply": false, "consumable_used": false,
		"pressure": clampi(int(facts.get("starting_pressure", 0)), 0, 100), "full_pressure": false,
		"rooms_after_full_pressure": 0, "actual_pressure_relief": 0, "shield_absorbed": 0,
		"peak_power": maxi(int(facts.get("power", 0)), int(facts.get("starting_power", 0))),
		"exit_rooms": {}, "extraction_position": NO_CELL, "visited_hidden_exit": false, "all_exits_visited": false,
		"work_paid": false, "recovery_sources": {}, "recovery_transfer": false,
		"compression_outputs": {}, "compression_picked_up": false, "altar_tiers": {},
		"dice_rounds": {}, "savings_ids": {}, "best_interest": 0,
		"arrived_collectibles": [], "carried_collectibles": [], "collectible_value": 0, "registered": {}, "consumable_evidence_complete": false,
		"consignment_delivered": false, "best_mine_streak": 0,
	}
	_read_start(run)
	run.full_pressure = int(run.pressure) == 100
	for event: Dictionary in facts.run_events:
		if str(event.get("source", "")) == "debug_command":
			continue
		_read_event(run, str(event.get("event_type", "")), dictionary(event.get("payload")), event)
	_read_terminal(run, facts, map)
	return run


static func _read_start(run: Dictionary) -> void:
	var start: Dictionary = run.start
	for field in ["selected_equipment_ids", "selected_consumable_ids", "carried_equipment_ids", "starting_instance_ids"]:
		for instance_id in entries(start.get(field)):
			var id := str(instance_id)
			if not id.is_empty():
				run.start_ids[id] = true
				if field in ["selected_equipment_ids", "carried_equipment_ids"]:
					run.equipment_ids[id] = true
	for field in ["selected_equipment_items", "selected_consumable_items", "carried_equipment_items", "starting_items"]:
		for raw in entries(start.get(field)):
			var item := dictionary(raw)
			var id := str(item.get("instance_id", ""))
			if not id.is_empty():
				run.start_ids[id] = true
				if str(item.get("item_type", "")) == "equipment":
					run.equipment_ids[id] = true
	var effect := dictionary(start.get("opening_effect"))
	if int(effect.get("batch", 0)) == 1:
		run.opening_id = str(effect.get("id", ""))


static func _read_event(run: Dictionary, kind: String, p: Dictionary, event: Dictionary) -> void:
	var pos: Variant = p.get("position", NO_CELL)
	var inside := _inside(pos, int(run.size))
	match kind:
		"run_started":
			if inside and run.spawn == NO_CELL:
				run.spawn = pos
				run.visited[pos] = true
				run.peak_power = maxi(run.peak_power, int(p.get("power", 0)))
				if p.has("pressure"):
					run.pressure = clampi(int(p.pressure), 0, 100)
					run.full_pressure = int(run.pressure) == 100
		"room_entered":
			if inside and pos != run.spawn:
				_entered_room(run, pos, str(p.get("room_type", "")))
		"room_searched":
			if inside and pos != run.spawn and p.get("is_chest") == false:
				run.searches[pos] = true
		"combat_resolved":
			if inside and p.get("runtime") == true and p.get("automatic") != true and p.get("won", true) == true:
				if p.get("cage") == true:
					run.cage_won = true
				else:
					run.clears[pos] = true
		"manual_flag_changed":
			if inside and str(event.get("actor_id", "")) == "player":
				_flag_changed(run, pos, p)
		"mine_triggered":
			if inside and run.last_entry.get("position") == pos and not run.last_entry.get("mine_hit", false):
				run.last_entry.mine_hit = true
				run.mine_hits += 1
		"extraction_success":
			if inside and not str(p.get("exit_id", "")).is_empty():
				run.extraction_position = pos
		"power_changed":
			run.peak_power = maxi(run.peak_power, int(p.get("power", 0)))
		"consumable_used":
			if not str(p.get("instance_id", "")).is_empty():
				run.consumable_used = true
				run.effective_supply = run.effective_supply or p.get("effective") == true
		"vitals_pressure":
			_pressure_changed(run, p, str(event.get("source", "")))
		"vitals_damage":
			run.shield_absorbed += maxi(0, int(p.get("absorbed", 0)))
		_:
			_read_event_service_fact(run, kind, p, pos if inside else NO_CELL)


static func _entered_room(run: Dictionary, pos: Vector2i, room_type: String) -> void:
	var entry := {"position": pos, "mine_hit": false}
	run.last_entry = entry
	if run.first_move.is_empty():
		run.first_move = entry
	if run.room_counts.has(room_type):
		run.room_counts[room_type] += 1
	if room_type == "Exit":
		run.exit_rooms[pos] = true
	if run.visited.has(pos):
		return
	run.visited[pos] = true
	run.explorations.append(entry)
	if run.full_pressure:
		run.rooms_after_full_pressure += 1
	if room_type in SAFE_ROOM_TYPES:
		run.flags_before_safe_room = maxi(run.flags_before_safe_room, run.correct_flags.size())


static func _flag_changed(run: Dictionary, pos: Vector2i, p: Dictionary) -> void:
	if p.get("enabled") == false:
		run.current_flags.erase(pos)
	elif p.get("enabled") == true and p.has("is_mine"):
		run.current_flags[pos] = p.is_mine == true
		if p.is_mine == true and p.get("triggered") == false:
			run.correct_flags[pos] = true


static func _pressure_changed(run: Dictionary, payload: Dictionary, source: String) -> void:
	var actual := int(payload.get("actual_pressure_delta", 0))
	var origin := str(payload.get("origin", ""))
	run.pressure = clampi(run.pressure + actual, 0, 100)
	run.full_pressure = run.full_pressure or int(run.pressure) == 100
	if actual < 0 and (origin in ["consumable", "event"] or source.begins_with("consumable_")):
		run.actual_pressure_relief -= actual


static func _read_event_service_fact(run: Dictionary, kind: String, p: Dictionary, pos: Vector2i) -> void:
	match kind:
		"work_order_paid":
			if not str(p.get("contract_id", "")).is_empty() and int(p.get("new_room_count", 0)) >= 3 and int(p.get("payout", 0)) > 0:
				run.work_paid = true
		"recovery_collected":
			var id := str(p.get("instance_id", ""))
			if pos != NO_CELL and not id.is_empty() and not run.recovery_sources.has(id):
				run.recovery_sources[id] = pos
		"recovery_delivered":
			var origin: Vector2i = run.recovery_sources.get(str(p.get("instance_id", "")), NO_CELL)
			if pos != NO_CELL and origin != NO_CELL and pos != origin and int(p.get("payout", 0)) > 0:
				run.recovery_transfer = true
		"compression_completed":
			_record_compression(run.compression_outputs, p)
		"item_picked_up":
			var id := str(dictionary(p.get("item")).get("instance_id", ""))
			if run.compression_outputs.has(id):
				run.compression_picked_up = true
		"altar_offered":
			var tier := int(p.get("tier", 0))
			if pos != NO_CELL and tier >= 1 and tier <= 5 and tier == int(run.altar_tiers.get(pos, 0)) + 1:
				run.altar_tiers[pos] = tier
		"dice_round_settled":
			var round_number := int(p.get("round", 0))
			if pos != NO_CELL and round_number in [1, 2, 3] and p.get("won") is bool:
				var rounds: Dictionary = run.dice_rounds.get_or_add(pos, {})
				if not rounds.has(round_number):
					rounds[round_number] = p.won
		"savings_withdrawn":
			var id := str(p.get("transaction_id", ""))
			var principal := int(p.get("principal", 0))
			if not id.is_empty() and principal > 0 and not run.savings_ids.has(id):
				run.savings_ids[id] = true
				run.best_interest = maxi(run.best_interest, int(p.get("withdrawn", 0)) - principal)


static func _record_compression(outputs: Dictionary, event: Dictionary) -> void:
	var inputs := entries(event.get("inputs"))
	var output := dictionary(event.get("output"))
	if inputs.size() != 2 or not collectible(output) or item_tier(output) != 2:
		return
	var first := dictionary(inputs[0])
	var second := dictionary(inputs[1])
	var first_id := str(first.get("instance_id", ""))
	var second_id := str(second.get("instance_id", ""))
	var output_id := str(output.get("instance_id", ""))
	if first_id.is_empty() or second_id.is_empty() or first_id == second_id or output_id.is_empty() or output_id in [first_id, second_id]:
		return
	if collectible(first) and collectible(second) and item_tier(first) == 1 and item_tier(second) == 1:
		outputs[output_id] = true


static func _read_terminal(run: Dictionary, facts: Dictionary, map: Dictionary) -> void:
	var stats := dictionary(facts.get("run_stats"))
	run.mine_hits = maxi(run.mine_hits, int(stats.get("mine_hits", 0)))
	run.consumable_used = run.consumable_used or int(stats.get("consumables_used", 0)) > 0
	run.consumable_evidence_complete = facts.get("consumable_evidence_complete", stats.has("consumables_used")) == true
	_read_exits(run, facts, map)
	var before := dictionary(facts.get("items_before_settlement"))
	var seen := {}
	for raw in entries(facts.get("warehouse_items")):
		var item := dictionary(raw)
		var id := str(item.get("instance_id", ""))
		if id.is_empty() or seen.has(id) or not collectible(item):
			continue
		seen[id] = true
		run.arrived_collectibles.append(item)
		if not run.start_ids.has(id):
			run.collectible_value += maxi(0, int(item.get("base_value", 0)))
		var location := str(dictionary(before.get(id)).get("location_state", ""))
		if location == "inventory":
			run.carried_collectibles.append(item)
		elif location == "consigned":
			var weight := int(item.get("weight", 0))
			run.consignment_delivered = run.consignment_delivered or (item_tier(item) >= 4 and weight > 0 and weight <= 20)
	for raw in entries(facts.get("registered_collectibles", run.arrived_collectibles)):
		var item := dictionary(raw)
		var id := str(item.get("item_id", ""))
		var tier := item_tier(item)
		if not id.is_empty() and collectible(item) and tier in [1, 2, 3, 4, 5, 6]:
			run.registered[id] = tier
	var streak := 0
	for entry: Dictionary in run.explorations:
		streak = streak + 1 if entry.mine_hit else 0
		run.best_mine_streak = maxi(run.best_mine_streak, streak)


static func _read_exits(run: Dictionary, facts: Dictionary, map: Dictionary) -> void:
	var exits := {}
	for position in entries(facts.get("exits")):
		if _inside(position, int(run.size)):
			exits[position] = true
	var hidden := entries(facts.get("hidden_exits_at_start"))
	if not facts.has("hidden_exits_at_start") and int(map.get("visible_exit_count", -1)) == 0:
		hidden = exits.keys()
	for position in hidden:
		if exits.has(position) and run.exit_rooms.has(position):
			run.visited_hidden_exit = true
	var expected := int(map.get("visible_exit_count", 0)) + int(map.get("hidden_exit_count", 0))
	if expected <= 0 or exits.size() != expected or not exits.has(run.extraction_position):
		return
	for position in exits:
		if not run.exit_rooms.has(position):
			return
	run.all_exits_visited = true


static func _inside(value: Variant, size: int) -> bool:
	return value is Vector2i and value.x >= 0 and value.y >= 0 and value.x < size and value.y < size


static func dictionary(value: Variant) -> Dictionary:
	return value if value is Dictionary else {}


static func entries(value: Variant) -> Array:
	return value if value is Array else []


static func item_tier(item: Dictionary) -> int:
	return int(item.get("tier", item.get("collectible_level", 0)))


static func collectible(item: Dictionary) -> bool:
	return str(item.get("item_type", "")) == "collectible" and not item.get("is_unique", false) and item_tier(item) in [1, 2, 3, 4, 5, 6]
