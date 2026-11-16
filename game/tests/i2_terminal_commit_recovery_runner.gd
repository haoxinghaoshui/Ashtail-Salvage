extends SceneTree

const MetaProgressAdapterScript := preload("res://scripts/core/save/meta_progress_adapter.gd")
const ResultPanelScene := preload("res://scenes/ui/result/result_panel.tscn")
const RunRuntimeControllerScript := preload("res://scripts/core/run/run_runtime_controller.gd")
const RunSceneResultControllerScript := preload("res://scripts/core/run/run_scene_result_controller.gd")
const ResultPresentationModelScript := preload("res://scripts/ui/result/result_presentation_model.gd")

class TerminalWriteFailure extends SaveAdapter:
	var target_path := ""
	var target_run_id := ""
	var blocked := true

	func save_json(data: Dictionary, path: String = M1_META_PROGRESS_PATH, normalize_meta_progress: bool = true) -> bool:
		if blocked and path == target_path and data.get("run_receipts", {}).has(target_run_id):
			last_error = "i2_terminal_meta_write_failure"
			return false
		return super.save_json(data, path, normalize_meta_progress)

var failures: Array[String] = []
var blocker_path := "user://i2_terminal_commit_recovery/not_a_directory"
var blocked_save_path := blocker_path + "/meta_progress.json"
var result_signal_count: int = 0
var retry_request_count: int = 0
var discard_request_count: int = 0
var production_retry_command_count: int = 0
var production_discard_command_count: int = 0
var production_result_signal_count: int = 0
var production_result_signals: Array[Dictionary] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_cleanup()
	_validate_run_id_compatibility()
	var recovery_fixture := _validate_failed_commit_and_retry()
	await _validate_result_panel_guards(recovery_fixture)
	_validate_legacy_discard(recovery_fixture)
	_cleanup()
	await _validate_production_run_scene_guards()
	_cleanup()
	if failures.is_empty():
		print("I2_TERMINAL_COMMIT_RECOVERY=PASS nonce=128bit legacy_ids=compatible save_failure=rollback retry=same_snapshot result_body=frozen_across_retry duplicate=idempotent result_signals=unchanged exits=guarded discard=legacy_only durable_terminal=retry_required restart=settled")
		quit(0)
		return
	for failure in failures:
		printerr("I2_TERMINAL_COMMIT_RECOVERY=FAIL:%s" % failure)
	quit(1)


func _validate_run_id_compatibility() -> void:
	var seen: Dictionary = {}
	for index in range(12):
		var controller = RunRuntimeControllerScript.new()
		_require(bool(controller.start_demo_run(null).get("ok", false)), "run-id fixture %d did not start" % index)
		var run_id := String(controller.context.run_id)
		_require(not seen.has(run_id), "new controllers generated duplicate run id: %s" % run_id)
		seen[run_id] = true
		var pieces := run_id.split("_")
		var nonce := String(pieces[pieces.size() - 1]) if not pieces.is_empty() else ""
		_require(nonce.length() == 32 and _is_lower_hex(nonce), "run id nonce is not 128-bit hex: %s" % run_id)
		_release_runtime(controller)

	var legacy_id := "demo_1234_1:Abandoned:0"
	var legacy_adapter = MetaProgressAdapterScript.new()
	legacy_adapter.data = legacy_adapter.save_adapter.default_meta_progress()
	legacy_adapter.data["committed_result_ids"] = [legacy_id]
	var legacy_duplicate := legacy_adapter.apply_settlement({
		"result_id": legacy_id,
		"run_id": "demo_1234_1",
		"outcome": "Abandoned",
		"turn": 0,
		"settlement": {"outcome": &"abandon", "finalized": true},
	})
	_require(str(legacy_duplicate.get("status", "")) == "duplicate_ignored", "legacy result id was not preserved as opaque id")
	_require((legacy_adapter.data.get("committed_result_ids", []) as Array) == [legacy_id], "legacy committed id was migrated or rewritten")


