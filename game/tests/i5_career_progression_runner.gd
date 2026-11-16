extends SceneTree

const Catalog := preload("res://scripts/core/content/m7_content_catalog.gd")
const MetaAdapter := preload("res://scripts/core/save/meta_progress_adapter.gd")
const ResultController := preload("res://scripts/core/run/run_scene_result_controller.gd")
const ResultModel := preload("res://scripts/ui/result/result_presentation_model.gd")

class FailingSaveAdapter extends SaveAdapter:
	var fail_next_save := true

	func save_json(source_data: Dictionary, path: String = M1_META_PROGRESS_PATH, normalize_meta_progress: bool = true) -> bool:
		if fail_next_save:
			fail_next_save = false
			last_error = "forced_career_save_failure"
			return false
		return super.save_json(source_data, path, normalize_meta_progress)

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_curve()
	_test_exploration_experience()
	_test_new_career()
	_test_research_then_level()
	_test_final_map_unlock()
	_test_settlement_retry()
	_test_legacy_save()
	_test_player_flow_feedback()
	if failures.is_empty():
		print("I5_CAREER_PROGRESSION=PASS curve=1-30 experience=exploration,difficulty,finalized gates=level,clear,research legacy=maps,talents")
		quit(0)
	else:
		for failure in failures:
			print("I5_CAREER_PROGRESSION_CASE_FAIL " + failure)
		print("I5_CAREER_PROGRESSION=FAIL failures=%d" % failures.size())
		quit(1)


func _test_curve() -> void:
	for pair in [[0, 1], [29, 1], [30, 2], [70, 3], [180, 5], [419, 7], [420, 8],
			[630, 10], [3765, 25], [5314, 29], [5315, 30], [12600, 30], [50000, 30]]:
		_check(Catalog.profile_level_for_exp(pair[0]) == pair[1], "level_at_%d" % pair[0])
	_check(Catalog.profile_exp_for_level(30) == 5315 and Catalog.profile_exp_for_level(31) == -1, "demo_cap_threshold")


func _test_exploration_experience() -> void:
	var adapter := _profile("scoring")
	var shallow := adapter.apply_settlement(_result("shallow", "classic_10x10_standard", "success", 8, 1))
	_check(_exp(shallow) == 13, "shallow_extraction")
	for pair in [["classic_10x10_easy", 60], ["classic_10x10_standard", 67], ["classic_10x10_hard", 73]]:
		var deep := adapter.apply_settlement(_result(pair[0], pair[0], "success", 24, 2, 2, 2, true))
		_check(_exp(deep) == pair[1], "difficulty_%s" % pair[0])
	var production := _result("production_shape", "classic_10x10_standard", "success", 24, 2, 2, 2)
	production["run_start_config"]["selected_objective_id"] = "commission_open_crates"
	production["RunResult"] = {
		"unique_rooms_explored": production["unique_rooms_explored"],
		"run_stats": production["run_stats"],
	}
	production.erase("unique_rooms_explored")
	production.erase("run_stats")
	var production_commit := adapter.apply_settlement(production)
	_check(_exp(production_commit) == 67, "production_nested_experience")
	_check(bool(production_commit.get("m7_progression_delta", {}).get("commission_completed", false)), "production_nested_commission")
	var capped := adapter.apply_settlement(_result("capped", "classic_13x13_hell", "success", 60, 9, 9, 9, true))
	_check(_exp(capped) == 100, "capped_extraction")
	var pending := _result("salvage", "classic_10x10_standard", "failure", 24, 2, 2, 2)
	pending["settlement"]["requires_salvage_selection"] = true
	pending["settlement"]["finalized"] = false
	var before := int(adapter.get_summary().get("profile_exp", -1))
	_check(str(adapter.apply_settlement(pending).get("status", "")) == "awaiting_salvage_selection", "pending_not_committed")
	_check(int(adapter.get_summary().get("profile_exp", -1)) == before, "pending_no_experience")
	pending["settlement"]["finalized"] = true
	pending["settlement"]["requires_salvage_selection"] = false
	_check(_exp(adapter.apply_settlement(pending)) == 34, "confirmed_failure_experience")
	_check(str(adapter.apply_settlement(pending).get("status", "")) == "duplicate_ignored", "settlement_duplicate")
	_check(int(adapter.get_summary().get("profile_exp", -1)) == before + 34, "experience_granted_once")
	_check(_exp(adapter.apply_settlement(_result("abandon", "classic_10x10_standard", "abandon", 24, 2, 2, 2))) == 0, "abandon_no_experience")


