extends RefCounted
class_name RunStatusService


static func advance(state: Dictionary, delta: float, trigger: Dictionary) -> Dictionary:
	if not is_finite(delta) or delta < 0.0 or not _valid_statuses(state.get("statuses", [])):
		return _reject(state, "invalid_status_time_or_state")
	if not _valid_trigger(trigger):
		return _reject(state, "invalid_trigger")
	var next := state.duplicate(true)
	var facts := {"started": [], "ended": [], "hits_consumed": {}, "active_seconds": {}}
	if bool(trigger.get("offline", false)):
		return {"ok": true, "state": next, "facts": facts, "reason": ""}
	var kind := str(trigger.get("kind", ""))
	for status in next.get("statuses", []):
		if str(status.phase) == "ended":
			continue
		var id := str(status.id)
		var temporary: bool = str(status.type) in ["temporary_buff", "temporary_debuff"]
		var cleared: bool = temporary and (kind == "clear_temporary" or trigger.get("clear_types", []).has(str(status.type)) or trigger.get("clear_temporary_types", []).has(str(status.get("temporary_type", ""))))
		if cleared or (kind != "" and status.get("clear_on", []).has(kind)):
			status["phase"] = "ended"
			facts.ended.append(id)
			continue
		if str(status.phase) == "waiting":
			if kind == "" or kind != str(status.get("start_trigger", "")):
				continue
			status["phase"] = "active"
			facts.started.append(id)
		var active_seconds := 0.0 if status.has("hits_left") and int(status.hits_left) == 0 else delta
		if status.has("remaining"):
			active_seconds = minf(active_seconds, float(status.remaining))
			status.remaining = maxf(0.0, float(status.remaining) - active_seconds)
			# Avoid one extra fixed step from floating point residue at expiry.
			if float(status.remaining) <= 0.000000001:
				status.remaining = 0.0
		status.elapsed = float(status.get("elapsed", 0.0)) + active_seconds
		facts.active_seconds[id] = active_seconds
		if kind != "" and kind == str(status.get("hit_trigger", "hit")) and status.has("hits_left"):
			var hits := mini(int(status.hits_left), int(trigger.get("hit_count", 1)))
			status.hits_left = int(status.hits_left) - hits
			if hits > 0:
				facts.hits_consumed[id] = hits
		if (status.has("remaining") and float(status.remaining) == 0.0) or (status.has("hits_left") and int(status.hits_left) == 0):
			status["phase"] = "ended"
			facts.ended.append(id)
	return {"ok": true, "state": next, "facts": facts, "reason": ""}


static func _valid_statuses(value: Variant) -> bool:
	if not value is Array:
		return false
	var ids := {}
	for status in value:
		if not status is Dictionary:
			return false
		var id := str(status.get("id", ""))
		if id == "" or ids.has(id):
			return false
		ids[id] = true
		if not str(status.get("phase", "")) in ["waiting", "active", "ended"]:
			return false
		var kind := str(status.get("type", ""))
		if not kind in ["temporary_buff", "temporary_debuff", "equipment", "permanent"]:
			return false
		if kind in ["temporary_buff", "temporary_debuff"] and str(status.get("temporary_type", "")) == "":
			return false
		if str(status.phase) == "waiting" and str(status.get("start_trigger", "")) == "":
			return false
		for key in ["remaining", "elapsed", "hits_left"]:
			if status.has(key) and not _nonnegative(status[key]):
				return false
		if status.has("hits_left") and float(status.hits_left) != floor(float(status.hits_left)):
			return false
		if not status.get("clear_on", []) is Array or not status.get("paid_costs", {}) is Dictionary:
			return false
	return true


static func _valid_trigger(trigger: Dictionary) -> bool:
	var hits: Variant = trigger.get("hit_count", 1)
	return _nonnegative(hits) and float(hits) == floor(float(hits)) and trigger.get("clear_types", []) is Array and trigger.get("clear_temporary_types", []) is Array


static func _nonnegative(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) >= 0.0


static func _reject(state: Dictionary, reason: String) -> Dictionary:
	return {"ok": false, "state": state.duplicate(true), "facts": {}, "reason": reason}
