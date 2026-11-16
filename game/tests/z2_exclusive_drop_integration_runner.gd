extends SceneTree

# Real authority and saves in an explicitly isolated D QA root. No production
# mock, fake clear event, item injection, or changes to another owner's runner.
const LootPath := "res://scripts/core/content/z2_loot_catalog.gd"
const Content := preload("res://scripts/core/run/run_content_catalog.gd")
const Eligibility := preload("res://scripts/core/content/z2_content_eligibility.gd")
const Talents := preload("res://scripts/core/progression/z2_talent_catalog.gd")
const TalentRuntime := preload("res://scripts/core/progression/z2_talent_runtime.gd")
const Runtime := preload("res://scripts/core/run/run_runtime_controller.gd")
const Growth := preload("res://scripts/core/progression/z2_progression_rules.gd")
const TARGETS := ["mon_old_gear_set", "mon_broken_patrol_badge", "mon_overheated_core", "mon_loader_black_box", "mon_abnormal_instruction"]
const BATTLES := [
	["classic_7x7_simple", 1, false], ["classic_10x10_standard", 5, true],
	["classic_10x10_hard", 10, true], ["classic_13x13_normal", 15, true], ["classic_13x13_hell", 25, true],
]
const DIRECTIONS := [Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT, Vector2i.UP]
var loot: Variant
var checks := 0
var failures: Array[String] = []
var qa_home := ""
var phase := "suite"
var case_index := 0
var token := ""
var runtime: RunRuntimeController


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	qa_home = OS.get_environment("Z2_FORMAL_QA_HOME").replace("\\", "/").simplify_path().trim_suffix("/")
	if not _check(qa_home.is_absolute_path() and qa_home.to_lower().begins_with("d:/") and qa_home.length() > 3, "explicit absolute D QA root"):
		_finish()
		return
	for path in [OS.get_user_data_dir(), OS.get_environment("APPDATA"), OS.get_environment("LOCALAPPDATA"), OS.get_environment("TEMP"), OS.get_environment("TMP")]:
		_check(path.replace("\\", "/").simplify_path().to_lower().begins_with(qa_home.to_lower() + "/"), "isolated user/env path " + path)
	if not failures.is_empty():
		_finish()
		return
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--phase="): phase = arg.get_slice("=", 1)
		if arg.begins_with("--case="): case_index = int(arg.get_slice("=", 1))
		if arg.begins_with("--token="): token = arg.get_slice("=", 1)
	loot = load(LootPath)
	if phase == "suite" or phase == "unit":
		if _check(not FileAccess.file_exists("user://saves/manifest.json"), "suite requires fresh isolated saves"):
			_unit()
			if phase == "suite" and failures.is_empty(): _suite()
	elif phase in ["prepare", "resume", "verify", "invalid-admission"] and _check(case_index >= 0 and case_index < BATTLES.size() and token.is_valid_identifier(), "strict child arguments"):
		if _open():
			match phase:
				"prepare": _prepare()
				"resume": _resume()
				"verify": _verify()
				"invalid-admission": _invalid_admission()
	else:
		_check(false, "unknown phase")
	_finish()


func _profile(boost: bool = true) -> Dictionary:
	return TalentRuntime.run_profile({"ruleset_id": "z2", "z2_progression_version": 1}, [Talents.definition("z2_talent_38")] if boost else [])


func _frozen(level: int) -> Dictionary:
	return Eligibility.freeze_profile({"profile_level": level, "research_completed_ids": ["research_hard_shell_patch", "research_red_battery", "research_black_box_bell"]})


func _checked(channel: String, frozen: Dictionary, map_id: String, stage: int = 1, profile: Dictionary = {}) -> Dictionary:
	# The pre-feature RED must be an assertion failure, not a missing-method crash.
	return loot.checked_pool(channel, frozen, map_id, stage, profile) if loot.has_method("checked_pool") else loot.preflight(channel, frozen, map_id, stage)


