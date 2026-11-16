extends SceneTree

const NavigationIntentScript := preload("res://scripts/ui/app_shell/navigation_intent.gd")
const WorldProjectionScript := preload("res://scripts/gameplay/runtime/g41_world_object_projection.gd")

class SettlementWriteFailure extends SaveAdapter:
	func save_json(data: Dictionary, path: String = M1_META_PROGRESS_PATH, normalize_meta_progress: bool = true) -> bool:
		if not data.get("run_receipts", {}).is_empty():
			last_error = "z2_scene_terminal_meta_failure"
			return false
		return super.save_json(data, path, normalize_meta_progress)

var failures: Array[String] = []
var checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	root.size = Vector2i(1280, 720)
	if OS.get_cmdline_user_args().has("--event-preview-only"):
		await _test_event_preview_button_conditions()
		print("Z2_EVENT_PREVIEW_SCENE checks=%d failures=%d" % [checks, failures.size()])
		for failure in failures:
			printerr("Z2_EVENT_PREVIEW_SCENE=FAIL: " + failure)
		quit(0 if failures.is_empty() else 1)
		return
	if OS.get_cmdline_user_args().has("--extract-recovery-only"):
		await _test_extract_confirmation_recovery()
		print("Z2_EXTRACT_RECOVERY checks=%d failures=%d" % [checks, failures.size()])
		for failure in failures:
			printerr("Z2_EXTRACT_RECOVERY=FAIL: " + failure)
		quit(0 if failures.is_empty() else 1)
		return
	if OS.get_cmdline_user_args().is_empty():
		await _test_sandbox_checkpoint_isolation()
	var packed := load("res://scenes/main/main.tscn") as PackedScene
	var main := packed.instantiate()
	root.add_child(main)
	var scene = main.get_node("RunScene")
	scene.set_process(false)
	await process_frame
	var runtime = scene.runtime_controller
	for arg in OS.get_cmdline_user_args():
		if arg == "--capture-error":
			runtime.persistence_error = {"ok": false, "reason": "capture_storage_failure"}
			scene._process(0.0)
			_check(_absolute_z(scene.persistence_controller.persistence_error_panel) > _absolute_z(scene.result_panel.get_node("ResultSummary")), "recovery overlay renders above terminal result text")
			await process_frame
			await RenderingServer.frame_post_draw
			var capture_path := OS.get_environment("TEMP").get_base_dir().path_join("persistence-error.png")
			var capture_error := root.get_texture().get_image().save_png(capture_path)
			print("Z2_ERROR_CAPTURE=%s path=%s" % [capture_error, capture_path])
			for failure in failures:
				printerr("Z2_ERROR_CAPTURE=FAIL: " + failure)
			_release_main(main)
			await process_frame
			quit(capture_error if failures.is_empty() else 1)
			return
		if arg.begins_with("--close-probe="):
			await _run_close_probe(scene, arg.get_slice("=", 1))
			return
	var parent_ready: bool = runtime.has_method("initialize_z2_session") and runtime.has_method("advance_idle_frame") and runtime.has_method("save_current_checkpoint")
	_check(parent_ready, "parent dependency: initialize_z2_session/advance_idle_frame/save_current_checkpoint")
	_check(not auto_accept_quit, "OS close must be intercepted until checkpoint succeeds")
	var started := _start_formal_fixture(scene)
	_check(bool(started.get("ok", false)), "real scene starts an admitted standard fixture")
	if bool(started.get("ok", false)):
		scene._show_run_screen()
		_test_modal_combat(scene)
		if parent_ready:
			main = await _test_combat_resume(main, scene)
			scene = main.get_node("RunScene")
			_test_idle_status(scene)
			main = await _test_disk_resume(main, scene)
			scene = main.get_node("RunScene")
			_test_retry_continue(scene)
			_test_close_failure(scene)
			await _test_saved_closes()
			main = await _test_pending_terminal(main)
			await _test_terminal_close()
	_release_main(main)
	await process_frame
	await _test_extract_confirmation_recovery()
	await _test_event_preview_button_conditions()
	print("Z2_RESUME_SCENE checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures:
		printerr("Z2_RESUME_SCENE=FAIL: " + failure)
	if failures.is_empty():
		print("Z2_RESUME_SCENE=PASS")
	quit(0 if failures.is_empty() else 1)


func _test_modal_combat(scene) -> void:
	var context = scene.run_context
	context.tutorial_popup.clear()
	var source := Vector2i(1, 1)
	context.truth_map.set_room_type(source, &"Monster")
	context.player_pos = source
	context.current_pos = source
	context.intel_map.reveal_cell(source, context.truth_map)
	scene.command_bus.room_resolver.enter_room(context)
	scene.player_controller.set_local_position(Vector2(0.5, 0.5))
	scene.in_run_runtime.sync_room(Vector2(0.5, 0.5))
	scene._apply_full_view_models()
	_check(scene.in_run_runtime.has_active_combat(), "real scene has live combat")
	if not scene.in_run_runtime.has_active_combat():
		return
	var timed_status: bool = context.get("temporary_statuses") is Array
	if timed_status:
		context.temporary_statuses = [{"id": "combat-modal-dot", "type": "temporary_debuff", "temporary_type": "dot", "phase": "active", "remaining": 10.0, "elapsed": 0.0, "dot_per_second": 10.0}]
		context.max_hp = 1000
		context.hp = 1000
	for mode in ["pause", "settings", "map", "tutorial", "blocking", "main", "deploy", "shell_settings", "hidden"]:
		scene._hide_runtime_popups()
		context.tutorial_popup.clear()
		scene._show_run_screen()
		match mode:
			"pause": scene._show_pause_panel()
			"settings":
				scene._show_pause_panel()
				scene._open_settings_from_pause()
			"map": scene._open_map_from_ui(&"z2_test")
			"tutorial": context.tutorial_popup = {"id": "z2-clock", "blocking": true}
			"blocking":
				scene._show_pause_panel()
				scene._request_abandon_from_pause()
			"main": scene._show_main_menu()
			"deploy": scene._show_deploy_shell(&"config")
			"shell_settings": scene._show_settings_shell()
			"hidden": scene.hide()
		var simulation = scene.in_run_runtime.simulation
		var tick_before: int = simulation.tick_index
		var position_before: Vector2 = simulation.player.pos
		var room_before: Vector2i = context.get_current_pos()
		var sequence_before: int = scene.command_bus.command_sequence
		var hp_before: int = context.hp
		var remaining_before: float = float(context.temporary_statuses[0].remaining) if timed_status else 0.0
		Input.action_press("move_right")
		scene._process(0.10)
		Input.action_release("move_right")
		_check(simulation.tick_index > tick_before, mode + ": battle clock advances")
		_check(not scene.in_run_runtime.paused, mode + ": modal must not pause simulation")
		_check(not scene.player_controller.input_enabled, mode + ": movement input blocked")
		_check(Vector2(simulation.player.pos).is_equal_approx(position_before), mode + ": held movement does not move player")
		_check(context.get_current_pos() == room_before and scene.command_bus.command_sequence == sequence_before, mode + ": no transition/gameplay command")
		var attack := InputEventAction.new()
		attack.action = &"attack"
		attack.pressed = true
		_check(not scene._handle_run_action_input(attack), mode + ": new attack input blocked")
		if timed_status:
			_check(is_equal_approx(float(context.temporary_statuses[0].remaining), remaining_before - 0.10), mode + ": battle status clock advances exactly once")
			_check(context.hp < hp_before, mode + ": battle DOT continues")
		scene.show()
		if mode == "settings":
			scene._cancel_runtime_settings()
		elif mode == "shell_settings":
			scene.ui_shell._hide_settings(false)
	context.tutorial_popup.clear()
	scene._hide_runtime_popups()
	scene._show_run_screen()
	_check(not scene.pause_status_label.text.contains("已暂停"), "menu copy must describe continuing exploration")


func _test_combat_resume(main: Node, scene) -> Node:
	var saved: Dictionary = scene.runtime_controller.save_current_checkpoint()
	_check(bool(saved.get("ok", false)), "real combat checkpoint saves")
	var combat_state: Dictionary = scene.in_run_runtime.export_transaction_state()
	var position: Vector2 = scene.in_run_runtime.get_player_local_position(Vector2.ZERO)
	var statuses: Array = scene.run_context.temporary_statuses.duplicate(true)
	_release_main(main)
	await process_frame
	var packed := load("res://scenes/main/main.tscn") as PackedScene
	var restored := packed.instantiate()
	root.add_child(restored)
	var scene2 = restored.get_node("RunScene")
	scene2.set_process(false)
	await process_frame
	_check(scene2.in_run_runtime.export_transaction_state() == combat_state, "combat disk restore retains actors, RNG, timers and encounter ordinals")
	_check(scene2.player_controller.get_local_position().is_equal_approx(position), "combat restore uses the bridge position")
	_check(scene2.run_context.temporary_statuses == statuses, "combat restore freezes offline status time")
	scene2.ui_shell.host_route_requested.emit(NavigationIntentScript.make_run(&"z2_combat_test", {"continue_active_run": true}))
	_check(scene2.screen_state == scene2.SCREEN_RUN and scene2.in_run_runtime.export_transaction_state() == combat_state, "actual continue route does not rerandomize restored combat")
	return restored


func _test_idle_status(scene) -> void:
	var context = scene.run_context
	context.truth_map.set_room_type(context.get_current_pos(), &"Normal")
	context.current_room_type = &"Normal"
	scene.in_run_runtime.sync_room(scene.player_controller.get_local_position())
	var statuses: Variant = context.get("temporary_statuses")
	_check(statuses is Array, "parent dependency: serializable temporary_statuses")
	if not statuses is Array:
		return
	context.temporary_statuses = [{"id": "z2-scene-dot", "type": "temporary_debuff", "temporary_type": "dot", "phase": "active", "remaining": 10.0, "elapsed": 0.0, "dot_per_second": 2.0}]
	var hp_before: int = context.hp
	scene._show_pause_panel()
	for _frame in range(3):
		scene._process(0.25)
	scene._hide_runtime_popups()
	scene._show_deploy_shell(&"config")
	var deploy = scene.ui_shell.get_deploy_page()
	deploy._show_cancel_modal()
	scene._process(0.25)
	_check(is_equal_approx(float(context.temporary_statuses[0].remaining), 9.0), "noncombat modals advance one second exactly once")
	_check(context.hp == hp_before - 2, "noncombat modals continue periodic HP damage")
	_check(deploy.modal_focus_stack.top_modal_id() == &"deploy_abandon", "background clock refresh preserves Deploy confirmation")
	var cancel := InputEventAction.new()
	cancel.action = &"cancel"
	cancel.pressed = true
	_check(scene._handle_cancel_input(cancel) and deploy.modal_focus_stack.depth() == 0 and scene.screen_state == scene.SCREEN_DEPLOY, "Deploy confirmation still cancels in place")
	scene._show_run_screen()


func _test_disk_resume(main: Node, scene) -> Node:
	var context = scene.run_context
	var position := Vector2(0.37, 0.63)
	scene.player_controller.set_local_position(position)
	# The production frame must capture position before its periodic full snapshot.
	for _frame in range(4):
		scene._process(0.25)
	var run_id := String(context.run_id)
	var hp: int = context.hp
	var statuses: Array = context.temporary_statuses.duplicate(true)
	_check(scene.runtime_controller.persistence_error.is_empty(), "periodic real checkpoint saved before reload")
	_release_main(main)
	await process_frame
	var packed := load("res://scenes/main/main.tscn") as PackedScene
	var restored := packed.instantiate()
	root.add_child(restored)
	var resumed = restored.get_node("RunScene")
	resumed.set_process(false)
	await process_frame
	_check(resumed.run_context.run_active and String(resumed.run_context.run_id) == run_id, "new scene restores active run from disk")
	_check(resumed.run_context.hp == hp and resumed.run_context.temporary_statuses == statuses, "disk restore does not advance offline HP or timers")
	_check(resumed.player_controller.get_local_position().is_equal_approx(position), "disk restore rehydrates noncombat local position")
	resumed.ui_shell.host_route_requested.emit(NavigationIntentScript.make_run(&"z2_scene_test", {"continue_active_run": true}))
	_check(resumed.screen_state == resumed.SCREEN_RUN and resumed.last_command_result.get("status") == &"continued_active_run", "actual shell continue route resumes restored run")
	_check(String(resumed.run_context.run_id) == run_id and resumed.player_controller.get_local_position().is_equal_approx(position), "continue does not start a new run or reset position")
	return restored


func _test_retry_continue(scene) -> void:
	var runtime = scene.runtime_controller
	runtime.checkpoint_writer = func(_snapshot: Dictionary) -> Dictionary:
		return {"ok": false, "status": "save_failed", "reason": "z2_scene_periodic_failure"}
	for _frame in range(4):
		scene._process(0.25)
	_check(not runtime.persistence_error.is_empty() and scene.persistence_controller.persistence_error_panel.is_visible_in_tree(), "ordinary autosave failure surfaces a blocking retry")
	var frozen: Array = scene.run_context.temporary_statuses.duplicate(true)
	scene._process(0.25)
	_check(scene.run_context.temporary_statuses == frozen, "storage failure freezes countdowns")
	runtime.checkpoint_writer = Callable()
	scene.persistence_controller.persistence_retry_button.pressed.emit()
	_check(runtime.persistence_error.is_empty() and not scene.persistence_controller.persistence_error_panel.visible, "successful retry dismisses error without exiting")
	var remaining: float = scene.run_context.temporary_statuses[0].remaining
	scene._process(0.25)
	_check(float(scene.run_context.temporary_statuses[0].remaining) < remaining, "successful retry resumes normal simulation")


func _test_close_failure(scene) -> void:
	var runtime = scene.runtime_controller
	var writes := [0]
	runtime.checkpoint_writer = func(_snapshot: Dictionary) -> Dictionary:
		writes[0] += 1
		return {"ok": false, "status": "save_failed", "reason": "z2_scene_disk_failure"}
	scene.notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	_check(writes[0] == 1, "normal OS close attempts a checkpoint")
	var error_panel: Variant = scene.persistence_controller.get("persistence_error_panel")
	_check(error_panel != null and error_panel.is_visible_in_tree(), "failed close remains alive with a visible retry panel")
	_check(error_panel != null and _absolute_z(error_panel) > _absolute_z(scene.pause_panel), "persistence error renders above existing runtime modals")
	var hp_before: int = scene.run_context.hp
	scene._process(2.0)
	_check(scene.run_context.hp == hp_before and writes[0] == 1, "persistence failure freezes time and future writes")
	_check(scene.ui_shell.has_signal("exit_requested"), "shell exit delegates to the same save-before-quit route")
	if scene.ui_shell.has_signal("exit_requested"):
		scene.ui_shell.exit_requested.emit()
		_check(writes[0] == 1, "repeated exit cannot write past persistence barrier")
	# A failed retry must keep the application open, without an automatic quit.
	var retry: Variant = scene.persistence_controller.get("persistence_retry_button")
	_check(retry is Button, "retry is an actionable visible button")
	if retry is Button:
		retry.pressed.emit()
		_check(error_panel.is_visible_in_tree() and not runtime.persistence_error.is_empty(), "failed retry remains visible and blocked")
	runtime.checkpoint_writer = Callable()


func _run_close_probe(scene, mode: String) -> void:
	var runtime = scene.runtime_controller
	if mode == "terminal":
		var started := _start_formal_fixture(scene)
		_check(bool(started.get("ok", false)), "terminal close fixture starts a new admitted run")
		scene.meta_progress_adapter.save_adapter = SettlementWriteFailure.new()
		var abandoned: Dictionary = scene.command_bus.dispatch(&"abandon_run", {"confirmed": true})
		if scene.run_context.phase == &"failure_salvage":
			abandoned = scene.command_bus.dispatch(&"confirm_failure_salvage", {"selected_instance_ids": []})
		_check(bool(abandoned.get("ok", false)), "terminal action commits its checkpoint before settlement")
		_check(not bool(runtime.last_meta_commit.get("ok", true)) and bool(runtime.last_meta_commit.get("durable_checkpoint", false)), "terminal meta failure retains durable checkpoint authority")
		_check(FileAccess.file_exists(runtime.checkpoint_service.checkpoint_path), "failed terminal remains on disk before exit")
		await _drain_terminal_audio(scene)
		scene.notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	else:
		_check(scene.run_context.run_active, mode + ": child restores the active disk checkpoint")
		scene.player_controller.set_local_position(Vector2(0.41, 0.59))
		if mode != "normal":
			runtime.checkpoint_writer = func(_snapshot: Dictionary) -> Dictionary:
				return {"ok": false, "status": "save_failed", "reason": "z2_child_failure"}
		if mode in ["os", "normal"]:
			scene.notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
		else:
			scene.ui_shell._show_exit_confirm()
			var accept := scene.ui_shell.exit_confirm_panel.get_node("ExitConfirmAccept") as Button
			accept.pressed.emit()
		if mode != "normal":
			_check(not runtime.persistence_error.is_empty() and scene.persistence_controller.persistence_error_panel.is_visible_in_tree(), mode + ": failed exit stays alive")
			runtime.checkpoint_writer = Callable()
			scene.persistence_controller.persistence_retry_button.pressed.emit()
	_check(runtime.persistence_error.is_empty(), mode + ": successful retry saves before quit")
	if failures.is_empty():
		print("Z2_RESUME_SCENE_CLOSE=PASS:" + mode)
		_release_main(scene.get_parent())
		process_frame.connect(func() -> void:
			printerr("Z2_RESUME_SCENE_CLOSE=FAIL: successful save did not quit")
			quit(1)
		, CONNECT_ONE_SHOT)
	else:
		for failure in failures:
			printerr("Z2_RESUME_SCENE_CLOSE=FAIL:" + failure)
		quit(1)


func _drain_terminal_audio(scene: Node) -> void:
	var streams: Array[WeakRef] = []
	for child in scene.player_feedback_service.get_children():
		if child is AudioStreamPlayer and child.stream != null:
			streams.append(weakref(child.stream))
			child.stop()
			child.stream = null
	var deadline := Time.get_ticks_msec() + 1000
	while streams.any(func(stream: WeakRef) -> bool: return stream.get_ref() != null) and Time.get_ticks_msec() < deadline:
		await process_frame
	if streams.any(func(stream: WeakRef) -> bool: return stream.get_ref() != null):
		failures.append("terminal audio teardown timed out")


func _test_saved_closes() -> void:
	for mode in ["os", "shell", "normal"]:
		var output: Array = []
		var args := PackedStringArray(["--headless", "--path", ProjectSettings.globalize_path("res://"), "--script", "res://tests/z2_resume_scene_runner.gd", "--quit-after", "1000", "--", "--close-probe=" + mode])
		var exit_code := OS.execute(OS.get_executable_path(), args, output, true)
		var transcript := "\n".join(output)
		print(transcript)
		_check(exit_code == 0 and transcript.contains("Z2_RESUME_SCENE_CLOSE=PASS:" + mode), mode + ": real process exits only after successful retry")
		var packed := load("res://scenes/main/main.tscn") as PackedScene
		var reopened := packed.instantiate()
		root.add_child(reopened)
		var scene = reopened.get_node("RunScene")
		scene.set_process(false)
		# A valid same-revision primary preserves current motion when retrying.
		var expected_position := Vector2(0.41, 0.59)
		_check(scene.run_context.run_active and scene.player_controller.get_local_position().is_equal_approx(expected_position), mode + ": close persists the authoritative position")
		_release_main(reopened)
		await process_frame


func _test_pending_terminal(main: Node) -> Node:
	_release_main(main)
	await process_frame
	var packed := load("res://scenes/main/main.tscn") as PackedScene
	var interrupted := packed.instantiate()
	root.add_child(interrupted)
	var scene = interrupted.get_node("RunScene")
	scene.set_process(false)
	await process_frame
	# Simulate interruption after durable terminal checkpoint, before meta settlement.
	scene.command_bus.result_available.disconnect(Callable(scene.runtime_controller, "_on_terminal_result_available"))
	var abandoned: Dictionary = scene.command_bus.dispatch(&"abandon_run", {"confirmed": true, "source": "z2_terminal_cutpoint"})
	if scene.run_context.phase == &"failure_salvage":
		abandoned = scene.command_bus.dispatch(&"confirm_failure_salvage", {"selected_instance_ids": []})
	_check(bool(abandoned.get("ok", false)), "terminal cutpoint persists pending result")
	var result_id := String(scene.run_context.result_snapshot.get("result_id", ""))
	_release_main(interrupted)
	await process_frame
	var restored := packed.instantiate()
	root.add_child(restored)
	var resumed = restored.get_node("RunScene")
	resumed.set_process(false)
	await process_frame
	_check(not resumed.run_context.run_active and String(resumed.run_context.result_snapshot.get("result_id", "")) == result_id, "pending terminal restores the same result")
	_check(resumed.result_panel.is_visible_in_tree() and resumed._runtime_modal_is_top(&"result"), "pending terminal is presented after real scene bindings")
	_check(resumed.result_panel.normal_exit_allowed(), "restored terminal commits through runtime authority")
	return restored


func _test_terminal_close() -> void:
	var output: Array = []
	var args := PackedStringArray(["--headless", "--path", ProjectSettings.globalize_path("res://"), "--script", "res://tests/z2_resume_scene_runner.gd", "--quit-after", "1000", "--", "--close-probe=terminal"])
	var exit_code := OS.execute(OS.get_executable_path(), args, output, true)
	var transcript := "\n".join(output)
	print(transcript)
	_check(exit_code == 0 and transcript.contains("Z2_RESUME_SCENE_CLOSE=PASS:terminal"), "normal close keeps a failed terminal settlement durable")
	var packed := load("res://scenes/main/main.tscn") as PackedScene
	var reopened := packed.instantiate()
	root.add_child(reopened)
	var scene = reopened.get_node("RunScene")
	scene.set_process(false)
	await process_frame
	_check(not scene.run_context.run_active and not scene.run_context.result_snapshot.is_empty() and scene.result_panel.is_visible_in_tree(), "failed terminal survives normal exit and reappears after restart")
	_check(scene.result_panel.normal_exit_allowed(), "restored terminal retries settlement without discarding admission")
	_release_main(reopened)
	await process_frame


func _absolute_z(control: CanvasItem) -> int:
	var result := control.z_index
	if control.z_as_relative and control.get_parent() is CanvasItem:
		result += _absolute_z(control.get_parent())
	return result


func _release_main(main: Node) -> void:
	var scene = main.get_node("RunScene")
	var runtime = scene.runtime_controller
	main.queue_free()
	# Release the existing runtime/bus cycle after the view is removed.
	runtime.in_run_runtime.bind(null)
	runtime.command_bus.bind_runtime_controller(null)


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)

