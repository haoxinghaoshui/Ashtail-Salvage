extends SceneTree

const Runtime = preload("res://scripts/core/run/run_runtime_controller.gd")
var opening
var failures: Array[String] = []
var checks := 0
var serial := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var path := "res://scripts/core/run/z2_opening_runtime.gd"
	if not ResourceLoader.exists(path):
		_check(false, "T09 implementation missing: nine effects cannot execute")
	else:
		opening = load(path)
		_test_choice()
		_test_rebate()
		_test_pressure()
		_test_power()
		_test_status_and_sacrifice()
		_test_cash_and_tools()
		_test_auto_clear()
		_test_atomic_replay()
		_test_review_boundaries()
		_test_positive_currency_loop()
	for failure in failures:
		print("Z2_OPENING_CASE_FAIL " + failure)
	print("Z2_OPENING_RUNTIME=%s checks=%d" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)


func _runtime(effect: String = "", power: int = 40):
	var r = Runtime.new()
	r.checkpoint_writer = func(_candidate: Dictionary) -> Dictionary: return {"ok": true}
	r.command_bus.dispatch(&"start_demo_run", {})
	var c: RunContext = r.context
	c.mode = &"standard"
	c.run_start_config["tutorial_map"] = false
	c.profile_fields = {"ruleset_id": "z2", "z2_progression_version": 1}
	c.run_start_config["profile_fields"] = c.profile_fields.duplicate(true)
	c.active_talent_effects.assign([{"talent_id": "z2_talent_15", "effect_kind": "opening_effect_batch_unlock", "effect_amount": 1, "effect_params": {"batch": 1}}])
	c.width = 12
	c.height = 3
	c.truth_map.setup_manual_map({"width": 12, "height": 3, "manual_map": {"spawn": Vector2i.ZERO,
		"monsters": [Vector2i(1, 1), Vector2i(2, 1), Vector2i(3, 1), Vector2i(4, 1), Vector2i(5, 1), Vector2i(6, 1), Vector2i(7, 1)],
		"mines": [Vector2i(1, 2), Vector2i(2, 2), Vector2i(3, 2), Vector2i(4, 2)], "chests": [Vector2i(8, 1), Vector2i(9, 1)]}})
	c.intel_map.setup(12, 3)
	c.visited_cells.clear()
	c.explored_cells.clear()
	c.entered_cells.clear()
	c.searched_cells.clear()
	c.interacted_cells.clear()
	c.z1_event_flags.clear()
	c.z1_event_rooms.clear()
	c.z1_event_intel.clear()
	c.run_stats.clear()
	c.asset_ledger.setup({"run_id": str(c.run_id), "backpack_capacity": 100, "equipment_capacity": 100})
	c.asset_ledger.add_currency(&"long_term_gold", 1000, "candidate_meta_fixture")
	c.power = power
	c.max_hp = 100
	c.hp = 80
	c.pressure = 0
	c.protocol_level = 0
	c.protocol_pressure_reduce = 0
	c.max_hp_equipment_floor_debt = 0
	c.vitals_modifiers.clear()
	c.vitals_counters.clear()
	c.temporary_statuses.clear()
	_room(r, Vector2i.ZERO)
	if effect != "":
		var found := false
		for seed_value in range(100):
			c.seed_value = seed_value
			c.z1_event_flags.clear()
			var prepared := _call(r, "prepare")
			if bool(prepared.get("ok", false)) and _state(r).get("candidates", []).has(effect):
				found = true
				break
		_check(found, "fixture draws " + effect)
		var chosen := _call(r, "choose", {"offer_id": _state(r).get("offer_id", ""), "effect_id": effect}, {"d06_policy": opening.D06_POLICY})
		_check(chosen.get("ok", false), "select " + effect + ": " + str(chosen.get("reason", "")))
	return r


func _dispose(r) -> void:
	r.checkpoint_writer = Callable()
	r.command_bus.runtime_controller = null
	r.command_bus.room_resolver.bind_runtime_controller(null)
	r.in_run_runtime.bind(null)