func _context(map_id: String, level: int, boost: bool) -> RunContext:
	var context := RunContext.new()
	context.start_run({"id": "exclusive_probe", "mode": &"standard", "seed": 19, "width": 3, "height": 3,
		"manual_map": {"spawn": Vector2i.ONE, "mines": [], "monsters": [], "events": [], "chests": [], "exits": []}})
	context.run_start_config.merge({"map_config_id": map_id, "profile_fields": {"ruleset_id": "z2", "z2_progression_version": 1, "content_eligibility": _frozen(level)},
		"active_talent_effects": [Talents.definition("z2_talent_38")] if boost else []}, true)
	context.profile_fields = context.run_start_config.profile_fields.duplicate(true)
	context.active_talent_effects.assign(context.run_start_config.active_talent_effects)
	return context


func _unit() -> void:
	_check(loot.has_method("checked_pool") and loot.has_method("preflight_config") and loot.has_method("frozen_talents"), "checked pool / admission / frozen talent API exists")
	var probability_proof: Array = []
	for map in M7ContentCatalog.map_definitions():
		var map_id := str(map.id)
		if bool(map.get("tutorial_map", false)): continue
		for level in range(1, 51):
			var frozen := _frozen(level)
			var base: Array = loot.candidates("monster", frozen, map_id)
			var adjusted := _checked("monster", frozen, map_id, 1, _profile())
			if not _check(adjusted.get("ok", false) and adjusted.pool.size() == base.size(), "eligible monster pool " + map_id + "/" + str(level)): continue
			var mass := _target_mass(base)
			var ids: Array = base.map(func(row: Dictionary) -> String: return str(row.item_id))
			_check(ids.has("mon_overheated_core") == (map_id in ["classic_13x13_normal", "classic_13x13_hard", "classic_13x13_hell"]), "overheated material only on 13 maps")
			_check(ids.has("mon_loader_black_box") == (map_id == "classic_13x13_hell"), "loader black box only 13 hell")
			var materials := 0.0
			var probability_total := 0.0
			var weight_total := 0.0
			var base_weight := 0.0
			for entry: Dictionary in base: base_weight += float(entry.roll_weight)
			for index in range(base.size()):
				var a: Dictionary = adjusted.pool[index]
				var b: Dictionary = base[index]
				var expected := float(b.probability) * (1.2 if TARGETS.has(str(b.item_id)) else (1.0 - 1.2 * mass) / (1.0 - mass))
				_check(a.item_id == b.item_id and absf(float(a.probability) - expected) < 1e-12, "exact target/complement probability " + map_id + "/" + str(level) + "/" + str(b.item_id))
				_check(absf(float(a.roll_weight) / base_weight - expected) < 1e-12, "roll_weight agrees with probability " + str(b.item_id))
				_check(Eligibility.is_eligible(str(a.item_id), "monster", frozen, map_id), "no qualification bypass " + str(a.item_id))
				if str(b.item_id).begins_with("mon_") or b.item_id == "sp_reset_spring": materials += float(b.probability)
				probability_total += float(a.probability)
				weight_total += float(a.roll_weight)
			var eligible_share := 0.65 + (0.25 if Eligibility.is_eligible("con_stabilizer", "monster", frozen, map_id) else 0.0) + (0.10 if Eligibility.is_eligible("eq_strapped_backplate", "monster", frozen, map_id) else 0.0)
			_check(absf(materials - 0.65 / eligible_share) < 1e-12 and mass <= 0.65 + 1e-12 and _target_mass(adjusted.pool) <= 0.78 + 1e-12, "65% pre-filter group share / 78% final target bound")
			_check(absf(probability_total - 1.0) < 1e-12 and absf(weight_total - base_weight) < 1e-12, "total probability and roll mass conserved")
			_check(_checked("monster", frozen, map_id, 1, _profile(false)).pool == base, "no talent exactly identity")
			_check(_checked("monster", frozen, map_id, 1, _profile()) == adjusted, "repeat checked call never double-applies")
			probability_proof.append({"map_id": map_id, "level": level, "base_target_mass": mass, "target_mass": _target_mass(adjusted.pool),
				"base_pool": base, "adjusted_pool": adjusted.pool, "map_level_reachable": level >= int(Growth.MAP_RULES[map_id][0])})
			if loot.has_method("checked_pool"):
				_check(loot.candidates("monster", frozen, map_id, 1, _profile()) == adjusted.pool and loot.preflight("monster", frozen, map_id, 1, _profile()) == adjusted, "all public pool entries share checked result")
			for channel in loot.CHANNELS:
				if channel == "monster": continue
				for stage in range(1, 6) if channel == "altar" else [1]:
					_check(_checked(channel, frozen, map_id, stage, _profile()).pool == loot.candidates(channel, frozen, map_id, stage), "other channel exactly unchanged " + channel)
	var map_id := "classic_13x13_hell"
	var context := _context(map_id, 50, true)
	var base: Array = loot.candidates("monster", _frozen(50), map_id)
	var expected := _reference_pool(base, true)
	seed(513)
	var global_next := randi()
	seed(513)
	_checked("monster", _frozen(50), map_id, 1, _profile())
	_check(randi() == global_next, "checked pool never advances global RNG")
	for seed_value in range(48):
		context.seed_value = seed_value
		var item := Content.monster_trophy(Vector2i.ONE, 3, context)
		_check(str(item.get("item_id", "")) == _reference_draw(expected, Vector2i.ONE, seed_value + 3)[0], "actual trophy consumes adjusted pool seed=" + str(seed_value))
		if not item.is_empty():
			var definition: Dictionary = loot.definition(str(item.item_id))
			_check(item.weight == definition.weight and item.base_value == definition.base_value, "actual item physical values untouched")
		if loot.has_method("checked_pool"):
			var draws: Array = loot.roll("monster", Vector2i.ONE, seed_value, _frozen(50), map_id, 3, 1, -1, _profile())
			_check(draws.map(func(row: Dictionary) -> String: return str(row.item_id)) == _reference_draw(expected, Vector2i.ONE, seed_value, 3), "same seed / three draws / exactly one randf each")
			var neutral: Array = loot.roll("monster", Vector2i.ONE, seed_value, _frozen(50), map_id, 3)
			_check(neutral.map(func(row: Dictionary) -> String: return str(row.item_id)) == _reference_draw(base, Vector2i.ONE, seed_value, 3), "no talent keeps original roll sequence")
	var plain := _context(map_id, 50, false)
	for channel in loot.CHANNELS:
		if channel == "monster": continue
		if loot.has_method("checked_pool"):
			_check(loot.roll(channel, Vector2i.ONE, 77, _frozen(50), map_id, 2, 4, 3, _profile()) == loot.roll(channel, Vector2i.ONE, 77, _frozen(50), map_id, 2, 4, 3), "other channel actual rolls identical " + channel)
	_check(loot.economy_catalog(plain) == loot.economy_catalog(context) and loot.process_rules(plain, 4) == loot.process_rules(context, 4), "economy and process adapters unchanged")
	var empty := _checked("monster", _frozen(0), map_id, 1, _profile())
	_check(not empty.ok and empty.pool.is_empty() and empty.reason == "empty_eligible_pool", "mandatory empty stays rejected")
	_check(not _checked("monster", _frozen(50), "unknown_map", 1, _profile()).ok, "unknown map remains locked")
	_check(not _checked("qualification", _frozen(50), map_id, 1, _profile()).ok, "qualification never an acquisition channel")
	var invalid := _profile()
	invalid.effects[0].effect_amount = 400
	_check(not _checked("monster", _frozen(50), map_id, 1, invalid).ok, "overflow configuration explicitly rejects")
	invalid.effects[0].effect_amount = -1
	_check(not _checked("monster", _frozen(50), map_id, 1, invalid).ok, "negative talent configuration rejects")
	if loot.has_method("preflight_config"):
		_check(loot.preflight_config(context.run_start_config).ok, "legal frozen config preflight")
		context.run_start_config.active_talent_effects[0].effect_amount = 400
		_check(not loot.preflight_config(context.run_start_config).ok, "invalid frozen config rejects before admission")
		var before_reward := RunStateSnapshot.capture_context(context)
		var refused := RunRuleService.apply_combat_reward(context, Vector2i.ONE, 3)
		_check(not refused.get("ok", true) and refused.get("reason") == "exclusive_probability_overflow", "actual reward consumer returns invalid configuration instead of fallback")
		_check(RunStateSnapshot.capture_context(context) == before_reward, "invalid reward cannot pay coins, draw items or write ledger facts")
		context = _context(map_id, 0, true)
		before_reward = RunStateSnapshot.capture_context(context)
		refused = RunRuleService.apply_combat_reward(context, Vector2i.ONE, 3)
		_check(not refused.get("ok", true) and refused.get("reason") == "empty_eligible_pool" and RunStateSnapshot.capture_context(context) == before_reward, "empty reward pool refuses before any mutation")
		_check(Content.monster_trophy(Vector2i.ONE, 3, context).is_empty(), "empty Z2 eligibility never falls back to legacy")
	context = _context(map_id, 50, true)
	var before := Content.monster_trophy(Vector2i.ONE, 3, context)
	context.active_talent_effects.clear()
	context.profile_fields.clear()
	_check(Content.monster_trophy(Vector2i.ONE, 3, context) == before, "consumer uses departure snapshot, not mutable live projections")
	var duplicate := _profile()
	duplicate.effects.append(duplicate.effects[0].duplicate(true))
	_check(not _checked("monster", _frozen(50), map_id, 1, duplicate).ok, "malformed duplicate projected profile rejected")
	var tutorial := TalentRuntime.run_profile({"ruleset_id": "z2", "z2_progression_version": 1}, [Talents.definition("z2_talent_38")], true)
	_check(_checked("monster", _frozen(50), map_id, 1, tutorial).pool == base, "tutorial cannot enable exclusive recovery")
	var proof := FileAccess.open(qa_home.path_join("probability-proof.json"), FileAccess.WRITE)
	if _check(proof != null, "analytic probability evidence opens"): proof.store_string(JSON.stringify(probability_proof, "\t"))


