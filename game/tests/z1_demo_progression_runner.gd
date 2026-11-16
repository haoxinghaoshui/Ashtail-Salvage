extends SceneTree

const Catalog = preload("res://scripts/core/content/m7_content_catalog.gd")
const MetaAdapter = preload("res://scripts/core/save/meta_progress_adapter.gd")
const Progression = preload("res://scripts/core/progression/m7_progression_service.gd")
const Talents = preload("res://scripts/core/progression/m7_talent_catalog.gd")
const Rules = preload("res://scripts/core/run/run_rule_service.gd")
var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_cap()
	_test_tutorial_and_gates()
	_test_legacy()
	_test_abandoned_deliveries()
	_test_loot()
	if failures.is_empty():
		print("Z1_DEMO_PROGRESSION=PASS cap=30 gates=tutorial,level,clear,research loot=weighted,deterministic legacy=maps,points")
		quit(0)
	else:
		for failure in failures:
			print("Z1_DEMO_CASE_FAIL " + failure)
		print("Z1_DEMO_PROGRESSION=FAIL failures=%d" % failures.size())
		quit(1)


func _test_cap() -> void:
	_check(Catalog.PROFILE_EXP_THRESHOLDS.size() == 30, "demo_has_30_thresholds")
	for pair in [[0, 1], [29, 1], [30, 2], [180, 5], [1375, 15], [5314, 29], [5315, 30], [12600, 30], [50000, 30]]:
		_check(Catalog.profile_level_for_exp(pair[0]) == pair[1], "level_%d" % pair[0])
	_check(Catalog.profile_exp_for_level(31) == -1, "no_level_31_target")
	_check(Talents.definitions().size() == 6, "six_existing_talents")
	_check(Talents.point_budget_for_level(30) == 4, "four_points_at_cap")
	_check(str(Catalog.research_definition("research_extraction_signal").get("effect", "")).contains("13×13 困难"), "research_text_matches_hard_gate")


func _test_tutorial_and_gates() -> void:
	var adapter = _profile("tutorial")
	_check(_maps(adapter) == ["tutorial_5x5"], "new_profile_tutorial_only")
	var tutorial := {"result_id": "z1_tutorial", "mode": "tutorial", "outcome": "Training Complete", "run_start_config": {"map_config_id": "tutorial_5x5"}}
	_check(bool(adapter.apply_settlement(tutorial).get("ok", false)), "tutorial_commits")
	_check(_maps(adapter) == ["tutorial_5x5", "classic_7x7_simple"], "tutorial_opens_7_simple")
	_check(int(adapter.get_summary().get("profile_exp", -1)) == 0, "tutorial_zero_xp")
	_check(int(adapter.get_summary().get("talent_points", -1)) == 0, "tutorial_zero_points")
	adapter.load_or_create_default()
	_check(_maps(adapter) == ["tutorial_5x5", "classic_7x7_simple"], "tutorial_unlock_durable")
	var cases := [
		[3, "classic_7x7_normal", "classic_7x7_simple", ""],
		[5, "classic_10x10_easy", "", ""],
		[8, "classic_10x10_standard", "classic_10x10_easy", ""],
		[12, "classic_10x10_hard", "classic_10x10_standard", ""],
		[15, "classic_13x13_normal", "", ""],
		[21, "classic_13x13_hard", "classic_13x13_normal", "research_extraction_signal"],
		[26, "classic_13x13_hell", "classic_13x13_hard", ""],
	]
	for gate in cases:
		var data: Dictionary = adapter.save_adapter.default_meta_progress()
		data["tutorial_completed"] = true
		data["profile_exp"] = Catalog.profile_exp_for_level(gate[0]) - 1
		data["profile_level"] = int(gate[0]) - 1
		if gate[2] != "":
			data["map_success_counts"][gate[2]] = 1
		if gate[3] != "":
			data["research_completed_ids"] = [gate[3]]
		data["achievement_states"]["achievement_critical_return"]["achieved"] = true
		var below: Dictionary = Progression.normalize_meta(data)
		_check(not below["unlocked_map_ids"].has(gate[1]), "below_gate_%s" % gate[1])
		data["profile_exp"] += 1
		var at: Dictionary = Progression.normalize_meta(data)
		_check(at["unlocked_map_ids"].has(gate[1]), "at_gate_%s" % gate[1])
		if gate[2] != "":
			data["map_success_counts"] = {}
			_check(not Progression.normalize_meta(data)["unlocked_map_ids"].has(gate[1]), "clear_required_%s" % gate[1])
	var research: Dictionary = adapter.save_adapter.default_meta_progress()
	research["tutorial_completed"] = true
	research["profile_exp"] = 2665
	research["map_success_counts"] = {"classic_13x13_normal": 1}
	_check(not Progression.normalize_meta(research)["unlocked_map_ids"].has("classic_13x13_hard"), "hard_requires_research")
	research["research_completed_ids"] = ["research_extraction_signal"]
	_check(Progression.normalize_meta(research)["unlocked_map_ids"].has("classic_13x13_hard"), "research_after_level_opens_hard")