func _id() -> String:
	serial += 1
	return "opening-test-%d" % serial


func _state(r) -> Dictionary:
	return opening.public_state(r.context)


func _call(r, action: String, payload: Dictionary = {}, services: Dictionary = {}, id: String = "") -> Dictionary:
	var data := payload.duplicate(true)
	data["action_id"] = _id() if id == "" else id
	return r.execute_atomic_operation(&"z2_opening", {"action": action, "payload": data},
		func() -> Dictionary: return opening.execute(r.context, action, data, services), data.action_id)


func _hook(r, kind: String, extra: Dictionary = {}, id: String = "") -> Dictionary:
	var fact := {"kind": kind, "fact_id": _id() if id == "" else id, "actual": true, "pos": r.context.get_current_pos()}
	fact.merge(extra, true)
	return _call(r, "hook", {"fact": fact})


func _room(r, pos: Vector2i) -> void:
	r.context.current_pos = pos
	r.context.player_pos = pos
	r.context.visited_cells[r.context.cell_key(pos)] = true
	r.context.explored_cells[r.context.cell_key(pos)] = true
	r.context.truth_map.mark_explored(pos)
	r.context.intel_map.reveal_cell(pos, r.context.truth_map)


func _income(r, amount: int, id: String = "", source: String = "income") -> Dictionary:
	var action_id := _id() if id == "" else id
	return r.execute_atomic_operation(&"income", {"amount": amount, "source": source}, func() -> Dictionary:
		r.context.asset_ledger.add_currency(&"black_coin", amount, source)
		return opening.execute(r.context, "hook", {"action_id": action_id, "fact": {"kind": "black_income", "actual": true,
			"fact_id": action_id, "gross": amount, "ledger_index": r.context.asset_ledger.settlement_log.size() - 1}}), action_id)


func _black(r) -> int:
	return r.context.asset_ledger.get_currency(&"black_coin")


func _check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append(label)


func _reject(r, action: String, data: Dictionary = {}, services: Dictionary = {}) -> void:
	var before: Dictionary = r.capture_authoritative_state()
	var result := _call(r, action, data, services)
	_check(not result.get("ok", true), "rejected " + action + ": " + str(result.get("reason", "")))
	_check(r.capture_authoritative_state() == before, "failed " + action + " keeps complete state")


func _pay(c: RunContext, amount: int, _action_id: String) -> Dictionary:
	var paid := c.asset_ledger.spend_currency(&"long_term_gold", amount, "candidate_meta_fixture")
	return {"ok": paid.get("ok", false), "spent": paid.get("spent", 0), "currency": "meta_gold"}


func _test_choice() -> void:
	var r = _runtime()
	var before: Dictionary = r.capture_authoritative_state()
	opening.options(r.context)
	opening.plan_trigger(r.context, {"kind": "room_entered"})
	_check(r.capture_authoritative_state() == before, "all preview calls are read-only")
	_check(_call(r, "prepare", {"initial_power": 999}).get("ok", false), "prepare")
	var state := _state(r)
	_check(state.initial_power == 40 and state.candidates.size() == 3 and state.candidates[0] != state.candidates[1] and state.candidates[1] != state.candidates[2] and state.candidates[0] != state.candidates[2], "context power and three distinct choices")
	_call(r, "prepare")
	_check(_state(r).candidates == state.candidates and _state(r).offer_id == state.offer_id, "reopen does not redraw")
	_reject(r, "refresh", {"offer_id": state.offer_id})
	_reject(r, "choose", {"offer_id": "stale", "effect_id": state.candidates[0]})
	for i in range(10):
		state = _state(r)
		_check(state.next_refresh_gold == (i + 1) * 5, "refresh quote " + str(i))
		var result := _call(r, "refresh", {"offer_id": state.offer_id}, {"pay_refresh": _pay})
		_check(result.get("ok", false) and _state(r).refresh_count == i + 1, "refresh actual payment/draw " + str(i))
		_check(_state(r).candidates != state.candidates, "refresh produces a different offer")
	_check(r.context.asset_ledger.get_currency(&"long_term_gold") == 725, "ten refreshes debit275 meta gold")
	_reject(r, "refresh", {"offer_id": _state(r).offer_id}, {"pay_refresh": _pay})
	_check(_call(r, "skip").get("ok", false) and _state(r).status == "skipped", "skip")
	_reject(r, "choose", {"offer_id": _state(r).offer_id, "effect_id": _state(r).candidates[0]})
	_dispose(r)
	r = _runtime()
	_call(r, "prepare")
	r.context.asset_ledger.currency_balances[&"long_term_gold"] = 4
	_reject(r, "refresh", {"offer_id": _state(r).offer_id}, {"pay_refresh": _pay})
	_dispose(r)
	r = _runtime()
	r.context.active_talent_effects.clear()
	_reject(r, "prepare")
	r.context.active_talent_effects.assign([{"talent_id": "z2_talent_29", "effect_kind": "opening_effect_batch_unlock", "effect_amount": 2, "effect_params": {"batch": 2}}])
	_check(_state(r).future_batches == [2] and opening.options(r.context).is_empty(), "future qualification creates no first-batch effects")
	_reject(r, "prepare")
	_dispose(r)


