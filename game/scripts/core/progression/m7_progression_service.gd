extends RefCounted
class_name M7ProgressionService

const M7ContentCatalogScript := preload("res://scripts/core/content/m7_content_catalog.gd")
const M7TalentCatalogScript := preload("res://scripts/core/progression/m7_talent_catalog.gd")
const PlayerAppearanceConfigScript := preload("res://scripts/core/content/player_appearance_config.gd")
const CAREER_PROGRESSION_VERSION := 2
const Z2Rules := preload("res://scripts/core/progression/z2_progression_rules.gd")
const Z2QuestCatalogScript := preload("res://scripts/core/progression/z2_quest_catalog.gd")
const Z2QuestProgressionScript := preload("res://scripts/core/progression/z2_goals/goal_progression.gd")
const Z2QuestFactsScript := preload("res://scripts/core/progression/z2_quest_facts.gd")


static func default_meta_fields() -> Dictionary:
	return {
		"career_progression_version": CAREER_PROGRESSION_VERSION,
		"unlocked_map_ids": M7ContentCatalogScript.DEFAULT_UNLOCKED_MAPS.duplicate(),
		"tutorial_completed": false,
		"map_success_counts": {},
		"commission_history": [],
		"task_states": _default_task_states(),
		"achievement_states": _default_achievement_states(),
		"research_completed_ids": [],
		"codex_discoveries": M7ContentCatalogScript.initial_codex_discoveries(),
		"unread_codex_ids": M7ContentCatalogScript.initial_codex_discoveries(),
		"collection_discoveries": [],
		"completed_collection_set_ids": [],
		"unread_collection_set_ids": [],
		"unread_history_ids": [],
		"event_completion_counts": {"trader": 0, "dice": 0, "altar": 0, "trap": 0},
		"purchased_instance_ids": [],
		"claimed_reward_ids": [],
		"granted_reward_ids": [],
		"titles": ["新进回收员"],
		"badges": [],
		"transaction_sequence": 0,
		"red_dot_state": {},
		"player_appearance": PlayerAppearanceConfigScript.default_config(),
	}


static func normalize_meta(data: Dictionary) -> Dictionary:
	if Z2Rules.applies_to(data):
		var current := data.duplicate(true)
		sync_z2_quests(current)
		M7TalentCatalogScript.sync_progress(current)
		refresh_map_unlocks(current)
		_refresh_red_dots(current)
		return current
	var result := data.duplicate(true)
	var defaults := default_meta_fields()
	for key in defaults.keys():
		if not result.has(key):
			result[key] = defaults[key].duplicate(true) if defaults[key] is Array or defaults[key] is Dictionary else defaults[key]
	var progression_version := int(data.get("career_progression_version", 0))
	var starter_maps := M7ContentCatalogScript.DEFAULT_UNLOCKED_MAPS
	if progression_version < 1:
		starter_maps = M7ContentCatalogScript.LEGACY_I5_DEFAULT_UNLOCKED_MAPS
	elif progression_version == 1:
		starter_maps = ["tutorial_5x5", "classic_7x7_simple"]
	result["unlocked_map_ids"] = _unique_strings(_array(result.get("unlocked_map_ids", [])), starter_maps)
	result["career_progression_version"] = maxi(progression_version, CAREER_PROGRESSION_VERSION)
	result["tutorial_completed"] = bool(result.get("tutorial_completed", false))
	result["map_success_counts"] = _dictionary(result.get("map_success_counts", {}))
	result["commission_history"] = _array(result.get("commission_history", []))
	result["task_states"] = _normalize_goal_states(_dictionary(result.get("task_states", {})), M7ContentCatalogScript.task_definitions(data), true)
	for definition in M7ContentCatalogScript.optional_task_definitions(data):
		var id := str(definition.get("id", ""))
		if not (result["task_states"] as Dictionary).has(id):
			(result["task_states"] as Dictionary)[id] = _goal_state("active")
	result["achievement_states"] = _normalize_goal_states(_dictionary(result.get("achievement_states", {})), M7ContentCatalogScript.achievement_definitions(data), false)
	for key in ["research_completed_ids", "codex_discoveries", "unread_codex_ids", "collection_discoveries", "completed_collection_set_ids", "unread_collection_set_ids", "unread_history_ids", "purchased_instance_ids", "claimed_reward_ids", "granted_reward_ids", "titles", "badges"]:
		result[key] = _unique_strings(_array(result.get(key, [])))
	result["event_completion_counts"] = _dictionary(result.get("event_completion_counts", {}))
	result["player_appearance"] = PlayerAppearanceConfigScript.normalize(result.get("player_appearance", {}))
	for event_id in ["trader", "dice", "altar", "trap"]:
		(result["event_completion_counts"] as Dictionary)[event_id] = maxi(0, int((result["event_completion_counts"] as Dictionary).get(event_id, 0)))
	result["transaction_sequence"] = maxi(0, int(result.get("transaction_sequence", 0)))
	result["profile_exp"] = maxi(0, int(result.get("profile_exp", 0)))
	_refresh_profile_awards(result)
	M7TalentCatalogScript.sync_progress(result)
	refresh_map_unlocks(result)
	_refresh_red_dots(result)
	return result


