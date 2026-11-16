extends SceneTree

const Runtime = preload("res://scripts/core/run/run_runtime_controller.gd")
const Effects = preload("res://scripts/core/run/run_effect_applier.gd")
var failures: Array[String] = []
var checks: int = 0

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	_test_partial_failure()
	_test_preview_is_read_only()
	_test_terminal_after_facts()
	_test_duplicate_action()
	_test_unknown_modifier()
	_test_snapshot_roundtrip()
	_test_full_rollback_and_preview()
	_test_stale_plan_and_invalid_snapshot()
	_test_command_publication()
	_test_preview_conditions()
	for failure in failures:
		print("Z2_ACTION_CASE_FAIL " + failure)
	print("Z2_ACTION_TRANSACTION=%s checks=%d" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)

func _new_context() -> RunContext:
	var context := RunContext.new()
	RunStateMachine.new().start_demo_run(context)
	return context

func _test_partial_failure() -> void:
	var context := _new_context()
	var before_balance := context.asset_ledger.get_currency(RunAssetLedger.CURRENCY_BLACK)
	var before_log := context.transaction_log.snapshot()
	var result := Effects.apply_effects(context, [
		Effects.effect(Effects.EFFECT_PENDING_GOLD_DELTA, "atomic_test", {"amount": 7}),
		Effects.effect(&"unsupported_z2_effect", "atomic_test"),
	])
	_check(not bool(result.get("ok", true)), "unknown_effect_rejected")
	_check(context.asset_ledger.get_currency(RunAssetLedger.CURRENCY_BLACK) == before_balance, "second_effect_failure_restores_currency")
	_check(context.transaction_log.snapshot() == before_log, "second_effect_failure_restores_log")

func _test_preview_is_read_only() -> void:
	var context := _new_context()
	var effect := Effects.effect(Effects.EFFECT_PENDING_GOLD_DELTA, "preview", {"amount": 9})
	effect["read_only_preview"] = true
	var before := context.asset_ledger.get_currency(RunAssetLedger.CURRENCY_BLACK)
	for index in range(100):
		Effects.apply_effects(context, [effect])
	_check(context.asset_ledger.get_currency(RunAssetLedger.CURRENCY_BLACK) == before, "hundred_previews_do_not_credit")

func _test_terminal_after_facts() -> void:
	var context := _new_context()
	context.hp = 1
	Effects.apply_effects(context, [
		Effects.effect_hp_delta(-5, "lethal_test"),
		Effects.effect_protocol_pressure_delta(12, "final_source"),
		Effects.effect(Effects.EFFECT_EVENT_MARK_COMPLETED, "final_event", {"position": context.get_current_pos()}),
	])
	_check(context.failed, "lethal_action_fails")
	_check(int(context.result_snapshot.get("pressure", -1)) == 12, "terminal_includes_later_pressure")
	_check(context.interacted_cells.has(context.cell_key(context.get_current_pos())), "terminal_includes_event_completion")

func _test_duplicate_action() -> void:
	var runtime = Runtime.new()
	runtime.command_bus.dispatch(&"start_demo_run", {})
	var pos := Vector2i(3, 2)
	var first: Dictionary = runtime.command_bus.dispatch(&"toggle_flag_cell", {"pos": pos, "action_id": "same_flag"})
	var second: Dictionary = runtime.command_bus.dispatch(&"toggle_flag_cell", {"pos": pos, "action_id": "same_flag"})
	_check(bool(first.get("ok", false)), "first_flag_accepted")
	_check(bool(second.get("ok", false)) and bool(second.get("duplicate", false)), "same_action_returns_receipt")
	_check(runtime.context.intel_map.is_flagged(pos), "duplicate_does_not_toggle_back")
	var conflict: Dictionary = runtime.command_bus.dispatch(&"toggle_flag_cell", {"pos": Vector2i(4, 3), "action_id": "same_flag"})
	_check(not bool(conflict.get("ok", true)) and str(conflict.get("reason", "")) == "action_id_conflict", "same_id_changed_payload_rejected")
	runtime.command_bus.runtime_controller = null
	runtime.command_bus.room_resolver.bind_runtime_controller(null)
	runtime.in_run_runtime.bind(null)

func _preview_event_runtime():
	var runtime = Runtime.new()
	runtime.command_bus.dispatch(&"start_demo_run")
	runtime.context.player_pos = Vector2i(5, 1)
	runtime.context.current_pos = Vector2i(5, 1)
	runtime.context.z1_event_rooms["5,1"] = {"event_type": &"z1_event_e10", "completed": false}
	runtime.command_bus.room_resolver.enter_room(runtime.context)
	runtime.context.pressure = 40
	runtime.context.asset_ledger.add_currency(&"black_coin", 100)
	return runtime

