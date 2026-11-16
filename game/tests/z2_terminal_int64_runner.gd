extends SceneTree

const Runtime := preload("res://scripts/core/run/run_runtime_controller.gd")
const Manager := preload("res://scripts/core/save/save_manager.gd")
const Meta := preload("res://scripts/core/save/meta_progress_adapter.gd")
const Save := preload("res://scripts/core/save/save_adapter.gd")
const StartConfig := preload("res://scripts/core/run/run_start_config.gd")
const Catalog := preload("res://scripts/core/content/m7_content_catalog.gd")
const Checkpoint := preload("res://scripts/core/save/run_checkpoint_service.gd")
const Context := preload("res://scripts/core/run/run_context.gd")
const Lifecycle := preload("res://scripts/core/run/run_state_machine.gd")
const Snapshot := preload("res://scripts/core/run/run_state_snapshot.gd")
const FULL_SEED: int = 9223372036854775806

var failures: Array[String] = []
var checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_real_full_width_terminal()
	_test_signed_nested_terminal_numbers()
	_test_existing_plain_profiles_and_receipts()
	_check(Save.json_fingerprint({"seed": FULL_SEED}).is_empty(), "raw unsafe JSON number validation remains strict")
	for failure in failures:
		print("Z2_TERMINAL_INT64_CASE_FAIL " + failure)
	print("Z2_TERMINAL_INT64 checks=%d failures=%d" % [checks, failures.size()])
	print("Z2_TERMINAL_INT64=%s" % ("PASS" if failures.is_empty() else "FAIL"))
	quit(0 if failures.is_empty() else 1)


func _test_real_full_width_terminal() -> void:
	# Break caught: valid int64 seed checkpoints but settlement refuses it or rounds it on disk.
	var manager = Manager.new()
	manager.switch_profile("z2_int64_%d" % Time.get_ticks_usec())
	var meta = Meta.new()
	manager.configure_meta_adapter(meta)
	_check(bool(meta.initialize_z2_profile(Runtime.Z2_CONTENT_VERSION).get("ok", false)), "create explicit Z2 profile")
	if not _complete_teaching(meta):
		return
	var runtime = Runtime.new()
	runtime.bind_meta_progress_adapter(meta)
	_check(bool(runtime.initialize_z2_session(manager).get("ok", false)), "configure real runtime")
	var config := StartConfig.default_config()
	config.merge({"map_config_id": "classic_7x7_simple", "difficulty": &"simple", "seed_value": FULL_SEED}, true)
	config["selected_objective_id"] = Catalog.commission_offer_candidates("classic_7x7_simple", 0)[0]["id"]
	var started: Dictionary = runtime.command_bus.dispatch(&"start_standard_run", {"run_start_config": config})
	_check(bool(started.get("ok", false)), "public standard start accepts full-width seed")
	if not started.get("ok", false):
		_release(runtime)
		return
	_check(runtime.context.seed_value == FULL_SEED, "start retains exact native int64 seed")
	_check(bool(runtime.save_current_checkpoint().get("ok", false)), "full-width seed checkpoints")
	var checkpoint: Dictionary = runtime.checkpoint_service.load_checkpoint()
	var decoded: Dictionary = runtime.decode_checkpoint_state(checkpoint.get("snapshot", {}).get("state", {})).get("state", {})
	_check(decoded.get("context", {}).get("data", {}).get("seed_value") == FULL_SEED, "real checkpoint seed remains exact")
	var terminal: Dictionary = runtime.command_bus.dispatch(&"abandon_run", {"confirmed": true})
	if runtime.context.phase == &"failure_salvage":
		terminal = runtime.command_bus.dispatch(&"confirm_failure_salvage", {"selected_instance_ids": []})
	var payload: Dictionary = runtime.context.result_snapshot.duplicate(true)
	var untouched := payload.duplicate(true)
	var run_id := str(runtime.context.run_id)
	_check(bool(terminal.get("ok", false)), "terminal command commits")
	_check(bool(runtime.last_meta_commit.get("ok", false)), "full-width seed reaches durable terminal receipt: " + str(runtime.last_meta_commit.get("status", "")))
	_check(meta.data.run_receipts.has(run_id), "terminal receipt exists")
	_check(not FileAccess.file_exists(runtime.checkpoint_service.checkpoint_path), "durable terminal receipt permits checkpoint cleanup")
	var stored_result: Dictionary = meta.data.run_receipts.get(run_id, {}).get("result", {}).duplicate(true)
	# Compare the same public Meta boundary, excluding only Checkpoint/Runtime transport fields.
	var original: Dictionary = runtime.last_meta_commit.duplicate(true)
	original.erase("cleanup_pending")
	original.erase("durable_checkpoint")
	var reloaded = Meta.new()
	manager.configure_meta_adapter(reloaded)
	_check(not reloaded.write_blocked, "full-width metadata reloads writable")
	var history: Array = reloaded.get_summary().get("history_records", [])
	_check(history.size() == 1, "one terminal history record after disk reload")
	if not history.is_empty():
		_check(history[0].get("seed") is int and history[0].get("seed") == FULL_SEED, "history seed reloads as exact native int64")
	var before := FileAccess.get_file_as_string(meta.active_meta_progress_path)
	var replay: Dictionary = reloaded.apply_settlement(payload)
	_check(bool(replay.get("ok", false)) and replay == original, "reloaded identical payload returns original receipt")
	var reordered := {}
	var keys: Array = payload.keys()
	keys.reverse()
	for key in keys:
		reordered[key] = payload[key]
	_check(reloaded.apply_settlement(reordered) == original, "dictionary order does not change terminal fingerprint")
	_check(reloaded.data.run_receipts.get(run_id, {}).get("result", {}) == stored_result, "stored terminal receipt remains exactly unchanged after reload and public replay")
	var conflict := payload.duplicate(true)
	conflict.run_start_config.seed_value = FULL_SEED + 1
	_check(reloaded.apply_settlement(conflict).get("status") == "run_receipt_conflict", "adjacent full-width seed remains distinguishable")
	conflict.run_start_config.seed_value = str(FULL_SEED)
	_check(reloaded.apply_settlement(conflict).get("status") == "run_receipt_conflict", "numeric seed and textual seed remain distinct")
	_check(before == FileAccess.get_file_as_string(meta.active_meta_progress_path), "replays and conflicts perform no metadata writes")
	_check(int(reloaded.data.run_count) == 1 and int(reloaded.data.abandon_count) == 1, "terminal replay never reapplies progression")
	_check(payload == untouched, "fingerprint and storage never mutate terminal payload")
	_release(runtime)


