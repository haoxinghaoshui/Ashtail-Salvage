extends RefCounted
class_name Z1EventRuntime

const Catalog := preload("res://scripts/core/content/z1_event_catalog.gd")
const ItemModel := preload("res://scripts/core/content/m3r_item_usability_model.gd")
const MetaCatalog := preload("res://scripts/core/content/m7_content_catalog.gd")
const RunContent := preload("res://scripts/core/run/run_content_catalog.gd")
const SupplyRules := preload("res://scripts/core/run/z1_supply_rule_service.gd")
const Z2Events := preload("res://scripts/core/run/z2_event_runtime.gd")
const SEAL_ID := "con_salvage_seal"
const SAMPLE_ID := "sp_inspection_calibration_plate"
const TRANSIT_SEAL_ID := "sp_transit_lead_seal"
const WORK_ORDER_ROOMS := 3
const CARDINALS := [Vector2i.UP, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT]
const DIAGONALS := [Vector2i(-1, -1), Vector2i(1, -1), Vector2i(1, 1), Vector2i(-1, 1)]
const HANDS := [&"rock", &"paper", &"scissors"]
const HAND_NAMES := {&"rock": "石头", &"paper": "布", &"scissors": "剪刀"}


static func room_state(context: RunContext, pos: Vector2i, event_id: StringName, persist: bool = false) -> Dictionary:
	if Z2Events.applies_to(context):
		return Z2Events.public_state(context, pos, str(event_id))
	var key := context.cell_key(pos)
	var state: Dictionary = context.z1_event_rooms.get(key, {"event_type": event_id})
	state["event_type"] = event_id
	if not state.has("completed"):
		state["completed"] = context.interacted_cells.has(key)
	if Catalog.number(event_id) == 25 and not state.has("stock"):
		state["refresh_count"] = 0
		state["stock"] = _shop_stock(context, pos, 0)
	if persist:
		context.z1_event_rooms[key] = state
	return state


static func public_state(context: RunContext, pos: Vector2i, event_id: StringName) -> Dictionary:
	if Z2Events.applies_to(context):
		return Z2Events.public_state(context, pos, str(event_id))
	var state := room_state(context, pos, event_id)
	var result := Catalog.definition(event_id)
	result["completed"] = bool(state.get("completed", false)) and Catalog.number(event_id) != 25
	result["progress_completed"] = bool(state.get("completed", false))
	result["allow_after_completion"] = Catalog.number(event_id) == 25
	result["options"] = options(context, pos, event_id)
	for field in [
		"stock", "refresh_count", "wins", "losses", "rounds", "cage", "last_result",
		"shortcut_target", "detonation", "recon_size", "pressure_relief",
	]:
		if state.has(field):
			result[field] = state[field].duplicate(true) if state[field] is Array or state[field] is Dictionary else state[field]
	match Catalog.number(event_id):
		13:
			result["item_choices"] = context.asset_ledger.get_items_by_location(&"inventory")
		20:
			var work: Dictionary = context.z1_event_flags.get("work_order", {})
			var started := String(work.get("room_key", "")) == context.cell_key(pos)
			result["work_order"] = {
				"started": started,
				"visited": mini(work.get("new_rooms", {}).size(), WORK_ORDER_ROOMS) if started else 0,
				"required": WORK_ORDER_ROOMS,
				"claimed": started and bool(work.get("claimed", false)),
			}
	return result


