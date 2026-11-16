extends SceneTree

# Measurement-only subclasses: all production work is delegated unchanged.
const Context := preload("res://scripts/core/run/run_context.gd")
const Eligibility := preload("res://scripts/core/content/z2_content_eligibility.gd")
const Snapshot := preload("res://scripts/core/run/run_state_snapshot.gd")
const STEP := 1.0 / 60.0
const FRAME_BUDGET_US := 1000000.0 / 60.0

class MeasuredRuntime extends RunRuntimeController:
	var samples := {}
	var lane := "setup"
	var writes := 0

	func record(label: String, elapsed: int) -> void:
		if not samples.has(label):
			samples[label] = []
		samples[label].append(elapsed)

	func capture_authoritative_state() -> Dictionary:
		var start := Time.get_ticks_usec()
		var result := super.capture_authoritative_state()
		record(lane + "/full_snapshot_us", Time.get_ticks_usec() - start)
		return result

	func encode_checkpoint_state(state: Dictionary) -> Variant:
		var start := Time.get_ticks_usec()
		var result: Variant = super.encode_checkpoint_state(state)
		record(lane + "/encode_checkpoint_us", Time.get_ticks_usec() - start)
		return result

	func persist_candidate_state(state: Dictionary) -> Dictionary:
		var start := Time.get_ticks_usec()
		var result := super.persist_candidate_state(state)
		record(lane + "/persist_candidate_us", Time.get_ticks_usec() - start)
		writes += 1
		return result

var failures: Array[String] = []
var checks := 0
var results: Array = []
var batch_id := ""


func _initialize() -> void:
	Engine.physics_ticks_per_second = 60
	Engine.max_fps = 60
	batch_id = str(Time.get_unix_time_from_system()) + "_" + str(Time.get_ticks_usec())
	call_deferred("_run")


func _run() -> void:
	for history_count in [0, 1000, 5000]:
		await _case(history_count)
		if not failures.is_empty():
			break
	var output := {
		"version": 1, "godot": Engine.get_version_info(), "physics_hz": Engine.physics_ticks_per_second,
		"headless": DisplayServer.get_name(), "user_data_dir": OS.get_user_data_dir(),
		"frame_budget_us": FRAME_BUDGET_US, "timestamp_utc": Time.get_datetime_string_from_system(true),
		"method": "Real physics_frame scheduling, production idle/search/atomic checkpoint path, synthetic event-log history through record_event; inclusive timings are not additive.",
		"cases": results, "checks": checks, "failures": failures,
	}
	var path := OS.get_environment("T05_PERF_OUTPUT")
	if path.is_empty():
		path = "user://t05_performance_" + batch_id + ".json"
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		failures.append("cannot write measurement artifact")
	else:
		file.store_string(JSON.stringify(output, "\t"))
		file.close()
	for failure in failures:
		print("PERF_FAIL: " + failure)
	print("Z2_RUNTIME_PERFORMANCE=%s checks=%d failures=%d output=%s" % ["PASS" if failures.is_empty() else "FAIL", checks, failures.size(), ProjectSettings.globalize_path(path)])
	quit(0 if failures.is_empty() else 1)


