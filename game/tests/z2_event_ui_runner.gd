extends SceneTree

const Integration = preload("res://tests/z2_event_integration_runner.gd")
const Events = preload("res://scripts/core/run/z2_event_runtime.gd")
const Service = preload("res://scripts/core/run/event_service.gd")
const Eligibility = preload("res://scripts/core/content/z2_content_eligibility.gd")
const Rules = preload("res://scripts/core/progression/z2_progression_rules.gd")
const Items = preload("res://scripts/core/content/z2_item_catalog.gd")
const Meta = preload("res://scripts/core/save/meta_progress_adapter.gd")
const Catalog = preload("res://scripts/core/content/m7_content_catalog.gd")
const Builder = preload("res://scripts/core/run/run_result_builder.gd")
const Checkpoints = preload("res://scripts/core/save/run_checkpoint_service.gd")
const Snapshot = preload("res://scripts/core/run/run_state_snapshot.gd")
const Opening = preload("res://scripts/core/run/z2_opening_runtime.gd")
const Offer = preload("res://scripts/core/progression/z2_opening_offer.gd")
var checks := 0
var failures: Array[String] = []
var scene: Node
var runtime: Integration.HarnessRuntime

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	root.size = Vector2i(1280, 720)
	root.content_scale_size = Vector2i(1280, 720)
	DirAccess.make_dir_recursive_absolute("user://saves/profiles")
	var main: Node = load("res://scenes/main/main.tscn").instantiate()
	root.add_child(main)
	scene = main.get_node("RunScene")
	await process_frame
	scene.set_process(false)
	scene.set_physics_process(false)
	_check(scene.get("z2_event_adapter") is Control, "actual RunScene mounts unified event adapter")
	_check(root.get_node_or_null("Z2PersistentOverlays/NotificationQueue") != null, "queue lives outside RunScene")
	if scene.get("z2_event_adapter") is Control:
		_setup_runtime()
		await _projections()
		await _receipts()
		await _materials()
		_check(scene.has_method("_refresh_opening_inventory_controls"), "actual RunScene wires conditional opening inventory controls")
		if scene.has_method("_refresh_opening_inventory_controls"):
			await _opening_actions()
		await _actual_notification()
	await process_frame
	_release_runtime(scene.runtime_controller)
	scene.free()
	var persistent := root.get_node_or_null("Z2PersistentOverlays")
	if persistent != null:
		var queue_id: int = persistent.get_node("NotificationQueue").get_instance_id()
		scene = load("res://scenes/run/run_scene.tscn").instantiate()
		main.add_child(scene)
		await process_frame
		_check(root.get_node("Z2PersistentOverlays/NotificationQueue").get_instance_id() == queue_id, "same queue survives actual RunScene replacement within Main")
		_release_runtime(scene.runtime_controller)
		scene.free()
	main.free()
	if runtime != null:
		runtime.checkpoint_writer = Callable()
		runtime.command_bus.runtime_controller = null
		runtime.command_bus.room_resolver.bind_runtime_controller(null)
		runtime.in_run_runtime.bind(null)
		runtime = null
	await process_frame
	await process_frame
	_check(root.get_node_or_null("Z2PersistentOverlays") == null, "Main lifecycle releases persistent queue without test cleanup")
	for failure in failures:
		print("Z2_EVENT_UI_FAIL " + failure)
	print("Z2_EVENT_UI=%s checks=%d" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)

func _check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)

