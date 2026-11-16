extends RefCounted
class_name Z2EconomyEvents

const Items = preload("res://scripts/core/content/z2_item_catalog.gd")
const Eligibility = preload("res://scripts/core/content/z2_content_eligibility.gd")
const Snapshot = preload("res://scripts/core/run/run_state_snapshot.gd")
const Effects = preload("res://scripts/core/run/run_effect_applier.gd")
const SEAL_USED_FLAG := "z2_salvage_seal_used"
const EVACUATION_SERVICE_FLAG := "z2_evacuation_service_done"
const EVENTS := ["shop", "savings", "seal", "relief", "first_aid", "consign", "expand", "compress", "trader", "pawn"]
const LEGACY_IDS := {
	"z1_event_e25": "shop", "z1_event_e03": "savings", "z1_event_e05": "seal",
	"z1_event_e09": "relief", "z1_event_e23": "relief", "z1_event_e10": "first_aid",
	"z1_event_e11": "consign", "z1_event_e12": "expand", "z1_event_e13": "compress",
	"z1_event_e14": "trader", "merchant": "trader", "z1_event_e15": "pawn",
}

# T14 calls this before its capacity check, for its already selected candidates.
# It changes neither item weights nor locations; T14 owns terminal eligibility.
static func salvage_weights(context: RunContext, ending: String, selected_instance_ids: Array) -> Dictionary:
	if context == null or context.asset_ledger == null or ending not in ["success", "failure", "abandon"]:
		return _fail("invalid_salvage_context")
	var weights := {}
	var raw_weight := 0
	var heaviest := ""
	var heaviest_weight := 0
	for raw_id: Variant in selected_instance_ids:
		if not raw_id is String or str(raw_id).is_empty() or weights.has(raw_id):
			return _fail("invalid_salvage_selection")
		var id := str(raw_id)
		var item: Dictionary = context.asset_ledger.item_instances.get(id, {})
		if str(item.get("location_state", "")) not in ["inventory", "equipped", "settlement_pool"] or int(item.get("weight", -1)) < 0:
			return _fail("invalid_salvage_selection")
		var weight := int(item.weight)
		weights[id] = weight
		raw_weight += weight
		if _normal_collectible(item) and (weight > heaviest_weight or (weight == heaviest_weight and id < heaviest)):
			heaviest = id
			heaviest_weight = weight
	var saved := 0
	if ending in ["failure", "abandon"] and bool(context.z1_event_flags.get(SEAL_USED_FLAG, false)) and not heaviest.is_empty():
		var reduced := maxi(1, heaviest_weight - 10)
		saved = heaviest_weight - reduced
		weights[heaviest] = reduced
	return {"ok": true, "ending": ending, "weights": weights, "raw_weight": raw_weight,
		"selected_weight": raw_weight - saved, "weight_saved": saved, "discounted_instance_id": heaviest if saved > 0 else ""}

# Public projections never draw, reserve, pay, award growth, or write a save.
# choose MUST run inside execute_atomic_operation. The caller also applies the
# returned black_income_gross to its unified income triggers, in that same action.
# shop_pool / compression_pool are trusted caller inputs, NOT player payloads.
# No guessed official pool: missing pools fail closed. Duplicates encode weighting.
static func public_state(context: RunContext, pos: Vector2i, event_id: String, _catalog: Dictionary = {}) -> Dictionary:
	var event := _canonical(event_id)
	var rejection := _validate(context, pos, event)
	if not rejection.is_empty():
		return _fail(rejection)
	var state := _room_state(context, pos, event)
	var quote: Dictionary = state.get("quote", {})
	var stale := quote.is_empty() or str(quote.get("conditions", "")) != Snapshot.fingerprint(_conditions(context, pos, event, state))
	return {
		"ok": true, "event_type": event, "room_key": context.cell_key(pos),
		"prepared": not quote.is_empty(), "requires_prepare": stale,
		"completed": bool(state.get("completed", false)), "stage_awarded": bool(state.get("stage_awarded", false)),
		"refresh_count": int(state.get("refresh_count", 0)),
		"offers": state.get("offers", []).duplicate(true), "reward": state.get("reward", {}).duplicate(true),
		"quote_id": str(quote.get("quote_id", "")), "quote": quote.duplicate(true),
		"options": quote.get("options", []).duplicate(true),
	}


