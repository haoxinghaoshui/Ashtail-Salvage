extends SceneTree

const SaveScript := preload("res://scripts/core/save/save_adapter.gd")
const ManagerScript := preload("res://scripts/core/save/save_manager.gd")
const Paths := preload("res://scripts/core/save/save_profile_manifest.gd")
var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var manager := ManagerScript.new()
	var save := SaveScript.new()
	var id := "reset_fixture_%d" % Time.get_ticks_usec()
	manager.switch_profile(id)
	var paths := Paths.profile_paths(id)
	var old: Dictionary = save.default_meta_progress()
	old.gold = 777
	old.profile_exp = 5000
	save.save_json(old, paths.meta_progress)
	save.save_json({"old_checkpoint": true}, paths.run_checkpoint, false)
	_check(manager.has_method("reset_outdated_profiles_for_z2"), "official startup can reset old profiles")
	if manager.has_method("reset_outdated_profiles_for_z2"):
		var reset: Dictionary = manager.reset_outdated_profiles_for_z2()
		_check(reset.get("ok", false), "old profile reset succeeds")
		var fresh: Dictionary = save.load_json_or_default(paths.meta_progress)
		_check(fresh.get("profile_level", -1) == 0 and fresh.get("gold", -1) == 0 and fresh.get("warehouse_items", [1]).is_empty(), "old gold, level, and starter inventory are replaced")
		_check(fresh.get("talent_earned", 0) == 100 and fresh.get("talent_spent", -1) == 0, "reset creates only the new teaching grant")
		_check(not FileAccess.file_exists(paths.run_checkpoint), "old live run is removed after reset")
		fresh.gold = 13
		save.save_json(fresh, paths.meta_progress)
		manager.reset_outdated_profiles_for_z2()
		_check(save.load_json_or_default(paths.meta_progress).gold == 13, "current-version progress is not reset again")
	print("Z2_PROFILE_RESET failures=%d" % failures.size())
	for failure in failures:
		print("Z2_PROFILE_RESET_CASE_FAIL " + failure)
	print("Z2_PROFILE_RESET=%s" % ("PASS" if failures.is_empty() else "FAIL"))
	quit(0 if failures.is_empty() else 1)


func _check(ok: bool, message: String) -> void:
	if not ok:
		failures.append(message)
