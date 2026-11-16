extends SceneTree

const Runtime = preload("res://scripts/core/run/run_runtime_controller.gd")
const Manager = preload("res://scripts/core/save/save_manager.gd")
const Meta = preload("res://scripts/core/save/meta_progress_adapter.gd")
const Codec = preload("res://scripts/core/run/run_state_snapshot.gd")

class CutMetaSave extends SaveAdapter:
	var fail_next_commit := false
	func _rename_file(source: String, target: String) -> bool:
		if fail_next_commit and source.ends_with(ATOMIC_TEMP_SUFFIX):
			fail_next_commit = false
			return false
		return super._rename_file(source, target)

var failures: Array[String] = []
var checks := 0

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var runtime = Runtime.new()
	if not runtime.has_method("initialize_z2_session"):
		_check(false, "runtime_persistence_api_missing")
	else:
		_test_disk_resume(runtime)
	_release(runtime)
	_test_terminal_retry(false)
	_test_terminal_retry(true)
	_test_envelope_state_binding()
	_test_semantic_restore_and_retry()
	_test_malformed_runtime_fields()
	for operation_seed in [17, 20261115, 2147483647]:
		_test_restart_sequence(operation_seed)
	for failure in failures:
		print("Z2_PERSISTENCE_CASE_FAIL " + failure)
	print("Z2_RUNTIME_PERSISTENCE=%s checks=%d" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)

func _test_disk_resume(runtime) -> void:
	var manager = Manager.new()
	manager.switch_profile("z2_test_%d" % Time.get_ticks_usec())
	var adapter = Meta.new()
	manager.configure_meta_adapter(adapter)
	var initialized: Dictionary = adapter.initialize_z2_profile("z2-t00-t04-20261115")
	_check(bool(initialized.get("ok", false)), "explicit_missing_profile_created")
	runtime.bind_meta_progress_adapter(adapter)
	var configured: Dictionary = runtime.initialize_z2_session(manager)
	_check(bool(configured.get("ok", false)), "runtime_service_configured")
	var start: Dictionary = runtime.command_bus.dispatch(&"start_demo_run", {})
	_check(bool(start.get("ok", false)), "start_persisted")
	_check(runtime.transaction_revision == 0, "admission_starts_revision_zero")
	var checkpoint: Dictionary = runtime.checkpoint_service.load_checkpoint()
	_check(bool(checkpoint.get("can_simulate", false)) and int(checkpoint.get("generation", -1)) == 0, "admission_is_active_before_success")
	var changed: Dictionary = runtime.command_bus.dispatch(&"toggle_flag_cell", {"pos": Vector2i(3, 2), "action_id": "persisted_flag"})
	_check(bool(changed.get("ok", false)), "action_persisted")
	runtime.update_player_location(Vector2(87, 104))
	_check(bool(runtime.save_current_checkpoint().get("ok", false)), "normal_quit_flushes_position")
	var expected: Dictionary = runtime.capture_authoritative_state()
	var resumed = Runtime.new()
	var reloaded_adapter = Meta.new()
	manager.configure_meta_adapter(reloaded_adapter)
	resumed.bind_meta_progress_adapter(reloaded_adapter)
	var restored: Dictionary = resumed.initialize_z2_session(manager)
	_check(bool(restored.get("ok", false)), "fresh_runtime_loads_disk")
	_check(resumed.capture_authoritative_state() == expected, "complete_runtime_roundtrip")
	_check(resumed.get_restored_local_position(Vector2.ZERO) == Vector2(87, 104), "player_local_position_restored")
	var replay: Dictionary = resumed.command_bus.dispatch(&"toggle_flag_cell", {"pos": Vector2i(3, 2), "action_id": "persisted_flag"})
	_check(bool(replay.get("duplicate", false)) and resumed.context.intel_map.is_flagged(Vector2i(3, 2)), "receipt_survives_process_restart")
	var before: Dictionary = resumed.capture_authoritative_state()
	resumed.checkpoint_writer = func(_snapshot: Dictionary) -> Dictionary: return {"ok": false, "reason": "disk_full"}
	var rejected: Dictionary = resumed.command_bus.dispatch(&"toggle_flag_cell", {"pos": Vector2i(4, 3)})
	_check(not bool(rejected.get("ok", true)), "write_failure_rejected")
	_check(resumed.capture_authoritative_state() == before, "write_failure_rolls_back_full_state")
	_release(resumed)

