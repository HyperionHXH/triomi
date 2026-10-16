# ADR 001：JS 执行隔离与取消

日期：2026-10-02；2026-10-10 C125 更新。决策：Android/Windows 生产 JS 已迁入可终止的 OS worker；其他平台明确报告暂不支持该隔离运行器。

## 证据

flutter_js 0.8.7 的 QuickJsRuntime2 Dart 构造器暴露 timeout、memoryLimit，但默认工厂不传入。Windows 随包 DLL 实验中：开启 memoryLimit 导致 jsSetMemoryLimit 符号缺失；只传 timeout=100 时顶层 while(true) 仍阻塞，必须从另一进程结束测试子进程。失败实验代码已撤掉，避免普通测试挂死。没有修改 SDK 或 Pub 缓存。Android/iOS 的对应行为没有实测。

这证明不能以 Dart 构造器存在参数来认定原生执行有时间上限，也不能以 Future.timeout 或 Isolate.kill 保证正在执行 FFI 的原生循环会退出。

## 本轮实现

FlutterJsRuntime 不再使用插件 handlePromise 的不可取消轮询。应用持有 job pump、每次 call 的 Completer 和 triomiResult 通道；调用结束/超时取消空闲轮询，dispose 立即失败所有 pending 调用并取消轮询，晚到宿主响应继续丢弃。异步 Promise 超时后可继续调用正常函数。

## 生产实现（C125，替代 D59 后续设计）

沿用 JsRuntime 接口，Android/Windows 工厂返回 `ProcessJsRuntime`；`FlutterJsRuntime` 仅位于 worker 内部和明确的引擎单元测试。HTTP、凭据和 HTML 选择器能力保留在宿主，选择器桥改为可 await。worker 不初始化应用数据库、Hive、账号或网络客户端，不注册应用插件；这是执行/故障隔离，不是不同 UID 或完整权限沙箱。

C145来源生命周期边界：注册表读取停用JS规则只解析描述元数据，不启动引擎、不执行脚本来探测能力。已启用来源的实例与初始化Future一起归注册表所有；停用/移除后加载、规则替换、注册表销毁直接撤销实例，迟到初始化按缓存所有权拒绝发布，重新启用使用新会话。释放使isReady=false并清详情缓存，保留已探测描述能力供目录安装校验使用；描述能力不是运行许可。显式目录安装仍会执行候选规则来校验能力，不能将此边界当完整权限沙箱或所有安装流程不执行。

Android 用 `exported=false` 私有 Service 和独立 FlutterEngine。前台应用独占 `:js_worker` / `JsWorkerService`，漫画后台任务独占 `:js_worker_background` / `BackgroundJsWorkerService`；各控制器的 start/stop/孤儿恢复只作用于自己的精确进程名和服务，不能跨 engine 终止对方。C138 修复此前两个 Dart broker 争用同一服务、后台收尾使前台来源初始化失败的问题。宿主原生控制器仅杀同 UID 且精确匹配所属进程名的 PID；先 stopService 清理 AMS started 记录再杀进程，避免崩溃服务重启退避。独立 JVM 线程每 100ms 采样 native heap，超过 384MiB 只终止所属 worker，超时控制不依赖被阻塞的 Dart/FFI 线程。该采样阈值不等同所有映射内存的精确预算；并行前后台各有自己的阈值。

Windows 只启动自己的 triomi.exe worker 模式，隐藏窗口且跳过插件，单独 root Dart 入口在应用初始化前执行。Windows Job Object 将 worker committed memory 限为 384MiB；无法应用限制则启动失败。宿主终止自己的 child 并等待退出。Flutter integration_test 生成的入口包装器不能暴露该自定义 root 入口，桌面恶意用例使用直接构建的 `tools/windows_js_acceptance.dart`；它与 Android 复用相同验收用例。

IPC 为 loopback TCP、随机 256bit token、generation/session/call ID、4 字节长度前缀 JSON。8MiB 上限在缓冲 payload 前检查，拆包/粘包保持顺序；无效帧关闭连接。超时/在途取消/连接损坏杀掉共享 worker 并使所有会话失效，各 runtime 下一次调用重新加载规则。晚到宿主响应及旧 generation 结果丢弃；规则日志不输出。共享进程故障会中断其他来源的在途调用，这是明确的取舍。

所有无限循环验收均由独立 Python 宿主 watchdog 保护。API35、API26、Windows 真实 OS 进程均已通过顶层/函数/await 后无限循环、无限分配、递归错误、超长返回、乱序宿主请求、取消/晚到响应、其他会话重载和最终重启；API26最终无限分配约1999ms退出且其他会话恢复，见C125-js-api26.json。协议拆包/长度与无效 envelope 为真实 socket 回归。真实来源回归独立记录，不用恶意合成输入代表站点可用性。
