extends SceneTree

const CATALOG_PATH := "res://scripts/core/progression/z2_goals/goal_catalog.gd"
const PROGRESSION_PATH := "res://scripts/core/progression/z2_goals/goal_progression.gd"
const MAP_7 := "classic_7x7_normal"
const MAP_10 := "classic_10x10_standard"
const MAP_13 := "classic_13x13_normal"
const HELL := "classic_13x13_hell"
const Maps := preload("res://scripts/core/content/m7_content_catalog.gd")

var catalog: Script
var goals: Script
var checks := 0
var case_count := 0
var serial := 0
var failures: Array[String] = []
var covered: Dictionary = {}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_check(ResourceLoader.exists(CATALOG_PATH), "catalog exists")
	_check(ResourceLoader.exists(PROGRESSION_PATH), "progression exists")
	if failures.is_empty():
		catalog = load(CATALOG_PATH)
		goals = load(PROGRESSION_PATH)
		_check(catalog != null and catalog.can_instantiate(), "catalog compiles")
		_check(goals != null and goals.can_instantiate(), "progression compiles")
		if failures.is_empty():
			_catalog()
			_progression_and_claims()
			_chronology_and_completeness()
			_runtime_fact_smoke()
			_main_quests()
			_side_quests()
			_achievements()
			_check(covered.size() == 50, "all 50 goal IDs exercised")
	for failure in failures:
		print("Z2_GOAL_CASE_FAIL " + failure)
	print("Z2_GOAL_ACCEPTANCE=%s goals=%d cases=%d checks=%d failures=%d" % [
		"PASS" if failures.is_empty() else "FAIL", covered.size(), case_count, checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _catalog() -> void:
	var all: Array = catalog.definitions()
	_check(all.size() == 50, "exactly 50 goals")
	var known := {}
	for row: Dictionary in all:
		_check(not known.has(row.id) and not row.display_name.is_empty(), "unique named row " + row.id)
		known[row.id] = true
	for spec: Array in [["main", 15, 1025, 1140], ["side", 10, 270, 355], ["achievement", 25, 0, 2765]]:
		var entries: Array = catalog.definitions(spec[0])
		var exp_value := 0
		var gold := 0
		for entry: Dictionary in entries:
			for tier: Dictionary in entry.milestones:
				exp_value += int(tier.reward.exp)
				gold += int(tier.reward.gold)
		_check(entries.size() == spec[1] and exp_value == spec[2] and gold == spec[3], "table rewards " + spec[0])


func _progression_and_claims() -> void:
	var meta: Dictionary = goals.initial_state({"tutorial_completed": false, "gold": 41, "profile_exp": 17})
	_check(_state(meta, "M01").status == "locked" and _state(meta, "A01").status == "locked", "teaching gates goals")
	var tutorial := _facts([], {"mode": "tutorial"})
	var outcome: Dictionary = goals.apply_settlement(meta, tutorial, "tutorial")
	_check(outcome.meta == meta and outcome.completions.is_empty(), "tutorial gives no task credit")
	meta.tutorial_completed = true
	meta = goals.activate_available(meta)
	_check(_state(meta, "M01").status == "active" and _state(meta, "A01").status == "active", "teaching opens M01 and all achievements")
	_check(_state(meta, "S01").status == "locked", "side waits for M01")

	var snapshot := _facts(_right_flags(3) + [_room(Vector2i(4, 1)), _use(true)], {"ending": "failure"})
	var preview := snapshot.duplicate(true)
	preview.finalized = false
	var rejected: Dictionary = goals.apply_settlement(meta, preview, "first")
	_check(not rejected.ok and rejected.meta == meta, "preview leaves progress intact")
	var first: Dictionary = goals.apply_settlement(meta, snapshot, "first")
	_check(first.ok and _done(first.meta, "M01"), "failure completes M01")
	_check(_state(first.meta, "M02").status == "active" and _state(first.meta, "S01").status == "active", "settlement opens next main and side")
	_check(not _done(first.meta, "M02") and not _done(first.meta, "S01"), "activation cannot consume same settlement")
	_check(first.meta.gold == 41 and first.meta.profile_exp == 17, "progress does not post reward")
	var receipt := _find_notice(first.completions, "M01")
	_check(receipt.get("receipt_id", "") != "" and receipt.get("tier", 0) == 1, "stable completion notice")
	_check(not receipt.get("committed", false), "candidate notice cannot be broadcast before the save")
	var retry: Dictionary = goals.apply_settlement(first.meta, snapshot, "first")
	_check(retry.ok and retry.meta == first.meta and retry.completions.is_empty(), "settlement retry has no new progress or notice")
	var conflicting: Dictionary = goals.apply_settlement(first.meta, snapshot, "other-result")
	_check(not conflicting.ok and conflicting.meta == first.meta, "same run different result rejects")
	var changed_facts := snapshot.duplicate(true)
	changed_facts.ending = "abandon"
	var changed: Dictionary = goals.apply_settlement(first.meta, changed_facts, "first")
	_check(not changed.ok and changed.meta == first.meta, "same receipt with changed facts rejects")
	var another_run: Dictionary = goals.apply_settlement(first.meta, _facts(), "first")
	_check(not another_run.ok and another_run.meta == first.meta, "same result ID cannot identify two runs")
	var incomplete := _facts()
	incomplete.run_events.clear()
	var missing_start: Dictionary = goals.apply_settlement(first.meta, incomplete, "missing-start")
	_check(not missing_start.ok and missing_start.meta == first.meta, "missing departure journal cannot award zero-mine achievement")
	var claimed: Dictionary = goals.claim_evaluation(first.meta, "M01")
	_check(claimed.ok and claimed.reward == {"exp": 10, "gold": 10}, "manual claim exposes full task award")
	_check(claimed.meta.gold == 41 and first.meta.gold == 41 and _state(first.meta, "M01").status == "claimable", "claim is a candidate for atomic save")
	var claim_retry: Dictionary = goals.claim_evaluation(first.meta, "M01")
	_check(claim_retry.reward_id == claimed.reward_id and claim_retry.meta == claimed.meta, "discarding unsaved candidate allows identical retry")
	var duplicate: Dictionary = goals.claim_evaluation(claimed.meta, "M01")
	_check(duplicate.ok and duplicate.reward.is_empty() and duplicate.meta == claimed.meta, "saved claim is idempotent")
	var restored: Dictionary = JSON.parse_string(JSON.stringify(claimed.meta))
	var after_reload: Dictionary = goals.claim_evaluation(restored, "M01")
	_check(after_reload.ok and after_reload.reward.is_empty(), "persisted numeric claim tier keeps idempotency")
	_check(_state(restored, "M01").status == "claimed", "status survives save round trip")

	var towards_state := _active("M03")
	towards_state.talent_flags = ["z2_talent_02", "z2_talent_03", "z2_talent_04"]
	var triggered: Dictionary = _submit(towards_state, _facts(_typed_rooms()))
	_check(_done(triggered.meta, "M03") and _done(triggered.meta, "M04"), "M04 checks existing talents when it opens")
	_check(_state(triggered.meta, "M05").status == "active", "state objective advances the main line")
	_check(not _find_notice(triggered.completions, "M04").is_empty(), "state objective completion has a receipt")

	var tier_meta: Dictionary = _submit(_active("A08"), _facts(_many_entries("Event", 110))).meta
	var third: Dictionary = goals.claim_evaluation(tier_meta, "A08", 3)
	_check(not third.ok, "locked tier cannot be claimed")
	var second: Dictionary = goals.claim_evaluation(tier_meta, "A08", 2)
	_check(second.ok and second.reward == {"exp": 0, "gold": 40}, "tier two claims separately")
	var tier_one: Dictionary = goals.claim_evaluation(second.meta, "A08", 1)
	_check(tier_one.ok and tier_one.reward.gold == 20 and tier_one.reward_id != second.reward_id, "tier one remains claimable")
	_check(_state(tier_one.meta, "A08").status == "active", "claimed lower tiers can keep progressing")
	var replayed: Dictionary = goals.claim_evaluation(second.meta, "A08", 2)
	_check(replayed.ok and replayed.reward.is_empty(), "tier replay cannot pay twice")


func _chronology_and_completeness() -> void:
	var m04 := _active("M04")
	m04.talent_flags = ["z2_talent_02", "z2_talent_03", "z2_talent_04"]
	var gear := [_gear("a", "eq_old_vest", "armor"), _gear("b", "eq_edge_opener", "tool"), _gear("c", "eq_recovery_bag", "rig")]
	var caught_up := _submit(m04, _facts([], {"run_start_config": _start(MAP_10, gear)}))
	_check(_done(caught_up.meta, "M04") and _state(caught_up.meta, "M05").status == "active",
		"M04 caught at settlement cannot let newly open M05 consume departure")

	var meta: Dictionary = goals.initial_state({"tutorial_completed": true})
	meta = _submit(meta, _facts([], {"departure_sequence": 1, "settlement_sequence": 5})).meta
	var qualifying := _right_flags(3) + [_room(Vector2i(4, 1))]
	var delayed := _submit(meta, _facts(qualifying, {"departure_sequence": 3, "settlement_sequence": 7}))
	_check(not _done(delayed.meta, "M02"), "M02 rejects a run that departed before its activation cursor")
	var timely := _submit(delayed.meta, _facts(qualifying, {"departure_sequence": 8, "settlement_sequence": 9}))
	_check(_done(timely.meta, "M02"), "M02 applies only newer whole-run behavior")
	var stale: Dictionary = goals.apply_settlement(timely.meta, _facts([], {"departure_sequence": 2, "settlement_sequence": 4}), "stale-run")
	_check(not stale.ok and stale.meta == timely.meta, "profile sequence must advance even for an unseen run ID")

	var a20 := _active("A20")
	var journal := _facts(_grid(13, 85) + [_use(true)], {"run_start_config": _start(MAP_13)})
	journal.run_events.back().sequence = 2
	var unordered: Dictionary = goals.apply_settlement(a20, journal, "unordered")
	_check(not unordered.ok and unordered.meta == a20, "out-of-order use cannot disappear and award A20")
	var incomplete := _facts(_grid(13, 85), {"run_start_config": _start(MAP_13), "consumable_evidence_complete": false})
	_check(not _done(_submit(a20, incomplete).meta, "A20"), "missing use telemetry cannot award A20")


func _runtime_fact_smoke() -> void:
	var context := RunContext.new()
	var start := _start(HELL)
	context.start_run(Maps.map_runtime_config(HELL, 581, start))
	var exits: Array = context.truth_map.exits.duplicate()
	_check(exits.size() == 1, "real hell map has one exit")
	if exits.is_empty():
		return
	context.player_pos = exits[0]
	context.current_pos = exits[0]
	var resolver := RoomResolver.new()
	var entered := resolver.enter_room(context)
	_check(entered.get("ok", false), "real room resolver records an exit visit")
	var capacity_before := context.asset_ledger.get_capacity_snapshot()
	var lifecycle := RunStateMachine.new()
	_check(lifecycle.request_extract(context, true).get("ok", false), "real request enters extraction confirmation")
	var settled := lifecycle.confirm_extract(context, true)
	_check(settled.get("ok", false), "real extractor commits an outcome")
	if not settled.get("ok", false):
		return
	var snapshot: Dictionary = settled.result_snapshot.RunResult
	var facts := {"run_id": str(snapshot.run_id), "mode": snapshot.mode, "finalized": snapshot.terminal,
		"ending": str(snapshot.settlement.outcome), "run_start_config": snapshot.run_start_config,
		"run_events": snapshot.run_events, "exits": exits, "capacity_before_settlement": capacity_before}
	_check(_done(_submit(_active("M14"), facts).meta, "M14"), "M14 consumes actual RunResult and RunEventLog without test-only events")
	_check(_done(_submit(_active("M06"), facts).meta, "M06"), "M06 consumes actual exit arrival on a hidden-only map")


func _main_quests() -> void:
	_case("M01", _facts([], {"ending": "abandon"}), _facts([], {"mode": "tutorial"}))
	_case("M02", _facts(_right_flags(3) + [_room(Vector2i(4, 1))]), _facts(
		[_room(Vector2i(4, 1))] + _right_flags(2) + [_flag(Vector2i(1, 1), true), _flag(Vector2i(3, 1), true, true, true), _room(Vector2i(4, 1))]))
	var prior_flags: Dictionary = _submit(_active("M02"), _facts(_right_flags(2), {"ending": "failure"})).meta
	var final_flag: Dictionary = _submit(prior_flags, _facts([_flag(Vector2i(3, 1), true), _room(Vector2i(4, 1))])).meta
	_check(not _done(final_flag, "M02"), "M02 cannot combine flags across two runs")
	_case("M03", _facts(_typed_rooms(), {"ending": "failure"}), _facts(_typed_rooms().slice(0, 8)))
	var m04 := _active("M04")
	m04.talent_flags = ["z2_talent_01", "z2_talent_02", "z2_talent_03", "z2_talent_03", "old_flag"]
	m04 = goals.activate_available(m04)
	_check(not _done(m04, "M04"), "M04 excludes teaching, duplicates and old node")
	m04.talent_flags.append("z2_talent_04")
	var trained: Dictionary = goals.apply_camp_action(m04, {"sequence": 1, "kind": "unlock_talent"})
	_state_case("M04", _done(trained.meta, "M04"), "M04 checks three current distinct non-teaching nodes after purchase")

	var gear := [_gear("start-a", "eq_old_vest", "armor"), _gear("start-b", "eq_edge_opener", "tool")]
	var start := _start(MAP_10, gear, [], [_gear("start-c", "eq_recovery_bag", "rig")])
	_case("M05", _facts([], {"run_start_config": start}), _facts(
		[_event("item_picked_up", {"item": _gear("new", "eq_recovery_bag", "rig")})],
		{"run_start_config": _start(MAP_10, gear)}))
	_check(not _done(_submit(_active("M05"), _facts([], {"run_start_config": start, "ending": "failure"})).meta, "M05"), "M05 requires success")
	var exit_room := Vector2i(6, 6)
	_case("M06", _facts([_room(exit_room, "Exit")], {
		"run_start_config": _start(MAP_7), "exits": [exit_room], "hidden_exits_at_start": [exit_room], "ending": "abandon"}),
		_facts([_event("extraction_found", {"position": exit_room, "exit_id": "random_1"})], {
			"run_start_config": _start(MAP_7), "exits": [exit_room], "hidden_exits_at_start": [exit_room]}))
	_check(not _done(_submit(_active("M06"), _facts([_room(exit_room, "Exit")], {
		"run_start_config": _start(MAP_7), "exits": [exit_room], "hidden_exits_at_start": []})).meta, "M06"), "M06 excludes an exit shown at start")
	_cumulative("M07", [_facts(), _facts(), _facts([], {"ending": "failure"})], _facts())
	var old := _loot("already-carried", 1, 900)
	var m08 := _active("M08")
	var initial: Dictionary = _submit(m08, _facts([], {"ending": "failure",
		"run_start_config": _start(MAP_10, [], [], [], [old]),
		"warehouse_items": [old, _loot("rescued", 3, 120), _loot("rescued", 3, 120)]})).meta
	_check(_state(initial, "M08").progress == 120, "M08 excludes start items and repeated instance")
	var final: Dictionary = _submit(initial, _facts([], {"ending": "abandon",
		"warehouse_items": [_loot("delivered", 4, 180)], "items_before_settlement": {"delivered": {"location_state": "consigned"}}})).meta
	_state_case("M08", _done(final, "M08"), "M08 combines actually stored loot across endings")
	_case("M09", _facts(_searches(10)), _facts(_searches(9) + [_event("room_searched", {"position": Vector2i(0, 1), "is_chest": false}), _event("room_searched", {"position": Vector2i(9, 1), "is_chest": true})]))
	_case("M10", _facts(_wins(3)), _facts(_wins(2) + [
		_event("combat_resolved", {"position": Vector2i(3, 3), "runtime": true, "cage": true}),
		_event("combat_resolved", {"position": Vector2i(3, 4), "runtime": true, "automatic": true})]))
	_case("M11", _facts([], {"run_start_config": _start(MAP_13)}), _facts())
	_case("M12", _facts([], {"run_start_config": _with_effect(MAP_10, "trade", 1)}),
		_facts([], {"run_start_config": _with_effect(MAP_10, "future", 2)}))
	var high_tiers := [_loot("a", 4, 20), _loot("b", 5, 20), _loot("c", 6, 20)]
	_case("M13", _facts([], {"warehouse_items": high_tiers, "items_before_settlement": _loot_locations(high_tiers)}),
		_facts([], {"warehouse_items": high_tiers, "items_before_settlement": _loot_locations(high_tiers, "c")}))
	for row: Array in [[MAP_13, 4], ["classic_13x13_hard", 2], [HELL, 1]]:
		var exits: Array = []
		var visited: Array = []
		for i in range(row[1]):
			var pos := Vector2i(1, i + 1)
			exits.append(pos)
			visited.append(_room(pos, "Exit"))
		var fields := {"run_start_config": _start(row[0]), "exits": exits}
		var escape := _event("extraction_success", {"position": exits.back(), "exit_id": "exit_%d" % row[1]})
		_case("M14", _facts(visited + [escape], fields), _facts(visited.slice(0, -1) + [escape], fields))
	var tier_six := [_loot("a", 6, 20), _loot("b", 6, 20)]
	_case("M15", _facts([], {"warehouse_items": tier_six, "run_start_config": _start(MAP_10, [], [], [], [tier_six[0]]),
		"items_before_settlement": _loot_locations(tier_six)}),
		_facts([], {"warehouse_items": tier_six, "items_before_settlement": _loot_locations(tier_six, "b")}))


func _side_quests() -> void:
	_case("S01", _facts([_use(true)], {"ending": "abandon"}), _facts([_use(false)]))
	_cumulative("S02", [_facts([_pressure(-8, "consumable")], {"ending": "failure"}),
		_facts([_pressure(-11, "event"), _pressure(-30, "talent")], {"ending": "abandon"})], _facts([_pressure(-1, "event")]))
	var meta := _active("S03")
	var sale := {"sequence": 2, "kind": "sell_collectible", "item": _loot("sold", 2, 40)}
	var old_purchase := {"sequence": 1, "kind": "purchase", "item": _gear("bought-early", "eq_old_vest", "armor")}
	meta = goals.apply_camp_action(meta, old_purchase).meta
	meta = goals.apply_camp_action(meta, sale).meta
	var too_early := _facts([], {"run_start_config": _start(MAP_10, [old_purchase.item])})
	meta = _submit(meta, too_early).meta
	_check(not _done(meta, "S03"), "S03 earlier purchase cannot satisfy sale first")
	var acquired := _gear("correct-instance", "eq_old_vest", "armor")
	meta = goals.apply_camp_action(meta, {"sequence": 3, "kind": "purchase", "items": [
		_gear("other-batch-instance", "eq_edge_opener", "tool"), acquired]}).meta
	_check(not _done(_submit(meta, _facts([], {"run_start_config": _start(MAP_10, [
		_gear("different-instance", "eq_old_vest", "armor")])})).meta, "S03"), "S03 same definition with other instance does not count")
	_state_case("S03", _done(_submit(meta, _facts([], {"run_start_config": _start(MAP_10, [acquired])})).meta, "S03"),
		"S03 sell, buy and take the purchased instance")
	_case("S04", _facts([], {"run_start_config": _with_effect(MAP_7, "trade", 1), "ending": "failure"}), _facts())
	_cumulative("S05", [_facts([], {"run_start_config": _start(MAP_7, [_gear("a", "eq_old_vest", "armor")]), "ending": "failure"}),
		_facts([], {"run_start_config": _start(MAP_7, [_gear("a2", "eq_old_vest", "armor")])}),
		_facts([], {"run_start_config": _start(MAP_7, [_gear("b", "eq_goggles", "head")])})],
		_facts([], {"run_start_config": _start(MAP_7, [_gear("c", "eq_strapped_backplate", "armor")]), "ending": "abandon"}))
	_case("S06", _facts([_event("work_order_paid", {"contract_id": "work-1", "new_room_count": 3, "payout": 12})]),
		_facts([_event("work_order_paid", {"contract_id": "work-1", "new_room_count": 2, "payout": 12})]))
	var s07 := _active("S07")
	s07.research_completed_ids = ["research_protocol_formula"]
	s07 = goals.activate_available(s07)
	_check(not _done(s07, "S07"), "S07 excludes old research")
	s07.research_completed_ids.append("research_red_battery")
	var researched: Dictionary = goals.apply_camp_action(s07, {"sequence": 1, "kind": "complete_research"})
	_state_case("S07", _done(researched.meta, "S07"), "S07 checks an actual completed Z2 research")
	var received := _event("recovery_collected", {"position": Vector2i(2, 2), "instance_id": "material-a"})
	_case("S08", _facts([received, _event("recovery_delivered", {"position": Vector2i(3, 2), "instance_id": "material-a", "payout": 5})]),
		_facts([received, _event("recovery_delivered", {"position": Vector2i(3, 2), "instance_id": "material-b", "payout": 5})]))
	_check(not _done(_submit(_active("S08"), _facts([received, _event("recovery_delivered", {
		"position": Vector2i(2, 2), "instance_id": "material-a", "payout": 5})])).meta, "S08"), "S08 requires a different point")
	var output := _loot("crafted", 2, 10)
	var compressed := _event("compression_completed", {"inputs": [_loot("in1", 1, 5), _loot("in2", 1, 5)], "output": output})
	_case("S09", _facts([compressed, _event("item_picked_up", {"item": output})]),
		_facts([compressed, _event("item_picked_up", {"item": _loot("other", 2, 10)})]))
	_case("S10", _facts([], {"ending": "abandon", "warehouse_items": [_loot("shipment", 4, 10)],
		"items_before_settlement": {"shipment": {"location_state": "consigned"}}}),
		_facts([], {"warehouse_items": [_loot("shipment", 4, 10)], "items_before_settlement": {"shipment": {"location_state": "inventory"}}}))
	_check(not _done(_submit(_active("S10"), _facts([], {"items_before_settlement": {
		"shipment": {"location_state": "consigned"}}})).meta, "S10"), "S10 delivery must actually enter warehouse")


func _achievements() -> void:
	var first_mine := [_room(Vector2i(1, 0), "Mine"), _event("mine_triggered", {"position": Vector2i(1, 0)})]
	_case("A01", _facts([], {"ending": "failure"}), _facts(first_mine))
	_case("A02", _facts([_event("power_changed", {"power": 100})], {"power": 40}),
		_facts([_event("power_changed", {"power": 99})]))
	_case("A03", _facts(_grid(10, 100)), _facts(_grid(10, 99) + [_event("intel_revealed", {"position": Vector2i(9, 9)})]))
	_case("A04", _facts([], {"capacity_before_settlement": {"used": 120, "capacity": 120,
		"equipment_used": 103, "equipment_capacity": 103}}),
		_facts([], {"capacity_before_settlement": {"used": 120, "capacity": 120,
			"equipment_used": 102, "equipment_capacity": 103}}))
	_case("A05", _facts([], {"black_coin_gold": 250, "warehouse_items": [_loot("value", 5, 750)]}),
		_facts([], {"black_coin_gold": 249, "safe_gold": 99, "warehouse_items": [_loot("value", 5, 750)]}))
	var after := [_room(Vector2i(0, 1)), _pressure(100, "room")]
	for i in range(10):
		after.append(_room(Vector2i(i, 2)))
	_case("A06", _facts(after), _facts(after.slice(0, -1) + [_room(Vector2i(0, 2))]))
	var damage := _event("vitals_damage", {"absorbed": 60})
	var double_logged := _event("runtime_combat_damage", {"facts": [{"absorbed": 60}]})
	_case("A07", _facts([damage, _event("vitals_damage", {"absorbed": 40})], {"shield": 0}),
		_facts([damage, double_logged], {"shield": 110}))
	_check(not _done(_submit(_active("A07"), _facts([_event("vitals_damage", {"absorbed": 100})], {"ending": "failure"})).meta, "A07"), "A07 requires success")
	for entry: Array in [["A08", "Event", 200], ["A09", "Monster", 300], ["A10", "Chest", 200]]:
		_case(entry[0], _facts(_many_entries(entry[1], 50)), _facts(_many_entries(entry[1], 49)))
		var multi: Dictionary = _submit(_active(entry[0]), _facts(_many_entries(entry[1], entry[2]), {"ending": "abandon"}))
		_check(_state(multi.meta, entry[0]).achieved_tiers.size() == 3, entry[0] + " three thresholds")
	_case("A11", _facts([], {"pressure": 0}), _facts([], {"pressure": 0, "ending": "failure"}))
	_case("A12", _facts([], {"run_start_config": _start(HELL), "hp": 125, "max_hp": 125}),
		_facts([], {"run_start_config": _start(HELL), "hp": 124, "max_hp": 125}))
	_case("A13", _facts(first_mine, {"ending": "abandon"}), _facts([_room(Vector2i(0, 1))] + first_mine))
	_check(not _done(_submit(_active("A13"), _facts([_room(Vector2i(1, 0), "Mine")])).meta, "A13"), "A13 a spent mine is not a trigger")
	var mines: Array = []
	for i in range(1, 6):
		mines.append(_room(Vector2i(i, 1), "Mine"))
		mines.append(_event("mine_triggered", {"position": Vector2i(i, 1)}))
	_case("A14", _facts(mines), _facts(mines.slice(0, 4) + [_room(Vector2i(6, 6))] + mines.slice(4)))
	_case("A15", _facts(_altar(false)), _facts(_altar(true)))
	_case("A16", _facts(_dice(false)), _facts(_dice(true)))
	var first_interest := _event("savings_withdrawn", {"transaction_id": "deposit-a", "principal": 250, "withdrawn": 300})
	var second_interest := _event("savings_withdrawn", {"transaction_id": "deposit-b", "principal": 250, "withdrawn": 300})
	_case("A17", _facts([_event("savings_withdrawn", {"transaction_id": "deposit-full", "principal": 500, "withdrawn": 600})]),
		_facts([first_interest, second_interest]))
	var collection: Array = []
	for i in range(20):
		collection.append(_loot("registered-%d" % i, 1 + i % 6, 10))
	var partial := collection.duplicate(true)
	partial[5].tier = 1
	partial[11].tier = 1
	partial[17].tier = 1
	_case("A18", _facts([], {"registered_collectibles": collection}), _facts([], {"registered_collectibles": partial}))
	_case("A19", _facts(_grid(10, 50)),
		_facts(_grid(10, 50), {"run_start_config": _start(MAP_10, [_gear("one", "eq_old_vest", "armor")])}))
	_case("A20", _facts(_grid(13, 85), {"run_start_config": _start(MAP_13)}),
		_facts(_grid(13, 85) + [_use(false)], {"run_start_config": _start(MAP_13)}))
	_check(not _done(_submit(_active("A20"), _facts(_grid(13, 84), {"run_start_config": _start(MAP_13)})).meta, "A20"), "13 map half needs 85 visited")
	_case("A21", _facts([_event("combat_resolved", {"position": Vector2i(3, 3), "runtime": true, "cage": true})]), _facts(_wins(3)))
	var all_tiers: Array = []
	for i in range(1, 7):
		all_tiers.append(_loot("tier%d" % i, i, 1))
	_case("A22", _facts([], {"warehouse_items": all_tiers, "items_before_settlement": _loot_locations(all_tiers, "tier6")}),
		_facts([], {"warehouse_items": all_tiers.slice(0, 5), "items_before_settlement": _loot_locations(all_tiers, "tier6")}))
	_check(not _done(_submit(_active("A22"), _facts([], {"warehouse_items": all_tiers, "ending": "abandon"})).meta, "A22"), "A22 requires success even with all six delivered")
	_case("A23", _facts(_grid(10, 50), {"hp": 12, "max_hp": 120}), _facts(_grid(10, 50), {"hp": 13, "max_hp": 120}))
	_cumulative("A24", [_facts([], {"run_start_config": _with_effect(MAP_7, "trade", 1)}),
		_facts([], {"run_start_config": _with_effect(MAP_10, "retaliation", 1)}),
		_facts([], {"run_start_config": _with_effect(MAP_13, "trade", 1)}),
		_facts([], {"run_start_config": _with_effect(MAP_10, "trade", 1)})],
		_facts([], {"run_start_config": _with_effect(MAP_7, "avoid", 1)}))
	var incorrect := _flag(Vector2i(5, 2), false)
	_case("A25", _facts(_right_flags(10) + [incorrect, _flag(Vector2i(5, 2), false, false)]),
		_facts(_right_flags(10) + [incorrect]))
	_check(not _done(_submit(_active("A25"), _facts(_right_flags(9) + [_flag(Vector2i(9, 1), true)])).meta, "A25"), "A25 repeated placement gives no distinct room")


func _case(id: String, positive: Dictionary, negative: Dictionary) -> void:
	var meta := _active(id)
	var rejected := _submit(meta, negative)
	_check(not _done(rejected.meta, id), id + " rejects near miss")
	var accepted := _submit(meta, positive)
	_state_case(id, _done(accepted.meta, id), id + " commits qualifying facts")
	_check(not _find_notice(accepted.completions, id).is_empty(), id + " emits completion with stable identity")


func _state_case(id: String, passed: bool, label: String) -> void:
	covered[id] = true
	case_count += 1
	_check(passed, label)


func _cumulative(id: String, before: Array, last: Dictionary) -> void:
	var meta := _active(id)
	for facts: Dictionary in before:
		meta = _submit(meta, facts).meta
		_check(not _done(meta, id), id + " stays active below the threshold")
	var result := _submit(meta, last)
	_state_case(id, _done(result.meta, id), id + " combines eligible completed runs")


func _submit(meta: Dictionary, facts: Dictionary) -> Dictionary:
	var result: Dictionary = goals.apply_settlement(meta, facts, str(facts.run_id) + ":final")
	_check(result.ok, "accepts final run " + str(facts.run_id))
	return result


func _active(id: String) -> Dictionary:
	var target: Dictionary = catalog.definition(id)
	var meta: Dictionary = goals.initial_state({"tutorial_completed": true, "first_opening_batch_unlocked": true})
	if target.kind == "achievement":
		return meta
	var index := int(target.get("required_main", 0))
	var states: Dictionary = meta.z2_goals.states
	for i in range(1, index + 1):
		states["M%02d" % i] = {"unlocked": true, "progress": int(catalog.definition("M%02d" % i).milestones[0].target), "claimed_tiers": [], "evidence": {}}
	return goals.activate_available(meta)


func _done(meta: Dictionary, id: String) -> bool:
	return not _state(meta, id).achieved_tiers.is_empty()


func _state(meta: Dictionary, id: String) -> Dictionary:
	return goals.goal_state(meta, id)


func _find_notice(notices: Array, id: String) -> Dictionary:
	for n: Dictionary in notices:
		if n.get("goal_id", "") == id:
			return n
	return {}


func _facts(raw_events: Array = [], changes: Dictionary = {}) -> Dictionary:
	serial += 1
	var entries: Array = [_event("run_started", {"position": Vector2i.ZERO})]
	entries.append_array(raw_events)
	for i in range(entries.size()):
		entries[i] = entries[i].duplicate(true)
		entries[i]["sequence"] = i + 1
		entries[i]["event_id"] = "evt_%d" % i
	var facts := {"run_id": "run-%d" % serial, "finalized": true, "mode": "standard",
		"ending": "success", "run_start_config": _start(MAP_10), "run_events": entries, "consumable_evidence_complete": true,
		"hp": 90, "max_hp": 100, "pressure": 45, "power": 20}
	facts.merge(changes, true)
	return facts


func _start(map_id: String, worn: Array = [], consumables: Array = [], carried_equipment: Array = [], starting_items: Array = []) -> Dictionary:
	return {"map_config_id": map_id, "selected_equipment_items": worn, "selected_consumable_ids": consumables,
		"carried_equipment_items": carried_equipment, "starting_items": starting_items}


func _with_effect(map_id: String, id: String, batch: int) -> Dictionary:
	var start := _start(map_id)
	start.opening_effect = {"id": id, "batch": batch}
	return start


func _event(kind: String, payload: Dictionary) -> Dictionary:
	return {"event_type": kind, "source": "acceptance_fixture", "actor_id": "player", "payload": payload}


func _room(pos: Vector2i, kind: String = "Normal") -> Dictionary:
	return _event("room_entered", {"position": pos, "room_type": kind})


func _flag(pos: Vector2i, mine: bool, enabled: bool = true, triggered: bool = false) -> Dictionary:
	return _event("manual_flag_changed", {"position": pos, "is_mine": mine, "enabled": enabled, "triggered": triggered})


func _right_flags(count: int) -> Array:
	var entries: Array = []
	for i in range(1, count + 1):
		entries.append(_flag(Vector2i(i % 10, 1 + i / 10), true))
	return entries


func _gear(id: String, item_id: String, slot: String) -> Dictionary:
	return {"instance_id": id, "item_id": item_id, "item_type": "equipment", "equipment_slot": slot}


func _loot(id: String, tier: int, value: int) -> Dictionary:
	return {"instance_id": id, "item_id": "col_" + id, "item_type": "collectible", "tier": tier, "base_value": value, "weight": 10}


func _loot_locations(items: Array, consigned: String = "") -> Dictionary:
	var places := {}
	for item: Dictionary in items:
		places[item.instance_id] = {"location_state": "consigned" if item.instance_id == consigned else "inventory"}
	return places


func _use(effective: bool) -> Dictionary:
	return _event("consumable_used", {"instance_id": "used-supply", "effective": effective})


func _pressure(delta: int, origin: String) -> Dictionary:
	return _event("vitals_pressure", {"actual_pressure_delta": delta, "origin": origin})


func _typed_rooms() -> Array:
	var entries: Array = []
	for i in range(3):
		entries.append(_room(Vector2i(1, i + 1), "Event"))
		entries.append(_room(Vector2i(2, i + 1), "Monster"))
		entries.append(_room(Vector2i(3, i + 1), "Chest"))
	return entries


func _many_entries(kind: String, count: int) -> Array:
	var entries: Array = []
	for i in range(count):
		entries.append(_room(Vector2i(1 + i % 2, 1), kind))
	return entries


func _searches(count: int) -> Array:
	var entries: Array = []
	for i in range(count):
		entries.append(_event("room_searched", {"position": Vector2i(i, 1), "is_chest": false}))
	return entries


func _wins(count: int) -> Array:
	var entries: Array = []
	for i in range(count):
		entries.append(_event("combat_resolved", {"position": Vector2i(i + 1, 1), "runtime": true}))
	return entries


func _grid(size: int, cells: int) -> Array:
	var entries: Array = []
	for i in range(1, cells):
		entries.append(_room(Vector2i(i % size, i / size), "Mine" if i == 1 else "Normal"))
	return entries


func _altar(split: bool) -> Array:
	var entries: Array = []
	for stage in range(1, 6):
		var position := Vector2i(1, 1) if not split or stage < 5 else Vector2i(1, 2)
		entries.append(_event("altar_offered", {"position": position, "tier": stage}))
	return entries


func _dice(split: bool) -> Array:
	var entries: Array = []
	for i in range(1, 4):
		var position := Vector2i(1, 1) if not split or i < 3 else Vector2i(1, 2)
		entries.append(_event("dice_round_settled", {"position": position, "round": i, "won": true}))
	return entries


func _check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)
