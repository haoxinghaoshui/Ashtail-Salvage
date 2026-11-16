extends "res://tests/z2_event_ui_runner.gd"

# Actual Main, durable admission/abandon/retention. Only inventory eligibility is seeded.
func _run() -> void:
	root.size = Vector2i(1280, 720)
	var main: Node = load("res://scenes/main/main.tscn").instantiate()
	root.add_child(main)
	current_scene = main
	scene = main.get_node("RunScene")
	await process_frame
	scene.set_process(false)
	scene.set_physics_process(false)
	await _idle_main_font_change()
	var live: RunRuntimeController = scene.runtime_controller
	var meta: MetaProgressAdapter = scene.meta_progress_adapter
	_check(meta.begin_tutorial_training().get("ok", false), "actual Main isolated tutorial eligibility")
	_check(meta.purchase_tutorial_flag().get("ok", false), "actual Main training admission")
	_check(meta._apply_tutorial_settlement({"mode": "tutorial", "outcome": "Training Complete", "settlement": {"outcome": "success"}}, "lifecycle_training").get("ok", false), "actual Main teaching completed")
	for replace in [false, true]:
		await _terminal_case(live, replace)
	_release_runtime(live)
	main.free()
	await process_frame
	await process_frame
	var retained: Array[String] = []
	for node in root.find_children("*", "", true, false): retained.append(str(node.get_path()))
	print("Z2_TERMINAL_RETAINED_TREE=" + JSON.stringify(retained))
	_check(root.get_node_or_null("Z2PersistentOverlays") == null, "Main teardown releases notification subtree without test cleanup")
	for failure in failures: print("Z2_TERMINAL_UI_LIFECYCLE_FAIL " + failure)
	print("Z2_TERMINAL_UI_LIFECYCLE=%s checks=%d failures=%d" % ["PASS" if failures.is_empty() else "FAIL", checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _idle_main_font_change() -> void:
	_check(not scene.run_context.run_active and scene.run_context.asset_ledger == null, "fresh Main has no active ledger")
	var entry: Button = scene.ui_shell.find_child("MainMenuEntry_long_term", true, false)
	_check(entry != null and entry.is_visible_in_tree(), "normal Main exposes long-term entry")
	entry.pressed.emit()
	for frame in range(180):
		await process_frame
		if scene.ui_shell.long_term_page.is_visible_in_tree(): break
	_check(scene.ui_shell.long_term_page.is_visible_in_tree(), "actual Main entry reaches long-term page")
	for scale_value in [1.0, 1.25, 1.5]:
		scene.set_ui_scale_factor(scale_value)
		await _frames()
		_check(is_equal_approx(scene.get_ui_scale_factor(), scale_value) and scene.ui_shell.long_term_page.is_visible_in_tree(), "idle long-term font %d refresh remains usable" % roundi(scale_value * 100))
		_check(not scene.run_context.run_active and scene.run_context.asset_ledger == null, "font refresh never creates a ledger")
	await _capture_lifecycle("idle-long-term-150")

func _terminal_case(live: RunRuntimeController, replace: bool) -> void:
	var tag := "replacement" if replace else "ground"
	var config := RunStartConfig.default_config()
	config.merge({"map_config_id": "classic_7x7_simple", "difficulty": &"simple", "seed_value": 71}, true)
	config.selected_objective_id = Catalog.commission_offer_candidates("classic_7x7_simple", 0)[0].id
	var started: Dictionary = scene.command_bus.dispatch(&"start_standard_run", {"run_start_config": config})
	_check(started.get("ok", false), tag + ": actual standard admission")
	if not started.get("ok", false): return
	var context: RunContext = scene.run_context
	var ids := {}
	var added := live.execute_atomic_operation(&"ui_lifecycle_fixture", {}, func() -> Dictionary:
		ids["medicine"] = context.asset_ledger.create_item_instance(Items.definition("con_ration"), &"inventory").instance_id
		ids["outgoing"] = context.asset_ledger.create_item_instance(Items.definition("col_01"), &"inventory").instance_id
		ids["floor"] = context.asset_ledger.create_item_instance(Items.definition("col_02"), &"room_floor", context.get_current_pos()).instance_id
		if replace: context.asset_ledger.backpack_capacity = context.asset_ledger.get_backpack_used()
		context.asset_ledger.sync_compat_fields(context)
		context.active_talent_effects.append({"effect_kind": "consumable_retention", "effect_amount": 1})
		return {"ok": true})
	_check(added.get("ok", false), tag + ": fixture enters actual atomic ledger")
	scene._show_run_screen()
	scene._refresh_view_models()
	await _frames()
	var room = scene.room_runtime_view
	room.set_context_ui_suppressed(false)
	_check(not room.ground_loot_entities.is_empty(), tag + ": actual ground entity exists")
	if room.ground_loot_entities.is_empty(): return
	var entity = room.ground_loot_entities.values()[0]
	room._refresh_context_popup(scene.player_controller.get_local_position(), entity)
	var popup: Control = room.context_popup
	await _frames()
	_check(popup.is_visible_in_tree() and popup.context_kind == &"ground_loot", tag + ": actual ground context opens")
	if replace:
		_check(popup.activate_primary(), tag + ": actual primary enters replacement")
		await _frames()
		_check(popup.replacement_ground_id == ids.floor, tag + ": exact incoming replacement selected")
	await _capture_lifecycle(tag + "-before-terminal")
	var ended: Dictionary = scene.command_bus.dispatch(&"abandon_run", {"confirmed": true, "action_id": "ui-lifecycle-" + tag})
	_check(ended.get("ok", false), tag + ": real abandon enters retention")
	await _frames()
	_check(scene.result_panel.is_visible_in_tree() and scene.result_panel.requires_salvage_confirmation(), tag + ": terminal retention remains available")
	_check(scene._runtime_modal_is_top(&"result"), tag + ": result owns modal input")
	_check(not popup.is_visible_in_tree(), tag + ": old world popup closed at terminal")
	_check(popup.current_context.is_empty() and popup.context_items.is_empty() and popup.replacement_ground_id.is_empty(), tag + ": stale ground and replacement identities cleared")
	var before := live.capture_authoritative_state()
	var last_result: Dictionary = scene.last_command_result.duplicate(true)
	_check(not popup.activate_primary(), tag + ": closed primary cannot dispatch")
	popup.pickup_requested.emit(str(ids.floor))
	popup.replace_requested.emit(str(ids.floor), str(ids.outgoing))
	scene._on_ground_loot_pickup_requested(str(ids.floor))
	scene._on_ground_loot_replace_requested(str(ids.floor))
	await _frames()
	_check(live.capture_authoritative_state() == before and scene.last_command_result == last_result, tag + ": stale UI signals cannot submit or mutate terminal state")
	await _capture_lifecycle(tag + "-retention-clean")
	scene.result_panel.salvage_confirm_button.pressed.emit()
	await _frames()
	_check(live.last_meta_commit.get("ok", false), tag + ": real retention confirmation persists")
	_check(not scene.result_panel.requires_salvage_confirmation(), tag + ": existing retention business completes")
	scene._return_from_result_to_deploy()
	await _frames()
	before = live.capture_authoritative_state()
	last_result = scene.last_command_result.duplicate(true)
	popup.pickup_requested.emit(str(ids.floor))
	popup.replace_requested.emit(str(ids.floor), str(ids.outgoing))
	await _frames()
	_check(live.capture_authoritative_state() == before and scene.last_command_result == last_result, tag + ": stale context cannot dispatch after returning to camp")

func _frames() -> void:
	for frame in range(4): await process_frame

func _capture_lifecycle(tag: String) -> void:
	if DisplayServer.get_name() == "headless": return
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute("user://captures/lifecycle")
	_check(root.get_texture().get_image().save_png("user://captures/lifecycle/%s.png" % tag) == OK, tag + ": raw GPU capture")