func _target_mass(pool: Array) -> float:
	var result := 0.0
	for row: Dictionary in pool:
		if TARGETS.has(str(row.item_id)): result += float(row.probability)
	return result


func _reference_pool(base: Array, boost: bool) -> Array:
	var result := base.duplicate(true)
	var mass := _target_mass(base)
	for row: Dictionary in result:
		if boost: row.probability *= 1.2 if TARGETS.has(str(row.item_id)) else (1.0 - mass * 1.2) / (1.0 - mass)
	return result


func _reference_draw(pool: Array, pos: Vector2i, seed_value: int, count: int = 1) -> Array:
	var random := RandomNumberGenerator.new()
	random.seed = ("z2:monster:%d:%d:%d:1" % [pos.x, pos.y, seed_value]).hash()
	var result: Array = []
	for index in range(count):
		var ticket := random.randf()
		var chosen: String = pool.back().item_id
		for row: Dictionary in pool:
			ticket -= float(row.probability)
			if ticket < 0.0:
				chosen = str(row.item_id)
				break
		result.append(chosen)
	return result


func _suite() -> void:
	token = "x" + Crypto.new().generate_random_bytes(8).hex_encode()
	for index in range(BATTLES.size()):
		for child_phase in ["prepare", "resume", "verify"]:
			var output: Array = []
			var args := PackedStringArray(["--headless", "--path", ProjectSettings.globalize_path("res://"), "--script", "res://tests/z2_exclusive_drop_integration_runner.gd", "--", "--phase=" + child_phase, "--case=" + str(index), "--token=" + token])
			var code := OS.execute(OS.get_executable_path(), args, output, true)
			var log := ""
			for chunk in output: log += str(chunk)
			var path := qa_home.path_join("battle-%d-%s.log" % [index, child_phase])
			var file := FileAccess.open(path, FileAccess.WRITE)
			if _check(file != null, "child log opens"): file.store_string(log)
			var clean := not log.contains("SCRIPT ERROR") and not log.contains("ERROR:") and not log.contains("WARNING:")
			var passed := _check(code == 0 and clean and log.contains("Z2_EXCLUSIVE_DROP_INTEGRATION_CHILD=PASS"), "battle %d/%s exit=%d" % [index, child_phase, code])
			print("EXCLUSIVE_BATTLE case=%d phase=%s exit=%d log=%s" % [index, child_phase, code, path])
			if not passed:
				print(log)
				return


