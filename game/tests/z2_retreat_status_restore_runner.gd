extends SceneTree

# No arguments runs both cases through separate prepare/restart processes.
# The guard must point at the harness's isolated user-data/environment root.
const Runtime := preload("res://scripts/core/run/run_runtime_controller.gd")
const Bridge := preload("res://scripts/core/run/g41_in_run_runtime.gd")
const Progress := preload("res://scripts/core/progression/m7_progression_service.gd")
const DRUGS := ["con_waiver_medicine", "con_countdown_pill"]
const STEP := 1.0 / 60.0

class ObservedBridge extends Bridge:
	var retreats := 0
	func _supply_lifecycle(kind: String) -> Dictionary:
		if kind == "retreat":
			retreats += 1
		return super._supply_lifecycle(kind)

class CutCheckpointRename extends SaveAdapter:
	var cut := true
	var cuts := 0
	func _rename_file(source_path: String, target_path: String) -> bool:
		if cut and source_path.ends_with("/run_checkpoint.json.tmp"):
			cuts += 1
			return false
		return super._rename_file(source_path, target_path)

var checks := 0
var failures: Array[String] = []
var qa_home := ""
var phase := "suite"
var drug := ""
var token := ""
var runtime


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	qa_home = OS.get_environment("Z2_RETREAT_RESTORE_QA_HOME").replace("\\", "/").simplify_path().trim_suffix("/")
	if not _check(qa_home.is_absolute_path() and qa_home.to_lower().begins_with("d:/") and qa_home.length() > 3, "explicit D isolation root required"):
		_finish()
		return
	for path in [OS.get_user_data_dir(), OS.get_environment("APPDATA"), OS.get_environment("LOCALAPPDATA"), OS.get_environment("TEMP"), OS.get_environment("TMP")]:
		_check(path.replace("\\", "/").simplify_path().to_lower().begins_with(qa_home.to_lower() + "/"), "user data and environment remain under QA root: " + path)
	if not failures.is_empty():
		_finish()
		return
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--phase="): phase = arg.get_slice("=", 1)
		if arg.begins_with("--drug="): drug = arg.get_slice("=", 1)
		if arg.begins_with("--token="): token = arg.get_slice("=", 1)
	if phase == "suite":
		_suite()
	elif _check(phase in ["prepare", "restart"] and drug in DRUGS and not token.is_empty() and token.is_valid_identifier(), "valid child phase/drug/token"):
		if _open():
			if phase == "prepare": _prepare()
			else: _restart()
	_finish()


func _suite() -> void:
	token = "r" + Crypto.new().generate_random_bytes(8).hex_encode()
	for item_id in DRUGS:
		for child_phase in ["prepare", "restart"]:
			var output: Array = []
			var args := PackedStringArray(["--headless", "--quit-after", "120", "--path", ProjectSettings.globalize_path("res://"), "--script", "res://tests/z2_retreat_status_restore_runner.gd", "--", "--phase=" + child_phase, "--drug=" + item_id, "--token=" + token])
			var exit_code := OS.execute(OS.get_executable_path(), args, output, true)
			var log := ""
			for chunk in output: log += str(chunk)
			var log_path := qa_home.path_join(token + "-" + item_id + "-" + child_phase + ".log")
			var file := FileAccess.open(log_path, FileAccess.WRITE)
			if _check(file != null, "child evidence log opens"):
				file.store_string(log)
				file.close()
			var clean := true
			for diagnostic in ["SCRIPT ERROR", "Parse Error", "ERROR:", "WARNING:"]:
				clean = clean and not log.contains(diagnostic)
			_check(exit_code == 0 and clean and log.contains("Z2_RETREAT_RESTORE=PASS"), item_id + "/" + child_phase + " exit=" + str(exit_code))
			print("RETREAT_RESTORE_CHILD drug=%s phase=%s exit=%d log=%s" % [item_id, child_phase, exit_code, log_path])
			print(log.strip_edges())


func _open() -> bool:
	var manager := SaveManager.new()
	manager.load_manifest()
	if not _check(manager.switch_profile("retreat_" + token + "_" + drug).get("ok", false), "isolated profile selected"):
		return false
	runtime = Runtime.new()
	runtime.in_run_runtime.bind(null)
	runtime.in_run_runtime = ObservedBridge.new()
	runtime.in_run_runtime.bind(runtime)
	runtime.command_bus.item_command_handler.combat_active_query = Callable(runtime.in_run_runtime, "has_active_combat")
	runtime.bind_meta_progress_adapter(MetaProgressAdapter.new())
	var result: Dictionary = runtime.initialize_z2_session(manager)
	_check(runtime.checkpoint_service != null and not runtime.checkpoint_writer.is_valid(), "real checkpoint service owns persistence")
	return _check(result.get("ok", false), "official session initialize/restore: " + str(result))


