extends RefCounted
class_name RunSettlementService

const Snapshot := preload("res://scripts/core/run/run_state_snapshot.gd")
const Growth := preload("res://scripts/core/progression/z2_progression_rules.gd")
const Economy := preload("res://scripts/core/run/z2_economy_events.gd")

static func applies_to(context) -> bool:
	return context != null and context.mode != &"tutorial" and context.profile_fields.get("ruleset_id", "") == "z2" and context.profile_fields.get("z2_progression_version") == 1


static func build(context, ending: String, selected_instance_ids: Array = [], preview: bool = false, options: Dictionary = {}) -> Dictionary:
	if not applies_to(context) or context.asset_ledger == null or ending not in ["success", "failure", "abandon"]:
		return {"ok": false, "reason": "invalid_settlement_context"}
	var input := Snapshot.capture_data(context.asset_ledger)
	var ledger := RunAssetLedger.new()
	Snapshot.install_data(ledger, input)
	var choice := selection_preview(context, ending, selected_instance_ids)
	var needs_success_choice: bool = ending == "success" and int(choice.retention_limit) > 0 and not (choice.retention_candidates as Array).is_empty()
	var pending: bool = preview or (needs_success_choice and not bool(options.get("selection_confirmed", false)))
	var settlement: Dictionary
	if pending:
		settlement = ledger.build_failure_preview()
		settlement.merge(choice, true)
		settlement["requires_salvage_selection"] = ending != "success" or needs_success_choice
		settlement["selection_kind"] = "retention" if ending == "success" else "salvage"
		settlement["finalized"] = false
		settlement["warehouse_items"] = []
	elif ending == "success":
		var selection := _validate_selection(context, ending, selected_instance_ids, needs_success_choice)
		if not selection.ok:
			return selection
		var conversion_percent := 100
		for effect in context.active_talent_effects:
			if str(effect.get("effect_kind", "")) == "extraction_gold_percent":
				conversion_percent += int(effect.get("effect_amount", 0))
		settlement = ledger.settle_success(conversion_percent, selection)
		settlement.merge(selection.display, true)
	else:
		var selection := _validate_selection(context, ending, selected_instance_ids, true)
		if not selection.ok:
			return selection
		settlement = ledger.settle_failure(selected_instance_ids, selection)
		settlement.merge(selection.display, true)
	if not settlement.get("ok", false):
		return settlement
	settlement["outcome"] = StringName(ending)
	settlement["settlement_outcome"] = StringName(ending)
	settlement["warehouse_items"] = settlement.get("warehouse_lite", settlement.get("salvaged_items", [])).duplicate(true)
	if ending != "success":
		settlement["warehouse_items"] = settlement.get("salvaged_items", []).duplicate(true)
	var events: Array = context.run_event_log.snapshot()
	var score := Growth.score_events(events)
	settlement["z2_growth"] = Growth.settle_scores(str(context.run_start_config.get("map_config_id", "")), int(score.experience), int(score.talent_points), ending)
	settlement["terminal_facts"] = {
		"run_id": str(context.run_id), "ending": ending,
		"run_start_config": context.run_start_config.duplicate(true),
		"run_stats": context.run_stats.duplicate(true), "run_events": events,
		"explored_cells": context.explored_cells.duplicate(true),
		"exits": context.truth_map.exits.duplicate(),
		"event_state": context.z1_event_flags.duplicate(true),
		"items_before_settlement": input.item_instances.duplicate(true),
		"capacity_before_settlement": context.asset_ledger.get_capacity_snapshot(),
		"hp": context.hp, "max_hp": context.max_hp, "shield": context.shield,
		"power": context.power, "stress": context.pressure,
		"starting_power": int(context.run_start_config.get("starting_power", 0)),
		"starting_pressure": int(context.run_start_config.get("starting_pressure", 0)),
		"hidden_exits_at_start": context.run_start_config.get("hidden_exits_at_start", []).duplicate(),
		"intel": Snapshot.capture_data(context.intel_map),
	}
	settlement["settlement_source"] = "RunSettlementService"
	return {"ok": true, "run_id": str(context.run_id), "preview": preview,
		"input_fingerprint": Snapshot.fingerprint(Snapshot.capture_context(context)), "candidate_ledger": Snapshot.capture_data(ledger),
		"settlement": settlement}


static func apply(context, plan: Dictionary) -> Dictionary:
	if not plan.get("ok", false):
		return plan.duplicate(true)
	if plan.get("preview", false):
		return {"ok": false, "reason": "settlement_plan_not_committable"}
	if str(plan.get("run_id", "")) != str(context.run_id) or plan.get("input_fingerprint", "") != Snapshot.fingerprint(Snapshot.capture_context(context)):
		return {"ok": false, "reason": "stale_settlement_plan"}
	Snapshot.install_data(context.asset_ledger, plan.candidate_ledger)
	return plan.settlement.duplicate(true)