static func choose(context: RunContext, pos: Vector2i, event_id: String, option_id: String, payload: Dictionary = {}, catalog: Dictionary = {}) -> Dictionary:
	var event := _canonical(event_id)
	var rejection := _validate(context, pos, event)
	if not rejection.is_empty():
		return _fail(rejection)
	var state := _room_state(context, pos, event)
	if option_id == "prepare":
		return _prepare(context, pos, event, state, payload, catalog)
	var quote: Dictionary = state.get("quote", {})
	if quote.is_empty():
		return _fail("not_prepared")
	if str(payload.get("quote_id", "")) != str(quote.quote_id) or str(quote.conditions) != Snapshot.fingerprint(_conditions(context, pos, event, state)):
		return _fail("stale_quote")
	var option := _find_option(quote.get("options", []), option_id, payload)
	if option.is_empty():
		return _fail("invalid_selection")
	if not bool(option.enabled):
		return _fail(str(option.reason))
	var result := _execute(context, pos, event, state, option, payload, catalog)
	if not bool(result.get("ok", false)):
		return result
	var delivered := option_id != "refresh"
	var stage := delivered and not bool(state.get("stage_awarded", false))
	var room_key := context.cell_key(pos)
	var room: Dictionary = context.z1_event_rooms.get(room_key, {}).duplicate(true)
	var first_room := stage and not bool(room.get("z2_economy_xp_delivered", false))
	if stage:
		state["stage_awarded"] = true
		room["z2_economy_xp_delivered"] = true
		context.z1_event_rooms[room_key] = room
	if delivered and event != "shop":
		state["completed"] = true
	var facts: Dictionary = result.get("facts", {})
	facts["event_type"] = event
	facts["option_id"] = option_id
	facts["room_key"] = room_key
	facts["fee_black"] = int(option.fee_black)
	var history: Array = state.get("transactions", [])
	history.append({"quote": quote.duplicate(true), "option_id": option_id, "facts": facts.duplicate(true)})
	state["transactions"] = history
	_write_quote(context, pos, event, state)
	_store_room(context, pos, event, state)
	context.asset_ledger.sync_compat_fields(context)
	return {"ok": true, "reason": "", "event_type": event, "option_id": option_id,
		"facts": facts, "stage_completed": stage, "first_room_completion": first_room,
		"stage_id": "z2:economy:%s:%s:delivered" % [room_key, event], "xp_key": "z2:event_room:" + room_key,
		"base_talent": 2 if stage else 0, "base_xp": 5 if first_room else 0,
		"quote_id": str(quote.quote_id), "public_state": public_state(context, pos, event)}


static func _canonical(event_id: String) -> String:
	return str(LEGACY_IDS.get(event_id, event_id))


static func _validate(context: RunContext, pos: Vector2i, event: String) -> String:
	if context == null or context.asset_ledger == null or not context.run_active or context.failed or context.extracted or context.abandoned:
		return "no_active_run"
	if not EVENTS.has(event):
		return "unsupported_event"
	if pos != context.get_current_pos():
		return "not_current_room"
	var profile: Dictionary = context.run_start_config.get("profile_fields", {})
	if str(profile.get("ruleset_id", "")) != "z2" or int(profile.get("z2_progression_version", 0)) != 1:
		return "wrong_ruleset"
	if not profile.get("content_eligibility", null) is Dictionary:
		return "missing_frozen_eligibility"
	return ""


static func _fail(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason}


static func _room_state(context: RunContext, pos: Vector2i, event: String) -> Dictionary:
	var room: Dictionary = context.z1_event_rooms.get(context.cell_key(pos), {})
	var economy: Dictionary = room.get("z2_economy", {})
	return economy.get(event, {"completed": false, "stage_awarded": false, "refresh_count": 0, "selection": {}}).duplicate(true)


static func _store_room(context: RunContext, pos: Vector2i, event: String, state: Dictionary) -> void:
	var key := context.cell_key(pos)
	var room: Dictionary = context.z1_event_rooms.get(key, {}).duplicate(true)
	var economy: Dictionary = room.get("z2_economy", {})
	economy[event] = state
	room["z2_economy"] = economy
	context.z1_event_rooms[key] = room


