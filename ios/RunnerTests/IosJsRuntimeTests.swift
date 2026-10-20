import Flutter
import UIKit
import XCTest
@testable import Runner

/// Actual WebContent execution. These tests make no claim about an immediate
/// PID kill: they assert responsive native deadlines, host revocation and a
/// usable replacement WKWebView using only public WebKit APIs.
final class IosJsRuntimeTests: XCTestCase {
    private func makeRuntime() throws -> IosJsRuntime {
        let sceneControllers = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .compactMap { $0.rootViewController as? FlutterViewController }
        let delegate = UIApplication.shared.delegate as? FlutterAppDelegate
        let controller = try XCTUnwrap(sceneControllers.first ??
            (delegate?.window?.rootViewController as? FlutterViewController))
        return IosJsRuntime(messenger: controller.binaryMessenger,
                            channelName: "triomi/ios-js-runtime-tests-" + UUID().uuidString)
    }

    private func request(_ runtime: IosJsRuntime, method: String, session: String,
                         values: [String: Any] = [:], timeoutMs: Int = 10_000) -> Any? {
        let finished = expectation(description: method + " finishes")
        var response: Any?
        var args = values
        args["session"] = session
        args["id"] = UUID().uuidString
        args["timeoutMs"] = timeoutMs
        runtime.handle(FlutterMethodCall(methodName: method, arguments: args)) { value in
            response = value
            finished.fulfill()
        }
        wait(for: [finished], timeout: 15)
        return response
    }

    func testSynchronousLoopLeavesNativeThreadResponsiveAndReplacementExecutes() throws {
        let runtime = try makeRuntime()
        let session = UUID().uuidString
        defer { _ = request(runtime, method: "dispose", session: session) }
        let script = """
            function ping() { return Promise.resolve({value: 42}); }
            function loop() { while (true) {} }
            """
        XCTAssertEqual(request(runtime, method: "load", session: session,
                               values: ["script": script]) as? Bool, true)
        let responsive = expectation(description: "native main thread stays responsive during JS")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { responsive.fulfill() }
        let failure = request(runtime, method: "call", session: session,
                              values: ["function": "loop", "args": []], timeoutMs: 300) as? FlutterError
        XCTAssertEqual(failure?.code, "js_session_reset")
        XCTAssertTrue(failure?.message?.contains("超时") == true)
        wait(for: [responsive], timeout: 1)
        XCTAssertEqual(request(runtime, method: "load", session: session,
                               values: ["script": script]) as? Bool, true)
        let value = request(runtime, method: "call", session: session,
                            values: ["function": "ping", "args": []]) as? [String: Any]
        XCTAssertEqual(value?["value"] as? Int, 42)
    }

    func testDisposalRevokesExecutionAfterAwaitWithoutWaitingForDeadline() throws {
        let runtime = try makeRuntime()
        let session = UUID().uuidString
        defer { _ = request(runtime, method: "dispose", session: session) }
        XCTAssertEqual(request(runtime, method: "load", session: session, values: ["script": """
            async function loop() { await Promise.resolve(); while (true) {} }
            """]) as? Bool, true)
        let stopped = expectation(description: "in-flight call is revoked")
        let disposed = expectation(description: "native disposal does not wait for WebContent")
        runtime.handle(FlutterMethodCall(methodName: "call", arguments: [
            "session": session, "id": UUID().uuidString, "timeoutMs": 10_000,
            "function": "loop", "args": []
        ])) { response in
            XCTAssertEqual((response as? FlutterError)?.code, "js_session_reset")
            stopped.fulfill()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            runtime.handle(FlutterMethodCall(methodName: "dispose", arguments: ["session": session])) { response in
                XCTAssertNil(response)
                disposed.fulfill()
            }
        }
        wait(for: [stopped, disposed], timeout: 3)
        XCTAssertEqual(request(runtime, method: "load", session: session,
                               values: ["script": "function recovered() { return 7; }"]) as? Bool, true)
        XCTAssertEqual(request(runtime, method: "call", session: session,
                               values: ["function": "recovered", "args": []]) as? Int, 7)
    }

    func testOversizedActualResultResetsSessionWithoutClaimingMemoryBudget() throws {
        let runtime = try makeRuntime()
        let session = UUID().uuidString
        defer { _ = request(runtime, method: "dispose", session: session) }
        XCTAssertEqual(request(runtime, method: "load", session: session, values: ["script": """
            function oversized() { return 'x'.repeat(8 * 1024 * 1024 + 1); }
            """]) as? Bool, true)
        let failure = request(runtime, method: "call", session: session,
                              values: ["function": "oversized", "args": []]) as? FlutterError
        XCTAssertEqual(failure?.code, "js_session_reset")
        XCTAssertTrue(failure?.message?.contains("8MiB") == true)
        XCTAssertEqual(request(runtime, method: "load", session: session,
                               values: ["script": "function recovered() { return true; }"]) as? Bool, true)
        XCTAssertEqual(request(runtime, method: "call", session: session,
                               values: ["function": "recovered", "args": []]) as? Bool, true)
    }
}
