# SAF 写入契约（`writeToTree`）静态文档（D43）

> 本文是 `triomi/platform` 通道 `writeToTree` 方法的**静态契约**：Dart 侧
> 封装（`lib/core/platform/platform_channel.dart:54`）与 Android 侧实现
> （`MainActivity.kt:91` `writeToTree`）的对应关系。通道行为另有单测钉住
> （`test/platform_channel_mime_test.dart`、`test/detail_export_page_test.dart`）；
> SAF 真机流程由 T7-4 设备记录覆盖，本文不声称设备验证。

## 请求参数

| 参数 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `treeUri` | String | ✅ | `pickDirectory` 返回的 SAF tree URI |
| `fileName` | String | ❌（Kotlin 缺省 `export.zip`） | 目标文件名（含扩展名） |
| `bytes` | Uint8List | ✅ | 文件内容（一次性写入，不适合超大文件） |
| `mime` | String | ❌ | **Dart 缺省 `application/zip`；Kotlin 缺省 `application/zip`**——传给 `DocumentsContract.createDocument` 决定新建文档的类型 |

## MIME 场景映射（Dart 侧调用方）

| 调用方 | mime | 说明 |
|---|---|---|
| 备份导出（`backup_page.dart`，旧调用） | 不传 → `application/zip` | **两侧缺省一致，旧调用兼容**（D43 核对结论） |
| EPUB 整书导出（`detail_page.dart`） | `application/epub+zip` | EPUB 3 规范 MIME |
| TXT 整书导出（`detail_page.dart`） | `text/plain` | 纯文本 |

## 返回与错误

- **成功**：返回新建文档的 content URI 字符串
  （`DocumentsContract.createDocument` 的结果，`result.success(uri)`）。
- **D49 合同升级**：注入器类型统一为 `SafTreeWriter`
  （`platform_channel.dart`）——**返回系统实际创建的 document URI**，
  调用方（`BackupService.exportToFile` / `NovelExportService._writeOut`）
  以该 URI 作为导出路径，**不得合成 `treeUri/fileName` 形式的路径**
  （系统对重名文件会改名，合成路径是错的；回归见
  `test/export_saf_injection_test.dart` 的「系统改名」用例）。
  通道返回 null/空 URI 视为失败（通道层抛 `PlatformException`，
  注入器返回空串同样触发回退）。
- **错误**（`result.error(code, message)`，向上抛 `PlatformException`，
  **通道层不吞错**——调用方依赖异常做私有目录回退）：

| code | 触发 | 调用方预期行为 |
|---|---|---|
| `invalid_args` | `treeUri`/`bytes` 缺失 | 参数缺陷，不应重试 |
| `create_failed` | `createDocument` 返回 null（目录无效/授权失效） | 回退应用私有目录 |
| `write_failed` | 写流/flush 抛异常（磁盘满、权限被回收） | 回退应用私有目录 |

## 回退契约

`BackupService._writeOut` 与 `NovelExportService._writeOut` 同一模式：
**授权目录优先（提供注入器时），写失败/未授权回退应用私有目录**
（备份 → `<docs>/backups/`；小说导出 → `<docs>/exports/`，同名加 `(n)` 序号）。
SAF 路径无同名冲突检测（由系统 DocumentsUI 的覆盖确认处理）。

## 保存位置提示（D50）

导出方（详情页 snackbar / 备份页状态）按结果**显式区分**保存位置：

| 场景 | 提示 |
|---|---|
| SAF 写入成功 | 已保存到授权目录（+ 真实 document URI） |
| 用户取消目录选择 | 未选择授权目录，已保存到应用目录 |
| 授权目录写入失败 | 授权目录写入失败，已保存到应用目录（**仍是导出成功**，不得报成导出失败） |

证据分层：以上三态由 widget/服务层测试钉住（`detail_export_page_test.dart`、
`export_saf_injection_test.dart`、`t7_misc_test.dart`）；SAF 真机落盘仍以
T7-4 设备记录为准，不因本批改动改判。

## 已知边界

- 文件内容一次性进内存（`bytes` 参数），不适合数百 MB 级大文件；
  当前用途（备份 zip / EPUB / TXT）量级可控。
- `fileName` 的非法字符由各导出服务先清洗（`_safeName`）；SAF 侧不再过滤。
- 非 Android 平台无该通道实现（`MissingPluginException` 由 Dart 侧
  `pickDirectory` 捕获为 null；`writeToTree` 不捕获——没有授权目录时调用方
  根本不会走到写入）。
