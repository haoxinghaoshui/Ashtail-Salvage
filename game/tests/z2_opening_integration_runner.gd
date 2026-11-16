extends SceneTree

const Runtime = preload("res://scripts/core/run/run_runtime_controller.gd")
const Meta = preload("res://scripts/core/save/meta_progress_adapter.gd")
const Rules = preload("res://scripts/core/progression/z2_progression_rules.gd")
const Offer = preload("res://scripts/core/progression/z2_opening_offer.gd")
const Snapshot = preload("res://scripts/core/run/run_state_snapshot.gd")
var checks := 0
var failures: Array[String] = []

class CutSave extends SaveAdapter:
	var cut := false
	func save_json(payload: Dictionary, path: String = "", pretty: bool = true) -> bool:
		if cut:
			last_error = "injected_opening_save_failure"
			return false
		return super.save_json(payload, path, pretty)

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var meta := Meta.new()
	meta.set_active_profile_path("user://z2_opening_integration_%d/meta.json" % Time.get_ticks_usec(), "opening-integration")
	meta.initialize_z2_profile(Rules.CONTENT_VERSION)
	meta.data.tutorial_completed = true
	meta.data.profile_level = Rules.level_for_exp(12650)
	meta.data.profile_exp = 12650
	meta.data.talent_flags = []
	for number in range(1, 16):
		meta.data.talent_flags.append("z2_talent_%02d" % number)
	meta.data.talent_earned = 2000
	meta.data.talent_spent = 1500
	meta.data.talent_points = 500
	meta.data.gold = 1000
	meta.save()
	var r := Runtime.new()
	r.bind_meta_progress_adapter(meta)
	var prepare := _request("prepare", "prepare-offer")
	var prepared: Dictionary = r.execute_meta_action(prepare)
	_check(prepared.get("ok", false), "prepare actual camp offer " + str(prepared.get("result", {}).get("error", prepared.get("result", {}).get("reason", ""))))
	var cached_state := r.capture_authoritative_state()
	_check(var_to_bytes(cached_state.meta_action_cache).size() < var_to_bytes(prepared).size() * 0.7, "cached receipt does not duplicate the complete meta projection")
	var repeated := prepared.duplicate(true)
	repeated["duplicate"] = true
	_check(r.execute_meta_action(prepare) == repeated, "compact receipt replays the complete original response")
	var cache_restored := Runtime.new()
	cache_restored.bind_meta_progress_adapter(meta)
	cache_restored.install_authoritative_state(Snapshot.unpack_checkpoint(Snapshot.pack_checkpoint(cached_state)).state)
	_check(cache_restored.execute_meta_action(prepare) == repeated, "native checkpoint roundtrip preserves full receipt replay")
	cache_restored.command_bus.runtime_controller = null
	cache_restored.command_bus.room_resolver.bind_runtime_controller(null)
	cache_restored.in_run_runtime.bind(null)
	if not meta.data.has("z2_opening_offer"):
		_finish(r)
		return
	var first: Dictionary = meta.data.z2_opening_offer.duplicate(true)
	_check(first.candidates.size() == 3, "persist three real candidates")
	var restart := Meta.new()
	restart.set_active_profile_path(meta.active_meta_progress_path, meta.active_profile_id)
	restart.load_or_create_default()
	var reloaded: Dictionary = restart.data.z2_opening_offer
	_check(Offer.valid_offer(reloaded) and reloaded.candidates == first.candidates and int(reloaded.seed) == int(first.seed) and reloaded.offer_id == first.offer_id, "reopen keeps exact candidates and seed")
	var reopened := Runtime.new()
	reopened.bind_meta_progress_adapter(restart)
	_check(reopened.execute_meta_action(prepare).get("duplicate", false), "reopened runtime reuses durable preparation receipt")
	reopened.command_bus.runtime_controller = null
	reopened.command_bus.room_resolver.bind_runtime_controller(null)
	reopened.in_run_runtime.bind(null)
	var refresh := _request("refresh", "refresh-failure", {"offer_id": first.offer_id})
	var previous := meta.data.duplicate(true)
	var cutter := CutSave.new()
	cutter.cut = true
	meta.save_adapter = cutter
	_check(not r.execute_meta_action(refresh).get("ok", true) and meta.data == previous, "failed save rolls back charge and redraw")
	cutter.cut = false
	var retry: Dictionary = r.execute_meta_action(refresh)
	_check(retry.get("ok", false), "same failed request retries successfully " + str(retry.get("status", "")) + ":" + str(retry.get("result", {}).get("error", "")))
	_check(meta.data.gold == 995, "refresh charges once")
	r.execute_meta_action(refresh)
	_check(meta.data.gold == 995, "durable replay cannot charge again")
	var current: Dictionary = meta.data.z2_opening_offer
	while not current.candidates.has("rebate") and int(current.refresh_count) < 10:
		var refreshed: Dictionary = r.execute_meta_action(_request("refresh", "find-rebate:%d" % int(current.refresh_count), {"offer_id": current.offer_id}))
		if not refreshed.get("ok", false):
			break
		current = meta.data.z2_opening_offer
	_check(current.candidates.has("rebate"), "fixture reaches rebate using legal refreshes")
	if not current.candidates.has("rebate"):
		_finish(r)
		return
	_check(r.execute_meta_action(_request("choose", "choose-rebate", {"offer_id": current.offer_id, "effect_id": "rebate"})).get("ok", false), "select one offered actual effect")
	r.checkpoint_writer = func(_candidate: Dictionary) -> Dictionary: return {"ok": true}
	var commission: Dictionary = M7ContentCatalog.commission_offer_candidates("classic_7x7_simple", 0, 3)[0]
	var started: Dictionary = r.command_bus.dispatch(&"start_standard_run", {"run_start_config": {"map_config_id": "classic_7x7_simple", "difficulty": "simple", "seed_value": 20261116, "selected_objective_id": commission.id, "z2_opening_offer": {"selected": "avoidance"}}})
	_check(started.get("ok", false), "trusted selected effect admits into actual departure")
	if started.get("ok", false):
		_check(r.context.z1_event_flags.get("z2_opening", {}).get("selected") == "rebate", "client injected opening cannot replace trusted choice")
		_check(r.context.run_start_config.get("opening_effect", {}).get("id") == "rebate", "actual opening fact frozen for goals")
		for index in range(16):
			var credited: Dictionary = r.execute_atomic_operation(&"fixture_income", {"index": index}, func() -> Dictionary:
				return RunAssetEffectHandler.apply_effects(r.context, [{"type": RunAssetEffectHandler.EFFECT_ADD_CURRENCY, "source": "actual_income_fixture", "payload": {"currency_id": &"black_coin", "amount": 5}}]), "credit:%d" % index)
			_check(credited.get("ok", false), "actual positive credit %d" % index)
		_check(r.context.asset_ledger.get_currency(&"black_coin") == 50 and r.context.asset_ledger.get_currency(&"gold_coin") == 50, "80 gross charges at most30 and grants50 safe")
		var saved := Snapshot.capture_context(r.context)
		r.execute_atomic_operation(&"fixture_income", {"index": 15}, func() -> Dictionary: return {"ok": false}, "credit:15")
		_check(Snapshot.capture_context(r.context) == saved, "credit replay cannot repeat fee or rebate")
	_finish(r)

func _request(action: String, request_id: String, fields: Dictionary = {}) -> Dictionary:
	var request := {"source_page": "deploy_prep", "action": "opening_" + action, "request_id": request_id}
	request.merge(fields)
	return request

func _finish(r) -> void:
	r.command_bus.runtime_controller = null
	r.command_bus.room_resolver.bind_runtime_controller(null)
	r.in_run_runtime.bind(null)
	for failure in failures:
		print("Z2_OPENING_INTEGRATION_FAIL " + failure)
	print("Z2_OPENING_INTEGRATION=%s checks=%d failures=%d" % ["PASS" if failures.is_empty() else "FAIL", checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)
