# T7 · 杂项收口（小缺口打包）

> 规格逐条核对后剩下的小项，打包成一个任务。**每项都可独立完成并独立
> 提交**（建议每项一个 commit）。无需账号。
> 对应规格编号见各项标题。

## 1. 追番页订阅交互（M3 验收收尾）
- 现状：追番页（`features/schedule/schedule_page.dart`）只读展示放送表。
- 做：条目点击 → 用内置 `bangumi-anime` 规则构造 `MediaItem`
  （sourceId=`bangumi-anime`，remoteId=条目 id，url 对齐规则 detail 的
  `{urlRaw}` 约定）→ `context.push(AppRoutes.detail, extra: item)`。
  详情页已有的追番/收藏按钮（_FollowButton）即完成「加入追番列表」。
- 测试：导航参数构造的单测（id/url 拼接）。

## 2. 发现页「已经到底了」提示（A3）
- 现状：feeds 触底分页由 `hasMore` 控制（空页停止），但没有明确提示。
- 做：某 feed 返回空列表或长度 < pageSize 时，在列表尾部显示
  「已经到底了」分隔条（只显示一次，不重复追加）。
- 测试：空页 → hasMore=false 且提示文本出现。

## 3. 同书版本展示（B1，尽力而为）
- 看 Mixn `get-book-detail` 响应里是否有版本/相关书籍字段（Mixn
  LightNovelRepository.kt 的 detail 解析处）。
- 有 → LK 详情映射出 `versions`（标题 + bookId），`LkBook` 加字段，
  详情页由本机接 UI；**没有则在交付说明写明「接口无此数据，项关闭」**，
  不要伪造。

## 4. 导出到用户授权目录（D4）
- 现状：导出固定写应用私有 `exports/`。
- 做：MethodChannel（沿用 `triomi/platform`）加
  `pickDirectory() → uri?`（SAF `ACTION_OPEN_DOCUMENT_TREE`）与
  `writeToTree(treeUri, fileName, bytes)`（用
  `DocumentsContract` + `takePersistableUriPermission` 持久授权）。
- 设置项 `export.directoryUri`：未设置走原路径；失败回退原路径并提示。
- 测试：路径选择逻辑与回退分支（channel 可 fake）。

## 5. 在线可下载字体 + 预览页（E1）
- 现状：`UserFontStore` 只支持本地导入。
- 做：`assets/fonts/catalog.json` 内置 3–5 款开源字体条目
  （name / url / license / 备注，URL 用官方发布地址如 Google Fonts
  GitHub 的思源宋体/黑体 raw 链接）；
  字体管理页加「在线字体」分区：下载（走 `fetchBytes`）→ 导入同现有
  流程；**预览页**：同一页展示中文/标点/英文示例，
  未下载时用系统字体渲染、已下载可切换对比。
- 测试：catalog 解析；下载失败分类。

## 6. 备份「包含离线内容」开关
- 现状：精简 = 不含封面，但 `contentJson`（已下载正文）仍进包，
  下载多时体积膨胀明显。
- 做：`BackupService.exportToFile/exportToBytes` 加
  `includeOfflineContent = true` 参数；为 false 时 chapterRows 不写
  `contentJson`；备份页第三档「导出精简备份（不含封面与离线内容）」。
- 测试：两档字节数对比与导入后 localChapterContent 为 null。

## 7. 后台更新提醒（D5，设计 + 桩，最低优先级）
- 规格要求 WorkManager 等价物 + 通知权限，默认关。
- 本项**只做设计与设置位**：设置项 `updates.backgroundCheck = false`（默认关）、
  「我的 → 备份与恢复」旁的说明文案；真实 WorkManager 排程留 TODO
  注释并写明方案（workmanager 插件或 MethodChannel + JobScheduler）。
- 不要引入 workmanager 插件。

## 验收标准（每项独立）
- analyze 零问题；该项测试全绿；全量测试不回归。
- 每项在交付说明里写「完成/关闭（原因）」二态。

## 后续集成点
- 本机：追番点击链路的模拟器 E2E；SAF 目录选择与写入的设备验证；
  在线字体下载的模拟器 E2E（夹具补字体文件端点）。