static func _global(context: RunContext) -> Dictionary:
	return context.z1_event_flags.get("z2_economy", {}).duplicate(true)


static func _prepare(context: RunContext, pos: Vector2i, event: String, state: Dictionary, payload: Dictionary, catalog: Dictionary) -> Dictionary:
	if event == "savings" and payload.has("amount"):
		if not payload.amount is int or int(payload.amount) <= 0:
			return _fail("invalid_principal")
		var principal := int(payload.amount)
		@warning_ignore("integer_division")
		var interest := principal / 5
		if principal > 9223372036854775807 - interest:
			return _fail("principal_overflow")
		# floor(50%P) and floor(120%P) without floating-point currency loss.
		state["selection"] = {"amount": principal, "guarantee": principal >> 1, "withdrawal": principal + interest}
	if event == "shop" and not state.has("offers"):
		var pool := _pool(context, event, catalog)
		if not pool.ok:
			return pool
		state["offers"] = _draw_offers(context, pos, pool.items, 0)
	if event in ["compress", "first_aid", "seal"] and not state.has("reward"):
		var pool := _pool(context, event, catalog)
		if not pool.ok:
			return pool
		var rng := _rng(context, pos, event, 0)
		state["reward"] = _draw(pool.items, rng)
	_write_quote(context, pos, event, state)
	_store_room(context, pos, event, state)
	return {"ok": true, "reason": "", "event_type": event, "option_id": "prepare", "facts": {},
		"stage_completed": false, "first_room_completion": false, "public_state": public_state(context, pos, event)}


static func _pool(context: RunContext, event: String, catalog: Dictionary) -> Dictionary:
	var key: String = {"shop": "shop_pool", "compress": "compression_pool", "first_aid": "first_aid_pool", "seal": "seal_pool"}[event]
	var channel: String = {"shop": "shop", "compress": "compression", "first_aid": "first_aid_cabinet", "seal": "salvage_seal_cabinet"}[event]
	if event in ["shop", "compress"] and not catalog.has(key):
		return _fail("missing_pool")
	var fixed_id := "con_med_patch" if event == "first_aid" else "con_salvage_seal"
	var raw: Variant = catalog.get(key, [fixed_id])
	if not raw is Array:
		return _fail("invalid_pool")
	var profile: Dictionary = context.run_start_config.profile_fields
	var pool: Array[Dictionary] = []
	var total_weight := 0.0
	for entry: Variant in raw:
		var id := ""
		var raw_weight: Variant = 1.0
		if entry is Array and entry.size() == 2:
			id = str(entry[0])
			raw_weight = entry[1]
		elif entry is Dictionary:
			id = str(entry.get("item_id", entry.get("definition_id", entry.get("id", ""))))
			raw_weight = entry.get("roll_weight", 1.0)
		elif entry is String or entry is StringName:
			id = str(entry)
		else:
			return _fail("invalid_pool")
		if not (raw_weight is int or raw_weight is float) or not is_finite(float(raw_weight)) or float(raw_weight) <= 0.0:
			return _fail("invalid_pool_weight")
		if Eligibility.filter_pool([id], channel, profile.content_eligibility, str(context.run_start_config.get("map_config_id", ""))).is_empty():
			continue
		var item := Items.definition(id)
		if item.is_empty() or bool(item.get("is_unique", false)) or int(item.get("weight", -1)) < 0:
			continue
		if event == "shop" and (str(item.item_type) not in ["equipment", "consumable"] or int(item.purchase_price) <= 0):
			continue
		if event == "compress" and (not _normal_collectible(item) or _tier(item) != 2):
			continue
		if event in ["first_aid", "seal"] and id != fixed_id:
			continue
		pool.append({"item": item, "roll_weight": float(raw_weight)})
		total_weight += float(raw_weight)
	if pool.is_empty():
		return _fail("empty_eligible_pool")
	if not is_finite(total_weight):
		return _fail("invalid_pool_weight")
	return {"ok": true, "items": pool}


static func _rng(context: RunContext, pos: Vector2i, event: String, generation: int) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = ("%s|%s|%s|%s|%d" % [str(context.run_id), str(context.seed_value), context.cell_key(pos), event, generation]).hash()
	return rng