func _setup_runtime() -> void:
	# Actual atomic runtime/CommandBus; only pools and parent consumers are fixtures.
	runtime = Integration.HarnessRuntime.new()
	runtime.command_bus.dispatch(&"start_demo_run", {})
	runtime.context.run_start_config["profile_fields"] = {"ruleset_id": "z2", "z2_progression_version": 1,
		"content_eligibility": Eligibility.freeze_profile({"profile_level": 50})}
	runtime.context.profile_fields = runtime.context.run_start_config.profile_fields.duplicate(true)
	runtime.context.asset_ledger.setup({"run_id": str(runtime.context.run_id)})
	runtime.context.asset_ledger.add_currency(&"black_coin", 300, "ui_fixture")
	runtime.context.power = 999
	runtime.context.run_start_config["map_config_id"] = "classic_13x13_normal"
	runtime.pools = {}
	runtime.process_rules = {"difficulty": "normal", "mechanism_failure_damage_type": "physical", "electric_damage_type": "physical",
		"rps_reward_pool": [27], "enemy_pool": [{"enemy_id": "fixture_enemy", "original_power": 17, "hp": 30}]}
	var previous: RunRuntimeController = scene.runtime_controller
	previous.command_bus.state_changed.disconnect(scene._on_state_changed)
	previous.command_bus.result_available.disconnect(scene._on_result_available)
	_release_runtime(previous)
	scene.runtime_controller = runtime
	scene.run_context = runtime.context
	scene.command_bus = runtime.command_bus
	scene.in_run_runtime = runtime.in_run_runtime
	runtime.command_bus.state_changed.connect(scene._on_state_changed)
	runtime.command_bus.result_available.connect(scene._on_result_available)
	scene.screen_state = scene.SCREEN_RUN
	scene.run_overlay_root.show()
	scene._set_gameplay_visible(true)
	scene.persistence_controller.persistence_error_panel.hide()

func _release_runtime(value: RunRuntimeController) -> void:
	value.checkpoint_writer = Callable()
	value.checkpoint_service = null
	value._persistence_manager = null
	value.command_bus.runtime_controller = null
	value.command_bus.room_resolver.bind_runtime_controller(null)
	value.in_run_runtime.bind(null)

func _open(event: String, fresh := true) -> Dictionary:
	scene._cancel_event_modal()
	var pos := Vector2i(2, 2)
	runtime.context.current_pos = pos
	runtime.context.player_pos = pos
	runtime.context.current_room_type = &"Event"
	runtime.context.visited_cells[runtime.context.cell_key(pos)] = true
	if fresh:
		runtime.action_receipts.clear()
		runtime.context.z1_event_rooms[runtime.context.cell_key(pos)] = {"event_type": StringName(event)}
		runtime.context.z1_event_flags.clear()
		runtime.context.interacted_cells.clear()
	var state := Service.get_event_state(runtime.context, pos)
	runtime.context.event_state = state.duplicate(true)
	scene.room_runtime_view.configure_room(runtime.context.get_status_snapshot())
	for entity: Node in scene.room_runtime_view.special_entities.values():
		if str(entity.interaction_kind) == "event":
			scene.player_controller.set_local_position(entity.local_pos)
			break
	scene._show_event_panel(state)
	return state

func _projections() -> void:
	for event in Events.event_ids():
		var state := _open(event)
		var before := runtime.capture_authoritative_state()
		await process_frame
		var adapter: Control = scene.z2_event_adapter
		_check(adapter.is_visible_in_tree(), event + ": real event modal visible")
		_check(adapter.dialogue.scene_file_path == "res://scenes/components/z2_overlays/z2_event_dialogue.tscn", event + ": delivered component")
		var view: Dictionary = adapter.dialogue.get("_view")
		_check(view.get("options", []).size() == state.get("options", []).size(), event + ": all core options")
		if not state.get("dialogue", []).is_empty():
			_check(view.lines == state.dialogue, event + ": exact S3 dialogue and speaker projection")
		elif state.has("player_summary"):
			_check(not view.lines.is_empty() and view.lines[0].text == state.player_summary, event + ": exact core prose")
		for i in mini(view.get("options", []).size(), state.get("options", []).size()):
			_check(view.options[i].label == str(state.options[i].get("player_title", state.options[i].get("label", ""))), event + ": core label")
		_check(runtime.capture_authoritative_state() == before, event + ": pure projection")
		await _verify_source_dialogue(state, event)
		if event != "cage":
			await _press("prepare")
			var current := Service.get_event_state(runtime.context, Vector2i(2, 2))
			# Savings needs a typed principal before preparing; its actual path is below.
			if event != "savings":
				_check(bool(current.get("prepared", false)), event + ": actual prepare commits")
				if not current.get("prepared", false):
					print("PREPARE_DIAGNOSTIC ", event, " ", scene.last_command_result)
				_check(adapter.dialogue.get("_view").options.size() == current.options.size(), event + ": prepared choices project core state")
				await _verify_source_dialogue(current, event + "-prepared")