func _test_rebate() -> void:
	for parts in [[80], [100], [5, 70, 5], [1, 3, 75, 1], [20, 60], [5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5]]:
		var r = _runtime("rebate")
		var total := 0
		for amount in parts:
			total += amount
			_check(_income(r, amount).get("ok", false), "D06 actual income " + str(amount))
		_check(_black(r) == total - 30 and r.context.asset_ledger.get_currency(&"gold_coin") == 50, "D06 split/lump fees and safe50 " + str(parts))
		_check(_state(r).effect_state.done and _state(r).effect_state.fees_paid == 30, "D06 stops at80")
		_income(r, 5)
		_check(_black(r) == total - 25 and r.context.asset_ledger.get_currency(&"gold_coin") == 50, "D06 post-target no fee/rebate")
		_dispose(r)
	var r = _runtime("rebate")
	_income(r, 75)
	_check(_black(r) == 45 and r.context.asset_ledger.get_currency(&"gold_coin") == 0, "D06 75 means15fees no early rebate")
	_income(r, 4)
	_check(_black(r) == 49, "D06 79 no new fee")
	_income(r, 1)
	_check(_black(r) == 50 and r.context.asset_ledger.get_currency(&"gold_coin") == 50, "D06 80 stops before terminal fee")
	_dispose(r)
	for available in [0, 1]:
		r = _runtime("rebate")
		r.context.asset_ledger.add_currency(&"black_coin", 5, "migrated_income")
		var index: int = r.context.asset_ledger.settlement_log.size() - 1
		r.context.asset_ledger.spend_currency(&"black_coin", 5 - available, "migrated_spend")
		_check(_hook(r, "black_income", {"gross": 5, "ledger_index": index}).get("ok", false), "D06 insufficient income accepted")
		_check(_black(r) == available and _state(r).effect_state.fees_skipped == 1, "D06 skips whole fee below2")
		_income(r, 5)
		_check(_black(r) == available + 3 and _state(r).effect_state.fees_paid == 2, "D06 no debt/makeup")
		var prior: Dictionary = r.capture_authoritative_state()
		_hook(r, "black_income", {"gross": 5, "ledger_index": index}, "different_fact_id")
		_check(_black(r) == available + 3 and _state(r).effect_state.gross == 10, "same ledger receipt cannot count twice")
		_check(prior.context.data.z1_event_flags.z2_opening.effect_state == _state(r).effect_state, "dedupe preserves rebate state")
		_dispose(r)
	r = _runtime("rebate")
	_reject(r, "hook", {"fact": {"kind": "black_income", "fact_id": "fake", "actual": true, "ledger_index": 0, "gross": 80}})
	_reject(r, "hook", {"fact": {"kind": "black_income", "fact_id": "preview", "actual": false, "gross": 80}})
	_dispose(r)


