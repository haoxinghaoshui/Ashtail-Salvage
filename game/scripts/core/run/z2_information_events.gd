extends RefCounted
class_name Z2InformationEvents

const Snapshot = preload("res://scripts/core/run/run_state_snapshot.gd")
const Effects = preload("res://scripts/core/run/run_effect_applier.gd")
const EVENTS := ["information", "shortcut", "demine", "recon"]
const LEGACY_IDS := {
	"z1_event_e01": "information", "z1_event_e04": "information", "z1_event_e17": "information",
	"z1_event_e16": "shortcut", "z1_event_e19": "demine", "z1_event_e21": "recon",
}
const DIAGONALS := [Vector2i(-1, -1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(1, 1)]
const CARDINALS := [Vector2i.UP, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT]
const RECON_PRICES := {"recon_3": 10, "recon_5": 30, "recon_7": 70}
const INFORMATION_SERVICE_FLAG := "z2_information_service_completed"

# S3 E9/B25, E226, E257, E290; legacy event numbers differ from S3's 22 rows.
# Projections never prepare, draw, pay, visit, flag, save, or award growth.
static func public_state(context: RunContext, pos: Vector2i, event_id: String) -> Dictionary:
	var event := _canonical(event_id)
	var reason := _validate(context, pos, event, false)
	if not reason.is_empty():
		return _fail(reason)
	var state := _room(context, pos, event)
	var quote: Dictionary = state.get("quote", {})
	return {
		"ok": true, "event_type": event, "room_key": context.cell_key(pos),
		"prepared": not quote.is_empty(), "requires_prepare": not bool(state.get("completed", false)) and (quote.is_empty() or _stale_quote(context, event, quote)),
		"completed": bool(state.get("completed", false)), "remaining_uses": int(state.get("remaining_uses", 1)),
		"quote_id": str(quote.get("quote_id", "")), "quote": quote.duplicate(true),
		"targets": state.get("targets", []).duplicate(), "preview": state.get("preview", {}).duplicate(true),
		"last_result": state.get("last_result", {}).duplicate(true), "options": _options(context, pos, event, state),
	}


static func options(context: RunContext, pos: Vector2i, event_id: String) -> Array:
	return public_state(context, pos, event_id).get("options", [])


# MUST be called inside RunRuntimeController.execute_atomic_operation. This
# function edits only the candidate context; the parent owns persistence,
# publication, growth consumers and runtime bindings. Failed local effects are
# also rolled back for callers inspecting the candidate before outer commit.
# enter_room is a trusted parent Callable(request), not part of the UI payload.
# It must perform actual entry (including protocol/mine costs), never the fee.
static func execute(context: RunContext, pos: Vector2i, event_id: String, option_id: String, payload: Dictionary = {}, enter_room: Callable = Callable()) -> Dictionary:
	var event := _canonical(event_id)
	var reason := _validate(context, pos, event, true)
	if not reason.is_empty():
		return _fail(reason)
	if option_id == "leave":
		return {"ok": true, "completed": false, "stage_completed": false, "facts": {}}
	var state := _room(context, pos, event)
	if bool(state.get("completed", false)):
		return _fail("already_completed")
	if option_id == "prepare":
		return _prepare(context, pos, event, state)
	var quote: Dictionary = state.get("quote", {})
	if quote.is_empty():
		return _fail("not_prepared")
	if str(payload.get("quote_id", "")) != str(quote.quote_id) or _stale_quote(context, event, quote):
		return _fail("stale_quote")
	if event == "shortcut" and option_id == "preview_target":
		return _preview(context, pos, state, payload)
	var fee := _fee(event, option_id, quote)
	if fee < 0:
		return _fail("invalid_option")
	if context.asset_ledger.get_currency(&"black_coin") < fee:
		return _fail("insufficient_black")
	var before := Snapshot.capture_context(context)
	var result: Dictionary
	match event:
		"information":
			result = _information(context, pos, option_id)
		"recon":
			result = _reveal_mines(context, pos, int(option_id.trim_prefix("recon_")))
		"demine":
			result = _demine(context, pos, payload)
		"shortcut":
			result = _travel(context, pos, state, payload, enter_room)
	if bool(result.get("ok", false)):
		var paid := context.asset_ledger.spend_currency(&"black_coin", fee, "event_" + event) if fee > 0 else {"ok": true}
		if not bool(paid.get("ok", false)):
			result = _fail("insufficient_black")
	if not bool(result.get("ok", false)):
		Snapshot.install_context(context, before)
		return result
	if event in ["information", "recon"]:
		context.z1_event_flags[INFORMATION_SERVICE_FLAG] = true
	context.asset_ledger.sync_compat_fields(context)
	return _complete(context, pos, event, option_id, fee, state, result)


static func _canonical(event_id: String) -> String:
	return str(LEGACY_IDS.get(event_id, event_id))


static func _validate(context: RunContext, pos: Vector2i, event: String, current: bool) -> String:
	if context == null or context.truth_map == null or context.intel_map == null or context.asset_ledger == null:
		return "no_active_run"
	if not EVENTS.has(event):
		return "unsupported_event"
	if not context.truth_map.is_inside(pos):
		return "invalid_room"
	if current and (not context.run_active or context.failed or context.extracted or context.abandoned):
		return "no_active_run"
	if current and context.get_current_pos() != pos:
		return "not_current_room"
	return ""


static func _fail(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason, "stage_completed": false}


static func _room(context: RunContext, pos: Vector2i, event: String) -> Dictionary:
	return context.z1_event_rooms.get(context.cell_key(pos), {}).get("z2_information", {}).get(event,
		{"completed": false, "remaining_uses": 1}).duplicate(true)


static func _store(context: RunContext, pos: Vector2i, event: String, state: Dictionary) -> void:
	var key := context.cell_key(pos)
	var room: Dictionary = context.z1_event_rooms.get(key, {}).duplicate(true)
	var information: Dictionary = room.get("z2_information", {})
	information[event] = state.duplicate(true)
	room["z2_information"] = information
	context.z1_event_rooms[key] = room


static func _information_fee(context: RunContext) -> int:
	return 3 if bool(context.z1_event_flags.get(INFORMATION_SERVICE_FLAG, false)) else 5


static func _stale_quote(context: RunContext, event: String, quote: Dictionary) -> bool:
	return event == "information" and int(quote.get("paid_fee_black", -1)) != _information_fee(context)


static func _prepare(context: RunContext, pos: Vector2i, event: String, state: Dictionary) -> Dictionary:
	if event == "shortcut" and not state.has("targets"):
		var candidates: Array[Vector2i] = []
		for offset in DIAGONALS:
			if context.truth_map.is_inside(pos + offset):
				candidates.append(pos + offset)
		if candidates.is_empty():
			return _fail("no_shortcut_target")
		var rng := RandomNumberGenerator.new()
		rng.seed = ("t11:shortcut:%d:%s" % [context.seed_value, context.cell_key(pos)]).hash()
		var count := mini(candidates.size(), rng.randi_range(1, 2))
		var targets: Array[Vector2i] = []
		for index in range(count):
			var selected := rng.randi_range(0, candidates.size() - 1)
			targets.append(candidates[selected])
			candidates.remove_at(selected)
		state["targets"] = targets
	var quote := {"event_type": event, "room_key": context.cell_key(pos), "run_id": str(context.run_id)}
	match event:
		"information": quote["paid_fee_black"] = _information_fee(context)
		"shortcut":
			quote["fee_black"] = 6
			quote["targets"] = state.targets.duplicate()
		"demine": quote["fee_black"] = 7
		"recon": quote["prices"] = RECON_PRICES.duplicate()
	quote["quote_id"] = Snapshot.fingerprint(quote)
	state["quote"] = quote
	_store(context, pos, event, state)
	return {"ok": true, "stage_completed": false, "facts": {}, "public_state": public_state(context, pos, event)}


static func _fee(event: String, option: String, quote: Dictionary) -> int:
	match event:
		"information":
			if option == "mine_count":
				return 0
			if option in ["mine_locations", "chest_locations", "exit_direction"]:
				return int(quote.paid_fee_black)
		"shortcut": return 6 if option == "travel" else -1
		"demine": return 7 if option == "detonate" else -1
		"recon": return int(RECON_PRICES.get(option, -1))
	return -1


static func _options(context: RunContext, pos: Vector2i, event: String, state: Dictionary) -> Array:
	if not state.has("quote") or bool(state.get("completed", false)):
		return []
	var rows: Array = []
	var quote: Dictionary = state.quote
	match event:
		"information":
			for action in ["mine_count", "mine_locations", "chest_locations", "exit_direction"]:
				rows.append(_option(context, action, _fee(event, action, quote), quote))
		"recon":
			for action in RECON_PRICES:
				rows.append(_option(context, action, int(RECON_PRICES[action]), quote))
		"demine":
			for offset in CARDINALS:
				var target: Vector2i = pos + offset
				if _manual_flag(context, target):
					rows.append(_option(context, "detonate", 7, quote, {"target_pos": target}))
		"shortcut":
			for target in state.get("targets", []):
				var row := _option(context, "preview_target", 0, quote, {"target_pos": target})
				row["travel_fee_black"] = 6
				row["direction"] = _direction(pos, target)
				row["known"] = context.intel_map.get_cell_info(target)
				rows.append(row)
			var preview: Dictionary = state.get("preview", {})
			if not preview.is_empty():
				var row := _option(context, "travel", 6, quote, {"target_pos": preview.target_pos, "preview_id": preview.preview_id})
				row["requires_confirmation"] = bool(preview.flagged)
				rows.append(row)
	return rows


static func _option(context: RunContext, id: String, fee: int, quote: Dictionary, payload: Dictionary = {}) -> Dictionary:
	var params := payload.duplicate(true)
	params["quote_id"] = quote.quote_id
	var affordable := context.asset_ledger.get_currency(&"black_coin") >= fee
	var stale := _stale_quote(context, str(quote.event_type), quote)
	return {"id": id, "fee_black": fee, "enabled": affordable and not stale,
		"reason": "stale_quote" if stale else ("" if affordable else "insufficient_black"), "payload": params}


static func _square(context: RunContext, pos: Vector2i, size: int) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	var radius := size >> 1
	for y in range(maxi(0, pos.y - radius), mini(context.truth_map.height, pos.y + radius + 1)):
		for x in range(maxi(0, pos.x - radius), mini(context.truth_map.width, pos.x + radius + 1)):
			result.append(Vector2i(x, y))
	return result


static func _knows_mine(context: RunContext, pos: Vector2i) -> bool:
	return context.intel_map.is_revealed(pos) or bool(context.intel_map.get_cell_info(pos).get("confirmed_mine", false)) or bool(context.z1_event_intel.get(context.cell_key(pos), {}).get("known_mine", false))


static func _learn(context: RunContext, pos: Vector2i, fields: Dictionary) -> void:
	var key := context.cell_key(pos)
	var knowledge: Dictionary = context.z1_event_intel.get(key, {}).duplicate(true)
	knowledge.merge(fields, true)
	knowledge["position"] = pos
	context.z1_event_intel[key] = knowledge
	context.intel_map.learn_event_intel(pos, knowledge)
	if bool(knowledge.get("known_chest", false)):
		context.intel_map.scan_cell(pos, context.truth_map, &"room_type", 1.0)


static func _reveal_mines(context: RunContext, pos: Vector2i, size: int) -> Dictionary:
	var revealed: Array[Vector2i] = []
	for target in _square(context, pos, size):
		if context.truth_map.is_mine(target) and not _knows_mine(context, target):
			_learn(context, target, {"known_mine": true})
			revealed.append(target)
	if revealed.is_empty():
		return _fail("no_new_intel")
	return {"ok": true, "facts": {"intel_revealed_count": revealed.size(), "intel_positions": revealed, "scan_size": size}}


static func _information(context: RunContext, pos: Vector2i, option: String) -> Dictionary:
	if option == "mine_locations":
		return _reveal_mines(context, pos, 3)
	var facts := {"intel_revealed_count": 0}
	if option == "mine_count":
		var count := 0
		for target in _square(context, pos, 5):
			if context.truth_map.is_mine(target):
				count += 1
		facts["mine_count"] = count
		facts["scan_size"] = 5
	elif option == "chest_locations":
		var revealed: Array[Vector2i] = []
		for target in _square(context, pos, 5):
			var known: Dictionary = context.z1_event_intel.get(context.cell_key(target), {})
			var public_cell := context.intel_map.get_cell_info(target)
			var known_chest := bool(known.get("known_chest", false)) or str(public_cell.get("scan_room_type_hint", "")) == "Chest"
			if context.truth_map.get_room_type(target) == &"Chest" and not context.intel_map.is_revealed(target) and not known_chest:
				_learn(context, target, {"known_chest": true})
				revealed.append(target)
		if revealed.is_empty():
			return _fail("no_new_intel")
		facts["intel_revealed_count"] = revealed.size()
		facts["intel_positions"] = revealed
	elif option == "exit_direction":
		var exits := context.truth_map.get_exits()
		if exits.is_empty():
			return _fail("no_exit")
		# Four-direction grid distance; stable y/x tie break. Return direction only.
		exits.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
			var da := absi(pos.x - a.x) + absi(pos.y - a.y)
			var db := absi(pos.x - b.x) + absi(pos.y - b.y)
			return da < db if da != db else (a.y < b.y if a.y != b.y else a.x < b.x))
		facts["exit_direction"] = _direction(pos, exits[0])
	return {"ok": true, "facts": facts}