static func apply_settlement(data: Dictionary, result_snapshot: Dictionary) -> Dictionary:
	if Z2Rules.applies_to(data):
		return _apply_z2_growth(data, result_snapshot)
	var run_result := _dictionary(result_snapshot.get("RunResult", result_snapshot.get("run_result", {})))
	if not run_result.is_empty():
		result_snapshot = result_snapshot.duplicate()
		for key in ["run_start_config", "run_stats", "run_events", "unique_rooms_explored"]:
			if run_result.has(key):
				result_snapshot[key] = run_result[key]
	var run_start := _dictionary(result_snapshot.get("run_start_config", {}))
	if str(result_snapshot.get("mode", "")) == "tutorial" or str(run_start.get("map_config_id", "")) == "tutorial_5x5":
		return {"skipped": true, "reason": "tutorial_completion_owned_by_meta_adapter"}
	var result_id := str(result_snapshot.get("result_id", ""))
	var map_id := str(run_start.get("map_config_id", run_start.get("config_id", "classic_10x10_standard")))
	if not map_id.begins_with("classic_"):
		map_id = "classic_10x10_standard"
	var commission_id := str(run_start.get("selected_objective_id", "commission_recover_supply"))
	var settlement := _dictionary(result_snapshot.get("settlement", {}))
	var outcome := str(result_snapshot.get("outcome", settlement.get("outcome", "")))
	var settlement_outcome := str(settlement.get("outcome", ""))
	var is_success := outcome in ["Extracted", "Training Complete"] or settlement_outcome == "success"
	var is_failure := outcome == "Failed" or settlement_outcome == "failure"
	var is_abandon := outcome == "Abandoned" or settlement_outcome == "abandon"
	var run_stats := _dictionary(result_snapshot.get("run_stats", result_snapshot.get("stats", {})))
	var events := _array(result_snapshot.get("run_events", result_snapshot.get("event_log", [])))
	var recovered_items := _recovered_items(result_snapshot, settlement, is_success, is_failure, is_abandon)
	var talent_points_before := int(data.get("talent_points", 0))
	var delta := {
		"result_id": result_id,
		"map_id": map_id,
		"commission_id": commission_id,
		"commission_completed": false,
		"gold_gained": 0,
		"exp_gained": 0,
		"profile_level_before": int(data.get("profile_level", 1)),
		"new_codex_ids": [],
		"new_collection_ids": [],
		"new_unlock_ids": [],
		"new_achievement_ids": [],
		"task_became_claimable": "",
	}

	_add_discovery(data, "map:%s" % map_id, delta)
	_record_runtime_discoveries(data, events, delta)
	_record_recovered_discoveries(data, recovered_items, delta)
	_update_event_counts(data, run_stats)

	var commission_completed := is_success and _commission_completed(commission_id, result_snapshot, settlement, recovered_items, run_stats, events)
	var commission_exp := 0
	delta["commission_completed"] = commission_completed
	if is_success:
		_increment_map_success(data, map_id)
	if commission_completed:
		var reward := _dictionary(M7ContentCatalogScript.commission_definition(commission_id).get("reward", {}))
		var reward_id := "commission:%s:%s" % [result_id, commission_id]
		if _grant_automatic_reward(data, reward_id, reward):
			delta["gold_gained"] = int(reward.get("gold", 0))
			commission_exp = int(reward.get("exp", 0))
	var outcome_percent := 100 if is_success else (60 if is_failure else 0)
	var experience := _exploration_experience(result_snapshot, run_stats, map_id, commission_exp, outcome_percent)
	delta["experience_breakdown"] = experience
	delta["exp_gained"] = int(experience["experience"])
	_add_exp(data, int(delta["exp_gained"]))
	(data["commission_history"] as Array).append({
		"result_id": result_id,
		"map_id": map_id,
		"commission_id": commission_id,
		"completed": commission_completed,
		"outcome": outcome,
	})

	_update_active_task(data, result_snapshot, recovered_items, run_stats, events, commission_completed, is_failure)
	var task_states: Dictionary = data.get("task_states", {})
	for task_id in task_states.keys():
		var state := _dictionary(task_states[task_id])
		if str(state.get("newly_claimable_result_id", "")) == result_id:
			delta["task_became_claimable"] = task_id
	_update_achievements(data, result_snapshot, run_stats, events, is_success, delta)
	_update_collection_sets(data)
	_refresh_profile_awards(data)
	delta["profile_level_after"] = int(data.get("profile_level", 1))
	delta["talent_points_gained"] = int(data.get("talent_points", 0)) - talent_points_before
	delta["new_unlock_ids"] = refresh_map_unlocks(data)
	if result_id != "":
		_append_unique(data["unread_history_ids"] as Array, result_id)
	_refresh_red_dots(data)
	return delta


