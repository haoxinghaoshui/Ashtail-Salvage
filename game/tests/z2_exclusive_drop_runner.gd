extends SceneTree

const MODULE_PATH := "res://scripts/core/content/z2_exclusive_drop.gd"
var adjuster: GDScript
var checks := 0
var cases := 0
var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	if not _check(ResourceLoader.exists(MODULE_PATH), "pure adjuster exists"):
		_finish()
		return
	adjuster = load(MODULE_PATH) as GDScript
	if not _check(adjuster != null and adjuster.has_method("adjust_exclusive_pool"), "pure consumer API available"):
		_finish()
		return
	_exact_probability_and_complement()
	_noops_and_unknown_scope()
	_duplicate_entries_and_metadata()
	_unit_mass_boundary()
	_invalid_inputs()
	_mass_scale_extremes()
	_unrepresentable_adjusted_mass()
	_purity_and_restart()
	_rng_is_not_advanced()
	_finish()


func _entry(id: Variant, mass: Variant, probability: Variant) -> Dictionary:
	return {"item_id": id, "roll_weight": mass, "probability": probability, "weight": 987,
		"origin": {"channel": "synthetic_test_only", "tags": ["keep"]}}


func _base() -> Array:
	return [_entry("target", 1, 0.1), _entry("other", 9, 0.9)]


func _adjust(pool: Array, bonus: float = 20.0, ids: Array = ["target"], configured: bool = true) -> Dictionary:
	return adjuster.adjust_exclusive_pool(pool, bonus, ids, configured)


func _exact_probability_and_complement() -> void:
	cases += 1
	var result := _adjust(_base())
	_distribution(result, [0.12, 0.88], [1.2, 8.8], "10 percent becomes12, not30 or11.7647")
	_check(result.get("applied", false), "actual positive gain marked applied")
	_near(float(result.get("base_target_mass", -1.0)), 0.1, "reports baseline target probability")
	_near(float(result.get("target_mass", -1.0)), 0.12, "reports actual target probability")
	cases += 1
	var pool := [_entry("a", 20, 0.2), _entry("b", 30, 0.3), _entry("c", 10, 0.1), _entry("d", 40, 0.4)]
	_distribution(_adjust(pool, 50.0, ["a", "b"]), [0.3, 0.45, 0.05, 0.2], [30.0, 45.0, 5.0, 20.0], "each target scales, complement keeps1:4 ratio")
	cases += 1
	_distribution(_adjust(_base(), 12.5), [0.1125, 0.8875], [1.125, 8.875], "fractional finite percentage")


func _noops_and_unknown_scope() -> void:
	for test: Array in [[0.0, ["target"], false], [20.0, [], true], [20.0, ["already_filtered"], true], [0.0, ["target", "other"], true], [1.0e-18, ["target"], true]]:
		cases += 1
		var pool := _base()
		var result := _adjust(pool, test[0], test[1], test[2])
		_check(result.get("ok", false) and result.get("reason", "missing") == "", "valid no-op succeeds " + str(test))
		_check(not result.get("applied", true), "no representable gain means not applied " + str(test))
		_check(result.get("pool") == pool, "no-op preserves validated entries exactly")
		_check(result.get("base_target_mass", -1) == result.get("target_mass", -2), "no-op target probability unchanged")
	_reject(_base(), 20.0, ["target"], false, "exclusive_scope_unconfigured", "unconfigured positive effect")
	_reject(_base(), 20.0, [], false, "exclusive_scope_unconfigured", "unknown is not configured-empty")
	cases += 1
	var default_scope: Dictionary = adjuster.adjust_exclusive_pool(_base(), 20.0, ["target"])
	_check(not default_scope.get("ok", true) and default_scope.get("reason") == "exclusive_scope_unconfigured", "omitted scope never enables unknown content")


func _duplicate_entries_and_metadata() -> void:
	cases += 1
	var pool := [_entry("target", 2, 0.02), _entry(&"target", 8, 0.08), _entry("c", 36, 0.36), _entry("d", 54, 0.54)]
	for index in pool.size():
		pool[index]["entry_id"] = "source-row-%d" % index
		pool[index]["weight"] = [0, -100, "not_a_probability", INF][index]
	var before := var_to_bytes(pool)
	var result := _adjust(pool)
	_distribution(result, [0.024, 0.096, 0.352, 0.528], [2.4, 9.6, 35.2, 52.8], "duplicate ID entries preserve2:8 ratio")
	_check(var_to_bytes(pool) == before, "success does not mutate input")
	var output: Array = result.get("pool", [])
	if output.size() == pool.size():
		for index in pool.size():
			var expected: Dictionary = pool[index].duplicate(true)
			var actual: Dictionary = output[index].duplicate(true)
			for key in ["probability", "roll_weight"]:
				expected.erase(key)
				actual.erase(key)
			_check(var_to_bytes(actual) == var_to_bytes(expected), "identity/order/metadata/physical weight kept " + str(index))
		output[0].origin.tags.append("output_only")
		_check(var_to_bytes(pool) == before, "nested result metadata does not alias input")
	_reject(_base(), 20.0, ["target", &"target"], true, "invalid_target_ids", "duplicate configured IDs rejected, unlike duplicate entries")


