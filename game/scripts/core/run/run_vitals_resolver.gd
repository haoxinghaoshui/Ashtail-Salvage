extends RefCounted
class_name RunVitalsResolver

const Balance := preload("res://scripts/core/run/run_balance_catalog.gd")
const Z2Talents := preload("res://scripts/core/progression/z2_talent_runtime.gd")


static func resolve_damage(state: Dictionary, packet: Dictionary) -> Dictionary:
	if not _valid_state(state):
		return _reject(state, "invalid_state")
	if not _valid_damage(packet):
		return _reject(state, "invalid_packet")
	packet = Z2Talents.damage_packet(state, packet)
	var next := _copy_state(state)
	var kind := str(packet.get("damage_type", "physical"))
	var amount := float(packet.amount)
	var spent: Dictionary = {}
	var facts := {"source_id": str(packet.get("source_id", "")), "damage_type": kind,
		"requested": amount, "resolved_damage": 0, "actual_hp_loss": 0, "hp_delta": 0,
		"max_hp_delta": 0, "absorbed": 0, "shield_added": 0, "paid": 0,
		"survival_source": "", "consumed_counters": spent, "dead": int(next.hp) == 0}
	if kind in ["hp_payment", "max_hp_payment"]:
		var cost := int(amount)
		if kind == "hp_payment":
			if int(next.hp) - cost < 1:
				return _reject(state, "insufficient_hp")
			next.hp = int(next.hp) - cost
		else:
			if int(next.max_hp) - cost < 1 or int(next.hp) < 1:
				return _reject(state, "insufficient_max_hp")
			next.max_hp = int(next.max_hp) - cost
			next.hp = mini(int(next.hp), int(next.max_hp))
			facts.max_hp_delta = -cost
		facts.paid = cost
		facts.hp_delta = int(next.hp) - int(state.hp)
		facts.actual_hp_loss = -int(facts.hp_delta)
		return _success(next, facts)
	if int(next.hp) == 0:
		return _success(next, facts)
	var modifiers: Array[Dictionary] = []
	if kind == "physical":
		var projected_shield := int(next.shield)
		var prediction_bell: Dictionary = packet.get("blackbell", {})
		if amount > 0.0 and bool(prediction_bell.get("eligible", false)) and _available(next, prediction_bell, true):
			projected_shield = maxi(projected_shield, 40)
		var loss_budget := int(next.hp) + projected_shield
		modifiers.append_array(_modifiers(next, packet, "percent_reductions", "percent"))
		modifiers.append_array(_modifiers(next, packet, "minimum_blocks", "minimum"))
		modifiers.append_array(_modifiers(next, packet, "flat_blocks", "flat"))
		# Drop redundant limited sources from the end, preserving stable source priority.
		for index in range(modifiers.size() - 1, -1, -1):
			if str(modifiers[index].get("counter_key", "")) == "":
				continue
			var without := modifiers.duplicate()
			without.remove_at(index)
			if mini(loss_budget, _physical_damage(amount, without)) == mini(loss_budget, _physical_damage(amount, modifiers)):
				modifiers.remove_at(index)
		for modifier in modifiers:
			_consume(next, modifier, spent)
	var damage := _physical_damage(amount, modifiers) if kind == "physical" else maxi(0, floori(amount))
	facts.resolved_damage = damage
	if kind in ["physical", "mine"]:
		var bell: Dictionary = packet.get("blackbell", {})
		if damage > 0 and bool(bell.get("eligible", false)) and int(next.shield) < 40 and _available(next, bell, true):
			facts.shield_added = 40 - int(next.shield)
			next.shield = 40
			_consume(next, bell, spent)
		facts.absorbed = mini(int(next.shield), damage)
		next.shield = int(next.shield) - int(facts.absorbed)
	var hp_damage := damage - int(facts.absorbed)
	var hp_after := maxi(0, int(next.hp) - hp_damage)
	if hp_after == 0:
		# A single talent wins before a single item, regardless of packet list order.
		for priority in ["talent", "item"]:
			for survival in packet.get("survivals", []):
				if str(survival.kind) == priority and _available(next, survival, true):
					hp_after = mini(int(next.max_hp), int(survival.get("hp", 1)))
					facts.survival_source = str(survival.source_id)
					_consume(next, survival, spent)
					break
			if hp_after > 0:
				break
	next.hp = hp_after
	facts.hp_delta = hp_after - int(state.hp)
	facts.actual_hp_loss = maxi(0, -int(facts.hp_delta))
	facts.dead = hp_after == 0
	return _success(next, facts)


