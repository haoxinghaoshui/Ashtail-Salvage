extends RefCounted
class_name Z1ItemVisualCatalog

const MANIFEST := "res://data/assets/z1_item_art_manifest.json"
const TextureCache := preload("res://scripts/presentation/runtime_texture_cache.gd")

static var records: Dictionary = {}
static var records_by_key: Dictionary = {}

static func entry(item_id: String) -> Dictionary:
	_load_manifest()
	return records.get(item_id, {})

static func path_for_key(key: StringName) -> String:
	_load_manifest()
	return String(records_by_key.get(key, {}).get("path", ""))

static func texture_for(item: Dictionary) -> Texture2D:
	var record := entry(String(item.get("item_id", item.get("definition_id", ""))))
	return TextureCache.texture(String(record.get("path", ""))) if not record.is_empty() else null

static func _load_manifest() -> void:
	if not records.is_empty() or not FileAccess.file_exists(MANIFEST):
		return
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST))
	if not data is Dictionary:
		return
	for record: Dictionary in data.get("assets", []):
		records[String(record.get("runtime_id", ""))] = record
		records_by_key[StringName(record.get("visual_key", ""))] = record
