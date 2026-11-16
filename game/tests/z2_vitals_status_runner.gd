extends SceneTree

const Vitals := preload("res://scripts/core/run/run_vitals_resolver.gd")
const Statuses := preload("res://scripts/core/run/run_status_service.gd")
const Protocol := preload("res://scripts/core/run/protocol_service.gd")
const Context := preload("res://scripts/core/run/run_context.gd")

var failures: Array[String] = []
var checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_physical_order()
	_test_effective_damage_counters()
	_test_damage_types()
	_test_blackbell()
	_test_survival_and_sequential_hits()
	_test_full_payments()
	_test_healing_order()
	_test_pressure_order()
	_test_pressure_effective_counters()
	_test_status_activation_and_limits()
	_test_status_identity_and_clearing()
	_test_status_time()
	_test_immutability_and_rejections()
	_test_protocol_costs_and_compatibility()
	for failure in failures:
		print("Z2_VITALS_STATUS_CASE_FAIL " + failure)
	print("Z2_VITALS_STATUS=%s checks=%d failures=%d" % ["PASS" if failures.is_empty() else "FAIL", checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _state(hp: int = 100, shield: int = 0, pressure: int = 0) -> Dictionary:
	return {"hp": hp, "max_hp": 100, "shield": shield, "pressure": pressure, "protocol_level": 5, "counters": {}, "statuses": []}


func _check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append(label)


func _fact(result: Dictionary, key: String) -> Variant:
	return result.get("facts", {}).get(key, null)


func _test_physical_order() -> void:
	var result := Vitals.resolve_damage(_state(), {
		"amount": 100, "percent_reductions": [{"rate": 0.05}, {"rate": 0.1}, {"rate": 0.1}, {"rate": 0.5}],
		"flat_blocks": [{"amount": 10}],
	})
	_check(result.ok and result.state.hp == 72, "physical_multiply_then_floor_once_28")
	_check(_fact(result, "resolved_damage") == 28 and _fact(result, "actual_hp_loss") == 28, "physical_actual_facts_28")
	result = Vitals.resolve_damage(_state(), {"amount": 20, "percent_reductions": [{"rate": 0.1}], "minimum_blocks": [{"amount": 5}, {"amount": 8}], "flat_blocks": [{"amount": 2}]})
	_check(result.state.hp == 90, "minimum_block_highest_total_not_sum_or_extra")
	result = Vitals.resolve_damage(_state(), {"amount": 20, "percent_reductions": [{"rate": 0.5}], "minimum_blocks": [{"amount": 8}]})
	_check(result.state.hp == 90, "percentage_block_already_above_minimum")
	result = Vitals.resolve_damage(_state(), {"amount": 1, "flat_blocks": [{"amount": 999}]})
	_check(result.state.hp == 99, "positive_physical_minimum_one")
	result = Vitals.resolve_damage(_state(100, 1), {"amount": 0.01, "flat_blocks": [{"amount": 999}]})
	_check(result.state.hp == 100 and result.state.shield == 0, "minimum_one_before_shield")
	result = Vitals.resolve_damage(_state(), {"amount": 0, "flat_blocks": [{"amount": 999}]})
	_check(result.state.hp == 100 and _fact(result, "resolved_damage") == 0, "zero_incoming_not_raised_to_one")


func _test_effective_damage_counters() -> void:
	var state := _state()
	state.counters = {"visor": 2, "low": 1, "high": 1}
	var packet := {"amount": 10, "flat_blocks": [{"amount": 3, "counter_key": "visor"}]}
	var result := Vitals.resolve_damage(state, packet)
	_check(result.state.hp == 93 and result.state.counters.visor == 1, "effective_flat_charge")
	result = Vitals.resolve_damage(result.state, packet)
	_check(result.state.hp == 86 and result.state.counters.visor == 0, "last_flat_charge")
	result = Vitals.resolve_damage(result.state, packet)
	_check(result.state.hp == 76 and result.state.counters.visor == 0, "exhausted_modifier_inactive")
	result = Vitals.resolve_damage(state, {"amount": 1, "flat_blocks": [{"amount": 3, "counter_key": "visor"}]})
	_check(result.state.hp == 99 and result.state.counters.visor == 2, "floor_erases_benefit_no_charge")
	result = Vitals.resolve_damage(state, {"amount": 20, "minimum_blocks": [{"amount": 5, "counter_key": "low"}, {"amount": 8, "counter_key": "high"}]})
	_check(result.state.hp == 88 and result.state.counters.low == 1 and result.state.counters.high == 0, "only_winning_minimum_costs_charge")
	result = Vitals.resolve_damage(state, {"amount": 20, "flat_blocks": [{"amount": 20, "counter_key": "low"}, {"amount": 20, "counter_key": "high"}]})
	_check(result.state.hp == 99 and result.state.counters.low == 0 and result.state.counters.high == 1, "redundant_flat_charges_stable_first_wins")
	result = Vitals.resolve_damage(_state(3), {"amount": 20, "flat_blocks": [{"amount": 2, "counter_key": "missing"}]})
	_check(result.state.hp == 0 and _fact(result, "actual_hp_loss") == 3, "missing_counter_inactive_actual_loss_capped")
	state = _state(3, 5)
	state.counters.visor = 1
	result = Vitals.resolve_damage(state, {"amount": 20, "flat_blocks": [{"amount": 10, "counter_key": "visor"}]})
	_check(result.state.hp == 0 and result.state.shield == 0 and result.state.counters.visor == 1, "overkill_same_actual_losses_no_mitigation_charge")


func _test_damage_types() -> void:
	for kind in ["mine", "dot"]:
		var state := _state(30, 20)
		state.counters = {"bell": 1, "visor": 1}
		var result := Vitals.resolve_damage(state, {"amount": 12, "damage_type": kind, "percent_reductions": [{"rate": 1.0, "counter_key": "visor"}], "flat_blocks": [{"amount": 99}], "blackbell": {"eligible": false, "counter_key": "bell"}})
		if kind == "mine":
			_check(result.state.hp == 30 and result.state.shield == 8 and _fact(result, "absorbed") == 12, "mine_ignores_physical_blocks_but_uses_shield")
		else:
			_check(result.state.hp == 18 and result.state.shield == 20 and _fact(result, "absorbed") == 0, "dot_bypasses_shield_and_physical_blocks")
		_check(result.state.counters.visor == 1, "nonphysical_does_not_charge_physical_modifier_" + kind)
	var state := _state(30, 20)
	state.counters.bell = 1
	var result := Vitals.resolve_damage(state, {"amount": 12, "damage_type": "dot", "blackbell": {"eligible": true, "counter_key": "bell"}})
	_check(result.state.hp == 18 and result.state.shield == 20 and result.state.counters.bell == 1, "dot_never_triggers_blackbell")


func _test_blackbell() -> void:
	for fixture in [[0, 10, 40, 0], [39, 10, 1, 0], [40, 10, 0, 1], [65, 10, 0, 1]]:
		var state := _state(50, fixture[0])
		state.counters.bell = 1
		var result := Vitals.resolve_damage(state, {"amount": fixture[1], "blackbell": {"eligible": true, "counter_key": "bell"}})
		_check(result.state.hp == 50 and result.state.shield == fixture[0] + fixture[2] - 10, "bell_topup_boundary_%d" % fixture[0])
		_check(_fact(result, "shield_added") == fixture[2] and result.state.counters.bell == fixture[3], "bell_charge_boundary_%d" % fixture[0])
	var state := _state(50)
	state.counters.bell = 1
	var result := Vitals.resolve_damage(state, {"amount": 0, "blackbell": {"eligible": true, "counter_key": "bell"}})
	_check(result.state.shield == 0 and result.state.counters.bell == 1, "bell_not_on_zero_hit")
	result = Vitals.resolve_damage(state, {"amount": 45, "damage_type": "mine", "blackbell": {"eligible": true, "counter_key": "bell"}})
	_check(result.state.hp == 45 and _fact(result, "absorbed") == 40, "bell_direct_mine_before_absorption")


func _test_survival_and_sequential_hits() -> void:
	var state := _state(10)
	state.counters = {"talent": 1, "item": 1}
	var packet := {"amount": 20, "survivals": [{"source_id": "potion", "kind": "item", "counter_key": "item", "hp": 5}, {"source_id": "talent", "kind": "talent", "counter_key": "talent", "hp": 1}]}
	var result := Vitals.resolve_damage(state, packet)
	_check(result.state.hp == 1 and result.state.counters.talent == 0 and result.state.counters.item == 1, "one_survival_talent_priority_over_list_order")
	_check(_fact(result, "survival_source") == "talent" and _fact(result, "actual_hp_loss") == 9 and _fact(result, "dead") == false, "survival_facts_actuals")
	packet.amount = 2
	result = Vitals.resolve_damage(result.state, packet)
	_check(result.state.hp == 5 and result.state.counters.item == 0, "next_hit_observes_consumed_talent")
	result = Vitals.resolve_damage(result.state, {"amount": 8})
	_check(result.state.hp == 0 and _fact(result, "actual_hp_loss") == 5 and _fact(result, "dead") == true, "lethal_facts_remain_available")
	state.hp = 0
	result = Vitals.resolve_damage(state, packet)
	_check(result.state.hp == 0 and result.state.counters == state.counters, "damage_cannot_resurrect_dead_state")
	state = _state(10, 20)
	state.counters.talent = 1
	result = Vitals.resolve_damage(state, {"amount": 10, "survivals": [{"source_id": "talent", "kind": "talent", "counter_key": "talent"}]})
	_check(result.state.hp == 10 and result.state.counters.talent == 1, "shield_prevents_unneeded_survival_charge")


func _test_full_payments() -> void:
	var state := _state(10, 50)
	state.counters = {"talent": 1, "bell": 1}
	var packet := {"amount": 10, "damage_type": "hp_payment", "blackbell": {"eligible": true, "counter_key": "bell"}, "survivals": [{"source_id": "talent", "kind": "talent", "counter_key": "talent"}]}
	var result := Vitals.resolve_damage(state, packet)
	_check(not result.ok and result.reason == "insufficient_hp" and result.state == state, "hp_payment_full_or_reject_no_survival")
	packet.amount = 9
	result = Vitals.resolve_damage(state, packet)
	_check(result.ok and result.state.hp == 1 and result.state.shield == 50 and result.state.counters == state.counters, "hp_payment_leaves_one_bypasses_all_protection")
	_check(_fact(result, "paid") == 9 and _fact(result, "absorbed") == 0, "payment_actual_facts")
	state.hp = 98
	result = Vitals.resolve_damage(state, {"amount": 5, "damage_type": "max_hp_payment"})
	_check(result.ok and result.state.max_hp == 95 and result.state.hp == 95 and result.state.shield == 50, "max_hp_payment_clamps_absolute_hp")
	state.hp = 40
	result = Vitals.resolve_damage(state, {"amount": 5, "damage_type": "max_hp_payment"})
	_check(result.state.max_hp == 95 and result.state.hp == 40, "max_hp_payment_no_free_heal_or_ratio")
	result = Vitals.resolve_damage(state, {"amount": 100, "damage_type": "max_hp_payment"})
	_check(not result.ok and result.reason == "insufficient_max_hp" and result.state == state, "max_hp_payment_rejects_partial_payment")
	result = Vitals.resolve_damage(state, {"amount": 99, "damage_type": "max_hp_payment"})
	_check(result.ok and result.state.max_hp == 1 and result.state.hp == 1, "max_hp_payment_one_is_payable")
	result = Vitals.resolve_damage(state, {"amount": 0.5, "damage_type": "hp_payment"})
	_check(not result.ok and result.state == state, "fractional_payment_never_underpaid")


func _test_healing_order() -> void:
	var state := _state(10)
	state.max_hp = 200
	var packet := {"amount": 50, "base_multiplier": 2.0, "bonus_rate": 0.2, "reduction_multiplier": 0.5}
	var result := Vitals.resolve_heal(state, packet)
	_check(result.ok and result.state.hp == 65 and _fact(result, "actual_heal") == 55, "battery_plus_talent_same_base_then_half_55")
	packet.flat_bonus = 10
	result = Vitals.resolve_heal(state, packet)
	_check(result.state.hp == 70 and _fact(result, "resolved_heal") == 60, "flat_heal_bonus_before_halving_60")
	result = Vitals.resolve_heal(_state(95), packet)
	_check(result.state.hp == 100 and _fact(result, "actual_heal") == 5, "heal_reports_capped_actual")
	result = Vitals.resolve_heal(_state(), packet)
	_check(result.state.hp == 100 and _fact(result, "actual_heal") == 0, "full_health_zero_benefit_no_implicit_cost")
	result = Vitals.resolve_heal(_state(0), packet)
	_check(result.state.hp == 0 and _fact(result, "actual_heal") == 0, "ordinary_healing_does_not_revive")


func _test_pressure_order() -> void:
	var state := _state()
	state.counters.waiver = 1
	var result := Vitals.resolve_pressure(state, {"amount": 20, "percent_reductions": [{"rate": 0.25}], "flat_reductions": [{"amount": 7}], "waiver": {"counter_key": "waiver"}})
	_check(result.ok and result.state.pressure == 8 and result.state.counters.waiver == 1, "pressure_20_minus_25_percent_minus7_is8_no_waiver")
	result = Vitals.resolve_pressure(state, {"amount": 8, "source_id": "combat", "waiver": {"counter_key": "waiver"}})
	result = Vitals.resolve_pressure(result.state, {"amount": 4, "source_id": "shovel", "waiver": {"counter_key": "waiver"}})
	_check(result.state.pressure == 12 and result.state.counters.waiver == 1, "separate_8_and4_packets_never_merge_for_waiver")
	_check(_fact(result, "actual_pressure_delta") == 4 and _fact(result, "source_id") == "shovel", "per_source_pressure_actuals")
	result = Vitals.resolve_pressure(state, {"amount": 20, "percent_reductions": [{"rate": 0.25}, {"rate": 0.25}]})
	_check(result.state.pressure == 10, "pressure_percentages_read_same_base_not_multiply")
	result = Vitals.resolve_pressure(state, {"amount": 20, "replacement_amount": 8, "percent_reductions": [{"rate": 0.25}], "extra": 1})
	_check(result.state.pressure == 7, "replacement_before_reductions_extra_after")
	result = Vitals.resolve_pressure(state, {"amount": 20, "percent_reductions": [{"rate": 1.0}], "extra": 1})
	_check(result.state.pressure == 0, "no_extra_on_fully_reduced_pressure")
	result = Vitals.resolve_pressure(state, {"amount": 50, "extra": 1})
	_check(result.state.pressure == 15 and _fact(result, "adjusted") == 15, "positive_packet_cap15")
	result = Vitals.resolve_pressure(_state(100, 0, 90), {"amount": -40, "extra": 10, "percent_reductions": [{"rate": 0.5}]})
	_check(result.state.pressure == 50 and _fact(result, "actual_pressure_delta") == -40 and result.state.protocol_level == 3, "negative_pressure_bypasses_positive_modifiers_and_cap")
	result = Vitals.resolve_pressure(_state(100, 0, 3), {"amount": -20})
	_check(result.state.pressure == 0 and _fact(result, "actual_pressure_delta") == -3, "pressure_reduction_actual_clamped")
	result = Vitals.resolve_pressure(_state(100, 0, 79), {"amount": 1})
	_check(result.state.protocol_level == 1, "protocol_one_starts80")


func _test_pressure_effective_counters() -> void:
	var state := _state()
	state.counters = {"wrench": 2, "waiver": 1}
	var result := Vitals.resolve_pressure(state, {"amount": 20, "flat_reductions": [{"amount": 7, "counter_key": "wrench"}], "waiver": {"counter_key": "waiver"}})
	_check(result.state.pressure == 0 and result.state.counters.waiver == 0 and result.state.counters.wrench == 2, "waived_packet_does_not_spend_redundant_mitigation")
	result = Vitals.resolve_pressure(state, {"amount": 20, "flat_reductions": [{"amount": 12, "counter_key": "wrench"}], "waiver": {"counter_key": "waiver"}})
	_check(result.state.pressure == 8 and result.state.counters.waiver == 1 and result.state.counters.wrench == 1, "effective_reduction_below_waiver_threshold")
	result = Vitals.resolve_pressure(state, {"amount": 30, "flat_reductions": [{"amount": 1, "counter_key": "wrench"}]})
	_check(result.state.pressure == 15 and result.state.counters.wrench == 2, "cap_erases_reduction_no_charge")
	state.pressure = 99
	result = Vitals.resolve_pressure(state, {"amount": 20, "flat_reductions": [{"amount": 7, "counter_key": "wrench"}]})
	_check(result.state.pressure == 100 and result.state.counters.wrench == 2 and _fact(result, "actual_pressure_delta") == 1, "pressure_clamp_erases_reduction_no_charge")
	state.pressure = 100
	result = Vitals.resolve_pressure(state, {"amount": 20, "waiver": {"counter_key": "waiver"}})
	_check(result.ok and result.state.pressure == 100 and result.state.counters.waiver == 1 and result.state.hp == 100, "pressure100_no_waiver_no_terminal_or_hp_effect")
	state.pressure = 0
	result = Vitals.resolve_pressure(state, {"amount": 9, "waiver": {"counter_key": "waiver"}})
	_check(result.state.pressure == 9 and result.state.counters.waiver == 1, "waiver_strict_threshold_below10")
	result = Vitals.resolve_pressure(state, {"amount": 10, "waiver": {"counter_key": "waiver"}})
	_check(result.state.pressure == 0 and result.state.counters.waiver == 0, "waiver_at10")


func _status(id: String, effect: String, phase: String = "active") -> Dictionary:
	return {"id": id, "type": "temporary_buff", "temporary_type": effect, "phase": phase, "remaining": 5.0, "elapsed": 0.0}


func _test_status_activation_and_limits() -> void:
	var state := _state()
	var waiting := _status("immunity", "immunity", "waiting")
	waiting.start_trigger = "combat_start"
	waiting.hits_left = 2
	state.statuses = [waiting]
	var result := Statuses.advance(state, 8.0, {"kind": "hit"})
	_check(result.ok and result.state.statuses[0].phase == "waiting" and result.state.statuses[0].remaining == 5.0 and result.state.statuses[0].hits_left == 2, "waiting_does_not_tick_or_consume_hits")
	result = Statuses.advance(result.state, 1.0, {"kind": "combat_start"})
	_check(result.state.statuses[0].phase == "active" and result.state.statuses[0].remaining == 4.0 and _fact(result, "started") == ["immunity"], "next_combat_activates_at_step_start")
	result = Statuses.advance(result.state, 0.25, {"kind": "hit", "hit_count": 2})
	_check(result.state.statuses[0].phase == "ended" and result.state.statuses[0].hits_left == 0, "hit_limit_ends_before_time")
	_check(_fact(result, "hits_consumed") == {"immunity": 2} and _fact(result, "ended") == ["immunity"], "hit_end_facts")
	var pill := _status("pill", "countdown", "waiting")
	pill.start_trigger = "attack"
	pill.hits_left = 8
	state.statuses = [pill]
	result = Statuses.advance(state, 0.0, {"kind": "combat_start"})
	_check(result.state.statuses[0].phase == "waiting", "countdown_waits_for_first_attack")
	result = Statuses.advance(result.state, 2.0, {"kind": "attack"})
	_check(result.state.statuses[0].phase == "active" and result.state.statuses[0].remaining == 3.0, "first_attack_starts_countdown")
	result = Statuses.advance(result.state, 10.0, {})
	_check(result.state.statuses[0].phase == "ended" and result.state.statuses[0].remaining == 0.0 and result.state.statuses[0].hits_left == 8, "time_limit_ends_before_hits")
	_check(_fact(result, "active_seconds") == {"pill": 3.0}, "status_active_interval_clamped_to_expiry")
	result = Statuses.advance(result.state, 20.0, {"kind": "attack"})
	_check(_fact(result, "started") == [] and _fact(result, "ended") == [], "ended_status_never_restarts_or_reemits")
	var empty := _status("empty", "immunity")
	empty.hits_left = 0
	state.statuses = [empty]
	result = Statuses.advance(state, 2.0, {})
	_check(result.state.statuses[0].phase == "ended" and _fact(result, "active_seconds") == {"empty": 0.0} and result.state.statuses[0].elapsed == 0.0, "already_exhausted_status_has_no_active_time")


func _test_status_identity_and_clearing() -> void:
	var state := _state(70, 10, 20)
	state.max_hp = 95
	state.gold = 40
	state.statuses = [_status("a", "haste"), _status("b", "immunity"), _status("c", "strength"), {"id": "gear", "type": "equipment", "phase": "active"}, {"id": "perm", "type": "permanent", "phase": "active"}]
	state.statuses[0].paid_costs = {"gold": 5, "pressure": 20, "max_hp": 5, "items": ["used-pill"]}
	var result := Statuses.advance(state, 0.0, {})
	_check(result.ok and result.state.statuses.size() == 5 and result.state.statuses[2].temporary_type == "strength", "three_distinct_temporary_effects_same_category_coexist")
	result = Statuses.advance(state, 0.0, {"clear_temporary_types": ["immunity"]})
	_check(result.state.statuses[0].phase == "active" and result.state.statuses[1].phase == "ended" and result.state.statuses[2].phase == "active", "clear_specific_effect_identity_not_whole_buff_category")
	result = Statuses.advance(state, 0.0, {"kind": "clear_temporary", "clear_types": ["permanent", "equipment"]})
	_check(result.state.statuses[0].phase == "ended" and result.state.statuses[1].phase == "ended" and result.state.statuses[2].phase == "ended", "clear_all_temporary_types")
	_check(result.state.statuses[3].phase == "active" and result.state.statuses[4].phase == "active", "global_clear_keeps_equipment_and_permanent")
	_check(result.state.gold == 40 and result.state.pressure == 20 and result.state.max_hp == 95 and result.state.hp == 70 and result.state.statuses[0].paid_costs == state.statuses[0].paid_costs, "clearing_never_refunds_paid_costs")
	state.statuses[2].clear_on = ["room_exit"]
	result = Statuses.advance(state, 0.0, {"kind": "room_exit"})
	_check(result.state.statuses[2].phase == "ended" and result.state.statuses[0].phase == "active", "defined_event_clear_only_matching_status")


func _test_status_time() -> void:
	var state := _state()
	state.statuses = [_status("clock", "clock")]
	for menu in ["map", "esc", "settings", "inventory", "dialogue"]:
		var result := Statuses.advance(state, 2.0, {"kind": menu})
		_check(result.state.statuses[0].remaining == 3.0, "ordinary_menu_keeps_simulation_time_" + menu)
	var frozen := Statuses.advance(state, 3600.0, {"offline": true, "kind": "clear_temporary"})
	_check(frozen.state == state, "offline_freezes_status_and_trigger")
	var single := Statuses.advance(state, 1.0, {})
	var split := state
	for index in range(10):
		split = Statuses.advance(split, 0.1, {}).state
	_check(is_equal_approx(single.state.statuses[0].remaining, split.statuses[0].remaining) and is_equal_approx(single.state.statuses[0].elapsed, split.statuses[0].elapsed), "status_catchup_equivalent_simulated_time")
	state.statuses[0].remaining = 0.3
	single = Statuses.advance(state, 0.3, {})
	split = state
	for index in range(3):
		split = Statuses.advance(split, 0.1, {}).state
	_check(single.state.statuses[0].phase == "ended" and split.statuses[0].phase == "ended", "fractional_time_expiry_same_boundary_after_catchup")


func _test_immutability_and_rejections() -> void:
	var state := _state(20, 10, 10)
	state.counters = {"visor": 3}
	state.statuses = [_status("nested", "haste")]
	state.extra = {"nested": [1, 2]}
	var before := state.duplicate(true)
	var packet := {"amount": 8, "flat_blocks": [{"amount": 2, "counter_key": "visor"}]}
	var packet_before := packet.duplicate(true)
	var outputs := [Vitals.resolve_damage(state, packet), Vitals.resolve_heal(state, {"amount": 5}), Vitals.resolve_pressure(state, {"amount": 4}), Statuses.advance(state, 1.0, {})]
	for result in outputs:
		_check(result.ok, "valid_resolver_result")
		result.state.extra.nested[0] = 99
		result.state.statuses[0].phase = "ended"
		result.state.counters.visor = 0
	_check(state == before and packet == packet_before, "all_outputs_deep_copy_inputs_unchanged")
	for invalid in [{"amount": -1}, {"amount": INF}, {"amount": 1, "damage_type": "unknown"}, {"amount": 1, "percent_reductions": [{"rate": 1.1}]}]:
		var result := Vitals.resolve_damage(state, invalid)
		_check(not result.ok and result.state == before and result.facts.is_empty(), "invalid_damage_rejected_" + str(invalid))
	var result := Vitals.resolve_heal(state, {"amount": 5, "reduction_multiplier": -1.0})
	_check(not result.ok and result.state == before, "invalid_heal_rejected")
	result = Vitals.resolve_pressure(state, {"amount": NAN})
	_check(not result.ok and result.state == before, "invalid_pressure_rejected")
	result = Statuses.advance(state, -1.0, {})
	_check(not result.ok and result.state == before, "negative_time_rejected_atomically")
	var invalid_state := state.duplicate(true)
	invalid_state.hp = 101
	result = Vitals.resolve_damage(invalid_state, {"amount": 5})
	_check(not result.ok and result.state == invalid_state, "invalid_state_not_silently_normalized")
	invalid_state = state.duplicate(true)
	invalid_state.statuses.append({"id": "bad", "type": "temporary_buff", "phase": "active", "remaining": -1.0})
	result = Statuses.advance(invalid_state, 1.0, {})
	_check(not result.ok and result.state == invalid_state, "invalid_status_rejects_before_any_tick")
	result = Vitals.resolve_damage(state, {"amount": 20, "damage_type": "hp_payment"})
	result.state.extra.nested[0] = 77
	_check(state == before, "rejected_result_also_deep_copy")


func _test_protocol_costs_and_compatibility() -> void:
	var matrices := {"simple": [1, 0, 0, 0, 0], "easy": [1, 0, 0, 0, 0], "normal": [2, 1, 0, 0, 0], "standard": [2, 1, 0, 0, 0], "hard": [3, 2, 1, 0, 0], "hell": [4, 3, 2, 1, 0]}
	for difficulty in matrices:
		for tier in range(1, 6):
			_check(Protocol.exploration_cost(StringName(difficulty), tier, true) == matrices[difficulty][tier - 1], "protocol_cost_%s_%d" % [difficulty, tier])
			_check(Protocol.exploration_cost(StringName(difficulty), tier, false) == 0, "revisit_free_%s_%d" % [difficulty, tier])
	_check(Protocol.exploration_cost(&"unknown", 1, true) == 0, "unknown_difficulty_no_invented_charge")
	var context := Context.new()
	context.hp = 1
	context.pressure = 99
	context.protocol_level = 1
	var result := Protocol.add_pressure(context, 20)
	_check(context.hp == 1 and context.pressure == 100 and context.protocol_level == 1 and not bool(result.penalty), "legacy_add_pressure_no_hidden_hp_cost_or_pressure100_failure")
	result = Protocol.add_pressure(context, -25)
	_check(context.pressure == 75 and context.protocol_level == 2 and result.changed, "legacy_add_pressure_negative_and_tier_change")
	_check(Protocol.level_for_pressure(80) == 1 and Protocol.level_for_pressure(79) == 2, "legacy_protocol_boundary_compatible")
	_check(Protocol.add_pressure(null, 5).changed == false, "legacy_null_context_compatible")