func _prepare() -> void:
	var meta = runtime.meta_progress_adapter
	if not _check(meta.begin_tutorial_training().get("ok", false), "teaching grant persists"): return
	if not _check(meta.purchase_tutorial_flag().get("ok", false), "teaching purchase persists"): return
	if not _check(meta._apply_tutorial_settlement({"mode": "tutorial", "outcome": "Training Complete", "settlement": {"outcome": "success"}}, "retreat-teaching-" + token).get("ok", false), "legal standard-run qualification persists"): return
	var ids := {}
	for item_id in DRUGS:
		var item := Progress.add_item_instance(meta.data, item_id, "retreat_restore_fixture")
		if not _check(not item.is_empty(), "owned supply instance " + item_id): return
		ids[item_id] = str(item.instance_id)
	if not _check(meta.save(), "owned instances saved before admission"): return
	var config := RunStartConfig.default_config()
	config.merge({"map_config_id": "classic_7x7_simple", "difficulty": &"simple", "seed_value": 71, "selected_consumable_ids": ids.values()}, true)
	config.selected_objective_id = M7ContentCatalog.commission_offer_candidates("classic_7x7_simple", 0)[0].id
	if not _check(runtime.command_bus.dispatch(&"start_standard_run", {"run_start_config": config}).get("ok", false), "real departure admits selected supply instances"): return
	var old_drug: String = DRUGS[1] if drug == DRUGS[0] else DRUGS[0]
	if not _use(str(ids[old_drug])): return
	var path := _monster_path()
	if not _check(not path.is_empty(), "generated map has a safe route to an ordinary Monster"): return
	for direction in path:
		if not _move(direction): return
	if not _activate(old_drug): return
	if not _flee(): return
	_check(_status(old_drug).get("phase") == "ended", "real retreat ends the old active drug")
	if not _use(str(ids[drug])): return
	_check(_status(drug).get("phase") == "waiting", "medicine used after retreat waits for the next encounter/attack")
	if not _check(runtime.save_current_checkpoint().get("ok", false), "waiting medicine saved through real Checkpoint"): return
	var before: Dictionary = runtime.capture_authoritative_state()
	var checkpoint_path: String = runtime.checkpoint_service.checkpoint_path
	var disk_before := FileAccess.get_file_as_bytes(checkpoint_path)
	var retreats_before: int = runtime.in_run_runtime.retreats
	var cut := CutCheckpointRename.new()
	runtime.checkpoint_service.save_adapter = cut
	var back: Vector2i = -Vector2i(path.back())
	var failed: Dictionary = runtime.command_bus.dispatch(&"attempt_room_transition", {"direction": back})
	_check(not failed.get("ok", true) and cut.cuts > 0 and not runtime.persistence_error.is_empty(), "real crossing reaches the injected checkpoint rename failure")
	_check(runtime.capture_authoritative_state() == before, "failed crossing rolls back the complete authoritative state")
	_check(FileAccess.get_file_as_bytes(checkpoint_path) == disk_before, "failed crossing leaves the committed checkpoint byte-identical")
	_check(runtime.in_run_runtime.retreats == retreats_before, "rollback installs authorization without replaying retreat")
	cut.cut = false
	_check(runtime.retry_persistence().get("ok", false), "official persistence retry restores the committed checkpoint")
	_check(runtime.capture_authoritative_state() == before, "retry also preserves all authority including waiting and ended statuses")
	var evidence := FileAccess.open(_evidence_path(), FileAccess.WRITE)
	if not _check(evidence != null, "restart expectation opens"): return
	evidence.store_var({"state": before, "old_drug": old_drug, "back": back})
	evidence.close()


