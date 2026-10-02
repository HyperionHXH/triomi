# 编码修复与 CI 记录

## 原因与修复

Windows PowerShell 5 默认代码页 936，Get-Content 默认编码也不等于 UTF-8。UTF-8 中文会被显示成乱码；用默认编码追加内容还会产生混合编码文件。README.md 和 docs/AFTER_M5_PLAN.md 的尾部确实存在 GBK 字节，已经恢复成 UTF-8，原意和正文没有改变。

仓库增加 .editorconfig（UTF-8）和 tools/check_text_encoding.py。CI 拒绝非 UTF-8 文件和 Unicode 替换字符；检查不声称能识别所有合法 Unicode 中的乱码。

Windows PowerShell 中运行 `. ./tools/utf8_shell.ps1` 可为当前会话设置 UTF-8 输入输出、Python 输出和文件命令默认编码。脚本不修改用户全局配置；新的会话需再次加载。Codex 后续读取中文使用 `Get-Content -Encoding UTF8`，手工编辑使用 apply_patch。

## CI 修复

run 37025611076：Flutter analyze、Python 工具、Android/Windows 构建通过；Flutter test 为 525 passed / 14 failed / 8 skipped。14 条失败均因 Linux 测试机缺少 libquickjs_c_bridge_plugin.so。

完整 Flutter 测试改到 Windows runner，通过已有 tools/setup_quickjs_dll.py 从 pub cache 复制随依赖分发的 DLL 到宿主搜索目录。支持 PUB_CACHE 环境变量；没有删除断言或把失败改为跳过。新 run 结果尚待验收，CI 全绿前不发布测试版本。

## 尚未完成

- D59 同步 JS 强隔离和 D60 跨存储崩溃恢复仍需实现，不是手机才能完成的任务。
- 真实番剧规则与真实内容播放尚未验证；Bangumi 资料源无法提供正片。
- Release 自动化已经入分支，但尚未发布可下载版本；手机验收尚未开始。