static func _apply_z2_growth(data: Dictionary, snapshot: Dictionary) -> Dictionary:
	var result := _dictionary(snapshot.get("RunResult", snapshot.get("run_result", snapshot)))
	var start := _dictionary(result.get("run_start_config", {}))
	var map_id := str(start.get("map_config_id", ""))
	if map_id == "tutorial_5x5" or result.get("mode", "") == "tutorial":
		return {"skipped": true, "reason": "tutorial_completion_owned_by_meta_adapter"}
	var candidate := data.duplicate(true)
	var previous_notices := _dictionary(data.get("z2_quest_notices", {})).duplicate(true)
	sync_z2_quests(candidate)
	var source := Z2QuestFactsScript.build(candidate, snapshot)
	if not bool(source.get("ok", false)):
		return {"ok": false, "skipped": true, "reason": str(source.get("status", "quest_facts_missing"))}
	var quests := Z2QuestProgressionScript.apply_settlement(candidate, source.facts, str(source.result_id))
	if not bool(quests.get("ok", false)):
		return {"ok": false, "skipped": true, "reason": str(quests.get("status", "quest_reduction_failed"))}
	if quests.status != "applied":
		return {"ok": true, "status": quests.status, "result_id": str(source.result_id), "exp_gained": 0, "gold_gained": 0, "completions": []}
	var ending := str(source.facts.ending)
	var events := _array(result.get("run_events", source.facts.run_events))
	var score := Z2Rules.score_events(events)
	var growth := Z2Rules.settle_scores(map_id, int(score.experience), int(score.talent_points), ending)
	if _dictionary(result.get("settlement", {})).has("z2_growth"):
		growth = _dictionary(result.settlement.z2_growth)
	if not growth.get("ok", false):
		return {"ok": false, "skipped": true, "reason": "invalid_growth_source"}
	data.merge(quests.meta, true)
	data["z2_fact_sequence"] = int(source.facts.settlement_sequence)
	_remember_quest_completions(data, quests.completions)
	var before := int(data.get("profile_level", 0))
	_add_exp(data, int(growth.experience))
	data["talent_earned"] = int(data.talent_earned) + int(growth.talent_points)
	M7TalentCatalogScript.sync_progress(data)
	if ending == "success":
		_increment_map_success(data, map_id)
	var delta := {"ok": true, "result_id": str(source.result_id), "map_id": map_id,
		"gold_gained": 0, "exp_gained": int(growth.experience), "talent_points_gained": int(growth.talent_points),
		"profile_level_before": before, "profile_level_after": int(data.profile_level),
		"experience_breakdown": growth, "new_codex_ids": [], "new_collection_ids": [],
		"new_unlock_ids": refresh_map_unlocks(data), "new_achievement_ids": [], "task_became_claimable": "",
		"quest_missing_fact_goal_ids": source.missing_fact_goal_ids.duplicate(), "completions": []}
	for key in data.get("z2_quest_notices", {}):
		if not previous_notices.has(key):
			var notice: Dictionary = data.z2_quest_notices[key]
			delta.completions.append(notice.duplicate(true))
			if str(notice.goal_id).begins_with("A"):
				delta.new_achievement_ids.append(notice.goal_id)
			elif str(delta.task_became_claimable).is_empty():
				delta.task_became_claimable = notice.goal_id
	_record_runtime_discoveries(data, events, delta)
	_record_recovered_discoveries(data, _recovered_items(snapshot, _dictionary(snapshot.get("settlement", {})), ending == "success", ending == "failure", ending == "abandon"), delta)
	_append_unique(data["unread_history_ids"], str(source.result_id))
	_refresh_profile_awards(data)
	_refresh_red_dots(data)
	return delta


static func claim_goal_reward(data: Dictionary, goal_kind: String, goal_id: String, tier: int = 1) -> Dictionary:
	if Z2Rules.applies_to(data):
		return _claim_z2_goal_reward(data, goal_kind, goal_id, tier)
	var definitions := M7ContentCatalogScript.task_definitions(data) + M7ContentCatalogScript.optional_task_definitions(data) if goal_kind == "task" else M7ContentCatalogScript.achievement_definitions(data)
	var states_key := "task_states" if goal_kind == "task" else "achievement_states"
	var states: Dictionary = data.get(states_key, {})
	var state := _dictionary(states.get(goal_id, {}))
	var reward_id := "%s:%s" % [goal_kind, goal_id]
	if str(state.get("status", "")) == "claimed" or (data["claimed_reward_ids"] as Array).has(reward_id):
		return {"ok": true, "status": "duplicate_ignored", "goal_id": goal_id}
	if str(state.get("status", "")) != "claimable":
		return {"ok": false, "status": "not_claimable", "goal_id": goal_id}
	var definition := _find_definition(definitions, goal_id)
	if definition.is_empty():
		return {"ok": false, "status": "unknown_goal", "goal_id": goal_id}
	var reward := _dictionary(definition.get("reward", {}))
	state["status"] = "claimed"
	state["claimed"] = true
	states[goal_id] = state
	_append_unique(data["claimed_reward_ids"] as Array, reward_id)
	_grant_reward_payload(data, reward, "m7_%s_reward" % goal_kind)
	if goal_kind == "task":
		_activate_next_task(data, goal_id)
	_refresh_profile_awards(data)
	var new_unlock_ids := refresh_map_unlocks(data)
	_refresh_red_dots(data)
	return {"ok": true, "status": "claimed", "goal_id": goal_id, "reward": reward.duplicate(true), "new_unlock_ids": new_unlock_ids}


