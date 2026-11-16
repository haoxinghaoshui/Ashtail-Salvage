extends SceneTree

const Context = preload("res://scripts/core/run/run_context.gd")
const Lifecycle = preload("res://scripts/core/run/run_state_machine.gd")
const Snapshot = preload("res://scripts/core/run/run_state_snapshot.gd")
const Items = preload("res://scripts/core/content/z2_item_catalog.gd")
const Meta = preload("res://scripts/core/save/meta_progress_adapter.gd")
const Rules = preload("res://scripts/core/progression/z2_progression_rules.gd")
const Checkpoint = preload("res://scripts/core/save/run_checkpoint_service.gd")
const StartConfig = preload("res://scripts/core/run/run_start_config.gd")
const Catalog = preload("res://scripts/core/content/m7_content_catalog.gd")
var failures: Array[String] = []
var checks := 0

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var path := "res://scripts/core/run/run_settlement_service.gd"
	if not ResourceLoader.exists(path):
		print("Z2_SETTLEMENT_SERVICE=FAIL service_missing")
		quit(1)
		return
	var service = load(path)
	for ending in ["success", "failure", "abandon"]:
		var context := Context.new()
		Lifecycle.new().start_standard_run(context, {"map_config_id": "classic_7x7_simple", "difficulty": "simple", "profile_fields": {"ruleset_id": "z2", "z2_progression_version": 1}})
		context.asset_ledger.add_currency(&"black_coin", 17, "fixture")
		context.asset_ledger.add_currency(&"gold_coin", 7, "fixture")
		var item: Dictionary = Items.definition("col_01")
		item["instance_id"] = "settlement-test-item"
		item["location_state"] = &"inventory"
		context.asset_ledger.item_instances[item.instance_id] = item
		var new_room := Vector2i((context.player_pos.x + 1) % context.truth_map.width, context.player_pos.y)
		context.record_event(&"room_entered", "test-enter", &"player", "room_resolver", {"position": new_room, "room_type": &"Normal"})
		var before: Dictionary = Snapshot.capture_context(context)
		var preview: Dictionary = service.build(context, ending, [], true)
		_check(preview.get("ok", false), ending + " preview available")
		_check(Snapshot.capture_context(context) == before, ending + " preview is read-only")
		if ending != "success":
			_check(preview.settlement.salvage_capacity == 40 and preview.settlement.requires_salvage_selection, ending + " offers base40 selection")
			var bad: Dictionary = service.build(context, ending, ["missing"])
			_check(not bad.get("ok", true) and Snapshot.capture_context(context) == before, ending + " invalid selection has no effect")
		var plan: Dictionary = service.build(context, ending, ["settlement-test-item"])
		_check(plan.get("ok", false), ending + " plan accepts owned instance")
		var result: Dictionary = service.apply(context, plan)
		_check(result.get("ok", false) and result.get("finalized", false), ending + " finalized")
		_check(str(result.get("outcome", "")) == ending, ending + " preserves ending")
		_check(result.get("long_term_gold_gained", -1) == (24 if ending == "success" else 7), ending + " currency kept once")
		_check(result.get("warehouse_items", []).size() == 1, ending + " chosen instance has warehouse destination")
		_check(result.get("z2_growth", {}).get("talent_points", -1) == 1, ending + " genuine progress yields talent")
		_check(not service.apply(context, plan).get("ok", true), ending + " stale plan cannot duplicate settlement")
	var bonus_context := Context.new()
	Lifecycle.new().start_standard_run(bonus_context, {"map_config_id": "classic_7x7_simple", "difficulty": "simple", "profile_fields": {"ruleset_id": "z2", "z2_progression_version": 1}})
	bonus_context.active_talent_effects = [{"talent_id": "z2_talent_14", "effect_kind": "extraction_gold_percent", "effect_amount": 5}, {"talent_id": "z2_talent_18", "effect_kind": "extraction_gold_percent", "effect_amount": 10}]
	bonus_context.asset_ledger.add_currency(&"black_coin", 101)
	bonus_context.asset_ledger.add_currency(&"gold_coin", 7)
	var bonus_plan: Dictionary = service.build(bonus_context, "success")
	_check(bonus_plan.settlement.long_term_gold_gained == 123, "15percent applies once to black coin only")
	bonus_context.active_talent_effects = []
	bonus_context.asset_ledger.currency_balances[&"black_coin"] = 9007199254740993
	var precise_plan: Dictionary = service.build(bonus_context, "success")
	_check(precise_plan.settlement.long_term_gold_gained == 9007199254741000, "currency conversion preserves int64")
	_check_frozen_warehouse_items()
	for failure in failures:
		print("Z2_SETTLEMENT_CASE_FAIL " + failure)
	print("Z2_SETTLEMENT_SERVICE=%s checks=%d failures=%d" % ["PASS" if failures.is_empty() else "FAIL", checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _check_frozen_warehouse_items() -> void:
	for ending in ["success", "failure", "abandon"]:
		var meta := Meta.new()
		meta.set_active_profile_path("user://z2_frozen_%s_%d/meta.json" % [ending, Time.get_ticks_usec()], "frozen-" + ending)
		_check(meta.initialize_z2_profile(Rules.CONTENT_VERSION).get("ok", false), ending + " creates current profile")
		if not _complete_teaching(meta):
			continue
		var admitted := _admitted_context(meta, "classic_7x7_simple")
		if admitted.is_empty():
			continue
		var context: RunContext = admitted.context
		meta.load_or_create_default()
		_check(meta.data.admission.get("phase") == "active" and meta.data.z2_quest_departures.has(str(context.run_id)), ending + " reloads real departure reservation")
		var item: Dictionary = Items.definition("eq_signal_pin")
		item["instance_id"] = "frozen-signal-pin"
		item["location_state"] = &"inventory"
		item["counters"] = {"uses": 1}
		context.asset_ledger.item_instances[item.instance_id] = item.duplicate(true)
		context.record_event(&"item_picked_up", "frozen-item-fixture", &"player", "acceptance_fixture", {"position": context.player_pos, "item": item.duplicate(true)})
		match ending:
			"success": context.complete_extract()
			"failure": context.fail_run("frozen_item_test")
			"abandon": context.abandon_run()
		if not context.settlement_result.get("finalized", false):
			_check(context.confirm_failure_salvage([item.instance_id]).get("ok", false), ending + " confirms real terminal selection")
		var result := context.result_snapshot.duplicate(true)
		_check(result.settlement.get("finalized", false) and str(result.settlement.outcome) == ending, ending + " builds complete finalized RunResult")
		var committed: Dictionary = admitted.checkpoint.apply_settlement(result)
		_check(committed.get("ok", false), ending + " terminal profile write")
		meta.load_or_create_default()
		var arrivals: Array = meta.data.get("warehouse_items", [])
		_check(arrivals.size() == 1, ending + " one persisted instance")
		if arrivals.is_empty():
			continue
		var saved: Dictionary = arrivals[0]
		for field in ["instance_id", "content_version", "purchase_price", "base_value", "effect_params", "counters"]:
			_check(SaveAdapter.json_fingerprint(meta._json_safe({"value": saved.get(field)})) == SaveAdapter.json_fingerprint(meta._json_safe({"value": item.get(field)})), ending + " preserves " + field)
		var expected := item.duplicate(true)
		expected.location_state = "warehouse"
		if expected.has("base_weight"):
			expected.weight = int(expected.base_weight)
		var expected_fingerprint := SaveAdapter.json_fingerprint(meta._json_safe(expected))
		_check(not expected_fingerprint.is_empty() and SaveAdapter.json_fingerprint(meta._json_safe(saved)) == expected_fingerprint, ending + " preserves the entire original item apart from warehouse location and base weight")
		var disk := FileAccess.get_file_as_bytes(meta.active_meta_progress_path)
		_check(meta.apply_settlement(result).get("ok", false) and FileAccess.get_file_as_bytes(meta.active_meta_progress_path) == disk and meta.data.warehouse_items.size() == 1, ending + " replay preserves exact saved item without another write")

func _complete_teaching(meta) -> bool:
	_check(meta.begin_tutorial_training().get("ok", false), "teaching starts through Meta")
	_check(meta.purchase_tutorial_flag().get("ok", false), "teaching flag purchase commits")
	var admitted := _admitted_context(meta, "tutorial_5x5")
	if admitted.is_empty():
		return false
	admitted.context.complete_extract()
	var result: Dictionary = admitted.checkpoint.apply_settlement(admitted.context.result_snapshot)
	meta.load_or_create_default()
	var ready: bool = result.get("ok", false) and meta.data.tutorial_completed and meta.data.profile_level == 1 and meta.data.talent_spent == 100
	_check(ready, "real teaching terminal persists legal level and purchased talent")
	return ready

func _admitted_context(meta, map_id: String) -> Dictionary:
	var config := StartConfig.default_config()
	config.merge({"map_config_id": map_id, "difficulty": Catalog.map_definition_exact(map_id).difficulty, "seed_value": 71}, true)
	config.selected_objective_id = "" if map_id == "tutorial_5x5" else Catalog.commission_offer_candidates(map_id, 0)[0].id
	var authorized := StartConfig.authorize_with_meta(config, meta.get_summary())
	_check(authorized.get("ok", false), map_id + " authorized from trusted Meta")
	if not authorized.get("ok", false):
		return {}
	var context := Context.new()
	_check(Lifecycle.new().start_standard_run(context, authorized.config).get("ok", false), map_id + " actual context starts")
	var checkpoint := Checkpoint.new()
	_check(checkpoint.configure(meta, "z2", Rules.CONTENT_VERSION).get("ok", false), map_id + " checkpoint configures")
	var snapshot := {"schema_version": 1, "profile_id": meta.active_profile_id, "run_id": str(context.run_id), "revision": 0,
		"ruleset_id": "z2", "content_version": Rules.CONTENT_VERSION, "state": Snapshot.pack_checkpoint({"context": Snapshot.capture_context(context)})}
	var admitted := checkpoint.begin_admission(snapshot)
	_check(admitted.get("ok", false) and admitted.get("can_simulate", false), map_id + " prepared and active admission persist")
	return {"context": context, "checkpoint": checkpoint} if admitted.get("ok", false) else {}

func _check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)