func _test_new_career() -> void:
	var adapter := _profile("fresh")
	_check(_maps(adapter) == ["tutorial_5x5", "classic_7x7_simple"], "fresh_only_first_map")
	var first := _result("first", "classic_7x7_simple", "success", 10, 1, 1, 1, true)
	_check(_exp(adapter.apply_settlement(first)) == 32, "first_realistic_experience")
	_check(int(adapter.get_summary().get("profile_level", 0)) == 2, "first_level_up")
	_check(int(adapter.get_summary().get("talent_points", 0)) == 1, "first_talent_point")
	_check(not _maps(adapter).has("classic_7x7_normal"), "clear_before_level_waits")
	var second := _result("second", "classic_7x7_simple", "success", 18, 2, 2, 2, true)
	_check(_exp(adapter.apply_settlement(second)) == 45, "first_map_cap")
	_check(_maps(adapter).has("classic_7x7_normal"), "first_gate_opens")
	_check(not _maps(adapter).has("classic_10x10_easy"), "first_gate_only")
	adapter.load_or_create_default()
	_check(_maps(adapter) == ["tutorial_5x5", "classic_7x7_simple", "classic_7x7_normal"], "new_save_stays_new")
	_check(bool(adapter.unlock_talent("talent_carry_rigging").get("ok", false)), "spend_first_talent")
	_check(int(adapter.get_summary().get("talent_points", -1)) == 0, "spent_talent_point")
	adapter.apply_settlement(_result("third", "classic_7x7_normal", "success", 23, 2, 2, 2, true))
	_check(int(adapter.get_summary().get("talent_points", -1)) == 1, "second_point_at_level_four")
	adapter.apply_settlement(_result("fourth", "classic_7x7_normal", "success", 23, 2, 2, 2, true))
	_check(_maps(adapter).has("classic_10x10_easy") and not _maps(adapter).has("classic_10x10_standard"), "second_gate_only")


func _test_research_then_level() -> void:
	var adapter := _profile("research")
	adapter.data["profile_exp"] = 2655
	adapter.data["gold"] = 100
	adapter.data["map_success_counts"]["classic_13x13_normal"] = 1
	adapter.data["research_completed_ids"] = ["research_anomaly_structure", "research_protocol_formula"]
	var material := Catalog.item_definition("mon_loader_black_box")
	material["instance_id"] = "career_research_black_box"
	adapter.data["warehouse_items"].append(material)
	adapter.data["task_states"]["task_first_survey"]["status"] = "claimable"
	_check(adapter.save(), "seed_research_profile")
	adapter.load_or_create_default()
	_check(bool(adapter.complete_research("research_extraction_signal").get("ok", false)), "research_completes")
	_check(not _maps(adapter).has("classic_13x13_hard"), "research_before_level_waits")
	var claim := adapter.claim_goal_reward("task", "task_first_survey")
	_check(bool(claim.get("ok", false)), "claim_level_experience")
	_check("classic_13x13_hard" in claim.get("new_unlock_ids", []), "claim_reports_new_map")
	_check(_maps(adapter).has("classic_13x13_hard"), "claim_crossing_level_unlocks_researched_map")
	_check(not _maps(adapter).has("classic_13x13_hell"), "next_map_requires_clear")


func _test_final_map_unlock() -> void:
	var adapter := _profile("final_map")
	adapter.data["profile_exp"] = Catalog.profile_exp_for_level(26)
	adapter.data["unlocked_map_ids"].append("classic_13x13_hard")
	_check(adapter.save(), "seed_final_map_profile")
	adapter.load_or_create_default()
	for outcome in ["failure", "abandon"]:
		adapter.apply_settlement(_result("hard_%s" % outcome, "classic_13x13_hard", outcome, 20, 2))
	_check(not adapter.data["map_success_counts"].has("classic_13x13_hard"), "unsuccessful_runs_do_not_clear_map")
	adapter.apply_settlement(_result("hard_clear", "classic_13x13_hard", "success", 20, 2))
	_check(not _maps(adapter).has("classic_13x13_hell"), "hard_clear_waits_for_critical_return")
	var critical := _result("critical_return", "classic_7x7_simple", "success", 10, 1)
	critical["protocol_level"] = 1
	var commit := adapter.apply_settlement(critical)
	_check(_maps(adapter).has("classic_13x13_hell"), "critical_return_unlocks_earlier_clear")
	_check("classic_13x13_hell" in commit["m7_progression_delta"]["new_unlock_ids"], "last_unlock_reported")


