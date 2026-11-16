extends RefCounted
class_name Z2SupplyRuntime

const Items := preload("res://scripts/core/content/z2_item_catalog.gd")
const Effects := preload("res://scripts/core/run/run_effect_applier.gd")
const Vitals := preload("res://scripts/core/run/run_vitals_resolver.gd")
const Statuses := preload("res://scripts/core/run/run_status_service.gd")
const Snapshot := preload("res://scripts/core/run/run_state_snapshot.gd")
const KEY := "z2_supply_runtime"
const PREFIX := "z2_supply:"
const DIRECTIONS := [Vector2i.UP, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT]
const DIAGONALS := [Vector2i(-1, -1), Vector2i(1, -1), Vector2i(1, 1), Vector2i(-1, 1)]

# Only operates on the parent's candidate RunContext. No save, inventory removal,
# random draw, scene access or legacy-rule installation happens here.
static func evaluate_consumable(run: RunContext, item: Dictionary) -> Dictionary:
	if not _usable(run):
		return _reject("no_active_run")
	var candidate := RunContext.new()
	Snapshot.install_context(candidate, Snapshot.capture_context(run))
	return apply_consumable(candidate, item)


static func apply_consumable(run: RunContext, item: Dictionary) -> Dictionary:
	if not _usable(run) or run.asset_ledger == null:
		return _reject("no_active_run")
	if not _valid_item(item, "consumable"):
		return _reject("invalid_supply_instance")
	var before := Snapshot.capture_context(run)
	var resources := _resources(run)
	var result := _consume(run, item)
	if not bool(result.ok):
		Snapshot.install_context(run, before)
		return result
	result["consume_instance_id"] = str(item.instance_id)
	result["preview"] = {"before": resources, "after": _resources(run)}
	return result


static func equipment_parameters(equipped: Array) -> Dictionary:
	var result := {"ok": true, "reason": "", "max_hp": 0, "power": 0, "backpack_capacity": 0,
		"salvage_capacity": 0, "scan_diagonals": 0, "departure_shield": 0}
	var ids := {}
	var slots := {}
	for item: Variant in equipped:
		if not item is Dictionary or not _valid_item(item, "equipment"):
			return _reject("invalid_equipment_instance")
		var slot := str(item.equipment_slot)
		if ids.has(item.instance_id) or slots.has(slot) or slot.is_empty():
			return _reject("duplicate_equipment_or_slot")
		ids[item.instance_id] = true
		slots[slot] = true
		var params: Dictionary = item.effect_params
		match str(item.effect_kind):
			"max_hp": result.max_hp += int(item.effect_amount)
			"combat_power": result.power += int(item.effect_amount)
			"backpack_capacity": result.backpack_capacity += int(item.effect_amount)
			"salvage_capacity": result.salvage_capacity += int(item.effect_amount)
			"scan_diagonal_reveal": result.scan_diagonals += int(item.effect_amount)
		result.max_hp += int(params.get("max_hp_delta", 0))
		result.backpack_capacity += int(params.get("backpack_capacity_delta", 0))
		result.departure_shield += int(params.get("departure_shield", 0))
	return result


static func apply_equipment_change(run: RunContext, before: Array, after: Array) -> Dictionary:
	if not _usable(run) or run.asset_ledger == null:
		return _reject("no_active_run")
	if bool(_state(run).combat_active):
		return _reject("equipment_locked_in_combat")
	var old := equipment_parameters(before)
	var next := equipment_parameters(after)
	if not bool(old.ok) or not bool(next.ok):
		return _reject("invalid_equipment_set")
	if _equipment_ids(before) != _equipment_ids(_state(run).equipped):
		return _reject("stale_equipment_before")
	var capacity := run.asset_ledger.backpack_capacity + int(next.backpack_capacity) - int(old.backpack_capacity)
	if capacity < run.asset_ledger.get_backpack_used():
		return _reject("loot_capacity_exceeded")
	# Same-slot changes are aggregated once; preserve below-floor debt like RunInventory.
	var raw_hp := run.max_hp - run.max_hp_equipment_floor_debt + int(next.max_hp) - int(old.max_hp)
	run.max_hp = maxi(1, raw_hp)
	run.max_hp_equipment_floor_debt = maxi(0, 1 - raw_hp)
	run.hp = mini(run.hp, run.max_hp)
	run.power += int(next.power) - int(old.power)
	run.asset_ledger.backpack_capacity = capacity
	run.asset_ledger.failure_salvage_capacity += _salvage_equipment_bonus(run, after) - _salvage_equipment_bonus(run, before)
	var state := _ensure(run)
	state.equipped = after.duplicate(true)
	_register_equipment(run, after)
	return _ok()


