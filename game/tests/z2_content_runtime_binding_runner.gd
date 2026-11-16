extends SceneTree

const Snapshot = preload("res://scripts/core/run/run_state_snapshot.gd")
var failures: Array[String] = []
var checks := 0

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var registry := ContentDefRegistry.new()
	_check(registry.setup_z2().get("ok", false), "canonical registry ready")
	var expected := Snapshot.fingerprint(registry.snapshot())
	var manager := SaveManager.new()
	manager.switch_profile("binding_%d" % Time.get_ticks_usec())
	var meta := MetaProgressAdapter.new()
	var runtime := RunRuntimeController.new()
	runtime.bind_meta_progress_adapter(meta)
	_check(runtime.initialize_z2_session(manager).get("ok", false), "real session initialized")
	_check(runtime.get("_content_hash") == expected, "session hash identifies actual Z2 definitions and rules")
	var context := RunContext.new()
	context.start_run({"id": "binding", "width": 7, "height": 7, "profile_fields": {"ruleset_id": "z2", "z2_progression_version": 1}})
	_check(context.run_active and context.content_defs.definitions.has("goal.M01") and context.content_defs.definitions.has("item.col_missing_shift_roster"), "run binds current goals and items")
	_check(Snapshot.fingerprint(context.content_defs.snapshot()) == expected, "context and session use same content build")
	var saved := Snapshot.capture_context(context)
	var restored := RunContext.new()
	_check(Snapshot.install_context(restored, saved).get("ok", false), "new context restores")
	_check(Snapshot.fingerprint(restored.content_defs.snapshot()) == expected, "restoration recreates actual registry")
	var reused := RunContext.new()
	reused.start_run({"id": "legacy", "width": 7, "height": 7})
	var legacy := Snapshot.capture_context(reused)
	_check(Snapshot.install_context(reused, saved).get("ok", false) and reused.content_defs.definitions.has("rules.z2"), "restoring Z2 replaces existing legacy binding")
	_check(Snapshot.install_context(reused, legacy).get("ok", false) and not reused.content_defs.definitions.has("rules.z2"), "legacy restoration retains legacy definitions")
	runtime.command_bus.runtime_controller = null
	runtime.command_bus.room_resolver.bind_runtime_controller(null)
	runtime.in_run_runtime.bind(null)
	for failure in failures:
		print("Z2_CONTENT_RUNTIME_BINDING_FAIL " + failure)
	print("Z2_CONTENT_RUNTIME_BINDING=%s checks=%d failures=%d" % ["PASS" if failures.is_empty() else "FAIL", checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)