static func options(context: RunContext, pos: Vector2i, event_id: StringName) -> Array[Dictionary]:
	if Z2Events.applies_to(context):
		return Z2Events.public_state(context, pos, str(event_id)).get("options", [])
	var state := room_state(context, pos, event_id)
	var choices: Array[Dictionary] = []
	var number := Catalog.number(event_id)
	if bool(state.get("completed", false)) and number != 25:
		return [_option(context, &"leave", "返回探索")]
	match number:
		1, 4:
			var price := 0 if number == 1 else (2 if bool(context.z1_event_flags.get("note_read", false)) else 5)
			for target in _neighbors(context, pos, CARDINALS):
				if not context.intel_map.is_revealed(target):
					choices.append(_option(context, &"read" if number == 1 else &"inspect", "核对%s邻房" % _direction(pos, target), price, {"target_pos": target}))
		2:
			choices.append(_option(context, &"take_tape", "领取胶带卷", 12))
			choices.append(_option(context, &"take_scan", "领取扫描针", 8))
		3:
			choices.append(_option(context, &"convert", "锁定6点安全收益", 10))
		5:
			choices.append(_option(context, &"take_seal", "领取抢救封条", 6 if bool(context.z1_event_flags.get("cashout", false)) else 8))
		6:
			choices.append(_option(context, &"force_open", "徒手开柜"))
			_append_item_options(context, choices, &"safe_open", "交回胶带安全开柜", ["con_tape_roll"])
		7:
			choices.append(_option(context, &"take_sample", "领取巡检校验片", 6))
		8:
			_append_item_options(context, choices, &"hand_in", "交付并锁定5点安全收益", [SAMPLE_ID, "mon_old_gear_set"])
			_append_item_options(context, choices, &"hand_in", "交付并锁定10点安全收益", [TRANSIT_SEAL_ID])
		9:
			choices.append(_option(context, &"quiet", "减少5点压力", 6))
		10:
			choices.append(_option(context, &"buy_patch", "领取急救贴", 4 if context.pressure >= 40 else 9))
		11, 15:
			for item in context.asset_ledger.get_items_by_location(&"inventory"):
				if _ordinary_collectible(item) and ((number == 11 and int(item.get("weight", 0)) <= 20) or (number == 15 and int(item.get("base_value", 0)) >= 21)):
					choices.append(_option(context, &"consign" if number == 11 else &"pawn", ("托运 " if number == 11 else "抵押 ") + String(item.get("display_name", "藏品")), 8 if number == 11 else 0, {"instance_id": item.get("instance_id", "")}))
		12:
			choices.append(_option(context, &"expand", "背包容量增加20", 8, {}, not bool(context.z1_event_flags.get("expanded", false)), "本局已经扩容。"))
		13:
			var ids: Array[String] = []
			for item in context.asset_ledger.get_items_by_location(&"inventory"):
				if _ordinary_collectible(item) and StringName(item.get("rarity", &"")) == &"tier_1":
					ids.append(String(item.get("instance_id", "")))
			var selected_id := String(state.get("selected_first", ""))
			if ids.has(selected_id):
				for candidate_id in ids:
					if candidate_id != selected_id:
						choices.append(_compression_option(context, [selected_id, candidate_id]))
				choices.append(_option(context, &"change_first", "重新选择第一件藏品"))
			else:
				choices.append(_compression_option(context, ids.slice(0, 2)))
				for candidate_id in ids:
					var item := _inventory_item(context, candidate_id)
					choices.append(_option(context, &"select_first", "先选 %s" % item.get("display_name", "藏品"), 0, {"instance_id": candidate_id}))
		14:
			_append_item_options(context, choices, &"return_item", "退回物资", ["con_ration", "con_med_patch"])
		16:
			var targets := _neighbors(context, pos, DIAGONALS)
			if not targets.is_empty():
				var target: Vector2i = targets[_roll(context, pos, 16) % targets.size()]
				choices.append(_option(context, &"travel", "抄近路前往%s" % _direction(pos, target), 6, {"target_pos": target}))
		17:
			choices.append(_option(context, &"locate", "询问撤离方向", 0 if _hidden_exits(context).is_empty() else 6))
		18:
			choices.append(_option(context, &"calibrate", "校准拾料线圈", 5, {}, not bool(context.z1_event_flags.get("coil_pending", false)), "已有一次待用校准。"))
		19:
			for target in _neighbors(context, pos, CARDINALS):
				if context.intel_map.is_flagged(target):
					choices.append(_option(context, &"detonate", "远程起爆%s邻房" % _direction(pos, target), 7, {"target_pos": target}))
		20:
			var work: Dictionary = context.z1_event_flags.get("work_order", {})
			if work.is_empty():
				choices.append(_option(context, &"start_work", "盖开工章", 4))
			elif String(work.get("room_key", "")) == context.cell_key(pos):
				var count: int = work.get("new_rooms", {}).size()
				choices.append(_option(context, &"claim_work", "签退领12黑币（%d/%d）" % [mini(count, WORK_ORDER_ROOMS), WORK_ORDER_ROOMS], 0, {}, count >= WORK_ORDER_ROOMS and not bool(work.get("claimed", false)), "实际进入三个新房后回来签退。"))
		21:
			for pair in [[3, 10], [5, 30], [7, 70]]:
				choices.append(_option(context, StringName("recon_%d" % pair[0]), "侦察%d×%d" % [pair[0], pair[0]], pair[1]))
		22:
			for hand in HANDS:
				choices.append(_option(context, hand, HAND_NAMES[hand]))
		23:
			choices.append(_option(context, &"footbath", "泡脚，减压10%", 10, {}, int(floor(context.pressure * 0.1)) >= 1, "当前压力不足以减压。"))
			choices.append(_option(context, &"massage", "按摩，减压30%", 30, {}, int(floor(context.pressure * 0.3)) >= 1, "当前压力不足以减压。"))
		24:
			choices.append(_option(context, &"enter_cage", "进入围笼", 0, {}, not bool(state.get("cage", {}).get("active", false)), "围笼战斗进行中。"))
		25:
			var stock: Array = state.get("stock", [])
			for index in range(stock.size()):
				var slot: Dictionary = stock[index]
				choices.append(_option(context, StringName("buy_%d" % index), String(slot.get("display_name", "空货槽")), int(slot.get("price", 0)), {}, not bool(slot.get("sold", false)), "该货槽已售空。"))
			choices.append(_option(context, &"refresh", "刷新三格货槽", 5, {}, not _shop_stock(context, pos, int(state.get("refresh_count", 0)) + 1).is_empty(), "当前没有可售商品。"))
	choices.append(_option(context, &"leave", "离开事件"))
	return choices