func _release(runtime) -> void:
	runtime.command_bus.runtime_controller = null
	runtime.command_bus.room_resolver.bind_runtime_controller(null)
	runtime.in_run_runtime.bind(null)

func _check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)


func _fixture(label: String, standard_seed: bool = false) -> Dictionary:
	var manager = Manager.new()
	manager.switch_profile("review_%s_%d" % [label, Time.get_ticks_usec()])
	var meta = Meta.new()
	manager.configure_meta_adapter(meta)
	_check(bool(meta.initialize_z2_profile(Runtime.Z2_CONTENT_VERSION).get("ok", false)), label + ": profile")
	if standard_seed:
		meta.data["tutorial_completed"] = true
		meta.data["unlocked_map_ids"] = ["tutorial_5x5", "classic_7x7_simple"]
		_check(meta.save(), label + ": persist existing tutorial-complete fixture")
	var runtime = Runtime.new()
	runtime.bind_meta_progress_adapter(meta)
	_check(bool(runtime.initialize_z2_session(manager).get("ok", false)), label + ": initialize")
	var start: Dictionary
	if standard_seed:
		var config := RunStartConfig.default_config()
		config.merge({"map_config_id": "classic_7x7_simple", "difficulty": &"simple", "seed_value": 9223372036854775806}, true)
		config["selected_objective_id"] = M7ContentCatalog.commission_offer_candidates("classic_7x7_simple", 0)[0]["id"]
		start = runtime.command_bus.dispatch(&"start_standard_run", {"run_start_config": config})
		if not bool(start.get("ok", false)):
			print("FIXTURE_START_ERROR %s maps=%s" % [start, meta.get_summary().get("unlocked_map_ids")])
	else:
		start = runtime.command_bus.dispatch(&"start_demo_run", {})
	_check(bool(start.get("ok", false)), label + ": start")
	return {"runtime": runtime, "meta": meta, "manager": manager}


func _test_terminal_retry(preview: bool) -> void:
	var label := "preview_retry" if preview else "actual_retry"
	var f := _fixture(label)
	var runtime = f.runtime
	var adapter := CutMetaSave.new()
	f.meta.save_adapter = adapter
	adapter.fail_next_commit = true
	var terminal: Dictionary = runtime.command_bus.dispatch(&"abandon_run", {"confirmed": true})
	_check(bool(terminal.get("ok", false)) and str(runtime.last_meta_commit.get("status", "")) == "save_failed", label + ": pending terminal fixture")
	var before := FileAccess.get_file_as_string(f.meta.active_meta_progress_path)
	var before_authority: Dictionary = runtime.capture_authoritative_state()
	var cp_path: String = runtime.checkpoint_service.checkpoint_path
	_check(FileAccess.file_exists(cp_path), label + ": terminal checkpoint exists before retry")
	var result: Dictionary = runtime.command_bus.dispatch(&"retry_terminal_commit", {"preview": preview})
	var disk_changed := before != FileAccess.get_file_as_string(f.meta.active_meta_progress_path)
	var has_receipt: bool = f.meta.data.run_receipts.has(str(runtime.context.run_id))
	if preview:
		_check(not disk_changed and not has_receipt and FileAccess.file_exists(cp_path), "preview retry must preserve disk/meta/checkpoint")
		_check(before_authority == runtime.capture_authoritative_state(), "preview retry preserves runtime")
	else:
		_check(bool(result.get("ok", false)) and runtime.persistence_error.is_empty(), "successful terminal retry must report success and remain unblocked")
		_check(bool(runtime.last_meta_commit.get("ok", false)), "successful terminal retry must retain successful meta result")
	_release(runtime)


func _test_envelope_state_binding() -> void:
	var f := _fixture("binding")
	var loaded: Dictionary = f.runtime.checkpoint_service.load_checkpoint()
	var cp: Dictionary = loaded.snapshot.duplicate(true)
	cp["revision"] = 1
	_check(bool(f.runtime.checkpoint_service.save_checkpoint(cp).get("ok", false)), "binding: opaque service accepts increasing envelope revision")
	var runtime = Runtime.new()
	var meta = Meta.new()
	f.manager.configure_meta_adapter(meta)
	runtime.bind_meta_progress_adapter(meta)
	var restored: Dictionary = runtime.initialize_z2_session(f.manager)
	var action := {}
	if bool(restored.get("ok", false)):
		action = runtime.command_bus.dispatch(&"toggle_flag_cell", {"pos": Vector2i(3, 2)})
	_check(not bool(restored.get("ok", false)) and not runtime.context.run_started, "runtime must reject envelope/state revision mismatch before install")
	_release(runtime)
	_release(f.runtime)


