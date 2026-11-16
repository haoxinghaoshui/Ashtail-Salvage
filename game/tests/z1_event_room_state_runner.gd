extends SceneTree

const EventServiceScript := preload("res://scripts/core/run/event_service.gd")
const EventCatalog := preload("res://scripts/core/content/z1_event_catalog.gd")
const DeviceStatePath := "res://scripts/presentation/z1/z1_event_room_state.gd"
const ORIGIN := Vector2i(2, 2)
const OTHER_EVENT := Vector2i(3, 2)
const MINE := Vector2i(2, 1)
const HALL := Vector2i(1, 2)

var failures: Array[String] = []
var device_state_script: Script


func _initialize() -> void:
	if ResourceLoader.exists(DeviceStatePath):
		device_state_script = load(DeviceStatePath)
	_check(device_state_script != null, "device_state_script_missing")
	_test_device_coverage()
	_test_work_lights()
	_test_recon_and_relief()
	_test_direction_markers()
	_test_hands_cage_and_stock()
	_test_legacy_devices()
	_test_revisit_receipts()
	for failure in failures:
		print("Z1_EVENT_ROOM_STATE_CASE_FAIL ", failure)
	print("Z1_EVENT_ROOM_STATE=PASS" if failures.is_empty() else "Z1_EVENT_ROOM_STATE=FAIL")
	quit(0 if failures.is_empty() else 1)


func _test_device_coverage() -> void:
	var event_ids := EventCatalog.event_ids()
	event_ids.append_array([&"trader", &"dice", &"altar", &"trap"])
	for event_type in event_ids:
		var context := _event(event_type)
		_check_state(context, &"ready", {})
		if device_state_script != null:
			_check(_device(context).has("stock") == (event_type == &"z1_event_e25"), "stock_only_on_supply")
	var cabinet := _event(&"z1_event_e06")
	_check_state(cabinet, &"ready", {"cabinet_open": false})
	_act(cabinet, &"force_open")
	_revisit(cabinet)
	_check_state(cabinet, &"complete", {"cabinet_open": true})


func _test_work_lights() -> void:
	var context := _event(&"z1_event_e20")
	_check_work(context, false, 0, false, &"ready")
	_act(context, &"start_work")
	_check_work(context, true, 0, false, &"active")
	context.z1_event_rooms[context.cell_key(OTHER_EVENT)] = {"event_type": &"z1_event_e20"}
	var other: Dictionary = EventServiceScript.get_event_state(context, OTHER_EVENT).get("work_order", {})
	_check(not bool(other.get("started", true)) and int(other.get("visited", -1)) == 0, "work_progress_is_local_to_origin")
	for step in [[HALL, 1], [HALL, 1], [Vector2i(1, 3), 2], [Vector2i(1, 4), 3], [Vector2i(0, 4), 3]]:
		_enter(context, step[0])
		_enter(context, ORIGIN)
		_check_work(context, true, step[1], false, &"ready_to_claim" if step[1] == 3 else &"active")
	_act(context, &"claim_work")
	_revisit(context)
	_check_work(context, true, 3, true, &"complete")
	_check(_coins(context) == 108, "work_payment_unchanged")


func _test_recon_and_relief() -> void:
	for size in [3, 5, 7]:
		var context := _event(&"z1_event_e21")
		_check(not _state(context).has("recon_size"), "no_recon_marker_before_scan")
		_act(context, StringName("recon_%d" % size))
		_check(context.z1_event_intel.get(context.cell_key(MINE), {}).get("known_mine", false), "recon_option_marks_known_mine")
		_act(context, &"leave")
		_revisit(context)
		_check(_state(context).get("recon_size") == size, "recon_size_keeps_paid_scan_%d" % size)
		_check_state(context, &"complete", {"recon_size": size})

	var relief := _event(&"z1_event_e23")
	relief.pressure = 2
	var rejected := RoomResolver.new().select_event_option(relief, &"footbath")
	_check(not bool(rejected.get("ok", true)) and not _state(relief).has("pressure_relief"), "rejected_relief_does_not_publish_action")
	relief.pressure = 45
	_act(relief, &"massage")
	var actual_delta := relief.pressure - 45
	_check(actual_delta == -13, "relief_applies_real_reduction")
	_act(relief, &"leave")
	_revisit(relief)
	_check(_state(relief).get("pressure_relief") == {"service": &"massage", "pressure_delta": actual_delta}, "relief_snapshot_keeps_success_after_leave")
	_check_state(relief, &"complete", {"service": &"massage", "pressure_delta": actual_delta})


