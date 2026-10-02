# GLM 批次 D70-D74：交付索引与实机前收口

状态：待 CI 绿后执行

| 任务 | 工作内容 | 验收 |
|---|---|---|
| D70 | 把 `docs/REVIEW_2026-10-02_MEDIA_SCOPE.md` 的番剧/漫画边界同步到 README、PROJECT_SPEC、RELEASE_READINESS 的对应章节 | 文档互链存在；不把夹具写成真实番剧 |
| D71 | 检查所有内置规则的 capability 声明与实际字段，报告“声明可播放但无 playSources”的漂移 | 新增扫描器测试；0 个误报 |
| D72 | 为漫画核心闭环补一份从规则导入到离线阅读的契约测试索引 | 只补测试/文档，不新增 OCR 或站点策略 |
| D73 | 检查 Release workflow 的 APK/Windows ZIP 工件路径和标签说明，补文档链接 | 不创建 tag，不修改密钥或 SDK |
| D74 | 运行 Python、文档扫描器和可用的 Flutter 检查，记录本轮命令/退出码/环境缺口 | `docs/delivery/BATCH_D70_D74_SUMMARY.md`；不复制历史结果 |

禁止范围：真实番剧源、真实站点写入、账号/审核凭据、D59/D60 架构、DLNA、一起看、Anime4K、OCR 翻译、后台朗读。
