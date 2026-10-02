# 发布准备检查表（D57）

> 目的：把「能发布」拆成**可复现的验收步骤**。每项列出：步骤 → 预期 →
> 证据应记录的位置。只列可复现操作；不自动下载工具链、不使用任何真实账号。
> 执行人勾选时必须附实际观测值（机型 / 系统版本 / 截图或日志路径），
> 不允许以「代码已完成」代替本表任何一项。

## A. Android 前台 TTS

| # | 步骤 | 预期 | 证据位置 |
|---|---|---|---|
| A1 | `flutter build apk --release`（配好 keystore 后 `flutter build apk`） | 构建成功，无 warning 升级为 error | `build/app/outputs/flutter-apk/app-release.apk` 存在 + 构建日志 |
| A2 | 安装到真实设备（API 26+ 与 API 35 各一台），打开小说阅读器 → 点「朗读」 | 系统语音出声，从当前锚所在段开始 | 机型 + 录屏/照片；系统 TTS 引擎名称（设置 → 语言和输入 → 文字转语音） |
| A3 | 朗读中按「暂停朗读」再恢复 | 当前段停止，恢复**重读本段**（无逐词高亮降级基线） | 录屏 |
| A4 | 朗读中切后台 / 锁屏 / 来电（触发音频焦点丢失） | 返回前台后朗读已停止，不自动恢复（前台第一版基线）；无崩溃 | `adb logcat` 无 FATAL/ANR；录屏 |
| A5 | 朗读中点「下一章」、退出阅读器、繁简切换 | 三条路径全部立即停止（`novel_reader_tts_lifecycle_test.dart` 的设备复验） | 录屏 |
| A6 | 打开「朗读设置」：切语速 0.3/0.7、选音色，杀进程重开 | 面板回显所选项；新会话语速/音色生效 | 录屏 + `flutter test test/d48_tts_settings_test.dart` 通过 |
| A7 | 朗读中开启飞行模式 | 正文缓存朗读不受影响（无网络请求）；无异常 | `adb logcat` |

## B. Android 权限与系统集成

| # | 步骤 | 预期 | 证据位置 |
|---|---|---|---|
| B1 | 全新安装首启，逐个触发需要的能力（后台提醒开关、SAF 导出） | 仅弹 `POST_NOTIFICATIONS` 与 SAF 目录选择器；**无**存储/电话等额外权限申请 | 设置 → 应用 → 权限列表截图（对照 `AndroidManifest.xml`） |
| B2 | 后台更新提醒：开启后强杀应用，`adb shell dumpsys jobscheduler` | JobScheduler 里有 persisted job（12h、仅 WiFi 约束） | dumpsys 输出片段 |
| B3 | 备份导出 → 选择 SAF 目录 | 详情页 snackbar 显示「已保存到授权目录」+ 真实 document URI；文件在系统文件管理器可见 | URI 文本截图 + 文件管理器截图（对照 T7-4 记录） |
| B4 | 导出时在系统选择器按返回取消 | 提示「未选择授权目录，已保存到应用导出目录」，且是**导出成功**话术 | 录屏 |
| B5 | 授权目录写入失败模拟（把目录授权后在系统侧撤销，或选只读位置） | 「授权目录写入失败，已保存到应用导出目录」，应用目录文件可读 | 录屏 + 文件校验 |

## C. Windows 桌面

| # | 步骤 | 预期 | 证据位置 |
|---|---|---|---|
| C1 | 装有 Visual Studio 2022 C++ 工作负载的机器：`flutter build windows --release` | 构建成功 | 构建日志（当前本机无工具链，D38 未完成） |
| C2 | 运行桌面端播放夹具视频 | media_kit/libmpv 出画（`media_kit_libs_windows_video 1.0.11` 已锁入） | 录屏/帧截图（D38） |
| C3 | 桌面端朗读一段小说 | flutter_tts Windows 实际发声（README 标 ✅ 的能力在本项目首次实测） | 录屏；不通过则记 issue |
| C4 | 桌面端导出 EPUB/TXT/备份 | 走应用目录路径（SAF 通道桌面未实现），提示与实际一致 | 录屏 |

## D. 回归门槛（每轮发布前必跑）

| # | 步骤 | 预期 | 证据位置 |
|---|---|---|---|
| D1 | `flutter analyze --no-pub` | No issues found | 构建日志 |
| D2 | `flutter test --no-pub --reporter compact` | 全绿（当前 547+） | 测试日志 |
| D3 | `python -m unittest discover -s tools -p "test_*.py"` | 全绿 | 日志 |
| D4 | `python tools/ui_doc_drift_scan.py --json` 与 `python tools/delivery_consistency_scan.py --json` | 0 error（漂移扫描允许 1 条历史副本 info） | JSON 输出 |
| D5 | `python tools/check_fixture_media.py` | 720 帧 / 24 fps / 30 s / dynamic=true | JSON 输出 |

## 明确不在发布门槛内（当前决策）

- 弹弹play 真实凭据联调（官方审核未过）；真实站点写入类验收（凭据属用户）；
  LNS/LK 新增真实账号回归（已有记录不重跑）；Anime4K、DLNA、一起看
  （用户已决策关闭/暂缓）；JS 同步强隔离（ADR 001 路线，D59）与备份崩溃
  恢复（D60）——发布前在发布说明标注已知限制即可，不阻塞 A–D 表。
