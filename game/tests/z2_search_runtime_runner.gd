extends SceneTree

const SEARCH_PATH := "res://scripts/core/run/z2_search_runtime.gd"
const Talents := preload("res://scripts/core/progression/z2_talent_runtime.gd")
const Catalog := preload("res://scripts/core/progression/z2_talent_catalog.gd")
const GATES := {"run_active": true, "online": true, "paused": false, "combat_active": false}
# Test-only durations. Production must inject confirmed values by room type.
const BASE_SECONDS := {"Normal": 13.0, "Chest": 26.0}
const RUN_ID := "search_fixture"

var runtime_script: Script
var checks := 0
var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	if not FileAccess.file_exists(SEARCH_PATH):
		_check(false, "missing_search_runtime: no resumable search consumer")
		_finish()
		return
	runtime_script = load(SEARCH_PATH)
	var runtime = runtime_script.new()
	for method in ["begin", "advance", "complete", "progress", "export_transaction_state", "validate_transaction_state", "import_transaction_state", "reset"]:
		_check(runtime.has_method(method), "missing_search_api: " + method)
	if failures.is_empty():
		_test_duration_and_completion()
		_test_scope_and_missing_configuration()
		_test_simulation_gates()
		_test_resume_and_room_progress()
		_test_rejected_snapshot()
		_test_frame_partition()
	_finish()


func _profile(nodes: Array = [], tutorial: bool = false, z2: bool = true) -> Dictionary:
	var effects: Array = []
	for node in nodes:
		effects.append(Catalog.definition("z2_talent_%02d" % int(node)))
	return Talents.run_profile({"ruleset_id": "z2", "z2_progression_version": 1} if z2 else {}, effects, tutorial)


func _begin(runtime, room_key: String = "1,1", room_type: StringName = &"Normal", profile: Dictionary = {}, durations: Dictionary = BASE_SECONDS, gates: Dictionary = GATES) -> Dictionary:
	return runtime.begin(RUN_ID, room_key, room_type, durations, _profile([12, 16]) if profile.is_empty() else profile, gates)


func _test_duration_and_completion() -> void:
	for fixture in [[[12], 11.0], [[16], 12.0], [[12, 16], 13.0]]:
		var runtime = runtime_script.new()
		var begun := _begin(runtime, "1,1", &"Normal", _profile(fixture[0]), {"Normal": fixture[1]})
		_check(begun.get("ok") == true and is_equal_approx(float(begun.get("duration_seconds", -1)), 10.0), "active talent speed divides actual required search time: " + str(fixture[0]))
		runtime.advance(9.0, RUN_ID, "1,1", GATES)
		_check(runtime.complete(RUN_ID, "1,1", GATES).get("reason") == "search_incomplete", "cannot complete/grant before adjusted duration")
		var ready: Dictionary = runtime.advance(1.0, RUN_ID, "1,1", GATES)
		_check(ready.get("phase") == "ready" and ready.get("became_ready") == true, "talented search becomes ready on actual elapsed boundary")
		var completed: Dictionary = runtime.complete(RUN_ID, "1,1", GATES)
		_check(completed.get("completed_now") == true and completed.get("completion_id") == RUN_ID + "/search:1,1", "completion gives a stable once-per-room identity")
		_check(runtime.complete(RUN_ID, "1,1", GATES).get("completed_now") == false, "repeat completion does not emit another completion")
	var chest = runtime_script.new()
	_begin(chest, "2,1", &"Chest")
	var halfway: Dictionary = chest.advance(10.0, RUN_ID, "2,1", GATES)
	_check(halfway.get("phase") == "searching" and is_equal_approx(float(halfway.get("progress", -1)), 0.5), "chest consumes its separately injected base duration")
	_check(chest.advance(10.0, RUN_ID, "2,1", GATES).get("phase") == "ready", "chest speed reaches readiness at20 test seconds")


func _test_scope_and_missing_configuration() -> void:
	var runtime = runtime_script.new()
	var empty: Dictionary = runtime.export_transaction_state()
	for durations in [{}, {"Chest": 26.0}, {"Normal": 0}, {"Normal": -1}, {"Normal": INF}, {"Normal": NAN}, {"Normal": "13"}, {"Normal": true}]:
		_check(_begin(runtime, "1,1", &"Normal", _profile(), durations).get("ok") == false and runtime.export_transaction_state() == empty, "missing/invalid base duration fails without inventing gameplay timing")
	_check(_begin(runtime, "1,1", &"Monster").get("reason") == "room_not_searchable", "combat room is not a timed search target")
	_check(_begin(runtime, "1,1", &"Normal", _profile([12, 16], false, false)).get("reason") == "unsupported_ruleset", "new search runtime does not change unversioned legacy scope")
	var tutorial: Dictionary = _begin(runtime, "1,1", &"Normal", _profile([12, 16], true))
	_check(tutorial.get("duration_seconds") == 13.0, "tutorial consumes injected baseline without purchased talent speed")
	var state: Dictionary = runtime.export_transaction_state()
	for delta in [-1.0, INF, NAN]:
		_check(runtime.advance(delta, RUN_ID, "1,1", GATES).get("ok") == false and runtime.export_transaction_state() == state, "invalid simulated time cannot corrupt progress")
	_check(runtime.advance(0.0, RUN_ID, "1,1", GATES).get("elapsed_seconds") == 0.0, "zero simulated time does no work")