static func resolve_heal(state: Dictionary, packet: Dictionary) -> Dictionary:
	if not _valid_state(state):
		return _reject(state, "invalid_state")
	if not _nonnegative(packet.get("amount")):
		return _reject(state, "invalid_packet")
	for key in ["base_multiplier", "bonus_rate", "flat_bonus", "reduction_multiplier"]:
		if packet.has(key) and not _nonnegative(packet[key]):
			return _reject(state, "invalid_packet")
	packet = Z2Talents.heal_packet(state, packet)
	var next := _copy_state(state)
	# Battery and talent read the same base; reductions follow every bonus.
	var boosted := float(packet.amount) * (float(packet.get("base_multiplier", 1.0)) + float(packet.get("bonus_rate", 0.0))) + float(packet.get("flat_bonus", 0.0))
	var resolved := maxi(0, floori(boosted * float(packet.get("reduction_multiplier", 1.0))))
	var actual := mini(resolved, int(next.max_hp) - int(next.hp)) if int(next.hp) > 0 else 0
	next.hp = int(next.hp) + actual
	return _success(next, {"source_id": str(packet.get("source_id", "")), "requested": packet.amount,
		"resolved_heal": resolved, "actual_heal": actual, "hp_delta": actual})


static func resolve_pressure(state: Dictionary, packet: Dictionary) -> Dictionary:
	if not _valid_state(state):
		return _reject(state, "invalid_state")
	if not _number(packet.get("amount")) or not _number(packet.get("replacement_amount", packet.get("amount"))):
		return _reject(state, "invalid_packet")
	if not _valid_modifiers(packet.get("percent_reductions", []), "rate") or not _valid_modifiers(packet.get("flat_reductions", []), "amount"):
		return _reject(state, "invalid_packet")
	if not _nonnegative(packet.get("extra", 0)) or not _valid_counter_entry(packet.get("waiver", {})):
		return _reject(state, "invalid_packet")
	packet = Z2Talents.pressure_packet(state, packet)
	var pressure_cap := Z2Talents.pressure_cap(state)
	var next := _copy_state(state)
	var original := float(packet.get("replacement_amount", packet.amount))
	var adjusted := floori(original)
	var spent: Dictionary = {}
	var waived := false
	if original > 0.0:
		var modifiers := _modifiers(next, packet, "percent_reductions", "percent")
		modifiers.append_array(_modifiers(next, packet, "flat_reductions", "flat"))
		var extra := float(packet.get("extra", 0))
		var waiver: Dictionary = packet.get("waiver", {})
		var can_waive := _available(next, waiver, true) and int(next.pressure) < 100
		for index in range(modifiers.size() - 1, -1, -1):
			if str(modifiers[index].get("counter_key", "")) == "":
				continue
			var with_delta := _pressure_amount(original, modifiers, extra, pressure_cap)
			var without := modifiers.duplicate()
			without.remove_at(index)
			var without_delta := _pressure_amount(original, without, extra, pressure_cap)
			var redundant := mini(with_delta, 100 - int(next.pressure)) == mini(without_delta, 100 - int(next.pressure))
			if can_waive and with_delta >= 10 and without_delta >= 10:
				redundant = true
			if redundant:
				modifiers.remove_at(index)
		adjusted = _pressure_amount(original, modifiers, extra, pressure_cap)
		for modifier in modifiers:
			_consume(next, modifier, spent)
		if can_waive and adjusted >= 10:
			waived = true
			_consume(next, waiver, spent)
	var actual := clampi(int(next.pressure) + (0 if waived else adjusted), 0, 100) - int(next.pressure)
	next.pressure = int(next.pressure) + actual
	next.protocol_level = Balance.protocol_level_for_pressure(int(next.pressure))
	return _success(next, {"source_id": str(packet.get("source_id", "")), "requested": packet.amount,
		"replaced": original, "adjusted": adjusted, "actual_pressure_delta": actual, "waived": waived,
		"consumed_counters": spent, "protocol_level": next.protocol_level})


static func _physical_damage(amount: float, modifiers: Array) -> int:
	if amount <= 0.0:
		return 0
	var remaining := amount
	var minimum_block := 0.0
	var flat_block := 0.0
	for modifier in modifiers:
		match str(modifier.kind):
			"percent":
				remaining *= 1.0 - float(modifier.rate)
			"minimum":
				minimum_block = maxf(minimum_block, float(modifier.amount))
			"flat":
				flat_block += float(modifier.amount)
	return maxi(1, floori(minf(remaining, amount - minimum_block) - flat_block))