func _validate_failed_commit_and_retry() -> Dictionary:
	var base_dir := blocker_path.get_base_dir()
	_require(DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(base_dir)) == OK, "could not create recovery fixture directory")
	var blocker := FileAccess.open(blocker_path, FileAccess.WRITE)
	_require(blocker != null, "could not create deterministic save blocker")
	if blocker == null:
		return {}
	blocker.store_string("this file intentionally blocks the settlement save parent")
	blocker.close()

	var adapter = MetaProgressAdapterScript.new()
	adapter.set_active_profile_path(blocked_save_path, "i2_terminal_commit_recovery")
	var before_data: Dictionary = adapter.data.duplicate(true)
	var controller = RunRuntimeControllerScript.new()
	controller.bind_meta_progress_adapter(adapter)
	controller.command_bus.result_available.connect(func(_snapshot: Dictionary) -> void: result_signal_count += 1)
	_require(bool(controller.start_demo_run(null).get("ok", false)), "save-recovery fixture did not start")
	controller.context.asset_ledger.create_item_instance({
		"instance_id": "recovery_keep",
		"item_id": "recovery_keep",
		"display_name": "恢复测试样本",
		"short_description": "用于验证保存失败恢复。",
		"item_type": &"collectible",
		"rarity": &"tier_4",
		"weight": 2,
		"base_value": 30,
		"can_store": true,
	}, RunAssetLedger.LOCATION_INVENTORY)
	controller.context.asset_ledger.add_currency(RunAssetLedger.CURRENCY_BLACK, 17, "i2_recovery")
	_require(bool(controller.debug_force_extract().get("ok", false)), "save-recovery fixture did not reach terminal result")
	var terminal_snapshot: Dictionary = controller.context.result_snapshot.duplicate(true)
	controller.command_bus.result_available.emit(terminal_snapshot)
	_require(result_signal_count == 1, "initial terminal result signal count mismatch")
	_require(str(controller.last_meta_commit.get("status", "")) == "save_failed", "deterministic settlement save failure did not occur")
	_require(adapter.data == before_data, "save failure did not roll back complete meta data")
	_require(not (terminal_snapshot.get("result_id", "") in (adapter.data.get("committed_result_ids", []) as Array)), "failed save retained committed result id")
	var failed_display := RunSceneResultControllerScript.build_result_display_snapshot(terminal_snapshot, adapter.get_summary(), controller.last_meta_commit)
	_require(StringName(failed_display.get("persistence_state", &"")) == &"save_failed", "save failure display state was normalized incorrectly")
	_require(not bool(failed_display.get("normal_exit_allowed", true)), "save failure allowed normal exit")
	_require(bool(failed_display.get("retry_save_allowed", false)), "save failure did not expose retry")

	var still_blocked := controller.retry_terminal_commit()
	_require(str(still_blocked.get("status", "")) == "save_failed", "retry while blocked returned wrong status")
	_require(result_signal_count == 1, "retry re-emitted terminal result signal")
	_require(adapter.data == before_data, "blocked retry changed meta data")

	_require(DirAccess.remove_absolute(ProjectSettings.globalize_path(blocker_path)) == OK, "could not remove deterministic save blocker")
	var recovered := controller.retry_terminal_commit()
	_require(bool(recovered.get("ok", false)) and str(recovered.get("status", "")) == "committed", "same-snapshot retry did not recover")
	_require(result_signal_count == 1, "successful retry re-emitted terminal result signal")
	var committed_summary: Dictionary = adapter.get_summary()
	_require(int(committed_summary.get("run_count", 0)) == int(before_data.get("run_count", 0)) + 1, "recovered retry run count mismatch")
	_require(int(committed_summary.get("history_record_count", 0)) == (before_data.get("history_records", []) as Array).size() + 1, "recovered retry history count mismatch")
	_require(_warehouse_has(committed_summary.get("warehouse_items", []), "recovery_keep"), "recovered retry lost warehouse item")
	var committed_data: Dictionary = adapter.data.duplicate(true)
	var duplicate := controller.retry_terminal_commit()
	_require(str(duplicate.get("status", "")) == "duplicate_ignored", "second retry was not idempotent")
	_require(result_signal_count == 1, "duplicate retry re-emitted terminal result signal")
	_require(adapter.data == committed_data, "duplicate retry changed meta data")
	_release_runtime(controller)
	return {
		"snapshot": terminal_snapshot,
		"summary": adapter.get_summary(),
	}


