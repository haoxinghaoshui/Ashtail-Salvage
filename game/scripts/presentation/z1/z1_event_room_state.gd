extends RefCounted
class_name Z1EventRoomState


static func describe(event_type: StringName, public_state: Dictionary, room_pos: Vector2i) -> Dictionary:
	var completed := bool(public_state.get("completed", false))
	var markers := {}
	var description := {"state_id": &"complete" if completed else &"ready", "markers": markers}
	match event_type:
		&"z1_event_e06":
			markers["cabinet_open"] = completed
		&"z1_event_e16":
			var target: Variant = _shortcut_target(public_state)
			if target is Vector2i:
				markers["target_offset"] = target - room_pos
		&"z1_event_e19":
			var detonation: Dictionary = public_state.get("detonation", {})
			var target: Variant = detonation.get("target_pos")
			if target is Vector2i:
				markers["target_offset"] = target - room_pos
				markers["detonated"] = bool(detonation.get("hit", false))
		&"z1_event_e20":
			var work: Dictionary = public_state.get("work_order", {})
			var visited := int(work.get("visited", 0))
			var required := int(work.get("required", 0))
			var claimed := bool(work.get("claimed", false))
			markers["work_visited"] = visited
			markers["work_required"] = required
			markers["work_claimed"] = claimed
			if not completed and bool(work.get("started", false)):
				description["state_id"] = &"ready_to_claim" if required > 0 and visited >= required else &"active"
		&"z1_event_e21":
			if public_state.has("recon_size"):
				markers["recon_size"] = int(public_state["recon_size"])
		&"z1_event_e22":
			var rounds: Array = public_state.get("rounds", [])
			markers["wins"] = int(public_state.get("wins", 0))
			markers["losses"] = int(public_state.get("losses", 0))
			markers["round_count"] = rounds.size()
			if not rounds.is_empty():
				var latest: Dictionary = rounds.back()
				markers["player_hand"] = StringName(latest.get("player", &""))
				markers["opponent_hand"] = StringName(latest.get("opponent", &""))
				markers["round_result"] = StringName(latest.get("result", &""))
				if not completed:
					description["state_id"] = &"active"
		&"z1_event_e23":
			var relief: Dictionary = public_state.get("pressure_relief", {})
			if not relief.is_empty():
				markers["service"] = StringName(relief.get("service", &""))
				markers["pressure_delta"] = int(relief.get("pressure_delta", 0))
		&"z1_event_e24":
			var locked := bool(public_state.get("cage", {}).get("active", false))
			markers["cage_locked"] = locked
			if locked:
				description["state_id"] = &"active"
		&"z1_event_e25":
			markers["refresh_count"] = int(public_state.get("refresh_count", 0))
			description["stock"] = _visible_stock(public_state.get("stock", []))
		&"altar":
			var stage := int(public_state.get("altar_stage", 0))
			var total := int(public_state.get("altar_stage_total", 0))
			markers["altar_stage"] = stage
			markers["altar_stage_total"] = total
			markers["altar_stages_completed"] = total if completed else maxi(0, stage - 1)
			if not completed and stage > 1:
				description["state_id"] = &"active"
		&"dice":
			if public_state.has("dice_roll"):
				markers["dice_roll"] = int(public_state["dice_roll"])
		&"trap":
			if public_state.has("trap_threshold"):
				markers["trap_threshold"] = int(public_state["trap_threshold"])
			if public_state.has("trap_triggered"):
				markers["trap_triggered"] = bool(public_state["trap_triggered"])
	return description


static func _shortcut_target(public_state: Dictionary) -> Variant:
	if public_state.has("shortcut_target"):
		return public_state["shortcut_target"]
	for option in public_state.get("options", []):
		if option.get("id") == &"travel":
			return option.get("payload", {}).get("target_pos")
	return null


static func _visible_stock(stock: Array) -> Array[Dictionary]:
	var visible: Array[Dictionary] = []
	for slot in stock:
		visible.append({
			"item_id": String(slot.get("item_id", "")),
			"display_name": String(slot.get("display_name", "")),
			"price": int(slot.get("price", 0)),
			"sold": bool(slot.get("sold", false)),
		})
	return visible
