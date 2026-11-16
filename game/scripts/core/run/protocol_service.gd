extends RefCounted
class_name ProtocolService

const RunBalanceCatalogScript := preload("res://scripts/core/run/run_balance_catalog.gd")

const MAX_PRESSURE := RunBalanceCatalogScript.PROTOCOL_PRESSURE_MAX


static func level_for_pressure(pressure: int) -> int:
	return RunBalanceCatalogScript.protocol_level_for_pressure(pressure)


static func exploration_cost(difficulty: StringName, protocol_level: int, first_entry: bool = true) -> int:
	if not first_entry:
		return 0
	var first_cost_level := 0
	match difficulty:
		&"simple", &"easy":
			first_cost_level = 1
		&"normal", &"standard":
			first_cost_level = 2
		&"hard":
			first_cost_level = 3
		&"hell":
			first_cost_level = 4
	if protocol_level < 1 or protocol_level > first_cost_level:
		return 0
	return first_cost_level - protocol_level + 1


static func add_pressure(context: RunContext, amount: int) -> Dictionary:
	if context == null:
		return {"pressure": 0, "protocol_level": 5, "changed": false}
	var previous_level := context.protocol_level
	context.pressure = clampi(context.pressure + amount, 0, MAX_PRESSURE)
	context.protocol_level = level_for_pressure(context.pressure)
	return {
		"pressure": context.pressure,
		"protocol_level": context.protocol_level,
		"changed": previous_level != context.protocol_level,
		"penalty": false,
	}