static func _manual_flag(context: RunContext, pos: Vector2i) -> bool:
	var mark: Dictionary = context.intel_map.mark_map.get(context.cell_key(pos), {})
	return context.truth_map.is_inside(pos) and context.intel_map.is_flagged(pos) and bool(mark.get("marked", false)) and str(mark.get("mark_type", "")) == "risk_flag"


static func _demine(context: RunContext, pos: Vector2i, payload: Dictionary) -> Dictionary:
	var target: Variant = payload.get("target_pos")
	if not target is Vector2i or not context.truth_map.is_inside(target) or not CARDINALS.has(target - pos):
		return _fail("invalid_target")
	if not _manual_flag(context, target):
		return _fail("manual_flag_required")
	var key := context.cell_key(target)
	var remote: Dictionary = context.z1_event_flags.get("remote_mines", {}).duplicate(true)
	if context.truth_map.is_mine(target) and (context.truth_map.is_triggered(target) or bool(remote.get(key, false))):
		return _fail("mine_already_inactive")
	var hit := context.truth_map.is_mine(target)
	var facts := {"target_pos": target, "hit": hit, "mines_disarmed": 0, "pressure_delta": 0, "intel_revealed_count": 0}
	if hit:
		# Remote service is not an actual player mine hit; do not consume on-hit rules.
		var pressure := Effects.apply_pressure_packet(context, {"amount": 10, "source_id": "event_demine", "reason": "event_demine"})
		if not bool(pressure.get("ok", false)):
			return _fail(str(pressure.get("reason", "pressure_failed")))
		facts["pressure_delta"] = int(pressure.facts.get("actual_pressure_delta", 0))
		facts["pressure_facts"] = pressure.facts.duplicate(true)
		facts["mines_disarmed"] = 1
		facts["intel_revealed_count"] = 0 if _knows_mine(context, target) else 1
		remote[key] = true
		context.z1_event_flags["remote_mines"] = remote
		# Keep mine=true and the original adjacency. RoomResolver reads remote_mines.
		context.truth_map.mark_triggered(target)
		_learn(context, target, {"known_mine": true, "mine_triggered": true})
	return {"ok": true, "facts": facts}