static func on_departure(run: RunContext, equipped: Array) -> Dictionary:
	if not _usable(run) or not bool(equipment_parameters(equipped).ok):
		return _reject("invalid_departure")
	var state := _ensure(run)
	if bool(state.departure_done):
		return _ok({"shield_added": 0})
	_register_equipment(run, equipped)
	state.equipped = equipped.duplicate(true)
	state.departure_done = true
	var added := int(equipment_parameters(equipped).departure_shield)
	run.shield += added
	return _ok({"shield_added": added})


# kind: damage/pressure/heal use packet; ordinary_clear uses room_id+actual;
# event_stage uses event_id+valid+noncombat; search_completed/chest_opened use
# room_id+new_output_base_value; random_reward_event uses room_id+ordinary_random+noncombat
# +extra_item already selected by the parent from the eligible origin pool.
static func on_event(run: RunContext, equipped: Array, event: Dictionary) -> Dictionary:
	if run == null:
		return _reject("no_active_run")
	var kind := str(event.get("kind", ""))
	if kind == "offline":
		return _ok()
	if kind in ["combat_ended", "retreat"]:
		_ensure(run).combat_active = false
		return _advance_statuses(run, 0.0, {"kind": kind})
	if not _usable(run) or not bool(equipment_parameters(equipped).ok):
		return _reject("invalid_run_or_equipment")
	match kind:
		"combat_started":
			if not bool(event.get("actual", false)):
				return _ok()
			_ensure(run).combat_active = true
			return _advance_statuses(run, 0.0, {"kind": "combat_started"})
		"first_attack":
			if bool(event.get("actual", false)) and bool(_state(run).combat_active):
				return _advance_statuses(run, 0.0, {"kind": "first_attack"})
			return _ok()
		"damage": return _damage(run, equipped, event.get("packet", {}))
		"pressure": return _pressure(run, equipped, event.get("packet", {}))
		"heal": return _heal(run, event.get("packet", {}))
		"basic_scan":
			return _scan(run, equipped, false)
		"ordinary_clear", "event_stage", "search_completed", "chest_opened", "random_reward_event":
			return _equipment_event(run, equipped, event)
	return _reject("unknown_supply_event")


static func advance_time(run: RunContext, delta: float) -> Dictionary:
	if not _usable(run):
		return _reject("no_active_run")
	return _advance_statuses(run, delta, {})


static func attack_power(run: RunContext, base_power: int) -> int:
	return floori(float(base_power) * 1.25) if not _status(run, "con_countdown_pill", true).is_empty() else base_power


static func equipped_items(run: RunContext) -> Array:
	return _state(run).equipped.duplicate(true)


static func salvage_weights(run: RunContext, selected: Array) -> Dictionary:
	var weights := {}
	var heaviest := ""
	var largest := -1
	for item: Dictionary in selected:
		var id := str(item.get("instance_id", ""))
		weights[id] = maxi(1, int(item.get("weight", 1)))
		if str(item.get("item_type", "")) == "collectible" and not bool(item.get("is_unique", false)) and int(weights[id]) > largest:
			largest = int(weights[id])
			heaviest = id
	if bool(_state(run).salvage_seal) and not heaviest.is_empty():
		weights[heaviest] = maxi(1, int(weights[heaviest]) - 10)
	var total := 0
	for weight in weights.values():
		total += int(weight)
	return {"weights": weights, "total_weight": total, "reduced_instance_id": heaviest if bool(_state(run).salvage_seal) else ""}


static func snapshot(run: RunContext) -> Dictionary:
	var counters := {}
	var statuses: Array = []
	for key in run.vitals_counters:
		if str(key).begins_with(PREFIX):
			counters[key] = run.vitals_counters[key]
	for status: Dictionary in run.temporary_statuses:
		if str(status.get("id", "")).begins_with(PREFIX):
			statuses.append(status.duplicate(true))
	return {"state": _state(run).duplicate(true), "counters": counters, "statuses": statuses}