func _test_sandbox_checkpoint_isolation() -> void:
	var debug_setting: Variant = ProjectSettings.get_setting(DebugGate.ENABLE_SETTING, false)
	ProjectSettings.set_setting(DebugGate.ENABLE_SETTING, true)
	var packed := load("res://scenes/main/main.tscn") as PackedScene
	var main := packed.instantiate()
	root.add_child(main)
	var scene = main.get_node("RunScene")
	scene.set_process(false)
	await process_frame
	var runtime = scene.runtime_controller
	var before: Dictionary = runtime.capture_authoritative_state()
	var service: Variant = runtime.checkpoint_service
	var profile_id := str(scene.save_manager.active_profile_id)
	var before_hash := DebugSandboxSession.profile_storage_hash(profile_id)
	var intent := NavigationIntentScript.make_run(&"z2_sandbox_check", {"debug_test_room": true, "route_mode": &"demo_run", "scenario_id": &"demo_7x7"})
	scene.debug_panel_controller.start_test_room_if_requested(intent, Callable(scene, "_run_start_asset_admission"), Callable(scene, "_show_run_screen"), Callable(scene, "_show_main_menu"))
	_check(scene.debug_panel_controller.is_test_room_active() and scene.run_context.run_active, "debug sandbox enters its playable fixture")
	_check(runtime.checkpoint_service == null and scene.save_manager.active_profile_id == "dev_sandbox", "debug sandbox suspends production checkpoint binding")
	var abandoned: Dictionary = scene.command_bus.dispatch(&"abandon_run", {"confirmed": true})
	_check(bool(abandoned.get("ok")), "debug sandbox can finish independently")
	var ended: Dictionary = scene.debug_panel_controller.end_test_room_if_ready()
	_check(bool(ended.get("ok")) and runtime.checkpoint_service == service and scene.save_manager.active_profile_id == profile_id, "sandbox exit restores original profile and checkpoint binding")
	_check(runtime.capture_authoritative_state() == before, "sandbox exit restores complete production runtime")
	_check(DebugSandboxSession.profile_storage_hash(profile_id) == before_hash, "sandbox keeps production profile files byte-identical")
	_release_main(main)
	await process_frame
	ProjectSettings.set_setting(DebugGate.ENABLE_SETTING, debug_setting)