func _test_direction_markers() -> void:
	var shortcut := _event(&"z1_event_e16")
	var option: Dictionary = _state(shortcut).get("options", [])[0]
	var target: Vector2i = option.get("payload", {}).get("target_pos", Vector2i.ZERO)
	_check_state(shortcut, &"ready", {"target_offset": target - ORIGIN})
	_act(shortcut, &"travel")
	_check(shortcut.get_current_pos() == target, "shortcut_enters_actual_target")
	_enter(shortcut, ORIGIN)
	_act(shortcut, &"leave")
	_check(_state(shortcut).get("shortcut_target") == target, "shortcut_keeps_actual_target")
	_check_state(shortcut, &"complete", {"target_offset": target - ORIGIN})
	for detonation_target in [MINE, OTHER_EVENT]:
		var context := _event(&"z1_event_e19")
		context.intel_map.flag_cell(detonation_target)
		_check(not _state(context).has("detonation"), "detonation_does_not_expose_hidden_mine")
		_act(context, &"detonate", {"target_pos": detonation_target})
		_revisit(context)
		var hit: bool = detonation_target == MINE
		_check(_state(context).get("detonation") == {"target_pos": detonation_target, "hit": hit}, "detonation_keeps_public_result")
		_check_state(context, &"complete", {"target_offset": detonation_target - ORIGIN, "detonated": hit})


func _test_hands_cage_and_stock() -> void:
	var game := _event(&"z1_event_e22")
	_act(game, &"paper")
	_revisit(game)
	var game_state := _state(game)
	var round: Dictionary = game_state.get("rounds", [])[0]
	_check_state(game, &"active", {"player_hand": &"paper", "opponent_hand": round["opponent"], "round_result": StringName(round["result"]), "round_count": 1, "wins": game_state["wins"], "losses": game_state["losses"]})
	var cage := _event(&"z1_event_e24")
	_act(cage, &"enter_cage")
	_check_state(cage, &"active", {"cage_locked": true})
	EventServiceScript.resolve_cage(cage, ORIGIN, true)
	_revisit(cage)
	_check_state(cage, &"complete", {"cage_locked": false})

	var supply := _event(&"z1_event_e25")
	_act(supply, &"buy_0")
	_revisit(supply)
	var public_state := _state(supply)
	var stock: Array = public_state.get("stock", [])
	_check(stock.size() == 3 and bool(stock[0].get("sold", false)), "supply_sold_slot_persists")
	if device_state_script != null:
		var visible_stock: Array = _device(supply).get("stock", [])
		_check(visible_stock.size() == 3 and visible_stock[0] == {"item_id": stock[0]["item_id"], "display_name": stock[0]["display_name"], "price": stock[0]["price"], "sold": true}, "supply_projection_matches_public_slot")
		visible_stock[0]["sold"] = false
		_check(_state(supply).get("stock") == stock, "projection_does_not_mutate_authority")
	_act(supply, &"refresh")
	_check(_state(supply).get("refresh_count") == 1, "supply_refresh_count_is_public")
	_check_state(supply, &"ready", {"refresh_count": 1})