static func restore(run: RunContext, saved: Dictionary) -> void:
	# The enclosing checkpoint validator owns untrusted-save validation.
	run.z1_event_flags[KEY] = saved.get("state", _new_state()).duplicate(true)
	for key in run.vitals_counters.keys():
		if str(key).begins_with(PREFIX):
			run.vitals_counters.erase(key)
	run.vitals_counters.merge(saved.get("counters", {}).duplicate(true), true)
	var other: Array = run.temporary_statuses.filter(func(s: Dictionary) -> bool: return not str(s.get("id", "")).begins_with(PREFIX))
	other.append_array(saved.get("statuses", []).duplicate(true))
	run.temporary_statuses = other


static func _consume(run: RunContext, item: Dictionary) -> Dictionary:
	var state := _ensure(run)
	var id := str(item.item_id)
	var iid := str(item.instance_id)
	var params: Dictionary = item.effect_params
	if state.consumed.has(iid):
		return _reject("instance_already_consumed")
	if int(params.get("max_uses", 0)) > 0 and int(state.uses.get(id, 0)) >= int(params.max_uses):
		return _reject("run_use_limit")
	if bool(params.get("nonstacking", false)) and not _status(run, id).is_empty():
		return _reject("same_status_active")
	var battery := not _status(run, "con_red_battery").is_empty()
	var multiplier := 2 if battery else 1
	var used_battery := false
	var amount := int(item.effect_amount)
	var result := _ok()
	match str(item.effect_kind):
		"heal", "heal_below_half":
			if run.hp >= run.max_hp or (str(item.effect_kind) == "heal_below_half" and run.hp * 2 >= run.max_hp):
				return _reject("healing_condition_not_met")
			result = _heal(run, {"amount": amount, "base_multiplier": multiplier, "source_id": iid})
			if not bool(result.ok) or int(result.get("facts", {}).get("actual_heal", 0)) <= 0:
				return _reject("no_actual_healing")
			used_battery = battery
		"physical_reduction_once":
			_add_status(run, item, {"reduction": amount})
			run.vitals_counters[_counter(iid)] = 1
		"reveal_two_away":
			result = _scan(run, state.equipped, true)
		"basic_scan":
			result = _scan(run, state.equipped, false)
		"shield":
			run.shield += amount * multiplier
			used_battery = battery
		"pressure_reduce":
			result = _pressure(run, state.equipped, {"amount": -amount * multiplier, "source_id": iid})
			if bool(result.ok):
				_add_status(run, item, {"reduction": int(params.next_pressure_reduction) * multiplier})
				run.vitals_counters[_counter(iid)] = int(params.max_hits)
				used_battery = battery
		"black_to_safe_gold_percent":
			var cost := mini(int(params.max_black_currency), run.asset_ledger.get_currency(&"black_coin"))
			var gold := floori(float(cost * amount) / 100.0)
			if gold < 1:
				return _reject("no_exchange_gain")
			result = Effects.apply_effects(run, [Effects.effect(Effects.EFFECT_PENDING_GOLD_DELTA, iid, {"amount": -cost}), Effects.effect(Effects.EFFECT_SAFE_GOLD_DELTA, iid, {"amount": gold})])
		"pressure_reduce_and_cleanse":
			var target := _cleanse_index(run)
			if run.pressure <= 0 and target < 0:
				return _reject("no_pressure_or_cleanse_benefit")
			result = _pressure(run, state.equipped, {"amount": -amount * multiplier, "source_id": iid})
			used_battery = battery and int(result.get("facts", {}).get("actual_pressure_delta", 0)) < 0
			if bool(result.ok) and target >= 0:
				run.temporary_statuses[target].phase = "ended"
		"shield_and_pressure_reduce":
			run.shield += amount * multiplier
			result = _pressure(run, state.equipped, {"amount": -int(params.pressure_reduction) * multiplier, "source_id": iid})
			used_battery = battery
		"next_supply_base_bonus_percent":
			result = _pressure(run, state.equipped, {"amount": int(params.pressure_cost), "source_id": iid, "source_kind": "item_cost"})
			if bool(result.ok):
				_add_status(run, item, {})
		"salvage_capacity":
			run.asset_ledger.failure_salvage_capacity += amount
			state.salvage_seal = true
		"physical_damage_reduce_percent", "combat_power_percent":
			if id == "con_countdown_pill":
				if run.max_hp <= int(params.max_hp_cost):
					return _reject("insufficient_max_hp")
				result = Effects.apply_damage_packet(run, {"amount": int(params.max_hp_cost), "damage_type": "max_hp_payment", "source_id": iid})
				if not bool(result.ok):
					return result
			result = _pressure(run, state.equipped, {"amount": int(params.pressure_cost), "source_id": iid, "source_kind": "item_cost"})
			if bool(result.ok):
				var drug := {"phase": "active" if bool(state.combat_active) else "waiting", "remaining": float(params.duration_seconds),
					"start_trigger": "combat_started" if id == "con_waiver_medicine" else "first_attack", "clear_on": ["combat_ended", "retreat"], "paid_costs": {"pressure": int(params.pressure_cost)}}
				if id == "con_waiver_medicine":
					drug.hits_left = int(params.max_hits)
					drug.hit_trigger = "physical_hit"
				else:
					drug.paid_costs.max_hp = int(params.max_hp_cost)
					run.vitals_counters[_counter(iid)] = 1
				_add_status(run, item, drug)
		_:
			return _reject("unsupported_supply_effect")
	if not bool(result.ok):
		return result
	if used_battery:
		_end_status(run, "con_red_battery")
	state.consumed[iid] = true
	state.uses[id] = int(state.uses.get(id, 0)) + 1
	run.asset_ledger.sync_compat_fields(run)
	return _ok({"effects": [result]})