static func execute(context: RunContext, pos: Vector2i, event_id: StringName, option_id: StringName, payload: Dictionary = {}, fail_authority = null) -> Dictionary:
	if Z2Events.applies_to(context):
		return Z2Events.choose(context, pos, str(event_id), str(option_id), payload, Z2Events.hooks_for(fail_authority, context, pos, str(event_id)))
	var state := room_state(context, pos, event_id, true)
	var number := Catalog.number(event_id)
	if option_id == &"leave":
		return _finish(context, pos, event_id, {"ok": true, "completed": false, "message": "已返回探索。"})
	if bool(state.get("completed", false)) and number != 25:
		return _finish(context, pos, event_id, {"ok": true, "completed": true, "message": "这里已经处理完毕。"})
	var selected: Dictionary = {}
	var instance_id := str(payload.get("instance_id", ""))
	for option in options(context, pos, event_id):
		if option.get("id") == option_id:
			var option_payload: Dictionary = option.get("payload", {})
			if option_payload.has("instance_id") and (instance_id.is_empty() or instance_id != str(option_payload["instance_id"])):
				continue
			selected = option
			break
	if selected.is_empty() or not bool(selected.get("enabled", false)):
		return _finish(context, pos, event_id, _blocked("event_option_unavailable", "当前无法执行这个选项。"))
	var effective_payload: Dictionary = selected.get("payload", {}).duplicate(true)
	effective_payload.merge(payload, true)
	var result := _execute_choice(context, pos, event_id, number, option_id, effective_payload, selected, fail_authority)
	result["option_id"] = option_id
	return _finish(context, pos, event_id, result, true)