func _test_semantic_restore_and_retry() -> void:
	var f := _fixture("semantic_retry")
	var runtime = f.runtime
	var before: Dictionary = runtime.capture_authoritative_state()
	var malformed := before.duplicate(true)
	malformed["command_sequence"] = -1
	var direct: Dictionary = runtime.restore_checkpoint_state(runtime.encode_checkpoint_state(malformed))
	_check(not bool(direct.get("ok", false)) and runtime.capture_authoritative_state() == before, "negative command sequence rejects atomically")
	runtime.install_authoritative_state(before)
	var path: String = runtime.checkpoint_service.checkpoint_path
	var envelope: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	malformed = before.duplicate(true)
	malformed["context"]["data"]["hp"] = -1
	envelope["snapshot"]["state"] = runtime.encode_checkpoint_state(malformed)
	envelope["snapshot_hash"] = SaveAdapter.json_fingerprint(envelope["snapshot"])
	# A generation-zero snapshot is bound to the admission, so use an ordinary
	# committed generation-one snapshot to test same-revision backup validation.
	var changed: Dictionary = runtime.command_bus.dispatch(&"toggle_flag_cell", {"pos": Vector2i(3, 2)})
	_check(bool(changed.get("ok", false)), "semantic_retry: revision one")
	before = runtime.capture_authoritative_state()
	envelope = JSON.parse_string(FileAccess.get_file_as_string(path))
	malformed = before.duplicate(true)
	malformed["context"]["data"]["hp"] = -1
	envelope["snapshot"]["state"] = runtime.encode_checkpoint_state(malformed)
	envelope["snapshot_hash"] = SaveAdapter.json_fingerprint(envelope["snapshot"])
	_write_text(path + ".bak", JSON.stringify(envelope, "", true, true))
	_write_text(path, "{broken")
	runtime.persistence_error = {"ok": false, "status": "save_failed"}
	var retry: Dictionary = runtime.retry_persistence()
	_check(FileAccess.get_file_as_string(path) == "{broken", "invalid_backup_never_repairs_primary")
	_check(not bool(retry.get("ok", false)) and not runtime.persistence_error.is_empty(), "retry must validate same-revision recovered backup before repair")
	_release(runtime)


