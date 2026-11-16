extends RefCounted
class_name RunContentCatalog

# M2 effect-first content boundary.
# IDs and placeholder rewards are centralized here so Lua/UE parity tuning does not scatter.

const M3ItemCatalogScript := preload("res://scripts/core/content/m3_item_catalog.gd")
const M7ContentCatalogScript := preload("res://scripts/core/content/m7_content_catalog.gd")
const Z1LootCatalogScript := preload("res://scripts/core/content/z1_loot_catalog.gd")
const Z2LootCatalogScript := preload("res://scripts/core/content/z2_loot_catalog.gd")


static func search_items(pos: Vector2i, adjacent_mines: int, is_chest: bool, black_coin: int, context: RunContext = null) -> Array[Dictionary]:
	var seed_value := adjacent_mines * 11 + black_coin
	if _uses_z2_loot(context):
		return _z2_items(context, "chest" if is_chest else "search", pos, seed_value, 2 if is_chest and adjacent_mines >= 2 else 1, 1, adjacent_mines)
	if _uses_z1_loot(context):
		return _weighted_items(context, &"chest" if is_chest else &"search", pos, seed_value, 2 if is_chest and adjacent_mines >= 2 else 1, 1, adjacent_mines)
	if is_chest:
		return M3ItemCatalogScript.deterministic_drop(&"chest", pos, seed_value, 2 if adjacent_mines >= 2 else 1)
	if adjacent_mines >= 2:
		return M3ItemCatalogScript.deterministic_drop(&"search", pos, seed_value, 1)
	return M3ItemCatalogScript.deterministic_drop(&"search", pos, seed_value + 3, 1)


static func monster_trophy(pos: Vector2i, reward_gold: int, context: RunContext = null) -> Dictionary:
	if _uses_z2_loot(context):
		var current := _z2_items(context, "monster", pos, reward_gold)
		return current[0] if not current.is_empty() else {}
	var uses_z1_loot := _uses_z1_loot(context)
	if uses_z1_loot:
		var profile_type := str(context.enemy_state.get("monster_type", ""))
		var legacy_id := str(context.enemy_state.get("monster_id", context.enemy_state.get("id", "")))
		if profile_type == "z1_monster_m03" or legacy_id == "z1_monster_m03":
			var sample := M7ContentCatalogScript.item_definition("sp_inspection_calibration_plate")
			sample["instance_id"] = "%s:z1:m03:%d:%d:%d" % [context.run_id, pos.x, pos.y, context.turn]
			return sample
	var drops := _weighted_items(context, &"monster", pos, reward_gold) if uses_z1_loot else M3ItemCatalogScript.deterministic_drop(&"monster", pos, reward_gold, 1)
	if drops.is_empty():
		return {}
	var drop: Dictionary = drops[0]
	if not uses_z1_loot:
		drop["instance_id"] = "monster_drop_%d_%d_%s" % [pos.x, pos.y, String(drop.get("item_id", "item"))]
	return drop


static func altar_relic(context: RunContext, stage: int = 1) -> Dictionary:
	var turn := 0 if context == null else context.turn
	var pos := context.get_current_pos() if context != null else Vector2i(turn + stage, turn)
	if _uses_z2_loot(context):
		var current := _z2_items(context, "altar", pos, turn + stage * 7, 1, stage)
		if current.is_empty():
			return {}
		current[0]["altar_stage"] = stage
		return current[0]
	var drops := _weighted_items(context, &"altar", pos, turn + stage * 7, 1, stage) if _uses_z1_loot(context) else M3ItemCatalogScript.deterministic_drop(&"altar", Vector2i(turn + stage, turn), turn + stage * 7, 1)
	if drops.is_empty():
		return {}
	var drop: Dictionary = drops[0]
	if not _uses_z1_loot(context):
		drop["instance_id"] = "altar_drop_%d_%d_%s" % [turn, stage, String(drop.get("item_id", "item"))]
	drop["altar_stage"] = stage
	return drop


static func trap_cache(context: RunContext) -> Array[Dictionary]:
	var turn := 0 if context == null else context.turn
	if _uses_z2_loot(context):
		return _z2_items(context, "mechanism_success", context.get_current_pos(), turn, 2)
	if _uses_z1_loot(context):
		return _weighted_items(context, &"event", context.get_current_pos(), turn, 2)
	return M3ItemCatalogScript.deterministic_drop(&"event", Vector2i(turn, turn + 1), turn, 2)


static func _uses_z2_loot(context: RunContext) -> bool:
	if context == null:
		return false
	var profile: Dictionary = context.run_start_config.get("profile_fields", {})
	var frozen: Variant = profile.get("content_eligibility", {})
	return str(profile.get("ruleset_id", "")) == "z2" or (frozen is Dictionary and frozen.get("content_version", "") == "z2-system-20261116")


static func _z2_items(context: RunContext, channel: String, pos: Vector2i, seed_value: int, count: int = 1, stage: int = 1, adjacent_mines: int = -1) -> Array[Dictionary]:
	var profile: Dictionary = context.run_start_config.get("profile_fields", {})
	var frozen: Variant = profile.get("content_eligibility", {})
	if not frozen is Dictionary:
		return []
	# The search existence ticket depends on the original map seed, not black-coin bonuses.
	var seed_for_drop := context.seed_value if channel == "search" else context.seed_value + seed_value
	var items := Z2LootCatalogScript.roll(channel, pos, seed_for_drop, frozen, str(context.run_start_config.get("map_config_id", "")), count, stage, adjacent_mines, Z2LootCatalogScript.frozen_talents(context.run_start_config))
	for index in range(items.size()):
		items[index]["instance_id"] = "%s:z2:%s:%d:%d:%d:%d:%d" % [context.run_id, channel, pos.x, pos.y, context.turn, stage, index]
	return items


static func _uses_z1_loot(context: RunContext) -> bool:
	return context != null and str(context.run_start_config.get("map_config_id", "")).begins_with("classic_")


static func _weighted_items(context: RunContext, source: StringName, pos: Vector2i, seed_value: int, count: int = 1, stage: int = 1, adjacent_mines: int = -1) -> Array[Dictionary]:
	var map_id := str(context.run_start_config.get("map_config_id", ""))
	var definition := M7ContentCatalogScript.map_definition_exact(map_id)
	var difficulty := StringName(definition.get("difficulty", &"normal"))
	var items := Z1LootCatalogScript.roll(source, pos, context.seed_value + seed_value, difficulty, count, stage, adjacent_mines)
	for index in range(items.size()):
		items[index]["instance_id"] = "%s:z1:%s:%d:%d:%d:%d:%d" % [context.run_id, source, pos.x, pos.y, context.turn, stage, index]
	return items


static func item_def(item_id: String, display_name: String, item_type: StringName, value: int, rarity: StringName, tags: Array) -> Dictionary:
	return {
		"item_id": item_id,
		"display_name": display_name,
		"short_description": "M3 compatibility item definition.",
		"icon_fallback": "icon.%s.%s" % [String(item_type), item_id],
		"item_type": item_type,
		"main_type": item_type,
		"rarity": rarity,
		"weight": 1,
		"value_state": &"known_value",
		"base_value": value,
		"tags": tags.duplicate(true),
		"can_sell": rarity != &"unique",
		"can_store": true,
		"can_equip": false,
		"can_consume": false,
		"is_unique": rarity == &"unique",
		"unique_drop_allowed": false,
		"reward_location": RunAssetLedger.LOCATION_ROOM_FLOOR,
	}
