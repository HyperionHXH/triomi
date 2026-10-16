# GLM 批次 D99-D105：扩展管理与来源边界

日期：2026-10-05  
负责人：GLM（简单、重复、可回归的工作）  
前置：Codex 已完成 Mihon 索引解析、扩展管理页第一版和 Bangumi 发现页边界。

状态：待执行

历史工作单说明：本批未按 D99–D105 编号单独执行/提交交付记录，不能捏造已交付文档。相关功能后来由 C 系列主线实现并持续修复，以 [CURRENT_STATUS](CURRENT_STATUS.md) 和 [ROADMAP](ROADMAP.md) 为当前事实；本表保留原计划，不再作为当前待办或声明 APK 尚无宿主。

## 交付目标

这批只补用户可见的管理体验和回归测试，不实现 Android DEX 宿主。每个任务都必须先证明用户能完成一个动作，再补测试；“测试全绿”不能写成“APK 已可执行”。

| 任务 | 范围 | 验收 |
|---|---|---|
| D99 | Mihon 扩展页 UI：仓库列表、刷新错误、中文/类型筛选、版本与 `extensionLib` 展示 | widget 测试覆盖加载、空态、错误重试、筛选；不改 `MihonRepositoryParser` 协议 |
| D100 | 扩展下载状态 UI：下载中、已下载、失败重试、启用开关禁用条件 | 明确显示“已下载，等待 Triomi Mihon 宿主”；不得显示“已安装可用” |
| D101 | 来源页按番剧/漫画/小说分组、规则目录与 Mihon 扩展入口 | widget 测试断言三个分组和两个入口；不改来源执行器 |
| D102 | Bangumi 发现页回归 | 有真实 `discover` 番剧源时，发现页不显示 `bangumi-anime`；全局搜索仍能搜到；更新旧 D94 测试断言 |
| D103 | Mihon 索引解析回归扩展 | 覆盖裸 `extensions` 兼容、缺字段、非 HTTPS APK、重复包名提示；不把 APK 下载当作执行 |
| D104 | 文档一致性扫描 | 修正旧文档中“无阻塞项”“插件可用”“全部筛选”等过时措辞；区分离线/widget/联网/模拟器/实机证据 |
| D105 | 低风险无障碍和窄屏回归 | 只修扩展卡片文本溢出、开关语义和按钮最小高度；不得顺便改播放器、规则协议或阅读器 |

## 明确禁止

- 不实现、不模拟、不声明 `DexClassLoader`、`SourceFactory`、Mihon source-api 调用已经完成。
- 不把 Mihon APK 反解析成 JSON/JS 规则，不把下载成功写入 Triomi `SourceRepository`。
- 不修改 AGE、MangaDex、LK、LNS 的真实请求协议来让测试通过。
- 不新增 OCR、社交、推荐算法、播放器特效或与来源聚合无关的功能。
- 每个交付文档必须写“用户实际能做什么”和证据层级；离线测试不得写成真实联网或模拟器验收。

## Codex 保留工作

Android Mihon 宿主仍由 Codex 负责：针对 `extensionLib 1.6` 做 APK 签名/版本校验、只读 DEX 加载、source-api ABI 兼容、最小 MangaDex discover/search/detail/chapters/content 桥接和 Flutter 映射。GLM 不得改动该边界。
