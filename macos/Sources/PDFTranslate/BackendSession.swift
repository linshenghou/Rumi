import Darwin
import Foundation

struct RuntimeCommand {
    var executable: URL
    var arguments: [String]
    var directory: URL?
    var developmentRoot: URL?
    static func locate() throws -> RuntimeCommand {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/pdftranslate-engine/pdftranslate-engine")
        if FileManager.default.isExecutableFile(atPath: helper.path) {
            return RuntimeCommand(executable: helper, arguments: ["--request-stdin"], directory: nil, developmentRoot: nil)
        }
        if let url = Bundle.main.url(forResource: "bootstrap", withExtension: "json"),
           let data = try? Data(contentsOf: url), let paths = try? JSONDecoder().decode([String: String].self, from: data),
           let python = paths["pythonPath"], let project = paths["projectPath"] {
            let root = URL(fileURLWithPath: project)
            return RuntimeCommand(executable: URL(fileURLWithPath: python), arguments: ["-u", "-m", "pdf2zh_next.desktop_bridge", "--request-stdin"], directory: root, developmentRoot: root)
        }
        #if DEBUG
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return RuntimeCommand(executable: root.appendingPathComponent(".venv/bin/python"), arguments: ["-u", "-m", "pdf2zh_next.desktop_bridge", "--request-stdin"], directory: root, developmentRoot: root)
        #else
        throw NSError(domain: "PDFTranslate", code: 1, userInfo: [NSLocalizedDescriptionKey: L10n.text("The translation component is missing. Reinstall the app.")])
        #endif
    }
}

/// Owns one engine process. Pipe EOF is not the process lifetime: a child can inherit stdout.
final class BackendSession {
    struct CancellationTimeouts {
        var cooperative: TimeInterval = 8
        var termination: TimeInterval = 2
    }

    private let process = Process()
    private let output = Pipe(), input = Pipe(), errors = Pipe()
    private let queue = DispatchQueue(label: "PDFTranslate.backend")
    private var decoder = EventDecoder()
    private var request: BackendRequest?
    private let command: RuntimeCommand?
    private let timeouts: CancellationTimeouts
    private let onEvent: (BridgeEvent) -> Void
    private let onExit: (Int32) -> Void
    private var outputSource: DispatchSourceRead?
    private var errorSource: DispatchSourceRead?
    private var inputSource: DispatchSourceWrite?
    private var pendingInput = Data()
    private var inputOffset = 0
    private var outputClosed = false
    private var errorClosed = false
    private var started = false
    private var launched = false
    private var completed = false
    private var suppressCallbacks = false
    private var cancellationRequested = false
    private var terminationWork: DispatchWorkItem?
    private var killWork: DispatchWorkItem?

    init(request: BackendRequest, command: RuntimeCommand? = nil,
         cancellationTimeouts: CancellationTimeouts = CancellationTimeouts(),
         onEvent: @escaping (BridgeEvent) -> Void, onExit: @escaping (Int32) -> Void) {
        self.request = request
        self.command = command
        timeouts = cancellationTimeouts
        self.onEvent = onEvent
        self.onExit = onExit
    }

