extends RefCounted
class_name Z1SupplyCatalog

# Values and weights follow the user-approved 2026-11-11 content inventory.
const BASE_BACKPACK_CAPACITY := 100
const BASE_EQUIPMENT_CAPACITY := 100
const BASE_FAILURE_SALVAGE_CAPACITY := 40
const EXISTING_WEIGHTS := {
	"col_01": 11, "col_02": 9, "col_03": 10, "col_04": 9,
	"col_05": 12, "col_06": 13, "col_07": 11, "col_08": 12,
	"col_09": 13, "col_10": 15, "col_11": 14, "col_12": 13,
	"col_13": 17, "col_14": 15, "col_15": 16, "col_16": 16,
	"col_17": 17, "col_18": 19, "col_19": 18, "col_20": 19,
	"col_21": 21, "col_22": 19, "col_23": 19, "col_24": 20,
	"con_calm_candy": 13, "con_med_patch": 11, "con_ration": 10,
	"con_scan_pin": 9, "con_stabilizer": 14, "con_tape_roll": 13,
	"eq_edge_opener": 13, "eq_goggles": 12, "eq_insulated_sleeve": 12,
	"eq_old_vest": 15, "eq_recovery_bag": 15, "eq_signal_pin": 13,
	"mon_abnormal_instruction": 15, "mon_broken_patrol_badge": 13,
	"mon_loader_black_box": 17, "mon_old_gear_set": 13, "mon_overheated_core": 15,
	"sp_altar_residue": 14, "sp_trader_receipt": 0,
}
const CAPACITY_EFFECTS := {"eq_recovery_bag": 20, "eq_signal_pin": 10}
const OUT_OF_RUN_PRICES := {
	"con_ration": 6, "con_tape_roll": 16, "con_scan_pin": 8, "con_med_patch": 12,
	"con_calm_candy": 12, "con_stabilizer": 12, "eq_goggles": 18,
	"eq_insulated_sleeve": 22, "eq_old_vest": 24, "eq_recovery_bag": 28,
}


static func out_of_run_price(item_id: String) -> int:
	return int(OUT_OF_RUN_PRICES.get(item_id, -1))


static func all_items() -> Array[Dictionary]:
	return [
		_item("S01", "con_salvage_seal", "抢救封条", "consumable", 11, 8, 2, "event_drop", "使用后本局失败抢救容量增加10。", "salvage_capacity", 10),
		_item("S02", "eq_buffer_buckle", "缓冲腰扣", "equipment", 13, 25, 2, "chest_drop", "触雷伤害减少5。腰具位，与回收袋互斥。", "mine_damage_reduce", 5, {"equipment_slot": "rig"}),
		_item("S03", "col_clockwork_copper_dial", "校时铜盘", "collectible", 15, 20, 3, "chest_drop", "三级藏品，可登记或出售。指针卡在五点前一格。"),
		_item("S04", "sp_inspection_calibration_plate", "巡检校验片", "special", 11, 8, 2, "monster_drop", "取样或卡轨巡检机掉落。交给签收台获得5点安全收益。"),
		_item("S05", "eq_pressure_relief_wrench", "泄压扳手", "equipment", 13, 20, 2, "chest_drop", "战斗和机关造成的压力少增加1。工具位，与开刃器互斥。", "combat_mechanism_pressure_reduce", 1, {"equipment_slot": "tool"}),
		_item("S06", "eq_debris_brow_guard", "挡屑额罩", "equipment", 12, 22, 2, "search_drop", "触雷伤害减少4。头部位，仅邻雷少于2的普通房掉落。", "mine_damage_reduce", 4, {"equipment_slot": "head"}),
		_item("S07", "eq_etched_sleeve", "刻线护袖", "equipment", 11, 28, 2, "chest_drop", "扫描多揭示1个对角房间。护具位，与绝缘套互斥。", "scan_hint", 1, {"equipment_slot": "gear"}),
		_item("S08", "eq_strapped_backplate", "束带背板", "equipment", 15, 32, 3, "event_drop", "背包容量增加10。护甲位，与旧背心互斥。", "backpack_capacity", 10, {"equipment_slot": "armor"}),
		_item("S09", "eq_seam_finder_pendant", "寻缝坠", "equipment", 11, 34, 2, "search_drop", "每次搜索或开箱多得1黑币。装置位，与信号针互斥。", "search_reward", 1, {"equipment_slot": "device"}),
		_item("S10", "con_ledger_seal_paper", "封账纸", "consumable", 9, 6, 1, "search_drop", "使用后获得3点安全收益，终局入账。", "safe_yield", 3),
		_item("S11", "con_cooling_patch", "静脉冷贴", "consumable", 12, 14, 2, "chest_drop", "恢复4生命，压力减少10。", "heal_pressure_reduce", 4, {"pressure_amount": 10}),
		_item("S12", "con_hemostatic_clasp", "止血扣", "consumable", 15, 14, 2, "event_drop", "生命低于一半时可用，恢复32生命。", "heal_below_half", 32),
		_item("S13", "con_range_powder", "测距粉包", "consumable", 11, 8, 1, "search_drop", "依次向上、右、下、左寻找，揭示两格外第一个未知房间。", "scan_two_away", 1),
		_item("S14", "con_hard_shell_patch", "硬壳补片", "consumable", 13, 12, 2, "monster_drop", "抵消下一次触雷生命伤害，压力增加3。", "mine_immunity_pressure", 1, {"pressure_amount": 3}),
		_item("S15", "col_missing_tooth_counter", "掉齿计次轮", "collectible", 17, 31, 4, "monster_drop", "四级藏品，可登记或出售。"),
		_item("S16", "col_missing_shift_roster", "缺格值班表", "collectible", 10, 2, 1, "search_drop", "一级藏品，可登记、出售或投入压缩事件。"),
		_item("S17", "sp_reset_spring", "返校弹簧", "special", 11, 10, 2, "monster_drop", "交付给机关后门槛减少一个难度步长，当前为3战力。"),
		_item("S18", "sp_transit_lead_seal", "转运铅封", "special", 15, 16, 3, "chest_drop", "交付给签收台可获得10点安全收益，并结束本房交易。"),
		_item("S19", "col_folded_price_board", "折角价目板", "collectible", 17, 80, 5, "altar_special_event", "五级藏品，可登记或出售。祭坛第三、四档掉落。"),
		_item("S20", "sp_depressurized_valve_core", "失压阀心", "special", 15, 16, 3, "event_drop", "献祭时交付，下一次祭坛生命消耗减少5。"),
	]


static func _item(source_id: String, item_id: String, display_name: String, kind: String, weight: int, value: int, tier: int, source: String, description: String, effect_kind: String = "", effect_amount: int = 0, extra: Dictionary = {}) -> Dictionary:
	var result := {
		"source_id": source_id, "item_id": item_id, "display_name": display_name,
		"item_type": StringName(kind), "main_type": StringName(kind),
		"short_description": description, "flavor": description,
		"weight": weight, "base_value": value, "value_state": &"known_value",
		"rarity": StringName("tier_%d" % tier), "collectible_level": tier if kind == "collectible" else 0,
		"tags": [kind, "z1_supply", source_id], "source": source, "source_label": source,
		"icon_fallback": "icon.%s.%s" % [kind, item_id],
		"can_equip": kind == "equipment", "can_consume": kind == "consumable",
		"can_sell": kind == "collectible", "can_store": true,
		"is_unique": false, "unique_drop_allowed": false, "ordinary_drop_allowed": true,
		"effect_kind": effect_kind, "effect_amount": effect_amount,
		"reward_location": &"room_floor",
	}
	result.merge(extra, true)
	return result