static func _draw_offers(context: RunContext, pos: Vector2i, pool: Array, generation: int) -> Array[Dictionary]:
	var rng := _rng(context, pos, "shop", generation)
	var offers: Array[Dictionary] = []
	for slot in range(3):
		var item := _draw(pool, rng)
		offers.append({"slot": slot, "item": item, "price": ceili(float(item.purchase_price) * 1.3), "sold": false})
	return offers


static func _draw(pool: Array, rng: RandomNumberGenerator) -> Dictionary:
	var total := 0.0
	for entry: Dictionary in pool:
		total += float(entry.roll_weight)
	var target := rng.randf() * total
	for entry: Dictionary in pool:
		target -= float(entry.roll_weight)
		if target < 0.0:
			return entry.item.duplicate(true)
	return pool.back().item.duplicate(true)


static func _conditions(context: RunContext, pos: Vector2i, event: String, state: Dictionary) -> Dictionary:
	var inventory: Array = []
	var ids: Array = context.asset_ledger.item_instances.keys()
	ids.sort()
	for id: Variant in ids:
		var item: Dictionary = context.asset_ledger.item_instances[id]
		if str(item.get("location_state", "")) in ["inventory", "equipped"]:
			inventory.append(item.duplicate(true))
	return {"run_id": str(context.run_id), "room": context.cell_key(pos), "event": event,
		"frozen": context.run_start_config.profile_fields.content_eligibility,
		"map": context.run_start_config.get("map_config_id", ""),
		"black": context.asset_ledger.get_currency(&"black_coin"), "safe": context.asset_ledger.get_currency(&"gold_coin"),
		"inventory": inventory, "capacities": context.asset_ledger.get_capacity_snapshot(),
		"vitals": Effects.capture_vitals(context), "protocol_reduction": context.protocol_pressure_reduce,
		"global": _global(context), "seal_used": bool(context.z1_event_flags.get(SEAL_USED_FLAG, false)),
		"evacuation_service": bool(context.z1_event_flags.get(EVACUATION_SERVICE_FLAG, false)),
		"completed": state.get("completed", false), "stage_awarded": state.get("stage_awarded", false),
		"refresh_count": state.get("refresh_count", 0), "offers": state.get("offers", []),
		"reward": state.get("reward", {}), "selection": state.get("selection", {})}


static func _write_quote(context: RunContext, pos: Vector2i, event: String, state: Dictionary) -> void:
	var quote := {"conditions": Snapshot.fingerprint(_conditions(context, pos, event, state)),
		"options": _options(context, pos, event, state)}
	quote["quote_id"] = Snapshot.fingerprint(quote)
	state["quote"] = quote


static func _option(id: String, fee: int = 0, params: Dictionary = {}, reward: Dictionary = {}, reason: String = "") -> Dictionary:
	return {"option_id": id, "fee_black": fee, "params": params, "reward": reward, "enabled": reason.is_empty(), "reason": reason}