func _test_simulation_gates() -> void:
	var runtime = runtime_script.new()
	for gate in ["run_active", "online", "paused", "combat_active"]:
		var blocked := GATES.duplicate()
		blocked[gate] = not GATES[gate]
		_check(_begin(runtime, "1,1", &"Normal", _profile(), BASE_SECONDS, blocked).get("ok") == false and runtime.export_transaction_state().get("rooms", {}).is_empty(), gate + " prevents starting")
	_begin(runtime)
	runtime.advance(2.0, RUN_ID, "1,1", GATES)
	var before: Dictionary = runtime.export_transaction_state()
	for gate in ["run_active", "online", "paused", "combat_active"]:
		var blocked := GATES.duplicate()
		blocked[gate] = not GATES[gate]
		_check(runtime.advance(86400.0, RUN_ID, "1,1", blocked).get("ok") == false and runtime.export_transaction_state() == before, gate + " does not advance or bank offline time")
	_check(runtime.advance(5.0, RUN_ID, "1,1", {}).get("ok") == false and runtime.export_transaction_state() == before, "missing simulation gates fail closed")
	runtime.advance(8.0, RUN_ID, "1,1", GATES)
	var fighting := GATES.duplicate()
	fighting["combat_active"] = true
	_check(runtime.complete(RUN_ID, "1,1", fighting).get("reason") == "combat_locked" and runtime.progress(RUN_ID, "1,1").get("phase") == "ready", "combat locks completion even when progress was already ready")
	_check(runtime.complete(RUN_ID, "1,1", GATES).get("completed_now") == true, "ready search completes once combat lock clears")


func _test_resume_and_room_progress() -> void:
	var runtime = runtime_script.new()
	_begin(runtime)
	runtime.advance(2.0, RUN_ID, "1,1", GATES)
	var repeated := _begin(runtime, "1,1", &"Normal", _profile(), {"Normal": 500.0})
	_check(repeated.get("duration_seconds") == 10.0 and repeated.get("elapsed_seconds") == 2.0, "restarting same search keeps frozen duration and progress")
	_begin(runtime, "2,1", &"Chest")
	runtime.advance(3.0, RUN_ID, "2,1", GATES)
	_check(runtime.progress(RUN_ID, "1,1").get("elapsed_seconds") == 2.0, "working in a second room preserves the first room's progress")
	var saved: Dictionary = runtime.export_transaction_state()
	var decoded: Variant = JSON.parse_string(JSON.stringify(saved))
	var restored = runtime_script.new()
	_check(restored.validate_transaction_state(decoded) and restored.import_transaction_state(decoded).get("ok") == true, "JSON checkpoint restores both rooms")
	_check(restored.progress(RUN_ID, "1,1").get("elapsed_seconds") == 2.0 and restored.progress(RUN_ID, "2,1").get("elapsed_seconds") == 3.0, "restore performs no wall-clock catch-up")
	restored.advance(8.0, RUN_ID, "1,1", GATES)
	var completed: Dictionary = restored.complete(RUN_ID, "1,1", GATES)
	_check(completed.get("completed_now") == true, "resumed remaining simulation time finishes real search")
	var restarted = runtime_script.new()
	restarted.import_transaction_state(restored.export_transaction_state())
	_check(restarted.complete(RUN_ID, "1,1", GATES).get("completed_now") == false, "completed checkpoint cannot issue completion twice after restart")
	var before: Dictionary = restarted.export_transaction_state()
	_check(restarted.advance(50.0, "other_run", "1,1", GATES).get("ok") == false and restarted.export_transaction_state() == before, "different run cannot advance saved search")
	_check(restarted.advance(50.0, RUN_ID, "unknown", GATES).get("ok") == false and restarted.export_transaction_state() == before, "unstarted room cannot receive search work")
	var detached: Dictionary = restarted.export_transaction_state()
	detached["rooms"].clear()
	_check(restarted.export_transaction_state() == before, "exported snapshot cannot mutate live progress")
	restarted.reset()
	_check(restarted.export_transaction_state().get("rooms", {}).is_empty() and restarted.progress(RUN_ID, "1,1").get("ok") == false, "new-run reset discards prior progress and completion receipts")


func _test_rejected_snapshot() -> void:
	var runtime = runtime_script.new()
	_begin(runtime)
	runtime.advance(2.0, RUN_ID, "1,1", GATES)
	var before: Dictionary = runtime.export_transaction_state()
	var malformed: Array = [{}, {"version": 2, "run_id": RUN_ID, "rooms": {}}]
	for fixture in [["elapsed_seconds", -1.0], ["elapsed_seconds", 11.0], ["elapsed_seconds", NAN], ["duration_seconds", 0.0], ["duration_seconds", 20.0], ["phase", "ready"], ["room_type", "Monster"]]:
		var candidate := before.duplicate(true)
		candidate.rooms["1,1"][fixture[0]] = fixture[1]
		malformed.append(candidate)
	for candidate in malformed:
		_check(not runtime.validate_transaction_state(candidate) and runtime.import_transaction_state(candidate).get("ok") == false and runtime.export_transaction_state() == before, "invalid restored progress is rejected atomically")


func _test_frame_partition() -> void:
	var runtime = runtime_script.new()
	_begin(runtime)
	for tick in range(600):
		runtime.advance(1.0 / 60.0, RUN_ID, "1,1", GATES)
	_check(runtime.progress(RUN_ID, "1,1").get("phase") == "ready", "fixed-step search reaches same boundary as two larger simulation steps")


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)


func _finish() -> void:
	for failure in failures:
		print("ASSERT_FAIL: " + failure)
	print("Z2_SEARCH_RUNTIME=%s checks=%d failures=%d" % ["PASS" if failures.is_empty() else "FAIL", checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
