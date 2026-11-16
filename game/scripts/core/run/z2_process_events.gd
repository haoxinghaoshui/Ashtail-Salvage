extends RefCounted
class_name Z2ProcessEvents

const Items = preload("res://scripts/core/content/z2_item_catalog.gd")
const Eligibility = preload("res://scripts/core/content/z2_content_eligibility.gd")
const Effects = preload("res://scripts/core/run/run_effect_applier.gd")
const KEY := "z2_process"
const EVENTS := ["mechanism", "recycle", "coil", "clock_in", "rps", "cage", "dice", "altar"]
const LEGACY_IDS := {"z1_event_e06": "mechanism", "z1_event_e18": "coil", "z1_event_e20": "clock_in", "z1_event_e22": "rps", "z1_event_e24": "cage"}
const HANDS := ["rock", "paper", "scissors"]
const DIFFICULTY := {"easy": 0.8, "normal": 1.0, "hard": 1.3, "hell": 1.6}
const ALTAR_HP := [10, 15, 25, 35, 50]
const ALTAR_BLACK := [2, 5, 8, 10, 15]

# All mutations belong inside the caller's existing atomic operation. Rules and
# asynchronous receipts are trusted core inputs, never UI/player payload fields.
# No growth consumer or persistence pipeline is implemented here.
static func supports(event_id: String) -> bool:
	return EVENTS.has(_canonical(event_id))


static func public_state(context: RunContext, pos: Vector2i, event_id: String) -> Dictionary:
	var event := _canonical(event_id)
	var reason := _validate(context, context.get_current_pos() if context != null else pos, event, true)
	if not reason.is_empty():
		return _fail(reason)
	var state := _room(context, pos, event)
	var result := {"ok": true, "event_type": event, "room_id": context.cell_key(pos),
		"revision": int(state.get("revision", 0)), "prepared": bool(state.get("prepared", false)),
		"completed": bool(state.get("completed", false)), "progress_completed": bool(state.get("stage_awarded", false))}
	for field in ["variant", "threshold", "base_threshold", "rewards", "wins", "losses", "rounds", "last_result", "tier", "hp_cost", "black_reward", "assisted", "combat_request", "offer_count", "phase"]:
		if state.has(field):
			var value: Variant = state[field]
			result[field] = value.duplicate(true) if value is Array or value is Dictionary else value
	var global := _global(context)
	if event == "coil":
		result["pending"] = global.get("coil_pending", {}).duplicate(true)
	if event == "clock_in":
		result["contract"] = global.get("work", {}).duplicate(true)
	if event == "altar":
		result["global_tier"] = int(global.get("altar_tier", 0))
	return result


static func choose(context: RunContext, pos: Vector2i, event_id: String, option_id: String, payload: Dictionary = {}, rules: Dictionary = {}) -> Dictionary:
	var event := _canonical(event_id)
	var reason := _validate(context, pos, event)
	if not reason.is_empty():
		return _fail(reason)
	if event == "cage":
		return _fail("combat_hook_required")
	if option_id == "leave":
		return _noop()
	var state := _room(context, pos, event)
	var dependencies := rules.duplicate(true)
	if event_id == "z1_event_e06":
		dependencies["mechanism_variant"] = "electric"
	if option_id == "prepare":
		return _prepare(context, pos, event, state, dependencies)
	if not bool(state.get("prepared", false)):
		return _fail("not_prepared")
	if not payload.get("revision") is int or int(payload.revision) != int(state.get("revision", 0)):
		return _fail("stale_revision")
	if bool(state.get("completed", false)):
		return _fail("completed")
	var result: Dictionary
	match event:
		"mechanism": result = _mechanism(context, pos, state, option_id, payload, dependencies)
		"recycle": result = _recycle(context, pos, state, option_id, payload, dependencies)
		"coil": result = _coil(context, pos, state, option_id, dependencies)
		"clock_in": result = _work(context, pos, state, option_id)
		"rps": result = _rps(context, pos, state, option_id)
		"dice": result = _dice(context, pos, state, option_id)
		"altar": result = _altar(context, pos, state, option_id, payload, dependencies)
		_: return _fail("unsupported_event")
	if not bool(result.get("ok", false)):
		return result
	return _commit(context, pos, event, state, result)