func _restart() -> void:
	var evidence := FileAccess.open(_evidence_path(), FileAccess.READ)
	if not _check(evidence != null, "previous process left its durable expectation"): return
	var expected: Dictionary = evidence.get_var()
	evidence.close()
	_check(_status(drug).get("phase") == "waiting", "fresh-process restore preserves waiting medicine")
	_check(_status(str(expected.old_drug)).get("phase") == "ended", "fresh-process restore never revives the old ended medicine")
	_check(runtime.capture_authoritative_state() == expected.state, "fresh-process restore exactly preserves the complete authoritative state")
	_check(runtime.in_run_runtime.retreats == 0, "fresh-process restore performs no retreat lifecycle")
	var loaded: Dictionary = runtime.checkpoint_service.load_checkpoint()
	if not _check(loaded.get("ok", false), "real persisted checkpoint loads"): return
	for index in range(2):
		var restored: Dictionary = runtime.restore_checkpoint_state(loaded.snapshot.state, loaded.snapshot)
		_check(restored.get("ok", false) and runtime.capture_authoritative_state() == expected.state, "repeated restore is fully idempotent " + str(index))
	_check(runtime.in_run_runtime.retreats == 0, "repeated restore never replays retreat")
	if not _move(expected.back) or not _move(-Vector2i(expected.back)): return
	if not _activate(drug): return
	if not _flee(): return
	_check(_status(drug).get("phase") == "ended" and _status(str(expected.old_drug)).get("phase") == "ended", "next real retreat ends the restored medicine without reviving the old one")


func _monster_path() -> Array:
	var origin: Vector2i = runtime.context.get_current_pos()
	var queue: Array[Vector2i] = [origin]
	var paths := {}
	paths[origin] = []
	while not queue.is_empty():
		var pos: Vector2i = queue.pop_front()
		for direction in [Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT, Vector2i.UP]:
			var target: Vector2i = pos + direction
			if not runtime.context.is_inside(target) or paths.has(target): continue
			var room_type: StringName = runtime.context.truth_map.get_room_type(target)
			if room_type not in [&"Normal", &"Monster"]: continue
			var path: Array = paths[pos].duplicate()
			path.append(direction)
			if room_type == &"Monster": return path
			paths[target] = path
			queue.append(target)
	return []


func _move(direction: Vector2i) -> bool:
	var result: Dictionary = runtime.command_bus.dispatch(&"attempt_room_transition", {"direction": direction})
	return _check(result.get("ok", false), "actual room transition: " + str(result.get("reason", result.get("status", ""))))


func _use(instance_id: String) -> bool:
	var result: Dictionary = runtime.command_bus.dispatch(&"use_consumable", {"instance_id": instance_id})
	return _check(result.get("ok", false), "actual carried-instance use: " + str(result.get("reason", result.get("status", ""))))


func _activate(item_id: String) -> bool:
	if not _check(runtime.in_run_runtime.has_active_combat(), "ordinary Monster creates real combat"): return false
	runtime.in_run_runtime.advance_frame(STEP, Vector2.ZERO, Vector2.RIGHT)
	if item_id == "con_countdown_pill":
		if not _check(runtime.in_run_runtime.request_attack(Vector2.RIGHT).get("ok", false), "actual first attack requested"): return false
		runtime.in_run_runtime.advance_frame(STEP, Vector2.ZERO, Vector2.RIGHT)
	return _check(_status(item_id).get("phase") == "active", "actual combat/first attack activates " + item_id)


func _flee() -> bool:
	var retreats_before: int = runtime.in_run_runtime.retreats
	var result: Dictionary = runtime.in_run_runtime.request_flee()
	if not _check(result.get("ok", false), "ordinary flee committed: " + str(result.get("reason", ""))): return false
	_check(runtime.in_run_runtime.retreats == retreats_before + 1, "real committed flee invokes retreat lifecycle exactly once")
	_check(runtime.in_run_runtime.flee_authorized and not runtime.in_run_runtime.has_active_combat(), "flee authorization survives commit without live combat")
	return true


func _status(item_id: String) -> Dictionary:
	for status: Dictionary in runtime.context.temporary_statuses:
		if str(status.get("item_id", "")) == item_id: return status
	return {}


func _evidence_path() -> String:
	return "user://retreat_" + token + "_" + drug + ".bin"


func _check(condition: bool, message: String) -> bool:
	checks += 1
	if not condition: failures.append(message)
	return condition


func _finish() -> void:
	if runtime != null:
		runtime.in_run_runtime.bind(null)
		runtime.command_bus.item_command_handler.combat_active_query = Callable()
		runtime.command_bus.bind_runtime_controller(null)
	for failure in failures: printerr("Z2_RETREAT_RESTORE_FAIL " + failure)
	print("Z2_RETREAT_RESTORE=%s phase=%s drug=%s checks=%d failures=%d" % ["PASS" if failures.is_empty() else "FAIL", phase, drug, checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