func _case(history_count: int) -> void:
	var runtime := MeasuredRuntime.new()
	var frozen := {"ruleset_id": "z2", "z2_progression_version": 1, "content_eligibility": Eligibility.freeze_profile({"profile_level": 30})}
	runtime.context.start_run({"id": "perf", "seed": 348, "width": 13, "height": 13, "power": 20, "max_hp": 100,
		"profile_fields": frozen, "run_start_config": {"profile_fields": frozen.duplicate(true), "map_config_id": "classic_13x13_normal", "difficulty": "normal"},
		"manual_map": {"spawn": Vector2i.ZERO, "chests": [Vector2i(2, 0), Vector2i(4, 0)], "exits": [{"pos": Vector2i(12, 12), "exit_id": "perf_exit"}]}})
	for index in range(history_count):
		var start := Time.get_ticks_usec()
		runtime.context.run_event_log.record_event(&"room_entered", "history:%d" % index, &"player", "performance_fixture", {
			"position": Vector2i(index % 13, (index / 13) as int % 13), "room_type": &"Normal", "first_visit": false,
		})
		runtime.record("history/append_event_us", Time.get_ticks_usec() - start)
	var meta := MetaProgressAdapter.new()
	meta.set_active_profile_path("user://t05_perf/%s/history_%d/meta.json" % [batch_id, history_count], "perf_%d" % history_count)
	if not _ok(meta.initialize_z2_profile(RunRuntimeController.Z2_CONTENT_VERSION), "initialize real profile"):
		_release(runtime)
		return
	# Freeze the real profile's global fact cursor, as formal departure does.
	runtime.context.profile_fields["z2_fact_sequence_base"] = int(meta.data.get("z2_fact_sequence", 0))
	runtime.context.run_start_config["profile_fields"] = runtime.context.profile_fields.duplicate(true)
	runtime.meta_progress_adapter = meta
	runtime.checkpoint_service = RunCheckpointService.new()
	if not _ok(runtime.checkpoint_service.configure(meta, "z2", RunRuntimeController.Z2_CONTENT_VERSION), "configure real checkpoint service"):
		_release(runtime)
		return
	if not _ok(runtime.persist_candidate_state(runtime.capture_authoritative_state()), "real initial admission checkpoint"):
		_release(runtime)
		return
	print("PERF_CASE history=%d admitted events=%d" % [history_count, runtime.context.run_event_log.size()])
	runtime.lane = "warmup"
	await _frames(runtime, 60, "warmup")
	var searches: Array = []
	runtime.lane = "frame"
	for room_index in range(1, 5):
		var move_start := Time.get_ticks_usec()
		var entered: Dictionary = runtime.command_bus.dispatch(&"move_by", {"delta": Vector2i.RIGHT})
		runtime.record("command/room_entry_us", Time.get_ticks_usec() - move_start)
		if not _ok(entered, "actual movement/room hook"):
			_release(runtime)
			return
		var room_type := str(runtime.context.current_room_type)
		var base_seconds := 3.0 if room_type == "Chest" else 2.0
		var started_at := Time.get_ticks_usec()
		var begun: Dictionary = runtime.command_bus.dispatch(&"search_current_room", {})
		runtime.record("command/begin_search_us", Time.get_ticks_usec() - started_at)
		if not _ok(begun, "actual search command"):
			_release(runtime)
			return
		var room_key: String = runtime.context.cell_key(runtime.context.get_current_pos())
		var search_state: Dictionary = runtime.context.z1_event_flags.get("z2_search", {}).get("rooms", {}).get(room_key, {})
		_check(search_state.get("duration_seconds") == base_seconds, "confirmed2s/3s actual search duration")
		var ticks := int(base_seconds * 60.0)
		var search_start := Time.get_ticks_usec()
		await _frames(runtime, ticks - 1, "search_" + room_type.to_lower())
		_check(not runtime.context.searched_cells.has(room_key), "no early search reward")
		await _frames(runtime, 1, "search_completion")
		_check(runtime.context.searched_cells.has(room_key), "actual search completion/reward committed")
		searches.append({"room": room_key, "type": room_type, "ticks": ticks, "simulation_seconds": base_seconds, "wall_us": Time.get_ticks_usec() - search_start})
		print("PERF_SEARCH history=%d room=%d type=%s ticks=%d" % [history_count, room_index, room_type, ticks])
	await _frames(runtime, 120, "idle")
	if not failures.is_empty():
		_release(runtime)
		return
	print("PERF_CASE history=%d frames_complete" % history_count)
	runtime.lane = "micro"
	var snapshot := runtime.capture_authoritative_state()
	var encoded: Dictionary = {}
	for index in range(1000):
		snapshot = runtime.capture_authoritative_state()
		var start := Time.get_ticks_usec()
		Snapshot.capture_data(runtime.context.run_event_log)
		runtime.record("micro/event_log_capture_us", Time.get_ticks_usec() - start)
	for index in range(100):
		encoded = runtime.encode_checkpoint_state(snapshot)
	_check(not encoded.is_empty(), "full snapshot encodes")
	for index in range(20):
		var start := Time.get_ticks_usec()
		if not _ok(runtime.save_current_checkpoint(), "forced real checkpoint"):
			_release(runtime)
			return
		runtime.record("micro/full_checkpoint_action_us", Time.get_ticks_usec() - start)
	var loaded := {}
	for index in range(10):
		var start := Time.get_ticks_usec()
		loaded = runtime.checkpoint_service.load_checkpoint()
		runtime.record("micro/disk_load_us", Time.get_ticks_usec() - start)
		if not _ok(loaded, "real checkpoint load"):
			_release(runtime)
			return
		var resumed := RunRuntimeController.new()
		start = Time.get_ticks_usec()
		var restored: Dictionary = resumed.restore_checkpoint_state(loaded.snapshot.state, loaded.snapshot)
		runtime.record("micro/decode_validate_install_us", Time.get_ticks_usec() - start)
		_check(restored.get("ok", false) and resumed.context.searched_cells == runtime.context.searched_cells, "disk-only restart preserves completed search")
		_release(resumed)
	var summary := {}
	for label in runtime.samples:
		summary[label] = _stats(runtime.samples[label])
	results.append({"synthetic_history_events": history_count, "final_events": runtime.context.run_event_log.size(),
		"map_dimensions": [13, 13], "searches": searches, "action_receipts": runtime.action_receipts.size(),
		"checkpoint_path": ProjectSettings.globalize_path(runtime.checkpoint_service.checkpoint_path),
		"checkpoint_bytes": FileAccess.get_file_as_bytes(runtime.checkpoint_service.checkpoint_path).size(),
		"native_snapshot_bytes": encoded.get("byte_count", 0), "packed_base64_bytes": str(encoded.get("data", "")).length(),
		"native_event_log_bytes": var_to_bytes(Snapshot.capture_data(runtime.context.run_event_log)).size(),
		"summary": summary, "samples_us": runtime.samples.duplicate(true)})
	print("PERF_CASE history=%d complete frame=%s" % [history_count, JSON.stringify(summary.get("frame/total_us", {}))])
	_release(runtime)