func _test_settlement_retry() -> void:
	var adapter := _profile("retry")
	adapter.data["profile_exp"] = 25
	_check(adapter.save(), "seed_retry_profile")
	adapter.load_or_create_default()
	var before := adapter.data.duplicate(true)
	adapter.save_adapter = FailingSaveAdapter.new()
	var result := _result("retry", "classic_7x7_simple", "success", 24, 2, 2, 2, true)
	_check(str(adapter.apply_settlement(result).get("status", "")) == "save_failed", "retry_first_write_fails")
	_check(adapter.data == before, "retry_rolls_back_experience_points_and_clear")
	_check(_exp(adapter.apply_settlement(result)) == 45, "retry_commits_once")
	_check(_maps(adapter).has("classic_7x7_normal"), "retry_opens_map")
	_check(int(adapter.get_summary().get("talent_points", -1)) == 1, "retry_grants_point")
	_check(str(adapter.apply_settlement(result).get("status", "")) == "duplicate_ignored", "retry_replay_ignored")
	_check(int(adapter.get_summary().get("profile_exp", -1)) == 70, "retry_experience_stays_committed")


func _test_legacy_save() -> void:
	var adapter := _profile("legacy")
	var legacy := adapter.save_adapter.default_meta_progress()
	legacy.erase("career_progression_version")
	legacy["profile_exp"] = 700
	legacy["profile_level"] = 5
	legacy["unlocked_map_ids"] = ["classic_13x13_normal"]
	legacy["talent_flags"] = ["talent_carry_rigging", "talent_salvage_clause"]
	legacy["talent_points"] = 2
	legacy["talent_budget_granted"] = 4
	_check(adapter.save_adapter.save_json(legacy, adapter.active_meta_progress_path, false), "write_i5_fixture")
	adapter.load_or_create_default()
	var summary := adapter.get_summary()
	_check(int(summary.get("profile_level", 0)) == 10 and int(summary.get("profile_exp", 0)) == 700, "legacy_experience_recomputed")
	for map_id in ["tutorial_5x5", "classic_7x7_simple", "classic_7x7_normal", "classic_10x10_easy", "classic_10x10_standard", "classic_13x13_normal"]:
		_check(_maps(adapter).has(map_id), "legacy_retains_%s" % map_id)
	_check(int(summary.get("talent_points", -1)) == 2 and summary.get("talent_flags", []) == legacy["talent_flags"], "legacy_retains_spent_and_available")
	_check(adapter.save(), "persist_migration")
	adapter.load_or_create_default()
	_check(int(adapter.get_summary().get("talent_points", -1)) == 2, "legacy_migration_idempotent")

	var no_budget := _profile("legacy_no_budget")
	legacy.erase("talent_budget_granted")
	legacy.erase("unlocked_map_ids")
	legacy["profile_exp"] = 420
	legacy["profile_level"] = 3
	legacy["talent_flags"] = ["talent_carry_rigging"]
	legacy["talent_points"] = 1
	_check(no_budget.save_adapter.save_json(legacy, no_budget.active_meta_progress_path, false), "write_legacy_without_budget")
	no_budget.load_or_create_default()
	_check(int(no_budget.get_summary().get("talent_points", -1)) == 2, "legacy_missing_budget_only_grants_difference")
	_check(_maps(no_budget).has("classic_10x10_standard"), "legacy_implicit_map_grant")