func _validate_result_panel_guards(fixture: Dictionary) -> void:
	if fixture.is_empty():
		return
	var panel := ResultPanelScene.instantiate() as ResultPanel
	root.add_child(panel)
	await process_frame
	panel.retry_save_requested.connect(func() -> void: retry_request_count += 1)
	panel.discard_unsaved_result_requested.connect(func() -> void: discard_request_count += 1)
	var snapshot: Dictionary = fixture.get("snapshot", {})
	var display := RunSceneResultControllerScript.build_result_display_snapshot(snapshot, fixture.get("summary", {}), {"ok": false, "status": &"save_failed"})
	panel.show_summary(display)
	await process_frame
	_require(not panel.normal_exit_allowed(), "result panel allowed normal exit while unsaved")
	_require(panel.retry_save_allowed(), "result panel did not expose save retry")
	_require(panel.discard_unsaved_allowed(), "result panel did not expose guarded discard")
	_require(not panel.return_deploy_button.visible and panel.return_deploy_button.disabled, "unsaved result exposed deploy exit")
	_require(not panel.return_main_button.visible and panel.return_main_button.disabled, "unsaved result exposed main-menu exit")
	_require(panel.retry_save_button.is_visible_in_tree() and not panel.retry_save_button.disabled, "unsaved result retry action is not reachable")
	_require(panel.retry_save_button.focus_mode == Control.FOCUS_ALL, "unsaved result retry action is not keyboard focusable")
	_require(panel.discard_unsaved_button.is_visible_in_tree() and not panel.discard_unsaved_button.disabled, "unsaved result discard action is not reachable")
	_require(panel.discard_unsaved_button.focus_mode == Control.FOCUS_ALL, "unsaved result discard action is not keyboard focusable")
	panel.retry_save_button.grab_focus()
	await process_frame
	_require(root.gui_get_focus_owner() == panel.retry_save_button, "unsaved result retry action could not take focus")
	panel.retry_save_button.pressed.emit()
	panel.retry_save_button.pressed.emit()
	_require(retry_request_count == 1, "result panel emitted duplicate retry requests")
	panel.mark_retry_complete()
	panel.call("_request_discard_unsaved_result")
	_require(panel.discard_unsaved_confirmation_step == 1 and discard_request_count == 0, "first discard confirmation escaped or did not arm")
	panel.call("_request_discard_unsaved_result")
	panel.call("_request_discard_unsaved_result")
	_require(discard_request_count == 1, "discard escape did not require exactly two confirmations")

	var committed_display := RunSceneResultControllerScript.build_result_display_snapshot(snapshot, fixture.get("summary", {}), {"ok": true, "status": &"committed"})
	panel.show_summary(committed_display)
	await process_frame
	_require(panel.normal_exit_allowed(), "legacy-style committed snapshot did not restore normal exit")
	_require(panel.return_deploy_button.is_visible_in_tree() and not panel.return_deploy_button.disabled, "committed result deploy exit is not reachable")
	_require(panel.return_main_button.is_visible_in_tree() and not panel.return_main_button.disabled, "committed result main-menu exit is not reachable")
	_require(panel.return_deploy_button.focus_mode == Control.FOCUS_ALL and panel.return_main_button.focus_mode == Control.FOCUS_ALL, "committed result exit actions are not keyboard focusable")
	_require(not panel.retry_save_button.visible and panel.retry_save_button.disabled, "committed result retained retry action")
	_require(not panel.discard_unsaved_button.visible and panel.discard_unsaved_button.disabled, "committed result retained discard action")
	var discarded_display := RunSceneResultControllerScript.build_result_display_snapshot(
		snapshot,
		fixture.get("summary", {}),
		{"ok": false, "status": &"discarded_unsaved", "committed": false, "discarded": true}
	)
	var discarded_model := ResultPresentationModelScript.build(discarded_display)
	_require(
		bool(discarded_model.get("normal_exit_allowed", false))
		and not bool(discarded_model.get("retry_save_allowed", true))
		and not bool(discarded_model.get("discard_unsaved_allowed", true)),
		"explicit unsaved discard did not project one-way normal exit"
	)
	_require(
		String(discarded_model.get("persistence_text", "")).contains("不会写入档案"),
		"explicit unsaved discard retained misleading retry copy"
	)
	panel.return_deploy_button.grab_focus()
	await process_frame
	_require(root.gui_get_focus_owner() == panel.return_deploy_button, "committed result primary exit could not take focus")
	panel.queue_free()
	await process_frame


