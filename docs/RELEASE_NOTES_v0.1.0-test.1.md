# Triomi v0.1.0-test.1

测试版本，Android APK 使用模板 debug 签名，仅供测试安装。

验证来源：GitHub Actions 37028520208，提交 b4737ff。

- Flutter analyze：零问题。
- Flutter test：547 tests passed；Windows QuickJS 探测 OK。
- Python 工具、编码与文档检查：通过。
- Android release APK、Windows ZIP：构建通过。

已修复 README/AFTER_M5_PLAN 的混合编码；Windows PowerShell 使用 UTF-8 会话脚本，CI 增加编码门槛。

已知限制：Bangumi 是资料/目录源，不提供正片播放地址。真实番剧播放需要有权使用且具备 content.playSources 的来源规则，目前尚未验收。漫画核心阅读和离线链路已有代码与测试，实际站点及设备仍需验证。D59 同步 JS 强隔离、D60 跨存储崩溃恢复未完成。手机、系统 TTS/权限/后台任务与真实视频画面尚未实机验收。

Windows ZIP 需完整解压后启动 triomi.exe。