static func _options(context: RunContext, pos: Vector2i, event: String, state: Dictionary) -> Array[Dictionary]:
	var options: Array[Dictionary] = []
	var global := _global(context)
	var pending: Dictionary = global.get("savings_pending", {})
	match event:
		"shop":
			for offer: Dictionary in state.get("offers", []):
				options.append(_option("buy", int(offer.price), {"slot": int(offer.slot)}, {"item": offer.item}, "sold" if offer.sold else ""))
			options.append(_option("refresh", 5 + 5 * int(state.get("refresh_count", 0))))
		"savings":
			var amount := int(state.get("selection", {}).get("amount", 0))
			options.append(_option("deposit", amount, {"amount": amount}, {"safe_guarantee": int(state.get("selection", {}).get("guarantee", 0)), "withdrawal": int(state.get("selection", {}).get("withdrawal", 0))}, "pending_deposit" if not pending.is_empty() else ("select_principal" if amount <= 0 else "")))
			var withdrawal_reason := "no_pending_deposit" if pending.is_empty() else ("same_room_savings" if str(pending.get("room_key", "")) == context.cell_key(pos) else "")
			if not pending.is_empty() and context.asset_ledger.get_currency(&"gold_coin") < int(pending.guarantee):
				withdrawal_reason = "guarantee_unavailable"
			options.append(_option("withdraw", 0, {}, {"black": int(pending.get("withdrawal", 0)), "revoke_safe": int(pending.get("guarantee", 0))}, withdrawal_reason))
		"seal":
			options.append(_option("use", 10 if context.z1_event_flags.get(EVACUATION_SERVICE_FLAG, false) else 20, {},
				{"salvage_capacity": 20, "weight_reduction": 10, "min_weight": 1, "item": state.get("reward", {})}, "seal_already_used" if context.z1_event_flags.get(SEAL_USED_FLAG, false) else ""))
		"relief":
			for row in [["flat", 5, mini(5, context.pressure)], ["ten_percent", 10, floori(context.pressure * 0.1)], ["thirty_percent", 30, floori(context.pressure * 0.3)]]:
				options.append(_option(row[0], row[1], {}, {"pressure_reduction": row[2]}, "no_effect" if int(row[2]) <= 0 else ""))
		"first_aid":
			options.append(_option("buy", 9 if context.pressure < 40 else 4, {}, {"item": state.get("reward", {}), "base_pressure": 0 if context.pressure < 40 else 5}))
		"expand":
			options.append(_option("expand", 8, {}, {"loot_capacity": 20}))
		"compress":
			options.append(_option("compress", 0, {}, {"item": state.get("reward", {}), "input_count": 2, "input_tier": 1}))
		"consign", "trader", "pawn":
			for item: Dictionary in context.asset_ledger.get_items_by_location(&"inventory"):
				var id := str(item.instance_id)
				if event == "consign" and _normal_collectible(item) and int(item.weight) <= 20:
					var fee := maxi(8, ceili((float(item.base_value) + 5.0 * float(item.weight)) / 10.0))
					options.append(_option("consign", fee, {"instance_id": id}, {"destination": "consigned", "item": item.duplicate(true)}))
				elif event == "pawn" and _normal_collectible(item) and int(item.base_value) >= 21:
					options.append(_option("pawn", 0, {"instance_id": id}, {"black": 12, "redeem_cost": 16, "destination": "pledged", "item": item.duplicate(true)}, "pawn_already_used" if global.get("pawn_used", false) else ""))
				elif event == "trader":
					var price := _trade_price(item)
					if not price.is_empty():
						options.append(_option("sell", 0, {"instance_id": id}, {"currency": price.currency, "amount": price.amount, "item": item.duplicate(true)}, "no_effect" if int(price.amount) <= 0 else ""))
	for option: Dictionary in options:
		if bool(state.get("completed", false)):
			option.reason = "room_complete"
		elif str(option.reason).is_empty() and int(option.fee_black) > context.asset_ledger.get_currency(&"black_coin"):
			option.reason = "insufficient_black"
		option.enabled = str(option.reason).is_empty()
	return options


static func _find_option(options: Array, id: String, payload: Dictionary) -> Dictionary:
	for option: Dictionary in options:
		if str(option.option_id) != id:
			continue
		var matches := true
		for key: Variant in option.params:
			var value: Variant = payload.get(key, null)
			if typeof(value) != typeof(option.params[key]) or value != option.params[key]:
				matches = false
		if matches:
			return option.duplicate(true)
	return {}


static func _tier(item: Dictionary) -> int:
	return int(item.get("collectible_level", item.get("tier", 0)))


static func _normal_collectible(item: Dictionary) -> bool:
	return str(item.get("item_type", "")) == "collectible" and str(item.get("main_type", "collectible")) == "collectible" and _tier(item) in [1, 2, 3, 4, 5, 6] and not bool(item.get("is_unique", false)) and str(item.get("rarity", "")) != "unique" and not bool(item.get("visual_only", false)) and int(item.get("weight", -1)) >= 0 and int(item.get("base_value", -1)) >= 0