func _test_legacy() -> void:
	for version in [0, 1]:
		var adapter = _profile("legacy_%d" % version)
		var old: Dictionary = adapter.save_adapter.default_meta_progress()
		old["career_progression_version"] = version
		old["profile_exp"] = 50000
		old["profile_level"] = 50
		old["unlocked_map_ids"] = ["classic_13x13_hell"]
		old["talent_flags"] = ["talent_carry_rigging", "talent_salvage_clause"]
		old["talent_points"] = 2
		old["talent_budget_granted"] = 4
		_check(adapter.save_adapter.save_json(old, adapter.active_meta_progress_path, false), "write_legacy_%d" % version)
		for reload_index in range(2):
			adapter.load_or_create_default()
			var summary: Dictionary = adapter.get_summary()
			_check(int(summary["profile_level"]) == 30, "legacy_cap_%d_%d" % [version, reload_index])
			_check(int(summary["profile_exp"]) == 50000, "legacy_raw_xp_%d_%d" % [version, reload_index])
			_check(_maps(adapter).has("classic_13x13_hell"), "legacy_hell_retained_%d" % version)
			_check(int(summary["talent_points"]) == 2 and summary["talent_flags"] == old["talent_flags"], "legacy_points_%d" % version)
			adapter.save()
	var current: Dictionary = SaveAdapter.new().default_meta_progress()
	current["career_progression_version"] = 1
	current["profile_exp"] = 30
	current["unlocked_map_ids"] = ["tutorial_5x5", "classic_7x7_simple"]
	_check(not Progression.normalize_meta(current)["unlocked_map_ids"].has("classic_10x10_standard"), "v1_does_not_get_original_default_maps")
	current.erase("unlocked_map_ids")
	_check(Progression.normalize_meta(current)["unlocked_map_ids"].has("classic_7x7_simple"), "v1_missing_maps_retains_first_map")


func _test_abandoned_deliveries() -> void:
	var adapter = _profile("abandoned_deliveries")
	adapter.data["collection_discoveries"] = ["col_02", "col_03", "col_04", "col_05", "col_06", "col_07", "col_08"]
	var delivered: Dictionary = Catalog.item_definition("col_01")
	delivered["instance_id"] = "z1_consigned_col_01"
	var lost: Dictionary = Catalog.item_definition("col_09")
	lost["instance_id"] = "z1_lost_col_09"
	var snapshot := {
		"result_id": "z1_abandoned_delivery",
		"outcome": "Abandoned",
		"run_start_config": {"map_config_id": "classic_7x7_simple"},
		"run_stats": {"unique_rooms_explored": 30, "chests_opened": 5},
		"settlement": {
			"outcome": "abandon",
			"finalized": true,
			"event_item_delivery": {"delivered": [delivered], "forfeited": [lost]},
			"warehouse_lite": [delivered, lost],
		},
	}
	var commit: Dictionary = adapter.apply_settlement(snapshot)
	_check(bool(commit.get("ok", false)), "abandoned_delivery_commits")
	var summary: Dictionary = adapter.get_summary()
	_check(summary.get("codex_discoveries", []).has("item:col_01"), "abandoned_delivery_codex_recorded")
	_check(summary.get("collection_discoveries", []).has("col_01"), "abandoned_delivery_collection_recorded")
	_check(summary.get("completed_collection_set_ids", []).has("collection_old_work"), "abandoned_delivery_completes_collection")
	_check(not summary.get("collection_discoveries", []).has("col_09"), "abandoned_undelivered_item_excluded")
	_check(int(summary.get("profile_exp", -1)) == 0 and int(summary.get("talent_points", -1)) == 0, "abandoned_delivery_has_zero_xp_and_points")
	_check(str(adapter.apply_settlement(snapshot).get("status", "")) == "duplicate_ignored", "abandoned_delivery_retry_ignored")
	adapter.load_or_create_default()
	var reloaded: Dictionary = adapter.get_summary()
	_check(reloaded.get("collection_discoveries", []) == summary.get("collection_discoveries", []), "abandoned_delivery_collection_durable")
	_check(reloaded.get("completed_collection_set_ids", []) == summary.get("completed_collection_set_ids", []), "abandoned_delivery_set_durable")
	_check(int(reloaded.get("talent_points", -1)) == 0, "abandoned_delivery_reload_keeps_points")