static func sync_z2_quests(data: Dictionary) -> void:
	if not Z2Rules.applies_to(data):
		return
	var refreshed := Z2QuestProgressionScript.refresh_available(data, "activation:%d" % int(data.get("z2_fact_sequence", 0)))
	data.merge(refreshed.meta, true)
	_remember_quest_completions(data, refreshed.completions)
	# These maps are views only, never inputs to the canonical detector.
	data["task_states"] = {}
	data["achievement_states"] = {}
	for definition in Z2QuestCatalogScript.definitions():
		var state := Z2QuestProgressionScript.goal_state(data, definition.id)
		var steps: Array = definition.reward_steps
		state["achieved"] = state.achieved_tiers.size() == steps.size()
		state["claimed"] = state.claimed_tiers.size() == steps.size()
		state["claimed_steps"] = []
		state["tier"] = int(steps.back().tier)
		state["newly_claimable_result_id"] = ""
		var pending := false
		for step: Dictionary in steps:
			if state.claimed_tiers.has(int(step.tier)):
				state.claimed_steps.append(int(step.target))
			elif not pending:
				state.tier = int(step.tier)
				state.target = int(step.target)
				pending = true
		var key := "achievement_states" if definition.kind == "achievement" else "task_states"
		data[key][definition.id] = state

static func _remember_quest_completions(data: Dictionary, completions: Array) -> void:
	var notices := _dictionary(data.get("z2_quest_notices", {}))
	for notice: Dictionary in completions:
		notices["%s:%d" % [str(notice.goal_id), int(notice.tier)]] = notice.duplicate(true)
	data["z2_quest_notices"] = notices


static func record_z2_lobby_fact(data: Dictionary, type: String, payload: Dictionary, receipt_id: String) -> Dictionary:
	if not Z2Rules.applies_to(data) or receipt_id.is_empty() or type not in ["item_sold", "item_purchased", "talent_unlocked", "research_completed"]:
		return {"ok": false, "status": "invalid_quest_lobby_fact"}
	if not _dictionary(data.get("admission", {})).is_empty():
		return {"ok": false, "status": "active_run_lobby_action_blocked"}
	var receipts: Dictionary = data.get("z2_quest_lobby_receipts", {})
	var fingerprint := JSON.stringify({"type": type, "payload": payload}, "", true).sha256_text()
	if receipts.has(receipt_id):
		return {"ok": receipts[receipt_id].fingerprint == fingerprint, "status": "duplicate_ignored" if receipts[receipt_id].fingerprint == fingerprint else "quest_lobby_receipt_conflict"}
	var seq := int(data.get("z2_fact_sequence", 0)) + 1
	var items: Array = _array(payload.get("items", [payload])).duplicate(true)
	for item: Dictionary in items:
		if item.get("item_type", "") == "collection":
			item.item_type = "collectible"
	var kind := str({"item_sold": "sell_collectible", "item_purchased": "purchase", "talent_unlocked": "unlock_talent", "research_completed": "complete_research"}[type])
	var reduced := Z2QuestProgressionScript.apply_camp_action(data, {"sequence": seq, "kind": kind, "items": items})
	if not reduced.ok or reduced.status != "applied":
		return {"ok": false, "status": "quest_lobby_sequence_conflict"}
	data.merge(reduced.meta, true)
	data["z2_fact_sequence"] = seq
	receipts[receipt_id] = {"sequence": seq, "fingerprint": fingerprint}
	data["z2_quest_lobby_receipts"] = receipts
	_remember_quest_completions(data, reduced.completions)
	sync_z2_quests(data)
	return {"ok": true, "status": "recorded", "sequence": seq, "completions": reduced.completions}


static func _claim_z2_goal_reward(data: Dictionary, kind: String, id: String, tier: int) -> Dictionary:
	if kind not in ["task", "achievement"] or (id.begins_with("A") != (kind == "achievement")):
		return {"ok": false, "status": "invalid_goal_kind", "goal_id": id, "tier": tier}
	var candidate := data.duplicate(true)
	sync_z2_quests(candidate)
	var evaluation := Z2QuestProgressionScript.claim_evaluation(candidate, id, tier)
	var result := {"ok": evaluation.ok, "status": evaluation.status, "goal_kind": kind, "goal_id": id, "tier": tier,
		"reward_id": str(evaluation.get("reward_id", "")), "reward": evaluation.reward.duplicate(true)}
	if not evaluation.ok or evaluation.status == "duplicate_ignored":
		return result
	data.merge(evaluation.meta, true)
	_grant_reward_payload(data, evaluation.reward, "z2_quest_reward")
	_append_unique(data["claimed_reward_ids"], str(evaluation.reward_id))
	_refresh_profile_awards(data)
	result["new_unlock_ids"] = refresh_map_unlocks(data)
	_refresh_red_dots(data)
	return result


static func next_instance_id(data: Dictionary, source: String, item_id: String) -> String:
	data["transaction_sequence"] = int(data.get("transaction_sequence", 0)) + 1
	return "m7:%s:%06d:%s" % [source, int(data["transaction_sequence"]), item_id]


static func add_item_instance(data: Dictionary, item_id: String, source: String) -> Dictionary:
	var item := M7ContentCatalogScript.item_definition(item_id, data)
	if item.is_empty():
		return {}
	item["instance_id"] = next_instance_id(data, source, item_id)
	item["source"] = source
	item["source_label"] = source
	item["location_state"] = &"warehouse"
	(data["warehouse_items"] as Array).append(item)
	_add_discovery(data, "item:%s" % item_id, {})
	return item.duplicate(true)