func _open() -> bool:
	var manager := SaveManager.new()
	manager.load_manifest()
	if not _check(manager.switch_profile("exclusive_" + token + "_" + str(case_index)).get("ok", false), "isolated profile selected"): return false
	runtime = Runtime.new()
	runtime.bind_meta_progress_adapter(MetaProgressAdapter.new())
	var opened := runtime.initialize_z2_session(manager)
	return _check(opened.get("ok", false) and runtime.checkpoint_service != null and not runtime.checkpoint_writer.is_valid(), "actual Meta/Checkpoint initialize or restart")


func _stage() -> bool:
	var meta = runtime.meta_progress_adapter
	var selected: Array = BATTLES[case_index]
	var flags: Array = ["z2_talent_01"]
	if selected[2]:
		flags.clear()
		for number in range(1, 39): flags.append("z2_talent_%02d" % number)
	var cost := 0
	for id in flags: cost += int(Talents.definition(id).cost)
	meta.data.merge({"tutorial_completed": true, "profile_level": selected[1], "profile_exp": Growth.exp_for_level(int(selected[1])),
		"talent_flags": flags, "talent_earned": cost, "talent_spent": cost, "talent_points": 0, "gold": 1000,
		"map_success_counts": {"classic_10x10_easy": 1, "classic_10x10_standard": 1, "classic_13x13_normal": 1, "classic_13x13_hard": 1}}, true)
	# Stabilize the existing lazy quest projection before comparing authority.
	meta.get_summary()
	return _check(Growth.profile_error(meta.data).is_empty() and meta.save(), "legal level/prerequisite/wallet fixture persisted")


