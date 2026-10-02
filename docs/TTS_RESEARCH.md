# TTS 实现前资料（D26）

> 日期：2026-10-02。本文件只是**实现前资料**：核实候选库能力、梳理现有代码
> 链路与约束、列出需要 Codex 拍板的接口问题。不含实现、不加依赖、不做验收。
> flutter_tts 的能力/平台信息核实自 pub.dev 包页（查阅日 2026-10-02）。

## 1. 候选库比较

| 维度 | flutter_tts 4.2.5（MIT） | 平台原生自研桥（Android `android.speech.tts` / Windows `Windows.Media.SpeechSynthesis`） |
|---|---|---|
| 平台 | Android / iOS / macOS / Web / Windows（**无 Linux**） | 按需写哪个端就有哪个端 |
| 暂停/恢复 | **Android 的 pause 需要 workaround**：借助 `onRangeStart` + `synthesizeToFile` 或 SDK≥26 的条件分支（README 明说）；Windows 的 pause ✅ | Android 原生 `stop()` 后按 offset 重叙即可实现；Windows 可控 |
| 回调精度 | `setProgressHandler` 给 text + start/end offset，**词粒度**（utterance 级 completion/error/cancel 齐全） | Android `onRangeStart`（句/词，API26+）可到词；自己封装工作量在桥层 |
| 离线语音 | 跟随系统 TTS 引擎（Android 有引擎选择/voices 枚举 API；Windows 用 UWP voices） | 同左 |
| 语种 | setLanguage + isLanguageAvailable（**isLanguageAvailable 不支持 Windows**） | 原生枚举 |
| 音频焦点 | 未内建——Android 后台播放/与其他应用抢焦点要自己做（或配 audio_service） | 原生自管 |
| 维护/许可 | MIT，最后发版约 8 个月前，社区主流选择 | 全自研，长期维护成本最高 |
| 测试替身能力 | 方法通道窄、API 面宽——替身要 mock 的方法多；但可以像 `triomi/platform` 一样在 Dart 侧抽接口 | 自研桥可按契约设计，天然好替身 |

**结论**：选 **flutter_tts**（覆盖 Android+iOS+Windows，MIT，维护尚可），
但**不要直接裸用**：在 `lib/features/reader/`（或新 `tts/`）抽一层
`TtsController` 接口（speak/pause/resume/stop/onProgress/onError），Android 的
pause workaround 与「音频焦点申请」封在实现里。这样测试替身只需实现接口，
Windows 的能力缺口（无 speech marks、无语言可用性查询）也能在接口层降级。
原生自研桥只在「flutter_tts 的 Android pause workaround 不够稳」时作为
plan B（届时只需要替换 Android 端实现）。

## 2. 现有代码链路：ReaderBlock → 可朗读文本

```
ChapterContent(html/text)
  → ReaderContentParser.parse()            novel_blocks.dart:68
  → List<ReaderBlock>（HeadingBlock / ParagraphBlock / IllustrationBlock）
  → paginateReaderBlocks()                 novel_blocks.dart:292（分页）
  → 阅读器渲染（novel_reader_page.dart）
```

可朗读文本的天然来源就是 `List<ReaderBlock>`：Heading/Paragraph 取 `text`，
Illustration 按替换词朗读（如「插图」）。现有进度锚点
`_progressParagraph`（当前块下标，`novel_reader_page.dart:314`）可直接作为
朗读位置 ↔ 阅读位置的锚——**复用它，就不要发明第二套位置模型**。

## 3. 约束（实现时必须处理）

| 约束 | 说明 |
|---|---|
| 混淆字体 | LNS 专用字体只影响**显示**（字形替换），朗读应使用**原始文本**——`ChapterContent.text/html` 本来就是明文，无影响；但不要把渲染层文本（繁简转换后的）当朗读源，除非与 `ZhConverter` 的当前设置一致 |
| 插图 | IllustrationBlock 不可朗读 → 朗读时应跳过或读「插图」，并且**不计入进度锚**（否则位置漂移） |
| 标题/正文混排 | HeadingBlock 朗读时建议加停顿；分页把一个段落切成多页时，跨页句子的朗读要先拼接再交给引擎（flutter_tts 是按 utterance 的，不能一页一个 utterance 断句） |
| 付费锁定章节 | `_locked` 时阅读器根本不渲染正文（`novel_reader_page.dart` `_load` 直接 return）——TTS 天然无正文可读，红线自动满足；**不要**为锁定章实现任何取数/解锁路径 |
| 繁简转换 | 朗读源与显示源不一致时，onProgress 的 offset 对不上显示文本；要么朗读转换后文本并把位置映射回块下标，要么朗读原文本 |
| 滚动/分页两模式 | `_progressParagraph` 两模式都有定义（`novel_reader_page.dart:314-331`），但滚动模式是按比例估算——TTS 的位置锚在滚动模式下会抖动，需要 Codex 决定接受精度还是改锚 |
| 后台/锁屏 | Android 朗读要继续需前台服务 + 音频焦点；这是实现量大头，M6 第一版可只做前台朗读 |

