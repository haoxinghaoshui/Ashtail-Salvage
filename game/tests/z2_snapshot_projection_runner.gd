extends SceneTree

const Snapshot = preload("res://scripts/core/run/run_state_snapshot.gd")
var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var context := RunContext.new()
	context.start_run({"id": "projection", "seed": 451, "width": 13, "height": 13})
	var raw_rooms := context.truth_map.rooms.duplicate(true)
	var before := {}
	for key in context.truth_map.rooms:
		var pos: Vector2i = context.truth_map.rooms[key].pos
		before[key] = context.truth_map.get_room_state(pos, context.intel_map)
	var snapshot := Snapshot.capture_context(context)
	var captured: Dictionary = snapshot.components.truth_map.rooms
	_check(captured.values().all(func(room: Dictionary) -> bool: return not room.has("RoomRulePreview")), "display-only no-persistence previews are not durable room state")
	_check(var_to_bytes(captured).size() < var_to_bytes(raw_rooms).size() / 2, "room snapshot removes the dominant redundant preview payload")
	_check(context.truth_map.rooms == raw_rooms, "capture never mutates live presentation or truth")
	var restored := RunContext.new()
	_check(Snapshot.install_context(restored, Snapshot.unpack_checkpoint(Snapshot.pack_checkpoint(snapshot)).state).get("ok", false), "compact native checkpoint restores")
	for key in before:
		_check(restored.truth_map.get_room_state(restored.truth_map.rooms[key].pos, restored.intel_map) == before[key], "all room presentation and truth survive restoration " + key)
	_check(restored.truth_map.rooms == raw_rooms, "raw room contract is restored exactly")
	var original := Snapshot.capture_context(restored)
	restored.truth_map.set_room_type(Vector2i(0, 0), &"Chest")
	Snapshot.install_context(restored, original)
	_check(restored.truth_map.rooms == raw_rooms, "rollback restores preview after room type changes")
	var encoded := Snapshot.pack_checkpoint(snapshot)
	_check(Snapshot.valid_context(Snapshot.unpack_checkpoint(encoded).state), "compact snapshot passes ordinary semantic validation")
	for failure in failures:
		print("Z2_SNAPSHOT_PROJECTION_FAIL " + failure)
	print("Z2_SNAPSHOT_PROJECTION=%s checks=%d failures=%d" % ["PASS" if failures.is_empty() else "FAIL", checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)