static func _preview(context: RunContext, pos: Vector2i, state: Dictionary, payload: Dictionary) -> Dictionary:
	var target: Variant = payload.get("target_pos")
	if not target is Vector2i or not state.get("targets", []).has(target):
		return _fail("invalid_target")
	var preview := _target_preview(context, pos, target, state.quote)
	state["preview"] = preview
	_store(context, pos, "shortcut", state)
	return {"ok": true, "stage_completed": false, "facts": {}, "preview": preview.duplicate(true)}


static func _target_preview(context: RunContext, pos: Vector2i, target: Vector2i, quote: Dictionary) -> Dictionary:
	var preview := {"origin": pos, "target_pos": target, "direction": _direction(pos, target),
		"known": context.intel_map.get_cell_info(target), "flagged": context.intel_map.is_flagged(target),
		"fee_black": 6, "quote_id": quote.quote_id}
	preview["preview_id"] = Snapshot.fingerprint(preview)
	return preview


static func _travel(context: RunContext, pos: Vector2i, state: Dictionary, payload: Dictionary, enter_room: Callable) -> Dictionary:
	var target: Variant = payload.get("target_pos")
	if not target is Vector2i or not state.get("targets", []).has(target):
		return _fail("invalid_target")
	var preview: Dictionary = state.get("preview", {})
	if preview.is_empty() or preview.get("target_pos") != target or str(payload.get("preview_id", "")) != str(preview.get("preview_id", "")):
		return _fail("preview_required")
	if preview != _target_preview(context, pos, target, state.quote):
		return _fail("stale_preview")
	var confirmed := payload.get("confirmed_flag", false) is bool and bool(payload.get("confirmed_flag", false))
	if context.intel_map.is_flagged(target) and not confirmed:
		return _fail("flag_confirmation_required")
	var request := {"kind": "shortcut_entry", "origin": pos, "target_pos": target, "confirmed_flag": confirmed,
		"fee_black": 6, "quote_id": state.quote.quote_id, "preview_id": preview.preview_id}
	if not enter_room.is_valid():
		var missing := _fail("room_entry_handler_required")
		missing["transition_request"] = request
		return missing
	var returned: Variant = enter_room.call(request.duplicate(true))
	if not returned is Dictionary:
		return _fail("invalid_entry_result")
	if not bool(returned.get("ok", false)):
		return _fail(str(returned.get("reason", "entry_failed")))
	if not returned.get("room_entry_result", {}) is Dictionary:
		return _fail("invalid_entry_result")
	var receipt: Dictionary = returned.get("room_entry_result", {})
	if context.get_current_pos() != target or context.player_pos != target or not context.visited_cells.has(context.cell_key(target)) or not bool(context.truth_map.get_cell(target).get("explored", false)) or receipt.get("position") != target:
		return _fail("entry_not_completed")
	return {"ok": true, "room_entry_result": receipt.duplicate(true), "facts": {"origin": pos, "target_pos": target, "rooms_entered": 1, "intel_revealed_count": 0}}


