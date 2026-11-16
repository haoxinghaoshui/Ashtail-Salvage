extends RefCounted
class_name Z2TalentRuntime


static func run_profile(profile_fields: Dictionary, active_effects: Array, tutorial: bool = false) -> Dictionary:
	var enabled: bool = str(profile_fields.get("ruleset_id", "")) == "z2" and profile_fields.get("z2_progression_version") == 1
	var effects: Array[Dictionary] = []
	var seen := {}
	if enabled:
		for raw in active_effects:
			if not raw is Dictionary:
				continue
			var talent_id := str(raw.get("talent_id", ""))
			if not talent_id.begins_with("z2_talent_") or seen.has(talent_id) or (tutorial and talent_id != "z2_talent_01"):
				continue
			seen[talent_id] = true
			effects.append({"talent_id": talent_id, "effect_kind": str(raw.get("effect_kind", "")),
				"effect_amount": int(raw.get("effect_amount", 0)), "effect_params": raw.get("effect_params", {}).duplicate(true)})
	return {"enabled": enabled, "effects": effects}


static func from_context(context) -> Dictionary:
	return run_profile(context.profile_fields, context.active_talent_effects,
		context.mode == &"tutorial" or bool(context.run_start_config.get("tutorial_map", false)))


static func valid_profile(value: Variant) -> bool:
	if not value is Dictionary or not value.get("enabled") is bool or not value.get("effects") is Array:
		return false
	var seen := {}
	for effect in value.effects:
		if not effect is Dictionary or not effect.get("talent_id") is String or not effect.get("effect_kind") is String:
			return false
		if not effect.talent_id.begins_with("z2_talent_") or seen.has(effect.talent_id):
			return false
		if not effect.get("effect_amount") is int or effect.effect_amount < 0 or not effect.get("effect_params") is Dictionary:
			return false
		for parameter in effect.effect_params.values():
			if not (parameter is int or parameter is bool) or (parameter is int and parameter < 0):
				return false
		seen[effect.talent_id] = true
	return true


static func amount(profile: Dictionary, kind: String) -> int:
	var total := 0
	for effect in _effects(profile, kind):
		total += int(effect.effect_amount)
	return total


static func speed_multiplier(profile: Dictionary, kind: String) -> float:
	return 1.0 + maxf(0.0, float(amount(profile, kind))) / 100.0


static func damage_packet(state: Dictionary, packet: Dictionary) -> Dictionary:
	var profile := _vitals_profile(state)
	if not bool(profile.get("enabled", false)):
		return packet
	var result := packet.duplicate(true)
	var percentages: Array = result.get("percent_reductions", []).duplicate(true)
	var minimums: Array = result.get("minimum_blocks", []).duplicate(true)
	for effect in _effects(profile, "physical_damage_reduction_percent"):
		percentages.append({"source_id": effect.talent_id, "rate": float(effect.effect_amount) / 100.0})
		minimums.append({"source_id": effect.talent_id, "amount": int(effect.effect_params.get("minimum_block", 0))})
	result["percent_reductions"] = percentages
	result["minimum_blocks"] = minimums
	if amount(profile, "lethal_protection") > 0:
		var survivals: Array = result.get("survivals", []).duplicate(true)
		var hp := maxi(amount(profile, "lethal_protection"), amount(profile, "lethal_protection_hp"))
		survivals.push_front({"source_id": "z2_talent_10", "kind": "talent", "counter_key": "z2_talent_10", "hp": hp})
		result["survivals"] = survivals
	return result


static func heal_packet(state: Dictionary, packet: Dictionary) -> Dictionary:
	var profile := _vitals_profile(state)
	var bonus := 0
	for effect in _effects(profile, "low_hp_healing_percent"):
		if int(state.hp) * 100 <= int(state.max_hp) * int(effect.effect_params.get("hp_threshold_percent", 30)):
			bonus += int(effect.effect_amount)
	if bonus == 0:
		return packet
	var result := packet.duplicate(true)
	result["bonus_rate"] = float(result.get("bonus_rate", 0.0)) + float(bonus) / 100.0
	return result


static func pressure_packet(state: Dictionary, packet: Dictionary) -> Dictionary:
	if amount(_vitals_profile(state), "first_pressure_waiver") <= 0 or int(state.get("counters", {}).get("z2_talent_05", 0)) <= 0:
		return packet
	var result := packet.duplicate(true)
	result["waiver"] = {"source_id": "z2_talent_05", "counter_key": "z2_talent_05"}
	return result


static func pressure_cap(state: Dictionary) -> int:
	var profile := _vitals_profile(state)
	if not bool(profile.get("enabled", false)):
		return 15 # The unversioned historical ruleset retains its original cap.
	var cap := amount(profile, "pressure_increase_cap")
	return cap if cap > 0 else -1


static func critical_stats(profile: Dictionary) -> Dictionary:
	var unlocked := _effects(profile, "critical_unlock")
	if unlocked.is_empty():
		return {"chance_percent": 0, "damage_percent": 100}
	var chance := amount(profile, "critical_unlock") + amount(profile, "critical_chance_percent")
	var damage := int(unlocked[0].effect_params.get("damage_percent", 150)) + amount(profile, "critical_damage_percent")
	if amount(profile, "critical_overflow") > 0:
		damage += maxi(0, chance - 100) * amount(profile, "critical_overflow")
	return {"chance_percent": clampi(chance, 0, 100), "damage_percent": damage}


static func _vitals_profile(state: Dictionary) -> Dictionary:
	return state.get("modifiers", {}).get("z2_talents", {})


static func _effects(profile: Dictionary, kind: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if bool(profile.get("enabled", false)):
		for effect in profile.get("effects", []):
			if str(effect.get("effect_kind", "")) == kind:
				result.append(effect)
	return result
