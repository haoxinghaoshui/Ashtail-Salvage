extends RefCounted
class_name ContentDefRegistry

# G8.2 stable ContentDef registry. Definitions are data only and never mutate state.

const ContentDeliverySchemaScript := preload("res://scripts/core/content/content_delivery_schema.gd")
const M3ItemCatalogScript := preload("res://scripts/core/content/m3_item_catalog.gd")

# These are actual shared inputs of the Z2 handlers, not legacy item pools to
# register. Z2 modules and rule/goal directory members are also discovered below.
const Z2_SHARED_RULE_SOURCES := [
	"res://scripts/core/content/content_def_registry.gd",
	"res://scripts/core/content/content_delivery_schema.gd",
	"res://scripts/core/content/m3_item_catalog.gd",
	"res://scripts/core/content/m7_content_catalog.gd",
	"res://scripts/core/content/m3r_item_usability_model.gd",
	"res://scripts/core/content/z1_supply_catalog.gd",
	"res://scripts/core/content/z1_loot_catalog.gd",
	"res://scripts/core/run/run_balance_catalog.gd",
	"res://scripts/core/run/run_runtime_controller.gd",
	"res://scripts/core/run/run_state_machine.gd",
	"res://scripts/core/run/run_start_config.gd",
	"res://scripts/core/run/run_start_route_adapter.gd",
	"res://scripts/core/run/run_context.gd",
	"res://scripts/core/run/run_config.gd",
	"res://scripts/core/run/run_state_snapshot.gd",
	"res://scripts/core/run/run_action_transaction.gd",
	"res://scripts/core/run/run_result_builder.gd",
	"res://scripts/core/run/g41_in_run_runtime.gd",
	"res://scripts/core/run/event_service.gd",
	# Presentation is also persisted in event responses; keep its version pinned.
	"res://scripts/core/run/z2_event_dialogue_catalog.gd",
	"res://scripts/core/run/protocol_service.gd",
	"res://scripts/core/run/tutorial_service.gd",
	"res://scripts/core/run/run_scene.gd",
	"res://scripts/core/run/run_scene_input_router.gd",
	"res://scripts/core/run/run_scene_meta_committer.gd",
	"res://scripts/core/run/run_scene_persistence_controller.gd",
	"res://scripts/core/run/run_scene_modal_controller.gd",
	"res://scripts/core/progression/m7_progression_service.gd",
	"res://scripts/core/progression/m7_talent_catalog.gd",
	"res://scripts/core/save/meta_progress_adapter.gd",
	"res://scripts/core/save/run_checkpoint_service.gd",
	"res://scripts/core/save/save_adapter.gd",
	"res://scripts/core/save/save_manager.gd",
	"res://scripts/core/map/minefield_service.gd",
	"res://scripts/gameplay/player/player_controller.gd",
	"res://scripts/core/run/run_rule_service.gd",
	"res://scripts/core/run/run_rule_pipeline.gd",
	"res://scripts/core/run/run_modifier_spec.gd",
	"res://scripts/core/run/run_asset_ledger.gd",
	"res://scripts/core/run/run_asset_effect_handler.gd",
	"res://scripts/core/run/run_effect_applier.gd",
	"res://scripts/core/run/run_vitals_resolver.gd",
	"res://scripts/core/run/run_status_service.gd",
	"res://scripts/core/run/run_settlement_service.gd",
	"res://scripts/core/run/run_inventory.gd",
	"res://scripts/core/run/room_resolver.gd",
	"res://scripts/core/run/combat_state.gd",
	"res://scripts/core/run/tutorial_map_catalog.gd",
	"res://scripts/core/map/truth_map.gd",
	"res://scripts/core/run/encounter/room_encounter_common_rule_schema.gd",
	"res://scripts/core/intel/intel_map.gd",
	"res://scripts/gameplay/combat/g41_combat_simulation.gd",
	"res://scripts/gameplay/combat/z1_monster_catalog.gd",
]

const Z2_RULE_DIGEST_PATH := "res://data/z2/rule_source_digest.json"
const Z2_RULE_DIGEST_POLICY := "utf8_lf_authoring_paths_excluded_v1"

const KIND_CURRENCY := &"CurrencyDef"
const KIND_ITEM := &"ItemDef"
const KIND_ENCOUNTER := &"EncounterDef"
const KIND_EFFECT := &"EffectDef"
const KIND_MODIFIER := &"ModifierDef"
const KIND_LOOT_TABLE := &"LootTableDef"