static func selection_preview(context, ending: String, selected_ids: Array = []) -> Dictionary:
	var limit := 0
	var additional := 0
	for effect in context.active_talent_effects:
		if str(effect.get("effect_kind", "")) == "consumable_retention":
			limit += int(effect.get("effect_amount", 0))
		elif str(effect.get("effect_kind", "")) == "failure_consumable_conversion_count":
			additional += int(effect.get("effect_amount", 0))
	if limit > 0 and ending != "success":
		limit += additional
	var pool: Array[Dictionary] = []
	var consumables: Array[Dictionary] = []
	var defaults: Array[String] = []
	for item: Dictionary in context.asset_ledger.get_inventory_and_equipped_items(true):
		if _consumable(item):
			if limit > 0 and not bool(item.get("used", false)) and int(item.get("counters", {}).get("uses", 0)) == 0:
				var candidate := item.duplicate(true)
				candidate["settlement_weight"] = 10
				pool.append(candidate)
				consumables.append(candidate)
		elif ending != "success" or str(item.get("location_state", "")) == "inventory":
			var candidate := item.duplicate(true)
			candidate["settlement_weight"] = int(item.weight)
			pool.append(candidate)
			defaults.append(str(item.instance_id))
	var weights: Dictionary = Economy.salvage_weights(context, ending, selected_ids)
	var total := 0
	if weights.get("ok", false):
		for id in weights.weights:
			if _consumable(context.asset_ledger.item_instances[id]):
				weights.weights[id] = 10
			total += int(weights.weights[id])
	return {"retention_limit": limit, "retention_candidates": consumables, "settlement_pool": pool,
		"default_selected_instance_ids": defaults if ending == "success" else [],
		"selected_salvage_weight": total, "settlement_weights": weights.get("weights", {}),
		"discounted_instance_id": weights.get("discounted_instance_id", ""),
		"salvage_capacity": context.asset_ledger.backpack_capacity if ending == "success" else context.asset_ledger.failure_salvage_capacity}


static func _validate_selection(context, ending: String, ids: Array, selection_required: bool) -> Dictionary:
	var display := selection_preview(context, ending, ids)
	var selected: Array = ids if selection_required else display.default_selected_instance_ids
	var lookup := {}
	for item: Dictionary in display.settlement_pool:
		lookup[str(item.instance_id)] = item
	var seen := {}
	var retained: Array[String] = []
	for raw_id: Variant in selected:
		if not raw_id is String or not lookup.has(raw_id) or seen.has(raw_id):
			return {"ok": false, "reason": "invalid_settlement_selection"}
		seen[raw_id] = true
		if _consumable(lookup[raw_id]):
			retained.append(str(raw_id))
	if retained.size() > int(display.retention_limit):
		return {"ok": false, "reason": "retention_limit_exceeded"}
	display = selection_preview(context, ending, selected)
	if int(display.selected_salvage_weight) > int(display.salvage_capacity):
		return {"ok": false, "reason": "selected_weight_exceeds_salvage_capacity", "selected_weight": display.selected_salvage_weight, "salvage_capacity": display.salvage_capacity}
	var discarded: Array[String] = []
	if ending == "success" and selection_required:
		for item: Dictionary in display.settlement_pool:
			if not _consumable(item) and not seen.has(str(item.instance_id)):
				discarded.append(str(item.instance_id))
	return {"ok": true, "include_consumables": int(display.retention_limit) > 0,
		"retained_consumable_ids": retained, "discarded_instance_ids": discarded,
		"settlement_weights": display.settlement_weights, "display": display}


static func selection_state(context, ending: String, ids: Array) -> Dictionary:
	var display := selection_preview(context, ending, ids)
	var checked := _validate_selection(context, ending, ids, true)
	display["ok"] = checked.ok
	display["reason"] = checked.get("reason", "")
	display["can_add"] = {}
	display["retained_count"] = 0
	for item: Dictionary in display.settlement_pool:
		var id := str(item.instance_id)
		if ids.has(id):
			display.can_add[id] = true
			if _consumable(item):
				display.retained_count += 1
		else:
			var candidate := ids.duplicate()
			candidate.append(id)
			display.can_add[id] = bool(_validate_selection(context, ending, candidate, true).ok)
	return display


static func _consumable(item: Dictionary) -> bool:
	return bool(item.get("can_consume", false)) or str(item.get("item_type", "")) == "consumable"