func _test_loot() -> void:
	var path := "res://scripts/core/content/z1_loot_catalog.gd"
	if not FileAccess.file_exists(path):
		_check(false, "weighted_loot_catalog_exists")
		return
	var loot = load(path)
	var content = load("res://scripts/core/run/run_content_catalog.gd")
	var checks := [[&"chest", 1, 4, 0.35, 0.455], [&"event", 1, 5, 0.28, 0.385], [&"altar", 3, 5, 0.45, 0.6], [&"altar", 4, 6, 0.3, 0.45]]
	for entry in checks:
		for i in range(2):
			var difficulty: StringName = &"hard" if i == 0 else &"hell"
			var dist: Array = loot.distribution(entry[0], difficulty, entry[1])
			var sum := 0.0
			var high := 0.0
			for row in dist:
				sum += float(row["probability"])
				var item: Dictionary = Catalog.item_definition(row["item_id"])
				_check(not bool(item.get("is_unique", false)), "unique_excluded")
				if int(item.get("collectible_level", 0)) == int(entry[2]):
					high += float(row["probability"])
			_check(is_equal_approx(sum, 1.0), "probability_sum_%s_%s" % [entry[0], difficulty])
			_check(is_equal_approx(high, float(entry[3 + i])), "high_tier_%s_%s" % [entry[0], difficulty])
	var context := RunContext.new()
	context.seed_value = 81273
	context.run_start_config = {"map_config_id": "classic_13x13_hell"}
	var repeated: Array = content.search_items(Vector2i(3, 2), 0, true, 7, context)
	_check(repeated == content.search_items(Vector2i(3, 2), 0, true, 7, context), "stable_seeded_drop")
	var high_count := 0
	for sample in range(4000):
		context.seed_value = sample + 101
		var items: Array = content.search_items(Vector2i(3, 2), 0, true, 7, context)
		_check(items.size() == 1, "chest_count_preserved")
		if int(items[0].get("collectible_level", 0)) == 4:
			high_count += 1
	_check(absf(float(high_count) / 4000.0 - 0.455) < 0.025, "production_weighted_frequency")
	for sample in range(32):
		context.seed_value = sample + 900
		context.run_id = StringName("z1_rule_%d" % sample)
		context.asset_ledger = RunAssetLedger.new()
		var result: Dictionary = Rules.apply_search_reward(context, Vector2i(3, 2), 0, true)
		var expected: Array = content.search_items(Vector2i(3, 2), 0, true, int(result.get("black_coin_delta", 0)), context)
		var actual: Array = result.get("ground_items", [])
		_check(actual.size() == expected.size() and not actual.is_empty(), "production_reward_count")
		if not actual.is_empty():
			_check(actual[0]["item_id"] == expected[0]["item_id"], "production_reward_uses_weights")
	context.asset_ledger = null
	context.run_id = &"z1_first_run"
	var first_run: Array = content.search_items(Vector2i(3, 2), 0, true, 7, context)
	context.run_id = &"z1_second_run"
	var second_run: Array = content.search_items(Vector2i(3, 2), 0, true, 7, context)
	_check(first_run[0].get("instance_id", "") != second_run[0].get("instance_id", ""), "independent_instances_across_runs")


func _profile(id: String):
	var adapter = MetaAdapter.new()
	adapter.set_active_profile_path("user://tests/z1_%s.json" % id, "z1_%s" % id)
	adapter.clear()
	return adapter


func _maps(adapter) -> Array:
	return adapter.get_summary().get("unlocked_map_ids", [])


func _check(condition: bool, message: String) -> void:
	if not condition and not failures.has(message):
		failures.append(message)
