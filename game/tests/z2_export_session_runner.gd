extends SceneTree

# Run in an isolated project, or as an external --script against a real PCK.
# --record and --restore deliberately use separate processes and the same user dir.
const Registry := preload("res://scripts/core/content/content_def_registry.gd")
const Runtime := preload("res://scripts/core/run/run_runtime_controller.gd")
const Intent := preload("res://scripts/ui/app_shell/navigation_intent.gd")
const RECEIPT := "user://z2_export_test.json"
var failures: Array[String] = []
var checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var qa_home := OS.get_environment("Z2_EXPORT_QA_HOME").replace("\\", "/").trim_suffix("/")
	if not qa_home.is_absolute_path() or not OS.get_user_data_dir().replace("\\", "/").to_lower().begins_with(qa_home.to_lower() + "/"):
		_check(false, "Z2_EXPORT_QA_HOME must contain isolated user data")
		_finish()
		return
	var args := OS.get_cmdline_user_args()
	for arg in args:
		if arg.begins_with("--expect-invalid="):
			var manager := SaveManager.new()
			manager.load_manifest()
			var runtime := Runtime.new()
			runtime.bind_meta_progress_adapter(MetaProgressAdapter.new())
			var initialized := runtime.initialize_z2_session(manager)
			_check(not initialized.get("ok", true) and initialized.get("reason") == arg.get_slice("=", 1), "initialize rejects exact reason: " + JSON.stringify(initialized))
			_check(not runtime.context.run_active, "rejected session never installs an active run")
			print("Z2_EXPORT_REJECT=" + JSON.stringify(initialized))
			if arg.get_slice("=", 1) == "checkpoint_content_mismatch" and FileAccess.file_exists(RECEIPT):
				var previous: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(RECEIPT))
				_check(runtime.get("_content_hash") != previous.content_hash, "actual rule edit changes checkpoint identity")
				print("Z2_EXPORT_CHANGED_IDENTITY=" + JSON.stringify({"before": previous.content_hash, "after": runtime.get("_content_hash"), "search_seconds": Runtime.Z2_SEARCH_BASE_SECONDS}))
			runtime.in_run_runtime.bind(null)
			runtime.command_bus.bind_runtime_controller(null)
			_finish()
			return
	var registry := Registry.new()
	var registered := registry.setup_z2()
	_check(registered.get("ok", false), "registry initializes: " + JSON.stringify(registered))
	if not registered.get("ok", false):
		_finish()
		return
	var content_hash := RunStateSnapshot.fingerprint(registry.snapshot())
	var packed_mode := not FileAccess.file_exists("res://project.godot")
	_check(not packed_mode or not FileAccess.file_exists("res://scripts/core/run/run_runtime_controller.gd"), "compressed PCK has no raw Runtime.gd")
	_check(FileAccess.file_exists("res://data/assets/asset_manifest.csv"), "raw runtime asset manifest exported for Main")
	if not failures.is_empty():
		_finish()
		return
	root.size = Vector2i(1280, 720)
	var main := (load("res://scenes/main/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	var scene = main.get_node("RunScene")
	scene.set_process(false)
	await process_frame
	_check(scene.runtime_controller.persistence_error.is_empty(), "Main official session initializes")
	if not scene.runtime_controller.persistence_error.is_empty():
		_release(main)
		await process_frame
		_finish()
		return
	if args.has("--restore"):
		var receipt: Variant = JSON.parse_string(FileAccess.get_file_as_string(RECEIPT)) if FileAccess.file_exists(RECEIPT) else null
		_check(receipt is Dictionary, "previous process left a test receipt")
		if receipt is Dictionary:
			_check(receipt.content_hash == content_hash, "source/pack content hash agrees")
			_check(scene.run_context.run_active and str(scene.run_context.run_id) == receipt.run_id, "Main restores the same actual checkpoint")
			_check(scene.run_context.hp == 73, "saved HP restored without offline simulation")
			scene.ui_shell.host_route_requested.emit(Intent.make_run(&"z2_export_test", {"continue_active_run": true}))
			_check(scene.screen_state == scene.SCREEN_RUN and scene.last_command_result.get("status") == &"continued_active_run", "Main continue route resumes restored run")
	else:
		_check(not scene.run_context.run_active and scene.meta_progress_adapter.data.get("ruleset_id") == "z2", "Main creates a new Z2 profile")
		var meta = scene.meta_progress_adapter
		_check(meta.begin_tutorial_training().get("ok", false), "fixture teaching grant persists")
		_check(meta.purchase_tutorial_flag().get("ok", false), "fixture teaching purchase persists")
		_check(meta._apply_tutorial_settlement({"mode": "tutorial", "outcome": "Training Complete", "settlement": {"outcome": "success"}}, "export-fixture-teaching").get("ok", false), "fixture teaching qualification persists")
		var config := RunStartConfig.default_config()
		config.merge({"map_config_id": "classic_7x7_simple", "difficulty": &"simple", "seed_value": 71}, true)
		config.selected_objective_id = M7ContentCatalog.commission_offer_candidates("classic_7x7_simple", 0)[0].id
		var started: Dictionary = scene.command_bus.dispatch(&"start_standard_run", {"run_start_config": config})
		_check(started.get("ok", false) and scene.run_context.run_active, "Main command starts admitted standard run")
		if started.get("ok", false):
			scene.run_context.hp = 73
			_check(scene.runtime_controller.save_current_checkpoint().get("ok", false), "actual checkpoint persisted")
			var receipt := FileAccess.open(RECEIPT, FileAccess.WRITE)
			receipt.store_string(JSON.stringify({"run_id": str(scene.run_context.run_id), "content_hash": content_hash}))
	print("Z2_EXPORT_IDENTITY=" + JSON.stringify({"packed": packed_mode, "content_hash": content_hash, "search_seconds": Runtime.Z2_SEARCH_BASE_SECONDS, "run_id": str(scene.run_context.run_id)}))
	_release(main)
	await process_frame
	await process_frame
	_finish()


func _release(main: Node) -> void:
	var runtime = main.get_node("RunScene").runtime_controller
	main.queue_free()
	runtime.in_run_runtime.bind(null)
	runtime.command_bus.bind_runtime_controller(null)


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)


func _finish() -> void:
	for failure in failures:
		printerr("Z2_EXPORT_SESSION_FAIL " + failure)
	print("Z2_EXPORT_SESSION=%s checks=%d failures=%d" % ["PASS" if failures.is_empty() else "FAIL", checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