var definitions: Dictionary = {}


func setup_defaults() -> void:
	definitions.clear()
	register_content_def("currency.black_coin", KIND_CURRENCY, "currency.black_coin", ["currency", "run"], {"currency_id": &"black_coin", "scope": &"run"})
	register_content_def("currency.gold_coin", KIND_CURRENCY, "currency.gold_coin", ["currency", "meta"], {"currency_id": &"gold_coin", "scope": &"meta"})
	register_content_def("currency.safe_yield", KIND_CURRENCY, "currency.safe_yield", ["currency", "safe_yield"], {"currency_id": &"safe_yield", "scope": &"settlement"})
	register_content_def("currency.long_term_gold", KIND_CURRENCY, "currency.long_term_gold", ["currency", "meta"], {"currency_id": &"long_term_gold", "scope": &"meta"})
	for item_def in M3ItemCatalogScript.all_items():
		var item_id := String(item_def.get("item_id", "unknown"))
		register_content_def("item.%s" % item_id, KIND_ITEM, "item.%s" % item_id, item_def.get("tags", []), item_def)
	register_content_def("encounter.search_basic", KIND_ENCOUNTER, "encounter.search_basic", ["encounter", "search"], {"room_type": &"Normal"})
	register_content_def("encounter.chest_basic", KIND_ENCOUNTER, "encounter.chest_basic", ["encounter", "loot"], {"room_type": &"Chest"})
	register_content_def("effect.asset.add_currency", KIND_EFFECT, "effect.asset.add_currency", ["effect", "asset"], {"type": &"asset.add_currency"})
	register_content_def("effect.asset.move_item", KIND_EFFECT, "effect.asset.move_item", ["effect", "asset"], {"type": &"asset.move_item"})
	register_content_def("effect.asset.consume_item", KIND_EFFECT, "effect.asset.consume_item", ["effect", "asset", "consumable"], {"type": &"asset.consume_inventory_item"})
	register_content_def("modifier.capacity.none", KIND_MODIFIER, "modifier.capacity.none", ["modifier", "noop"], {"target_rule": &"pickup_ground_item", "operation": &"none"})
	for table_id in [&"search", &"chest", &"monster", &"event", &"altar", &"debug"]:
		var entries: Array[String] = []
		for item_def in M3ItemCatalogScript.drop_table(table_id):
			entries.append("item.%s" % String(item_def.get("item_id", "unknown")))
		register_content_def("loot.%s.default" % String(table_id), KIND_LOOT_TABLE, "loot.%s.default" % String(table_id), ["loot", String(table_id)], {"entries": entries, "default_location": &"room_floor", "unique_drop_allowed": false})


