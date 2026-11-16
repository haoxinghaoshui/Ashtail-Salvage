extends SceneTree

const EventPanel := preload("res://scripts/ui/run_surface/z1_event_choice_panel.gd")
const WorldPopup := preload("res://scripts/gameplay/interaction/g41_world_context_popup.gd")
const Events := preload("res://scripts/core/content/z1_event_catalog.gd")
const EventServiceScript := preload("res://scripts/core/run/event_service.gd")
const Items := preload("res://scripts/core/content/m3r_item_usability_model.gd")
const UISkin := preload("res://scripts/presentation/art10_ui_skin_kit.gd")

const ROOM := Vector2i(2, 2)
const ROOM_GROUPS := {
	&"z1_event_e01": "EventTargetGrid", &"z1_event_e04": "EventTargetGrid",
	&"z1_event_e16": "EventTargetGrid", &"z1_event_e19": "EventTargetGrid",
	&"z1_event_e06": "EventMaterialChoices", &"z1_event_e08": "EventMaterialChoices",
	&"z1_event_e11": "EventMaterialChoices", &"z1_event_e13": "EventMaterialChoices",
	&"z1_event_e14": "EventMaterialChoices", &"z1_event_e15": "EventMaterialChoices",
	&"z1_event_e21": "EventReconRanges", &"z1_event_e22": "EventHands",
	&"z1_event_e25": "EventShopSlots", &"altar": "EventMaterialChoices", &"trap": "EventMaterialChoices",
}

var failures: Array[String] = []
var submitted: Array[Dictionary] = []
var opened: Array[Dictionary] = []
var panel: Control
var popup: Control
var modal: PanelContainer


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	root.size = Vector2i(1280, 720)
	modal = PanelContainer.new()
	modal.position = Vector2(956, 104)
	modal.size = Vector2(300, 360)
	UISkin.apply_player_ui_theme(modal)
	var frame := StyleBoxFlat.new()
	for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
		frame.set_content_margin(side, 20)
	modal.add_theme_stylebox_override("panel", frame)
	root.add_child(modal)
	panel = EventPanel.new()
	modal.add_child(panel)
	panel.option_selected.connect(func(option: Dictionary) -> void: submitted.append(option))
	popup = WorldPopup.new()
	root.add_child(popup)
	popup.event_open_requested.connect(func(payload: Dictionary) -> void: opened.append(payload))
	var event_ids := Events.event_ids()
	event_ids.append_array([&"trader", &"dice", &"altar", &"trap"])
	for ui_scale in [1.25, 1.50]:
		UISkin.set_runtime_ui_scale_factor(ui_scale)
		panel.call("set_ui_scale_factor", ui_scale)
		var seen_actions := {}
		for event_id in event_ids:
			await _check_room(event_id, ui_scale, seen_actions)
	await _check_results()
	popup.free()
	modal.free()
	await process_frame
	if failures.is_empty():
		print("Z1_EVENT_ROOM_UI=PASS rooms=29 scales=125,150")
		quit(0)
	else:
		for failure in failures:
			print("Z1_EVENT_ROOM_UI_CASE_FAIL " + failure)
		print("Z1_EVENT_ROOM_UI=FAIL count=", failures.size())
		quit(1)


