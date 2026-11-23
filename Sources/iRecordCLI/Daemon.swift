import AppKit
import Darwin
import Foundation
import iRecordCore

enum DaemonRunner {
    static func run(_ args: CLIArgs) -> Never {
        _ = setsid()

        guard let sessionID = args.string("session-id") else {
            Log.write("Daemon started without --session-id")
            exit(CLIExit.usage.rawValue)
        }

        let plan: RecordPlan
        do {
            plan = try CommandRunner.buildPlan(args)
        } catch let error as CLIError {
            failSession(id: sessionID, message: error.message, code: error.code)
            exit(error.exitCode.rawValue)
        } catch {
            failSession(id: sessionID, message: error.localizedDescription, code: "invalid_arguments")
            exit(CLIExit.usage.rawValue)
        }

        let daemon = HeadlessDaemon(plan: plan, sessionID: sessionID)
        do {
            try daemon.startControlServer()
        } catch {
            failSession(id: sessionID, message: "Could not start the control socket: \(error.localizedDescription)", code: "control_socket_failed")
            exit(CLIExit.general.rawValue)
        }
        daemon.installSignalHandlers()
        Task {
            await daemon.startRecording()
        }
        dispatchMain()
    }

    static func failSession(id: String, message: String, code: String) {
        var session = SessionStore.read(id: id) ?? HeadlessSession(
            id: id,
            pid: getpid(),
            state: "failed",
            mode: "unknown",
            target: "",
            outputPath: ""
        )
        session.state = "failed"
        session.error = message
        session.code = code
        session.elapsed = 0
        SessionStore.write(session)
    }
}

final class HeadlessDaemon {
    private let plan: RecordPlan
    private let sessionID: String
    private let recorder = ScreenRecorder()
    private let lock = NSLock()

    private var server: ControlServer?
    private var session: HeadlessSession
    private var state: String = "starting"
    private var startedAt: Date?
    private var pausedAt: Date?
    private var pausedAccumulated: TimeInterval = 0
    private var finishing = false
    private var signalSources: [DispatchSourceSignal] = []

    init(plan: RecordPlan, sessionID: String) {
        self.plan = plan
        self.sessionID = sessionID
        self.session = SessionStore.read(id: sessionID) ?? HeadlessSession(
            id: sessionID,
            pid: getpid(),
            state: "starting",
            mode: plan.mode.rawValue,
            target: "",
            outputPath: plan.outputURL.path,
            logFile: nil
        )
        self.session.pid = getpid()
        self.session.mode = plan.mode.rawValue
        self.session.target = describeTarget()
        self.session.outputPath = plan.outputURL.path
        writeSession()
        Log.write("Daemon \(sessionID) starting: \(describeTarget()) -> \(plan.outputURL.path)")
    }

    private func describeTarget() -> String {
        switch plan.mode {
        case .screen:
            return "display \(plan.displayID)"
        case .region:
            if let region = plan.region {
                return "display \(plan.displayID) region \(Int(region.minX)),\(Int(region.minY)),\(Int(region.width)),\(Int(region.height))"
            }
            return "region"
        case .window:
            if let id = plan.windowID { return "window \(id)" }
            let parts = [plan.windowApp, plan.windowTitle].compactMap { $0 }.filter { !$0.isEmpty }
            return "window matching " + parts.joined(separator: "/")
        }
    }

    func startControlServer() throws {
        let server = ControlServer(socketPath: AppPaths.controlSocket.path) { [weak self] request in
            guard let self else {
                return ControlResponse(ok: false, error: "The recording session is shutting down.", code: "shutting_down")
            }
            return self.handle(request)
        }
        try server.start()
        self.server = server
        Log.write("Daemon control socket: \(AppPaths.controlSocket.path)")
    }