static func _execute_choice(context: RunContext, pos: Vector2i, event_id: StringName, number: int, option_id: StringName, payload: Dictionary, selected: Dictionary, fail_authority) -> Dictionary:
	var cost := int(selected.get("player_cost", {}).get("amount", 0))
	var state := room_state(context, pos, event_id)
	match number:
		1, 4:
			var target: Vector2i = payload.get("target_pos", Vector2i(-1, -1))
			if not _neighbors(context, pos, CARDINALS).has(target) or context.intel_map.is_revealed(target):
				return _blocked("invalid_target", "目标必须是未知的相邻房间。")
			var result := _apply(context, event_id, cost, {}, fail_authority)
			if result.get("ok", false):
				var count := context.truth_map.get_adjacent_mine_count(target)
				context.z1_event_intel[context.cell_key(target)] = {"position": target, "adjacent_mines": count}
				context.intel_map.learn_event_intel(target, context.z1_event_intel[context.cell_key(target)])
				context.z1_event_flags["note_read"] = bool(context.z1_event_flags.get("note_read", false)) or number == 1
				result["message"] = "%s邻房周围有%d处雷。" % [_direction(pos, target), count]
				result["intel"] = context.z1_event_intel[context.cell_key(target)].duplicate(true)
			return result
		2, 5, 7, 10:
			var item_id := "con_tape_roll" if option_id == &"take_tape" else "con_scan_pin"
			if number == 5:
				item_id = SEAL_ID
			elif number == 7:
				item_id = SAMPLE_ID
			elif number == 10:
				item_id = "con_med_patch"
			var item := ItemModel.item_definition(item_id)
			if item.is_empty():
				return _blocked("missing_item_definition", "这件物资尚未配置。")
			var rule := {"item_defs": [item], "drop_on_floor": true}
			if number == 10 and context.pressure >= 40:
				rule["pressure_delta"] = 5
			return _apply(context, event_id, cost, rule, fail_authority)
		3:
			var result := _apply(context, event_id, cost, {"gold_coin_delta": 6}, fail_authority)
			if result.get("ok", false):
				context.z1_event_flags["cashout"] = true
			return result
		6:
			var rule := {"black_coin_delta": 6, "item_defs": RunContent.search_items(pos, context.current_adjacent_mines, true, 6, context).slice(0, 1)}
			if option_id == &"safe_open":
				var item := _selected_item(context, payload)
				if String(item.get("item_id", "")) != "con_tape_roll":
					return _blocked("invalid_item", "需要背包中的胶带卷。")
				var moved := context.asset_ledger.transfer_event_items([item.get("instance_id", "")], &"consumed")
				if not moved.get("ok", false):
					return moved
			else:
				rule["hp_delta"] = -mini(10, maxi(0, context.hp - 1))
			return _apply(context, event_id, 0, rule, fail_authority)
		8:
			var item := _selected_item(context, payload)
			var purpose := &"transit" if String(item.get("item_id", "")) == TRANSIT_SEAL_ID else &"inspection"
			var result := SupplyRules.exchange_material(context, String(item.get("instance_id", "")), purpose)
			if not bool(result.get("ok", false)):
				return _blocked(String(result.get("reason", "invalid_item")), "需要背包中的巡检校验片、旧齿轮组或转运铅封。")
			var amount := int(result.get("safe_yield_delta", 0))
			result["completed"] = true
			result["gold_coin_delta"] = amount
			result["message"] = "签收完成，已锁定 %d 点安全收益。" % amount
			return result
		11, 14, 15:
			return _execute_transfer(context, event_id, number, payload, cost, fail_authority)
		13:
			if option_id == &"select_first":
				var item := _selected_item(context, payload)
				if not _ordinary_collectible(item) or StringName(item.get("rarity", &"")) != &"tier_1":
					return _blocked("invalid_item", "需要一件背包中的一级普通藏品。")
				state["selected_first"] = String(item.get("instance_id", ""))
				return {"ok": true, "completed": false, "reopen_event": true, "message": "已选择%s，请选择第二件藏品。" % item.get("display_name", "藏品")}
			if option_id == &"change_first":
				state.erase("selected_first")
				return {"ok": true, "completed": false, "reopen_event": true, "message": "请重新选择第一件藏品。"}
			return _execute_transfer(context, event_id, number, payload, cost, fail_authority)
		9, 23:
			var amount := 5
			if number == 23:
				amount = int(floor(context.pressure * (0.1 if option_id == &"footbath" else 0.3)))
			if amount < 1:
				return _blocked("no_pressure_reduction", "当前压力不足以减压，不收取费用。")
			var before_pressure := context.pressure
			var result := _apply(context, event_id, cost, {"pressure_delta": -amount}, fail_authority)
			if number == 23 and bool(result.get("ok", false)):
				state["pressure_relief"] = {"service": option_id, "pressure_delta": context.pressure - before_pressure}
			return result
		12:
			if context.z1_event_flags.get("expanded", false):
				return _blocked("already_expanded", "本局已经扩容。")
			var result := _apply(context, event_id, cost, {}, fail_authority)
			if result.get("ok", false):
				context.asset_ledger.backpack_capacity += 20
				context.z1_event_flags["expanded"] = true
				context.asset_ledger.sync_compat_fields(context)
			return result
		16:
			var target: Vector2i = selected.get("payload", {}).get("target_pos", Vector2i(-1, -1))
			if payload.get("target_pos", target) != target or not context.is_inside(target):
				return _blocked("invalid_target", "检修口只能通往亮灯指向的房间。")
			var result := _apply(context, event_id, cost, {"shortcut_target": target}, fail_authority)
			if bool(result.get("ok", false)):
				state["shortcut_target"] = target
			return result
		17:
			var exits := _hidden_exits(context)
			if exits.is_empty():
				return {"ok": true, "completed": false, "message": "撤离点已经全部公开，无需支付费用。"}
			var target: Vector2i = exits[0]
			for candidate in exits:
				if _distance(pos, candidate) < _distance(pos, target):
					target = candidate
			var distance := _distance(pos, target)
			var lower := maxi(1, distance - 1)
			return _apply(context, event_id, cost, {"message": "最近隐藏撤离点在%s，约%d至%d格。" % [_direction(pos, target), lower, distance + 1]}, fail_authority)
		18:
			if context.z1_event_flags.get("coil_pending", false):
				return _blocked("coil_already_pending", "已有一次待用校准。")
			var result := _apply(context, event_id, cost, {}, fail_authority)
			if result.get("ok", false):
				context.z1_event_flags["coil_pending"] = true
			return result
		19:
			var target: Vector2i = payload.get("target_pos", Vector2i(-1, -1))
			if not _neighbors(context, pos, CARDINALS).has(target) or not context.intel_map.is_flagged(target):
				return _blocked("invalid_target", "只能起爆插旗的相邻房间。")
			var hit := context.truth_map.is_mine(target)
			var result := _apply(context, event_id, cost, {"pressure_delta": 10 if hit else 0, "message": "地雷已经远程引爆。" if hit else "目标没有地雷，本次费用已经支付。"}, fail_authority)
			if bool(result.get("ok", false)):
				state["detonation"] = {"target_pos": target, "hit": hit}
			if hit and result.get("ok", false):
				context.z1_event_flags.get_or_add("remote_mines", {})[context.cell_key(target)] = true
				context.truth_map.mark_triggered(target)
				context.z1_event_intel[context.cell_key(target)] = {"position": target, "known_mine": true, "mine_triggered": true}
				context.intel_map.learn_event_intel(target, context.z1_event_intel[context.cell_key(target)])
			return result
		20:
			return _execute_work(context, pos, event_id, option_id, fail_authority)
		21:
			var size := int(String(option_id).trim_prefix("recon_"))
			var result := _apply(context, event_id, cost, {}, fail_authority)
			if result.get("ok", false):
				state["recon_size"] = size
				var radius := size / 2
				for y in range(maxi(0, pos.y - radius), mini(context.height, pos.y + radius + 1)):
					for x in range(maxi(0, pos.x - radius), mini(context.width, pos.x + radius + 1)):
						var target := Vector2i(x, y)
						if context.truth_map.is_mine(target):
							context.z1_event_intel[context.cell_key(target)] = {"position": target, "known_mine": true}
							context.intel_map.learn_event_intel(target, context.z1_event_intel[context.cell_key(target)])
				result["message"] = "%d×%d范围的雷位已标记。" % [size, size]
			return result
		22:
			return _execute_rps(context, pos, event_id, option_id, state, fail_authority)
		24:
			var types := [&"slime", &"bat", &"drone"]
			state["cage"] = {"active": true, "monster_type": types[_roll(context, pos, 24) % 3], "base_power": 5 + _roll(context, pos, 240) % 16}
			return {"ok": true, "completed": false, "start_cage_combat": true, "cage": state["cage"].duplicate(true), "message": "围笼已锁定，击败怪物后开门。"}
		25:
			return _execute_shop(context, pos, event_id, option_id, state, cost, fail_authority)
	return _blocked("event_option_unavailable", "没有可执行的选项。")