static func _damage(run: RunContext, equipped: Array, packet: Dictionary) -> Dictionary:
	var composed := _composed(run, "damage", packet)
	var kind := str(composed.get("damage_type", "physical"))
	var percentages: Array = composed.get("percent_reductions", []).duplicate(true)
	var minimums: Array = composed.get("minimum_blocks", []).duplicate(true)
	var flats: Array = composed.get("flat_blocks", []).duplicate(true)
	var mine_counter := ""
	for item: Dictionary in equipped:
		var key := _counter(str(item.instance_id))
		if not _available(run, key):
			continue
		if str(item.item_id) == "eq_debris_brow_guard":
			percentages.append({"rate": 0.10, "counter_key": key})
			minimums.append({"amount": 1, "counter_key": key})
		if str(item.item_id) == "eq_buffer_buckle" and kind == "mine" and float(composed.get("amount", 0)) > 0.0:
			mine_counter = key
	var tape := _status(run, "con_tape_roll", true)
	if not tape.is_empty():
		flats.append({"amount": int(tape.reduction), "counter_key": _counter(str(tape.source_id))})
	var waiver := _status(run, "con_waiver_medicine", true)
	if not waiver.is_empty():
		percentages.append({"rate": 0.5})
	composed.percent_reductions = percentages
	composed.minimum_blocks = minimums
	composed.flat_blocks = flats
	if not _status(run, "con_countdown_pill", true).is_empty() and kind in ["physical", "mine"]:
		var pill := _status(run, "con_countdown_pill", true)
		var survivals: Array = composed.get("survivals", []).duplicate(true)
		survivals.append({"kind": "item", "source_id": str(pill.source_id), "counter_key": _counter(str(pill.source_id)), "hp": 1})
		composed.survivals = survivals
	var original := composed.duplicate(true)
	if not mine_counter.is_empty():
		composed.amount = maxf(0.0, float(composed.amount) - 5.0)
	if kind in ["physical", "mine"]:
		var predicted := Vitals.resolve_damage(Effects.capture_vitals(run), composed)
		if not bool(predicted.ok):
			return predicted
		var predicted_hp := run.hp - maxi(0, int(predicted.facts.resolved_damage) - run.shield)
		for item: Dictionary in equipped:
			if str(item.item_id) == "eq_black_box_bell" and _available(run, _counter(str(item.instance_id))):
				composed.blackbell = {"eligible": predicted_hp * 100 < run.max_hp * 30, "counter_key": _counter(str(item.instance_id))}
	var before := Effects.capture_vitals(run)
	var result := Effects.apply_vitals_packet(run, composed, "damage")
	if not bool(result.ok):
		return result
	if not mine_counter.is_empty():
		var without := Vitals.resolve_damage(before, original)
		if bool(without.ok) and (int(without.state.hp) < run.hp or int(without.state.shield) < run.shield):
			_spend(run, mine_counter)
	for item: Dictionary in equipped:
		if str(item.item_id) == "eq_black_box_bell" and result.facts.get("consumed_counters", {}).has(_counter(str(item.instance_id))):
			_ensure(run).bell_triggered = true
	if not tape.is_empty() and not _available(run, _counter(str(tape.source_id))):
		_end_status(run, "con_tape_roll")
	if not waiver.is_empty() and kind == "physical" and float(packet.get("amount", 0)) > 0:
		_advance_statuses(run, 0.0, {"kind": "physical_hit"})
	return result