func _check_room(event_id: StringName, ui_scale: float, seen_actions: Dictionary) -> void:
	var context := _fixture(event_id)
	var state := EventServiceScript.get_event_state(context, ROOM)
	var original := state.duplicate(true)
	var presentation := _presentation(context, state)
	popup.call("apply_context", _near_context(presentation))
	var primary := popup.find_child("ContextPrimaryButton", true, false) as Button
	var tag := "%s@%d" % [event_id, int(ui_scale * 100)]
	_expect(primary != null and primary.is_visible_in_tree() and not primary.text.is_empty(), tag + " missing near action")
	if primary != null:
		_expect(not seen_actions.has(primary.text), tag + " duplicate near action " + primary.text)
		seen_actions[primary.text] = true
	opened.clear()
	_expect(bool(popup.call("activate_primary")) and opened == [presentation], tag + " changed the near payload")
	popup.hide()

	panel.call("apply_event", state, presentation)
	await process_frame
	await process_frame
	_expect(state == original, tag + " mutated its state")
	_expect(is_equal_approx(modal.size.x, 300.0) and is_equal_approx(modal.size.y, 360.0), tag + " forced the modal outside its layout")
	if ROOM_GROUPS.has(event_id):
		var group := panel.find_child(ROOM_GROUPS[event_id], true, false) as Control
		_expect(group != null and group.is_visible_in_tree(), tag + " missing " + ROOM_GROUPS[event_id])
	if event_id == &"z1_event_e22":
		var score := panel.find_child("EventRoomScore", true, false) as Label
		_expect(score != null and score.is_visible_in_tree() and score.text.count("0") == 2, tag + " missing initial score")
	var scroll := panel.find_child("EventOptionScroll", true, false) as ScrollContainer
	var options: Array = state.get("options", [])
	for index in range(options.size()):
		var option: Dictionary = options[index]
		var button := panel.find_child("EventOption_%d" % index, true, false) as Button
		if button == null:
			_expect(false, tag + " lost option " + str(index))
			continue
		var rect := button.get_global_rect()
		_expect(rect.position.x >= scroll.global_position.x - 1.0 and rect.end.x <= scroll.get_global_rect().end.x + 1.0, tag + " clipped a button horizontally")
		_expect(button.disabled == not bool(option.get("enabled", true)), tag + " changed option enabled state")
		if event_id == &"z1_event_e25" and String(option.get("id", "")).begins_with("buy_"):
			_expect(scroll.get_global_rect().encloses(rect), tag + " clipped a stocked slot on open")
		_check_option(button, option, tag)


func _check_option(button: Button, option: Dictionary, tag: String) -> void:
	submitted.clear()
	button.pressed.emit()
	if button.disabled:
		_expect(submitted.is_empty(), tag + " dispatched a disabled option")
		return
	var id := StringName(option.get("id", &""))
	if id in [&"compress", &"enter_cage"]:
		var confirm := panel.find_child("ConfirmEventOption", true, false) as Button
		var close := panel.find_child("CloseEventOptions", true, false) as Button
		_expect(confirm != null and confirm.is_visible_in_tree() and submitted.is_empty(), tag + " committed before confirmation")
		if confirm == null or not confirm.is_visible_in_tree():
			return
		close.pressed.emit()
		_expect(submitted.is_empty() and button.is_visible_in_tree(), tag + " cancel changed the event")
		button.pressed.emit()
		confirm.pressed.emit()
		confirm.pressed.emit()
		close.pressed.emit()
	_expect(submitted == [option], tag + " lost, repeated or altered the exact option payload")


func _check_results() -> void:
	var event_id := &"z1_event_e03"
	var context := _fixture(event_id)
	var result := EventServiceScript.execute_option(context, ROOM, &"convert")
	var state := EventServiceScript.get_event_state(context, ROOM)
	var payload := _presentation(context, state)
	popup.call("apply_context", _near_context(payload))
	var status := popup.find_child("ContextStatus", true, false) as Label
	_expect(not bool(popup.call("activate_primary")), "completed room allowed a repeat command")
	_expect(status != null and status.visible and status.text.contains("安全收益") and status.text.contains("6"), "reentered cashout lost the real result")
	popup.hide()
	panel.call("apply_event", state, payload)
	var feedback := panel.find_child("EventRoomFeedback", true, false) as Label
	_expect(feedback != null and feedback.visible and feedback.text.contains(str(result.get("gold_coin_delta", 0))), "completed panel lost the real cashout result")

	event_id = &"z1_event_e13"
	context = _fixture(event_id)
	var rejection := EventServiceScript.execute_option(context, ROOM, &"compress", null, {"instance_ids": ["missing", "other"]})
	state = EventServiceScript.get_event_state(context, ROOM)
	var failed_attempt := _presentation(context, state)
	failed_attempt["attempt_result"] = rejection
	panel.call("apply_event", state, failed_attempt)
	var reason := UISkin.sanitize_player_copy(String(rejection.get("message", ""))).strip_edges()
	_expect(not bool(rejection.get("ok", false)) and not reason.is_empty(), "invalid materials did not produce a localized domain failure")
	_expect(feedback != null and feedback.visible and feedback.text == reason, "the actual domain failure was lost on reopen")

	event_id = &"z1_event_e25"
	context = _fixture(event_id)
	EventServiceScript.execute_option(context, ROOM, &"buy_0")
	state = EventServiceScript.get_event_state(context, ROOM)
	payload = _presentation(context, state)
	panel.call("apply_event", state, payload)
	var sold := panel.find_child("EventShopSlotStatus_0", true, false) as Label
	_expect(sold != null and sold.text.contains("售罄"), "bought slot was not marked sold")
	_expect(not bool(state.get("completed")) and bool(state.get("progress_completed")), "shop fixture did not exercise completion with remaining actions")

	event_id = &"z1_event_e24"
	context = _fixture(event_id)
	EventServiceScript.execute_option(context, ROOM, &"enter_cage")
	var victory := EventServiceScript.resolve_cage(context, ROOM, true)
	state = EventServiceScript.get_event_state(context, ROOM)
	popup.call("apply_context", _near_context(_presentation(context, state)))
	_expect(not bool(popup.call("activate_primary")), "defeated cage remained actionable")
	_expect(status.visible and status.text.contains("胜利") and status.text.contains(str(victory.get("power_delta", 0))), "cage result lost its real power gain")
	popup.hide()

	context = _fixture(&"altar")
	EventServiceScript.execute_option(context, ROOM, &"offer_hp")
	state = EventServiceScript.get_event_state(context, ROOM)
	panel.call("apply_event", state, _presentation(context, state))
	var readout := panel.find_child("EventRoomReadout", true, false) as Label
	_expect(readout != null and readout.visible and readout.text.contains("2/5"), "altar did not show the actual next stage")
	_expect(feedback != null and feedback.visible and feedback.text.contains("第 1/5"), "altar did not retain the first offering result")


