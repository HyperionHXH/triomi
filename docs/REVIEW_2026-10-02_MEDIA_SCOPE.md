# 媒体闭环审查（2026-10-02）

## 结论

- 番剧获取：已完成“规则注册 → 搜索 → 详情 → 集数目录”能力。内置 `assets/rules/bangumi-anime.json` 是 Bangumi 资料源，只声明 `search/detail`，没有 `content.playSources`，因此不能把它当成正片源。
- 番剧播放：播放器、线路选择、HLS/MP4 播放和视频下载链路支持规则返回的 `content.playSources`。当前仓库内可重复验证的是 `local-fixture-anime.json` + `tools/dev_fixture_server.py` 的合法测试媒体，不是真实番剧。
- 漫画：多源规则、搜索/详情、章节正文、书架、历史/进度、RTL/LTR/上下翻页/条漫滚动、离线图片和下载管理均已落地并有测试。Komikku 的 OCR 翻译、站点自动更新策略和桌面专属整合按范围冻结不实现。

## 实机前置条件

1. CI 全绿后从 GitHub Actions 或 Release 下载 APK。
2. 用户导入自己有权使用、且返回 `content.playSources` 的番剧规则，才能验收真实番剧播放。
3. 使用本地夹具只能验收播放器协议和控制逻辑，不能作为真实内容验收证据。

## 暂缓项判定

保留 D59（同步 JS 强隔离）和 D60（跨存储崩溃恢复）为 Codex 架构任务；两者需要版本化协议/日志设计，不能由重复性文档工作替代。真实站点写入、账号、审核凭据、物理设备和 Windows C++ 工具链属于外部条件，代码侧不伪造完成。

## 本轮验证

- `python -m unittest discover -s tools -p "test_*.py"`：81 tests，OK。
- Flutter/Android/Windows：由 GitHub Actions run `37024731760` 执行；本机没有 Flutter SDK，等待 CI 结果。