static func refresh_red_dots(data: Dictionary) -> Dictionary:
	_refresh_red_dots(data)
	return _dictionary(data.get("red_dot_state", {}))


static func _default_task_states() -> Dictionary:
	var result := {}
	var definitions := M7ContentCatalogScript.legacy_task_definitions()
	for index in range(definitions.size()):
		result[str(definitions[index].get("id", ""))] = _goal_state("active" if index == 0 else "locked")
	for definition in M7ContentCatalogScript.legacy_optional_task_definitions():
		result[str(definition.get("id", ""))] = _goal_state("active")
	return result


static func _default_achievement_states() -> Dictionary:
	var result := {}
	for definition in M7ContentCatalogScript.legacy_achievement_definitions():
		result[str(definition.get("id", ""))] = _goal_state("active")
	return result


static func _goal_state(status: String) -> Dictionary:
	return {"status": status, "progress": 0, "achieved": status in ["claimable", "claimed"], "claimed": status == "claimed", "newly_claimable_result_id": ""}


static func _normalize_goal_states(states: Dictionary, definitions: Array, sequential: bool) -> Dictionary:
	var result := states.duplicate(true)
	for index in range(definitions.size()):
		var id := str((definitions[index] as Dictionary).get("id", ""))
		if not result.has(id):
			result[id] = _goal_state("active" if not sequential or index == 0 else "locked")
		else:
			var state := _dictionary(result[id])
			var fallback := "active" if not sequential or index == 0 else "locked"
			state["status"] = str(state.get("status", fallback))
			state["progress"] = maxi(0, int(state.get("progress", 0)))
			state["achieved"] = bool(state.get("achieved", state["status"] in ["claimable", "claimed"]))
			state["claimed"] = bool(state.get("claimed", state["status"] == "claimed"))
			state["newly_claimable_result_id"] = str(state.get("newly_claimable_result_id", ""))
			result[id] = state
	return result


static func _commission_completed(commission_id: String, result_snapshot: Dictionary, settlement: Dictionary, recovered_items: Array, run_stats: Dictionary, events: Array) -> bool:
	var definition := M7ContentCatalogScript.commission_definition(commission_id)
	match StringName(definition.get("metric", &"")):
		&"recover_non_consumables":
			var count := 0
			for raw_item in recovered_items:
				if str(_dictionary(raw_item).get("item_type", "")) != "consumable":
					count += 1
			return count >= int(definition.get("target", 2))
		&"unique_rooms":
			return int(result_snapshot.get("unique_rooms_explored", 0)) >= int(definition.get("target", 12))
		&"monsters_defeated":
			return int(run_stats.get("monsters_defeated", 0)) >= int(definition.get("target", 2))
		&"chests_opened":
			return int(run_stats.get("chest_rooms", 0)) >= int(definition.get("target", 2))
		&"events_completed":
			return int(run_stats.get("events_completed", 0)) >= int(definition.get("target", 2))
		&"critical_extract":
			return int(result_snapshot.get("protocol_level", 5)) == 1
	return false


static func _update_active_task(data: Dictionary, result_snapshot: Dictionary, recovered_items: Array, run_stats: Dictionary, events: Array, commission_completed: bool, is_failure: bool) -> void:
	var states: Dictionary = data.get("task_states", {})
	var active_id := ""
	for definition in M7ContentCatalogScript.task_definitions(data):
		var id := str(definition.get("id", ""))
		if str(_dictionary(states.get(id, {})).get("status", "locked")) == "active":
			active_id = id
			break
	if active_id != "" and _task_condition(active_id, data, result_snapshot, recovered_items, run_stats, events, commission_completed):
		var state := _dictionary(states.get(active_id, {}))
		state["status"] = "claimable"
		state["achieved"] = true
		state["progress"] = 1
		state["newly_claimable_result_id"] = str(result_snapshot.get("result_id", ""))
		states[active_id] = state
	var salvage_state := _dictionary(states.get("task_failure_salvage", {}))
	if str(salvage_state.get("status", "active")) == "active" and is_failure and not recovered_items.is_empty():
		salvage_state["status"] = "claimable"
		salvage_state["achieved"] = true
		salvage_state["progress"] = 1
		salvage_state["newly_claimable_result_id"] = str(result_snapshot.get("result_id", ""))
		states["task_failure_salvage"] = salvage_state
	data["task_states"] = states


static func _task_condition(task_id: String, data: Dictionary, result_snapshot: Dictionary, recovered_items: Array, run_stats: Dictionary, events: Array, commission_completed: bool) -> bool:
	match task_id:
		"task_first_survey":
			return int(run_stats.get("map_open_count", 0)) >= 1 and int(result_snapshot.get("unique_rooms_explored", 0)) >= 3
		"task_risk_mark":
			return int(run_stats.get("flags_placed", 0)) >= 1
		"task_supply_recovery":
			return int(run_stats.get("chest_rooms", 0)) >= 1 and _event_count(events, "item_picked_up") >= 1
		"task_clear_anomaly":
			return int(run_stats.get("monsters_defeated", 0)) >= 1
		"task_complete_commission":
			return commission_completed
		"task_prepared_deploy":
			var purchased: Array = data.get("purchased_instance_ids", [])
			var run_start := _dictionary(result_snapshot.get("run_start_config", {}))
			for instance_id in _array(run_start.get("selected_equipment_ids", [])) + _array(run_start.get("selected_consumable_ids", [])):
				if purchased.has(str(instance_id)):
					return true
			return false
		"task_sample_research":
			return not _array(data.get("research_completed_ids", [])).is_empty() and _contains_monster_sample(recovered_items)
	return false