## 4. 已定稿决策与 D37 实现（2026-10-02）

flutter_tts 4.2.5 已接入，前台段落朗读与阅读器按钮已落地，锁定章拒绝。分页按块跟随；滚动起点仍估算，朗读中使用实际 utterance 块锚记录进度，精准滚动交 D61。暂停一律停止，恢复重读；退出/换章/繁简转换/后台停止，无后台服务与逐词高亮，Linux 隐藏入口。Android speak 请求 focus=true，实际焦点丢失和设备发声待外部验收。语速/音色设置交 GLM D48。下列六问保留为原研究问题，不能再据此声称接口尚未定稿。

1. **朗读位置与阅读位置的关系**：朗读推进是否驱动阅读器翻页/滚动（跟读模式）？
   还是独立进度，用户手动同步？`_progressParagraph` 作为公共锚是否足够？
2. **utterance 切分**：按段落（ReaderBlock）还是按句（需句读算法）？
   词粒度 progress 回调对「高亮当前句」是否属于第一版需求？
3. **生命周期**：退出阅读器/锁屏/来电（音频焦点丢失）时 pause 还是 stop？
   与 `keepScreenOn` 的联动策略？
4. **平台降级**：Windows 无 speech marks（拿不到词级 offset）时第一版是否
   降级为「整段朗读、无高亮」？Linux（flutter_tts 不支持）明确不做？
5. **依赖引入时机**：flutter_tts 是插件（非纯 Dart），引入需按 T6 先例评估
   平台面——Android 无碍，Windows 侧插件注册要过一次构建。
6. **回归范围**：至少覆盖——长段落跨 utterance、繁简转换下的位置一致性、
   锁定章入口隐藏、分页模式跨页句子拼接。

## 5. 不确定项

- flutter_tts 在 Windows 的 pause 实际表现（README 标 ✅，但社区 issue 较多）
  ——**未实测**，属实现前需在 Windows 构建打通后验证的项。
- Android 各厂商 TTS 引擎对 `onRangeStart` 的支持差异——未实测。
- 系统朗读与 `wakelock_plus`（media_kit 传递依赖已在）配合的常亮策略——未定义。

## 6. 实现进度后记（D56 回写，2026-10-02）

本文第 4 节的接口问题已在后续批次逐步落地，证据分三层记录：

| 事项 | 状态 | 证据 |
|---|---|---|
| 合同层（TtsPlan/TtsEngine/TtsController） | **代码完成** | D31（`lib/features/novel/tts/tts_controller.dart`，14 例） |
| flutter_tts 插件适配 + 阅读器接线（问题 1/2/3 的第一版决策） | **代码完成 + Android debug 构建通过** | D37/D39-D46 复核（锚=块下标、前台朗读、无逐词高亮） |
| 回调竞态（token/代次） | **代码完成** | D41（6 例）+ 复核修正（token 真正传入引擎） |
| 生命周期（退出/换章/后台/繁简停止、迟到事件丢弃） | **代码完成** | D47（4 例真实页面 widget） |
| 语速 0.3/0.5/0.7 + 系统音色 + 持久化（问题 4/5 的第一版决策） | **代码完成** | D48（10 例；Windows 无 speech marks → 天然落「无高亮」降级，无需分支） |
| 长段落超系统输入长度切分、同块锚映射、精准滚动定位、命令竞态 | **未实现**（Codex D61） | 本节不声称完成 |
| **设备层**：真实发声、来电音频焦点、后台/锁屏、Windows 语音 | **未验收**（需设备/Windows 工具链） | 不因代码完成改判 |

问题 6（回归范围）的「长段落跨 utterance、繁简位置一致性、锁定章入口隐藏、
分页跨页拼接」中：锁定章入口隐藏与跨页拼接已有覆盖（t2/reader 测试、
按块规划天然满足）；长段落与繁简 offset 一致性属 D61（当前无逐词 offset，
不存在该问题）。