static func _pressure(run: RunContext, equipped: Array, packet: Dictionary) -> Dictionary:
	if not run.vitals_modifiers.get("pressure", {}) is Dictionary:
		return _reject("invalid_vitals_modifiers")
	var composed := _composed(run, "pressure", packet)
	var reductions: Array = composed.get("flat_reductions", []).duplicate(true)
	var amount := float(composed.get("replacement_amount", composed.get("amount", 0)))
	for item: Dictionary in equipped:
		var key := _counter(str(item.instance_id))
		if not _available(run, key):
			continue
		if str(item.item_id) == "eq_pressure_relief_wrench" and str(packet.get("source_kind", "")) in ["combat", "mechanism"]:
			reductions.append({"amount": 5, "counter_key": key})
		if str(item.item_id) == "eq_insulated_sleeve":
			# S4 floors the reduction, not the remainder. Delegate subtraction/caps to Vitals.
			var reduction := mini(10, floori(amount * 0.25))
			if reduction > 0:
				reductions.append({"amount": reduction, "counter_key": key})
	var candy := _status(run, "con_calm_candy", true)
	if not candy.is_empty():
		reductions.append({"amount": int(candy.reduction), "counter_key": _counter(str(candy.source_id))})
	composed.flat_reductions = reductions
	if bool(_state(run).bell_triggered):
		composed.extra = float(composed.get("extra", 0)) + 1.0
	# Use the final shared entry, never the public supply-routing entry again.
	var result := Effects.apply_vitals_packet(run, composed, "pressure")
	if bool(result.ok):
		if not candy.is_empty() and not _available(run, _counter(str(candy.source_id))):
			_end_status(run, "con_calm_candy")
	return result


static func _heal(run: RunContext, packet: Dictionary) -> Dictionary:
	var composed := packet.duplicate(true)
	if not _status(run, "con_waiver_medicine", true).is_empty():
		var inherited: Dictionary = run.vitals_modifiers.get("heal", {}) if run.vitals_modifiers.get("heal", {}) is Dictionary else {}
		composed.reduction_multiplier = float(composed.get("reduction_multiplier", inherited.get("reduction_multiplier", 1.0))) * 0.5
	return Effects.apply_vitals_packet(run, composed, "heal")