static func _execute_transfer(context: RunContext, event_id: StringName, number: int, payload: Dictionary, cost: int, fail_authority) -> Dictionary:
	var item := _selected_item(context, payload)
	var ids: Array = payload.get("instance_ids", []) if number == 13 else [String(item.get("instance_id", ""))]
	var destination := &"consumed"
	var rule := {}
	match number:
		11:
			if not _ordinary_collectible(item) or int(item.get("weight", 0)) > 20:
				return _blocked("invalid_item", "托运只收重量不超过20的普通藏品。")
			destination = &"consigned"
		13:
			if ids.size() != 2 or ids[0] == ids[1]:
				return _blocked("invalid_items", "必须选择两件不同的一级藏品。")
			for instance_id in ids:
				var source := _inventory_item(context, String(instance_id))
				if not _ordinary_collectible(source) or StringName(source.get("rarity", &"")) != &"tier_1":
					return _blocked("invalid_items", "需要两件背包中的一级普通藏品。")
			var gear := ItemModel.item_definition("col_08")
			if gear.is_empty():
				return _blocked("missing_item_definition", "完整齿轮尚未配置。")
			rule["item_defs"] = [gear]
		14:
			var item_id := String(item.get("item_id", ""))
			if not ["con_ration", "con_med_patch"].has(item_id):
				return _blocked("invalid_item", "只接受压缩饼或急救贴。")
			rule["black_coin_delta"] = 3 if item_id == "con_ration" else 6
		15:
			if not _ordinary_collectible(item) or int(item.get("base_value", 0)) < 21:
				return _blocked("invalid_item", "需要基础价至少21的普通藏品。")
			destination = &"pledged"
			rule["black_coin_delta"] = 12
	if context.asset_ledger.get_currency(&"black_coin") < cost:
		return _blocked("need_black_coin", "本局黑币不足。")
	var transfer := context.asset_ledger.transfer_event_items(ids, destination)
	if not transfer.get("ok", false):
		return transfer
	rule["transferred_items"] = transfer.get("items", [])
	return _apply(context, event_id, cost, rule, fail_authority)