func _test_legacy_devices() -> void:
	var altar := _event(&"altar")
	_check(_state(altar).get("altar_stage") == 1, "altar_initial_stage")
	_act(altar, &"offer_hp")
	_revisit(altar)
	_check(_state(altar).get("altar_stage") == 2, "altar_next_stage_after_real_offer")
	_check_state(altar, &"active", {"altar_stage": 2, "altar_stage_total": 5, "altar_stages_completed": 1})

	var dice := _event(&"dice")
	var result := _act(dice, &"bet_small")
	_revisit(dice)
	_check(_state(dice).get("dice_roll") == result.get("roll"), "dice_keeps_real_roll")
	_check_state(dice, &"complete", {"dice_roll": result.get("roll")})

	for triggered in [false, true]:
		var trap := _event(&"trap")
		var threshold := int(_state(trap).get("trap_threshold", 0))
		trap.power = threshold - int(triggered)
		_act(trap, &"disarm")
		_revisit(trap)
		_check(_state(trap).get("trap_triggered") == triggered, "trap_keeps_actual_result_%s" % triggered)
		_check_state(trap, &"complete", {"trap_triggered": triggered, "trap_threshold": threshold})


func _test_revisit_receipts() -> void:
	var shop := _event(&"z1_event_e25")
	_act(shop, &"buy_0")
	var purchased: Dictionary = _state(shop).get("last_result", {})
	_check(purchased.get("option_id") == &"buy_0", "purchase_has_public_receipt")
	var repeated := RoomResolver.new().select_event_option(shop, &"buy_0")
	_check(not bool(repeated.get("ok", true)), "repeat_purchase_rejected")
	_check(_state(shop).get("last_result") == purchased, "rejected_repeat_keeps_purchase_receipt")
	_act(shop, &"leave")
	_revisit(shop)
	_check(_state(shop).get("last_result") == purchased, "leave_and_revisit_keep_purchase_receipt")
	_act(shop, &"refresh")
	_check(_state(shop).get("last_result", {}).get("option_id") == &"refresh", "real_refresh_replaces_purchase_receipt")

	var cabinet := _event(&"z1_event_e06")
	_act(cabinet, &"force_open")
	var opened: Dictionary = _state(cabinet).get("last_result", {})
	_act(cabinet, &"force_open")
	_check(_state(cabinet).get("last_result") == opened, "already_completed_action_keeps_receipt")

	var trader := _event(&"trader")
	trader.hp = trader.max_hp - 5
	var before_treatment_coin := _coins(trader)
	_act(trader, &"buy_treatment")
	_revisit(trader)
	var treated := _check_legacy_receipt(trader, &"buy_treatment", {"hp_delta": 5, "spend_black_coin": before_treatment_coin - _coins(trader)})
	trader.z1_event_rooms[trader.cell_key(OTHER_EVENT)] = {"event_type": &"trader"}
	_enter(trader, OTHER_EVENT)
	_check(_state(trader).get("last_result", {}).is_empty(), "receipt_does_not_cross_same_type_rooms")
	_enter(trader, ORIGIN)
	_check(_state(trader).get("last_result", {}) == treated, "trader_receipt_keeps_room_identity")

	var dice := _event(&"dice")
	var before_coin := _coins(dice)
	var bet := _act(dice, &"bet_small")
	_act(dice, &"bet_small")
	_revisit(dice)
	_check_legacy_receipt(dice, &"bet_small", {"roll": bet["roll"], "black_coin_delta": _coins(dice) - before_coin})

	var altar := _event(&"altar")
	var offer := _act(altar, &"offer_hp")
	var offering := _check_legacy_receipt(altar, &"offer_hp", {"altar_stage": 1, "altar_stage_total": 5, "hp_delta": offer["hp_delta"], "black_coin_delta": offer["black_coin_delta"]})
	altar.hp = 1
	var rejected := RoomResolver.new().select_event_option(altar, &"offer_hp")
	_check(not bool(rejected.get("ok", true)), "altar_followup_rejected_at_one_hp")
	_act(altar, &"leave")
	_revisit(altar)
	_check(_state(altar).get("last_result", {}) == offering, "altar_failed_followup_and_leave_keep_receipt")

	var trap := _event(&"trap")
	var threshold := int(_state(trap).get("trap_threshold", 0))
	trap.power = threshold - 1
	trap.protocol_pressure_reduce = 2
	var before_hp := trap.hp
	var before_pressure := trap.pressure
	_act(trap, &"disarm")
	_revisit(trap)
	_check_legacy_receipt(trap, &"disarm", {
		"trap_threshold": threshold,
		"trap_triggered": true,
		"hp_delta": trap.hp - before_hp,
		"pressure_delta": trap.pressure - before_pressure,
	})


