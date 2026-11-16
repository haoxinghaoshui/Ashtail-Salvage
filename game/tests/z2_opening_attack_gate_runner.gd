extends SceneTree

const Runtime := preload("res://scripts/core/run/run_runtime_controller.gd")
const Context := preload("res://scripts/core/run/run_context.gd")
const Opening := preload("res://scripts/core/run/z2_opening_runtime.gd")
const Offer := preload("res://scripts/core/progression/z2_opening_offer.gd")
const Talents := preload("res://scripts/core/progression/z2_talent_catalog.gd")
const Supplies := preload("res://scripts/core/run/z2_supply_runtime.gd")
const Items := preload("res://scripts/core/content/z2_item_catalog.gd")
const Eligibility := preload("res://scripts/core/content/z2_content_eligibility.gd")
const Snapshot := preload("res://scripts/core/run/run_state_snapshot.gd")
const ROOM := Vector2i(2, 2)
const STEP := 1.0 / 60.0
var checks := 0
var failures: Array[String] = []
var fixture_failed := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	for test in [_test_input_gate, _test_buffer_revalidation_and_release, _test_restore_binding, _test_impact_revalidation, _test_legacy_attack]:
		test.call()
		if fixture_failed:
			break
	for failure in failures:
		print("ASSERT_FAIL: " + failure)
	print("Z2_OPENING_ATTACK_GATE=%s checks=%d failures=%d" % ["PASS" if failures.is_empty() else "FAIL", checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _runtime(z2: bool = true):
	var runtime = Runtime.new()
	var run := Context.new()
	run.start_run({"id": "opening_gate", "mode": &"standard", "seed": 348, "width": 5, "height": 5,
		"max_hp": 100, "power": 20,
		"profile_fields": {"ruleset_id": "z2", "z2_progression_version": 1, "content_eligibility": Eligibility.freeze_profile({"profile_level": 30})} if z2 else {},
		"active_talent_effects": [Talents.definition("z2_talent_15")] if z2 else [],
		"manual_map": {"spawn": Vector2i.ZERO, "monsters": [ROOM], "exits": [{"pos": Vector2i(4, 4), "exit_id": "exit"}]}})
	run.run_id = &"opening_gate_fixture"
	runtime.context = run
	runtime.command_bus.bind_runtime_controller(runtime)
	runtime.in_run_runtime.bind(runtime)
	runtime.checkpoint_writer = func(_snapshot: Dictionary) -> Dictionary: return {"ok": true}
	if z2:
		run.run_start_config["profile_fields"] = run.profile_fields.duplicate(true)
		run.run_start_config["map_config_id"] = "classic_13x13_normal"
		var meta := {"ruleset_id": "z2", "z2_progression_version": 1, "talent_flags": ["z2_talent_15"], "gold": 0, "run_count": 0, "profile_id": "gate"}
		var prepared := {}
		for seed_value in range(1, 100):
			prepared = Offer.execute(meta, "prepare", {"request_id": "prepare"}, seed_value)
			if prepared.offer.candidates.has("avoidance"):
				break
		var selected := Offer.execute(prepared.meta, "choose", {"request_id": "choose", "offer_id": prepared.offer.offer_id, "effect_id": "avoidance"})
		_check(selected.get("ok", false), "valid frozen avoidance offer")
		run.run_start_config["z2_opening_offer"] = selected.offer.duplicate(true)
		_check(Opening.admit_departure(run, selected.offer).get("ok", false), "real opening admission")
		var pill := Items.definition("con_countdown_pill")
		pill["instance_id"] = "gate_pill"
		_check(Supplies.apply_consumable(run, pill).get("ok", false), "waiting first-attack pill admitted")
	run.player_pos = ROOM
	run.current_pos = ROOM
	var entered: Dictionary = runtime.command_bus.room_resolver.enter_room(run)
	_check(entered.get("ok", false), "actual room entry: " + str(entered))
	if not entered.get("ok", false):
		fixture_failed = true
		_release(runtime)
		return null
	runtime.in_run_runtime.sync_room(Vector2(0.5, 0.5))
	var sim = runtime.in_run_runtime.simulation
	if sim == null:
		fixture_failed = true
		_check(false, "actual room entry created no simulation")
		_release(runtime)
		return null
	sim.set_arena_obstacles([])
	sim.place_player_from_room_entry(Vector2(0.5, 0.5), Vector2.RIGHT)
	sim.enemies[0].pos = Vector2(0.66, 0.5)
	sim.enemies[0].facing = Vector2.RIGHT
	sim.enemies[0].entry_grace_remaining = 100.0
	sim.enemies[0].hp = 1000
	sim.enemies[0].max_hp = 1000
	return runtime


func _step(runtime, ticks: int) -> void:
	for tick in range(ticks):
		var result: Dictionary = runtime.in_run_runtime.advance_frame(STEP, Vector2.ZERO, Vector2.RIGHT)
		if not result.get("step_result", {}).get("ok", false):
			_check(false, "actual fixed step failed: " + str(result.get("step_result")))
			return


func _pill(run: RunContext) -> Dictionary:
	for status in run.temporary_statuses:
		if status.get("item_id") == "con_countdown_pill":
			return status
	return {}


func _check_waiting(runtime, label: String) -> void:
	var pill := _pill(runtime.context)
	_check(pill.get("phase") == "waiting" and pill.get("remaining") == 12.0, label + ": first_attack not consumed")
	_check(runtime.in_run_runtime.simulation.enemies[0].hp == 1000, label + ": enemy receives no damage")
	_check(runtime.in_run_runtime.simulation.next_player_attack_index == 1, label + ": no attack contract created")


func _end(runtime, id: String) -> void:
	_check(Opening.execute(runtime.context, "end", {"action_id": id}).get("ok", false), "actual avoidance end")
	_check(Opening.public_state(runtime.context).attack_allowed, "opening now permits attack")


func _test_input_gate() -> void:
	var runtime = _runtime()
	if runtime == null:
		return
	var before := Snapshot.capture_context(runtime.context)
	var request: Dictionary = runtime.in_run_runtime.request_attack(Vector2.RIGHT)
	_check(not request.get("ok", true) and request.get("reason") == &"opening_attack_blocked", "bridge reports avoidance rejection")
	_check(Snapshot.capture_context(runtime.context) == before, "rejected input does not mutate context or pill")
	_check(not runtime.in_run_runtime.simulation.queue_player_attack(Vector2.RIGHT), "direct simulation input cannot bypass opening gate")
	_step(runtime, 20)
	_check_waiting(runtime, "input rejection")
	_check(not runtime.in_run_runtime.simulation.attack_queued and runtime.in_run_runtime.simulation.player.attack_cooldown == 0.0, "rejected input leaves no buffer or cooldown")
	_release(runtime)


func _test_buffer_revalidation_and_release() -> void:
	var runtime = _runtime()
	if runtime == null:
		return
	var active_opening: Dictionary = runtime.context.z1_event_flags[Opening.KEY].duplicate(true)
	_end(runtime, "end_before_queue")
	_check(runtime.in_run_runtime.request_attack(Vector2.RIGHT).get("ok", false), "allowed attack queues")
	# Restore a valid active opening state between input and the authoritative tick.
	runtime.context.z1_event_flags[Opening.KEY] = active_opening
	_step(runtime, 12)
	_check_waiting(runtime, "queued attack revalidation")
	_check(not runtime.in_run_runtime.simulation.attack_queued, "blocked queued input is discarded")
	_end(runtime, "end_after_revalidation")
	_check(runtime.in_run_runtime.request_attack(Vector2.RIGHT).get("ok", false), "ending avoidance accepts new input")
	_step(runtime, 1)
	_check(_pill(runtime.context).get("phase") == "active" and _pill(runtime.context).get("remaining") == 12.0, "first permitted attack starts pill once without charging a time step")
	_step(runtime, 10)
	_check(runtime.in_run_runtime.simulation.enemies[0].hp == 975, "permitted real attack deals countdown125% damage")
	_release(runtime)


func _test_restore_binding() -> void:
	var runtime = _runtime()
	if runtime == null:
		return
	var saved: Dictionary = runtime.in_run_runtime.export_transaction_state()
	_check(runtime.in_run_runtime.validate_transaction_state(saved), "existing checkpoint shape remains valid")
	runtime.in_run_runtime.simulation = null
	runtime.in_run_runtime.import_transaction_state(saved)
	_check(not runtime.in_run_runtime.simulation.queue_player_attack(Vector2.RIGHT), "restored simulation rebinds live opening gate")
	_step(runtime, 12)
	_check_waiting(runtime, "restored attack rejection")
	_release(runtime)


func _test_impact_revalidation() -> void:
	var runtime = _runtime()
	if runtime == null:
		return
	var active_opening: Dictionary = runtime.context.z1_event_flags[Opening.KEY].duplicate(true)
	_end(runtime, "end_before_windup")
	_check(runtime.in_run_runtime.request_attack(Vector2.RIGHT).get("ok", false), "attack enters real windup")
	_step(runtime, 1)
	_check(_pill(runtime.context).get("phase") == "active", "earlier permitted attack legitimately started pill")
	runtime.context.z1_event_flags[Opening.KEY] = active_opening
	# The final damage entry also checks the live gate; no injected hit is accepted.
	runtime.in_run_runtime.simulation.call("_perform_player_attack")
	_check(runtime.in_run_runtime.simulation.enemies[0].hp == 1000, "direct impact entry cannot bypass restored avoidance")
	_step(runtime, 12)
	_check(runtime.in_run_runtime.simulation.enemies[0].hp == 1000, "windup cannot land damage after avoidance restoration")
	_check(is_equal_approx(float(_pill(runtime.context).get("remaining", -1)), 11.8), "gate checks neither restart nor double-advance an already active pill")
	_release(runtime)


func _test_legacy_attack() -> void:
	var runtime = _runtime(false)
	if runtime == null:
		return
	_check(runtime.in_run_runtime.request_attack(Vector2.RIGHT).get("ok", false), "legacy default still accepts attack")
	_step(runtime, 11)
	_check(runtime.in_run_runtime.simulation.enemies[0].hp == 980, "legacy actual damage remains20")
	_release(runtime)


func _release(runtime) -> void:
	runtime.in_run_runtime.bind(null)
	runtime.command_bus.item_command_handler.combat_active_query = Callable()
	runtime.command_bus.bind_runtime_controller(null)
	runtime.context = null
	runtime.in_run_runtime = null
	runtime.command_bus = null


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