func _test_signed_nested_terminal_numbers() -> void:
	# Break caught: nested signed bounds round or a literal typed-looking dictionary is mistaken for a numeric tag.
	for seed_value in [9223372036854775807, -9223372036854775807 - 1]:
		var profile := "signed_%d" % Time.get_ticks_usec()
		var path := "user://z2_int64_signed/%s/meta_progress.json" % profile
		var meta = Meta.new()
		meta.set_active_profile_path(path, profile)
		_check(bool(meta.initialize_z2_profile(Runtime.Z2_CONTENT_VERSION).get("ok", false)), "initialize current signed-bound profile")
		if not _complete_teaching(meta):
			continue
		var admitted := _admitted_context(meta, "classic_7x7_simple", seed_value)
		if admitted.is_empty():
			continue
		var service: RunCheckpointService = admitted.checkpoint
		var context: RunContext = admitted.context
		var loaded: Dictionary = service.load_checkpoint()
		var decoded := Snapshot.unpack_checkpoint(loaded.snapshot.state)
		_check(decoded.get("ok", false) and decoded.state.context.data.seed_value == seed_value, "signed-bound seed survives real initial checkpoint")
		context.abandon_run()
		if not context.settlement_result.get("finalized", false):
			_check(context.confirm_failure_salvage([]).get("ok", false), "signed-bound terminal selection confirms")
		var nested := {"bounds": [9223372036854775807, -9223372036854775807 - 1], "literal": {"$type": "i64", "value": str(seed_value)}}
		var payload := context.result_snapshot.duplicate(true)
		_check(payload.run_start_config.get("seed_value") == seed_value and payload.settlement.get("finalized", false), "signed-bound actual RunResult retains seed and finalization")
		# Codec-only probe attached to the real terminal; never used as a gameplay fact.
		(payload.settlement.settlement_log as Array).append(nested)
		# History uses Meta's documented StringName/Vector projection, while int64 stays numeric.
		var expected_log: Array = meta._json_safe(payload.settlement.settlement_log)
		var unsupported := payload.duplicate(true)
		unsupported["unsupported_value"] = Color.RED
		_check(service.apply_settlement(unsupported).get("status") == "invalid_settlement_payload", "numeric support does not admit previously unsupported payload types")
		var committed: Dictionary = service.apply_settlement(payload)
		_check(bool(committed.get("ok", false)), "signed-bound terminal commits")
		var reloaded = Meta.new()
		reloaded.set_active_profile_path(path, profile)
		var history: Array = reloaded.get_summary().get("history_records", [])
		_check(history.size() == 1 and history[0].get("seed") == seed_value, "signed seed survives disk reload")
		if not history.is_empty():
			_check(history[0].get("settlement_log") == expected_log, "nested numeric bounds and literal tags retain their original values and types")
			var saved_probe: Dictionary = history[0].settlement_log.back()
			_check(saved_probe == nested and saved_probe.bounds[0] is int and saved_probe.bounds[1] is int and saved_probe.literal is Dictionary, "both int64 limits remain native integers and the literal tag remains a dictionary")
		_check(bool(reloaded.apply_settlement(payload).get("ok", false)) and int(reloaded.data.run_count) == 1, "signed terminal replay remains idempotent")