static func _pressure_amount(amount: float, modifiers: Array, extra: float, cap: int) -> int:
	var remaining := amount
	for modifier in modifiers:
		if str(modifier.kind) == "percent":
			remaining -= amount * float(modifier.rate)
		else:
			remaining -= float(modifier.amount)
	if remaining <= 0.0:
		return 0
	var adjusted := maxi(0, floori(remaining + extra))
	return mini(cap, adjusted) if cap >= 0 else adjusted


static func _modifiers(state: Dictionary, packet: Dictionary, key: String, kind: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for entry in packet.get(key, []):
		if _available(state, entry):
			var modifier: Dictionary = entry.duplicate(true)
			modifier.kind = kind
			result.append(modifier)
	return result


static func _available(state: Dictionary, entry: Dictionary, require_counter: bool = false) -> bool:
	var key := str(entry.get("counter_key", ""))
	return not require_counter if key == "" else int(state.get("counters", {}).get(key, 0)) > 0


static func _consume(state: Dictionary, entry: Dictionary, spent: Dictionary) -> void:
	var key := str(entry.get("counter_key", ""))
	if key != "" and not spent.has(key):
		state.counters[key] = int(state.counters[key]) - 1
		spent[key] = 1


static func _valid_state(state: Dictionary) -> bool:
	if not _integer(state.get("hp")) or not _integer(state.get("max_hp")):
		return false
	if int(state.max_hp) < 1 or int(state.hp) < 0 or int(state.hp) > int(state.max_hp):
		return false
	if not _integer(state.get("shield", 0)) or float(state.get("shield", 0)) < 0.0:
		return false
	if not _integer(state.get("pressure", 0)) or float(state.get("pressure", 0)) < 0.0 or float(state.get("pressure", 0)) > 100.0:
		return false
	if not state.get("counters", {}) is Dictionary or not state.get("statuses", []) is Array:
		return false
	for key in state.get("counters", {}):
		if not _integer(state.counters[key]) or float(state.counters[key]) < 0.0:
			return false
	return true


static func _valid_damage(packet: Dictionary) -> bool:
	if not _nonnegative(packet.get("amount")):
		return false
	var kind := str(packet.get("damage_type", "physical"))
	if not kind in ["physical", "mine", "dot", "hp_payment", "max_hp_payment"]:
		return false
	if kind in ["hp_payment", "max_hp_payment"] and not _integer(packet.amount):
		return false
	if not _valid_modifiers(packet.get("percent_reductions", []), "rate"):
		return false
	for key in ["minimum_blocks", "flat_blocks"]:
		if not _valid_modifiers(packet.get(key, []), "amount"):
			return false
	if not _valid_counter_entry(packet.get("blackbell", {})) or not packet.get("survivals", []) is Array:
		return false
	for survival in packet.get("survivals", []):
		if not _valid_counter_entry(survival):
			return false
		if str(survival.get("source_id", "")) == "" or not str(survival.get("kind", "")) in ["talent", "item"]:
			return false
		if not _integer(survival.get("hp", 1)) or float(survival.get("hp", 1)) < 1.0:
			return false
	return true


static func _valid_modifiers(value: Variant, field: String) -> bool:
	if not value is Array:
		return false
	for entry in value:
		if not _valid_counter_entry(entry) or not _nonnegative(entry.get(field)):
			return false
		if field == "rate" and float(entry.rate) > 1.0:
			return false
	return true


static func _valid_counter_entry(value: Variant) -> bool:
	return value is Dictionary and (value.get("counter_key", "") is String or value.get("counter_key", "") is StringName)


static func _number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))


static func _nonnegative(value: Variant) -> bool:
	return _number(value) and float(value) >= 0.0


static func _integer(value: Variant) -> bool:
	return _number(value) and float(value) == floor(float(value))


static func _copy_state(state: Dictionary) -> Dictionary:
	var result := state.duplicate(true)
	result.shield = int(state.get("shield", 0))
	result.pressure = int(state.get("pressure", 0))
	result.counters = state.get("counters", {}).duplicate(true)
	result.statuses = state.get("statuses", []).duplicate(true)
	return result


static func _reject(state: Dictionary, reason: String) -> Dictionary:
	return {"ok": false, "state": state.duplicate(true), "facts": {}, "reason": reason}


static func _success(state: Dictionary, facts: Dictionary) -> Dictionary:
	return {"ok": true, "state": state, "facts": facts, "reason": ""}