func _advance_to_choices(dialogue: Control) -> void:
	for step in range(dialogue._lines.size() * 2 + 2):
		if dialogue._choosing or not dialogue.is_visible_in_tree(): break
		dialogue._advance()

func _verify_source_dialogue(state: Dictionary, tag: String) -> void:
	var dialogue: Control = scene.z2_event_adapter.dialogue
	var lines: Array = state.get("dialogue", [])
	if lines.is_empty(): return
	_check(dialogue._lines == lines and state.get("dialogue_source", {}).get("id", "") == "S3", tag + ": actual source catalog selected")
	if dialogue._lines != lines:
		print("SOURCE_VIEW_DIAGNOSTIC=", tag, " visible=", dialogue.is_visible_in_tree(), " shown=", dialogue._lines, " expected=", lines)
	var before := runtime.capture_authoritative_state()
	var longest := 0
	for index in lines.size():
		if str(lines[index].text).length() > str(lines[longest].text).length(): longest = index
	for index in lines.size():
		var line: Dictionary = lines[index]
		_check(dialogue._body.text == line.text, tag + ": complete source line " + str(index))
		_check(dialogue._speaker.text == str(line.get("speaker", state.get("speaker", ""))), tag + ": source speaker " + str(index))
		dialogue._complete_line()
		await process_frame
		if DisplayServer.get_name() != "headless" and index == longest:
			await RenderingServer.frame_post_draw
			DirAccess.make_dir_recursive_absolute("user://captures/source-dialogue")
			_check(root.get_texture().get_image().save_png("user://captures/source-dialogue/%s.png" % tag) == OK, tag + ": original GPU source-line capture")
		dialogue._advance()
	_check(runtime.capture_authoritative_state() == before, tag + ": reading original dialogue does not change game state")

func _press(id: String) -> void:
	var adapter: Control = scene.z2_event_adapter
	for i in adapter.get("_options").size():
		if str(adapter.get("_options")[i].get("id", "")) == id:
			_advance_to_choices(adapter.dialogue)
			adapter.dialogue.get("_buttons")[i].pressed.emit()
			adapter.dialogue.get("_buttons")[i].pressed.emit()
			await process_frame
			return
	_check(false, "missing option " + id)