func setup_z2() -> Dictionary:
	# Load only at explicit Z2 setup; legacy setup_defaults stays independent.
	var items: Script = load("res://scripts/core/content/z2_item_catalog.gd")
	var loot: Script = load("res://scripts/core/content/z2_loot_catalog.gd")
	var eligibility: Script = load("res://scripts/core/content/z2_content_eligibility.gd")
	var events: Script = load("res://scripts/core/run/z2_event_runtime.gd")
	var talents: Script = load("res://scripts/core/progression/z2_talent_catalog.gd")
	var goals: Script = load("res://scripts/core/progression/z2_goals/goal_catalog.gd")
	var maps: Script = load("res://scripts/core/content/m7_content_catalog.gd")
	var rules: Script = load("res://scripts/core/progression/z2_progression_rules.gd")
	var opening: Script = load("res://scripts/core/progression/z2_opening_offer.gd")
	var sources := _z2_rule_sources()
	if not sources.ok:
		return sources
	var candidate = get_script().new()
	var frozen_items: Array = items.all_items()
	var materials: Array = loot.MONSTER_MATERIALS + loot.OTHER_MATERIALS
	var event_ids: Array = events.event_ids()
	var talent_defs: Array = talents.definitions()
	var goal_defs: Array = goals.definitions()
	if frozen_items.size() != 72 or materials.size() != 10 or event_ids.size() != 22 or talent_defs.size() != 39 or goal_defs.size() != 50:
		return {"ok": false, "reason": "z2_catalog_count_mismatch"}
	for original: Dictionary in frozen_items:
		var item := original.duplicate(true)
		# An unimported art candidate's workstation path is not runtime content.
		# candidate_id/hash and S4/S5 source provenance remain intact.
		item.erase("candidate_sprite_path")
		var id := "item." + str(item.item_id)
		if candidate.definitions.has(id):
			return {"ok": false, "reason": "duplicate_z2_item", "content_id": id}
		candidate.register_content_def(id, KIND_ITEM, id, item.get("tags", []), item)
	for item_id: String in materials:
		var material: Dictionary = loot.definition(item_id)
		var id := "item." + item_id
		if material.is_empty() or candidate.definitions.has(id):
			return {"ok": false, "reason": "invalid_inherited_material", "content_id": id}
		candidate.register_content_def(id, KIND_ITEM, id, material.get("tags", []), material)
	for event_id: String in event_ids:
		var aliases: Array = []
		for alias in events.ALIASES:
			if events.ALIASES[alias] == event_id:
				aliases.append(alias)
		aliases.sort()
		var handler := "z2_economy_events" if events.ECONOMY.has(event_id) else ("z2_information_events" if events.INFORMATION.has(event_id) else "z2_process_events")
		candidate.register_content_def("event." + event_id, KIND_ENCOUNTER, "event." + event_id, ["z2", "event"], {
			"event_id": event_id, "display_name": events.TITLES[event_id], "min_profile_level": events.EVENT_LEVELS[event_id],
			"aliases": aliases, "source": "res://scripts/core/run/z2_event_runtime.gd", "handler_source": "res://scripts/core/run/" + handler + ".gd",
			"weight_total": events.EVENT_WEIGHT_TOTAL, "selection_policy": "unique22_equal_after_level_filter"})
	for original: Dictionary in talent_defs:
		var talent := original.duplicate(true)
		talent["source_hash"] = talents.SOURCE_SHA256
		var id := "talent." + str(talent.talent_id)
		candidate.register_content_def(id, KIND_MODIFIER, id, ["z2", "talent"], talent)
	for goal: Dictionary in goal_defs:
		var id := "goal." + str(goal.id)
		candidate.register_content_def(id, KIND_ENCOUNTER, id, ["z2", "goal", str(goal.kind)], goal)
	for original: Dictionary in maps.map_definitions():
		var map := original.duplicate(true)
		if not rules.MAP_RULES.has(str(map.id)):
			continue
		map.merge(rules.map_overrides(str(map.id)), true)
		var id := "map." + str(map.id)
		candidate.register_content_def(id, KIND_ENCOUNTER, id, ["z2", "map"], map)
	for research: Dictionary in eligibility.research_definitions():
		var id := "research." + str(research.id)
		candidate.register_content_def(id, KIND_MODIFIER, id, ["z2", "research"], research)
	for index in range(opening.IDS.size()):
		var id := "opening." + str(opening.IDS[index])
		candidate.register_content_def(id, KIND_MODIFIER, id, ["z2", "opening"], {
			"effect_id": opening.IDS[index], "display_name": opening.LABELS[index], "description": opening.DESCRIPTIONS[index],
			"batch": 1, "required_talent": "z2_talent_15", "handler_source": "res://scripts/core/run/z2_opening_runtime.gd"})
	# Full build reference, not a profile-specific unlocked pool. Per-item gates
	# and their executable source digest cover all lower qualification levels.
	var reference := {"content_version": items.CONTENT_VERSION, "profile_level": 50, "research_completed_ids": []}
	for research: Dictionary in eligibility.research_definitions():
		reference.research_completed_ids.append(str(research.id))
	for channel: String in loot.CHANNELS:
		var pools := {}
		var entries: Array = []
		for map_id: String in rules.MAP_RULES:
			var stages := {}
			for stage in range(1, 6) if channel == "altar" else [1]:
				var pool: Array = loot.candidates(channel, reference, map_id, stage)
				stages[str(stage)] = pool
				for entry: Dictionary in pool:
					var id := "item." + str(entry.item_id)
					if not candidate.definitions.has(id):
						return {"ok": false, "reason": "unregistered_z2_loot_item", "content_id": id}
					if not entries.has(id):
						entries.append(id)
			pools[map_id] = stages
		entries.sort()
		var id := "loot." + channel + ".z2"
		candidate.register_content_def(id, KIND_LOOT_TABLE, id, ["z2", "loot", channel], {
			"channel": channel, "entries": entries, "default_location": &"room_floor", "unique_drop_allowed": false,
			"source": "res://scripts/core/content/z2_loot_catalog.gd", "weight_source": "res://scripts/core/content/z1_loot_catalog.gd",
			"qualification_policy": "runtime_filter_before_normalization", "reference_qualification": reference, "reference_pools": pools})
	var ledger := RunAssetLedger.new()
	ledger.setup({})
	for currency_id in ledger.currency_definitions:
		var id := "currency." + str(currency_id)
		candidate.register_content_def(id, KIND_CURRENCY, id, ["currency", "z2"], ledger.currency_definitions[currency_id])
	candidate.register_content_def("currency.safe_yield", KIND_CURRENCY, "currency.safe_yield", ["currency", "safe_yield"], {"currency_id": &"gold_coin", "alias_id": &"safe_yield", "scope": &"settlement"})
	candidate.register_content_def("rules.z2", KIND_MODIFIER, "rules.z2", ["z2", "ruleset"], {
		"ruleset_id": "z2", "content_version": items.CONTENT_VERSION, "progression_version": rules.VERSION,
		"talent_catalog_version": talents.CATALOG_VERSION, "registry_version": 1,
		"source_sha256": sources.digests, "source_digest_policy": "utf8_lf_authoring_paths_excluded_v1"})
	var expected := {"item.": 82, "event.": 22, "talent.": 39, "goal.": 50, "map.": rules.MAP_RULES.size()}
	for prefix: String in expected:
		var count := 0
		for id: String in candidate.definitions:
			if id.begins_with(prefix):
				count += 1
		if count != int(expected[prefix]):
			return {"ok": false, "reason": "duplicate_or_missing_z2_definition", "prefix": prefix}
	definitions = candidate.snapshot()
	return {"ok": true, "items": 82, "events": 22, "talents": 39, "goals": 50, "definitions": definitions.size(), "rule_sources": sources.digests.size()}


