extends SceneTree

const Runtime = preload("res://scripts/core/run/run_runtime_controller.gd")
const Meta = preload("res://scripts/core/save/meta_progress_adapter.gd")
const Progress = preload("res://scripts/core/progression/m7_progression_service.gd")
const Rules = preload("res://scripts/core/progression/z2_progression_rules.gd")
const Items = preload("res://scripts/core/content/z2_item_catalog.gd")
const Snapshot = preload("res://scripts/core/run/run_state_snapshot.gd")
var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var meta := Meta.new()
	meta.set_active_profile_path("user://z2_supply_integration_%d/meta.json" % Time.get_ticks_usec(), "supplies")
	meta.initialize_z2_profile(Rules.CONTENT_VERSION)
	meta.data.tutorial_completed = true
	meta.data.profile_level = 2
	meta.data.profile_exp = 30
	meta.data.talent_flags = ["z2_talent_01"]
	meta.data.talent_spent = 100
	meta.data.talent_points = 0
	var equipment: Array = []
	var consumables: Array = []
	var owned := {}
	for id in ["eq_old_vest", "eq_edge_opener", "eq_recovery_bag", "con_ration", "con_red_battery", "con_hard_shell_patch", "con_salvage_seal"]:
		var item: Dictionary = Progress.add_item_instance(meta.data, id, "fixture")
		owned[id] = item.instance_id
		if id.begins_with("eq_"):
			equipment.append(item.instance_id)
		else:
			consumables.append(item.instance_id)
	meta.save()
	var runtime := Runtime.new()
	runtime.bind_meta_progress_adapter(meta)
	runtime.checkpoint_writer = func(_candidate: Dictionary) -> Dictionary: return {"ok": true}
	var started: Dictionary = runtime.command_bus.dispatch(&"start_standard_run", {"run_start_config": {"map_config_id": "classic_7x7_simple", "difficulty": "simple", "seed_value": 3141, "selected_equipment_ids": equipment, "selected_consumable_ids": consumables, "selected_objective_id": "commission_recover_supply"}})
	_check(started.get("ok", false), "actual departure admits frozen loadout")
	if not started.get("ok", false):
		print("SUPPLY_START_FAILURE ", started)
		_release(runtime)
		quit(1)
		return
	var context: RunContext = runtime.context
	_check(context.max_hp == 105 and context.power == 25 and context.asset_ledger.backpack_capacity == 110, "departure applies each equipment parameter once")
	_check(context.asset_ledger.item_instances[owned.eq_edge_opener].base_value == -1, "undefined supply resale value remains undefined")
	var before := Snapshot.capture_context(context)
	_check(not runtime.command_bus.dispatch(&"use_consumable", {"instance_id": owned.con_ration}).get("ok", true), "no-benefit ration rejected")
	_check(Snapshot.capture_context(context) == before, "no-benefit use preserves item and all effects")
	_check(runtime.command_bus.dispatch(&"use_consumable", {"instance_id": owned.con_red_battery}).get("ok", false), "battery actual use")
	_check(context.pressure == 5, "battery pays pressure five")
	var request := {"instance_id": owned.con_hard_shell_patch, "action_id": "use-patch"}
	_check(runtime.command_bus.dispatch(&"use_consumable", request).get("ok", false), "hard shell actual use")
	_check(context.shield == 40, "battery doubles next successful patch")
	runtime.command_bus.dispatch(&"use_consumable", request)
	_check(context.shield == 40, "replayed consume cannot regrant shield")
	_check(str(context.asset_ledger.item_instances[owned.con_hard_shell_patch].location_state) == "consumed", "actual used instance removed")
	_check(runtime.command_bus.dispatch(&"use_consumable", {"instance_id": owned.con_salvage_seal}).get("ok", false), "carried seal use")
	_check(context.asset_ledger.failure_salvage_capacity == 60 and bool(context.z1_event_flags.get("z2_salvage_seal_used", false)), "seal shares cabinet limit and settlement effect")
	var armor := Items.definition("eq_strapped_backplate")
	armor.instance_id = "new-armor"
	var grant: Dictionary = context.asset_ledger.add_reward_items([armor], &"inventory", context.get_current_pos(), "fixture")
	_check(grant.get("ok", false), "new armor physically granted")
	context.hp = 50
	var shield_before: int = context.shield
	var equipped: Dictionary = runtime.command_bus.dispatch(&"equip_item", {"instance_id": "new-armor"})
	_check(equipped.get("ok", false), "newly acquired equipment can be worn")
	_check(context.max_hp == 90 and context.hp == 50, "same-slot swap preserves absolute HP and applies negative max HP")
	_check(context.shield == shield_before, "mid-run equip does not grant departure shield")
	_check(runtime.command_bus.dispatch(&"unequip_item", {"instance_id": "new-armor"}).get("ok", false), "new equipment can be removed")
	_check(context.max_hp == 100 and context.hp == 50, "unequip restores maximum without healing")
	_check(runtime.command_bus.dispatch(&"equip_item", {"instance_id": owned.eq_old_vest}).get("ok", false) and context.max_hp == 105 and context.hp == 50, "re-equip old instance retains absolute HP")
	var ledger := RunAssetLedger.new()
	ledger.setup({"profile_fields": {"ruleset_id": "z2", "z2_progression_version": 1, "consumable_weight_reduce": 2}})
	var small: Dictionary = ledger.create_item_instance(Items.definition("con_ration"), &"inventory")
	_check(int(small.weight) == 2 and int(small.get("base_weight", 0)) == 4, "newly acquired consumables share reduction with carried supplies")
	_release(runtime)
	for failure in failures:
		print("Z2_SUPPLY_INTEGRATION_FAIL " + failure)
	print("Z2_SUPPLY_INTEGRATION=%s checks=%d failures=%d" % ["PASS" if failures.is_empty() else "FAIL", checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _release(runtime) -> void:
	runtime.command_bus.runtime_controller = null
	runtime.command_bus.room_resolver.bind_runtime_controller(null)
	runtime.in_run_runtime.bind(null)

func _check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)