func _test_pressure() -> void:
	var r = _runtime("mine_pressure")
	r.context.pressure = 25
	for i in range(1, 5):
		var pos := Vector2i(i, 2)
		_room(r, pos)
		r.context.truth_map.mark_triggered(pos)
		var before: Dictionary = r.capture_authoritative_state()
		var plan: Dictionary = opening.plan_trigger(r.context, {"kind": "mine_hit", "actual": true, "fact_id": "preview", "pos": pos})
		_check(plan.get("predicted", {}).get("facts", {}).get("replace_mine_pressure", false) == (i <= 3), "preview predicts real mine replacement without committing")
		_check(r.capture_authoritative_state() == before, "preview cannot consume actual effect counters")
		var result := _hook(r, "mine_hit")
		_check(result.get("facts", {}).get("replace_mine_pressure", false) == (i <= 3), "mine replacement occurrence " + str(i))
		_check(r.context.pressure == maxi(0, 25 - mini(i, 3) * 10), "mine pressure actual clamp")
		var uses: int = _state(r).effect_state.mine_uses
		_hook(r, "mine_hit")
		_check(_state(r).effect_state.mine_uses == uses, "same mine cannot consume another charge")
	_room(r, Vector2i(8, 1))
	_hook(r, "chest_opened")
	_check(r.context.pressure == 4, "chest adds4 via vitals")
	_hook(r, "chest_opened")
	_check(r.context.pressure == 4, "chest pressure once per room")
	_dispose(r)


func _test_power() -> void:
	var r = _runtime("avoidance")
	_check(not _state(r).attack_allowed, "avoidance blocks attack")
	for i in range(1, 10):
		_room(r, Vector2i(i, 0))
		_hook(r, "room_entered", {"first_visit": true})
		_check(r.context.power == 40 + mini(8, i), "avoidance 2.5 percent each new room")
		_hook(r, "room_entered", {"first_visit": true})
		_check(r.context.power == 40 + mini(8, i), "avoidance room dedupe")
	_check(_state(r).attack_allowed, "eight rooms ends attack restriction")
	_dispose(r)
	r = _runtime("avoidance")
	_room(r, Vector2i(1, 0))
	_hook(r, "room_entered", {"first_visit": true})
	_call(r, "end")
	_check(r.context.power == 41 and _state(r).attack_allowed, "manual end retains earned bonus")
	_reject(r, "end")
	_dispose(r)
	r = _runtime("avoidance")
	r.context.truth_map.set_room_type(Vector2i(1, 0), &"Event")
	_room(r, Vector2i(1, 0))
	_hook(r, "forced_cage", {"event_id": "cage"})
	_check(_state(r).attack_allowed and r.context.power == 40, "forced event cage ends avoidance explicitly")
	_dispose(r)
	r = _runtime("power_life", 41)
	_check(r.context.max_hp == 120 and r.context.hp == 80 and r.context.power == 37, "power-life uses frozen41 floor20/floor4 without heal")
	r.context.power += 9
	r.context.max_hp += 10
	_call(r, "end")
	_check(r.context.max_hp == 110 and r.context.power == 50 and r.context.hp == 80, "power-life end removes only own contributions")
	_reject(r, "end")
	_dispose(r)


