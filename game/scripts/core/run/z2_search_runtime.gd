extends RefCounted
class_name Z2SearchRuntime

const Talents := preload("res://scripts/core/progression/z2_talent_runtime.gd")
const STATE_VERSION := 1
const SEARCHABLE_TYPES := ["Normal", "Chest"]

# No gameplay duration defaults: the caller must supply confirmed base seconds.
# This state belongs in the parent's atomic snapshot alongside room rewards.
var _state: Dictionary = {"version": STATE_VERSION, "run_id": "", "rooms": {}}


func begin(run_id: String, room_key: String, room_type: StringName, base_seconds_by_type: Dictionary, talent_profile: Dictionary, gates: Dictionary) -> Dictionary:
	var blocked := _gate_reason(gates)
	if not blocked.is_empty():
		return _blocked(blocked)
	if not Talents.valid_profile(talent_profile) or not bool(talent_profile.get("enabled", false)):
		return _blocked("unsupported_ruleset")
	if run_id.is_empty() or room_key.is_empty():
		return _blocked("invalid_search_identity")
	if String(room_type) not in SEARCHABLE_TYPES:
		return _blocked("room_not_searchable")
	if not String(_state.run_id).is_empty() and _state.run_id != run_id:
		return _blocked("run_id_mismatch")
	if _state.rooms.has(room_key):
		if _state.rooms[room_key].room_type != String(room_type):
			return _blocked("room_type_mismatch")
		return progress(run_id, room_key)
	var base: Variant = base_seconds_by_type.get(String(room_type))
	if not _finite_number(base) or float(base) <= 0.0:
		return _blocked("base_duration_unconfigured")
	var multiplier := Talents.speed_multiplier(talent_profile, "search_speed_percent")
	var duration := float(base) / multiplier
	if not is_finite(duration) or duration <= 0.0:
		return _blocked("invalid_search_duration")
	_state.run_id = run_id
	_state.rooms[room_key] = {
		"room_type": String(room_type), "base_seconds": float(base),
		"speed_multiplier": multiplier, "duration_seconds": duration,
		"elapsed_seconds": 0.0, "phase": "searching",
	}
	return progress(run_id, room_key)


func advance(delta: float, run_id: String, room_key: String, gates: Dictionary) -> Dictionary:
	var blocked := _gate_reason(gates)
	if not blocked.is_empty():
		return _blocked(blocked)
	if not is_finite(delta) or delta < 0.0:
		return _blocked("invalid_simulation_delta")
	var current := progress(run_id, room_key)
	if not bool(current.ok):
		return current
	var became_ready := false
	var record: Dictionary = _state.rooms[room_key]
	if record.phase == "searching" and delta > 0.0:
		record.elapsed_seconds = minf(float(record.duration_seconds), float(record.elapsed_seconds) + delta)
		# Only absorb floating-point residue from partitioning simulation steps.
		if float(record.duration_seconds) - float(record.elapsed_seconds) <= 0.000000001:
			record.elapsed_seconds = record.duration_seconds
			record.phase = "ready"
			became_ready = true
	var result := progress(run_id, room_key)
	result["became_ready"] = became_ready
	return result


func complete(run_id: String, room_key: String, gates: Dictionary) -> Dictionary:
	var blocked := _gate_reason(gates)
	if not blocked.is_empty():
		return _blocked(blocked)
	var current := progress(run_id, room_key)
	if not bool(current.ok):
		return current
	if current.phase == "searching":
		return _blocked("search_incomplete")
	var completed_now: bool = current.phase == "ready"
	_state.rooms[room_key].phase = "completed"
	var result := progress(run_id, room_key)
	result["completed_now"] = completed_now
	result["completion_id"] = run_id + "/search:" + room_key
	return result


func progress(run_id: String, room_key: String) -> Dictionary:
	if run_id.is_empty() or _state.run_id != run_id:
		return _blocked("run_id_mismatch")
	if not _state.rooms.has(room_key):
		return _blocked("search_not_started")
	var result: Dictionary = _state.rooms[room_key].duplicate(true)
	result["ok"] = true
	result["run_id"] = run_id
	result["room_key"] = room_key
	result["progress"] = float(result.elapsed_seconds) / float(result.duration_seconds)
	result["remaining_seconds"] = float(result.duration_seconds) - float(result.elapsed_seconds)
	return result


func export_transaction_state() -> Dictionary:
	return _state.duplicate(true)


func validate_transaction_state(candidate: Variant) -> bool:
	if not candidate is Dictionary or candidate.size() != 3 or candidate.get("version") != STATE_VERSION:
		return false
	if not candidate.get("run_id") is String or not candidate.get("rooms") is Dictionary:
		return false
	if candidate.run_id.is_empty() and not candidate.rooms.is_empty():
		return false
	for room_key in candidate.rooms:
		if not room_key is String or room_key.is_empty():
			return false
		var record: Variant = candidate.rooms[room_key]
		if not record is Dictionary or record.size() != 6:
			return false
		if not record.get("room_type") is String or record.room_type not in SEARCHABLE_TYPES:
			return false
		if not record.get("phase") is String or record.phase not in ["searching", "ready", "completed"]:
			return false
		for field in ["base_seconds", "speed_multiplier", "duration_seconds", "elapsed_seconds"]:
			if not _finite_number(record.get(field)):
				return false
		if record.base_seconds <= 0.0 or record.speed_multiplier < 1.0 or record.duration_seconds <= 0.0:
			return false
		if not is_equal_approx(float(record.duration_seconds), float(record.base_seconds) / float(record.speed_multiplier)):
			return false
		if record.elapsed_seconds < 0.0 or record.elapsed_seconds > record.duration_seconds:
			return false
		if record.phase == "searching":
			if record.elapsed_seconds >= record.duration_seconds:
				return false
		elif record.elapsed_seconds != record.duration_seconds:
			return false
	return true


func import_transaction_state(candidate: Variant) -> Dictionary:
	if not validate_transaction_state(candidate):
		return _blocked("invalid_search_snapshot")
	_state = candidate.duplicate(true)
	return {"ok": true}


func reset() -> void:
	_state = {"version": STATE_VERSION, "run_id": "", "rooms": {}}


func _gate_reason(gates: Dictionary) -> String:
	for field in ["run_active", "online", "paused", "combat_active"]:
		if not gates.get(field) is bool:
			return "invalid_search_gates"
	if not gates.run_active:
		return "run_not_active"
	if not gates.online:
		return "offline"
	if gates.paused:
		return "simulation_paused"
	if gates.combat_active:
		return "combat_locked"
	return ""


func _finite_number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))


func _blocked(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason}