static func _complete(context: RunContext, pos: Vector2i, event: String, option: String, fee: int, state: Dictionary, result: Dictionary) -> Dictionary:
	var room_key := context.cell_key(pos)
	var stage_id := "z2:information:%s:%s:delivered" % [room_key, event]
	var xp_key := "z2:event_room:" + room_key
	var first_room := not context.interacted_cells.has(room_key)
	var facts: Dictionary = result.get("facts", {}).duplicate(true)
	facts.merge({"event_type": event, "option_id": option, "room_key": room_key, "fee_black": fee})
	var stage := {"kind": "event_stage_completed", "stage_id": stage_id, "xp_key": xp_key,
		"event_type": event, "position": pos, "effective": true, "base_xp": 5 if first_room else 0,
		"base_talent": 2, "facts": facts.duplicate(true)}
	result.merge({"ok": true, "completed": true, "progress_completed": true,
		"event_type": event, "option_id": option, "stage_completed": true, "first_room_completion": first_room,
		"stage_id": stage_id, "xp_key": xp_key, "base_xp": stage.base_xp, "base_talent": 2,
		"stage_fact": stage, "facts": facts, "quote_id": state.quote.quote_id}, true)
	state["completed"] = true
	state["remaining_uses"] = 0
	state["last_result"] = result.duplicate(true)
	context.interacted_cells[room_key] = true
	_store(context, pos, event, state)
	return result


static func _direction(origin: Vector2i, target: Vector2i) -> String:
	var vertical := "N" if target.y < origin.y else ("S" if target.y > origin.y else "")
	var horizontal := "W" if target.x < origin.x else ("E" if target.x > origin.x else "")
	return vertical + horizontal if target != origin else "HERE"