static func on_room_entered(context: RunContext, pos: Vector2i, event_id: String, rules: Dictionary = {}) -> Dictionary:
	var reason := _validate(context, pos, "clock_in")
	if not reason.is_empty():
		return _fail(reason)
	var room_id := context.cell_key(pos)
	if not context.visited_cells.has(room_id):
		return _fail("room_not_visited")
	var global := _global(context)
	var work: Dictionary = global.get("work", {})
	var changed := false
	if not work.is_empty() and not bool(work.get("claimed", false)) and not work.known_rooms.has(room_id) and not work.new_rooms.has(room_id):
		work.new_rooms[room_id] = true
		global["work"] = work
		context.z1_event_flags[KEY] = global
		changed = true
	if _canonical(event_id) == "cage":
		var state := _room(context, pos, "cage")
		if bool(state.get("completed", false)):
			return _noop()
		if state.has("combat_request"):
			var existing := _noop()
			existing["combat_request"] = state.combat_request.duplicate(true)
			return existing
		var raw: Variant = rules.get("enemy_pool", [])
		if not raw is Array or raw.is_empty():
			return _fail("missing_enemy_pool")
		for enemy: Variant in raw:
			if not enemy is Dictionary or str(enemy.get("enemy_id", "")).is_empty() or not enemy.get("original_power") is int or int(enemy.original_power) <= 0:
				return _fail("invalid_enemy_pool")
		var rng := _rng(context, pos, "cage", 0)
		var selected: Dictionary = raw[rng.randi_range(0, raw.size() - 1)].duplicate(true)
		state["combat_request"] = {"encounter_id": _instance_id(context, pos, "cage") + ":combat",
			"room_id": room_id, "enemy": selected, "original_power": int(selected.original_power),
			"allow_retreat": false, "ordinary_clear_rewards": false, "sequence": ["entry", "seal", "spawn", "combat"]}
		state["prepared"] = true
		state["phase"] = "combat_pending"
		var result := _commit(context, pos, "cage", state, {"ok": true, "facts": {"combat_requested": true}})
		result["combat_request"] = state.combat_request.duplicate(true)
		return result
	var result := _noop()
	result["durability_required"] = changed
	return result


static func on_normal_search_completed(context: RunContext, pos: Vector2i, receipt: Dictionary, rules: Dictionary = {}) -> Dictionary:
	var reason := _validate(context, pos, "coil")
	if not reason.is_empty():
		return _fail(reason)
	if str(receipt.get("room_type", "")) != "normal" or receipt.get("complete") != true:
		return _noop()
	if str(receipt.get("search_id", "")).is_empty() or str(receipt.get("room_id", "")) != context.cell_key(pos):
		return _fail("invalid_search_receipt")
	var global := _global(context)
	var pending: Dictionary = global.get("coil_pending", {})
	var searches: Dictionary = global.get("coil_searches", {})
	if searches.has(str(receipt.search_id)) or pending.is_empty():
		return _noop()
	var pool := _pool(context, "normal_search", rules)
	if not pool.ok:
		return pool
	var source_pos: Vector2i = pending.pos
	var state := _room(context, source_pos, "coil")
	var rng := _rng(context, pos, "coil:" + str(pending.room_id), 0)
	var item: Dictionary = _draw(pool.items, 1, rng)[0]
	var granted := _grant(context, pos, "coil", [item], _instance_id(context, source_pos, "coil") + ":extra")
	if not granted.ok:
		return granted
	global.erase("coil_pending")
	searches[str(receipt.search_id)] = true
	global["coil_searches"] = searches
	context.z1_event_flags[KEY] = global
	state["completed"] = true
	return _commit(context, source_pos, "coil", state, {"ok": true, "stage": "extra_delivered", "facts": {
		"search_id": str(receipt.search_id), "search_room_id": context.cell_key(pos), "items": granted.items,
		"item_instance_id": str(granted.items[0].instance_id), "origin_channel": str(pool.channel)}})


