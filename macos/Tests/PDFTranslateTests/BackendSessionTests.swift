import Darwin
import Foundation
import XCTest
@testable import PDFTranslate

@MainActor
final class BackendSessionTests: XCTestCase {
    func testCooperativeCancellationDeliversFinalEventBeforeSingleExit() async throws {
        let fixture = try makeFixture("""
        import json, sys
        json.loads(sys.stdin.readline())
        print('{"type":"ready"}', flush=True)
        for line in sys.stdin:
            if line.strip() == 'cancel':
                print('{"type":"cancelled"}', flush=True)
                sys.exit(2)
        """)
        defer { try? FileManager.default.removeItem(at: fixture.directory!) }
        let exited = expectation(description: "Helper exits cooperatively")
        var events: [String] = []
        var exits = 0
        var session: BackendSession!
        session = BackendSession(request: BackendRequest(operation: "check"), command: fixture,
            cancellationTimeouts: .init(cooperative: 0.3, termination: 0.2),
            onEvent: { event in
                events.append(event.type)
                if event.type == "ready" { session.cancel(); session.cancel() }
            }, onExit: { status in
                exits += 1
                XCTAssertEqual(status, 2)
                XCTAssertEqual(events.last, "cancelled")
                exited.fulfill()
            })
        try session.start()
        await fulfillment(of: [exited], timeout: 3)
        XCTAssertEqual(exits, 1)
    }

    func testStuckParentAndOwnedWorkerAreKilledAfterBoundedGrace() async throws {
        let fixture = try makeFixture("""
        import json, os, signal, subprocess, sys, time
        if os.getpgrp() != os.getpid(): os.setsid()
        json.loads(sys.stdin.readline())
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        child = subprocess.Popen([sys.executable, '-c',
            'import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)'])
        print(json.dumps({'type':'ready', 'stage':str(child.pid)}), flush=True)
        while True: time.sleep(1)
        """)
        defer { try? FileManager.default.removeItem(at: fixture.directory!) }
        let exited = expectation(description: "Unresponsive helper is killed")
        var child: Int32?
        defer { if let child { _ = Darwin.kill(child, SIGKILL) } }
        var session: BackendSession!
        session = BackendSession(request: BackendRequest(operation: "check"), command: fixture,
            cancellationTimeouts: .init(cooperative: 0.1, termination: 0.1),
            onEvent: { event in
                if event.type == "ready" {
                    child = event.stage.flatMap(Int32.init)
                    session.cancel()
                }
            }, onExit: { status in
                XCTAssertEqual(status, SIGKILL)
                exited.fulfill()
            })
        try session.start()
        await fulfillment(of: [exited], timeout: 3)
        let pid = try XCTUnwrap(child)
        // macOS may briefly retain an already-dead adopted child as a zombie.
        let state = try processState(pid)
        XCTAssertTrue(state.isEmpty || state.contains("Z"), "Worker must have stopped, state: \(state)")
    }

    func testExitedParentDoesNotWaitForInheritedOutputPipe() async throws {
        let fixture = try makeFixture("""
        import json, os, subprocess, sys
        json.loads(sys.stdin.readline())
        child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(10)'])
        print(json.dumps({'type':'finish', 'stage':str(child.pid)}), flush=True)
        os._exit(0)
        """)
        defer { try? FileManager.default.removeItem(at: fixture.directory!) }
        let exited = expectation(description: "Parent exit wins over inherited stdout")
        var child: Int32?
        defer { if let child { _ = Darwin.kill(child, SIGKILL) } }
        let start = Date()
        let session = BackendSession(request: BackendRequest(operation: "check"), command: fixture,
            onEvent: { event in child = event.stage.flatMap(Int32.init) },
            onExit: { status in
                XCTAssertEqual(status, 0)
                XCTAssertNotNil(child, "Final event must be drained before exit")
                exited.fulfill()
            })
        try session.start()
        await fulfillment(of: [exited], timeout: 3)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testBlockedRequestPipeDoesNotBlockStartOrCancellation() async throws {
        let fixture = try makeFixture("""
        import os, signal
        if os.getpgrp() != os.getpid(): os.setsid()
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        print('{"type":"ready"}', flush=True)
        while True: os.write(2, b'x' * 65536)
        """)
        defer { try? FileManager.default.removeItem(at: fixture.directory!) }
        let exited = expectation(description: "Unconsumed request pipe remains cancellable")
        var request = BackendRequest(operation: "check")
        request.configPath = String(repeating: "x", count: 300_000)
        var session: BackendSession!
        session = BackendSession(request: request, command: fixture,
            cancellationTimeouts: .init(cooperative: 0.1, termination: 0.1),
            onEvent: { if $0.type == "ready" { session.cancel() } },
            onExit: { status in XCTAssertEqual(status, SIGKILL); exited.fulfill() })
        let start = Date()
        try session.start()
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        await fulfillment(of: [exited], timeout: 3)
    }

    private func makeFixture(_ script: String) throws -> RuntimeCommand {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("helper.py")
        try Data(script.utf8).write(to: url)
        return RuntimeCommand(executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-u", url.path], directory: directory, developmentRoot: nil)
    }

    private func processState(_ pid: Int32) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "stat="]
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