func _validate_legacy_discard(fixture: Dictionary) -> void:
	if fixture.is_empty():
		return
	var adapter = MetaProgressAdapterScript.new()
	adapter.set_active_profile_path(blocked_save_path, "i2_terminal_legacy_discard")
	var runtime = RunRuntimeControllerScript.new()
	runtime.bind_meta_progress_adapter(adapter)
	runtime.context.result_snapshot = fixture.snapshot.duplicate(true)
	runtime.last_meta_commit = {"ok": false, "status": &"save_failed", "committed": false}
	var before: Dictionary = adapter.data.duplicate(true)
	_require(runtime.checkpoint_service == null, "legacy discard fixture unexpectedly acquired durable authority")
	_require(str(runtime.discard_unsaved_terminal_commit(false).get("status", "")) == "discard_confirmation_required", "legacy discard did not require explicit confirmation")
	var discarded: Dictionary = runtime.discard_unsaved_terminal_commit(true)
	_require(bool(discarded.get("ok", false)) and str(discarded.get("status", "")) == "discarded_unsaved", "confirmed legacy discard did not unlock")
	_require(adapter.data == before, "legacy discard wrote meta progress")
	_require(str(runtime.retry_terminal_commit().get("status", "")) == "terminal_commit_discarded", "legacy discard allowed a later save retry")
	_release_runtime(runtime)