static func on_cage_combat_completed(context: RunContext, pos: Vector2i, receipt: Dictionary) -> Dictionary:
	var reason := _validate(context, pos, "cage", true)
	if not reason.is_empty():
		return _fail(reason)
	var state := _room(context, pos, "cage")
	var request: Dictionary = state.get("combat_request", {})
	if request.is_empty() or receipt.get("actual_combat") != true or str(receipt.get("encounter_id", "")) != str(request.encounter_id) or str(receipt.get("room_id", "")) != context.cell_key(pos) or str(receipt.get("outcome", "")) not in ["win", "loss"]:
		return _fail("invalid_combat_receipt")
	if bool(state.get("completed", false)):
		return _noop()
	var won := str(receipt.outcome) == "win"
	var power_gain := 2 * int(request.original_power) if won else 0
	context.power += power_gain
	state["completed"] = true
	state["phase"] = "resolved"
	return _commit(context, pos, "cage", state, {"ok": true, "stage": "combat_resolved", "xp": 10 if won else 5,
		"talent": 5 if won else 2, "facts": {"encounter_id": str(request.encounter_id), "actual_combat": true,
			"win": won, "outcome": str(receipt.outcome), "original_power": int(request.original_power),
			"power_gain": power_gain, "ordinary_clear_rewards": false}})


static func _prepare(context: RunContext, pos: Vector2i, event: String, state: Dictionary, rules: Dictionary) -> Dictionary:
	if bool(state.get("completed", false)):
		return _fail("completed")
	var global := _global(context)
	var tier := mini(5, int(global.get("altar_tier", 0)) + 1)
	if event == "altar" and int(global.get("altar_tier", 0)) >= 5 and int(state.get("offer_count", 0)) > 0:
		return _fail("completed")
	if bool(state.get("prepared", false)) and (event != "altar" or int(state.get("tier", 0)) == tier):
		return _noop()
	var rng := _rng(context, pos, event, tier if event == "altar" else 0)
	match event:
		"mechanism":
			var variant := str(rules.get("mechanism_variant", "mechanical"))
			if variant not in ["mechanical", "electric"]:
				return _fail("invalid_mechanism_variant")
			var pool := _pool(context, "mechanism" if variant == "mechanical" else "electric", rules)
			if not pool.ok:
				return pool
			state["variant"] = variant
			state["rewards"] = _draw(pool.items, 2 if variant == "mechanical" else 1, rng)
			if variant == "mechanical":
				var difficulty := str(rules.get("difficulty", str(context.run_start_config.get("map_config_id", "")).get_slice("_", 2)))
				if not DIFFICULTY.has(difficulty) or context.current_adjacent_mines < 0 or context.current_adjacent_mines > 8:
					return _fail("invalid_mechanism_conditions")
				state["base_threshold"] = (22.0 + 3.0 * context.current_adjacent_mines) * float(DIFFICULTY[difficulty]) * rng.randf_range(0.85, 1.15)
				state["threshold"] = state.base_threshold
		"recycle":
			var pool := _pool(context, "recycle", rules)
			if not pool.ok:
				return pool
			var materials: Array = []
			for item: Dictionary in pool.items:
				if _recycle_value(item, rules) > 0:
					materials.append(item)
			if materials.is_empty():
				return _fail("empty_material_pool")
			state["rewards"] = _draw(materials, 1, rng)
		"coil":
			var pool := _pool(context, "normal_search", rules)
			if not pool.ok:
				return pool
		"rps":
			var prizes: Variant = rules.get("rps_reward_pool", [])
			if not prizes is Array or prizes.is_empty():
				return _fail("missing_rps_reward_pool")
			for prize: Variant in prizes:
				if not prize is int or prize < 10 or prize > 40:
					return _fail("invalid_rps_reward_pool")
			state["prize"] = prizes[rng.randi_range(0, prizes.size() - 1)]
			state["wins"] = 0
			state["losses"] = 0
			state["rounds"] = []
		"dice":
			state["rounds"] = []
		"altar":
			var pool := _pool(context, "altar", rules)
			if not pool.ok:
				return pool
			state["rewards"] = _draw(pool.items, 1, rng)
			state["tier"] = tier
			state["hp_cost"] = ALTAR_HP[tier - 1]
			state["black_reward"] = ALTAR_BLACK[tier - 1]
			state["assisted"] = false
	state["prepared"] = true
	state["phase"] = "entered"
	return _commit(context, pos, event, state, {"ok": true, "facts": {}})


