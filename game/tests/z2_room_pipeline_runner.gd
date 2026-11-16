extends SceneTree

const Runtime = preload("res://scripts/core/run/run_runtime_controller.gd")
const Meta = preload("res://scripts/core/save/meta_progress_adapter.gd")
const Rules = preload("res://scripts/core/progression/z2_progression_rules.gd")
const Events = preload("res://scripts/core/run/z2_event_runtime.gd")
const Snapshot = preload("res://scripts/core/run/run_state_snapshot.gd")
var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var meta := Meta.new()
	meta.set_active_profile_path("user://z2_room_pipeline_%d/meta.json" % Time.get_ticks_usec(), "room_pipeline")
	meta.initialize_z2_profile(Rules.CONTENT_VERSION)
	meta.data.tutorial_completed = true
	meta.data.profile_level = Rules.level_for_exp(12650)
	meta.data.profile_exp = 12650
	meta.data.talent_flags = ["z2_talent_01"]
	meta.data.talent_spent = 100
	meta.data.talent_points = 0
	meta.save()
	var r := Runtime.new()
	r.bind_meta_progress_adapter(meta)
	r.checkpoint_writer = func(_candidate: Dictionary) -> Dictionary: return {"ok": true}
	var commission: Dictionary = M7ContentCatalog.commission_offer_candidates("classic_13x13_normal", 0, 3)[0]
	var started: Dictionary = r.command_bus.dispatch(&"start_standard_run", {"run_start_config": {"map_config_id": "classic_13x13_normal", "difficulty": "normal", "seed_value": 3141, "selected_objective_id": commission.id}})
	_check(started.get("ok", false), "real authorized departure")
	if not started.get("ok", false):
		print("ROOM_START_FAILURE ", started)
	else:
		_check(r.has_method("z2_event_hooks"), "production runtime supplies actual event consumers")
		var c: RunContext = r.context
		c.asset_ledger.add_currency(&"black_coin", 1000, "fixture")
		c.power = 100
		var index := 0
		for event_id in Events.event_ids():
			var pos := Vector2i(index % 11 + 1, index / 11 + 1)
			index += 1
			c.truth_map.set_room_type(pos, &"Event")
			c.z1_event_rooms[c.cell_key(pos)] = {"event_type": StringName(event_id)}
			var entered := _enter(r, pos, "enter:" + event_id)
			_check(entered.get("ok", false), "real entry: " + event_id + " " + str(entered.get("reason", "")))
			var state := EventService.get_event_state(c, pos)
			_check(state.get("prepared", false), "entry prepares persisted offer: " + event_id)
			var before := Snapshot.capture_context(c)
			EventService.get_event_options(c, pos, StringName(event_id), bool(state.get("completed", false)))
			_check(Snapshot.capture_context(c) == before, "projection pure: " + event_id)
			if event_id == "shop" and state.get("prepared", false):
				for option in state.get("options", []):
					if str(option.id) != "buy" or not option.get("enabled", false):
						continue
					var payload: Dictionary = option.get("payload", {}).duplicate(true)
					payload.merge({"option_id": option.id, "action_id": "real-shop-buy"}, true)
					var bought: Dictionary = r.command_bus.dispatch(&"select_event_option", payload)
					_check(bought.get("ok", false), "shop action commits through real command bus")
					var paid := Snapshot.capture_context(c)
					r.command_bus.dispatch(&"select_event_option", payload)
					_check(Snapshot.capture_context(c) == paid, "replayed purchase cannot charge or advance twice")
					break
			if event_id == "cage":
				_check(EventService.cage_state(c, pos).get("active", false), "entry starts actual cage state")
				# The fixture ends the encounter before preparing the next independent room.
				r.in_run_runtime.reset()
		var stages := c.run_event_log.snapshot().filter(func(e: Dictionary) -> bool: return str(e.event_type) == "event_stage_completed")
		_check(not stages.is_empty(), "effective purchase emits durable stage facts")
		var generated := Vector2i(12, 12)
		c.truth_map.set_room_type(generated, &"Event")
		_check(_enter(r, generated, "generated-event").get("ok", false), "unbound event selected from actual pool")
		_check(not Events.stored_event_type(c, generated).is_empty(), "entry stores selected event identity")
	_release(r)
	for failure in failures:
		print("Z2_ROOM_PIPELINE_FAIL " + failure)
	print("Z2_ROOM_PIPELINE=%s checks=%d failures=%d" % ["PASS" if failures.is_empty() else "FAIL", checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _enter(r, pos: Vector2i, action_id: String) -> Dictionary:
	return r.execute_atomic_operation(&"room_entry", {}, func() -> Dictionary:
		r.context.player_pos = pos
		r.context.current_pos = pos
		return r.command_bus.room_resolver.enter_room(r.context), action_id)

func _release(r) -> void:
	r.command_bus.runtime_controller = null
	r.command_bus.room_resolver.bind_runtime_controller(null)
	r.in_run_runtime.bind(null)

func _check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)