    func start() throws {
        try queue.sync {
            guard !started else { throw startupError(L10n.text("The translation task has already started.")) }
            started = true
            do {
                let command = try self.command ?? RuntimeCommand.locate()
                guard FileManager.default.isExecutableFile(atPath: command.executable.path) else {
                    throw startupError(L10n.text("The translation component could not start. Reinstall the app."))
                }
                guard let request else { throw startupError(L10n.text("The translation request is invalid. Try again.")) }
                pendingInput = try JSONEncoder().encode(request)
                pendingInput.append(0x0A)
                self.request = nil
                guard pendingInput.count <= 1_048_576 else { throw startupError(L10n.text("The translation settings are too large. Review them and try again.")) }

                process.executableURL = command.executable
                process.arguments = command.arguments
                process.currentDirectoryURL = command.directory
                var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("PDF2ZH_") }
                environment.removeValue(forKey: "PYTHONHOME")
                environment.removeValue(forKey: "PYTHONPATH")
                environment["PYTHONUNBUFFERED"] = "1"
                if let root = command.developmentRoot { environment["PYTHONPATH"] = root.path }
                process.environment = environment
                process.standardOutput = output
                process.standardInput = input
                process.standardError = errors
                try nonblocking(output.fileHandleForReading)
                try nonblocking(errors.fileHandleForReading)
                try nonblocking(input.fileHandleForWriting)
                guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
                    throw startupError(L10n.text("Could not communicate with the translation component. Try again."))
                }
                installReaders()
                // Retain the session until the owned process terminates, even if startup fails
                // after launch and the caller immediately releases its reference.
                process.terminationHandler = { [self] process in
                    queue.async { self.processExited(process.terminationStatus) }
                }
                try process.run()
                launched = true
                closeChildEnds()
                try flushInput()
            } catch {
                request = nil
                pendingInput.removeAll()
                inputOffset = 0
                suppressCallbacks = true
                if launched {
                    // Closing stdin also requests cooperative shutdown in the bridge.
                    closeInput()
                    signalOwnedProcess(SIGTERM)
                    scheduleKill()
                } else {
                    complete(status: 1)
                }
                throw error
            }
        }
    }

    func cancel() {
        queue.async { [self] in
            guard launched, !completed, !cancellationRequested else { return }
            cancellationRequested = true
            pendingInput.append(contentsOf: Data("cancel\n".utf8))
            try? flushInput()
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.completed else { return }
                self.signalOwnedProcess(SIGTERM)
                self.scheduleKill()
            }
            terminationWork = work
            queue.asyncAfter(deadline: .now() + max(0, timeouts.cooperative), execute: work)
        }
    }

    private func installReaders() {
        let stdout = DispatchSource.makeReadSource(fileDescriptor: output.fileHandleForReading.fileDescriptor, queue: queue)
        stdout.setEventHandler { [weak self] in self?.drainOutput() }
        stdout.setCancelHandler { [handle = output.fileHandleForReading] in try? handle.close() }
        outputSource = stdout
        stdout.resume()
        let stderr = DispatchSource.makeReadSource(fileDescriptor: errors.fileHandleForReading.fileDescriptor, queue: queue)
        stderr.setEventHandler { [weak self] in self?.drainErrors() }
        stderr.setCancelHandler { [handle = errors.fileHandleForReading] in try? handle.close() }
        errorSource = stderr
        stderr.resume()
    }

    private func nonblocking(_ handle: FileHandle) throws {
        let flags = fcntl(handle.fileDescriptor, F_GETFL)
        guard flags != -1, fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) != -1 else {
            throw startupError(L10n.text("Could not communicate with the translation component. Try again."))
        }
    }

    /// No blocking writes: a stuck helper must not freeze the UI or the cancellation timer.
    private func flushInput() throws {
        guard !completed else { return }
        while inputOffset < pendingInput.count {
            let count = pendingInput.withUnsafeBytes { bytes in
                Darwin.write(input.fileHandleForWriting.fileDescriptor,
                    bytes.baseAddress!.advanced(by: inputOffset), bytes.count - inputOffset)
            }
            if count > 0 { inputOffset += count; continue }
            if count == -1 && errno == EINTR { continue }
            if count == -1 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                if inputSource == nil {
                    let source = DispatchSource.makeWriteSource(fileDescriptor: input.fileHandleForWriting.fileDescriptor, queue: queue)
                    source.setEventHandler { [weak self] in
                        guard let self else { return }
                        do { try self.flushInput() }
                        catch {
                            self.pendingInput.removeAll()
                            self.inputOffset = 0
                            self.closeInput()
                            self.signalOwnedProcess(SIGTERM)
                            self.scheduleKill()
                        }
                    }
                    inputSource = source
                    source.resume()
                }
                return
            }
            throw startupError(L10n.text("The translation component did not receive the request. Try again."))
        }
        pendingInput.removeAll()
        inputOffset = 0
        inputSource?.cancel()
        inputSource = nil
    }

    private func drainOutput() {
        guard !outputClosed else { return }
        drain(output.fileHandleForReading.fileDescriptor, consume: { data in
            for event in decoder.append(data) where !suppressCallbacks {
                DispatchQueue.main.async { [onEvent] in onEvent(event) }
            }
        }, reachedEnd: {
            outputClosed = true
            outputSource?.cancel()
            outputSource = nil
        })
    }

    private func drainErrors() {
        guard !errorClosed else { return }
        // Upstream errors can contain credentials or document text. Drain without retaining logs.
        drain(errors.fileHandleForReading.fileDescriptor, consume: { _ in }, reachedEnd: {
            errorClosed = true
            errorSource?.cancel()
            errorSource = nil
        })
    }

    private func drain(_ descriptor: Int32, consume: (Data) -> Void, reachedEnd: () -> Void) {
        var bytes = [UInt8](repeating: 0, count: 65_536)
        // Bound each turn so a noisy child cannot starve process-exit handling or kill timers.
        for _ in 0..<16 {
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count > 0 { consume(Data(bytes.prefix(count))); continue }
            if count == -1 && errno == EINTR { continue }
            if count == -1 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
            reachedEnd()
            return
        }
    }

    private func processExited(_ status: Int32) {
        guard !completed else { return }
        // Flush the parent's remaining complete JSON lines, then finish regardless of whether
        // inherited pipe descriptors in descendants are still open.
        drainOutput()
        drainErrors()
        complete(status: status)
    }

    private func scheduleKill() {
        guard !completed, killWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.completed else { return }
            self.signalOwnedProcess(SIGKILL)
        }
        killWork = work
        queue.asyncAfter(deadline: .now() + max(0, timeouts.termination), execute: work)
    }

    private func signalOwnedProcess(_ signal: Int32) {
        guard launched, !completed, process.isRunning else { return }
        let pid = process.processIdentifier
        guard pid > 1, pid != getpid() else { return }
        // The bridge isolates itself before starting workers. Never signal an inherited app or
        // shell group; also never signal a group after its known parent has exited.
        if signal == SIGKILL, getpgid(pid) == pid {
            _ = Darwin.kill(-pid, signal)
        } else {
            _ = Darwin.kill(pid, signal)
        }
    }

    private func closeChildEnds() {
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        try? input.fileHandleForReading.close()
    }

    private func closeInput() {
        if let source = inputSource {
            source.setCancelHandler { [handle = input.fileHandleForWriting] in try? handle.close() }
            source.cancel()
        } else { try? input.fileHandleForWriting.close() }
        inputSource = nil
    }

    private func complete(status: Int32) {
        guard !completed else { return }
        completed = true
        request = nil
        pendingInput.removeAll()
        inputOffset = 0
        terminationWork?.cancel()
        terminationWork = nil
        killWork?.cancel()
        killWork = nil
        process.terminationHandler = nil
        closeInput()
        closeChildEnds()
        outputClosed = true
        errorClosed = true
        if let source = outputSource { source.cancel() } else { try? output.fileHandleForReading.close() }
        if let source = errorSource { source.cancel() } else { try? errors.fileHandleForReading.close() }
        outputSource = nil
        errorSource = nil
        if !suppressCallbacks { DispatchQueue.main.async { [onExit] in onExit(status) } }
    }

    private func startupError(_ message: String) -> Error {
        NSError(domain: "PDFTranslate", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