func _config() -> Dictionary:
	var map_id := str(BATTLES[case_index][0])
	return {"map_config_id": map_id, "difficulty": "", "seed_value": 71, "selected_objective_id": M7ContentCatalog.commission_offer_candidates(map_id, 0)[0].id}


func _prepare() -> void:
	if not _stage(): return
	var started: Dictionary = runtime.command_bus.dispatch(&"start_standard_run", {"run_start_config": _config()})
	if not _check(started.get("ok", false), "real standard departure " + str(started)): return
	var frozen: Dictionary = loot.frozen_talents(runtime.context.run_start_config) if loot.has_method("frozen_talents") else _profile(bool(BATTLES[case_index][2]))
	_check(TalentRuntime.amount(frozen, "exclusive_drop_bonus_percent") == (20 if BATTLES[case_index][2] else 0), "real Meta freezes correct talent amount")
	var path := _monster_path()
	if not _check(not path.is_empty(), "generated map has safe route to ordinary Monster"): return
	for direction in path:
		if not _check(runtime.command_bus.dispatch(&"attempt_room_transition", {"direction": direction}).get("ok", false), "actual room transition"): return
	if not _check(runtime.in_run_runtime.has_active_combat(), "real ordinary Monster simulation active"): return
	if not _check(runtime.save_current_checkpoint().get("ok", false), "real pre-fight Checkpoint saved"): return
	var context: RunContext = runtime.context
	var pos: Vector2i = context.get_current_pos()
	var base: Array = loot.candidates("monster", context.run_start_config.profile_fields.content_eligibility, str(BATTLES[case_index][0]))
	var power := int(runtime.in_run_runtime.simulation.encounter_profile.enemy_power)
	var reward := CombatState.reward_gold_for_enemy_power(power)
	_store({"before": runtime.capture_authoritative_state(), "pos": pos, "expected_id": _reference_draw(_reference_pool(base, bool(BATTLES[case_index][2])), pos, context.seed_value + reward)[0],
		"gold": context.asset_ledger.get_currency(&"black_coin"), "reward": reward, "base_target_mass": _target_mass(base), "boost": BATTLES[case_index][2]})