static func _equipment_event(run: RunContext, equipped: Array, event: Dictionary) -> Dictionary:
	var kind := str(event.kind)
	var state := _ensure(run)
	if bool(event.get("supply_extra", false)):
		return _ok()
	if kind == "ordinary_clear" and not bool(event.get("actual", false)):
		return _ok()
	if kind == "event_stage" and not (bool(event.get("valid", false)) and bool(event.get("noncombat", false))):
		return _ok()
	var token := str(event.get("event_id", "")) if kind == "event_stage" else str(event.get("room_id", ""))
	if token.is_empty():
		return _reject("missing_event_identity")
	var effects: Array = []
	for item: Dictionary in equipped:
		var id := str(item.item_id)
		var key := _counter(str(item.instance_id))
		var seen_key := key + ":" + kind + ":" + token
		if state.seen.has(seen_key) or (item.effect_params.has("max_uses") and not _available(run, key)):
			continue
		var benefited := false
		var applied := _ok()
		if kind == "ordinary_clear":
			match id:
				"eq_signal_pin":
					run.asset_ledger.failure_salvage_capacity += 5
					benefited = true
				"eq_strapped_backplate":
					run.shield += 6
					benefited = true
				"eq_folding_shovel":
					applied = _pressure(run, equipped, {"amount": 4, "source_id": str(item.instance_id), "source_kind": "combat"})
					benefited = bool(applied.ok)
		if kind == "event_stage" and id == "eq_etched_sleeve":
			run.shield += 5
			benefited = true
		if kind in ["search_completed", "chest_opened"] and id == "eq_seam_finder_pendant":
			var gain := floori(float(event.get("new_output_base_value", 0)) * 0.1)
			if gain > 0:
				applied = Effects.apply_effects(run, [Effects.effect(Effects.EFFECT_PENDING_GOLD_DELTA, id, {"amount": gain})])
				benefited = bool(applied.ok)
		if kind == "random_reward_event" and id == "eq_old_work_badge" and bool(event.get("ordinary_random", false)) and bool(event.get("noncombat", false)):
			var extra: Dictionary = event.get("extra_item", {}).duplicate(true)
			if not extra.is_empty() and str(extra.get("item_type", "")) in ["collectible", "equipment", "consumable"] and not bool(extra.get("is_unique", false)):
				extra.reward_location = &"inventory"
				extra.supply_extra = true
				applied = Effects.apply_effects(run, [Effects.effect(Effects.EFFECT_BACKPACK_ITEM_ADD, id, {"item_def": extra})])
				benefited = bool(applied.ok)
		if not bool(applied.ok):
			return applied
		if benefited:
			state.seen[seen_key] = true
			if item.effect_params.has("max_uses"):
				_spend(run, key)
			effects.append({"instance_id": item.instance_id, "kind": kind})
	return _ok({"effects": effects})


static func _scan(run: RunContext, equipped: Array, two_away: bool) -> Dictionary:
	if run.truth_map == null or run.intel_map == null:
		return _reject("no_map")
	var targets: Array[Vector2i] = []
	for delta: Vector2i in DIRECTIONS:
		var target := run.get_current_pos() + delta * (2 if two_away else 1)
		if _unknown(run, target):
			targets.append(target)
			if two_away:
				break
	if not two_away:
		var remaining := int(equipment_parameters(equipped).get("scan_diagonals", 0))
		for delta: Vector2i in DIAGONALS:
			var target := run.get_current_pos() + delta
			if remaining > 0 and _unknown(run, target):
				targets.append(target)
				remaining -= 1
	if targets.is_empty():
		return _reject("no_unknown_scan_target")
	for target in targets:
		run.intel_map.reveal_cell(target, run.truth_map)
	return _ok({"revealed": targets})


static func _advance_statuses(run: RunContext, delta: float, trigger: Dictionary) -> Dictionary:
	var owned: Array = []
	var other: Array = []
	for status: Dictionary in run.temporary_statuses:
		if str(status.get("id", "")).begins_with(PREFIX):
			owned.append(status)
		else:
			other.append(status)
	var result := Statuses.advance({"statuses": owned}, delta, trigger)
	if bool(result.ok):
		other.append_array(result.state.statuses)
		run.temporary_statuses = other
	return result


static func _add_status(run: RunContext, item: Dictionary, extra: Dictionary) -> void:
	var id := PREFIX + str(item.item_id)
	run.temporary_statuses = run.temporary_statuses.filter(func(s: Dictionary) -> bool: return str(s.get("id", "")) != id)
	var status := {"id": id, "source_id": str(item.instance_id), "item_id": str(item.item_id), "type": "temporary_buff",
		"temporary_type": id, "phase": "active", "elapsed": 0.0, "clear_on": [], "paid_costs": {}}
	status.merge(extra, true)
	run.temporary_statuses.append(status)


static func _status(run: RunContext, item_id: String, active_only: bool = false) -> Dictionary:
	for status: Dictionary in run.temporary_statuses:
		if str(status.get("id", "")) == PREFIX + item_id and str(status.get("phase", "ended")) != "ended":
			if not active_only or str(status.phase) == "active":
				return status
	return {}


static func _end_status(run: RunContext, item_id: String) -> void:
	var status := _status(run, item_id)
	if not status.is_empty():
		status.phase = "ended"


