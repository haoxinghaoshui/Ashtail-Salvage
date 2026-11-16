# Ashtail Salvage — A1

Godot 4.6.3 游戏工程位于 `game/`。A1 是按用户要求保存的最新完整验收进度：Z2 的 T00—T04 运行基础。

使用 Godot 4.6.3 打开 `game/project.godot`，运行主场景。项目保留 Ashtail Salvage 名称及 AshtailSalvage 独立用户数据目录。

A1 包含原子动作、伤害与压力规则、容量和精确物品实例、战斗回滚、检查点保存及关闭后恢复。后续成长、完整内容投放、任务事件新接线、UI改造和屏幕适配仍在另一开发工作树实施，不能将本次A1当作最终Z2交付。

来源为 `2383c309af5823f791dfe08928cf39c7adb69c0b`，其代码和测试树与完整验收提交 `f0af2cd44e006cd810e878edbde97e2a61155c22` 完全相同。原验收126个runner全部接受；其中40项按既有精确清理诊断合同接受，并非全部没有警告。源验证摘要见 [A1验证来源](docs/A1_SOURCE_VALIDATION.json)。

向本仓库移植仅保留R0原有的应用名和独立存档目录设置，其余 `game/` 文件与已验收源码逐字节一致。导入后的复验见 [A1导入检查](docs/A1_IMPORT_VALIDATION.json)。未验证的设备、音频听感、长期压力和平衡不记为通过。

历史R0记录保留在Git历史及 `docs/validation.md`。