static func _mechanism(context: RunContext, pos: Vector2i, state: Dictionary, action: String, payload: Dictionary, rules: Dictionary) -> Dictionary:
	var electric := str(state.variant) == "electric"
	if action == "assist":
		var material := _material(context, str(payload.get("instance_id", "")), ["insulation", "repair"] if electric else ["dismantling", "reset"], rules)
		if not material.ok:
			return material
		var consumed := context.asset_ledger.transfer_event_items([str(material.item.instance_id)], &"consumed")
		if not consumed.ok:
			return consumed
		if not electric:
			state["threshold"] = maxf(0.0, float(state.threshold) - 3.0)
			return {"ok": true, "facts": {"material_instance_id": str(material.item.instance_id), "threshold": state.threshold}}
	elif action != "attempt":
		return _fail("invalid_selection")
	var won := electric or float(context.power) >= float(state.threshold)
	var facts := {"success": won, "items": []}
	if (electric and action == "attempt") or not won:
		var kind := str(rules.get("electric_damage_type" if electric else "mechanism_failure_damage_type", ""))
		if kind.is_empty():
			return _fail("missing_damage_type")
		if kind not in ["physical", "mine", "dot"]:
			return _fail("invalid_damage_type")
		var damage := Effects.apply_damage_packet(context, {"amount": mini(10, maxi(0, context.hp - 1)) if electric else 1,
			"damage_type": kind, "source_id": "z2_mechanism"})
		if not damage.ok:
			return damage
		facts["damage"] = damage.facts
		if not electric:
			var pressure := Effects.apply_pressure_packet(context, {"amount": 5, "source_id": "z2_mechanism_failure"})
			if not pressure.ok:
				return pressure
			facts["pressure"] = pressure.facts
	if won:
		var granted := _grant(context, pos, "mechanism", state.rewards, _instance_id(context, pos, "mechanism") + ":reward")
		if not granted.ok:
			return granted
		var income := 6 if electric else 25
		context.asset_ledger.add_currency(&"black_coin", income, "z2_mechanism")
		facts["black_income_gross"] = income
		facts["items"] = granted.items
	state["completed"] = true
	return {"ok": true, "stage": "resolved", "facts": facts}


static func _recycle(context: RunContext, pos: Vector2i, state: Dictionary, action: String, payload: Dictionary, rules: Dictionary) -> Dictionary:
	if action not in ["take", "deliver"]:
		return _fail("invalid_selection")
	var item: Dictionary = state.rewards[0]
	var instance_id := str(payload.get("instance_id", ""))
	if action == "take" and not instance_id.is_empty():
		return _fail("invalid_selection")
	if not instance_id.is_empty():
		var material := _material(context, instance_id, ["mechanical_material", "anomalous_sample"], rules)
		if not material.ok:
			return material
		item = material.item
	var price := _recycle_value(item, rules)
	if price <= 0:
		return _fail("invalid_material")
	var facts := {"operation": action, "item_id": str(item.item_id), "items": []}
	if instance_id.is_empty():
		if action == "deliver":
			# Admit and hand back in the same atomic command; no backpack space is
			# required for a material that never becomes a carried reward.
			var offered := item.duplicate(true)
			offered["instance_id"] = _instance_id(context, pos, "recycle") + ":onsite"
			offered["source"] = "z2_recycle_onsite"
			var admitted := context.asset_ledger.create_item_instance(offered, &"inventory", pos)
			if admitted.is_empty():
				return _fail("duplicate_item_instance")
			instance_id = str(admitted.instance_id)
		else:
			var granted := _grant(context, pos, "recycle", [item], _instance_id(context, pos, "recycle") + ":material")
			if not granted.ok:
				return granted
			instance_id = str(granted.items[0].instance_id)
			facts["items"] = granted.items
	if action == "deliver":
		var delivered := context.asset_ledger.deliver_inventory_item(instance_id, str(item.item_id), "z2_recycle")
		if not delivered.ok:
			return delivered
		context.asset_ledger.add_currency(&"gold_coin", price, "z2_recycle")
		facts["safe_income"] = price
	facts["item_instance_id"] = instance_id
	state["completed"] = true
	return {"ok": true, "stage": "resolved", "facts": facts}