func _test_status_and_sacrifice() -> void:
	var r = _runtime("status_clear")
	r.context.temporary_statuses.assign([{"id": "a", "type": "temporary_buff", "temporary_type": "speed", "phase": "active"},
		{"id": "b", "type": "temporary_debuff", "temporary_type": "speed", "phase": "active"},
		{"id": "c", "type": "temporary_debuff", "temporary_type": "slow", "phase": "active"},
		{"id": "gear", "type": "equipment", "phase": "active"}])
	_hook(r, "statuses_changed")
	_check(r.context.temporary_statuses[0].phase == "active", "same temp type counts once")
	r.context.temporary_statuses.append({"id": "d", "type": "temporary_buff", "temporary_type": "shield_buff", "phase": "waiting", "start_trigger": "hit", "paid_costs": {"pressure": 5}})
	var result := _hook(r, "statuses_changed")
	_check(result.get("applied", false) and r.context.temporary_statuses[0].phase == "ended" and r.context.temporary_statuses[3].phase == "active", "three temp types clear buffs/debuffs preserve equipment")
	_check(r.context.temporary_statuses[4].paid_costs.pressure == 5, "status clearing does not refund costs")
	r.context.temporary_statuses.append({"id": "e", "type": "temporary_buff", "temporary_type": "new", "phase": "active"})
	_hook(r, "statuses_changed")
	_check(r.context.temporary_statuses[5].phase == "active", "status clear only once")
	_dispose(r)
	r = _runtime("sacrifice")
	for i in range(1, 8):
		_room(r, Vector2i(i, 1))
		r.context.truth_map.mark_cleared(Vector2i(i, 1))
		_hook(r, "ordinary_combat_cleared", {"combat_id": "combat" + str(i), "automatic": false})
		_check(r.context.power == 40 + mini(i, 6) * 2 and r.context.max_hp == 100 - mini(i, 6) * 5, "six max ordinary actual sacrifices")
		_hook(r, "ordinary_combat_cleared", {"combat_id": "another_id", "automatic": false})
		_check(r.context.power == 40 + mini(i, 6) * 2, "reenter clear does not grant power")
	_dispose(r)
	r = _runtime("sacrifice")
	r.context.max_hp = 5
	r.context.hp = 5
	_room(r, Vector2i(1, 1))
	r.context.truth_map.mark_cleared(Vector2i(1, 1))
	_hook(r, "ordinary_combat_cleared", {"combat_id": "small", "automatic": false})
	_check(r.context.max_hp == 5 and r.context.power == 40 and _state(r).effect_state.uses == 0, "unaffordable maxHP payment yields no power/counter")
	_dispose(r)


func _item(r, id: String, weight: int, value: int, equipment: bool = false) -> void:
	r.context.asset_ledger.create_item_instance({"instance_id": id, "item_id": id, "item_type": "equipment" if equipment else "collectible",
		"can_equip": equipment, "weight": weight, "base_value": value, "can_sell": true}, &"inventory")


func _test_cash_and_tools() -> void:
	var r = _runtime("forced_cash")
	_check(r.context.asset_ledger.backpack_capacity == 140, "forced cash grants40percent capacity")
	_item(r, "loot", 112, 101)
	_hook(r, "inventory_changed")
	_check(_black(r) == 0 and r.context.asset_ledger.backpack_capacity == 140, "exact80percent no sale")
	_item(r, "gear", 29, 100, true)
	var result := _hook(r, "inventory_changed")
	_check(_black(r) == 60 and r.context.asset_ledger.backpack_capacity == 100, "strictly over80 sells floor60percent and removes expansion")
	_check(r.context.asset_ledger.item_instances.loot.location_state == &"consumed" and r.context.asset_ledger.item_instances.gear.location_state == &"inventory", "sale excludes equipment")
	_check(result.get("facts", {}).get("black_income_gross", 0) == 60, "cash reports actual gross for common pipeline")
	_hook(r, "inventory_changed")
	_check(_black(r) == 60, "forced cash once")
	_dispose(r)
	r = _runtime("forced_cash")
	_item(r, "worthless", 113, 1)
	_hook(r, "inventory_changed")
	_check(_black(r) == 0 and r.context.asset_ledger.backpack_capacity == 140 and r.context.asset_ledger.item_instances.worthless.location_state == &"inventory", "no gain does not consume item or expansion")
	_dispose(r)
	r = _runtime("dismantle")
	for i in range(4):
		_item(r, "scrap" + str(i), 1, 10)
		if i < 3:
			_check(_call(r, "dismantle", {"instance_id": "scrap" + str(i), "tool": "scan" if i == 0 else "trap"}).get("ok", false), "dismantle actual conversion")
		else:
			_reject(r, "dismantle", {"instance_id": "scrap3", "tool": "trap"})
	_check(_state(r).effect_state.tools.scan == 1 and _state(r).effect_state.tools.trap == 2, "two source-defined tool types")
	_reject(r, "use_tool", {"tool": "scan"})
	_reject(r, "use_tool", {"tool": "scan"}, {"resolve_tool": func(_c, _req): return {"ok": true, "applied": true}})
	var scan := func(c: RunContext, _request: Dictionary) -> Dictionary:
		c.intel_map.learn_event_intel(Vector2i(1, 2), {"known_mine": true, "source": "opening_scan"})
		return {"ok": true, "applied": true}
	var visits: Dictionary = r.context.visited_cells.duplicate(true)
	result = _call(r, "use_tool", {"tool": "scan"}, {"resolve_tool": scan})
	_check(result.get("ok", false) and r.context.pressure == 4 and _state(r).effect_state.tools.scan == 0, "actual scan consumes one tool and adds4")
	_check(r.context.visited_cells == visits and not r.context.intel_map.is_revealed(Vector2i(1, 2)), "scan does not visit/reveal")
	_reject(r, "use_tool", {"tool": "trap"}, {"trap_threshold": func(_c): return 50, "resolve_tool": scan})
	r.context.truth_map.set_room_type(Vector2i.ZERO, &"Event")
	var trap := func(c: RunContext, request: Dictionary) -> Dictionary:
		c.z1_event_rooms[c.cell_key(c.get_current_pos())] = {"completed": true}
		return {"ok": true, "applied": true, "threshold": request.threshold, "stage_completed": true, "facts": {"success": true}}
	result = _call(r, "use_tool", {"tool": "trap"}, {"trap_threshold": func(_c): return 43, "resolve_tool": trap})
	_check(result.get("ok", false) and r.context.pressure == 8 and _state(r).effect_state.tools.trap == 1, "actual trap threshold43to40 consumes1 adds4")
	_reject(r, "use_tool", {"tool": "trap"}, {"trap_threshold": func(_c): return 40, "resolve_tool": trap})
	_dispose(r)


