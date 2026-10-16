# BATCH_D92_D98_SUMMARY

批次：D92-D98（真实内容更完整、能更新、能续读）
执行：GLM（D94/D95/D96/D97/D98）；D92/D93 为 Codex 已完成基线（仅引用）
日期：2026-10-05

## 总览

| 任务 | 负责人 | 状态 | 交付 |
|---|---|---|---|
| D92 真实漫画完整目录 | Codex | 已完成（C108） | [D92.md](D92.md)（引用 C107/C108） |
| D93 规则安全更新 | Codex | 已完成（C100） | [D93.md](D93.md)（引用 C99-C102） |
| D94 资料源可操作空态 | GLM | 已完成 | [D94.md](D94.md) |
| D95 小说账号状态 | GLM | 已完成 | [D95.md](D95.md) |
| D96 书架/追番数据回归 | GLM | 已完成 | [D96.md](D96.md) |
| D97 阅读器压力回归 | GLM | 已完成 | [D97.md](D97.md) |
| D98 全批收口 | GLM | 已完成 | [D98.md](D98.md) |

## 审查修订

本批文档原先把“无阻塞项”写得过宽。经 Codex 审查，D94-D98 只代表空态、账号入口和回归测试交付；没有新增真实联网/模拟器证据，也没有实现 Mihon APK 宿主。完整审查见 [`docs/REVIEW_2026-10-05_GLM_D94_D98.md`](../REVIEW_2026-10-05_GLM_D94_D98.md)。

## GLM 改动文件

**生产（2 个，均为最小改动）**
- `lib/features/reader/manga_reader_page.dart`：预取跳过 `file://` 本地文件（D97 缺陷修复）
- 其余为 D94/D95 的空态与账号入口 UI：
  `lib/features/discover/discover_page.dart`、
  `lib/features/search/search_page.dart`、
  `lib/features/detail/detail_page.dart`、
  `lib/core/router/app_router.dart`、
  `lib/features/sources/source_account_entries.dart`（新增）

**测试（5 个新文件 + 2 个更新）**
- 新增：`discover_metadata_empty_test.dart`（7）、`detail_empty_directory_test.dart`（2）、
  `novel_account_guidance_test.dart`（3）、`shelf_follow_persistence_test.dart`（4）、
  `manga_reader_stress_test.dart`（6）
- 更新：`discover_empty_filter_test.dart`（D94 契约更新 1 例 + D98 新增 2 例）
- 交付文档：`docs/delivery/D92.md`–`D98.md` + 本汇总

## 验证（全部实际执行，UTF-8 环境，清代理变量）

```text
flutter analyze --no-pub → No issues found
flutter test --no-pub → 662 passed, 0 failed
python tools/check_text_encoding.py → 0 errors（exit 0）
python -m unittest discover -s tools -p "test_*.py" → 83 OK
python tools/delivery_consistency_scan.py → 0 error
git diff --check → 通过
```

## 证据边界

全部 GLM 验证都在离线单元/widget 层（替身、内存库、真文件库、真实 PNG）。
本批**没有**联网验证、没有启动模拟器；不把 D87/C107-C108 的历史设备结论
记为本批通过。APK 扩展兼容未实现（C109-C113，Codex）。

## 需要 Codex 接手的复杂问题

1. 备份重复导入的历史行倍增缺陷（既有缺陷回归保留中）；
2. 资料源「单源定向搜索」协议演化（本批的上下文搜索是 UI 层过滤+排序）；
3. C109-C113 APK 宿主/安装事务/重复回归；
4. LNS 登录后真实会话验证（需用户账号）；
5. 真实设备/模拟器对 D94-D97 行为的抽样复验（本机本轮未启动 AVD）。