static func _coil(context: RunContext, pos: Vector2i, state: Dictionary, action: String, rules: Dictionary) -> Dictionary:
	if action != "calibrate":
		return _fail("invalid_selection")
	var global := _global(context)
	if not global.get("coil_pending", {}).is_empty():
		return _fail("coil_pending")
	var pool := _pool(context, "normal_search", rules)
	if not pool.ok:
		return pool
	if not _pay(context, 5):
		return _fail("insufficient_black")
	global["coil_pending"] = {"room_id": context.cell_key(pos), "pos": pos, "event_instance_id": _instance_id(context, pos, "coil")}
	context.z1_event_flags[KEY] = global
	state["phase"] = "pending_search"
	return {"ok": true, "facts": {"fee_black": 5}}


static func _work(context: RunContext, pos: Vector2i, state: Dictionary, action: String) -> Dictionary:
	var global := _global(context)
	var work: Dictionary = global.get("work", {})
	if action == "register":
		if not work.is_empty():
			return _fail("work_contract_exists")
		if not _pay(context, 4):
			return _fail("insufficient_black")
		global["work"] = {"origin_room_id": context.cell_key(pos), "known_rooms": context.visited_cells.duplicate(true), "new_rooms": {}, "claimed": false}
		context.z1_event_flags[KEY] = global
		state["phase"] = "registered"
		return {"ok": true, "facts": {"fee_black": 4}}
	if action != "claim":
		return _fail("invalid_selection")
	if work.is_empty() or work.get("new_rooms", {}).size() < 3:
		return _fail("work_incomplete")
	if bool(work.get("claimed", false)):
		return _fail("work_claimed")
	context.asset_ledger.add_currency(&"black_coin", 12, "z2_clock_in")
	work["claimed"] = true
	work["delivery_room_id"] = context.cell_key(pos)
	global["work"] = work
	context.z1_event_flags[KEY] = global
	state["completed"] = true
	return {"ok": true, "stage": "paid", "facts": {"black_income_gross": 12, "origin_room_id": str(work.origin_room_id), "new_rooms": work.new_rooms.keys()}}


static func _rps(context: RunContext, pos: Vector2i, state: Dictionary, action: String) -> Dictionary:
	if not HANDS.has(action):
		return _fail("invalid_selection")
	var rounds: Array = state.rounds
	var rng := _rng(context, pos, "rps_round", rounds.size())
	var opponent: String = HANDS[rng.randi_range(0, 2)]
	var outcome := "tie"
	if action != opponent:
		outcome = "win" if (HANDS.find(action) - HANDS.find(opponent) + 3) % 3 == 1 else "loss"
		state["wins" if outcome == "win" else "losses"] += 1
	var facts := {"player": action, "opponent": opponent, "outcome": outcome, "round_id": _instance_id(context, pos, "rps") + ":round:%d" % (rounds.size() + 1)}
	rounds.append(facts.duplicate(true))
	state["rounds"] = rounds
	if int(state.wins) < 2 and int(state.losses) < 2:
		return {"ok": true, "facts": facts}
	state["completed"] = true
	var prize := int(state.prize) if int(state.wins) == 2 else 0
	if prize > 0:
		context.asset_ledger.add_currency(&"black_coin", prize, "z2_rps")
	facts["black_income_gross"] = prize
	facts["match_win"] = int(state.wins) == 2
	return {"ok": true, "stage": "match_finished", "facts": facts}


static func _dice(context: RunContext, pos: Vector2i, state: Dictionary, action: String) -> Dictionary:
	if action != "roll":
		return _fail("invalid_selection")
	var rounds: Array = state.rounds
	if rounds.size() >= 3:
		return _fail("completed")
	if not _pay(context, 20):
		return _fail("insufficient_black")
	var weights: Array = [1, 1, 1, 1, 1, 1] if rounds.is_empty() else [9, 9, 9, 9, 8, 4]
	var rng := _rng(context, pos, "dice", rounds.size())
	var ticket := rng.randi_range(0, 5 if rounds.is_empty() else 47)
	var face := 1
	for weight: int in weights:
		if ticket < weight:
			break
		ticket -= weight
		face += 1
	var returned := 0 if face < 5 else (40 if face == 5 else 80)
	if returned > 0:
		context.asset_ledger.add_currency(&"black_coin", returned, "z2_dice_return")
	var facts := {"face": face, "win": face >= 5, "weights": weights, "round": rounds.size() + 1,
		"round_id": _instance_id(context, pos, "dice") + ":round:%d" % (rounds.size() + 1),
		"fee_black": 20, "returned_black": returned, "black_income_gross": returned, "net_black": returned - 20}
	rounds.append(facts.duplicate(true))
	state["rounds"] = rounds
	state["completed"] = rounds.size() == 3
	return {"ok": true, "stage": "room_played" if rounds.size() == 1 else "", "facts": facts}