func _test_auto_clear() -> void:
	var r = _runtime("auto_clear")
	for i in range(1, 4):
		_room(r, Vector2i(i, 1))
		var result := _hook(r, "room_entered", {"first_visit": true})
		_check(r.context.truth_map.is_cleared(Vector2i(i, 1)) == (i < 3), "auto clear exactly2 ordinary rooms")
		_check(result.get("facts", {}).get("suppress_combat_rewards", false) == (i < 3), "auto clear suppresses ordinary growth/loot")
		_check(r.context.power == 40 and _black(r) == 0, "auto clear no ordinary reward")
	_room(r, Vector2i(8, 1))
	_check(_hook(r, "chest_opened").get("facts", {}).get("suppress_loot", false), "first chest empty")
	_room(r, Vector2i(9, 1))
	_check(not _hook(r, "chest_opened").get("facts", {}).get("suppress_loot", false), "second chest normal")
	_dispose(r)


func _test_atomic_replay() -> void:
	var r = _runtime("rebate")
	var before: Dictionary = r.capture_authoritative_state()
	r.checkpoint_writer = func(_candidate): return {"ok": false, "reason": "injected_disk_failure"}
	var result := _income(r, 80, "income_atomic")
	_check(not result.get("ok", true) and r.capture_authoritative_state() == before, "disk failure restores income/fees/safe reward/state")
	r.checkpoint_writer = func(_candidate): return {"ok": true}
	r.retry_persistence()
	_check(_income(r, 80, "income_atomic").get("ok", false), "retry completes previously failed income")
	var state := _state(r)
	var encoded: Dictionary = r.encode_checkpoint_state(r.capture_authoritative_state())
	_check(r.restore_checkpoint_state(encoded).get("ok", false) and _state(r) == state, "checkpoint restores opening counters/receipts/policy")
	before = r.capture_authoritative_state()
	result = _income(r, 80, "income_atomic")
	_check(result.get("duplicate", false) and r.capture_authoritative_state() == before, "checkpoint duplicate cannot repay/reaward")
	_dispose(r)
	for effect in ["mine_pressure", "avoidance", "power_life", "status_clear", "sacrifice", "forced_cash", "dismantle", "auto_clear"]:
		r = _runtime(effect)
		state = _state(r)
		encoded = r.encode_checkpoint_state(r.capture_authoritative_state())
		_check(r.restore_checkpoint_state(encoded).get("ok", false) and _state(r) == state, "checkpoint preserves " + effect)
		_dispose(r)