func _test_player_flow_feedback() -> void:
	var adapter := _profile("player_flow")
	var first := _result("player_flow_first", "classic_7x7_simple", "success", 10, 1)
	var commit := adapter.apply_settlement(first)
	var display := ResultController.build_result_display_snapshot(first, adapter.get_summary(), commit)
	var model := ResultModel.build(display)
	var follow_up: Dictionary = model.get("career_follow_up", {})
	_check(follow_up.get("card_id") == "achievement_first_return", "result_directly_targets_first_return")
	var copy := str(model.get("persistence_text", ""))
	_check(copy.contains("+14") and copy.contains("距 Lv.2 16"), "result_shows_next_level")
	_check(copy.contains("下一档 7×7 普通"), "result_shows_next_map")
	var tooltip := str(model.get("progression_tooltip", ""))
	_check(tooltip.contains("房间 +10") and tooltip.contains("开箱 +4") and tooltip.contains("100%"), "result_explains_exploration_score")
	_check(int(adapter.get_summary().get("profile_exp", -1)) == 14, "viewing_result_does_not_claim_reward")

	var failed := commit.duplicate(true)
	failed["status"] = "save_failed"
	var unsaved := ResultModel.build(ResultController.build_result_display_snapshot(first, adapter.get_summary(), failed))
	_check(unsaved.get("career_follow_up", {}).is_empty() and str(unsaved.get("progression_tooltip", "")).is_empty(), "unsaved_result_hides_career_changes")
	var pending := _result("player_flow_pending", "classic_7x7_simple", "failure", 10, 1)
	pending["settlement"]["requires_salvage_selection"] = true
	pending["settlement"]["finalized"] = false
	var before_confirmation := ResultModel.build(ResultController.build_result_display_snapshot(pending, adapter.get_summary(), commit))
	_check(before_confirmation.get("career_follow_up", {}).is_empty(), "pending_salvage_hides_career_actions")

	_check(bool(adapter.claim_goal_reward("achievement", "achievement_first_return").get("ok", false)), "claim_first_return_manually")
	_check(int(adapter.get_summary().get("profile_exp", -1)) == 44 and int(adapter.get_summary().get("talent_points", -1)) == 1, "first_return_brings_short_route_to_first_point")
	var second := _result("player_flow_second", "classic_7x7_simple", "success", 33, 5)
	var second_commit := adapter.apply_settlement(second)
	var second_model := ResultModel.build(ResultController.build_result_display_snapshot(second, adapter.get_summary(), second_commit))
	_check(str(second_model.get("persistence_text", "")).contains("新开放 7×7 普通"), "result_reports_new_map")
	var third := _result("player_flow_third", "classic_7x7_normal", "success", 33, 5)
	var third_commit := adapter.apply_settlement(third)
	var third_model := ResultModel.build(ResultController.build_result_display_snapshot(third, adapter.get_summary(), third_commit))
	_check(third_model.get("career_follow_up", {}).get("module_id") == &"talent", "result_targets_new_talent_point")


func _profile(name: String) -> MetaProgressAdapter:
	var adapter := MetaAdapter.new()
	adapter.set_active_profile_path("user://tests/i5_career_%s.json" % name, "i5_career_%s" % name)
	adapter.clear()
	adapter.apply_settlement({"result_id": "tutorial_%s" % name, "mode": "tutorial", "outcome": "Training Complete"})
	return adapter


func _maps(adapter: MetaProgressAdapter) -> Array:
	return adapter.get_summary().get("unlocked_map_ids", [])


func _exp(commit: Dictionary) -> int:
	return int((commit.get("m7_progression_delta", {}) as Dictionary).get("exp_gained", -1))


func _result(id: String, map_id: String, outcome: String, rooms: int, chests: int,
		combat: int = 0, events: int = 0, commission: bool = false) -> Dictionary:
	var recovered: Array[Dictionary] = []
	if commission:
		for index in range(2):
			var item := Catalog.item_definition("col_01")
			item["instance_id"] = "%s:item:%d" % [id, index]
			recovered.append(item)
	var labels := {"success": "Extracted", "failure": "Failed", "abandon": "Abandoned"}
	return {
		"result_id": id,
		"mode": "standard",
		"outcome": labels[outcome],
		"run_start_config": {"map_config_id": map_id, "selected_objective_id": "commission_recover_supply"},
		"unique_rooms_explored": rooms + 1,
		"run_stats": {"chest_rooms": chests, "monsters_defeated": combat, "events_completed": events},
		"settlement": {"outcome": outcome, "finalized": true, "warehouse_lite": recovered},
	}


func _check(condition: bool, label: String) -> void:
	if not condition:
		failures.append(label)