func _validate_production_run_scene_guards() -> void:
	var packed := load("res://scenes/main/main.tscn") as PackedScene
	_require(packed != null, "production Main scene could not be loaded for result recovery")
	if packed == null:
		return
	var main := packed.instantiate()
	root.add_child(main)
	var run_scene = main.get_node("RunScene")
	run_scene.set_process(false)
	await process_frame
	var runtime = run_scene.runtime_controller
	var adapter = run_scene.meta_progress_adapter
	var manager = run_scene.save_manager
	# Retain the scene's adapter identity, then explicitly bind all persistence
	# authorities to a new Z2 profile before admission. Never transplant a result.
	_require(bool(manager.switch_profile("i2_terminal_%d" % Time.get_ticks_usec()).get("ok", false)), "production profile selection failed")
	_require(bool(manager.configure_meta_adapter(adapter).get("ok", false)), "production meta profile binding failed")
	_require(bool(adapter.initialize_z2_profile(RunRuntimeControllerScript.Z2_CONTENT_VERSION).get("ok", false)), "production Z2 profile initialization failed")
	_require(bool(runtime.initialize_z2_session(manager).get("ok", false)), "production checkpoint service initialization failed")
	_require(runtime.checkpoint_service.meta_adapter == adapter and runtime.meta_progress_adapter == adapter, "production persistence authorities use different adapters")
	_require(runtime.checkpoint_service.checkpoint_path == manager.meta_progress_path().get_base_dir().path_join("run_checkpoint.json"), "production checkpoint path does not match the selected profile")
	var bus = run_scene.command_bus
	var panel = run_scene.result_panel
	bus.command_requested.connect(_on_production_command_requested)
	bus.result_available.connect(_on_production_result_available)
	_require(bool(preload("res://tests/z2_legacy_main_fixture.gd").start(run_scene).get("ok", false)), "production durable run admission failed")
	_require(bool(runtime.checkpoint_service.load_checkpoint().get("can_simulate", false)), "production run was not admitted durably")
	# Give the real terminal result a visible item section for the frozen-body guard.
	runtime.context.asset_ledger.create_item_instance({
		"instance_id": "production_terminal_item", "item_id": "production_terminal_item",
		"display_name": "终局恢复样本", "item_type": &"collectible", "rarity": &"tier_4",
		"weight": 2, "base_value": 30, "can_store": true,
	}, RunAssetLedger.LOCATION_INVENTORY)
	var failure_adapter := TerminalWriteFailure.new()
	failure_adapter.target_path = adapter.active_meta_progress_path
	failure_adapter.target_run_id = str(runtime.context.run_id)
	adapter.save_adapter = failure_adapter
	var before_meta: Dictionary = adapter.data.duplicate(true)
	var before_disk := FileAccess.get_file_as_string(adapter.active_meta_progress_path)
	_require(bool(run_scene.call("_show_run_screen")), "production RunScene could not enter the run surface")
	var terminal: Dictionary = bus.dispatch(&"abandon_run", {"confirmed": true, "source": "i2_terminal_fixture"})
	_require(bool(terminal.get("ok", false)), "production terminal checkpoint failed before meta settlement")
	_require(runtime.context.phase == &"failure_salvage" and not bool(runtime.context.result_snapshot.get("settlement", {}).get("finalized", false)), "Z2 abandon must retain an unfinalized selection checkpoint")
	_require(production_result_signal_count == 1 and production_result_signals.size() == 1 and not bool(production_result_signals[0].get("settlement", {}).get("finalized", true)), "Z2 abandon must publish exactly one pending selection result")
	_require(bool(bus.dispatch(&"confirm_failure_salvage", {"selected_instance_ids": []}).get("ok", false)), "production terminal selection did not finalize through the public command")
	var terminal_snapshot: Dictionary = runtime.context.result_snapshot.duplicate(true)
	_require(production_result_signal_count == 2 and production_result_signals.size() == 2 and production_result_signals[1] == terminal_snapshot and bool(terminal_snapshot.get("settlement", {}).get("finalized", false)), "Z2 selection must publish exactly one finalized result")
	_require(production_result_signals.size() == 2 and production_result_signals[0].get("run_id") == terminal_snapshot.get("run_id") and production_result_signals[0].get("outcome") == terminal_snapshot.get("outcome"), "selection cannot change the terminal run or outcome")
	var run_id := str(runtime.context.run_id)
	var checkpoint_path: String = runtime.checkpoint_service.checkpoint_path
	_require(FileAccess.file_exists(checkpoint_path), "failed terminal lost its durable checkpoint")
	var terminal_disk := FileAccess.get_file_as_string(checkpoint_path)
	_require(str(runtime.last_meta_commit.get("status", "")) == "save_failed" and bool(runtime.last_meta_commit.get("durable_checkpoint", false)), "production terminal did not fail specifically at durable meta settlement")
	_require(runtime.persistence_error.is_empty(), "terminal-only failure blocked checkpoint authority")
	_require(adapter.data == before_meta and FileAccess.get_file_as_string(adapter.active_meta_progress_path) == before_disk, "failed terminal did not roll back meta memory and disk")
	var reopened_adapter = MetaProgressAdapterScript.new()
	manager.configure_meta_adapter(reopened_adapter)
	reopened_adapter.save_adapter = failure_adapter
	var reopened_runtime = RunRuntimeControllerScript.new()
	reopened_runtime.bind_meta_progress_adapter(reopened_adapter)
	_require(bool(reopened_runtime.initialize_z2_session(manager).get("ok", false)), "pending terminal could not be restored from disk")
	_require(reopened_runtime.context.result_snapshot == terminal_snapshot and not reopened_runtime.context.run_active, "interruption lost or resumed the pending terminal as active gameplay")
	_require(str(reopened_runtime.last_meta_commit.get("status", "")) == "save_failed" and bool(reopened_runtime.last_meta_commit.get("durable_checkpoint", false)), "pending terminal restart bypassed the settlement failure")
	var restored_admission: Dictionary = reopened_adapter.data.get("admission", {})
	_require(str(restored_admission.get("run_id", "")) == run_id and str(restored_admission.get("phase", "")) == "active" and restored_admission.get("initial_snapshot_hash") == before_meta.admission.initial_snapshot_hash and reopened_adapter.data.get("run_receipts", {}).is_empty(), "pending terminal restart consumed or replaced the admission")
	_require(FileAccess.get_file_as_string(adapter.active_meta_progress_path) == before_disk and FileAccess.get_file_as_string(checkpoint_path) == terminal_disk, "pending terminal restart changed durable storage")
	_release_runtime(reopened_runtime)
	await create_timer(0.20).timeout
	_require(production_result_signal_count == 2, "restart emitted a result after pending and finalized selection signals")
	_require(bool(run_scene.call("_runtime_modal_is_top", &"result")), "production result modal was not registered as stack top")
	_require(not panel.normal_exit_allowed() and panel.retry_save_allowed(), "durable unsaved result did not expose only retry")
	_require(not panel.discard_unsaved_allowed() and not panel.discard_unsaved_button.visible and panel.discard_unsaved_button.disabled, "durable result exposed discard")
	var frozen_result_body := _capture_result_body(panel)
	_require_result_body_unchanged(panel, frozen_result_body, "initial durable save failure")

	for method in ["_return_from_result_to_main", "_return_from_result_to_deploy", "_close_top_runtime_modal"]:
		run_scene.call(method)
	run_scene.call("_cancel_result_modal", &"input_cancel")
	panel.call("_request_discard_unsaved_result")
	panel.call("_request_discard_unsaved_result")
	_require(production_discard_command_count == 0, "durable panel forwarded a forbidden discard")
	var rejected: Dictionary = bus.dispatch(&"discard_unsaved_terminal_commit", {"confirmed": true})
	_require(not bool(rejected.get("ok", true)) and str(rejected.get("reason", "")) == "durable_terminal_retry_required", "core accepted durable terminal discard")
	_require(adapter.data == before_meta and FileAccess.get_file_as_string(checkpoint_path) == terminal_disk, "forbidden discard changed admission or checkpoint")
	_require(StringName(run_scene.screen_state) == &"run" and bool(run_scene.call("_runtime_modal_is_top", &"result")), "unsaved production result escaped through return, Esc or discard")

	panel.retry_save_button.pressed.emit()
	await process_frame
	_require(production_retry_command_count == 1, "production retry did not dispatch exactly one retry command")
	_require(production_result_signal_count == 2, "failed production retry re-emitted result_available")
	_require(str(runtime.last_meta_commit.get("status", "")) == "save_failed" and runtime.persistence_error.is_empty(), "blocked retry failed outside terminal meta persistence")
	_require(not panel.normal_exit_allowed() and bool(run_scene.call("_runtime_modal_is_top", &"result")), "failed production retry unlocked or dismissed the result")
	_require(root.gui_get_focus_owner() == panel.retry_save_button, "failed production retry did not restore focus to retry")
	_require(adapter.data == before_meta and FileAccess.get_file_as_string(adapter.active_meta_progress_path) == before_disk and FileAccess.get_file_as_string(checkpoint_path) == terminal_disk, "blocked retry changed durable meta or terminal snapshot")
	_require_result_body_unchanged(panel, frozen_result_body, "blocked durable retry")
	failure_adapter.blocked = false
	panel.retry_save_button.pressed.emit()
	await process_frame
	_require(production_retry_command_count == 2, "successful production retry did not dispatch exactly one additional command")
	_require(production_result_signal_count == 2, "successful production retry re-emitted result_available")
	_require(panel.normal_exit_allowed() and runtime.persistence_error.is_empty(), "successful production retry did not restore normal exits")
	_require(root.gui_get_focus_owner() == panel.return_deploy_button, "successful production retry did not move focus to the primary exit")
	_require(runtime.context.result_snapshot == terminal_snapshot, "production retry replaced the immutable terminal snapshot")
	_require(adapter.data.get("run_receipts", {}).has(run_id) and adapter.data.get("admission", {}).is_empty(), "successful retry did not settle admission exactly once")
	_require(not FileAccess.file_exists(checkpoint_path) and not FileAccess.file_exists(checkpoint_path + ".bak"), "settlement left a resumable terminal checkpoint")
	_require_result_body_unchanged(panel, frozen_result_body, "committed durable retry")
	var committed_data: Dictionary = adapter.data.duplicate(true)
	var committed_disk := FileAccess.get_file_as_string(adapter.active_meta_progress_path)
	var duplicate: Dictionary = bus.dispatch(&"retry_terminal_commit")
	_require(bool(duplicate.get("ok", false)) and runtime.persistence_error.is_empty(), "production duplicate retry rejected the saved receipt")
	_require(adapter.data == committed_data and FileAccess.get_file_as_string(adapter.active_meta_progress_path) == committed_disk, "production duplicate retry wrote progress twice")
	_require(production_result_signal_count == 2, "duplicate production retry re-emitted result_available")
	run_scene.call("_return_from_result_to_deploy")
	_require(StringName(run_scene.screen_state) == &"deploy_shell" and not bool(run_scene.call("_runtime_modal_is_top", &"result")), "saved production result did not return through Deploy authority")
	main.queue_free()
	_release_runtime(runtime)
	await process_frame

	# A new production scene reloads the profile from disk; settled runs cannot return.
	var reopened := packed.instantiate()
	root.add_child(reopened)
	var restored = reopened.get_node("RunScene")
	restored.set_process(false)
	await process_frame
	_require(not restored.run_context.run_active and restored.run_context.result_snapshot.is_empty(), "settled terminal reappeared after scene restart")
	_require(restored.meta_progress_adapter.data.get("run_receipts", {}).has(run_id), "restart lost the committed run receipt")
	_require(restored.runtime_controller.persistence_error.is_empty(), "restart blocked after successful terminal retry")
	_release_runtime(restored.runtime_controller)
	reopened.queue_free()
	await process_frame


