extends SceneTree

const Snapshot := preload("res://scripts/core/run/run_state_snapshot.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var input_path := OS.get_environment("T05_LOAD_CHECKPOINT")
	var envelope: Variant = JSON.parse_string(FileAccess.get_file_as_string(input_path))
	if not envelope is Dictionary or not envelope.get("snapshot") is Dictionary:
		print("LOAD_INSPECTION=FAIL invalid checkpoint envelope")
		quit(1)
		return
	var decoded := Snapshot.unpack_checkpoint(envelope.snapshot.get("state"))
	if not decoded.get("ok", false):
		print("LOAD_INSPECTION=FAIL invalid encoded checkpoint")
		quit(1)
		return
	var state: Dictionary = decoded.state
	var rooms: Dictionary = state.context.components.truth_map.rooms
	var room_fields := {}
	var preview_fields := {}
	for room: Dictionary in rooms.values():
		for key in room:
			room_fields[str(key)] = int(room_fields.get(str(key), 0)) + var_to_bytes(room[key]).size()
		for key in room.get("RoomRulePreview", {}):
			preview_fields[str(key)] = int(preview_fields.get(str(key), 0)) + var_to_bytes(room.RoomRulePreview[key]).size()
	var cache: Dictionary = state.meta_action_cache
	var cache_rows: Array = []
	for id in cache:
		var cached: Dictionary = cache[id]
		var response: Dictionary = cached.get("envelope", {})
		var summary: Dictionary = response.get("meta_progress_summary", {})
		var result_summary: Dictionary = response.get("result", {}).get("summary", {})
		cache_rows.append({"action": response.get("action", ""), "bytes": var_to_bytes(cached).size(),
			"summary_bytes": var_to_bytes(summary).size(), "result_summary_bytes": var_to_bytes(result_summary).size(),
			"same_summary": not summary.is_empty() and summary == result_summary})
	var events: Array = state.context.components.run_event_log.events.duplicate(true)
	events.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return var_to_bytes(a).size() > var_to_bytes(b).size())
	var largest_events: Array = []
	for event: Dictionary in events.slice(0, 5):
		var reward: Dictionary = event.payload.get("reward", {})
		largest_events.append({"type": event.event_type, "bytes": var_to_bytes(event).size(),
			"payload_fields": _field_sizes(event.payload), "largest_nested_payloads": _nested_fields(event.payload, "payload", 0),
			"effects_equal_produced_effects": reward.has("effects") and reward.get("effects") == reward.get("produced_effects")})
	var data := {"checkpoint": input_path, "snapshot_bytes": var_to_bytes(state).size(), "room_count": rooms.size(),
		"room_value_bytes_by_field": room_fields, "room_rule_preview_value_bytes_by_field": preview_fields,
		"meta_cache": cache_rows, "largest_events": largest_events,
		"context_data_fields": _field_sizes(state.context.data), "root_fields": _field_sizes(state)}
	if "--registry" in OS.get_cmdline_user_args():
		data["registry_probe"] = _registry_probe(state)
	var output_path := OS.get_environment("T05_PERF_OUTPUT")
	var file := FileAccess.open(output_path, FileAccess.WRITE)
	if file == null:
		print("LOAD_INSPECTION=FAIL cannot write result")
		quit(1)
		return
	file.store_string(JSON.stringify(data, "\t"))
	file.close()
	print("LOAD_INSPECTION=PASS rooms=%d events=%d cache_entries=%d output=%s" % [rooms.size(), events.size(), cache.size(), output_path])
	quit(0)


func _field_sizes(value: Dictionary) -> Array:
	var rows: Array = []
	for key in value:
		rows.append({"field": str(key), "bytes": var_to_bytes(value[key]).size()})
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.bytes) > int(b.bytes))
	return rows


func _nested_fields(value: Dictionary, path: String, depth: int) -> Array:
	var result: Array = []
	for row: Dictionary in _field_sizes(value).slice(0, 5):
		var next := {"path": path + "/" + str(row.field), "bytes": row.bytes}
		if depth < 3 and value[row.field] is Dictionary and int(row.bytes) > 2048:
			next["children"] = _nested_fields(value[row.field], str(next.path), depth + 1)
		result.append(next)
	return result


func _registry_probe(state: Dictionary) -> Dictionary:
	var timings := {"setup_z2": [], "source_digests": [], "fresh_context_install": [], "existing_context_install": [], "opening_pure_preview": []}
	var context := RunContext.new()
	var installed := Snapshot.install_context(context, state.context)
	if not installed.get("ok", false):
		return {"error": installed}
	var opening := load("res://scripts/core/run/z2_opening_runtime.gd")
	var has_opening: bool = not context.z1_event_flags.get("z2_opening", {}).is_empty()
	var fact := {"kind": "room_entered", "fact_id": "readonly-profile", "actual": true, "pos": context.get_current_pos(), "first_visit": false}
	var before_preview := Snapshot.capture_context(context)
	var errors: Array = []
	for index in range(20):
		var registry := ContentDefRegistry.new()
		var began := Time.get_ticks_usec()
		var registered := registry.setup_z2()
		timings.setup_z2.append(Time.get_ticks_usec() - began)
		if not registered.get("ok", false):
			errors.append(registered)
		began = Time.get_ticks_usec()
		var sources: Dictionary = registry.call("_z2_rule_sources")
		timings.source_digests.append(Time.get_ticks_usec() - began)
		if not sources.get("ok", false):
			errors.append(sources)
		var fresh := RunContext.new()
		began = Time.get_ticks_usec()
		installed = Snapshot.install_context(fresh, state.context)
		timings.fresh_context_install.append(Time.get_ticks_usec() - began)
		if not installed.get("ok", false):
			errors.append(installed)
		began = Time.get_ticks_usec()
		installed = Snapshot.install_context(context, state.context)
		timings.existing_context_install.append(Time.get_ticks_usec() - began)
		if not installed.get("ok", false):
			errors.append(installed)
		if has_opening:
			began = Time.get_ticks_usec()
			opening.plan_trigger(context, fact)
			timings.opening_pure_preview.append(Time.get_ticks_usec() - began)
	var summary := {}
	for label in timings:
		var ordered: Array = timings[label].duplicate()
		if ordered.is_empty():
			continue
		ordered.sort()
		summary[label] = {"n": ordered.size(), "p50_us": ordered[ceili(ordered.size() * 0.5) - 1], "p95_us": ordered[ceili(ordered.size() * 0.95) - 1], "max_us": ordered.back()}
	return {"summary": summary, "samples_us": timings, "errors": errors,
		"content_defs_serialized": state.context.data.has("content_defs") or state.context.components.has("content_defs"),
		"registered_definitions": context.content_defs.definitions.size(), "preview_has_opening": has_opening,
		"preview_context_unchanged": Snapshot.capture_context(context) == before_preview}