func _test_preview_conditions() -> void:
	for changed in ["price", "capacity", "eligibility", "altar_stage"]:
		var runtime = _preview_event_runtime()
		var option_id := &"buy_patch"
		if changed == "altar_stage":
			runtime.context.z1_event_rooms["5,1"]["event_type"] = &"altar"
			option_id = &"offer_hp"
		var before: Dictionary = runtime.capture_authoritative_state()
		var quote: Dictionary = runtime.command_bus.dispatch(&"select_event_option", {"option_id": option_id, "preview": true})
		_check(bool(quote.get("ok", false)) and str(quote.get("condition_fingerprint", "")).length() == 64, changed + ": preview returns condition fingerprint")
		_check(runtime.capture_authoritative_state() == before, changed + ": quote is side-effect free")
		runtime.execute_atomic_operation(&"condition_change", {}, func() -> Dictionary:
			match changed:
				"price": runtime.context.pressure = 39
				"capacity": runtime.context.asset_ledger.equipment_capacity += 1
				"eligibility": runtime.context.z1_event_rooms["5,1"]["completed"] = true
				"altar_stage": runtime.context.run_stats["altar_stage"] = 1
			return {"ok": true}
		)
		before = runtime.capture_authoritative_state()
		var writes := [0]
		runtime.checkpoint_writer = func(_state: Dictionary) -> Dictionary:
			writes[0] += 1
			return {"ok": true}
		var rejected: Dictionary = runtime.command_bus.dispatch(&"select_event_option", {"option_id": option_id, "expected_conditions": quote.get("condition_fingerprint", "missing")})
		_check(str(rejected.get("reason", "")) == "stale_preview", changed + ": old conditions rejected")
		_check(runtime.capture_authoritative_state() == before and writes[0] == 0, changed + ": stale confirmation cannot spend, publish or write")
		runtime.command_bus.runtime_controller = null
		runtime.command_bus.room_resolver.bind_runtime_controller(null)
		runtime.in_run_runtime.bind(null)
	var runtime = _preview_event_runtime()
	runtime.context.temporary_statuses = [{"id": "unrelated_clock", "type": "temporary_buff", "temporary_type": "test", "phase": "active", "remaining": 5.0, "elapsed": 0.0, "dot_per_second": 1.0}]
	var before: Dictionary = runtime.capture_authoritative_state()
	var quote: Dictionary = runtime.command_bus.dispatch(&"select_event_option", {"option_id": &"buy_patch", "preview": true})
	for index in range(100):
		var repeated: Dictionary = runtime.command_bus.dispatch(&"select_event_option", {"option_id": &"buy_patch", "preview": true})
		_check(repeated.get("condition_fingerprint", "missing") == quote.get("condition_fingerprint", "") and runtime.capture_authoritative_state() == before, "quote repeat %d preserves conditions/RNG/state" % index)
	var original_revision: int = runtime.transaction_revision
	runtime.advance_idle_frame(0.25)
	_check(runtime.context.hp == before.context.data.hp and float(runtime.context.temporary_statuses[0].dot_remainder) > 0.0, "fractional timer progress does not change price or eligibility")
	runtime.update_player_location(Vector2(0.41, 0.63))
	runtime.execute_atomic_operation(&"checkpoint", {}, func() -> Dictionary: return {"ok": true})
	_check(runtime.transaction_revision > original_revision, "unrelated checkpoint advances global revision")
	var request := {"option_id": &"buy_patch", "expected_conditions": quote.get("condition_fingerprint", "missing"), "action_id": "quoted_purchase"}
	var accepted: Dictionary = runtime.command_bus.dispatch(&"select_event_option", request)
	_check(bool(accepted.get("ok", false)) and runtime.context.asset_ledger.get_currency(&"black_coin") == 96, "unchanged quote survives timer/motion/checkpoint and pays shown four coins")
	before = runtime.capture_authoritative_state()
	var duplicate: Dictionary = runtime.command_bus.dispatch(&"select_event_option", request)
	_check(bool(duplicate.get("duplicate", false)) and runtime.capture_authoritative_state() == before, "duplicate receipt wins over now-stale quote")
	runtime.command_bus.runtime_controller = null
	runtime.command_bus.room_resolver.bind_runtime_controller(null)
	runtime.in_run_runtime.bind(null)

