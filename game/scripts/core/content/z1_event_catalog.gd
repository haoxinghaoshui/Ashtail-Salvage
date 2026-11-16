extends RefCounted
class_name Z1EventCatalog

const TITLES := [
	"便签", "领料", "兑付", "路线台账", "封条柜", "断电", "取样", "签收",
	"消音", "急救柜", "托运", "扩容", "压缩", "退料", "预支", "捷径",
	"引路", "拾料线圈", "排雷", "打卡", "侦察", "博弈", "减压", "围笼", "补给",
]
const DESCRIPTIONS := [
	"选择一个未知邻房，读取它周围的雷数。",
	"维修台只发一件物资，领取后留在地面。",
	"交10黑币，锁定6点安全收益。",
	"核对一个未知邻房的雷数。读过便签后享受折扣。",
	"领取一张抢救封条。办过兑付后享受折扣。",
	"交胶带安全开柜，或徒手承受10点伤害，至少保留1点生命。",
	"交6黑币，领取一枚巡检校验片。",
	"交回巡检校验片或旧齿轮组，锁定5点安全收益。",
	"交6黑币，减少5点当前压力。",
	"领取急救贴。压力达到40时可使用应急价格。",
	"交8黑币，托运一件重量不超过20的普通藏品。终局送回仓库。",
	"交8黑币，本局背包容量增加20。每局一次。",
	"交两件一级普通藏品，压成一件完整齿轮，留在地上。",
	"退回一块压缩饼获得3黑币，退回一张急救贴获得6黑币。",
	"押一件基础价至少21的普通藏品，先领12黑币。成功时支付16赎回。",
	"交6黑币，从检修口进入亮灯指向的斜邻房。",
	"交6黑币，问出最近隐藏撤离点的大致方位和距离。",
	"交5黑币，下一次成功搜索普通房时多获得一件同池物资。",
	"交7黑币，对一个插旗邻房远程起爆。猜中增加10点基础压力。",
	"先交4黑币开工，实际进入三个新房后回此处领取12黑币。",
	"选择侦察范围，只标记雷位。侦察不计为到访。",
	"石头剪刀布，三局两胜，平局重来。胜得10至40黑币。",
	"泡脚减少当前压力的10%，按摩减少30%，减量向下取整。",
	"入笼后房门和地图回传锁定。胜利增加怪物基础战力的两倍。",
	"三格货槽，按局外价格的130%向上取整。花5黑币刷新三槽。",
]


static func event_ids() -> Array[StringName]:
	var result: Array[StringName] = []
	for number in range(1, 26):
		result.append(StringName("z1_event_e%02d" % number))
	return result


static func number(event_id: StringName) -> int:
	var value := String(event_id)
	if not value.begins_with("z1_event_e"):
		return 0
	var result := int(value.trim_prefix("z1_event_e"))
	return result if result >= 1 and result <= TITLES.size() else 0


static func definition(event_id: StringName) -> Dictionary:
	var index := number(event_id) - 1
	if index < 0:
		return {}
	return {"event_type": event_id, "source_id": "E%02d" % (index + 1), "player_title": TITLES[index], "description": DESCRIPTIONS[index]}