func _checkpoint(r, label: String) -> void:
	var before: Dictionary = r.capture_authoritative_state()
	var state := _state(r)
	var encoded: Dictionary = r.encode_checkpoint_state(before)
	_check(r.restore_checkpoint_state(encoded).get("ok", false) and _state(r) == state, "partial-use checkpoint " + label)


func _test_review_boundaries() -> void:
	var r = _runtime("dismantle")
	_item(r, "scan_blank", 1, 20)
	_call(r, "dismantle", {"instance_id": "scan_blank", "tool": "scan"})
	var blank := func(c: RunContext, _request: Dictionary) -> Dictionary:
		c.intel_map.known_rooms[c.cell_key(Vector2i(1, 2))]["scanned"] = true
		return {"ok": true, "applied": true}
	_reject(r, "use_tool", {"tool": "scan"}, {"resolve_tool": blank})
	_dispose(r)



	r = _runtime("dismantle")
	_item(r, "scan_partial", 1, 20)
	_call(r, "dismantle", {"instance_id": "scan_partial", "tool": "scan"})
	r.context.intel_map.scan_cell(Vector2i(1, 2))
	var improve := func(c: RunContext, _request: Dictionary) -> Dictionary:
		c.intel_map.learn_event_intel(Vector2i(1, 2), {"known_mine": true})
		return {"ok": true, "applied": true}
	var result := _call(r, "use_tool", {"tool": "scan"}, {"resolve_tool": improve})
	_check(result.get("ok", false) and result.get("facts", {}).get("intel_revealed_count", 0) == 1 and _state(r).effect_state.tools.scan == 0, "new mine intelligence on a previously scanned cell is actual benefit")
	_checkpoint(r, "dismantled and spent tool")
	_dispose(r)
	r = _runtime("dismantle")
	_item(r, "scan_mutation", 1, 20)
	_call(r, "dismantle", {"instance_id": "scan_mutation", "tool": "scan"})
	var corrupt_scan := func(c: RunContext, _request: Dictionary) -> Dictionary:
		c.intel_map.learn_event_intel(Vector2i(1, 2), {"known_mine": true})
		c.truth_map.mark_cleared(Vector2i(1, 1))
		return {"ok": true, "applied": true}
	_reject(r, "use_tool", {"tool": "scan"}, {"resolve_tool": corrupt_scan})
	var before: Dictionary = r.capture_authoritative_state()
	var failed_resolver := func(c: RunContext, _request: Dictionary) -> Dictionary:
		c.asset_ledger.add_currency(&"black_coin", 50, "failed_tool")
		c.hp -= 8
		return {"ok": false}
	result = opening.execute(r.context, "use_tool", {"action_id": "direct-rollback", "tool": "scan"}, {"resolve_tool": failed_resolver})
	_check(not result.get("ok", true) and r.capture_authoritative_state() == before, "module itself rolls back callback mutation even without outer commit")
	_dispose(r)
	r = _runtime("forced_cash")
	r.context.asset_ledger.backpack_capacity += 20
	_item(r, "valuable", 10, 50)
	_item(r, "heavy_gear", 125, 200, true)
	result = _hook(r, "inventory_changed")
	_check(result.get("ok", false) and r.context.asset_ledger.backpack_capacity == 120 and _black(r) == 30, "forced cash removes only own expansion, preserves other20")
	_check(r.context.asset_ledger.item_instances.heavy_gear.location_state == &"room_floor" and result.facts.overflow_dropped == ["heavy_gear"], "overflow drops actual unsold instance without destroying it")
	_checkpoint(r, "forced cash and overflow")
	_dispose(r)
	for id in ["mine_pressure", "avoidance", "sacrifice", "auto_clear"]:
		r = _runtime(id)
		var kind := "room_entered"
		var extra := {"first_visit": true}
		if id == "mine_pressure":
			_room(r, Vector2i(1, 2))
			r.context.truth_map.mark_triggered(Vector2i(1, 2))
			kind = "mine_hit"
		elif id == "sacrifice":
			_room(r, Vector2i(1, 1))
			r.context.truth_map.mark_cleared(Vector2i(1, 1))
			kind = "ordinary_combat_cleared"
			extra = {"combat_id": "actual-first", "automatic": false}
		else:
			_room(r, Vector2i(1, 1))
		_hook(r, kind, extra)
		_checkpoint(r, id)
		var state: Dictionary = _state(r).effect_state.duplicate(true)
		_hook(r, kind, extra)
		_check(_state(r).effect_state == state, "restored real room fact does not consume again " + id)
		_dispose(r)
	r = _runtime("rebate")
	_income(r, 20, "principal", "refund")
	_income(r, 60, "withdrawal", "savings_withdrawal")
	_check(_black(r) == 50 and _state(r).effect_state.gross == 80, "all actual gross includes whole60 withdrawal principal")
	_dispose(r)
	r = _runtime("dismantle")
	_item(r, "fractional_trap", 1, 20)
	_call(r, "dismantle", {"instance_id": "fractional_trap", "tool": "trap"})
	r.context.truth_map.set_room_type(Vector2i.ZERO, &"Event")
	var wrong_room := func(c: RunContext, req: Dictionary) -> Dictionary:
		c.z1_event_rooms["unrelated_room"] = {"completed": true}
		return {"ok": true, "applied": true, "threshold": req.threshold, "stage_completed": true, "facts": {"success": true}}
	_reject(r, "use_tool", {"tool": "trap"}, {"trap_threshold": func(_c): return 43, "resolve_tool": wrong_room})
	var fractional := func(c: RunContext, req: Dictionary) -> Dictionary:
		c.z1_event_rooms[c.cell_key(c.get_current_pos())] = {"completed": true, "threshold": req.threshold}
		return {"ok": true, "applied": true, "threshold": req.threshold, "stage_completed": true, "facts": {"success": true}}
	result = _call(r, "use_tool", {"tool": "trap"}, {"trap_threshold": func(_c): return 42.5, "resolve_tool": fractional})
	_check(result.get("ok", false) and result.get("facts", {}).get("threshold_reduction", 0) == 3.0, "real fractional mechanism threshold42.5 reduces to39.5")
	_check(result.get("tool_result", {}).get("stage_completed", false), "parent receives actual nested event stage receipt")
	_dispose(r)