func _unit_mass_boundary() -> void:
	cases += 1
	var boundary := [_entry("target", 5, 5.0 / 6.0), _entry("other", 1, 1.0 / 6.0)]
	var result := _adjust(boundary)
	_distribution(result, [1.0, 0.0], [6.0, 0.0], "exact upper boundary is valid with zero complement")
	_check(result.get("applied", false), "upper boundary gain applied")
	_near(float(result.get("target_mass", -1.0)), 1.0, "upper boundary reported as1")
	cases += 1
	var below := [_entry("target", 0.833333333, 0.833333333), _entry("other", 0.166666667, 0.166666667)]
	_distribution(_adjust(below), [0.9999999996, 0.0000000004], [0.9999999996, 0.0000000004], "near boundary remains finite")
	_reject([_entry("target", 0.833333334, 0.833333334), _entry("other", 0.166666666, 0.166666666)], 20.0, ["target"], true, "exclusive_probability_overflow", "just over boundary cannot be clamped")
	_reject([_entry("target", 9, 0.9), _entry("other", 1, 0.1)], 20.0, ["target"], true, "exclusive_probability_overflow", "108 percent is invalid configuration")
	_reject(_base(), 20.0, ["target", "other"], true, "exclusive_probability_overflow", "all positive-mass entries targeted")
	_reject(_base(), 1.0e-18, ["target", "other"], true, "exclusive_probability_overflow", "all-target positive bonus invalid even below multiplier precision")
	_reject([_entry("target", 5, 1.0)], 20.0, ["target"], true, "exclusive_probability_overflow", "single all-target pool")
	cases += 1
	var zero := [_entry("target", 0, 0.0), _entry("other", 5, 1.0)]
	var no_gain := _adjust(zero)
	_check(no_gain.get("ok", false) and not no_gain.get("applied", true) and no_gain.get("pool") == zero, "zero-mass target is not resurrected")


func _invalid_inputs() -> void:
	for bonus: float in [-1.0, INF, -INF, NAN]:
		_reject(_base(), bonus, ["target"], true, "invalid_bonus_percent", "invalid percentage " + str(bonus))
	for ids: Array in [[""], ["  "], [" target"], ["target "], [7], [null]]:
		_reject(_base(), 20.0, ids, true, "invalid_target_ids", "invalid configured ID " + str(ids))
	for bad: Variant in [null, 7, "not_an_entry", []]:
		_reject([bad], 20.0, ["target"], true, "invalid_pool_entry", "pool entry must be dictionary")
	for id: Variant in ["", " target", "target ", 7, null]:
		_reject([_entry(id, 1, 1.0)], 20.0, ["target"], true, "invalid_pool_entry", "invalid pool identity")
	for mass: Variant in [-1, INF, -INF, NAN, "1", true, null]:
		_reject([_entry("target", mass, 0.1), _entry("other", 9, 0.9)], 20.0, ["target"], true, "invalid_roll_weight", "roll mass must be finite nonnegative numeric")
	for probability: Variant in [-0.1, 1.1, INF, -INF, NAN, "0.1", true, null]:
		_reject([_entry("target", 1, probability), _entry("other", 9, 0.9)], 20.0, ["target"], true, "invalid_probability", "probability must be finite and in0..1")
	var missing_mass := _base()
	missing_mass[0].erase("roll_weight")
	_reject(missing_mass, 20.0, ["target"], true, "invalid_roll_weight", "physical weight is never fallback roll mass")
	var missing_probability := _base()
	missing_probability[0].erase("probability")
	_reject(missing_probability, 20.0, ["target"], true, "invalid_probability", "baseline probability required")
	_reject([_entry("target", 1, 0.2), _entry("other", 9, 0.8)], 20.0, ["target"], true, "inconsistent_probability", "two baseline representations must agree")
	_reject([_entry("target", 1, 0.1), _entry("other", 9, 0.8)], 20.0, ["target"], true, "inconsistent_probability", "unnormalized baseline not repaired silently")
	_reject([_entry("target", 1.0e308, 0.5), _entry("other", 1.0e308, 0.5)], 20.0, ["target"], true, "invalid_total_mass", "finite individual masses may overflow total")
	for bonus: float in [0.0, 20.0]:
		_reject([], bonus, [], true, "zero_total_mass", "empty pool cannot become drawable")
		_reject([_entry("target", 0, 0.0), _entry("other", 0, 0.0)], bonus, [], true, "zero_total_mass", "all zero pool cannot become drawable")
	_reject([_entry("target", -1, 0.1), _entry("other", 9, 0.9)], 0.0, [], false, "invalid_roll_weight", "no-op never bypasses malformed baseline")


func _mass_scale_extremes() -> void:
	for scale: float in [0.07, 1.0e-300, 1.0e300]:
		cases += 1
		var pool := [_entry("target", scale, 0.1), _entry("other", 9.0 * scale, 0.9)]
		_distribution(_adjust(pool), [0.12, 0.88], [1.2 * scale, 8.8 * scale], "positive tiny/large total " + str(scale))