static func _altar(context: RunContext, pos: Vector2i, state: Dictionary, action: String, payload: Dictionary, rules: Dictionary) -> Dictionary:
	var global := _global(context)
	var previous_tier := int(global.get("altar_tier", 0))
	var tier := mini(5, previous_tier + 1)
	if previous_tier >= 5 and int(state.get("offer_count", 0)) > 0:
		return _fail("completed")
	if int(state.tier) != tier:
		return _fail("stale_altar_offer")
	if action == "assist":
		if bool(state.get("assisted", false)):
			return _fail("already_assisted")
		var material := _material(context, str(payload.get("instance_id", "")), ["stabilizing", "flow_control"], rules)
		if not material.ok:
			return material
		var consumed := context.asset_ledger.transfer_event_items([str(material.item.instance_id)], &"consumed")
		if not consumed.ok:
			return consumed
		state["assisted"] = true
		state["hp_cost"] = int(state.hp_cost) - 5
		return {"ok": true, "facts": {"material_instance_id": str(material.item.instance_id), "hp_cost": int(state.hp_cost)}}
	if action != "offer":
		return _fail("invalid_selection")
	var payment := Effects.apply_damage_packet(context, {"amount": int(state.hp_cost), "damage_type": "hp_payment", "source_id": "z2_altar"})
	if not payment.ok:
		return payment
	var granted := _grant(context, pos, "altar", state.rewards, _instance_id(context, pos, "altar") + ":tier:%d" % tier)
	if not granted.ok:
		return granted
	var income: int = ALTAR_BLACK[tier - 1]
	context.asset_ledger.add_currency(&"black_coin", income, "z2_altar")
	global["altar_tier"] = tier
	context.z1_event_flags[KEY] = global
	state["offer_count"] = int(state.get("offer_count", 0)) + 1
	state["completed"] = tier == 5
	state["prepared"] = tier == 5
	return {"ok": true, "stage": "tier:%d" % tier, "talent_key": str(context.run_id) + ":z2:altar:tier:%d" % tier,
		"facts": {"tier": tier, "payment": payment.facts, "black_income_gross": income, "items": granted.items}}


static func _pool(context: RunContext, key: String, rules: Dictionary) -> Dictionary:
	var pools: Variant = rules.get("pools", {})
	if not pools is Dictionary or not pools.has(key):
		return _fail("missing_pool")
	var pool: Variant = pools[key]
	if not pool is Dictionary or not pool.get("items") is Array or str(pool.get("channel", "")).is_empty():
		return _fail("invalid_pool")
	var channel := str(pool.channel)
	if channel in ["qualification", "starter_claim", "research_craft"] or (key == "normal_search" and channel != "search"):
		return _fail("invalid_pool_channel")
	var profile: Variant = context.run_start_config.get("profile_fields", {})
	if not profile is Dictionary or not profile.get("content_eligibility") is Dictionary:
		return _fail("missing_frozen_eligibility")
	var frozen: Dictionary = profile.content_eligibility
	if frozen.get("content_version", "") != Items.CONTENT_VERSION:
		return _fail("invalid_frozen_eligibility")
	var definitions: Variant = rules.get("definitions", {})
	if not definitions is Dictionary:
		return _fail("invalid_pool_definitions")
	var items: Array[Dictionary] = []
	var total_weight := 0.0
	for raw: Variant in pool.items:
		var id: Variant = ""
		var weight: Variant = 1.0
		if raw is String or raw is StringName:
			id = raw
		elif raw is Dictionary:
			id = raw.get("item_id", "")
			weight = raw.get("roll_weight", 1.0)
		elif raw is Array and raw.size() == 2:
			id = raw[0]
			weight = raw[1]
		else:
			return _fail("invalid_pool_entry")
		if not (id is String or id is StringName) or str(id).is_empty():
			return _fail("invalid_pool_entry")
		if not (weight is int or weight is float) or not is_finite(float(weight)) or float(weight) <= 0.0:
			return _fail("invalid_pool_weight")
		if not Eligibility.is_eligible(str(id), channel, frozen, str(context.run_start_config.get("map_config_id", ""))):
			continue
		var item := _pool_definition(str(id), definitions)
		if item.is_empty() or bool(item.get("is_unique", false)):
			continue
		item["_roll_weight"] = float(weight)
		items.append(item)
		total_weight += float(weight)
	if items.is_empty():
		return _fail("empty_eligible_pool")
	if not is_finite(total_weight):
		return _fail("invalid_pool_weight")
	return {"ok": true, "items": items, "channel": channel}