static func _update_achievements(data: Dictionary, result_snapshot: Dictionary, run_stats: Dictionary, events: Array, is_success: bool, delta: Dictionary) -> void:
	var conditions := {
		"achievement_first_return": is_success,
		"achievement_clean_route": is_success and int(run_stats.get("mine_hits", 0)) == 0,
		"achievement_critical_return": is_success and int(result_snapshot.get("protocol_level", 5)) == 1,
		"achievement_low_hp_return": is_success and int(result_snapshot.get("hp", 100)) <= 10,
		"achievement_chest_expert": is_success and int(run_stats.get("chest_rooms", 0)) >= 4,
		"achievement_anomaly_sweep": is_success and int(run_stats.get("monsters_defeated", 0)) >= 4,
		"achievement_measured_greed": is_success and _unique_rooms_after_exit(events) >= 8,
		"achievement_four_events": _all_event_types_completed(data),
	}
	var states: Dictionary = data.get("achievement_states", {})
	for achievement_id in conditions.keys():
		if not bool(conditions[achievement_id]):
			continue
		var state := _dictionary(states.get(achievement_id, _goal_state("active")))
		if str(state.get("status", "active")) in ["claimable", "claimed"]:
			continue
		state["status"] = "claimable"
		state["achieved"] = true
		state["progress"] = 1
		state["newly_claimable_result_id"] = str(result_snapshot.get("result_id", ""))
		states[achievement_id] = state
		(delta["new_achievement_ids"] as Array).append(achievement_id)
	data["achievement_states"] = states


static func _record_runtime_discoveries(data: Dictionary, events: Array, delta: Dictionary) -> void:
	for raw_event in events:
		var event := _dictionary(raw_event)
		var payload := _dictionary(event.get("payload", {}))
		var event_type := str(event.get("event_type", ""))
		if event_type == "combat_resolved":
			var monster_types := _array(payload.get("monster_types", []))
			if monster_types.is_empty():
				monster_types = [payload.get("monster_type", payload.get("enemy_type", ""))]
			for raw_monster_type in monster_types:
				var monster_type := str(raw_monster_type)
				if monster_type != "":
					_add_discovery(data, "monster:%s" % monster_type, delta)
		if event_type == "event_option_selected":
			var encounter_type := str(payload.get("event_type", ""))
			if encounter_type != "":
				_add_discovery(data, "event:%s" % encounter_type, delta)


static func _record_recovered_discoveries(data: Dictionary, recovered_items: Array, delta: Dictionary) -> void:
	for raw_item in recovered_items:
		var item := _dictionary(raw_item)
		var item_id := str(item.get("item_id", ""))
		if item_id == "":
			continue
		_add_discovery(data, "item:%s" % item_id, delta)
		if str(item.get("item_type", "")) == "collectible":
			var discoveries: Array = data.get("collection_discoveries", [])
			if not discoveries.has(item_id):
				discoveries.append(item_id)
				(delta["new_collection_ids"] as Array).append(item_id)


static func _add_discovery(data: Dictionary, discovery_id: String, delta: Dictionary) -> void:
	if discovery_id == "":
		return
	var discoveries: Array = data.get("codex_discoveries", [])
	if discoveries.has(discovery_id):
		return
	discoveries.append(discovery_id)
	_append_unique(data["unread_codex_ids"] as Array, discovery_id)
	if delta.has("new_codex_ids") and delta["new_codex_ids"] is Array:
		(delta["new_codex_ids"] as Array).append(discovery_id)


static func _update_collection_sets(data: Dictionary) -> void:
	var discoveries: Array = data.get("collection_discoveries", [])
	var completed: Array = data.get("completed_collection_set_ids", [])
	for definition in M7ContentCatalogScript.collection_sets():
		var set_id := str(definition.get("id", ""))
		if completed.has(set_id):
			continue
		var complete := true
		for item_id in _array(definition.get("item_ids", [])):
			if not discoveries.has(str(item_id)):
				complete = false
				break
		if complete:
			completed.append(set_id)
			_append_unique(data["unread_collection_set_ids"] as Array, set_id)


static func refresh_map_unlocks(data: Dictionary) -> Array[String]:
	var unlocked: Array = data.get("unlocked_map_ids", [])
	if Z2Rules.applies_to(data):
		sync_z2_quests(data)
		var current: Array = []
		var added: Array[String] = []
		for id in Z2Rules.MAP_RULES:
			if Z2Rules.map_blockers(data, id).is_empty():
				current.append(id)
				if not unlocked.has(id):
					added.append(id)
		data["unlocked_map_ids"] = current
		return added
	var new_unlocks: Array[String] = []
	for definition in M7ContentCatalogScript.map_definitions():
		var map_id := str(definition["id"])
		if not unlocked.has(map_id) and map_unlock_blockers(data, definition).is_empty():
			unlocked.append(map_id)
			new_unlocks.append(map_id)
	data["unlocked_map_ids"] = unlocked
	return new_unlocks


