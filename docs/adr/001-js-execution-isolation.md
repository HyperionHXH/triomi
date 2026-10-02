# ADR 001：JS 执行隔离与取消

日期：2026-10-02。决策：异步调用生命周期修正已落地；同步循环的强制隔离尚未完成。

## 证据

flutter_js 0.8.7 的 QuickJsRuntime2 Dart 构造器暴露 timeout、memoryLimit，但默认工厂不传入。Windows 随包 DLL 实验中：开启 memoryLimit 导致 jsSetMemoryLimit 符号缺失；只传 timeout=100 时顶层 while(true) 仍阻塞，必须从另一进程结束测试子进程。失败实验代码已撤掉，避免普通测试挂死。没有修改 SDK 或 Pub 缓存。Android/iOS 的对应行为没有实测。

这证明不能以 Dart 构造器存在参数来认定原生执行有时间上限，也不能以 Future.timeout 或 Isolate.kill 保证正在执行 FFI 的原生循环会退出。

## 本轮实现

FlutterJsRuntime 不再使用插件 handlePromise 的不可取消轮询。应用持有 job pump、每次 call 的 Completer 和 triomiResult 通道；调用结束/超时取消空闲轮询，dispose 立即失败所有 pending 调用并取消轮询，晚到宿主响应继续丢弃。异步 Promise 超时后可继续调用正常函数。

## 后续设计（Codex D59）

沿用 JsRuntime 接口和 JsHostBridge 契约，运行器放到操作系统可终止的进程中。宿主保留凭据、HTTP 客户端和选择器；worker 只收规则文本、JSON 参数及经宿主处理的响应。协议必须带 sessionId/callId，消息有长度上限；异常不输出鉴权信息。进程超时、取消或协议损坏由宿主终止进程，拒绝旧会话结果。

Windows 优先验证独立 QuickJS runner 的构建、发行与 watchdog；Android 需要独立 service 进程或经审计的 native interrupt 实现，不能直接把桌面启动进程方案当成 Android 已实现。不得在主测试进程里运行未受外部 watchdog 保护的无限循环。

验收必须包含顶层循环、导出函数循环、await 后循环、递归、超大分配、宿主调用乱序、进程终止与重启。不同平台分别记录。
