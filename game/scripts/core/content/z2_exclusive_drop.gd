extends RefCounted
class_name Z2ExclusiveDrop

const PROBABILITY_TOLERANCE := 1.0e-12


# Pure content validation/transformation. The caller supplies an approved target
# set and an already-eligible pool; this module never enables content or draws RNG.
# Zero-mass output entries retain identity. Draw consumers must skip those entries.
static func adjust_exclusive_pool(pool: Array, bonus_percent: float, target_ids: Array, scope_configured: bool = false) -> Dictionary:
	if not is_finite(bonus_percent) or bonus_percent < 0.0:
		return _failure("invalid_bonus_percent")
	var targets := {}
	for id in target_ids:
		if not _valid_id(id) or targets.has(str(id)):
			return _failure("invalid_target_ids")
		targets[str(id)] = true
	var total_weight := 0.0
	var target_weight := 0.0
	var probability_total := 0.0
	for entry in pool:
		if not entry is Dictionary or not _valid_id(entry.get("item_id")):
			return _failure("invalid_pool_entry")
		if not _valid_mass(entry.get("roll_weight")):
			return _failure("invalid_roll_weight")
		if not _valid_mass(entry.get("probability")) or float(entry.probability) > 1.0:
			return _failure("invalid_probability")
		total_weight += float(entry.roll_weight)
		probability_total += float(entry.probability)
		if targets.has(str(entry.item_id)):
			target_weight += float(entry.roll_weight)
	if not is_finite(total_weight):
		return _failure("invalid_total_mass")
	if total_weight <= 0.0:
		return _failure("zero_total_mass")
	for entry: Dictionary in pool:
		if absf(float(entry.probability) - float(entry.roll_weight) / total_weight) > PROBABILITY_TOLERANCE:
			return _failure("inconsistent_probability")
	if absf(probability_total - 1.0) > PROBABILITY_TOLERANCE:
		return _failure("invalid_probability_total")
	var base_target_mass := target_weight / total_weight
	if bonus_percent == 0.0:
		return _success(pool.duplicate(true), false, base_target_mass, base_target_mass)
	if not scope_configured:
		return _failure("exclusive_scope_unconfigured")
	var factor := 1.0 + bonus_percent / 100.0
	var target_mass := base_target_mass * factor
	# Never normalize/cap an impossible configuration into a different promise.
	if base_target_mass >= 1.0 or target_mass > 1.0:
		return _failure("exclusive_probability_overflow", base_target_mass, target_mass)
	if target_mass == base_target_mass:
		return _success(pool.duplicate(true), false, base_target_mass, base_target_mass)
	var complement_factor := (1.0 - target_mass) / (1.0 - base_target_mass)
	var adjusted := pool.duplicate(true)
	var adjusted_weight := 0.0
	var adjusted_probability := 0.0
	for entry: Dictionary in adjusted:
		var probability := float(entry.roll_weight) / total_weight
		probability *= factor if targets.has(str(entry.item_id)) else complement_factor
		entry.probability = probability
		entry.roll_weight = probability * total_weight
		adjusted_weight += float(entry.roll_weight)
		adjusted_probability += probability
	# Subnormal rounding must not advertise one probability while the actual
	# weighted consumer receives another. Refuse instead of rescaling or capping.
	if not is_finite(adjusted_weight) or adjusted_weight <= 0.0 or absf(adjusted_probability - 1.0) > PROBABILITY_TOLERANCE or absf(adjusted_weight - total_weight) > total_weight * PROBABILITY_TOLERANCE:
		return _failure("unrepresentable_adjusted_mass", base_target_mass, target_mass)
	for entry: Dictionary in adjusted:
		if absf(float(entry.probability) - float(entry.roll_weight) / adjusted_weight) > PROBABILITY_TOLERANCE:
			return _failure("unrepresentable_adjusted_mass", base_target_mass, target_mass)
	return _success(adjusted, true, base_target_mass, target_mass)


static func _valid_id(value: Variant) -> bool:
	return (value is String or value is StringName) and not str(value).is_empty() and str(value) == str(value).strip_edges()


static func _valid_mass(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) >= 0.0


static func _success(pool: Array, applied: bool, base_target_mass: float, target_mass: float) -> Dictionary:
	return {"ok": true, "reason": "", "pool": pool, "applied": applied,
		"base_target_mass": base_target_mass, "target_mass": target_mass}


static func _failure(reason: String, base_target_mass: float = 0.0, target_mass: float = 0.0) -> Dictionary:
	return {"ok": false, "reason": reason, "pool": [], "applied": false,
		"base_target_mass": base_target_mass, "target_mass": target_mass}