func _check_legacy_receipt(context: RunContext, option_id: StringName, expected: Dictionary) -> Dictionary:
	var event_state := _state(context)
	var receipt: Dictionary = event_state.get("last_result", {})
	_check(receipt.get("option_id") == option_id and receipt.get("event_type") == event_state.get("event_type") and bool(receipt.get("ok", false)), "legacy_receipt_%s" % option_id)
	for key in expected:
		_check(receipt.get(key) == expected[key], "legacy_receipt_%s_%s" % [option_id, key])
	for key in receipt:
		_check(key in [
			"ok", "completed", "option_id", "event_type", "roll", "altar_stage", "altar_stage_total",
			"hp_delta", "pressure_delta", "black_coin_delta", "gold_coin_delta", "spend_black_coin",
			"trap_threshold", "trap_triggered",
		], "legacy_receipt_no_internal_%s_%s" % [option_id, key])
	return receipt


func _check_work(context: RunContext, started: bool, visited: int, claimed: bool, expected_state: StringName) -> void:
	_check(_state(context).get("work_order") == {"started": started, "visited": visited, "required": 3, "claimed": claimed}, "work_snapshot_%s_%d" % [expected_state, visited])
	_check_state(context, expected_state, {"work_visited": visited, "work_required": 3, "work_claimed": claimed})


func _event(event_type: StringName) -> RunContext:
	var context := RunContext.new()
	context.start_run({
		"id": "z1_event_room_state_test", "seed": 301, "width": 5, "height": 5,
		"manual_map": {"spawn": Vector2i.ZERO, "events": [ORIGIN, OTHER_EVENT], "mines": [MINE]},
	})
	context.asset_ledger.add_currency(&"black_coin", 100, "test")
	context.asset_ledger.sync_compat_fields(context)
	context.z1_event_rooms[context.cell_key(ORIGIN)] = {"event_type": event_type}
	_enter(context, ORIGIN)
	return context


func _enter(context: RunContext, pos: Vector2i) -> void:
	context.player_pos = pos
	context.current_pos = pos
	RoomResolver.new().enter_room(context)


func _revisit(context: RunContext) -> void:
	_enter(context, HALL)
	_enter(context, ORIGIN)


func _act(context: RunContext, option_id: StringName, payload: Dictionary = {}) -> Dictionary:
	var result := RoomResolver.new().select_event_option(context, option_id, payload)
	_check(bool(result.get("ok", false)), "production_action_%s" % option_id)
	return result


func _coins(context: RunContext) -> int:
	return context.asset_ledger.get_currency(&"black_coin")


func _state(context: RunContext) -> Dictionary:
	return context.get_status_snapshot().get("event_state", {})


func _device(context: RunContext) -> Dictionary:
	var public_state := _state(context)
	return device_state_script.call("describe", public_state.get("event_type", &""), public_state, context.get_current_pos())


func _check_state(context: RunContext, expected_state: StringName, expected_markers: Dictionary) -> void:
	if device_state_script == null:
		return
	var projected := _device(context)
	var event_type: StringName = _state(context).get("event_type", &"")
	_check(projected.get("state_id") == expected_state, "%s_state_%s" % [event_type, expected_state])
	for marker in expected_markers:
		_check(projected.get("markers", {}).get(marker) == expected_markers[marker], "%s_marker_%s" % [event_type, marker])


func _check(condition: bool, label: String) -> void:
	if not condition:
		failures.append(label)