func _fixture(event_id: StringName) -> RunContext:
	var context := RunContext.new()
	context.start_run({
		"id": "z1_event_room_ui", "seed": 301, "width": 5, "height": 5, "power": 20,
		"backpack_capacity": 100, "manual_map": {"spawn": Vector2i.ZERO, "events": [ROOM],
		"mines": [Vector2i(2, 1)], "exits": [{"pos": Vector2i(4, 4), "exit_id": "test_exit", "random_exit": true}]},
	})
	context.player_pos = ROOM
	context.current_pos = ROOM
	context.current_room_type = &"Event"
	context.z1_event_rooms[context.cell_key(ROOM)] = {"event_type": event_id}
	context.intel_map.reveal_cell(ROOM, context.truth_map)
	context.intel_map.toggle_flag(Vector2i(2, 1))
	context.asset_ledger.add_currency(&"black_coin", 250, "ui_fixture")
	context.pressure = 42
	context.hp = 60
	for item_id in ["col_01", "col_02", "col_13", "sp_inspection_calibration_plate", "con_tape_roll",
			"con_ration", "con_med_patch", "sp_transit_lead_seal", "sp_depressurized_valve_core", "sp_reset_spring"]:
		var item := Items.item_definition(item_id)
		if not item.is_empty():
			item["reward_location"] = RunAssetLedger.LOCATION_INVENTORY
			context.asset_ledger.add_reward_items([item], RunAssetLedger.LOCATION_INVENTORY, ROOM, "ui_fixture")
	context.asset_ledger.sync_compat_fields(context)
	return context


func _presentation(context: RunContext, state: Dictionary) -> Dictionary:
	var event_id := StringName(state.get("event_type"))
	var number := Events.number(event_id)
	return {
		"room_key": context.cell_key(ROOM), "room_pos": ROOM, "event_type": event_id,
		"completed": bool(state.get("completed", false)), "display_only": bool(state.get("completed", false)),
		"display_title": state.get("player_title", "异常事件"),
		"summary": state.get("description", ""),
		"event_icon_asset_id": StringName("z1.event.e%02d" % number) if number > 0 else &"",
		"last_result": state.get("last_result", {}),
		"inventory_items": context.asset_ledger.get_items_by_location(RunAssetLedger.LOCATION_INVENTORY),
	}


func _near_context(payload: Dictionary) -> Dictionary:
	return {"interaction_kind": &"event", "world_pos": Vector2(620, 340), "player_world_pos": Vector2(560, 370),
		"room_bounds": Rect2(330, 8, 600, 600), "payload": payload}


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