    func installSignalHandlers() {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                Log.write("Received signal \(sig), saving recording")
                self?.requestStop()
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func startRecording() async {
        do {
            if !Permissions.hasScreenCapture {
                _ = Permissions.requestScreenCapture()
                if !Permissions.hasScreenCapture {
                    throw CaptureError.screenPermission
                }
            }

            if plan.options.capturesMicrophone {
                if Permissions.microphoneAuthorization == .notDetermined {
                    _ = await Permissions.requestMicrophone()
                }
                if !Permissions.hasMicrophone {
                    throw CaptureError.microphonePermission
                }
            }

            let (target, description) = try await CommandRunner.resolveTarget(plan, verbose: plan.verbose)
            updateSession { session in
                session.target = description
                session.mode = plan.mode.rawValue
            }

            recorder.onStateChange = { [weak self] newState in
                self?.recorderStateChanged(newState)
            }
            recorder.onError = { [weak self] error in
                Log.write("Recorder error: \(error.errorDescription ?? "unknown")")
                self?.fail(error)
            }

            _ = try await recorder.start(target: target, options: plan.options, outputURL: plan.outputURL)
            startedAt = Date()
            state = "recording"
            updateSession { session in
                session.state = "recording"
                session.startedAt = self.startedAt ?? Date()
                session.elapsed = 0
            }
            Log.write("Recording started: \(sessionID)")

            if plan.duration > 0 {
                try await Task.sleep(nanoseconds: UInt64(plan.duration * 1_000_000_000))
                requestStop()
            }
        } catch {
            fail(error)
        }
    }

    private func recorderStateChanged(_ newState: ScreenRecorder.State) {
        switch newState {
        case .paused:
            if pausedAt == nil { pausedAt = Date() }
            state = "paused"
            persistCurrentState()
        case .recording:
            if let pausedAt {
                pausedAccumulated += Date().timeIntervalSince(pausedAt)
                self.pausedAt = nil
            }
            if startedAt == nil { startedAt = Date() }
            state = "recording"
            persistCurrentState()
        case .converting:
            state = "converting"
            persistCurrentState()
        case .finishing:
            state = "finishing"
            persistCurrentState()
        default:
            break
        }
    }

    private func persistCurrentState() {
        updateSession { session in
            session.state = self.state
            session.elapsed = self.currentElapsed()
        }
    }

    private func currentElapsed() -> TimeInterval {
        guard let startedAt else { return 0 }
        var elapsed = Date().timeIntervalSince(startedAt) - pausedAccumulated
        if state == "paused", let pausedAt {
            elapsed -= Date().timeIntervalSince(pausedAt)
        }
        return max(0, elapsed)
    }

    func requestStop() {
        lock.lock()
        if finishing {
            lock.unlock()
            return
        }
        finishing = true
        let current = recorder.state
        lock.unlock()

        guard current == .recording || current == .paused else {
            if current == .preparing {
                recorder.abort()
                state = "cancelled"
                updateSession { session in
                    session.state = "cancelled"
                    session.elapsed = 0
                }
                server?.stop()
                exit(CLIExit.cancelled.rawValue)
            }
            return
        }

        state = "finishing"
        persistCurrentState()
        Task {
            do {
                let result = try await recorder.stop()
                finishSuccessfully(result)
            } catch {
                fail(error)
            }
        }
    }

    private func finishSuccessfully(_ result: RecordingResult) {
        state = "completed"
        updateSession { session in
            session.state = "completed"
            session.result = result
            session.elapsed = result.duration
            session.error = nil
            session.code = nil
        }
        server?.stop()
        Log.write("Recording completed: \(result.outputPath) (\(String(format: "%.2f", result.duration))s)")
        exit(CLIExit.ok.rawValue)
    }

    private func fail(_ error: Error) {
        var code = "recording_failed"
        var message = error.localizedDescription
        if let capture = error as? CaptureError {
            code = capture.code
            message = capture.errorDescription ?? message
        } else if let cli = error as? CLIError {
            code = cli.code
            message = cli.message
        }
        state = "failed"
        updateSession { session in
            session.state = "failed"
            session.error = message
            session.code = code
            session.elapsed = self.currentElapsed()
        }
        recorder.abort()
        server?.stop()
        Log.write("Recording failed: \(message)")
        exit(CLIExit.general.rawValue)
    }

    private func cancel() {
        lock.lock()
        finishing = true
        lock.unlock()
        recorder.abort()
        try? FileManager.default.removeItem(at: plan.outputURL)
        state = "cancelled"
        updateSession { session in
            session.state = "cancelled"
            session.error = nil
            session.code = "cancelled"
            session.elapsed = self.currentElapsed()
        }
        server?.stop()
        Log.write("Recording cancelled: \(sessionID)")
        exit(CLIExit.cancelled.rawValue)
    }

    private func updateSession(_ transform: (inout HeadlessSession) -> Void) {
        lock.lock()
        transform(&session)
        session.updatedAt = Date()
        let copy = session
        lock.unlock()
        SessionStore.write(copy)
    }

    private func writeSession() {
        lock.lock()
        let copy = session
        lock.unlock()
        SessionStore.write(copy)
    }

    private func handle(_ request: ControlRequest) -> ControlResponse {
        if let requested = request.session, requested != sessionID {
            return ControlResponse(ok: false, session: sessionID, error: "Session mismatch. This control socket belongs to \(sessionID).", code: "session_mismatch")
        }

        switch request.command {
        case "status":
            lock.lock()
            let currentState = state
            let elapsed = currentElapsed()
            let output = session.outputPath
            let result = session.result
            lock.unlock()
            updateSession { $0.elapsed = elapsed }
            return ControlResponse(ok: true, state: currentState, session: sessionID, outputPath: output, elapsed: elapsed, result: result)

        case "pause":
            lock.lock()
            let current = state
            lock.unlock()
            guard current == "recording" else {
                if current == "paused" {
                    return ControlResponse(ok: true, state: "paused", session: sessionID)
                }
                return ControlResponse(ok: false, session: sessionID, error: "The recording is not running.", code: "not_recording")
            }
            recorder.pause()
            state = "paused"
            pausedAt = Date()
            persistCurrentState()
            return ControlResponse(ok: true, state: "paused", session: sessionID, outputPath: session.outputPath, elapsed: currentElapsed())

        case "resume":
            lock.lock()
            let current = state
            lock.unlock()
            guard current == "paused" else {
                if current == "recording" {
                    return ControlResponse(ok: true, state: "recording", session: sessionID)
                }
                return ControlResponse(ok: false, session: sessionID, error: "The recording is not paused.", code: "not_paused")
            }
            recorder.resume()
            if let pausedAt {
                pausedAccumulated += Date().timeIntervalSince(pausedAt)
                self.pausedAt = nil
            }
            state = "recording"
            persistCurrentState()
            return ControlResponse(ok: true, state: "recording", session: sessionID, outputPath: session.outputPath, elapsed: currentElapsed())

        case "stop":
            lock.lock()
            let current = state
            let isFinishing = finishing
            lock.unlock()
            if isFinishing || current == "finishing" || current == "converting" {
                return ControlResponse(ok: true, state: current, session: sessionID, outputPath: session.outputPath)
            }
            if current != "recording" && current != "paused" {
                return ControlResponse(ok: false, session: sessionID, error: "The recording is not running.", code: "not_recording")
            }
            requestStop()
            return ControlResponse(ok: true, state: "finishing", session: sessionID, outputPath: session.outputPath)

        case "cancel":
            DispatchQueue.main.async { [weak self] in
                self?.cancel()
            }
            return ControlResponse(ok: true, state: "cancelled", session: sessionID)

        default:
            return ControlResponse(ok: false, session: sessionID, error: "Unknown command '\(request.command)'.", code: "unknown_command")
        }
    }
}

extension CommandRunner {
    static func runStart(_ args: CLIArgs) async {
        let plan: RecordPlan
        do {
            plan = try buildPlan(args, allowIndefinite: true)
        } catch let error as CLIError {
            CLIOutput.error(error.message, code: error.code, json: args.wantsJSON, exitCode: error.exitCode, hint: error.hint)
        } catch {
            CLIOutput.error(error.localizedDescription, code: "invalid_arguments", json: args.wantsJSON, exitCode: .usage)
        }

        if var active = SessionStore.latest(activeOnly: true) {
            let alive = active.pid > 0 && kill(active.pid, 0) == 0
            if !alive && !ControlClient.isSessionActive() {
                active.state = "failed"
                active.error = "The recording process exited without finishing."
                active.code = "stale_session"
                SessionStore.write(active)
            } else {
                CLIOutput.error(
                    "A recording session is already active: \(active.id) (\(active.state)).",
                    code: "session_active",
                    json: plan.json,
                    exitCode: .general,
                    hint: "Stop it with `irecord stop --session \(active.id) --json` first."
                )
            }
        }
        if ControlClient.isSessionActive() {
            CLIOutput.error(
                "The control socket is already in use by another recording session.",
                code: "session_active",
                json: plan.json,
                exitCode: .general,
                hint: "Run `irecord status --json` to inspect it."
            )
        }

        let sessionID = SessionStore.newID()
        let logDirectory = AppPaths.supportDirectory.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        let logURL = logDirectory.appendingPathComponent("headless-\(sessionID).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)

        var initial = HeadlessSession(
            id: sessionID,
            pid: 0,
            state: "starting",
            mode: plan.mode.rawValue,
            target: describePlan(plan),
            outputPath: plan.outputURL.path,
            logFile: logURL.path
        )
        initial.elapsed = 0
        SessionStore.write(initial)

        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            CLIOutput.error("Cannot locate the irecord executable.", code: "executable_missing", json: plan.json, exitCode: .general)
        }

        var childArguments = ["__daemon", "--session-id", sessionID] + plan.rawArguments
        childArguments.removeAll { $0 == "--daemon" }
        childArguments.append(contentsOf: ["--output", plan.outputURL.path])
        if plan.overwrite { childArguments.append("--overwrite") }

        let process = Process()
        process.executableURL = executable
        process.arguments = childArguments
        process.standardInput = FileHandle.nullDevice
        let maybeLogHandle = try? FileHandle(forWritingTo: logURL)
        let logHandle = maybeLogHandle ?? FileHandle.nullDevice
        process.standardOutput = logHandle
        process.standardError = logHandle

        do {
            try process.run()
        } catch {
            CLIOutput.error("Could not start the background recorder: \(error.localizedDescription)",
                            code: "spawn_failed", json: plan.json, exitCode: .general,
                            hint: "Run `irecord record --duration N` instead if the environment blocks detached processes.")
        }
        try? maybeLogHandle?.close()

        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            if let session = SessionStore.read(id: sessionID) {
                if session.state == "recording" || session.state == "paused" || session.state == "completed" {
                    if plan.json {
                        var object = sessionDictionary(session)
                        object["ok"] = true
                        object["controls"] = ["pause", "resume", "stop", "status", "cancel"]
                        object["hint"] = session.state == "completed"
                            ? "The short recording already finished. Read `result.output`."
                            : "Use `irecord stop --session \(sessionID) --json` to finish."
                        CLIOutput.json(object)
                    }
                    if session.state == "completed" {
                        CLIOutput.line("Recording finished: session \(sessionID)")
                    } else {
                        CLIOutput.line("Recording started: session \(sessionID)")
                    }
                    CLIOutput.line("  Output: \(plan.outputURL.path)")
                    CLIOutput.line("  Stop:   irecord stop --session \(sessionID)")
                    exit(CLIExit.ok.rawValue)
                }
                if session.state == "failed" || session.state == "cancelled" {
                    CLIOutput.error(
                        session.error ?? "The background recorder failed to start.",
                        code: session.code ?? "start_failed",
                        json: plan.json,
                        exitCode: .general,
                        hint: "See the log: \(logURL.path)"
                    )
                }
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }

        if process.isRunning {
            process.terminate()
        }
        CLIOutput.error(
            "Timed out waiting for the background recorder to start.",
            code: "timeout",
            json: plan.json,
            exitCode: .timeout,
            hint: "See the log: \(logURL.path). A detached process may not be able to request Screen Recording permission; use `irecord record --duration N` instead."
        )
    }

    private static func describePlan(_ plan: RecordPlan) -> String {
        switch plan.mode {
        case .screen:
            return "display \(plan.displayID)"
        case .region:
            if let region = plan.region {
                return "display \(plan.displayID) region \(Int(region.minX)),\(Int(region.minY)),\(Int(region.width)),\(Int(region.height))"
            }
            return "region"
        case .window:
            if let id = plan.windowID { return "window \(id)" }
            let parts = [plan.windowApp, plan.windowTitle].compactMap { $0 }.filter { !$0.isEmpty }
            return "window matching " + parts.joined(separator: "/")
        }
    }
}