func _test_positive_currency_loop() -> void:
	var r = _runtime("rebate")
	for credit in [["black_coin", 20], ["gold_coin", 8], ["black_coin", 60]]:
		r.context.asset_ledger.add_currency(StringName(credit[0]), credit[1], "actual_income")
	var index := 0
	while index < r.context.asset_ledger.settlement_log.size():
		var entry: Dictionary = r.context.asset_ledger.settlement_log[index]
		if str(entry.get("type", "")) == "currency_delta" and int(entry.get("amount", 0)) > 0:
			var fact_id := "currency:%s:%d" % [r.context.run_id, index]
			var fact := {"kind": "currency_income", "fact_id": fact_id, "actual": true, "ledger_index": index, "gross": int(entry.amount)}
			var result := _call(r, "hook", {"fact": fact}, {}, "opening:" + fact_id)
			_check(result.get("ok", false), "all positive currencies dispatch safely " + str(entry.currency_id))
			var state: Dictionary = _state(r).effect_state.duplicate(true)
			result = _call(r, "hook", {"fact": fact}, {}, "opening:" + fact_id)
			_check(result.get("duplicate", false) and _state(r).effect_state == state, "all positive currency loop stable action replay")
			if str(entry.currency_id) == "black_coin":
				_hook(r, "black_income", {"ledger_index": index, "gross": int(entry.amount)})
				_check(_state(r).effect_state == state, "legacy black hook cannot duplicate currency alias")
		index += 1
	_check(_black(r) == 50 and r.context.asset_ledger.get_currency(&"gold_coin") == 58, "all-positive loop counts only actual black and terminates after safe rebate")
	_dispose(r)