static func _execute_work(context: RunContext, pos: Vector2i, event_id: StringName, option_id: StringName, fail_authority) -> Dictionary:
	var work: Dictionary = context.z1_event_flags.get("work_order", {})
	if option_id == &"start_work":
		if not work.is_empty():
			return _blocked("work_already_started", "本局已经开过验工单。")
		var result := _apply(context, event_id, 4, {"completed": false, "message": "开工章已盖，实际进入三个新房后回此处签退。"}, fail_authority)
		if result.get("ok", false):
			context.z1_event_flags["work_order"] = {"room_key": context.cell_key(pos), "known_rooms": context.visited_cells.duplicate(), "new_rooms": {}, "claimed": false}
		return result
	if work.is_empty() or String(work.get("room_key", "")) != context.cell_key(pos) or work.get("new_rooms", {}).size() < WORK_ORDER_ROOMS or bool(work.get("claimed", false)):
		return _blocked("work_not_ready", "实际进入三个新房后回开工处签退。")
	var result := _apply(context, event_id, 0, {"black_coin_delta": 12}, fail_authority)
	if result.get("ok", false):
		work["claimed"] = true
	return result


static func record_entry(context: RunContext, pos: Vector2i) -> void:
	if Z2Events.applies_to(context):
		# Z2 records real visited rooms through the parent's post-entry hook.
		return
	var work: Dictionary = context.z1_event_flags.get("work_order", {})
	if work.is_empty() or bool(work.get("claimed", false)):
		return
	var key := context.cell_key(pos)
	if key != String(work.get("room_key", "")) and not work.get("known_rooms", {}).has(key):
		work.get_or_add("new_rooms", {})[key] = true


static func _execute_rps(context: RunContext, pos: Vector2i, event_id: StringName, hand: StringName, state: Dictionary, fail_authority) -> Dictionary:
	var rounds: Array = state.get_or_add("rounds", [])
	var opponent: StringName = HANDS[_roll(context, pos, 220 + rounds.size()) % 3]
	var difference := posmod(HANDS.find(hand) - HANDS.find(opponent), 3)
	var wins := int(state.get("wins", 0)) + int(difference == 1)
	var losses := int(state.get("losses", 0)) + int(difference == 2)
	state["wins"] = wins
	state["losses"] = losses
	rounds.append({"player": hand, "opponent": opponent, "result": "draw" if difference == 0 else ("win" if difference == 1 else "loss")})
	var reward := 10 + _roll(context, pos, 2299) % 31 if wins >= 2 else 0
	return _apply(context, event_id, 0, {"completed": wins >= 2 or losses >= 2, "black_coin_delta": reward, "wins": wins, "losses": losses, "message": "对方出%s，比分%d比%d。%s" % [HAND_NAMES[opponent], wins, losses, "本场结束。" if wins >= 2 or losses >= 2 else "继续出拳。"]}, fail_authority)


static func _execute_shop(context: RunContext, pos: Vector2i, event_id: StringName, option_id: StringName, state: Dictionary, cost: int, fail_authority) -> Dictionary:
	if option_id == &"refresh":
		var result := _apply(context, event_id, 5, {"completed": false, "message": "三格货槽已刷新。"}, fail_authority)
		if result.get("ok", false):
			state["refresh_count"] = int(state.get("refresh_count", 0)) + 1
			state["stock"] = _shop_stock(context, pos, int(state["refresh_count"]))
		return result
	var index := int(String(option_id).trim_prefix("buy_"))
	var stock: Array = state.get("stock", [])
	if index < 0 or index >= stock.size() or bool(stock[index].get("sold", false)):
		return _blocked("shop_slot_empty", "该货槽已售空。")
	var purchased_item: Dictionary = stock[index].get("item", {}).duplicate(true)
	purchased_item["reward_location"] = &"inventory"
	var result := _apply(context, event_id, cost, {"completed": false, "item_defs": [purchased_item], "reward_location": &"inventory", "message": "购买完成，背包放不下的物资留在地面。"}, fail_authority)
	if result.get("ok", false):
		stock[index]["sold"] = true
		_mark_completed(context, pos, event_id)
		result["progress_completed"] = true
	return result