func _receipts() -> void:
	_open("savings")
	var adapter: Control = scene.z2_event_adapter
	var amount := adapter.find_child("EventAmount", true, false) as SpinBox
	_check(amount != null, "real amount input mounted")
	if amount != null:
		amount.get_line_edit().text = "24"
		await _press("prepare")
		var quote := Service.get_event_state(runtime.context, Vector2i(2, 2))
		var found := false
		for option: Dictionary in quote.options:
			if str(option.id) == "deposit":
				found = int(option.payload.get("amount", 0)) == 24
		_check(found, "typed amount reaches core quote")
		if not found:
			print("AMOUNT_DIAGNOSTIC ", scene.last_command_result, " / ", quote)
	_open("expand")
	await _press("prepare")
	var before: int = runtime.context.asset_ledger.get_currency(&"black_coin")
	runtime.checkpoint_writer = func(_candidate: Dictionary) -> Dictionary: return {"ok": false, "reason": "ui_injected_save_failure"}
	await _press("expand")
	var failed_id: String = adapter.get("last_action_id")
	_check(runtime.context.asset_ledger.get_currency(&"black_coin") == before, "save failure rolls back charge")
	_check(not runtime.action_receipts.has(failed_id), "failure has no receipt")
	_check(adapter.dialogue.get("_pending_by_room").is_empty(), "failure unlocks input")
	_check(str(adapter.dialogue.get("_feedback").text).contains("保存"), "retryable save failure feedback")
	runtime.checkpoint_writer = func(_candidate: Dictionary) -> Dictionary: return {"ok": true}
	scene.persistence_controller.retry()
	await _press("expand")
	_check(adapter.get("last_action_id") == failed_id, "retry keeps exact action identity")
	_check(runtime.action_receipts.has(failed_id), "durable receipt before NPC reply")
	_check(runtime.context.asset_ledger.get_currency(&"black_coin") < before, "retry charges once")
	var actual_reply: Dictionary = runtime.action_receipts.get(failed_id, {}).get("result", {}).get("action_result", {})
	_check(adapter.dialogue._lines == actual_reply.get("response_lines", []), "only committed core response lines reach dialogue")
	_check(not adapter.dialogue._lines.is_empty() and adapter.dialogue._lines[0].text == actual_reply.get("message", ""), "actual result precedes source NPC response")
	_check(not str(adapter.dialogue.get_node("%SpeakerName").text).is_empty(), "committed response inherits authoritative speaker")
	_open("expand", false)
	_check(bool(Service.get_event_state(runtime.context, Vector2i(2, 2)).completed), "revisit retains core progress")
	scene._cancel_event_modal()
	var before_revisit := runtime.capture_authoritative_state()
	scene._handle_interact_pressed()
	_check(scene._runtime_modal_is_top(&"event"), "actual interact reopens completed event at its marker")
	_check(runtime.capture_authoritative_state() == before_revisit, "revisit opens source dialogue without another command or reward")
	await _verify_source_dialogue(Service.get_event_state(runtime.context, Vector2i(2, 2)), "expand-revisit")
	scene._cancel_event_modal()
	scene.player_controller.set_local_position(Vector2.ZERO)
	scene._handle_interact_pressed()
	_check(not scene._runtime_modal_is_top(&"event"), "completed revisit still requires actual proximity")
	var notice := {"goal_id": "ui_fixture_goal", "tier": 1, "title": "测试完成通知"}
	_check(scene.enqueue_z2_committed_notifications({"ok": false, "committed": false, "receipt_id": "ui_fixture"}, [notice]) == 0, "no notification before commit")
	_check(scene.enqueue_z2_committed_notifications({"ok": true, "committed": true, "receipt_id": "ui_fixture"}, [notice]) == 1, "committed notification")
	_check(scene.enqueue_z2_committed_notifications({"ok": true, "committed": true, "receipt_id": "ui_fixture"}, [notice]) == 0, "notification receipt dedupe")
	scene._show_main_menu()
	var queue := root.get_node("Z2PersistentOverlays/NotificationQueue")
	_check(queue.is_inside_tree() and queue.get_parent().get_parent() == root, "queue survives page transition")

func _materials() -> void:
	scene.screen_state = scene.SCREEN_RUN
	scene.run_overlay_root.show()
	scene._set_gameplay_visible(true)
	var first: String = runtime.context.asset_ledger.create_item_instance(Items.definition("col_01"), &"inventory").instance_id
	var second: String = runtime.context.asset_ledger.create_item_instance(Items.definition("col_02"), &"inventory").instance_id
	_open("compress")
	await _press("prepare")
	var adapter: Control = scene.z2_event_adapter
	var before := runtime.capture_authoritative_state()
	await _press("compress")
	_check(runtime.capture_authoritative_state() == before, "missing two materials cannot pay or dispatch")
	for id in [first, second]:
		for child in adapter.get("_fields").get_children():
			if child is CheckBox and str(child.get_meta("instance_id", "")) == id:
				child.button_pressed = true
	_check(adapter.get("_selected_items") == [first, second], "two distinct real inventory instances selected")
	for viewport_size in [Vector2i(1280, 720), Vector2i(704, 540)]:
		root.size = viewport_size
		root.content_scale_size = viewport_size
		await process_frame
		await process_frame
		var frame: Control = adapter.dialogue.get_node("%ChoicesFrame")
		var rect := frame.get_global_rect()
		_check(rect.position.x >= 0 and rect.end.x <= viewport_size.x + 1 and rect.position.y >= 0 and rect.end.y <= viewport_size.y + 1, "real choices fit " + str(viewport_size))
		if DisplayServer.get_name() != "headless":
			await RenderingServer.frame_post_draw
			DirAccess.make_dir_recursive_absolute("user://captures")
			root.get_texture().get_image().save_png("user://captures/event-compression-%d.png" % viewport_size.x)
	root.size = Vector2i(1280, 720)
	root.content_scale_size = Vector2i(1280, 720)
	await _press("compress")
	_check(not runtime.context.asset_ledger.item_instances.has(first) or str(runtime.context.asset_ledger.item_instances[first].get("location_state")) != "inventory", "first material consumed after commit")
	_check(not runtime.context.asset_ledger.item_instances.has(second) or str(runtime.context.asset_ledger.item_instances[second].get("location_state")) != "inventory", "second material consumed after commit")
	_check(bool(Service.get_event_state(runtime.context, Vector2i(2, 2)).completed), "actual compression completed")