func _resume() -> void:
	var expected := _read()
	if not _check(not expected.is_empty() and runtime.capture_authoritative_state() == expected.before, "fresh process restores complete pre-fight authority"): return
	# Change only the camp profile after departure. The frozen run still owns its
	# original node38, even after a further real disk restore.
	var meta = runtime.meta_progress_adapter
	meta.data.talent_flags = ["z2_talent_01"]
	meta.data.talent_earned = 100
	meta.data.talent_spent = 100
	meta.data.talent_points = 0
	if not _check(meta.save(), "live camp talent change saved independently"): return
	var restored: Dictionary = runtime.checkpoint_service.load_checkpoint()
	if not _check(restored.get("ok", false) and runtime.restore_checkpoint_state(restored.snapshot.state, restored.snapshot).get("ok", false), "repeat real checkpoint install"): return
	var tick := 0
	while runtime.in_run_runtime.has_active_combat() and runtime.context.run_active and tick < 3600:
		var sim = runtime.in_run_runtime.simulation
		var player_pos: Vector2 = sim.player.pos
		var target := player_pos
		for enemy: Dictionary in sim.enemies:
			if int(enemy.get("hp", 0)) > 0:
				target = Vector2(enemy.pos)
				break
		var direction := (target - player_pos).normalized()
		runtime.in_run_runtime.request_attack(direction)
		var step: Dictionary = runtime.in_run_runtime.advance_frame(1.0 / 60.0, direction if player_pos.distance_to(target) > 0.15 else Vector2.ZERO, direction)
		if not step.get("step_result", {}).get("ok", true):
			_check(false, "real combat fixed step failed " + str(step.get("step_result")))
			break
		tick += 1
	var context: RunContext = runtime.context
	if not _check(context.truth_map.is_cleared(expected.pos) and context.run_active, "real attacks clear ordinary Monster within bound ticks=" + str(tick)): return
	var ground := context.asset_ledger.get_room_floor_items(expected.pos)
	if not _check(ground.size() == 1, "one ordinary clear produces exactly one floor item"): return
	_check(ground[0].item_id == expected.expected_id, "real clear consumes exactly-once adjusted probability")
	_check(context.asset_ledger.get_currency(&"black_coin") == expected.gold + expected.reward, "reward coin count unchanged")
	_check(ground[0].weight == loot.definition(str(ground[0].item_id)).weight, "real ledger preserves physical weight")
	_check(context.run_stats.get("monsters_defeated", 0) == 1, "one ordinary monster clear counted")
	_check(runtime.save_current_checkpoint().get("ok", false), "cleared reward checkpoint saved")
	expected["after"] = runtime.capture_authoritative_state()
	expected["item"] = ground[0].duplicate(true)
	expected["ticks"] = tick
	expected["clear_payload"] = {"source": "g41_combat_simulation", "combat_seed": context.enemy_state.get("combat_seed", 0),
		"combat_tick": context.enemy_state.get("combat_snapshot", {}).get("tick", 0), "combat_snapshot": context.enemy_state.get("combat_snapshot", {}).duplicate(true)}
	_store(expected)