func _release_runtime(runtime) -> void:
	runtime.in_run_runtime.bind(null)
	runtime.command_bus.bind_runtime_controller(null)




func _on_production_command_requested(command_name: StringName, _payload: Dictionary) -> void:
	if command_name == &"retry_terminal_commit":
		production_retry_command_count += 1
	elif command_name == &"discard_unsaved_terminal_commit":
		production_discard_command_count += 1


func _on_production_result_available(snapshot: Dictionary) -> void:
	production_result_signal_count += 1
	production_result_signals.append(snapshot.duplicate(true))


func _warehouse_has(items: Variant, instance_id: String) -> bool:
	if items is Array:
		for raw_item in items:
			if raw_item is Dictionary and String(raw_item.get("instance_id", "")) == instance_id:
				return true
	return false


func _capture_result_body(panel) -> Dictionary:
	var title := panel.get_node_or_null("ResultTitle") as Label
	var summary := panel.get_node_or_null("ResultSummary") as Label
	var metric_row := panel.get("result_metrics_row") as HBoxContainer
	var metric_titles: Array = panel.get("result_metric_title_labels")
	var metric_values: Array = panel.get("result_metric_value_labels")
	var items_scroll := panel.get("result_items_scroll") as ScrollContainer
	var sections_box := panel.get("result_item_sections_box") as VBoxContainer
	var first_section: Control
	if sections_box != null and sections_box.get_child_count() > 0:
		first_section = sections_box.get_child(0) as Control
	return {
		"title_id": title.get_instance_id() if title != null else 0,
		"title_text": title.text if title != null else "",
		"summary_id": summary.get_instance_id() if summary != null else 0,
		"summary_text": summary.text if summary != null else "",
		"metric_row_id": metric_row.get_instance_id() if metric_row != null else 0,
		"metric_title_ids": _control_instance_ids(metric_titles),
		"metric_title_texts": _label_texts(metric_titles),
		"metric_value_ids": _control_instance_ids(metric_values),
		"metric_value_texts": _label_texts(metric_values),
		"items_scroll_id": items_scroll.get_instance_id() if items_scroll != null else 0,
		"first_section_id": first_section.get_instance_id() if first_section != null else 0,
		"first_section_texts": _descendant_label_texts(first_section),
		"panel_alpha": panel.modulate.a,
	}


