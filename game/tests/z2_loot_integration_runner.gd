extends SceneTree

const PATH := "res://scripts/core/content/z2_loot_catalog.gd"
const Items := preload("res://scripts/core/content/z2_item_catalog.gd")
const Eligibility := preload("res://scripts/core/content/z2_content_eligibility.gd")
const Content := preload("res://scripts/core/run/run_content_catalog.gd")
const Legacy := preload("res://scripts/core/content/z1_loot_catalog.gd")
const OldItems := preload("res://scripts/core/content/m3_item_catalog.gd")
const Context := preload("res://scripts/core/run/run_context.gd")
const Snapshot := preload("res://scripts/core/run/run_state_snapshot.gd")
const Economy := preload("res://scripts/core/run/z2_economy_events.gd")
const Rules := preload("res://scripts/core/run/run_rule_service.gd")
const MAP := "classic_13x13_hell"
const CHANNELS := ["search", "chest", "monster", "mechanism_success", "compression", "recycle", "altar", "shop"]
var loot: Script
var checks := 0
var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	# Existing production entry points must fail on the old path, independently of the new file.
	var run := _context(1)
	for item in Content.search_items(Vector2i(2, 2), 0, true, 5, run):
		_check(item.get("content_version", "") == Items.CONTENT_VERSION, "actual chest emits Z2 frozen units")
	run.enemy_state = {"monster_type": "z1_monster_m03"}
	_check(Content.monster_trophy(Vector2i(2, 2), 1, run).get("item_id") != "sp_inspection_calibration_plate", "Z2 m03 no old guaranteed sample")
	_check(FileAccess.file_exists(PATH), "new actual loot catalog exists")
	if FileAccess.file_exists(PATH):
		loot = load(PATH)
		if loot != null and loot.can_instantiate():
			_catalog_and_channels()
			_weights_and_boundaries()
			_actual_drops_and_restart()
			_economy_and_process_contracts()
			_search_empty_gate()
			_legacy_path()
		else:
			_check(false, "loot catalog compiles")
	for failure in failures:
		print("Z2_LOOT_CASE_FAIL " + failure)
	print("Z2_LOOT_INTEGRATION=%s checks=%d failures=%d" % ["PASS" if failures.is_empty() else "FAIL", checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _context(level: int, map_id: String = MAP) -> RunContext:
	var run := Context.new()
	run.start_run({"id": "t07_loot", "mode": &"standard", "seed": 19, "width": 7, "height": 7,
		"manual_map": {"spawn": Vector2i(2, 2), "mines": [], "monsters": [], "events": [], "chests": [], "exits": []}})
	run.run_start_config.map_config_id = map_id
	run.run_start_config.profile_fields = {"ruleset_id": "z2", "z2_progression_version": 1,
		"content_eligibility": Eligibility.freeze_profile({"profile_level": level})}
	run.profile_fields = run.run_start_config.profile_fields.duplicate(true)
	return run


func _frozen(level: int) -> Dictionary:
	return Eligibility.freeze_profile({"profile_level": level, "research_completed_ids": ["research_hard_shell_patch", "research_red_battery", "research_black_box_bell"]})


func _ids(pool: Array) -> Array:
	return pool.map(func(entry: Dictionary) -> String: return str(entry.item_id))


func _catalog_and_channels() -> void:
	var seen := {}
	for channel in CHANNELS:
		for stage in range(1, 6) if channel == "altar" else [1]:
			var pool: Array = loot.candidates(channel, _frozen(50), MAP, stage)
			_check(not pool.is_empty(), "all actual pools reachable " + channel + str(stage))
			var sum := 0.0
			for entry: Dictionary in pool:
				var item: Dictionary = loot.definition(entry.item_id)
				_check(not item.is_empty() and float(entry.roll_weight) > 0, "weighted real definition " + str(entry.item_id))
				_check(Eligibility.is_eligible(entry.item_id, channel, _frozen(50), MAP), "pool passes actual channel " + str(entry.item_id))
				_check(str(item.get("required_research_id", "")).is_empty(), "research products never random " + channel)
				_check(not bool(item.get("is_unique", false)), "no unique placeholders")
				sum += float(entry.probability)
				if item.item_type == "collectible":
					seen[item.item_id] = true
					var tier := int(item.collectible_level)
					if channel == "search": _check(tier in [1, 2], "search uses true tier")
					if channel == "chest": _check(tier in [3, 4], "chest uses true tier")
					if channel == "compression": _check(tier == 2, "compression true tier2")
			_check(is_equal_approx(sum, 1.0), "normalized after filter " + channel)
	_check(seen.size() == 42, "all 42 true collectibles reachable")
	for id in ["con_hard_shell_patch", "con_red_battery", "eq_black_box_bell"]:
		for channel in CHANNELS + ["camp_shop", "starter_claim"]:
			_check(not Eligibility.is_eligible(id, channel, _frozen(50), MAP), "research-only " + id + channel)
		_check(Eligibility.is_eligible(id, "research_craft", _frozen(1), MAP), "repeat crafting allowed " + id)
	for channel in ["qualification", "event", "extra_drop", "unknown"]:
		_check(loot.candidates(channel, _frozen(50), MAP).is_empty(), "no ambiguous acquisition channel " + channel)
	for channel in CHANNELS:
		_check(not bool(loot.preflight(channel, _frozen(0), MAP).ok), "empty required preflight " + channel)
		_check(loot.roll(channel, Vector2i.ZERO, 3, _frozen(0), MAP).is_empty(), "empty roll has no fallback " + channel)
	for item in Items.all_items():
		var id := str(item.item_id)
		if not str(item.required_research_id).is_empty(): continue
		var minimum := int(item.min_profile_level)
		for channel in item.channels:
			_check(not Eligibility.is_eligible(id, channel, _frozen(minimum - 1), MAP), "level below " + id)
			_check(Eligibility.is_eligible(id, channel, _frozen(minimum), MAP), "level boundary " + id)
	for id in ["mon_old_gear_set", "mon_overheated_core", "mon_loader_black_box", "sp_inspection_calibration_plate", "sp_transit_lead_seal", "sp_reset_spring", "sp_depressurized_valve_core", "sp_altar_residue"]:
		var material: Dictionary = loot.definition(id)
		var original := {}
		for item in OldItems.all_items():
			if str(item.item_id) == id: original = item
		_check(not material.is_empty() and material.weight == original.weight and material.base_value == original.base_value, "exact inherited material units " + id)
	_check(loot.definition("sp_trader_receipt").is_empty(), "no arbitrary old definition fallback")
	_check(loot.definition("col_20").item_type == "collectible" and loot.definition("mon_overheated_core").item_type == "special", "same-name core IDs distinct")


func _weights_and_boundaries() -> void:
	for row in [["classic_7x7_simple", 0.15, 0.20], ["classic_13x13_normal", 0.25, 0.35], ["classic_13x13_hard", 0.35, 0.50], [MAP, 0.45, 0.65]]:
		var search: Array = loot.candidates("search", _frozen(50), row[0])
		_check(is_equal_approx(_tier_probability(search, 2), 0.70 * float(row[1])), "Z1 search difficulty share " + str(row[0]))
		var chest: Array = loot.candidates("chest", _frozen(50), row[0])
		_check(is_equal_approx(_tier_probability(chest, 4), 0.70 * float(row[2])), "Z1 chest difficulty share " + str(row[0]))
	var initial: Array = loot.candidates("search", _frozen(1), MAP)
	_check(is_equal_approx(_tier_probability(initial, 2), 0.70 * 0.45 / 0.95), "empty equipment category renormalizes before draw")
	_check(is_equal_approx(_prob(initial, "con_ration") / _prob(initial, "con_tape_roll"), 1.5), "60:40 roll weights not physical weight")
	for map_id in ["classic_7x7_simple", "classic_13x13_normal", "classic_13x13_hard", MAP]:
		var chest_ids := _ids(loot.candidates("chest", _frozen(50), map_id))
		var monster_ids := _ids(loot.candidates("monster", _frozen(50), map_id))
		var mechanism_ids := _ids(loot.candidates("mechanism_success", _frozen(50), map_id))
		_check(chest_ids.has("eq_folding_shovel") == map_id.begins_with("classic_13"), "shovel 13 maps " + map_id)
		_check(chest_ids.has("con_waiver_medicine") == (map_id in ["classic_13x13_hard", MAP]), "waiver difficult13 " + map_id)
		_check(chest_ids.has("con_countdown_pill") == (map_id == MAP), "pill hell " + map_id)
		_check(monster_ids.has("mon_overheated_core") == map_id.begins_with("classic_13"), "research core maps " + map_id)
		_check(monster_ids.has("mon_loader_black_box") == (map_id == MAP), "blackbox hell " + map_id)
		_check(mechanism_ids.has("eq_old_work_badge") == (map_id in ["classic_13x13_hard", MAP]), "oldbadge difficult13 " + map_id)
	_check(loot.candidates("chest", _frozen(50), "unknown_map").is_empty(), "unknown map fails closed")
	_check(loot.roll("chest", Vector2i.ZERO, 1, _frozen(50), MAP, 0).is_empty(), "zero count does not invent reward")


func _tier_probability(pool: Array, tier: int) -> float:
	var result := 0.0
	for entry: Dictionary in pool:
		var item: Dictionary = loot.definition(entry.item_id)
		if item.item_type == "collectible" and int(item.collectible_level) == tier:
			result += float(entry.probability)
	return result


func _prob(pool: Array, id: String) -> float:
	for entry: Dictionary in pool:
		if entry.item_id == id: return float(entry.probability)
	return 0.0


func _actual_drops_and_restart() -> void:
	var run := _context(50)
	var before := Snapshot.capture_context(run)
	var drops := Content.search_items(Vector2i(2, 2), 3, true, 7, run)
	_check(drops.size() == 2 and drops[0].instance_id != drops[1].instance_id, "actual chest count and identities")
	_check(before == Snapshot.capture_context(run), "drop query has no mutations")
	var restart := Context.new()
	Snapshot.install_context(restart, Snapshot.unpack_checkpoint(Snapshot.pack_checkpoint(before)).state)
	_check(drops == Content.search_items(Vector2i(2, 2), 3, true, 7, restart), "actual drops identical after checkpoint restart")
	run.profile_fields.profile_level = 0
	run.profile_fields.content_eligibility = _frozen(0)
	run.profile_level = 0
	_check(drops == Content.search_items(Vector2i(2, 2), 3, true, 7, run), "reads departure frozen not mutable live profile")
	restart.run_id = "another_run"
	_check(drops[0].instance_id != Content.search_items(Vector2i(2, 2), 3, true, 7, restart)[0].instance_id, "cross-run identities distinct")
	for index in range(80):
		run.seed_value = index
		for item in Content.search_items(Vector2i(2, 2), 3, true, 7, run) + Content.trap_cache(run) + [Content.monster_trophy(Vector2i(2, 2), 3, run), Content.altar_relic(run, 4)]:
			_check(not item.is_empty() and item.get("content_version") == Items.CONTENT_VERSION, "every actual entry Z2 " + str(index))
			_check(str(item.get("required_research_id", "")).is_empty(), "actual drops exclude research")
	var fresh := _context(1)
	var reward := Rules.apply_search_reward(fresh, Vector2i(2, 2), 2, true)
	_check(bool(reward.ok) and not reward.ground_items.is_empty(), "actual RunRuleService creates ledger ground items")
	for item in reward.ground_items:
		_check(item.get("content_version") == Items.CONTENT_VERSION, "ledger did not normalize to old units")
	var invalid := _context(50)
	invalid.run_start_config.profile_fields.erase("content_eligibility")
	_check(Content.search_items(Vector2i.ZERO, 0, true, 0, invalid).is_empty(), "missing Z2 freeze never enters legacy path")
	_check(Content.monster_trophy(Vector2i.ZERO, 0, invalid).is_empty(), "missing freeze blocks trophy")


func _economy_and_process_contracts() -> void:
	var run := _context(50)
	run.asset_ledger.add_currency(&"black_coin", 100)
	var catalog: Dictionary = loot.economy_catalog(run)
	_check(catalog.shop_pool == loot.candidates("shop", _frozen(50), MAP), "T10 actual weighted pool")
	var prepared := Economy.choose(run, Vector2i(2, 2), "shop", "prepare", {}, catalog)
	_check(bool(prepared.ok), "actual T10 shop prepares from loot catalog")
	var state := Economy.public_state(run, Vector2i(2, 2), "shop", catalog)
	var bought := Economy.choose(run, Vector2i(2, 2), "shop", "buy", {"slot": 0, "quote_id": state.quote_id}, catalog)
	_check(bool(bought.ok), "actual T10 weighted offer buys")
	var empty := _context(0)
	empty.asset_ledger.add_currency(&"black_coin", 100)
	var hp_before := empty.hp
	var denied := Economy.choose(empty, Vector2i(2, 2), "shop", "prepare", {}, loot.economy_catalog(empty))
	_check(not bool(denied.ok) and empty.asset_ledger.get_currency(&"black_coin") == 100, "mandatory empty shop rejects without payment")
	_check(empty.hp == hp_before, "mandatory empty no HP payment")
	var process: Dictionary = loot.process_rules(run, 4)
	for pair in [["normal_search", "search"], ["mechanism", "mechanism_success"], ["electric", "mechanism_success"], ["recycle", "recycle"], ["altar", "altar"]]:
		var pool: Dictionary = process.pools[pair[0]]
		_check(pool.channel == pair[1] and not pool.items.is_empty(), "T12 explicit channel " + str(pair[0]))
		for entry: Dictionary in pool.items:
			_check(process.definitions.has(entry.item_id), "T12 definition adapter resolves " + str(entry.item_id))
	_check(process.material_tags.sp_reset_spring.has("reset") and process.material_tags.sp_depressurized_valve_core.has("flow_control"), "source anchored natural use tags")
	_check(not process.material_tags.has("col_20"), "same-name collectible is not a material")
	for id in ["sp_reset_spring", "mon_old_gear_set", "mon_loader_black_box"]:
		_check(process.definitions.has(id), "T12 can resolve carried material absent from current reward pool " + id)


func _search_empty_gate() -> void:
	var low_empty := 0
	var high_empty := 0
	var empty_with_zero_black := false
	var empty_with_black := false
	for seed_value in range(100):
		# Source's integer ticket traverses all 100 residues exactly; not a stochastic frequency test.
		if not bool(loot.search_has_item(Vector2i.ZERO, seed_value, 0)): low_empty += 1
		if not bool(loot.search_has_item(Vector2i.ZERO, seed_value, 3)): high_empty += 1
		var run := _context(1)
		run.seed_value = seed_value
		var empty := Content.search_items(Vector2i.ZERO, 0, false, 0, run).is_empty()
		if empty:
			empty_with_zero_black = true
			empty_with_black = empty_with_black or Content.search_items(Vector2i.ZERO, 0, false, 3, run).is_empty()
	_check(low_empty == 35 and high_empty == 25, "source 35/25 empty gate exact integer enumeration")
	_check(empty_with_zero_black and empty_with_black, "ordinary search permits empty and black-only results")
	_check(not loot.candidates("search", _frozen(1), MAP).is_empty(), "coil uses conditional item pool without empty tickets")


func _legacy_path() -> void:
	var legacy := _context(1)
	legacy.run_start_config.profile_fields = {}
	legacy.profile_fields = {}
	legacy.enemy_state = {"monster_type": "z1_monster_m03"}
	_check(Content.monster_trophy(Vector2i.ZERO, 3, legacy).item_id == "sp_inspection_calibration_plate", "legacy m03 behavior retained")
	var old := Legacy.roll(&"chest", Vector2i(1, 1), legacy.seed_value + 7, &"hell", 1, 1, 0)
	var current := Content.search_items(Vector2i(1, 1), 0, true, 7, legacy)
	_check(current[0].item_id == old[0].item_id and current[0].weight == old[0].weight, "legacy seed and units unchanged")
	_check(not Content.search_items(Vector2i.ZERO, 0, true, 3).is_empty(), "null-context M3 remains available")


func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