static func map_unlock_blockers(data: Dictionary, definition: Dictionary) -> PackedStringArray:
	if Z2Rules.applies_to(data):
		return Z2Rules.map_blockers(data, str(definition.get("id", "")))
	var blockers := PackedStringArray()
	if bool(definition.get("required_tutorial", false)) and not bool(data.get("tutorial_completed", false)):
		blockers.append("完成新手教程")
	var level := int(definition.get("min_profile_level", 1))
	if int(data.get("profile_level", 1)) < level:
		blockers.append("达到 Lv.%d" % level)
	var clear_id := str(definition.get("required_clear_id", ""))
	if not clear_id.is_empty() and int(_dictionary(data.get("map_success_counts", {})).get(clear_id, 0)) < 1:
		var map_name := str(M7ContentCatalogScript.map_definition_exact(clear_id).get("display_name", clear_id))
		blockers.append("%s 成功撤离" % map_name)
	var research_id := str(definition.get("required_research_id", ""))
	if not research_id.is_empty() and not _array(data.get("research_completed_ids", [])).has(research_id):
		var research_name := str(M7ContentCatalogScript.research_definition(research_id).get("display_name", research_id))
		blockers.append("完成「%s」研究" % research_name)
	var achievement_id := str(definition.get("required_achievement_id", ""))
	var achievement := _dictionary(_dictionary(data.get("achievement_states", {})).get(achievement_id, {}))
	if not achievement_id.is_empty() and not bool(achievement.get("achieved", false)):
		var achievement_definition := _find_definition(M7ContentCatalogScript.achievement_definitions(data), achievement_id)
		blockers.append("达成「%s」" % str(achievement_definition.get("display_name", achievement_id)))
	return blockers


static func _increment_map_success(data: Dictionary, map_id: String) -> void:
	var counts: Dictionary = data.get("map_success_counts", {})
	counts[map_id] = int(counts.get(map_id, 0)) + 1


static func _update_event_counts(data: Dictionary, run_stats: Dictionary) -> void:
	var counts: Dictionary = data.get("event_completion_counts", {})
	for event_id in ["trader", "dice", "altar", "trap"]:
		counts[event_id] = int(counts.get(event_id, 0)) + int(run_stats.get("events_%s" % event_id, 0))


static func _all_event_types_completed(data: Dictionary) -> bool:
	var counts: Dictionary = data.get("event_completion_counts", {})
	for event_id in ["trader", "dice", "altar", "trap"]:
		if int(counts.get(event_id, 0)) < 1:
			return false
	return true


static func _activate_next_task(data: Dictionary, claimed_id: String) -> void:
	var definitions := M7ContentCatalogScript.task_definitions(data)
	var states: Dictionary = data.get("task_states", {})
	for index in range(definitions.size() - 1):
		if str(definitions[index].get("id", "")) != claimed_id:
			continue
		var next_id := str(definitions[index + 1].get("id", ""))
		var next_state := _dictionary(states.get(next_id, _goal_state("locked")))
		if str(next_state.get("status", "locked")) == "locked":
			next_state["status"] = "active"
			states[next_id] = next_state
		break


static func _grant_automatic_reward(data: Dictionary, reward_id: String, reward: Dictionary) -> bool:
	var granted: Array = data.get("granted_reward_ids", [])
	if granted.has(reward_id):
		return false
	granted.append(reward_id)
	var asset_reward := reward.duplicate()
	asset_reward.erase("exp")
	_grant_reward_payload(data, asset_reward, "m7_commission")
	return true


static func _grant_reward_payload(data: Dictionary, reward: Dictionary, source: String) -> void:
	data["gold"] = maxi(0, int(data.get("gold", 0)) + int(reward.get("gold", 0)))
	_add_exp(data, int(reward.get("exp", 0)))
	for item_id in _array(reward.get("items", [])):
		add_item_instance(data, str(item_id), source)


static func _add_exp(data: Dictionary, amount: int) -> void:
	data["profile_exp"] = maxi(0, int(data.get("profile_exp", 0)) + maxi(0, amount))
	data["profile_level"] = Z2Rules.level_for_exp(int(data["profile_exp"])) if Z2Rules.applies_to(data) else M7ContentCatalogScript.profile_level_for_exp(int(data["profile_exp"]))
	M7TalentCatalogScript.sync_progress(data)


static func _exploration_experience(result: Dictionary, run_stats: Dictionary, map_id: String, commission_exp: int, outcome_percent: int) -> Dictionary:
	var room_exp := clampi(int(result.get("unique_rooms_explored", 0)) - 1, 0, 45)
	var chest_exp := 4 * clampi(int(run_stats.get("chest_rooms", 0)), 0, 5)
	var combat_exp := 5 * clampi(int(run_stats.get("monsters_defeated", 0)), 0, 5)
	var event_exp := 5 * clampi(int(run_stats.get("events_completed", 0)), 0, 5)
	var score := room_exp + chest_exp + combat_exp + event_exp + commission_exp
	var definition := M7ContentCatalogScript.map_definition(map_id)
	var difficulty_percent := int(definition.get("experience_percent", 100))
	var cap := int(definition.get("experience_cap", 0))
	var scaled := mini(score * difficulty_percent, cap * 100)
	return {
		"room_exp": room_exp,
		"chest_exp": chest_exp,
		"combat_exp": combat_exp,
		"event_exp": event_exp,
		"commission_exp": commission_exp,
		"score": score,
		"difficulty_percent": difficulty_percent,
		"outcome_percent": outcome_percent,
		"cap": cap,
		"experience": int(scaled * outcome_percent / 10000.0),
	}