static func cage_state(context: RunContext, pos: Vector2i) -> Dictionary:
	if Z2Events.applies_to(context):
		return Z2Events.cage_state(context, pos)
	if context == null:
		return {}
	return context.z1_event_rooms.get(context.cell_key(pos), {}).get("cage", {}).duplicate(true)


static func resolve_cage(context: RunContext, pos: Vector2i, won: bool) -> Dictionary:
	if Z2Events.applies_to(context):
		return {"ok": false, "reason": "actual_combat_receipt_required"}
	if context == null or not context.run_active:
		return _blocked("run_not_active", "当前没有进行中的回收。")
	var event_id := &"z1_event_e24"
	var state := room_state(context, pos, event_id, true)
	var cage: Dictionary = state.get("cage", {})
	if not bool(cage.get("active", false)) or bool(state.get("completed", false)):
		return {"ok": true, "completed": bool(state.get("completed", false)), "reward_repeated": false}
	cage["active"] = false
	if not won:
		return _finish(context, pos, event_id, {"ok": true, "completed": false, "cage_defeated": true, "message": "围笼战斗失败。"}, true)
	var gain := int(cage.get("base_power", 5)) * 2
	context.power += gain
	return _finish(context, pos, event_id, {"ok": true, "completed": true, "power_delta": gain, "message": "围笼胜利，本局战力增加%d。" % gain}, true)


static func _apply(context: RunContext, event_id: StringName, cost: int, fields: Dictionary, fail_authority) -> Dictionary:
	if context.asset_ledger.get_currency(&"black_coin") < cost:
		return _blocked("need_black_coin", "本局黑币不足。")
	var rule := {"ok": true, "completed": true, "spend_black_coin": cost, "message": "处理完成。"}
	rule.merge(fields, true)
	return RunRuleService.apply_event_rule_result(context, event_id, rule, fail_authority)


static func _finish(context: RunContext, pos: Vector2i, event_id: StringName, result: Dictionary, record_receipt: bool = false) -> Dictionary:
	result["event_type"] = event_id
	if result.get("ok", false):
		if result.get("completed", false):
			_mark_completed(context, pos, event_id)
		if record_receipt:
			room_state(context, pos, event_id, true)["last_result"] = result.duplicate(true)
	context.event_state = public_state(context, pos, event_id)
	context.last_reward = result.duplicate(true)
	context.last_message = String(result.get("message", ""))
	context.blocked_reason = String(result.get("reason", ""))
	return result


static func _mark_completed(context: RunContext, pos: Vector2i, event_id: StringName) -> void:
	var state := room_state(context, pos, event_id, true)
	if bool(state.get("completed", false)):
		return
	state["completed"] = true
	context.interacted_cells[context.cell_key(pos)] = true
	context.truth_map.mark_cleared(pos)
	context.intel_map.refresh_revealed_cell(pos, context.truth_map)
	context.run_stats["events_completed"] = int(context.run_stats.get("events_completed", 0)) + 1
	context.run_stats["events_%s" % event_id] = int(context.run_stats.get("events_%s" % event_id, 0)) + 1


static func _option(context: RunContext, option_id: StringName, title: String, price: int = 0, payload: Dictionary = {}, available: bool = true, reason: String = "") -> Dictionary:
	var affordable := context.asset_ledger.get_currency(&"black_coin") >= price
	return {"id": option_id, "player_title": title, "label": title, "enabled": available and affordable,
		"player_cost": {"kind": &"black_coin" if price > 0 else &"none", "amount": price, "display_text": "%d黑币" % price if price > 0 else "无需花费"},
		"player_effect": title, "player_disabled_reason": reason if not available else ("本局黑币不足。" if not affordable else ""), "payload": payload.duplicate(true)}