func _require_result_body_unchanged(panel, before: Dictionary, phase: String) -> void:
	var after := _capture_result_body(panel)
	var title := panel.get_node_or_null("ResultTitle") as Label
	var summary := panel.get_node_or_null("ResultSummary") as Label
	var metric_row := panel.get("result_metrics_row") as HBoxContainer
	var items_scroll := panel.get("result_items_scroll") as ScrollContainer
	var sections_box := panel.get("result_item_sections_box") as VBoxContainer
	var first_section: Control
	if sections_box != null and sections_box.get_child_count() > 0:
		first_section = sections_box.get_child(0) as Control
	_require(title != null and title.is_visible_in_tree(), "%s hid the frozen result title" % phase)
	_require(summary != null and summary.is_visible_in_tree(), "%s hid the frozen result summary" % phase)
	_require(metric_row != null and metric_row.is_visible_in_tree(), "%s hid the frozen result metrics" % phase)
	_require(items_scroll != null and items_scroll.is_visible_in_tree(), "%s hid the frozen result item section" % phase)
	_require(first_section != null and first_section.is_visible_in_tree(), "%s removed the frozen result item section" % phase)
	for key in [
		"title_id",
		"title_text",
		"summary_id",
		"summary_text",
		"metric_row_id",
		"metric_title_ids",
		"metric_title_texts",
		"metric_value_ids",
		"metric_value_texts",
		"items_scroll_id",
		"first_section_id",
		"first_section_texts",
	]:
		_require(after.get(key) == before.get(key), "%s changed frozen result body field %s" % [phase, key])
	_require(float(after.get("panel_alpha", 0.0)) >= 0.99, "%s replayed the result entrance fade" % phase)


