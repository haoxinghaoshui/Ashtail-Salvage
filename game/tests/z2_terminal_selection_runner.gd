extends SceneTree

const Context = preload("res://scripts/core/run/run_context.gd")
const Lifecycle = preload("res://scripts/core/run/run_state_machine.gd")
const Service = preload("res://scripts/core/run/run_settlement_service.gd")
const Snapshot = preload("res://scripts/core/run/run_state_snapshot.gd")
const Items = preload("res://scripts/core/content/z2_item_catalog.gd")
var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var service = load("res://scripts/core/run/run_settlement_service.gd")
	for ending in ["success", "failure", "abandon"]:
		for retention in range(3):
			var context := _context(retention)
			var before := Snapshot.capture_context(context)
			var preview: Dictionary = Service.build(context, ending, [], true)
			_check(preview.get("ok", false) and Snapshot.capture_context(context) == before, ending + " preview pure")
			var pool: Array = preview.get("settlement", {}).get("settlement_pool", [])
			var expected_limit := (1 if ending == "success" else retention) if retention > 0 else 0
			_check(int(preview.get("settlement", {}).get("retention_limit", -1)) == expected_limit, ending + " retention limit " + str(retention))
			_check(pool.any(func(item: Dictionary) -> bool: return str(item.get("instance_id", "")) == "medicine-a") == (retention > 0), ending + " eligibility in selection")
			var selected: Array = ["loot-a", "loot-b"]
			if retention > 0:
				selected = ["loot-a", "medicine-a"]
				if expected_limit == 2:
					selected.append("medicine-b")
			var plan: Dictionary = service.build(context, ending, selected, false, {"selection_confirmed": true}) if service.get_script_method_list().any(func(method: Dictionary) -> bool: return method.name == "build" and method.args.size() >= 5) else service.build(context, ending, selected)
			_check(plan.get("ok", false), ending + " chosen original items accepted " + str(retention))
			if not plan.get("ok", false):
				continue
			var result: Dictionary = Service.apply(context, plan)
			var locations: Dictionary = context.asset_ledger.item_instances
			_check(result.get("finalized", false), ending + " finalized")
			_check(str(locations.freight.location_state) == "warehouse", ending + " freight delivered")
			_check(str(locations.pawn.location_state) == ("warehouse" if ending == "success" else "lost"), ending + " pledged item has one destination")
			_check(int(result.get("gold_coin_gained", -1)) == 5, ending + " safe original amount and redemption ordering")
			_check(str(locations["medicine-a"].location_state) == ("warehouse" if retention > 0 else "cleared"), ending + " original consumable destination")
			_check(str(locations["medicine-b"].location_state) == ("warehouse" if expected_limit == 2 else "cleared"), ending + " second consumable limit")
			_check(int(locations["loot-a"].weight) == 30, "settlement discount never changes physical weight")
			if retention == 0 and ending != "success":
				_check(int(result.get("selected_salvage_weight", -1)) == 50, "seal discounts one selected heaviest")
				_check(str(result.get("discounted_instance_id", "")) == "loot-a", "seal stable instance tie")
	var context := _context(1)
	var pending: Dictionary = Service.apply(context, Service.build(context, "success"))
	_check(pending.get("requires_salvage_selection", false) and not pending.get("finalized", true), "successful extraction waits for retention choice")
	var original := Snapshot.capture_context(context)
	if service.get_script_method_list().any(func(method: Dictionary) -> bool: return method.name == "build" and method.args.size() >= 5):
		for choice in [["loot-a", "loot-b", "medicine-a"], ["medicine-a", "medicine-b"], ["medicine-a", "medicine-a"], ["missing"]]:
			var rejected: Dictionary = service.build(context, "success", choice, false, {"selection_confirmed": true})
			_check(not rejected.get("ok", true) and Snapshot.capture_context(context) == original, "invalid success choice is atomic " + str(choice))
	_check_lifecycle()
	await _check_result_ui()
	for failure in failures:
		print("Z2_TERMINAL_SELECTION_FAIL " + failure)
	print("Z2_TERMINAL_SELECTION=%s checks=%d failures=%d" % ["PASS" if failures.is_empty() else "FAIL", checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _check_lifecycle() -> void:
	for entry in ["complete_extract", "force_extract"]:
		var direct := _context(1)
		var authority := Lifecycle.new()
		authority.call(entry, direct)
		_check(direct.phase == &"failure_salvage" and not direct.settlement_result.get("finalized", false), entry + " preserves pending successful retention")
		_check(authority.confirm_failure_salvage(direct, ["loot-a", "medicine-a"]).get("ok", false), entry + " pending selection remains confirmable")
	var context := _context(1)
	var lifecycle := Lifecycle.new()
	_check(lifecycle.request_extract(context, true).get("ok", false), "extraction confirmation opens")
	_check(lifecycle.confirm_extract(context, true).get("ok", false), "extraction acceptance freezes run")
	_check(context.extracted and not context.run_active and context.phase == &"failure_salvage", "success retains recoverable terminal selection")
	_check(not context.failure_salvage.get("settlement_pool", []).is_empty(), "success publishes retention pool")
	var resumed := Context.new()
	Snapshot.install_context(resumed, Snapshot.capture_context(context))
	var finished: Dictionary = lifecycle.confirm_failure_salvage(resumed, ["loot-a", "medicine-a"])
	_check(finished.get("ok", false) and resumed.phase == &"extracted", "restored success selection finalizes")
	_check(resumed.result_snapshot.get("settlement", {}).get("outcome", "") == "success", "selection preserves successful ending")
	_check(str(resumed.asset_ledger.item_instances["medicine-a"].location_state) == "warehouse", "selected consumable survives lifecycle")

func _check_result_ui() -> void:
	var context := _context(1)
	var lifecycle := Lifecycle.new()
	lifecycle.request_extract(context, true)
	lifecycle.confirm_extract(context, true)
	var panel = load("res://scenes/ui/result/result_panel.tscn").instantiate()
	root.add_child(panel)
	await process_frame
	if panel.get_property_list().any(func(property: Dictionary) -> bool: return property.name == "terminal_selection_query"):
		var service = load("res://scripts/core/run/run_settlement_service.gd")
		panel.terminal_selection_query = func(ids: Array) -> Dictionary: return service.selection_state(context, "success", ids)
	panel.show_summary(context.result_snapshot)
	_check(panel.selected_salvage_ids.has("loot-a") and panel.selected_salvage_ids.has("loot-b"), "success UI initially preserves existing loot")
	_check(not str(panel.salvage_consequence_label.text).contains("黑资损失"), "success choice does not claim loss of black coin")
	_check(int(panel.salvage_candidate_buttons["medicine-a"].get_meta("weight", 0)) == 10, "retained consumable displays fixed ten settlement weight")
	panel._toggle_salvage_item("loot-b", false)
	panel._toggle_salvage_item("medicine-a", true)
	_check(panel.salvage_candidate_buttons["medicine-b"].disabled, "UI enforces one retained consumable")
	_check(str(panel.salvage_capacity_label.text).contains("40 / 60"), "UI uses authoritative selection weight")
	_check(not str(panel.salvage_capacity_label.text).contains("所有消耗品都无法带回"), "UI explains permitted retention")
	panel.queue_free()
	await process_frame

func _context(retention: int) -> RunContext:
	var context := Context.new()
	Lifecycle.new().start_standard_run(context, {"map_config_id": "classic_7x7_simple", "profile_fields": {"ruleset_id": "z2", "z2_progression_version": 1}})
	context.asset_ledger.backpack_capacity = 60
	context.asset_ledger.failure_salvage_capacity = 60
	context.z1_event_flags["z2_salvage_seal_used"] = true
	if retention > 0:
		context.active_talent_effects.append({"effect_kind": "consumable_retention", "effect_amount": 1})
	if retention > 1:
		context.active_talent_effects.append({"effect_kind": "failure_consumable_conversion_count", "effect_amount": 1})
	for descriptor in [["loot-b", "col_01", "inventory"], ["loot-a", "col_01", "inventory"], ["medicine-a", "con_ration", "inventory"], ["medicine-b", "con_tape_roll", "inventory"], ["freight", "col_01", "consigned"], ["pawn", "col_01", "pledged"]]:
		var item: Dictionary = Items.definition(descriptor[1])
		item.instance_id = descriptor[0]
		item.location_state = descriptor[2]
		if str(descriptor[0]).begins_with("loot-"):
			item.weight = 30
		context.asset_ledger.item_instances[item.instance_id] = item
	context.asset_ledger.add_currency(&"black_coin", 16)
	context.asset_ledger.add_currency(&"gold_coin", 5)
	return context

func _check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)
