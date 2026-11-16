extends SceneTree

const Registry = preload("res://scripts/core/content/content_def_registry.gd")
const Snapshot = preload("res://scripts/core/run/run_state_snapshot.gd")
const Items = preload("res://scripts/core/content/z2_item_catalog.gd")
const Loot = preload("res://scripts/core/content/z2_loot_catalog.gd")
const Eligibility = preload("res://scripts/core/content/z2_content_eligibility.gd")
const Legacy = preload("res://scripts/core/content/m3_item_catalog.gd")
const Events = preload("res://scripts/core/run/z2_event_runtime.gd")
const Talents = preload("res://scripts/core/progression/z2_talent_catalog.gd")
const Goals = preload("res://scripts/core/progression/z2_goals/goal_catalog.gd")
const Maps = preload("res://scripts/core/content/m7_content_catalog.gd")
const Rules = preload("res://scripts/core/progression/z2_progression_rules.gd")
const Offer = preload("res://scripts/core/progression/z2_opening_offer.gd")
const LEGACY_BODY_SHA := "243541d8b4fb4123152f985554a8ebcdab96ed0c7ce5422082bc6b86d1be6611"
var checks := 0
var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var registry := Registry.new()
	if not registry.has_method("setup_z2"):
		_check(false, "setup_z2 is absent; active content hash still identifies legacy definitions")
	else:
		var ready: Dictionary = registry.call("setup_z2")
		_check(ready.get("ok", false), "complete Z2 registry builds: " + str(ready.get("reason", "")))
		if ready.get("ok", false):
			_test_items(registry)
			_test_catalogs(registry)
			_test_loot_and_rules(registry)
			_test_stability(registry)
			if OS.get_cmdline_user_args().has("--source-probes"):
				_test_source_changes(registry)
			print("Z2_REGISTRY_FINGERPRINT=" + Snapshot.fingerprint(registry.snapshot()))
	for failure in failures:
		print("Z2_REGISTRY_CASE_FAIL " + failure)
	print("Z2_CONTENT_REGISTRY=%s checks=%d failures=%d" % ["PASS" if failures.is_empty() else "FAIL", checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append(label)


func _ids(registry, prefix: String) -> Array:
	return registry.definitions.keys().filter(func(id): return str(id).begins_with(prefix))


func _definition(registry, id: String) -> Dictionary:
	return registry.get_content_def(id).get("definition", {})


func _test_items(registry) -> void:
	_check(_ids(registry, "item.").size() == 82 and registry.get_defs_by_kind(Registry.KIND_ITEM).size() == 82, "exact72 frozen plus10 inherited items")
	var allowed := {}
	for raw in Items.all_items():
		allowed[str(raw.item_id)] = true
		var expected: Dictionary = raw.duplicate(true)
		expected.erase("candidate_sprite_path")
		var actual := _definition(registry, "item." + str(raw.item_id))
		_check(actual == expected, "actual frozen definition/provenance " + str(raw.item_id))
		_check(str(actual.get("source_hash", "")).length() == 64 and int(actual.get("source_row", 0)) > 0, "source row/hash retained " + str(raw.item_id))
	for id in Loot.MONSTER_MATERIALS + Loot.OTHER_MATERIALS:
		_check(not allowed.has(id), "inherited material not mixed into frozen72 " + str(id))
		allowed[id] = true
		var actual := _definition(registry, "item." + id)
		_check(actual == Loot.definition(id) and actual.has("inherited_definition_source"), "actual allowed material/provenance " + id)
	var excluded := 0
	for raw in Legacy.all_items():
		if not allowed.has(str(raw.item_id)):
			excluded += 1
			_check(registry.get_content_def("item." + str(raw.item_id)).is_empty(), "old broad-pool item excluded " + str(raw.item_id))
	_check(excluded > 0, "legacy pool exclusion exercised")
	var shovel := _definition(registry, "item.eq_folding_shovel")
	_check(shovel.get("tier") == 5 and shovel.get("purchase_price") == 260 and shovel.get("weight") == 24 and shovel.get("source_id") == "S4", "new shovel tier/price/weight/source")
	_check(_definition(registry, "item.col_20").get("tier") == 3, "new collectible tier is actual S5, not old ID-derived tier")
	_check(not shovel.has("candidate_sprite_path") and shovel.get("candidate_sha256", "") != "", "machine authoring path omitted, content provenance preserved")


func _test_catalogs(registry) -> void:
	_check(_ids(registry, "event.").size() == 22, "22 canonical actual events")
	for id in Events.event_ids():
		var event := _definition(registry, "event." + str(id))
		_check(event.get("event_id") == id and event.get("min_profile_level") == Events.EVENT_LEVELS[id] and event.get("display_name") == Events.TITLES[id], "actual event route/eligibility " + str(id))
		_check(str(event.get("handler_source", "")).begins_with("res://scripts/core/run/z2_"), "actual event handler provenance " + str(id))
	_check(not registry.definitions.has("event.z1_event_e01") and _definition(registry, "event.information").get("aliases", []).has("z1_event_e04"), "aliases do not inflate event count")
	_check(_ids(registry, "talent.").size() == 39, "39 talents")
	for row in Talents.definitions():
		var actual := _definition(registry, "talent." + str(row.talent_id))
		for field in ["cost", "effect_kind", "effect_amount", "effect_params", "prerequisite_ids", "source_row"]:
			_check(actual.get(field) == row.get(field), "actual talent " + str(row.talent_id) + ":" + field)
	_check(_ids(registry, "goal.").size() == 50, "50 actual canonical goals")
	for row in Goals.definitions():
		_check(_definition(registry, "goal." + str(row.id)) == row, "actual goal milestones/rules/provenance " + str(row.id))
	_check(_ids(registry, "map.").size() == Rules.MAP_RULES.size(), "all nine Z2 maps")
	for raw in Maps.map_definitions():
		var expected: Dictionary = raw.duplicate(true)
		expected.merge(Rules.map_overrides(str(raw.id)), true)
		_check(_definition(registry, "map." + str(raw.id)) == expected, "map shape with actual Z2 progress " + str(raw.id))
	_check(_definition(registry, "map.classic_10x10_easy").get("min_profile_level") == 3, "map does not keep old level5 gate")
	_check(_ids(registry, "opening.").size() == 9, "actual9 opening effects represented")
	_check(_ids(registry, "research.").size() == Eligibility.research_definitions().size(), "actual research acquisition rules represented")


func _test_loot_and_rules(registry) -> void:
	_check(_ids(registry, "loot.").size() == Loot.CHANNELS.size(), "only actual10 Z2 acquisition channels")
	var rules := _definition(registry, "rules.z2")
	_check(rules.get("ruleset_id") == "z2" and rules.get("content_version") == Items.CONTENT_VERSION and rules.get("progression_version") == Rules.VERSION, "actual Z2 ruleset/content versions")
	var sources: Dictionary = rules.get("source_sha256", {})
	for path in ["res://scripts/core/content/z2_content_eligibility.gd", "res://scripts/core/content/z2_loot_catalog.gd", "res://scripts/core/content/z1_loot_catalog.gd", "res://scripts/core/rules/rule_effect_modifier_schema.gd", "res://scripts/core/progression/z2_goals/goal_conditions.gd"]:
		_check(str(sources.get(path, "")).length() == 64, "active rule/probability source covered " + path)
	for path in sources:
		_check(str(path).begins_with("res://") and str(sources[path]).length() == 64, "relative source identity and digest " + str(path))
	for channel in Loot.CHANNELS:
		var table := _definition(registry, "loot." + channel + ".z2")
		_check(table.get("source") == "res://scripts/core/content/z2_loot_catalog.gd" and table.get("qualification_policy") == "runtime_filter_before_normalization", "actual loot source/filter order " + channel)
		for map_id in Rules.MAP_RULES:
			for stage in range(1, 6) if channel == "altar" else [1]:
				var actual: Array = table.get("reference_pools", {}).get(map_id, {}).get(str(stage), [])
				var expected: Array = Loot.candidates(channel, table.get("reference_qualification", {}), map_id, stage)
				_check(actual == expected, "actual probability reference " + channel + ":" + map_id + ":" + str(stage))
				for entry in actual:
					_check(registry.definitions.has("item." + str(entry.item_id)), "loot references only registered item " + str(entry.item_id))
	_check(not JSON.stringify(registry.snapshot()).contains("D:/AGAME2/") and not JSON.stringify(registry.snapshot()).contains("C:/Users/"), "no workstation path in content snapshot")


func _test_stability(registry) -> void:
	var hash_before := Snapshot.fingerprint(registry.snapshot())
	var legacy := Registry.new()
	legacy.setup_defaults()
	var legacy_hash := Snapshot.fingerprint(legacy.snapshot())
	_check(legacy_hash != hash_before, "Z2 hash genuinely differs from legacy")
	var source := FileAccess.get_file_as_string("res://scripts/core/content/content_def_registry.gd").replace("\r\n", "\n")
	var start := source.find("func setup_defaults() -> void:")
	var end := source.find("\n\nfunc ", start + 1)
	_check(source.substr(start, end - start).strip_edges().sha256_text() == LEGACY_BODY_SHA, "legacy setup_defaults body unchanged")
	var isolated: Dictionary = registry.snapshot()
	isolated["item.eq_folding_shovel"].definition.purchase_price = 1
	var returned: Dictionary = registry.get_content_def("item.eq_folding_shovel")
	returned.definition.tier = 1
	_check(Snapshot.fingerprint(registry.snapshot()) == hash_before, "queries return independent copies")
	var meta := {"profile_id": "session", "ruleset_id": "z2", "z2_progression_version": 1, "gold": 1000, "run_count": 0, "talent_flags": ["z2_talent_15"], "admission": {}}
	for level in [1, 15, 50]:
		meta.profile_level = level
		var frozen := Eligibility.freeze_profile(meta)
		Loot.candidates("search", frozen, "classic_10x10_standard")
		Events.event_pool(frozen)
		var offer := Offer.execute(meta, "prepare", {"request_id": "prepare"})
		_check(offer.get("ok", false), "camp prepare really executes at profile level " + str(level))
		if offer.get("ok", false):
			var refreshed := Offer.execute(offer.meta, "refresh", {"request_id": "refresh", "offer_id": offer.offer.offer_id})
			_check(refreshed.get("ok", false) and refreshed.get("expense", {}).get("amount") == 5 and refreshed.get("meta", {}).get("gold") == 995, "camp session really spends gold without changing content at level " + str(level))
		registry.content_delivery_preview({"run_id": "another-session", "seed": level, "clock": Time.get_ticks_msec()})
		var rebuilt: Dictionary = registry.call("setup_z2")
		_check(rebuilt.get("ok", false) and Snapshot.fingerprint(registry.snapshot()) == hash_before, "profile/clock/session/camp operations never change build hash " + str(level))
	registry.setup_defaults()
	_check(Snapshot.fingerprint(registry.snapshot()) == legacy_hash, "legacy setup after Z2 resets to exact legacy definitions")
	registry.call("setup_z2")
	_check(Snapshot.fingerprint(registry.snapshot()) == hash_before, "Z2 setup is repeatable after legacy")


func _test_source_changes(registry) -> void:
	var project_root := ProjectSettings.globalize_path("res://").replace("\\", "/")
	if not project_root.begins_with("D:/AGAME2/.tmp/z2/registry/"):
		_check(false, "source mutation probes require the isolated D registry mirror")
		return
	var baseline := Snapshot.fingerprint(registry.snapshot())
	for probe in [
		["res://scripts/core/content/z1_loot_catalog.gd", "0.15, 0.20, 0.15", "0.16, 0.20, 0.15"],
		["res://scripts/core/content/z2_content_eligibility.gd", "if level < 1:", "if level < 2:"],
		["res://scripts/core/rules/rule_effect_modifier_schema.gd", "const SCHEMA_VERSION := 1", "const SCHEMA_VERSION := 2"],
	]:
		var original := FileAccess.get_file_as_string(probe[0])
		_check(original.contains(probe[1]), "source mutation is meaningful " + probe[0])
		_write(probe[0], original.replace(probe[1], probe[2]))
		var changed: Dictionary = registry.call("setup_z2")
		var hash_after := Snapshot.fingerprint(registry.snapshot())
		_write(probe[0], original)
		_check(changed.get("ok", false) and hash_after != baseline, "actual source change invalidates fingerprint " + probe[0])
		registry.call("setup_z2")
		_check(Snapshot.fingerprint(registry.snapshot()) == baseline, "restored source restores fingerprint " + probe[0])
	var added := "res://scripts/core/rules/z2_registry_probe.gd"
	if FileAccess.file_exists(added):
		_check(false, "probe path unexpectedly exists")
		return
	_write(added, "extends RefCounted\nconst PROBE_RULE := 2\n")
	registry.call("setup_z2")
	var new_rule_hash := Snapshot.fingerprint(registry.snapshot())
	DirAccess.remove_absolute(ProjectSettings.globalize_path(added))
	_check(new_rule_hash != baseline, "new rule directory member invalidates fingerprint")
	registry.call("setup_z2")
	_check(Snapshot.fingerprint(registry.snapshot()) == baseline, "directory probe restored")
	var item_source := "res://scripts/core/content/z2_item_catalog.gd"
	var original := FileAccess.get_file_as_string(item_source)
	_write(item_source, original.replace("D:/AGAME2/_worktrees/z1-scene-art", "E:/relocated/authoring-worktree"))
	registry.call("setup_z2")
	var relocated := Snapshot.fingerprint(registry.snapshot())
	_write(item_source, original)
	_check(relocated == baseline, "authoring workstation path changes do not change content hash")
	_write(item_source, original.replace("\r\n", "\n").replace("\n", "\r\n"))
	registry.call("setup_z2")
	var newline_hash := Snapshot.fingerprint(registry.snapshot())
	_write(item_source, original)
	_check(newline_hash == baseline, "CRLF/LF transport does not change source digest")
	var required_source := "res://scripts/core/content/z1_loot_catalog.gd"
	original = FileAccess.get_file_as_string(required_source)
	var before: Dictionary = registry.snapshot()
	_write(required_source, "")
	var rejected: Dictionary = registry.call("setup_z2")
	_write(required_source, original)
	_check(not rejected.get("ok", true) and registry.snapshot() == before, "empty required rule source cannot publish a partial registry")
	registry.call("setup_z2")
	_check(Snapshot.fingerprint(registry.snapshot()) == baseline, "all source probes restored exact content hash")


func _write(path: String, content: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(content)
	file.close()