func _opening_fixture(effect: String) -> void:
	runtime.context.mode = &"standard"
	runtime.context.run_start_config["tutorial_map"] = false
	runtime.context.visited_cells.clear()
	runtime.context.searched_cells.clear()
	runtime.context.interacted_cells.clear()
	runtime.context.run_stats["moves"] = 0
	runtime.context.active_talent_effects.assign([{"talent_id": "z2_talent_15", "effect_kind": "opening_effect_batch_unlock", "effect_amount": 1, "effect_params": {"batch": 1}}])
	var profile := {"profile_id": "ui_opening", "ruleset_id": "z2", "z2_progression_version": 1, "gold": 1000, "run_count": 0, "talent_flags": ["z2_talent_15"], "admission": {}}
	for seed_value in range(1, 100):
		var prepared := Offer.execute(profile, "prepare", {"request_id": "ui_prepare"}, seed_value)
		if not prepared.offer.candidates.has(effect):
			continue
		var chosen := Offer.execute(prepared.meta, "choose", {"request_id": "ui_choose", "offer_id": prepared.offer.offer_id, "effect_id": effect})
		runtime.context.run_start_config["z2_opening_offer"] = chosen.offer.duplicate(true)
		runtime.context.z1_event_flags.erase("z2_opening")
		var admitted := Opening.admit_departure(runtime.context, chosen.offer)
		_check(admitted.get("ok", false), "trusted opening fixture admits " + effect + ": " + str(admitted.get("reason", "")))
		return
	_check(false, "opening fixture candidate missing " + effect)

func _opening_actions() -> void:
	scene._cancel_event_modal()
	scene._show_inventory_panel()
	_check(scene.inventory_panel.get("opening_controls") == null, "no selected effect exposes no opening actions")
	for effect in ["avoidance", "power_life"]:
		_opening_fixture(effect)
		scene._refresh_opening_inventory_controls()
		var end := scene.inventory_panel.find_child("EndOpeningEffect", true, false) as Button
		_check(end != null and not end.disabled, effect + " exposes actual end action")
		if end != null:
			var attempted: Array[String] = []
			if effect == "avoidance":
				var original := Opening.public_state(runtime.context)
				runtime.checkpoint_writer = func(candidate: Dictionary) -> Dictionary:
					for id: String in candidate.get("receipts", {}):
						if not runtime.action_receipts.has(id): attempted.append(id)
					return {"ok": false, "reason": "opening_ui_save_failure"}
				end.pressed.emit()
				end.pressed.emit()
				await process_frame
				_check(Opening.public_state(runtime.context) == original, "failed inventory action preserves exact active effect")
				_check(attempted.size() == 1, "failed inventory double input makes one save attempt")
				runtime.checkpoint_writer = func(candidate: Dictionary) -> Dictionary:
					for id: String in candidate.get("receipts", {}):
						if not runtime.action_receipts.has(id): attempted.append(id)
					return {"ok": true}
				scene.persistence_controller.retry()
				end = scene.inventory_panel.find_child("EndOpeningEffect", true, false)
			end.pressed.emit()
			end.pressed.emit()
			await process_frame
			_check(not Opening.public_state(runtime.context).effect_state.active, effect + " ends through real atomic command")
			if effect == "avoidance":
				_check(attempted.size() == 2 and attempted[0] == attempted[1], "inventory save retry keeps exact action ID")
				runtime.checkpoint_writer = func(_candidate: Dictionary) -> Dictionary: return {"ok": true}
	_opening_fixture("dismantle")
	var id: String = runtime.context.asset_ledger.create_item_instance(Items.definition("col_01"), &"inventory").instance_id
	scene._refresh_opening_inventory_controls()
	var choice: OptionButton = scene.inventory_panel.opening_item_choice
	if choice == null:
		_check(false, "dismantle item chooser exists")
		scene._close_inventory_modal()
		return
	for index in choice.item_count:
		if str(choice.get_item_metadata(index)) == id:
			choice.select(index)
			choice.item_selected.emit(index)
	var dismantle := scene.inventory_panel.find_child("DismantleOpening_scan", true, false) as Button
	_check(dismantle != null and not dismantle.disabled, "exact selected item enables dismantle")
	if dismantle != null:
		dismantle.pressed.emit()
		dismantle.pressed.emit()
		await process_frame
		var state := Opening.public_state(runtime.context)
		_check(int(state.effect_state.uses) == 1 and int(state.effect_state.tools.scan) == 1, "dismantle double click consumes once and creates one tool")
		_check(str(runtime.context.asset_ledger.item_instances[id].location_state) == "consumed", "actual ledger owns item destruction")
		var scan := scene.inventory_panel.find_child("UseOpening_scan", true, false) as Button
		_check(scan != null and not scan.disabled, "real tool count enables scan")
		if scan != null:
			scan.pressed.emit()
			await process_frame
			_check(Opening.public_state(runtime.context).effect_state.tools.scan == 0, "actual scan result consumes tool")
	scene._close_inventory_modal()