func _verify() -> void:
	var expected := _read()
	if not _check(expected.has("after") and runtime.capture_authoritative_state() == expected.after, "fresh process restores committed reward exactly"): return
	var before_gold: int = runtime.context.asset_ledger.get_currency(&"black_coin")
	var before_items: Array = runtime.context.asset_ledger.get_room_floor_items(expected.pos)
	for index in range(2):
		var loaded: Dictionary = runtime.checkpoint_service.load_checkpoint()
		_check(loaded.get("ok", false) and runtime.restore_checkpoint_state(loaded.snapshot.state, loaded.snapshot).get("ok", false), "repeat cleared checkpoint install")
		var payload: Dictionary = expected.clear_payload.duplicate(true)
		payload["action_id"] = "exclusive-replay-" + str(index)
		var replay: Dictionary = runtime.command_bus.dispatch(&"resolve_runtime_combat", payload)
		_check(replay.get("ok", false) and replay.get("status") == &"runtime_combat_already_resolved" and not replay.get("action_result", {}).get("reward_committed", true), "replay refuses a second reward")
	_check(runtime.context.asset_ledger.get_room_floor_items(expected.pos) == before_items and runtime.context.asset_ledger.get_currency(&"black_coin") == before_gold, "restore/replay never duplicates item or coins")
	_check(runtime.context.run_stats.get("monsters_defeated", 0) == 1, "restore/replay never duplicates growth count")


func _invalid_admission() -> void:
	if not _stage(): return
	var before: Dictionary = runtime.meta_progress_adapter.data.duplicate(true)
	var state := runtime.capture_authoritative_state()
	var disk := FileAccess.get_file_as_bytes(runtime.meta_progress_adapter.active_meta_progress_path)
	var result: Dictionary = runtime.command_bus.dispatch(&"start_standard_run", {"run_start_config": _config()})
	print("INVALID_ADMISSION status=", result.get("status"), " issues=", result.get("action_result", {}).get("issues", []))
	_check(not result.get("ok", true) and result.get("status") == &"invalid_run_start_authority", "invalid content configuration rejected by formal authorization")
	_check(str(result.get("action_result", {}).get("issues", [])).contains("exclusive_probability_overflow"), "invalid admission exposes explicit content error")
	_check(runtime.meta_progress_adapter.data == before and FileAccess.get_file_as_bytes(runtime.meta_progress_adapter.active_meta_progress_path) == disk, "invalid admission leaves persisted Meta/fees/reservations unchanged")
	_check(runtime.capture_authoritative_state() == state and not runtime.context.run_started, "invalid admission never enters run")
	_check(not FileAccess.file_exists(runtime.checkpoint_service.checkpoint_path), "invalid admission writes no run checkpoint")


func _monster_path() -> Array:
	var origin: Vector2i = runtime.context.get_current_pos()
	var queue: Array[Vector2i] = [origin]
	var paths := {origin: []}
	while not queue.is_empty():
		var pos: Vector2i = queue.pop_front()
		for direction in DIRECTIONS:
			var next: Vector2i = pos + direction
			if not runtime.context.is_inside(next) or paths.has(next): continue
			var kind: StringName = runtime.context.truth_map.get_room_type(next)
			if kind not in [&"Normal", &"Monster"]: continue
			var path: Array = paths[pos].duplicate()
			path.append(direction)
			if kind == &"Monster": return path
			paths[next] = path
			queue.append(next)
	return []


func _store(data: Dictionary) -> void:
	var file := FileAccess.open("user://exclusive-%s-%d.bin" % [token, case_index], FileAccess.WRITE)
	if _check(file != null, "durable expected evidence opens"): file.store_var(data)


func _read() -> Dictionary:
	var file := FileAccess.open("user://exclusive-%s-%d.bin" % [token, case_index], FileAccess.READ)
	return file.get_var() if file != null else {}


func _check(ok: bool, message: String) -> bool:
	checks += 1
	if not ok: failures.append(message)
	return ok


func _finish() -> void:
	if runtime != null:
		runtime.in_run_runtime.bind(null)
		runtime.command_bus.bind_runtime_controller(null)
	for failure in failures: print("EXCLUSIVE_INTEGRATION_FAIL " + failure)
	var marker := "Z2_EXCLUSIVE_DROP_INTEGRATION" if phase in ["suite", "unit"] else "Z2_EXCLUSIVE_DROP_INTEGRATION_CHILD"
	print("%s=%s checks=%d failures=%d" % [marker, "PASS" if failures.is_empty() else "FAIL", checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