func _unrepresentable_adjusted_mass() -> void:
	var smallest := PackedByteArray([1, 0, 0, 0, 0, 0, 0, 0]).decode_double(0)
	_check(smallest > 0.0 and is_finite(smallest), "subnormal fixture is positive finite")
	# Preserving W here rounds1.2 units back to1 unit: reporting12% while
	# returning an actual10% weighted pool would violate the public contract.
	_reject([_entry("target", smallest, 0.1), _entry("other", 9.0 * smallest, 0.9)], 20.0, ["target"], true, "unrepresentable_adjusted_mass", "subnormal roundoff may not falsify actual roll probability")


func _purity_and_restart() -> void:
	cases += 1
	var pool := _base()
	var before := var_to_bytes(pool)
	var first := _adjust(pool)
	var second := _adjust(pool)
	_check(first == second and var_to_bytes(pool) == before, "repeat frozen inputs deterministic and immutable")
	var restored: Array = JSON.parse_string(JSON.stringify(pool, "", true, true))
	_distribution(_adjust(restored), [0.12, 0.88], [1.2, 8.8], "serialized frozen pool restart")
	var output: Array = first.get("pool", [])
	if not output.is_empty():
		output[0]["item_id"] = "changed_outside"
		output[0].origin.tags.append("changed_outside")
	_check(_adjust(pool) == second, "mutating returned pool does not change future calls")
	var no_op := _adjust(pool, 0.0, ["target"], false)
	if not no_op.get("pool", []).is_empty():
		no_op.pool[0].origin.tags.append("changed_noop")
	_check(var_to_bytes(pool) == before, "no-op result also deeply detached")
	pool[0].origin.tags.append("live_source_changed")
	_check(second.get("pool", []).is_empty() or second.pool[0].origin.tags == ["keep"], "later source mutation cannot change frozen result")


func _rng_is_not_advanced() -> void:
	cases += 1
	seed(927431)
	var expected := [randi(), randf(), randi_range(-100, 100)]
	seed(927431)
	_adjust(_base())
	_adjust(_base(), 0.0, [], false)
	_adjust(_base(), 20.0, ["target"], false)
	_adjust(_base(), 20.0, ["target", "other"])
	var actual := [randi(), randf(), randi_range(-100, 100)]
	_check(actual == expected, "success/no-op/refusal never advances global RNG")


func _distribution(result: Dictionary, probabilities: Array, masses: Array, label: String) -> void:
	if not _check(result.get("ok", false) and result.get("reason", "missing") == "", label + " accepted"):
		return
	var pool: Array = result.get("pool", [])
	if not _check(pool.size() == probabilities.size(), label + " retains all entries"):
		return
	var total_probability := 0.0
	var total_mass := 0.0
	var expected_mass := 0.0
	for index in pool.size():
		_near(float(pool[index].probability), float(probabilities[index]), label + " probability " + str(index))
		_near(float(pool[index].roll_weight), float(masses[index]), label + " roll_weight " + str(index))
		_check(is_finite(float(pool[index].probability)) and is_finite(float(pool[index].roll_weight)) and pool[index].probability >= 0.0 and pool[index].roll_weight >= 0.0, label + " finite nonnegative output")
		total_probability += float(pool[index].probability)
		total_mass += float(pool[index].roll_weight)
		expected_mass += float(masses[index])
	_near(total_probability, 1.0, label + " probability sums1")
	_near(total_mass, expected_mass, label + " preserves total roll mass")
	if total_mass > 0.0:
		for entry: Dictionary in pool:
			_near(float(entry.probability), float(entry.roll_weight) / total_mass, label + " both representations agree")


func _reject(pool: Array, bonus: float, ids: Array, configured: bool, reason: String, label: String) -> void:
	cases += 1
	var before := var_to_bytes(pool)
	var result := _adjust(pool, bonus, ids, configured)
	_check(not result.get("ok", true), label + " refused")
	_check(result.get("reason", "") == reason, label + " reason=" + str(result.get("reason", "")))
	_check(result.get("pool", ["unexpected"]).is_empty() and not result.get("applied", true), label + " no fallback pool")
	_check(var_to_bytes(pool) == before, label + " refusal leaves input unchanged")


func _near(actual: float, expected: float, label: String) -> void:
	var tolerance := maxf(absf(expected), 1.0e-308) * 1.0e-6 if absf(expected) < 1.0e-8 else absf(expected) * 1.0e-12
	_check(is_finite(actual) and (actual == 0.0 if expected == 0.0 else absf(actual - expected) <= tolerance), "%s actual=%s expected=%s" % [label, actual, expected])


func _check(value: bool, label: String) -> bool:
	checks += 1
	if not value:
		failures.append(label)
	return value


func _finish() -> void:
	for failure in failures:
		print("Z2_EXCLUSIVE_DROP_CASE_FAIL " + failure)
	print("Z2_EXCLUSIVE_DROP=%s cases=%d checks=%d failures=%d" % ["PASS" if failures.is_empty() else "FAIL", cases, checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