static func _append_item_options(context: RunContext, choices: Array[Dictionary], option_id: StringName, title: String, item_ids: Array) -> void:
	for item in context.asset_ledger.get_items_by_location(&"inventory"):
		if item_ids.has(String(item.get("item_id", ""))):
			choices.append(_option(context, option_id, "%s · %s" % [title, item.get("display_name", "物品")], 0, {"instance_id": item.get("instance_id", "")}))


static func _compression_option(context: RunContext, ids: Array) -> Dictionary:
	var choice := _option(context, &"compress", "压缩两件一级藏品", 0, {"instance_ids": ids}, ids.size() == 2, "需要两件一级普通藏品。")
	choice["requires_confirmation"] = true
	if ids.size() != 2:
		return choice
	var first := _inventory_item(context, String(ids[0]))
	var second := _inventory_item(context, String(ids[1]))
	var gear := ItemModel.item_definition("col_08")
	var value_delta := int(gear.get("base_value", 0)) - int(first.get("base_value", 0)) - int(second.get("base_value", 0))
	var weight_delta := int(first.get("weight", 0)) + int(second.get("weight", 0)) - int(gear.get("weight", 0))
	choice["player_title"] = "压缩%s和%s" % [first.get("display_name", "藏品"), second.get("display_name", "藏品")]
	choice["player_effect"] = "得到完整齿轮，基础价差%+d，重量减少%d。" % [value_delta, weight_delta]
	return choice


static func _inventory_item(context: RunContext, instance_id: String) -> Dictionary:
	var item: Dictionary = context.asset_ledger.item_instances.get(instance_id, {})
	return item if StringName(item.get("location_state", &"")) == &"inventory" else {}


static func _selected_item(context: RunContext, payload: Dictionary) -> Dictionary:
	return _inventory_item(context, String(payload.get("instance_id", "")))


static func _ordinary_collectible(item: Dictionary) -> bool:
	return StringName(item.get("item_type", item.get("main_type", &""))) == &"collectible" and StringName(item.get("rarity", &"")) != &"unique"


static func _neighbors(context: RunContext, pos: Vector2i, offsets: Array) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	for offset in offsets:
		var target: Vector2i = pos + offset
		if context.is_inside(target):
			result.append(target)
	return result


static func _hidden_exits(context: RunContext) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	for pos in context.truth_map.get_exits():
		if context.truth_map.is_random_exit(pos) and not context.intel_map.is_revealed(pos):
			result.append(pos)
	return result


static func _direction(origin: Vector2i, target: Vector2i) -> String:
	var horizontal := "东" if target.x > origin.x else ("西" if target.x < origin.x else "")
	var vertical := "南" if target.y > origin.y else ("北" if target.y < origin.y else "")
	return vertical + horizontal if vertical != "" or horizontal != "" else "本房"


static func _distance(origin: Vector2i, target: Vector2i) -> int:
	return absi(target.x - origin.x) + absi(target.y - origin.y)


static func _roll(context: RunContext, pos: Vector2i, salt: int) -> int:
	return posmod(context.seed_value * 73856093 + pos.x * 19349663 + pos.y * 83492791 + salt * 2654435761, 2147483647)


static func _shop_stock(context: RunContext, pos: Vector2i, refresh_count: int) -> Array[Dictionary]:
	return _stock_from_offers(context, pos, refresh_count, MetaCatalog.shop_definitions())


static func _stock_from_offers(context: RunContext, pos: Vector2i, refresh_count: int, offers: Array) -> Array[Dictionary]:
	var pool: Array[Dictionary] = []
	var seen: Dictionary = {}
	for offer in offers:
		var item_id := String(offer.get("item_id", ""))
		var listed_price := int(offer.get("price", 0))
		if listed_price <= 0 or seen.has(item_id):
			continue
		var item := ItemModel.item_definition(item_id)
		if item.is_empty():
			continue
		seen[item_id] = true
		pool.append({"item_id": item_id, "display_name": item.get("display_name", "物资"), "item": item, "price": int(ceil(listed_price * 1.3)), "sold": false})
	var stock: Array[Dictionary] = []
	for index in range(mini(3, pool.size())):
		var selected := _roll(context, pos, 2500 + refresh_count * 3 + index) % pool.size()
		stock.append(pool[selected])
		pool.remove_at(selected)
	return stock


static func _blocked(reason: String, message: String) -> Dictionary:
	return {"ok": false, "completed": false, "reason": reason, "blocked_reason": reason, "message": message}