static func _trade_price(item: Dictionary) -> Dictionary:
	if bool(item.get("is_unique", false)) or str(item.get("rarity", "")) == "unique" or bool(item.get("visual_only", false)):
		return {}
	var type := str(item.get("item_type", ""))
	if type in ["equipment", "consumable"]:
		# T08 records activations in instance counters. Returning an equipped,
		# consumed, or previously used supply must never manufacture a refund.
		var counters: Dictionary = item.get("counters", {})
		if bool(item.get("used", false)) or int(item.get("use_count", 0)) > 0 or int(counters.get("uses", 0)) > 0:
			return {}
		var id := str(item.get("item_id", ""))
		var price := int(item.get("purchase_price", -1))
		if price < 0:
			return {}
		return {"currency": "black_coin", "amount": 3 if id == "con_ration" else (6 if id == "con_med_patch" else floori(price * 0.3))}
	if type in ["collectible", "material"] and bool(item.get("can_sell", false)) and int(item.get("base_value", -1)) >= 0:
		return {"currency": "gold_coin", "amount": floori(float(item.base_value) * 0.75)}
	return {}


static func _owned(context: RunContext, id: Variant) -> Dictionary:
	if not id is String or str(id).is_empty():
		return {}
	var item: Dictionary = context.asset_ledger.item_instances.get(id, {})
	if str(item.get("location_state", "")) != "inventory":
		return {}
	return item


static func _grant(context: RunContext, pos: Vector2i, event: String, item: Dictionary) -> Dictionary:
	if item.is_empty() or item.has("instance_id") or bool(item.get("is_unique", false)) or str(item.get("rarity", "")) == "unique":
		return _fail("invalid_reward")
	var definition := item.duplicate(true)
	definition["reward_location"] = &"inventory"
	var result := context.asset_ledger.add_reward_items([definition], &"inventory", pos, "z2_economy_" + event, {"origin_run_id": str(context.run_id)})
	if not result.get("ok", false):
		return result
	var delivered: Array = result.get("inventory_items", []) + result.get("ground_items", [])
	if delivered.size() != 1 or delivered[0].is_empty():
		return _fail("reward_not_delivered")
	return {"ok": true, "delivery": delivered[0], "on_floor": not result.get("ground_items", []).is_empty()}