static func _pool_definition(id: String, definitions: Dictionary) -> Dictionary:
	# Canonical72 values cannot be overridden by pool entry fields or injections.
	# The trusted Loot adapter supplies inherited materials outside that catalog.
	var item := Items.definition(id)
	if not item.is_empty():
		return item
	var inherited: Variant = definitions.get(id, {})
	if not inherited is Dictionary or str(inherited.get("item_id", "")) != id:
		return {}
	return inherited.duplicate(true)


static func _material(context: RunContext, id: String, tags: Array, rules: Dictionary) -> Dictionary:
	var item: Dictionary = context.asset_ledger.item_instances.get(id, {})
	if item.is_empty() or StringName(item.get("location_state", &"")) != &"inventory":
		return _fail("material_unavailable")
	if not _has_tag(item, tags, rules):
		return _fail("invalid_material")
	return {"ok": true, "item": item.duplicate(true)}


static func _has_tag(item: Dictionary, tags: Array, rules: Dictionary) -> bool:
	var mappings: Variant = rules.get("material_tags", {})
	if not mappings is Dictionary:
		return false
	var natural: Variant = mappings.get(str(item.get("item_id", "")), [])
	if not natural is Array:
		return false
	for tag: String in tags:
		if natural.has(tag):
			return true
	return false


static func _recycle_value(item: Dictionary, rules: Dictionary) -> int:
	if _has_tag(item, ["anomalous_sample"], rules):
		return 10
	return 5 if _has_tag(item, ["mechanical_material"], rules) else 0


static func _grant(context: RunContext, pos: Vector2i, event: String, definitions: Array, reward_id: String) -> Dictionary:
	var bound: Array[Dictionary] = []
	for index in range(definitions.size()):
		var item: Dictionary = definitions[index].duplicate(true)
		item["instance_id"] = reward_id + ":item:%d" % index
		bound.append(item)
	var result := context.asset_ledger.add_reward_items(bound, &"inventory", pos, "z2_process_" + event)
	if not result.get("ok", false):
		return result
	var items: Array = result.inventory_items.duplicate(true)
	items.append_array(result.ground_items)
	if items.size() != bound.size() or items.is_empty():
		return _fail("reward_not_delivered")
	return {"ok": true, "items": items}


static func _pay(context: RunContext, amount: int) -> bool:
	return bool(context.asset_ledger.spend_currency(&"black_coin", amount, "z2_process").get("ok", false))


static func _draw(pool: Array, count: int, rng: RandomNumberGenerator) -> Array:
	var result: Array = []
	if pool.is_empty():
		return result
	var total_weight := 0.0
	for item: Dictionary in pool:
		total_weight += float(item.get("_roll_weight", 1.0))
	for _i in range(count):
		var ticket := rng.randf() * total_weight
		var selected: Dictionary = pool.back()
		for item: Dictionary in pool:
			ticket -= float(item.get("_roll_weight", 1.0))
			if ticket < 0.0:
				selected = item
				break
		var output := selected.duplicate(true)
		output.erase("_roll_weight")
		result.append(output)
	return result


static func _rng(context: RunContext, pos: Vector2i, event: String, generation: int) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = ("%s|%d|%s|%s|%d" % [str(context.run_id), context.seed_value, context.cell_key(pos), event, generation]).hash()
	return rng