func _test_existing_plain_profiles_and_receipts() -> void:
	# Break caught: new terminal numeric storage silently migrates legacy data or invalidates old Z2 receipts.
	var save := Save.new()
	var path := "user://z2_int64_compat_%d/meta_progress.json" % Time.get_ticks_usec()
	var plain := save.default_meta_progress()
	plain["gold"] = 87
	plain["history_records"] = [{"seed": 42, "history_id": "legacy-history"}]
	_check(save.save_json(plain, path, false), "write plain legacy fixture")
	var legacy = Meta.new()
	legacy.set_active_profile_path(path, "int64-legacy")
	_check(not legacy.data.has("ruleset_id") and int(legacy.data.gold) == 87, "legacy schema and progress remain compatible")
	_check(legacy.save(), "legacy saves remain writable")
	var raw: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	_check(not raw.has("ruleset_id") and raw.history_records[0].get("seed") == 42, "legacy history storage remains plain JSON")
	var payload := {"run_id": "old-run", "outcome": "Abandoned", "seed": 42}
	var result := {"ok": true, "status": "committed", "result_id": "old-result", "outcome": "Abandoned"}
	# This is the historical pre-growth Z2 schema, not a current profile missing required fields.
	plain.merge({"profile_id": "int64-old-z2", "ruleset_id": "z2", "content_version": "z2", "admission": {}, "checkpoint_cleanup_run_id": ""}, true)
	plain["run_receipts"] = {"old-run": {"schema_version": 1, "profile_id": "int64-old-z2", "run_id": "old-run", "fingerprint": Save.json_fingerprint(payload), "result": result}}
	var old_path := path.get_base_dir().path_join("old_z2.json")
	_check(save.save_json(plain, old_path, false), "write existing unencoded Z2 receipt fixture")
	var old_meta = Meta.new()
	old_meta.set_active_profile_path(old_path, "int64-old-z2")
	_check(old_meta.apply_settlement(payload) == result, "old safe-number Z2 fingerprint replays unchanged")
	for storage_version in [1, 999]:
		var invalid := plain.duplicate(true)
		invalid["terminal_storage_version"] = storage_version
		var invalid_path := path.get_base_dir().path_join("invalid_terminal_%d.json" % storage_version)
		var file := FileAccess.open(invalid_path, FileAccess.WRITE)
		file.store_string(JSON.stringify(invalid))
		file.close()
		var invalid_meta = Meta.new()
		invalid_meta.set_active_profile_path(invalid_path, "int64-old-z2")
		_check(invalid_meta.write_blocked, "malformed or future typed terminal storage refuses writes: %d" % storage_version)


func _complete_teaching(meta) -> bool:
	_check(meta.begin_tutorial_training().get("ok", false), "teaching starts through Meta")
	_check(meta.purchase_tutorial_flag().get("ok", false), "teaching flag purchase commits")
	var admitted := _admitted_context(meta, "tutorial_5x5", 71)
	if admitted.is_empty():
		return false
	admitted.context.complete_extract()
	var result: Dictionary = admitted.checkpoint.apply_settlement(admitted.context.result_snapshot)
	meta.load_or_create_default()
	var ready: bool = result.get("ok", false) and meta.data.tutorial_completed and meta.data.profile_level == 1 and meta.data.talent_spent == 100
	_check(ready, "real teaching terminal persists legal level and purchased talent")
	return ready

func _admitted_context(meta, map_id: String, seed_value: int) -> Dictionary:
	var config := StartConfig.default_config()
	config.merge({"map_config_id": map_id, "difficulty": Catalog.map_definition_exact(map_id).difficulty, "seed_value": seed_value}, true)
	config.selected_objective_id = "" if map_id == "tutorial_5x5" else Catalog.commission_offer_candidates(map_id, 0)[0].id
	var authorized := StartConfig.authorize_with_meta(config, meta.get_summary())
	_check(authorized.get("ok", false), map_id + " authorized from trusted Meta")
	if not authorized.get("ok", false):
		return {}
	var context := Context.new()
	_check(Lifecycle.new().start_standard_run(context, authorized.config).get("ok", false), map_id + " actual context starts")
	var checkpoint := Checkpoint.new()
	_check(checkpoint.configure(meta, "z2", Runtime.Z2_CONTENT_VERSION).get("ok", false), map_id + " checkpoint configures")
	var snapshot := {"schema_version": 1, "profile_id": meta.active_profile_id, "run_id": str(context.run_id), "revision": 0,
		"ruleset_id": "z2", "content_version": Runtime.Z2_CONTENT_VERSION, "state": Snapshot.pack_checkpoint({"context": Snapshot.capture_context(context)})}
	var admitted := checkpoint.begin_admission(snapshot)
	_check(admitted.get("ok", false) and admitted.get("can_simulate", false), map_id + " prepared and active admission persist")
	return {"context": context, "checkpoint": checkpoint} if admitted.get("ok", false) else {}

func _release(runtime) -> void:
	runtime.command_bus.runtime_controller = null
	runtime.command_bus.room_resolver.bind_runtime_controller(null)
	runtime.in_run_runtime.bind(null)

func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