static func _execute(context: RunContext, pos: Vector2i, event: String, state: Dictionary, option: Dictionary, payload: Dictionary, catalog: Dictionary) -> Dictionary:
	var action := str(option.option_id)
	var reward: Dictionary = option.reward
	var ledger: RunAssetLedger = context.asset_ledger
	var global := _global(context)
	var facts := {"black_income_gross": 0, "safe_income_gross": 0}
	var refresh_pool: Array = []
	var input_ids: Array = []
	# Preflight all selected ownership, materials and mandatory output pools before fees.
	if event == "shop" and action == "refresh":
		var pool := _pool(context, event, catalog)
		if not pool.ok:
			return pool
		refresh_pool = pool.items
	if event == "compress":
		if not payload.get("instance_ids", null) is Array:
			return _fail("invalid_compression_inputs")
		input_ids = payload.instance_ids
		if input_ids.size() != 2 or input_ids[0] == input_ids[1]:
			return _fail("invalid_compression_inputs")
		for id: Variant in input_ids:
			var item := _owned(context, id)
			if not _normal_collectible(item) or _tier(item) != 1:
				return _fail("invalid_compression_inputs")
	if event in ["consign", "trader", "pawn"] and _owned(context, option.params.instance_id).is_empty():
		return _fail("item_not_in_inventory")
	var fee := int(option.fee_black)
	if fee > 0:
		var spent := ledger.spend_currency(&"black_coin", fee, "z2_economy_" + event)
		if not spent.get("ok", false):
			return _fail("insufficient_black")
	match event:
		"shop":
			if action == "refresh":
				state.refresh_count = int(state.refresh_count) + 1
				state.offers = _draw_offers(context, pos, refresh_pool, state.refresh_count)
				facts["refresh_count"] = state.refresh_count
			else:
				var grant := _grant(context, pos, event, reward.item)
				if not grant.ok:
					return grant
				state.offers[int(option.params.slot)].sold = true
				facts["delivery"] = grant.delivery
				facts["on_floor"] = grant.on_floor
		"savings":
			if action == "deposit":
				var amount := int(option.params.amount)
				var guarantee := int(reward.safe_guarantee)
				var sequence := int(global.get("savings_sequence", 0)) + 1
				global["savings_sequence"] = sequence
				global["savings_pending"] = {"deposit_id": "%s:savings:%d" % [str(context.run_id), sequence],
					"room_key": context.cell_key(pos), "principal": amount, "guarantee": guarantee, "withdrawal": int(reward.withdrawal)}
				ledger.add_currency(&"gold_coin", guarantee, "z2_savings_guarantee")
				facts["deposit"] = global.savings_pending.duplicate(true)
				facts["safe_income_gross"] = guarantee
			else:
				var pending: Dictionary = global.savings_pending
				var revoked := ledger.spend_currency(&"gold_coin", int(pending.guarantee), "z2_savings_revoke_guarantee")
				if not revoked.get("ok", false):
					return _fail("guarantee_unavailable")
				var amount := int(pending.withdrawal)
				ledger.add_currency(&"black_coin", amount, "z2_savings_withdrawal")
				facts["deposit"] = pending.duplicate(true)
				facts["black_income_gross"] = amount
				facts["interest"] = amount - int(pending.principal)
				facts["revoked_safe"] = int(pending.guarantee)
				global.erase("savings_pending")
			context.z1_event_flags[EVACUATION_SERVICE_FLAG] = true
		"seal":
			ledger.failure_salvage_capacity += 20
			context.z1_event_flags[SEAL_USED_FLAG] = true
			var effect := {"id": "z2_salvage_seal", "weight_reduction": 10, "min_weight": 1,
				"target": "heaviest_selected_normal_collectible", "endings": ["failure", "abandon"], "capacity_already_added": 20}
			ledger.status_effects.append(effect)
			facts["salvage_rule"] = effect.duplicate(true)
			facts["item_id"] = "con_salvage_seal"
		"relief":
			var resolved := Effects.apply_pressure_packet(context, {"amount": -int(reward.pressure_reduction), "source_id": "z2_economy_relief"})
			if not resolved.get("ok", false):
				return resolved
			if int(resolved.facts.actual_pressure_delta) >= 0:
				return _fail("no_effect")
			facts["pressure"] = resolved.facts
		"first_aid":
			if int(reward.base_pressure) > 0:
				var resolved := Effects.apply_pressure_packet(context, {"amount": int(reward.base_pressure), "source_id": "z2_economy_first_aid", "reason": "event_first_aid"})
				if not resolved.get("ok", false):
					return resolved
				facts["pressure"] = resolved.facts
			var grant := _grant(context, pos, event, reward.item)
			if not grant.ok:
				return grant
			facts["delivery"] = grant.delivery
			facts["on_floor"] = grant.on_floor
		"consign", "pawn", "trader":
			var id := str(option.params.instance_id)
			var destination := "consigned" if event == "consign" else ("pledged" if event == "pawn" else "consumed")
			var transferred := ledger.transfer_event_items([id], StringName(destination))
			if not transferred.get("ok", false):
				return transferred
			facts["instance_id"] = id
			facts["destination"] = destination
			facts["item"] = reward.item.duplicate(true)
			if event == "consign":
				context.z1_event_flags[EVACUATION_SERVICE_FLAG] = true
			elif event == "pawn":
				global["pawn_used"] = true
				global["pawn"] = {"instance_id": id, "room_key": context.cell_key(pos), "advance": 12, "redeem_cost": 16}
				ledger.add_currency(&"black_coin", 12, "z2_pawn_advance")
				facts["black_income_gross"] = 12
				facts["redeem_cost"] = 16
			else:
				ledger.add_currency(StringName(reward.currency), int(reward.amount), "z2_trader_sale")
				facts["black_income_gross" if str(reward.currency) == "black_coin" else "safe_income_gross"] = int(reward.amount)
		"expand":
			ledger.backpack_capacity += 20
			facts["loot_capacity_delta"] = 20
		"compress":
			var transferred := ledger.transfer_event_items(input_ids, &"consumed")
			if not transferred.get("ok", false):
				return transferred
			var grant := _grant(context, pos, event, reward.item)
			if not grant.ok:
				return grant
			facts["consumed_instance_ids"] = input_ids.duplicate()
			facts["delivery"] = grant.delivery
			facts["on_floor"] = grant.on_floor
	context.z1_event_flags["z2_economy"] = global
	return {"ok": true, "facts": facts}