func _test_extract_confirmation_recovery() -> void:
	for recovery_case in ["restart", "confirm_write_failure", "cancel_write_failure"]:
		print("Z2_EXTRACT_RECOVERY_CASE=" + recovery_case)
		var main := await _make_extract_confirmation_scene(recovery_case)
		var scene = main.get_node("RunScene")
		var run_id := String(scene.run_context.run_id)
		var position: Vector2 = scene.player_controller.get_local_position()
		var receipt_count: int = scene.meta_progress_adapter.data.get("run_receipts", {}).size()
		if recovery_case == "restart":
			_release_main(main)
			await process_frame
			main = (load("res://scenes/main/main.tscn") as PackedScene).instantiate()
			root.add_child(main)
			scene = main.get_node("RunScene")
			scene.set_process(false)
			await process_frame
			_check(scene.screen_state == scene.SCREEN_MAIN_MENU and scene.run_context.phase == &"confirm_extract", "extract restart retains pending phase on main menu")
			scene.ui_shell.host_route_requested.emit(NavigationIntentScript.make_run(&"z2_extract_resume", {"continue_active_run": true}))
		else:
			var writes := [0]
			scene.runtime_controller.checkpoint_writer = func(_snapshot: Dictionary) -> Dictionary:
				writes[0] += 1
				return {"ok": false, "status": "save_failed", "reason": "extract_confirmation_write_failure"}
			if recovery_case == "confirm_write_failure":
				scene.extract_confirm_button.pressed.emit()
			else:
				scene.extract_cancel_button.pressed.emit()
			await process_frame
			_check(writes[0] == 1 and not scene.runtime_controller.persistence_error.is_empty(), recovery_case + ": actual command checkpoint fails")
			_check(scene.run_context.phase == &"confirm_extract" and scene.run_context.run_active and scene.run_context.result_snapshot.is_empty(), recovery_case + ": rollback retains pending confirmation without terminal")
			_check(scene.persistence_controller.persistence_error_panel.is_visible_in_tree(), recovery_case + ": retry action is visible")
			scene.runtime_controller.checkpoint_writer = Callable()
			scene.persistence_controller.persistence_retry_button.pressed.emit()
		await process_frame
		await process_frame
		_check(scene.runtime_controller.persistence_error.is_empty(), recovery_case + ": storage recovery succeeds")
		_check(scene.screen_state == scene.SCREEN_RUN and scene.run_context.run_active and String(scene.run_context.run_id) == run_id and scene.run_context.phase == &"confirm_extract", recovery_case + ": recovery preserves the same pending run")
		_check(scene.run_context.result_snapshot.is_empty() and scene.meta_progress_adapter.data.get("run_receipts", {}).size() == receipt_count, recovery_case + ": recovery never auto-extracts or settles")
		_check(scene.extract_panel.is_visible_in_tree() and scene._runtime_modal_is_top(&"extract_confirm") and scene.modal_controller.depth() == 1, recovery_case + ": pending confirmation is restored exactly once")
		_check(root.gui_get_focus_owner() == scene.extract_cancel_button and scene._gameplay_input_blocked(), recovery_case + ": restored confirmation owns safe focus and gameplay input")
		_check(scene.player_controller.get_local_position().is_equal_approx(position), recovery_case + ": restored local position is preserved")
		_check(scene.pending_exit_interaction_authorized and scene._exit_interaction_authorization_matches() and scene.pending_exit_interaction_position.is_equal_approx(position), recovery_case + ": opening permission is rebuilt for the current exit position")
		if recovery_case == "restart":
			# Re-entering Run is idempotent, and stale opening permission must not
			# authorize confirmation after the current player position changes.
			scene.ui_shell.host_route_requested.emit(NavigationIntentScript.make_run(&"z2_extract_repeat", {"continue_active_run": true}))
			await process_frame
			_check(scene.modal_controller.depth() == 1 and scene._runtime_modal_is_top(&"extract_confirm"), "extract repeat continue keeps one confirmation")
			var far_position := Vector2(0.05, 0.05)
			scene.player_controller.set_local_position(far_position)
			far_position = scene.player_controller.get_local_position()
			scene._show_run_screen()
			await process_frame
			_check(not scene.pending_exit_interaction_authorized and scene.player_controller.get_local_position().is_equal_approx(far_position), "extract recovery clears stale permission without moving player to exit")
			scene.extract_confirm_button.pressed.emit()
			_check(scene.run_context.run_active and scene.run_context.phase == &"confirm_extract" and scene.run_context.result_snapshot.is_empty(), "extract stale confirmation cannot bypass current proximity")
		if recovery_case == "confirm_write_failure":
			scene.extract_confirm_button.pressed.emit()
			_check(not scene.run_context.run_active and scene.run_context.extracted and String(scene.run_context.run_id) == run_id, "extract recovered confirm completes the same run")
			var receipts: Dictionary = scene.meta_progress_adapter.data.get("run_receipts", {}).duplicate(true)
			var result_id := String(scene.run_context.result_snapshot.get("result_id", ""))
			_check(receipts.size() == receipt_count + 1 and receipts.has(run_id) and not result_id.is_empty(), "extract recovered confirm settles exactly one receipt")
			scene.extract_confirm_button.pressed.emit()
			_check(scene.meta_progress_adapter.data.get("run_receipts", {}) == receipts and String(scene.run_context.result_snapshot.get("result_id", "")) == result_id, "extract repeated confirm cannot duplicate settlement")
		else:
			scene.extract_cancel_button.pressed.emit()
			_check(scene.run_context.run_active and scene.run_context.phase == &"running" and String(scene.run_context.run_id) == run_id, recovery_case + ": recovered cancel returns the same run to running")
			_check(scene.modal_controller.depth() == 0 and not scene.extract_panel.visible and scene.meta_progress_adapter.data.get("run_receipts", {}).size() == receipt_count, recovery_case + ": cancel closes confirmation without settlement")
		# Finish only for fixture isolation; exercise the normal cancel above first.
		if scene.run_context.run_active:
			scene.command_bus.dispatch(&"abandon_run", {"confirmed": true})
			if scene.run_context.phase == &"failure_salvage":
				scene.command_bus.dispatch(&"confirm_failure_salvage", {"selected_instance_ids": []})
		await _drain_terminal_audio(scene)
		_release_main(main)
		await process_frame
		await process_frame