func _frames(runtime: MeasuredRuntime, count: int, phase: String) -> void:
	var previous_start := 0
	for tick in range(count):
		await physics_frame
		var start := Time.get_ticks_usec()
		if previous_start > 0:
			runtime.record(runtime.lane + "/physics_interval_us", start - previous_start)
		previous_start = start
		var writes_before := runtime.writes
		var result := runtime.advance_idle_frame(STEP)
		var elapsed := Time.get_ticks_usec() - start
		runtime.record(runtime.lane + "/total_us", elapsed)
		runtime.record(runtime.lane + "/" + phase + "_us", elapsed)
		runtime.record(runtime.lane + ("/save_frame_us" if runtime.writes > writes_before else "/no_save_frame_us"), elapsed)
		if not _ok(result, "actual60Hz tick"):
			return


func _stats(values: Array) -> Dictionary:
	var ordered := values.duplicate()
	ordered.sort()
	var total := 0.0
	var over_budget := 0
	for value in values:
		total += value
		if value > FRAME_BUDGET_US:
			over_budget += 1
	return {"n": values.size(), "mean_us": total / values.size(), "p50_us": ordered[ceili(values.size() * 0.50) - 1],
		"p95_us": ordered[ceili(values.size() * 0.95) - 1], "p99_us": ordered[ceili(values.size() * 0.99) - 1],
		"max_us": ordered.back(), "over_16_667ms": over_budget}


func _ok(value: Dictionary, label: String) -> bool:
	var ok := bool(value.get("ok", false))
	_check(ok, label + ": " + str(value.get("reason", value.get("status", ""))))
	return ok


func _check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)


func _release(runtime) -> void:
	runtime.in_run_runtime.bind(null)
	runtime.command_bus.item_command_handler.combat_active_query = Callable()
	runtime.command_bus.bind_runtime_controller(null)
	runtime.context = null
	runtime.in_run_runtime = null
	runtime.command_bus = null
