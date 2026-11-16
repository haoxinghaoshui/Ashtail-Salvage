extends RefCounted
class_name Art25ContentAssetContract

const Art09ManifestAssetMappingScript := preload("res://scripts/presentation/art09_manifest_asset_mapping.gd")
const Art24ItemVisualCatalogScript := preload("res://scripts/presentation/art24/art24_item_visual_catalog.gd")

const FALLBACK_ICON := &"icon.minimap.explored"
const FALLBACK_PANEL := &"ui.art19.panel.deploy_main"
const TALENT_VISUAL_KEYS := {
	"talent_carry_rigging": &"art25.long_term.item.eq_recovery_bag",
	"talent_salvage_clause": &"art25.long_term.task.task_failure_salvage",
	"talent_shock_training": &"art25.long_term.item.eq_insulated_sleeve",
	"talent_pressure_reading": &"art25.long_term.research.research_protocol_formula",
	"talent_scan_discipline": &"art25.long_term.item.con_scan_pin",
	"talent_trader_notes": &"art25.long_term.task.task_supply_recovery",
}


static func handles_deploy_card(card_id: StringName) -> bool:
	var value := String(card_id)
	return value.begins_with("m7_map_") or value.begins_with("m7_shop_") or value.begins_with("m7_commission_")


static func deploy_card_ref(card_id: StringName) -> Dictionary:
	var value := String(card_id)
	var asset_id := &""
	var role := &"art25_deploy_content"
	if value.begins_with("m7_map_"):
		asset_id = StringName("ui.art25.deploy.map.%s" % value.trim_prefix("m7_map_"))
		role = &"deploy_map_thumbnail"
	elif value.begins_with("m7_shop_"):
		asset_id = StringName("ui.art25.deploy.shop.%s" % value.trim_prefix("m7_shop_"))
		role = &"deploy_shop_icon"
	elif value.begins_with("m7_commission_"):
		asset_id = StringName("ui.art25.deploy.commission.%s" % value.trim_prefix("m7_commission_"))
		role = &"deploy_commission_icon"
	return Art09ManifestAssetMappingScript.asset_ref(asset_id, FALLBACK_ICON, role, card_id, true)


static func long_term_card_ref(card: Dictionary) -> Dictionary:
	var asset_id := StringName(card.get("art25_asset_id", &""))
	if asset_id == &"":
		asset_id = _long_term_asset_id(StringName(card.get("visual_key", &"")))
	return Art09ManifestAssetMappingScript.asset_ref(
		asset_id,
		&"ui.art25.long_term.unknown" if asset_id != &"ui.art25.long_term.unknown" else FALLBACK_PANEL,
		&"long_term_content_card",
		StringName(card.get("state", &"normal")),
		true
	)


static func long_term_visual_key(group_key: String, card: Dictionary) -> StringName:
	var canonical_group_key := _canonical_long_term_group_key(group_key)
	var card_id := String(card.get("id", card.get("content_id", "")))
	if card_id == "":
		return &"art25.long_term.unknown"
	var z1_record := Z1ItemVisualCatalog.entry(card_id)
	if not z1_record.is_empty():
		return StringName(z1_record.get("visual_key", ""))
	if canonical_group_key == "task_archive/task":
		return StringName("art25.long_term.task.%s" % card_id)
	if canonical_group_key == "task_archive/achievement":
		return StringName("art25.long_term.achievement.%s" % card_id)
	if canonical_group_key == "task_archive/commission_record":
		return StringName("art25.deploy.commission.%s" % String(card.get("content_id", card_id)))
	if canonical_group_key.begins_with("research/"):
		return StringName("art25.long_term.research.%s" % card_id)
	if canonical_group_key == "talent/tree":
		return TALENT_VISUAL_KEYS.get(card_id, &"art25.long_term.unknown")
	if canonical_group_key == "profile/milestone":
		return StringName("art25.long_term.profile.%s" % card_id.trim_prefix("profile_level_"))
	if canonical_group_key.begins_with("profile/"):
		return &"art25.long_term.profile.1"
	if canonical_group_key.begins_with("collection_appearance/") and card_id.begins_with("collection_"):
		return StringName("art25.long_term.collection.%s" % card_id)
	if canonical_group_key.begins_with("codex/"):
		return _codex_visual_key(card_id)
	return &"art25.long_term.unknown"


static func _canonical_long_term_group_key(group_key: String) -> String:
	for legacy_prefix in ["goals/", "tasks/"]:
		if group_key.begins_with(legacy_prefix):
			return "task_archive/%s" % group_key.trim_prefix(legacy_prefix)
	return group_key


static func texture_for_long_term_card(card: Dictionary) -> Texture2D:
	var entry_id := String(card.get("id", ""))
	if bool(card.get("known", true)) and entry_id.begins_with("item:") and String(card.get("art25_asset_id", "")).is_empty():
		var item_id := entry_id.trim_prefix("item:")
		if Art24ItemVisualCatalogScript.has_explicit_mapping(item_id):
			var appearance := Art24ItemVisualCatalogScript.resolve({"item_id": item_id}, &"codex")
			if not bool(appearance.get("fallback_used", true)):
				return appearance.get("texture") as Texture2D
	return Art09ManifestAssetMappingScript.resolve_texture(long_term_card_ref(card))


static func _codex_visual_key(card_id: String) -> StringName:
	if card_id.begins_with("monster:z1_monster_"):
		return StringName("z1.monster." + card_id.trim_prefix("monster:z1_monster_"))
	if card_id.begins_with("event:z1_event_"):
		return StringName("z1.event." + card_id.trim_prefix("event:z1_event_"))
	if card_id.begins_with("item:"):
		var record := Z1ItemVisualCatalog.entry(card_id.trim_prefix("item:"))
		if not record.is_empty():
			return StringName(record.get("visual_key", ""))
	if card_id.begins_with("map:"):
		return StringName("art25.deploy.map.%s" % card_id.trim_prefix("map:"))
	if card_id.begins_with("monster:"):
		return StringName("art25.long_term.monster.%s" % card_id.trim_prefix("monster:"))
	if card_id.begins_with("event:"):
		return StringName("art25.long_term.event.%s" % card_id.trim_prefix("event:"))
	if card_id.begins_with("rule:"):
		return StringName("art25.long_term.rule.%s" % card_id.trim_prefix("rule:"))
	if card_id.begins_with("item:"):
		return StringName("art25.long_term.item.%s" % card_id.trim_prefix("item:"))
	return &"art25.long_term.unknown"


static func _long_term_asset_id(visual_key: StringName) -> StringName:
	var value := String(visual_key)
	if value.begins_with("z1."):
		return visual_key
	if value.begins_with("art25."):
		return StringName("ui.%s" % value)
	return &"ui.art25.long_term.unknown"