static func _cleanse_index(run: RunContext) -> int:
	for priority in ["poison", "bleeding", "other"]:
		for index in range(run.temporary_statuses.size()):
			var status: Dictionary = run.temporary_statuses[index]
			var kind := str(status.get("temporary_type", ""))
			if str(status.get("type", "")) != "temporary_debuff" or str(status.get("phase", "")) != "active":
				continue
			if not bool(status.get("cleanseable", kind in ["poison", "bleeding"])) or (float(status.get("remaining", 0)) <= 0.0 and float(status.get("dot_per_second", 0)) <= 0.0):
				continue
			if kind == priority or (priority == "other" and not kind in ["poison", "bleeding"]):
				return index
	return -1


static func _salvage_equipment_bonus(run: RunContext, equipped: Array) -> int:
	var bonus := int(equipment_parameters(equipped).get("salvage_capacity", 0))
	for item: Dictionary in equipped:
		if str(item.item_id) == "eq_signal_pin":
			bonus += (2 - int(run.vitals_counters.get(_counter(str(item.instance_id)), 2))) * 5
	return bonus


static func _register_equipment(run: RunContext, equipped: Array) -> void:
	for item: Dictionary in equipped:
		if item.effect_params.has("max_uses") and not run.vitals_counters.has(_counter(str(item.instance_id))):
			run.vitals_counters[_counter(str(item.instance_id))] = int(item.effect_params.max_uses)


static func _equipment_ids(equipped: Array) -> Array[String]:
	var result: Array[String] = []
	for item: Dictionary in equipped:
		result.append(str(item.instance_id) + ":" + str(item.item_id))
	result.sort()
	return result


static func _composed(run: RunContext, kind: String, packet: Dictionary) -> Dictionary:
	var base: Variant = run.vitals_modifiers.get(kind, {})
	var result: Dictionary = base.duplicate(true) if base is Dictionary else {}
	result.merge(packet.duplicate(true), true)
	return result


static func _valid_item(item: Dictionary, kind: String) -> bool:
	var amount: Variant = item.get("effect_amount")
	if not (amount is int or amount is float) or not is_finite(float(amount)) or float(amount) <= 0 or float(amount) != floor(float(amount)):
		return false
	var definition := Items.definition(str(item.get("item_id", "")))
	return not str(item.get("instance_id", "")).is_empty() and str(item.get("content_version", "")) == Items.CONTENT_VERSION and str(item.get("item_type", "")) == kind and item.get("effect_params") is Dictionary and str(definition.get("item_type", "")) == kind and str(item.get("effect_kind", "")) == str(definition.get("effect_kind", ""))


static func _unknown(run: RunContext, pos: Vector2i) -> bool:
	if not run.is_inside(pos):
		return false
	var cell := run.intel_map.get_cell_info(pos)
	return not bool(cell.get("revealed", false)) and not bool(cell.get("scanned", false))


static func _counter(instance_id: String) -> String:
	return PREFIX + instance_id


static func _available(run: RunContext, key: String) -> bool:
	return int(run.vitals_counters.get(key, 0)) > 0


static func _spend(run: RunContext, key: String) -> void:
	run.vitals_counters[key] = maxi(0, int(run.vitals_counters.get(key, 0)) - 1)


static func _usable(run: RunContext) -> bool:
	return run != null and run.run_active and not run.failed and not run.extracted and not run.abandoned and run.hp > 0


static func _new_state() -> Dictionary:
	return {"version": 1, "consumed": {}, "uses": {}, "seen": {}, "equipped": [], "departure_done": false, "combat_active": false, "bell_triggered": false, "salvage_seal": false}


static func _state(run: RunContext) -> Dictionary:
	return run.z1_event_flags.get(KEY, _new_state())


static func _ensure(run: RunContext) -> Dictionary:
	if not run.z1_event_flags.has(KEY):
		run.z1_event_flags[KEY] = _new_state()
	return run.z1_event_flags[KEY]


static func _resources(run: RunContext) -> Dictionary:
	return {"hp": run.hp, "max_hp": run.max_hp, "shield": run.shield, "pressure": run.pressure,
		"black_coin": run.asset_ledger.get_currency(&"black_coin"), "safe_gold": run.asset_ledger.get_currency(&"gold_coin"),
		"salvage_capacity": run.asset_ledger.failure_salvage_capacity}


static func _ok(extra: Dictionary = {}) -> Dictionary:
	var result := {"ok": true, "reason": "", "effects": []}
	result.merge(extra, true)
	return result


static func _reject(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason, "consume_instance_id": "", "effects": []}