func _write_text(path: String, value: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(value)
	file.close()

func _test_malformed_runtime_fields() -> void:
	var f := _fixture("bad_top_level")
	var runtime = f.runtime
	var before: Dictionary = runtime.capture_authoritative_state()
	for field in ["local_position", "command_sequence", "receipts", "checkpoint_elapsed", "has_local_position"]:
		var malformed := before.duplicate(true)
		malformed.context.data.hp = 77
		malformed[field] = "invalid_type"
		var rejected: Dictionary = runtime.restore_checkpoint_state(runtime.encode_checkpoint_state(malformed))
		_check(not bool(rejected.get("ok", false)) and runtime.capture_authoritative_state() == before, "invalid_top_level_atomic_" + field)
	var malformed := before.duplicate(true)
	malformed.receipts["bad_receipt"] = {"fingerprint": "short", "result": {}}
	_check(not bool(runtime.restore_checkpoint_state(runtime.encode_checkpoint_state(malformed)).get("ok", false)) and runtime.capture_authoritative_state() == before, "malformed_receipt_atomic")
	malformed = before.duplicate(true)
	var rooms: Dictionary = malformed.context.components.truth_map.rooms
	rooms[rooms.keys()[0]]["pos"] = Vector2i(-1, -1)
	_check(not bool(runtime.restore_checkpoint_state(runtime.encode_checkpoint_state(malformed)).get("ok", false)) and runtime.capture_authoritative_state() == before, "invalid_room_reference_atomic")
	malformed = before.duplicate(true)
	malformed.context.components.asset_ledger.item_instances["orphan_floor"] = {"instance_id": "orphan_floor", "location_state": "room_floor", "room_pos": Vector2i(3, 3)}
	_check(not bool(runtime.restore_checkpoint_state(runtime.encode_checkpoint_state(malformed)).get("ok", false)) and runtime.capture_authoritative_state() == before, "missing_floor_index_atomic")
	malformed = before.duplicate(true)
	malformed.context.data.temporary_statuses = [{"id": "bad", "phase": "unknown"}]
	_check(not bool(runtime.restore_checkpoint_state(runtime.encode_checkpoint_state(malformed)).get("ok", false)) and runtime.capture_authoritative_state() == before, "invalid_status_atomic")
	var display: Dictionary = RunSceneResultController.build_result_display_snapshot({"settlement": {"finalized": true}}, {}, {"status": "save_failed", "durable_checkpoint": true})
	_check(not bool(display.discard_unsaved_allowed) and bool(display.retry_save_allowed), "durable_terminal_requires_retry")
	_release(runtime)


# Reproducible operation sequences exercise interactions between individually
# covered boundaries. The parity model does not use production snapshot logic.
func _test_restart_sequence(operation_seed: int) -> void:
	var f := _fixture("sequence_%d" % operation_seed)
	var runtime = f.runtime
	var rng := RandomNumberGenerator.new()
	rng.seed = operation_seed
	var expected_flags := {}
	for x in range(5):
		for y in range(5):
			var pos := Vector2i(x, y)
			expected_flags[pos] = runtime.context.intel_map.is_flagged(pos)
	for step in range(12):
		var label := "seed=%d step=%d" % [operation_seed, step]
		var target := Vector2i(rng.randi_range(0, 4), rng.randi_range(0, 4))
		var payload := {"pos": target, "action_id": "sequence_%d_%d" % [operation_seed, step]}
		var before: Dictionary = runtime.capture_authoritative_state()
		var path: String = runtime.checkpoint_service.checkpoint_path
		var disk_before := FileAccess.get_file_as_bytes(path)
		if step % 2 == 0:
			var preview_payload := payload.duplicate(true)
			preview_payload["preview"] = true
			var preview: Dictionary = runtime.command_bus.dispatch(&"toggle_flag_cell", preview_payload)
			_check(bool(preview.get("ok", false)) and runtime.capture_authoritative_state() == before and FileAccess.get_file_as_bytes(path) == disk_before, label + ": preview has no memory/disk effect")
		if step % 3 == 0:
			runtime.checkpoint_writer = func(_snapshot: Dictionary) -> Dictionary: return {"ok": false, "reason": "sequence_disk_full"}
			var failed: Dictionary = runtime.command_bus.dispatch(&"toggle_flag_cell", payload)
			_check(not bool(failed.get("ok", true)) and runtime.capture_authoritative_state() == before and FileAccess.get_file_as_bytes(path) == disk_before, label + ": failed commit preserves complete authority and disk")
			runtime.checkpoint_writer = Callable()
			_check(bool(runtime.retry_persistence().get("ok", false)), label + ": storage recovers before same-ID retry")
		var committed: Dictionary = runtime.command_bus.dispatch(&"toggle_flag_cell", payload)
		expected_flags[target] = not bool(expected_flags[target])
		_check(bool(committed.get("ok", false)) and runtime.transaction_revision == step + 1, label + ": one successful revision")
		var after: Dictionary = runtime.capture_authoritative_state()
		var disk_after := FileAccess.get_file_as_bytes(path)
		var replay: Dictionary = runtime.command_bus.dispatch(&"toggle_flag_cell", payload)
		_check(bool(replay.get("duplicate", false)) and runtime.capture_authoritative_state() == after and FileAccess.get_file_as_bytes(path) == disk_after, label + ": duplicate has no second effect or write")
		if step % 4 == 3:
			# Discard the runtime without an exit save: a new adapter and runtime
			# must recover precisely the already committed checkpoint.
			_release(runtime)
			f.runtime = null
			runtime = Runtime.new()
			var fresh_meta = Meta.new()
			f.manager.configure_meta_adapter(fresh_meta)
			runtime.bind_meta_progress_adapter(fresh_meta)
			var restored: Dictionary = runtime.initialize_z2_session(f.manager)
			_check(bool(restored.get("ok", false)) and runtime.capture_authoritative_state() == after, label + ": restart restores complete checkpoint")
			var restarted_replay: Dictionary = runtime.command_bus.dispatch(&"toggle_flag_cell", payload)
			_check(bool(restarted_replay.get("duplicate", false)) and runtime.capture_authoritative_state() == after and FileAccess.get_file_as_bytes(path) == disk_after, label + ": restart retains exactly-once receipt")
		var flags_match := true
		for pos in expected_flags:
			flags_match = flags_match and runtime.context.intel_map.is_flagged(pos) == bool(expected_flags[pos])
		_check(flags_match, label + ": all flags match independent parity model")
	_release(runtime)