static func _commit(context: RunContext, pos: Vector2i, event: String, state: Dictionary, result: Dictionary) -> Dictionary:
	var stage := str(result.get("stage", ""))
	var valid := not stage.is_empty()
	var room_id := context.cell_key(pos)
	var instance_id := _instance_id(context, pos, event)
	var stage_id := instance_id + ":" + stage if valid else ""
	var xp_key := str(context.run_id) + ":z2:event_room:" + room_id
	var talent_key := str(result.get("talent_key", stage_id))
	var first_room := false
	var first_talent := false
	if valid:
		var global := _global(context)
		var xp_rooms: Dictionary = global.get("xp_rooms", {})
		var talent_stages: Dictionary = global.get("talent_stages", {})
		first_room = not xp_rooms.has(xp_key)
		first_talent = not talent_stages.has(talent_key)
		xp_rooms[xp_key] = true
		talent_stages[talent_key] = true
		global["xp_rooms"] = xp_rooms
		global["talent_stages"] = talent_stages
		context.z1_event_flags[KEY] = global
		state["stage_awarded"] = true
	state["revision"] = int(state.get("revision", 0)) + 1
	var facts: Dictionary = result.get("facts", {}).duplicate(true)
	facts.merge({"event_type": event, "event_instance_id": instance_id, "room_id": room_id, "stage_id": stage_id}, true)
	state["last_result"] = facts.duplicate(true)
	_store(context, pos, event, state)
	context.asset_ledger.sync_compat_fields(context)
	return {"ok": true, "reason": "", "event_type": event, "room_id": room_id, "room_key": room_id,
		"event_instance_id": instance_id, "progress_completed": valid, "valid_stage": valid, "stage_completed": valid,
		"stage_id": stage_id, "xp_key": xp_key, "talent_key": talent_key, "equipment_key": stage_id + ":equipment" if valid else "",
		"first_room_completion": first_room, "base_xp": int(result.get("xp", 5)) if first_room else 0,
		"base_talent": int(result.get("talent", 2)) if first_talent else 0, "facts": facts,
		"public_state": public_state(context, pos, event)}


static func _canonical(event_id: String) -> String:
	return str(LEGACY_IDS.get(event_id, event_id))


static func _validate(context: RunContext, pos: Vector2i, event: String, allow_terminal: bool = false) -> String:
	if context == null or context.asset_ledger == null or context.extracted or context.abandoned or (not allow_terminal and (not context.run_active or context.failed)):
		return "no_active_run"
	if not EVENTS.has(event):
		return "unsupported_event"
	if pos != context.get_current_pos():
		return "not_current_room"
	var profile: Dictionary = context.profile_fields
	if str(profile.get("ruleset_id", "")) != "z2" or profile.get("z2_progression_version") != 1:
		return "wrong_ruleset"
	if not profile.get("content_eligibility") is Dictionary:
		return "missing_frozen_eligibility"
	return ""


static func _room(context: RunContext, pos: Vector2i, event: String) -> Dictionary:
	var room: Dictionary = context.z1_event_rooms.get(context.cell_key(pos), {})
	var processes: Dictionary = room.get(KEY, {})
	return processes.get(event, {"revision": 0, "completed": false, "prepared": false}).duplicate(true)


static func _store(context: RunContext, pos: Vector2i, event: String, state: Dictionary) -> void:
	var room: Dictionary = context.z1_event_rooms.get(context.cell_key(pos), {}).duplicate(true)
	var processes: Dictionary = room.get(KEY, {})
	processes[event] = state.duplicate(true)
	room[KEY] = processes
	context.z1_event_rooms[context.cell_key(pos)] = room


static func _global(context: RunContext) -> Dictionary:
	return context.z1_event_flags.get(KEY, {}).duplicate(true)


static func _instance_id(context: RunContext, pos: Vector2i, event: String) -> String:
	return "%s:z2:process:%s:%s" % [str(context.run_id), context.cell_key(pos), event]


static func _noop() -> Dictionary:
	return {"ok": true, "ignored": true, "durability_required": false, "progress_completed": false, "valid_stage": false,
		"stage_completed": false, "base_xp": 0, "base_talent": 0, "facts": {}}


static func _fail(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason, "progress_completed": false, "valid_stage": false, "stage_completed": false}