func _z2_rule_sources() -> Dictionary:
	# project.godot is replaced by project.binary in exported packs. A missing
	# authoring source must never silently fall back to a previously built digest.
	if FileAccess.file_exists("res://project.godot"):
		return _z2_source_hashes()
	if not FileAccess.file_exists(Z2_RULE_DIGEST_PATH):
		return {"ok": false, "reason": "missing_z2_rule_digest"}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(Z2_RULE_DIGEST_PATH))
	if not parsed is Dictionary:
		return {"ok": false, "reason": "invalid_z2_rule_digest"}
	return validate_z2_rule_digest(parsed, true)


func _z2_rule_paths() -> Array:
	var paths: Array = Z2_SHARED_RULE_SOURCES.duplicate()
	for directory in ["res://scripts/core/content", "res://scripts/core/progression", "res://scripts/core/run"]:
		for file in ResourceLoader.list_directory(directory):
			if file.begins_with("z2_") and file.ends_with(".gd"):
				var path: String = directory.path_join(file)
				if not paths.has(path):
					paths.append(path)
	for directory in ["res://scripts/core/rules", "res://scripts/core/progression/z2_goals", "res://scripts/core/command", "res://scripts/gameplay/combat"]:
		_z2_collect_rule_files(directory, paths)
	paths.sort()
	return paths


func _z2_source_hashes() -> Dictionary:
	var digests := {}
	var authoring_path := RegEx.new()
	authoring_path.compile('(\"candidate_sprite_path\"\\s*:\\s*\")[^\"]*(\")')
	for path: String in _z2_rule_paths():
		if not FileAccess.file_exists(path):
			return {"ok": false, "reason": "missing_z2_rule_source", "source": path}
		var source := FileAccess.get_file_as_string(path).replace("\r\n", "\n").replace("\r", "\n")
		if source.is_empty():
			return {"ok": false, "reason": "empty_z2_rule_source", "source": path}
		source = authoring_path.sub(source, "$1<authoring-path>$2", true)
		digests[path] = source.sha256_text()
	return {"ok": true, "digests": digests}


func _z2_collect_rule_files(directory: String, paths: Array) -> void:
	# ResourceLoader preserves original names after .gd -> compressed .gdc export.
	for entry in ResourceLoader.list_directory(directory):
		var path := directory.path_join(entry)
		if entry.ends_with("/") and not entry.begins_with("."):
			_z2_collect_rule_files(path, paths)
		elif entry.ends_with(".gd") and not paths.has(path):
			paths.append(path)