func _test_unknown_modifier() -> void:
	var pipeline := RunRulePipeline.new()
	var result := pipeline.register_modifier({"target_rule": &"search", "operation": &"unimplemented", "value": 2})
	_check(not bool(result.get("ok", true)), "unknown_modifier_refused")
	_check(pipeline.modifiers.is_empty(), "unknown_modifier_not_registered")

func _test_snapshot_roundtrip() -> void:
	var runtime = Runtime.new()
	runtime.command_bus.dispatch(&"start_demo_run", {})
	if not runtime.has_method("capture_authoritative_state"):
		_check(false, "complete_snapshot_api_missing")
	else:
		runtime.context.seed_value = 9223372036854775806
		runtime.context.tutorial_popup = {"devices": PackedStringArray(["keyboard_mouse", "gamepad"]), "timer": 1.0 / 120.0}
		var original_context = runtime.context
		var original_ledger = runtime.context.asset_ledger
		var snapshot: Dictionary = runtime.capture_authoritative_state()
		runtime.context.hp = 2
		runtime.context.asset_ledger.add_currency(RunAssetLedger.CURRENCY_BLACK, 100)
		var encoded: Variant = runtime.call("encode_checkpoint_state", snapshot)
		_check(JSON.stringify(encoded).length() < 131072, "demo_checkpoint_transport_is_bounded")
		var parsed: Variant = JSON.parse_string(JSON.stringify(encoded))
		var restored: Dictionary = runtime.call("restore_checkpoint_state", parsed)
		_check(bool(restored.get("ok", false)), "complete_snapshot_roundtrip")
		_check(runtime.context == original_context and runtime.context.asset_ledger == original_ledger, "snapshot_preserves_authority_identity")
		_check(runtime.context.hp == 100 and runtime.context.pending_gold == 0, "snapshot_restores_hp_and_currency")
		_check(runtime.context.seed_value == 9223372036854775806, "int64_survives_json")
		_check(runtime.context.truth_map.spawn_pos == Vector2i(3, 3), "vector_roundtrip")
		_check(runtime.context.tutorial_popup.devices is PackedStringArray and runtime.context.tutorial_popup.devices == PackedStringArray(["keyboard_mouse", "gamepad"]), "tutorial_packed_strings_roundtrip")
		_check(var_to_bytes(runtime.context.tutorial_popup.timer) == var_to_bytes(1.0 / 120.0), "simulation_double_bits_roundtrip")
		var valid_before: Dictionary = runtime.capture_authoritative_state()
		for mutation in [{"codec": "unknown"}, {"byte_count": 67108865}, {"sha256": "corrupt"}, {"byte_count": 1.5}, {"data": "not-base64!", "sha256": "not-base64!".sha256_text()}]:
			var invalid: Dictionary = encoded.duplicate(true)
			invalid.merge(mutation, true)
			var rejected: Dictionary = runtime.restore_checkpoint_state(invalid)
			_check(not bool(rejected.get("ok", false)) and runtime.capture_authoritative_state() == valid_before, "invalid_checkpoint_transport_atomic_" + str(mutation.keys()[0]))
		var legacy: Dictionary = runtime.restore_checkpoint_state(RunStateSnapshot.encode(snapshot))
		_check(bool(legacy.get("ok", false)) and runtime.capture_authoritative_state() == valid_before, "legacy_typed_checkpoint_readable")
	runtime.command_bus.runtime_controller = null
	runtime.command_bus.room_resolver.bind_runtime_controller(null)
	runtime.in_run_runtime.bind(null)

func _check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)