static func _refresh_profile_awards(data: Dictionary) -> void:
	var level := Z2Rules.level_for_exp(int(data.get("profile_exp", 0))) if Z2Rules.applies_to(data) else M7ContentCatalogScript.profile_level_for_exp(int(data.get("profile_exp", 0)))
	if Z2Rules.applies_to(data) and not data.get("tutorial_completed", false):
		level = 0
	data["profile_level"] = level
	var titles: Array = data.get("titles", [])
	var badges: Array = data.get("badges", [])
	for definition in M7ContentCatalogScript.profile_levels():
		if int(definition.get("level", 1)) > level:
			continue
		_append_unique(titles, str(definition.get("title", "")))
		if str(definition.get("badge", "")) != "":
			_append_unique(badges, str(definition.get("badge", "")))


static func _refresh_red_dots(data: Dictionary) -> void:
	var task_claimable := _claimable_count(_dictionary(data.get("task_states", {})))
	var achievement_claimable := _claimable_count(_dictionary(data.get("achievement_states", {})))
	var research_available := 0
	for definition in M7ContentCatalogScript.research_definitions(data):
		if _research_can_complete(data, definition):
			research_available += 1
	var talent_available := 0
	for node in M7TalentCatalogScript.projection(data):
		if bool(node.get("available", false)):
			talent_available += 1
	data["red_dot_state"] = {
		"claimable_rewards": task_claimable + achievement_claimable,
		"new_codex": _array(data.get("unread_codex_ids", [])).size(),
		"research_available": research_available,
		"talent_available": talent_available,
		"new_history": _array(data.get("unread_history_ids", [])).size(),
		"collection_completed": _array(data.get("unread_collection_set_ids", [])).size(),
	}


static func _research_can_complete(data: Dictionary, definition: Dictionary) -> bool:
	var completed: Array = data.get("research_completed_ids", [])
	var id := str(definition.get("id", ""))
	if completed.has(id):
		return false
	var prerequisite := str(definition.get("prerequisite", ""))
	if prerequisite != "" and not completed.has(prerequisite):
		return false
	if int(data.get("gold", 0)) < int(definition.get("gold_cost", 0)):
		return false
	var material_id := str(definition.get("material_item_id", ""))
	for raw_item in _array(data.get("warehouse_items", [])):
		if str(_dictionary(raw_item).get("item_id", "")) == material_id:
			return true
	return false


static func _claimable_count(states: Dictionary) -> int:
	var count := 0
	for raw_state in states.values():
		if str(_dictionary(raw_state).get("status", "")) == "claimable":
			count += 1
	return count


static func _recovered_items(result_snapshot: Dictionary, settlement: Dictionary, is_success: bool, is_failure: bool, is_abandon: bool) -> Array:
	if is_success:
		return _array(settlement.get("warehouse_lite", result_snapshot.get("warehouse_lite", [])))
	if is_failure:
		var salvaged := _array(settlement.get("salvaged_items", []))
		if salvaged.is_empty():
			salvaged = _array(_dictionary(result_snapshot.get("failure_salvage", {})).get("salvaged_items", []))
		return salvaged
	if is_abandon:
		return _array(_dictionary(settlement.get("event_item_delivery", {})).get("delivered", []))
	return []


static func _contains_monster_sample(items: Array) -> bool:
	for raw_item in items:
		var item := _dictionary(raw_item)
		if str(item.get("source", "")).find("monster") >= 0 or (_array(item.get("tags", []))).has("monster"):
			return true
	return false


static func _unique_rooms_after_exit(events: Array) -> int:
	var exit_sequence := -1
	var positions := {}
	for raw_event in events:
		var event := _dictionary(raw_event)
		var event_type := str(event.get("event_type", ""))
		if event_type == "extraction_found" and exit_sequence < 0:
			exit_sequence = int(event.get("sequence", -1))
			continue
		if exit_sequence < 0 or event_type != "room_entered" or int(event.get("sequence", 0)) <= exit_sequence:
			continue
		var pos: Variant = _dictionary(event.get("payload", {})).get("position", null)
		positions[str(pos)] = true
	return positions.size()


static func _event_count(events: Array, event_type: String) -> int:
	var count := 0
	for raw_event in events:
		if str(_dictionary(raw_event).get("event_type", "")) == event_type:
			count += 1
	return count


static func _find_definition(definitions: Array, definition_id: String) -> Dictionary:
	for raw_definition in definitions:
		var definition := _dictionary(raw_definition)
		if str(definition.get("id", "")) == definition_id:
			return definition
	return {}


static func _append_unique(target: Array, value: String) -> void:
	if value != "" and not target.has(value):
		target.append(value)


static func _unique_strings(values: Array, required: Array = []) -> Array[String]:
	var result: Array[String] = []
	for value in required + values:
		_append_unique(result, str(value))
	return result


static func _dictionary(value: Variant) -> Dictionary:
	return value.duplicate(true) if value is Dictionary else {}


static func _array(value: Variant) -> Array:
	return value.duplicate(true) if value is Array else []