func _actual_notification() -> void:
	var meta := Meta.new()
	meta.set_active_profile_path("user://ui_quest_%d/meta.json" % Time.get_ticks_usec(), "ui_quest")
	_check(meta.initialize_z2_profile(Rules.CONTENT_VERSION).get("ok", false), "notification fixture creates actual profile")
	meta.begin_tutorial_training()
	meta.purchase_tutorial_flag()
	meta._apply_tutorial_settlement({"mode": "tutorial", "outcome": "Training Complete", "settlement": {"outcome": "success"}}, "ui_tutorial")
	var profile := {"ruleset_id": "z2", "z2_progression_version": 1, "z2_fact_sequence_base": int(meta.data.get("z2_fact_sequence", 0))}
	var config := Catalog.map_runtime_config("classic_7x7_simple", 71, {"map_config_id": "classic_7x7_simple", "profile_fields": profile})
	config["profile_fields"] = profile
	var context := RunContext.new()
	context.start_run(config)
	var service := Checkpoints.new()
	service.configure(meta, "z2", Rules.CONTENT_VERSION)
	var checkpoint := {"schema_version": 1, "profile_id": meta.active_profile_id, "run_id": str(context.run_id), "revision": 0,
		"ruleset_id": "z2", "content_version": Rules.CONTENT_VERSION, "state": Snapshot.pack_checkpoint({"context": Snapshot.capture_context(context)})}
	_check(service.begin_admission(checkpoint).get("ok", false), "notification run uses real reserved admission")
	context._apply_extract()
	var snapshot := Builder.build(context, context.asset_ledger.get_public_snapshot(context.player_pos))
	var result: Dictionary = meta.apply_settlement(snapshot)
	_check(result.get("ok", false) and not result.get("quest_notifications", []).is_empty(), "actual committed settlement publishes notices")
	if result.get("quest_notifications", []).is_empty():
		print("NOTICE_DIAGNOSTIC ", result)
	var queue := root.get_node("Z2PersistentOverlays/NotificationQueue")
	var count: int = queue.get("_seen").size()
	runtime.last_meta_commit = result.duplicate(true)
	scene._on_result_available(snapshot)
	_check(queue.get("_seen").size() > count, "actual completion receipt reaches shared queue")
	var after: int = queue.get("_seen").size()
	scene._publish_z2_notifications({"result": result})
	_check(queue.get("_seen").size() == after, "same completion across scene envelopes dedupes")
	await process_frame