func _test_command_publication() -> void:
	var runtime = Runtime.new()
	runtime.command_bus.dispatch(&"start_demo_run")
	var requests: Array[Dictionary] = []
	var snapshots: Array[Dictionary] = []
	runtime.command_bus.command_requested.connect(func(_name: StringName, command: Dictionary) -> void: requests.append(command))
	runtime.command_bus.state_changed.connect(func(snapshot: Dictionary) -> void: snapshots.append(snapshot))
	var payload := {"pos": Vector2i(3, 3), "source": "z2-publication", "action_id": "published-flag"}
	var accepted: Dictionary = runtime.command_bus.dispatch(&"toggle_flag_cell", payload)
	_check(bool(accepted.get("ok")) and requests.size() == 1, "committed_command_publishes_one_request")
	_check(requests[0].get("command_id") == accepted.get("command_id") and requests[0].get("payload", {}).get("pos") == payload.pos, "published_request_preserves_normalized_identity_and_payload")
	_check(snapshots.size() == 1, "committed_command_publishes_one_state")
	var before: Dictionary = runtime.capture_authoritative_state()
	var rejected: Dictionary = runtime.command_bus.dispatch(&"move_by", {"delta": Vector2i.ZERO})
	_check(not bool(rejected.get("ok")) and requests.size() == 2 and snapshots.size() == 1, "rejected_command_publishes_intent_without_state")
	_check(runtime.capture_authoritative_state() == before, "rejected_command_keeps_all_authority_including_sequence")
	runtime.command_bus.dispatch(&"toggle_flag_cell", {"pos": Vector2i(3, 4), "preview": true})
	_check(requests.size() == 2 and snapshots.size() == 1 and runtime.capture_authoritative_state() == before, "preview_publishes_no_command_or_state")
	runtime.command_bus.dispatch(&"toggle_flag_cell", payload)
	_check(requests.size() == 2 and snapshots.size() == 1, "duplicate_command_does_not_republish")
	runtime.command_bus.runtime_controller = null
	runtime.command_bus.room_resolver.bind_runtime_controller(null)
	runtime.in_run_runtime.bind(null)

func _test_full_rollback_and_preview() -> void:
	var runtime = Runtime.new()
	runtime.command_bus.dispatch(&"start_demo_run", {})
	var before: Dictionary = runtime.capture_authoritative_state()
	var operation := func() -> Dictionary:
		runtime.context.seed_value += 9
		runtime.context.run_stats["counter"] = 6
		runtime.context.asset_ledger.add_currency(RunAssetLedger.CURRENCY_BLACK, 23)
		return {"ok": true}
	for index in range(100):
		runtime.execute_atomic_operation(&"preview_rng", {"preview": true}, operation)
	_check(runtime.capture_authoritative_state() == before, "preview_preserves_all_authoritative_state")
	runtime.checkpoint_writer = func(_state: Dictionary) -> Dictionary: return {"ok": false, "reason": "injected_disk_failure"}
	var failed: Dictionary = runtime.execute_atomic_operation(&"save_failure", {}, operation, "failed_action")
	_check(not bool(failed.get("ok", true)), "failed_save_rejects_action")
	_check(runtime.capture_authoritative_state() == before, "failed_save_restores_all_authoritative_state")
	var blocked: Dictionary = runtime.execute_atomic_operation(&"blocked", {}, operation)
	_check(str(blocked.get("reason", "")) == "persistence_retry_required", "failed_save_blocks_following_actions")
	runtime.checkpoint_writer = func(_state: Dictionary) -> Dictionary: return {"ok": true}
	_check(bool(runtime.retry_persistence().get("ok", false)), "retry_clears_storage_block")
	var retried: Dictionary = runtime.execute_atomic_operation(&"save_failure", {}, operation, "failed_action")
	_check(bool(retried.get("ok", false)) and runtime.context.asset_ledger.get_currency(RunAssetLedger.CURRENCY_BLACK) == 23, "failed_action_can_retry_once")
	runtime.command_bus.runtime_controller = null
	runtime.command_bus.room_resolver.bind_runtime_controller(null)
	runtime.in_run_runtime.bind(null)

func _test_stale_plan_and_invalid_snapshot() -> void:
	var runtime = Runtime.new()
	runtime.command_bus.dispatch(&"start_demo_run", {})
	var before: Dictionary = runtime.capture_authoritative_state()
	var planner = load("res://scripts/core/run/run_action_transaction.gd")
	var plan: Dictionary = planner.plan(before, {"action_id": "stale", "computed_state": before, "result": {"ok": true}})
	runtime.transaction_revision += 1
	_check(str(planner.commit(runtime, plan["plan"]).get("reason", "")) == "stale_revision", "commit_rechecks_revision")
	runtime.transaction_revision -= 1
	var corrupt := before.duplicate(true)
	corrupt["context"]["data"]["hp"] = -1
	var rejected: Dictionary = runtime.restore_checkpoint_state(runtime.encode_checkpoint_state(corrupt))
	_check(not bool(rejected.get("ok", true)), "invalid_snapshot_vitals_rejected")
	_check(runtime.capture_authoritative_state() == before, "invalid_snapshot_never_partially_installed")
	var malformed: Dictionary = runtime.restore_checkpoint_state({"$type": "unknown", "value": []})
	_check(not bool(malformed.get("ok", true)), "invalid_snapshot_codec_rejected")
	runtime.command_bus.runtime_controller = null
	runtime.command_bus.room_resolver.bind_runtime_controller(null)
	runtime.in_run_runtime.bind(null)
