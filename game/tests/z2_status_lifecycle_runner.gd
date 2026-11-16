extends "res://tests/z2_combat_transaction_runner.gd"


func _run() -> void:
	_test_combat_start_trigger()
	_test_real_hit_trigger()
	_test_periodic_frame_partition()
	_test_hit_duplicate()
	_test_fractional_idle_frames()
	for failure in failures:
		print("Z2_STATUS_LIFECYCLE_CASE_FAIL " + failure)
	print("Z2_STATUS_LIFECYCLE=%s checks=%d failures=%d" % ["PASS" if failures.is_empty() else "FAIL", checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _test_combat_start_trigger() -> void:
	var runtime = RuntimeController.new()
	runtime.context.start_run({"id": "review_combat_start", "seed": 348, "width": 5, "height": 5, "max_hp": 100, "power": 10, "manual_map": {"spawn": Vector2i.ZERO, "monsters": [Vector2i(2, 2)], "exits": [{"pos": Vector2i(4, 4), "exit_id": "test_exit"}]}})
	runtime.checkpoint_writer = func(_snapshot: Dictionary) -> Dictionary: return {"ok": true}
	runtime.context.temporary_statuses = [{"id": "next_combat", "type": "temporary_debuff", "temporary_type": "bleed", "phase": "waiting", "start_trigger": "combat_start", "remaining": 1.0, "dot_per_second": 60.0}]
	runtime.context.player_pos = Vector2i(2, 2)
	runtime.context.current_pos = Vector2i(2, 2)
	runtime.command_bus.room_resolver.enter_room(runtime.context)
	runtime.in_run_runtime.sync_room(Vector2(0.28, 0.50))
	for enemy in runtime.in_run_runtime.simulation.enemies:
		enemy["entry_grace_remaining"] = 20.0
	runtime.in_run_runtime.simulation.set_player_input(Vector2.ZERO, Vector2.RIGHT)
	runtime.in_run_runtime.simulation.accumulator = CombatSimulation.FIXED_STEP
	var before: Dictionary = runtime.capture_authoritative_state()
	runtime.checkpoint_writer = func(_snapshot: Dictionary) -> Dictionary: return {"ok": false, "reason": "injected"}
	var failed: Dictionary = runtime.in_run_runtime.advance_frame(0.0, Vector2.ZERO, Vector2.RIGHT)
	_check(not bool(failed.get("step_result", {}).get("ok", true)) and runtime.capture_authoritative_state() == before, "combat_start_save_failure_restores_waiting_status_and_tick")
	runtime.checkpoint_writer = func(_snapshot: Dictionary) -> Dictionary: return {"ok": true}
	_check(bool(runtime.retry_persistence().get("ok", false)), "combat_start_storage_retry")
	var frame: Dictionary = runtime.in_run_runtime.advance_frame(0.0, Vector2.ZERO, Vector2.RIGHT)
	_check(bool(frame.get("step_result", {}).get("ok", false)) and runtime.in_run_runtime.simulation.tick_index == 1, "combat_start_control_step_commits")
	_check(runtime.context.temporary_statuses[0].phase == "active" and runtime.context.hp == 99, "combat_start_reaches_waiting_status_before_first_step")
	_release(runtime)


func _test_real_hit_trigger() -> void:
	var runtime = _controller()
	var bridge = runtime.in_run_runtime
	runtime.context.temporary_statuses = [{"id": "one_hit", "type": "temporary_debuff", "temporary_type": "bleed", "phase": "active", "hits_left": 1, "hit_trigger": "hit", "remaining": 2.0, "dot_per_second": 60.0}]
	_add_colliding_projectiles(bridge.simulation, 4)
	var frame: Dictionary = bridge.advance_frame(CombatSimulation.FIXED_STEP, Vector2.ZERO, Vector2.RIGHT)
	var hit_count := _count_events(bridge.recent_domain_events, &"player_damaged")
	var hp_after_hit: int = runtime.context.hp
	_check(bool(frame.get("step_result", {}).get("ok", false)) and hit_count == 1 and hp_after_hit == 95, "hit_control_is_one_accepted_collision_and_one_dot_tick")
	_check(runtime.context.temporary_statuses[0].hits_left == 0 and runtime.context.temporary_statuses[0].phase == "ended", "accepted_hit_consumes_matching_status_limit")
	bridge.advance_frame(CombatSimulation.FIXED_STEP, Vector2.ZERO, Vector2.RIGHT)
	_check(runtime.context.hp == hp_after_hit, "hit_expired_status_cannot_tick_again")
	_release(runtime)


func _idle_runtime():
	var runtime = RuntimeController.new()
	runtime.context.start_run({"id": "review_idle", "seed": 348, "width": 5, "height": 5, "max_hp": 100, "power": 10, "manual_map": {"spawn": Vector2i.ZERO, "exits": [{"pos": Vector2i(4, 4), "exit_id": "test_exit"}]}})
	runtime.checkpoint_writer = func(_snapshot: Dictionary) -> Dictionary: return {"ok": true}
	runtime.context.temporary_statuses = [
		{"id": "regen", "type": "temporary_buff", "temporary_type": "regen", "phase": "active", "remaining": 1.0, "heal_per_second": 60.0},
		{"id": "bleed", "type": "temporary_debuff", "temporary_type": "bleed", "phase": "active", "remaining": 1.0, "dot_per_second": 60.0},
	]
	return runtime


func _test_periodic_frame_partition() -> void:
	var long_frame = _idle_runtime()
	var small_frames = _idle_runtime()
	var result: Dictionary = long_frame.advance_idle_frame(0.25)
	_check(bool(result.get("ok", false)), "idle_control_long_frame_commits")
	for index in range(15):
		result = small_frames.advance_idle_frame(CombatSimulation.FIXED_STEP)
		_check(bool(result.get("ok", false)), "idle_control_small_frame_%d_commits" % index)
	_check(is_equal_approx(long_frame.context.temporary_statuses[0].elapsed, small_frames.context.temporary_statuses[0].elapsed), "idle_control_same_simulated_elapsed_time")
	_check(long_frame.context.hp == small_frames.context.hp, "same_elapsed_periodic_effects_do_not_depend_on_frame_partition")
	_release(long_frame)
	_release(small_frames)

func _test_hit_duplicate() -> void:
	var runtime = _idle_runtime()
	runtime.context.temporary_statuses = [{"id": "two_hits", "type": "temporary_debuff", "temporary_type": "bleed", "phase": "active", "hits_left": 2, "hit_trigger": "hit", "remaining": 2.0}]
	var packet := {"hit_id": "same_hit", "damage": 1, "source_id": "test"}
	var first: Dictionary = runtime.apply_combat_hit(packet)
	var before: Dictionary = runtime.capture_authoritative_state()
	var duplicate: Dictionary = runtime.apply_combat_hit(packet)
	_check(bool(first.get("ok", false)) and bool(duplicate.get("duplicate", false)), "duplicate_accepted_hit_returns_receipt")
	_check(runtime.capture_authoritative_state() == before and runtime.context.temporary_statuses[0].hits_left == 1 and float(runtime.context.temporary_statuses[0].get("elapsed", 0.0)) == 0.0, "duplicate_hit_does_not_consume_or_advance_time")
	_release(runtime)

func _test_fractional_idle_frames() -> void:
	for hp in [100, 2]:
		var long_frame = _idle_runtime()
		var fine_frames = _idle_runtime()
		long_frame.context.hp = hp
		fine_frames.context.hp = hp
		long_frame.advance_idle_frame(0.25)
		for index in range(36):
			fine_frames.advance_idle_frame(1.0 / 144.0)
		_check(long_frame.context.hp == fine_frames.context.hp and is_equal_approx(long_frame.context.temporary_statuses[0].elapsed, fine_frames.context.temporary_statuses[0].elapsed), "144hz_periodic_same_time_hp_%d" % hp)
		var before: Dictionary = fine_frames.capture_authoritative_state()
		fine_frames.checkpoint_writer = func(_snapshot: Dictionary) -> Dictionary: return {"ok": false, "reason": "injected"}
		var failed: Dictionary = fine_frames.advance_idle_frame(0.25)
		_check(not bool(failed.get("ok", true)) and fine_frames.capture_authoritative_state() == before, "idle_timer_failure_restores_accumulator_and_vitals_%d" % hp)
		_release(long_frame)
		_release(fine_frames)