func _make_extract_confirmation_scene(label: String) -> Node:
	var main := (load("res://scenes/main/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	var scene = main.get_node("RunScene")
	scene.set_process(false)
	await process_frame
	var started := _start_formal_fixture(scene)
	_check(bool(started.get("ok", false)), label + ": admitted exit fixture starts")
	scene.run_context.tutorial_popup.clear()
	scene._show_run_screen()
	var exits: Array[Vector2i] = scene.run_context.truth_map.get_exits()
	_check(not exits.is_empty(), label + ": real map contains an exit")
	if exits.is_empty():
		return main
	var exit_room := exits[0]
	scene.run_context.player_pos = exit_room
	scene.run_context.current_pos = exit_room
	scene.run_context.intel_map.reveal_cell(exit_room, scene.run_context.truth_map)
	scene.command_bus.room_resolver.enter_room(scene.run_context)
	scene._apply_full_view_models()
	scene.player_controller.set_local_position(WorldProjectionScript.EXIT_LOCAL_POS)
	scene._process(0.0)
	var extract_button := scene.run_surface.action_buttons.get(&"extract") as Button
	_check(extract_button != null and not extract_button.disabled, label + ": production extraction entry is actionable")
	if extract_button != null:
		extract_button.pressed.emit()
	await process_frame
	_check(scene.run_context.phase == &"confirm_extract" and scene._runtime_modal_is_top(&"extract_confirm") and scene.runtime_controller.persistence_error.is_empty(), label + ": actual request saves and opens confirmation")
	return main


func _test_event_preview_button_conditions() -> void:
	print("Z2_EVENT_PREVIEW_SCENE_CASE=e10_buy_patch")
	var main := (load("res://scenes/main/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	var scene = main.get_node("RunScene")
	scene.set_process(false)
	await process_frame
	var runtime = scene.runtime_controller
	var started := _start_formal_fixture(scene)
	_check(bool(started.get("ok", false)), "event UI fixture starts an admitted run")
	var context = scene.run_context
	context.tutorial_popup.clear()
	var event_room := Vector2i(5, 1)
	context.truth_map.set_room_type(event_room, &"Event")
	context.player_pos = event_room
	context.current_pos = event_room
	context.z1_event_rooms[context.cell_key(event_room)] = {"event_type": &"z1_event_e10", "completed": false}
	context.pressure = 40
	context.asset_ledger.add_currency(&"black_coin", 100)
	context.intel_map.reveal_cell(event_room, context.truth_map)
	scene.command_bus.room_resolver.enter_room(context)
	_check(scene.command_bus.dispatch(&"select_event_option", {"option_id": &"prepare"}).get("ok", false), "event UI fixture prepares its real four-coin quote")
	scene._show_run_screen()
	var projection: Dictionary = WorldProjectionScript.build(context.get_status_snapshot()).get("event_room", {})
	scene.player_controller.set_local_position(Vector2(projection.get("interaction_pos", WorldProjectionScript.EVENT_LOCAL_POS)))
	scene._process(0.0)
	var selected: Array[Dictionary] = []
	scene.z2_event_adapter.choice_requested.connect(func(_request: Dictionary, option: Dictionary) -> void: selected.append(option.duplicate(true)))
	scene._on_world_context_action_requested(&"event_open", {})
	await process_frame
	var old_button := _event_option_button(scene, 0)
	var old_cost := old_button.find_child("OptionCost", true, false) as Label if old_button != null else null
	_check(scene._runtime_modal_is_top(&"event") and old_button != null and not old_button.disabled and old_button.accessibility_name.contains("急救贴"), "actual Event e10 panel exposes the purchase button")
	_check(old_cost != null and old_cost.is_visible_in_tree() and old_cost.text.contains("4"), "actual initial event option displays four-coin cost")
	var previous_revision: int = runtime.transaction_revision
	var changed: Dictionary = runtime.execute_atomic_operation(&"scene_event_pressure_change", {}, func() -> Dictionary:
		context.pressure = 39
		return {"ok": true}
	)
	_check(bool(changed.get("ok", false)) and context.pressure == 39 and runtime.transaction_revision > previous_revision, "pressure changes through a committed durable operation")
	_check(is_instance_valid(old_cost) and old_cost.text.contains("4"), "already-open purchase still carries the displayed four-coin quote")
	var before: Dictionary = runtime.capture_authoritative_state()
	var disk_hash := FileAccess.get_sha256(runtime.checkpoint_service.checkpoint_path)
	if old_button != null:
		old_button.pressed.emit()
	await process_frame
	_check(selected.size() == 1 and str(selected[0].get("payload", {}).get("expected_conditions", "")).length() == 64, "actual old button sends its displayed condition token")
	_check(str(scene.last_command_result.get("reason", "")) == "stale_preview", "actual old button rejects changed price with stale_preview")
	_check(runtime.capture_authoritative_state() == before, "stale event button cannot spend or mutate authority")
	_check(FileAccess.get_sha256(runtime.checkpoint_service.checkpoint_path) == disk_hash, "stale event button cannot write a checkpoint")
	# Current Z2 quotes are refreshed by a separate, real prepare action.
	var prepare_button := _event_option_button(scene, 0)
	_check(prepare_button != null and not prepare_button.disabled and prepare_button.accessibility_name.contains("查看服务"), "stale quote exposes the real refresh action")
	if prepare_button != null:
		prepare_button.pressed.emit()
	await process_frame
	var refreshed_button := _event_option_button(scene, 0)
	var refreshed_cost := refreshed_button.find_child("OptionCost", true, false) as Label if refreshed_button != null else null
	_check(scene._runtime_modal_is_top(&"event") and refreshed_button != null and not refreshed_button.disabled and refreshed_button.accessibility_name.contains("急救贴") and refreshed_cost != null and refreshed_cost.is_visible_in_tree() and refreshed_cost.text.contains("9"), "reopened event panel displays the new nine-coin purchase")
	var coins_before: int = context.asset_ledger.get_currency(&"black_coin")
	var items_before: int = context.asset_ledger.item_instances.size()
	var receipts_before: int = runtime.action_receipts.size()
	if refreshed_button != null and refreshed_button.accessibility_name.contains("急救贴"):
		refreshed_button.pressed.emit()
	await process_frame
	_check(selected.size() == 3 and selected[2].get("payload", {}).get("expected_conditions", "") != selected[0].get("payload", {}).get("expected_conditions", ""), "reopened actual button sends a refreshed condition token after the separate quote refresh")
	_check(bool(scene.last_command_result.get("ok", false)) and context.asset_ledger.get_currency(&"black_coin") == coins_before - 9, "fresh actual purchase pays exactly nine coins")
	_check(context.asset_ledger.item_instances.size() == items_before + 1 and runtime.action_receipts.size() == receipts_before + 1, "fresh actual purchase grants one item and one committed receipt")
	scene.command_bus.dispatch(&"abandon_run", {"confirmed": true})
	if scene.run_context.phase == &"failure_salvage":
		scene.command_bus.dispatch(&"confirm_failure_salvage", {"selected_instance_ids": []})
	await _drain_terminal_audio(scene)
	_release_main(main)
	await process_frame
	await process_frame


func _start_formal_fixture(scene) -> Dictionary:
	var meta = scene.meta_progress_adapter
	# Eligibility setup only; the separate new-player journey owns natural teaching input.
	if not meta.data.get("tutorial_completed", false):
		_check(meta.begin_tutorial_training().get("ok", false), "fixture teaching eligibility begins")
		_check(meta.purchase_tutorial_flag().get("ok", false), "fixture teaching purchase persists")
		var completed: Dictionary = meta._apply_tutorial_settlement({"mode": "tutorial", "outcome": "Training Complete", "settlement": {"outcome": "success"}}, "resume-fixture-teaching")
		_check(completed.get("ok", false), "fixture legal teaching qualification persists")
		if not completed.get("ok", false):
			return completed
	var config := RunStartConfig.default_config()
	config.merge({"map_config_id": "classic_7x7_simple", "difficulty": &"simple", "seed_value": 71}, true)
	config.selected_objective_id = M7ContentCatalog.commission_offer_candidates("classic_7x7_simple", 0)[0].id
	return scene.command_bus.dispatch(&"start_standard_run", {"run_start_config": config})


func _event_option_button(scene, index: int) -> Button:
	var dialogue: Control = scene.z2_event_adapter.dialogue
	# Advance the delivered dialogue through its real click signal, then use its button.
	for advance in range(16):
		if dialogue.get_node("%ChoicesFrame").visible:
			break
		var click := InputEventMouseButton.new()
		click.button_index = MOUSE_BUTTON_LEFT
		dialogue.get_node("%DialogueText").gui_input.emit(click)
	return dialogue.find_child("Option_%d" % index, true, false) as Button