func _control_instance_ids(controls: Array) -> Array[int]:
	var ids: Array[int] = []
	for raw_control in controls:
		var control := raw_control as Control
		ids.append(control.get_instance_id() if control != null else 0)
	return ids


func _label_texts(labels: Array) -> Array[String]:
	var texts: Array[String] = []
	for raw_label in labels:
		var label := raw_label as Label
		texts.append(label.text if label != null else "")
	return texts


func _descendant_label_texts(root_control: Control) -> Array[String]:
	var texts: Array[String] = []
	if root_control == null:
		return texts
	for raw_node in root_control.find_children("*", "Label", true, false):
		var label := raw_node as Label
		if label != null:
			texts.append(label.text)
	return texts


func _is_lower_hex(value: String) -> bool:
	for index in range(value.length()):
		if "0123456789abcdef".find(value.substr(index, 1)) < 0:
			return false
	return true


func _cleanup() -> void:
	for path in [blocked_save_path, blocked_save_path + ".tmp", blocked_save_path + ".bak", blocked_save_path + ".corrupt", blocker_path]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	var blocked_dir := ProjectSettings.globalize_path(blocker_path)
	if DirAccess.dir_exists_absolute(blocked_dir):
		DirAccess.remove_absolute(blocked_dir)


func _require(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