func z2_rule_fingerprint(digests: Dictionary) -> String:
	var paths := digests.keys()
	paths.sort()
	var lines := PackedStringArray()
	for path in paths:
		lines.append(str(path) + "=" + str(digests[path]))
	return "\n".join(lines).sha256_text()


func validate_z2_rule_digest(digest: Dictionary, packed: bool) -> Dictionary:
	if digest.get("schema_version") != 1 or digest.get("digest_policy") != Z2_RULE_DIGEST_POLICY:
		return {"ok": false, "reason": "invalid_z2_rule_digest_schema"}
	var paths := _z2_rule_paths()
	var hash_pattern := RegEx.new()
	hash_pattern.compile("^[0-9a-f]{64}$")
	for field in ["source_sha256", "compiled_sha256"]:
		var values: Variant = digest.get(field)
		if not values is Dictionary or values.size() != paths.size():
			return {"ok": false, "reason": "incomplete_z2_rule_digest", "field": field}
		for path: String in paths:
			if not values.get(path) is String or hash_pattern.search(values[path]) == null:
				return {"ok": false, "reason": "invalid_z2_rule_hash", "field": field, "source": path}
	if digest.get("source_fingerprint") != z2_rule_fingerprint(digest.source_sha256):
		return {"ok": false, "reason": "invalid_z2_rule_fingerprint"}
	var actual := _z2_compiled_hashes() if packed else _z2_source_hashes()
	if not actual.ok:
		return actual
	var expected: Dictionary = digest.compiled_sha256 if packed else digest.source_sha256
	for path: String in paths:
		if actual.digests[path] != expected[path]:
			return {"ok": false, "reason": "stale_z2_rule_digest", "source": path, "packed": packed}
	return {"ok": true, "digests": digest.source_sha256.duplicate(true)}


func _z2_compiled_hashes() -> Dictionary:
	var digests := {}
	for path: String in _z2_rule_paths():
		if not FileAccess.file_exists(path + ".remap"):
			return {"ok": false, "reason": "missing_z2_compiled_remap", "source": path}
		var remap := ConfigFile.new()
		if remap.load(path + ".remap") != OK:
			return {"ok": false, "reason": "invalid_z2_compiled_remap", "source": path}
		var target: Variant = remap.get_value("remap", "path", "")
		if not target is String or not target.begins_with("res://") or not target.ends_with(".gdc") or not FileAccess.file_exists(target):
			return {"ok": false, "reason": "missing_z2_compiled_rule", "source": path}
		var file := FileAccess.open(target, FileAccess.READ)
		if file == null or file.get_length() == 0:
			return {"ok": false, "reason": "empty_z2_compiled_rule", "source": path}
		var hash := FileAccess.get_sha256(target)
		if hash.length() != 64:
			return {"ok": false, "reason": "unreadable_z2_compiled_rule", "source": path}
		digests[path] = hash
	return {"ok": true, "digests": digests}


func register_content_def(content_id: String, kind: StringName, display_name_key: String, tags: Array, definition: Dictionary, schema_version: int = 1, deprecated_state: StringName = &"active") -> Dictionary:
	var content_def: Dictionary = {
		"content_id": content_id,
		"schema_version": schema_version,
		"kind": kind,
		"display_name_key": display_name_key,
		"tags": tags.duplicate(true),
		"definition": definition.duplicate(true),
		"deprecated_state": deprecated_state,
	}
	definitions[content_id] = content_def
	return content_def.duplicate(true)


func get_content_def(content_id: String) -> Dictionary:
	if not definitions.has(content_id):
		return {}
	return definitions[content_id].duplicate(true)


func get_defs_by_kind(kind: StringName) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for content_def in definitions.values():
		if StringName(content_def.get("kind", &"")) == kind:
			result.append(content_def.duplicate(true))
	return result


func snapshot() -> Dictionary:
	return definitions.duplicate(true)


func content_pool_preview() -> Dictionary:
	return ContentDeliverySchemaScript.build_registry_pool_preview(snapshot())


func content_delivery_preview(context: Dictionary = {}) -> Dictionary:
	return ContentDeliverySchemaScript.build_content_delivery_preview(content_pool_preview(), context)
