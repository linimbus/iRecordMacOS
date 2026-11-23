import AppKit
import CoreGraphics
import Foundation
import iRecordCore

struct CLIError: Error {
    let message: String
    let code: String
    let exitCode: CLIExit
    let hint: String?

    init(_ message: String, code: String, exitCode: CLIExit = .general, hint: String? = nil) {
        self.message = message
        self.code = code
        self.exitCode = exitCode
        self.hint = hint
    }
}

struct RecordPlan {
    var options: CaptureOptions
    var outputURL: URL
    var mode: CaptureTargetKind
    var displayID: CGDirectDisplayID
    var windowID: CGWindowID?
    var windowApp: String?
    var windowTitle: String?
    var region: CGRect?
    var duration: TimeInterval
    var overwrite: Bool
    var json: Bool
    var quiet: Bool
    var verbose: Bool
    var rawArguments: [String]
}

enum CommandRunner {
    static func run(_ args: CLIArgs) {
        if args.command == "help" || args.has("help") {
            if args.wantsJSON && args.command == "help" {
                CLIOutput.json(HelpSpec.capabilities)
            }
            let command = args.command == "help" ? args.positional.first : args.command
            print(HelpSpec.humanHelp(command: command))
            exit(CLIExit.ok.rawValue)
        }

        switch args.command {
        case "version", "--version":
            if args.wantsJSON {
                CLIOutput.json(["ok": true, "version": AppInfo.version, "tool": "irecord"])
            }
            print("iRecord \(AppInfo.version)")
            exit(CLIExit.ok.rawValue)
        case "doctor":
            runDoctor(args)
        case "targets", "list-targets", "list":
            runAsyncAndWait { await runTargets(args) }
        case "config":
            runConfig(args)
        case "record":
            runAsyncAndWait { await runRecord(args) }
        case "start":
            runAsyncAndWait { await runStart(args) }
        case "pause":
            runControl(args, action: "pause")
        case "resume":
            runControl(args, action: "resume")
        case "status":
            runStatus(args)
        case "stop":
            runAsyncAndWait { await runStop(args) }
        case "__daemon":
            DaemonRunner.run(args)
        default:
            CLIOutput.error(
                "Unknown command '\(args.command)'.",
                code: "unknown_command",
                json: args.wantsJSON,
                exitCode: .usage,
                hint: "Run `irecord help` or `irecord help --json`."
            )
        }
    }

    static func runAsyncAndWait(_ body: @escaping () async -> Void) {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await body()
            semaphore.signal()
        }
        semaphore.wait()
    }

    // MARK: - Plan

    static func buildPlan(_ args: CLIArgs, requireOutput: Bool = true, allowIndefinite: Bool = true) throws -> RecordPlan {
        let base = SettingsStore.shared.current

        var mode: CaptureTargetKind
        if let rawMode = args.string("mode", "capture-mode") {
            switch rawMode.lowercased() {
            case "screen", "full", "display", "fullscreen": mode = .screen
            case "window", "app": mode = .window
            case "region", "area", "rect": mode = .region
            default:
                throw CLIError("Invalid --mode '\(rawMode)'.", code: "invalid_mode", exitCode: .usage,
                               hint: "Use screen, window or region.")
            }
        } else if args.string("window", "window-id", "app", "title") != nil {
            mode = .window
        } else if args.string("region") != nil {
            mode = .region
        } else {
            mode = .screen
        }

        let format: VideoFormat
        if let raw = args.string("format") {
            guard let parsed = VideoFormat.parse(raw) else {
                throw CLIError("Invalid format '\(raw)'.", code: "invalid_format", exitCode: .usage,
                               hint: "Supported formats: \(VideoFormat.supportedList).")
            }
            format = parsed
        } else {
            format = base.format
        }

        var fps = args.int("fps") ?? base.fps
        fps = min(120, max(5, fps))

        var quality = base.quality
        if let raw = args.string("quality") {
            guard let parsed = CaptureQuality(rawValue: raw.lowercased()) else {
                throw CLIError("Invalid quality '\(raw)'.", code: "invalid_quality", exitCode: .usage)
            }
            quality = parsed
        }

        var scale = args.double("scale") ?? base.scale
        scale = min(1.0, max(0.25, scale))

        var audioSource = base.audioSource
        if args.has("no-audio") {
            audioSource = .off
        } else if let raw = args.string("audio") {
            guard let parsed = parseAudio(raw) else {
                throw CLIError("Invalid audio source '\(raw)'.", code: "invalid_audio", exitCode: .usage,
                               hint: "Use none, system, microphone or both.")
            }
            audioSource = parsed
        }

        var showCursor = base.showCursor
        if args.has("no-cursor") { showCursor = false }
        if args.has("cursor") { showCursor = true }

        var highlightClicks = base.highlightClicks
        if args.has("no-mouse-clicks") { highlightClicks = false }
        if args.has("mouse-clicks") { highlightClicks = true }

        let gifWidth = min(3840, max(120, args.int("gif-width") ?? base.gifMaxWidth))
        let gifFPS = min(30, max(2, args.int("gif-fps") ?? base.gifFPS))

        let options = CaptureOptions(
            format: format,
            fps: fps,
            quality: quality,
            scale: scale,
            audioSource: audioSource,
            showCursor: showCursor,
            highlightClicks: highlightClicks,
            gifMaxWidth: gifWidth,
            gifFPS: gifFPS
        ).sanitized()

        var displayID = CGMainDisplayID()
        if let raw = args.string("display", "display-id") {
            if raw.lowercased() == "main" {
                displayID = CGMainDisplayID()
            } else if let value = UInt32(raw) {
                displayID = CGDirectDisplayID(value)
            } else {
                throw CLIError("Invalid --display '\(raw)'.", code: "invalid_display", exitCode: .usage,
                               hint: "Use `main` or a numeric id from `irecord targets --json`.")
            }
        }

        var windowID: CGWindowID?
        if let raw = args.string("window", "window-id") {
            guard let value = UInt32(raw) else {
                throw CLIError("Invalid --window '\(raw)'.", code: "invalid_window", exitCode: .usage)
            }
            windowID = CGWindowID(value)
        }
        let windowApp = args.string("app")
        let windowTitle = args.string("title")

        var region: CGRect?
        if let raw = args.string("region") {
            guard let rect = parseRegion(raw) else {
                throw CLIError("Invalid --region '\(raw)'.", code: "invalid_region", exitCode: .usage,
                               hint: "Use x,y,width,height in display-local points, e.g. 100,200,800,600.")
            }
            guard rect.width >= 8, rect.height >= 8 else {
                throw CLIError("The capture region is too small.", code: "invalid_region", exitCode: .usage)
            }
            region = rect
        }

        if mode == .window && windowID == nil && windowApp == nil && windowTitle == nil {
            throw CLIError("Window capture needs --window, --app or --title.",
                           code: "missing_window", exitCode: .usage,
                           hint: "Run `irecord targets --json` to list windows.")
        }
        if mode == .region && region == nil {
            throw CLIError("Region capture needs --region x,y,w,h.", code: "missing_region", exitCode: .usage)
        }

        var duration = args.double("duration", "seconds") ?? 0
        if duration < 0 {
            throw CLIError("--duration must be zero or positive.", code: "invalid_duration", exitCode: .usage)
        }
        if !allowIndefinite && duration <= 0 {
            duration = 0
        }

        let overwrite = args.has("overwrite")
        let outputURL: URL
        if requireOutput {
            outputURL = try resolveOutput(args.string("output", "out", "o"), format: format, overwrite: overwrite)
        } else {
            outputURL = URL(fileURLWithPath: "/dev/null")
        }

        return RecordPlan(
            options: options,
            outputURL: outputURL,
            mode: mode,
            displayID: displayID,
            windowID: windowID,
            windowApp: windowApp,
            windowTitle: windowTitle,
            region: region,
            duration: duration,
            overwrite: overwrite,
            json: args.wantsJSON,
            quiet: args.isQuiet,
            verbose: args.isVerbose,
            rawArguments: args.rawArguments
        )
    }

    static func parseAudio(_ raw: String) -> AudioSource? {
        switch raw.lowercased() {
        case "none", "off", "no", "false", "mute", "0": return .off
        case "system", "app", "desktop", "system-audio": return .system
        case "microphone", "mic", "input": return .microphone
        case "both", "all", "system+microphone", "system+mic": return .both
        default: return nil
        }
    }

    static func parseRegion(_ raw: String) -> CGRect? {
        let separators = CharacterSet(charactersIn: ",xX ")
        let parts = raw.components(separatedBy: separators).filter { !$0.isEmpty }
        guard parts.count == 4,
              let x = Double(parts[0]),
              let y = Double(parts[1]),
              let w = Double(parts[2]),
              let h = Double(parts[3]),
              w > 0, h > 0 else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    static func resolveOutput(_ raw: String?, format: VideoFormat, overwrite: Bool) throws -> URL {
        let fm = FileManager.default
        let settings = SettingsStore.shared.current
        var url: URL

        if let raw, !raw.isEmpty {
            let expanded = NSString(string: raw).expandingTildeInPath
            url = URL(fileURLWithPath: expanded)
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                url = AppPaths.availableOutputURL(directory: url, format: format)
            } else if raw.hasSuffix("/") {
                try? fm.createDirectory(at: url, withIntermediateDirectories: true)
                url = AppPaths.availableOutputURL(directory: url, format: format)
            } else {
                if url.pathExtension.isEmpty {
                    url = url.appendingPathExtension(format.fileExtension)
                } else if url.pathExtension.lowercased() != format.fileExtension {
                    throw CLIError(
                        "The output extension .\(url.pathExtension) does not match format \(format.rawValue) (.\(format.fileExtension)).",
                        code: "output_extension_mismatch",
                        exitCode: .usage,
                        hint: "Use a matching extension or let irecord add it automatically."
                    )
                }
            }
        } else {
            url = AppPaths.availableOutputURL(directory: settings.outputDirectoryURL, format: format)
        }

        let directory = url.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw CLIError("Cannot create the output folder \(directory.path).", code: "output_not_writable", exitCode: .output)
        }

        if fm.fileExists(atPath: url.path) {
            if overwrite {
                do {
                    try fm.removeItem(at: url)
                } catch {
                    throw CLIError("Cannot replace \(url.path).", code: "output_not_writable", exitCode: .output)
                }
            } else {
                throw CLIError("The output file already exists: \(url.path)", code: "output_exists", exitCode: .output,
                               hint: "Pass --overwrite to replace it.")
            }
        }
        return url
    }

    // MARK: - Target resolution

    static func resolveTarget(_ plan: RecordPlan, verbose: Bool = false) async throws -> (CaptureTarget, String) {
        switch plan.mode {
        case .screen:
            return (.display(displayID: plan.displayID), "display \(plan.displayID)")
        case .region:
            guard let region = plan.region else {
                throw CLIError("Missing region.", code: "missing_region", exitCode: .usage)
            }
            return (.region(displayID: plan.displayID, rect: region),
                    "display \(plan.displayID) region \(Int(region.origin.x)),\(Int(region.origin.y)),\(Int(region.width)),\(Int(region.height))")
        case .window:
            if let windowID = plan.windowID {
                if let window = try? await windowsMatching(id: windowID) {
                    return (.window(windowID: window.id, title: window.title), window.displayTitle)
                }
                // Let ScreenCaptureKit give the authoritative answer at capture time.
                return (.window(windowID: windowID, title: ""), "window \(windowID)")
            }
            let windows = try await ShareableContentLoader.windows()
            let matched = windows.filter { window in
                var matches = true
                if let app = plan.windowApp, !app.isEmpty {
                    matches = window.appName.localizedCaseInsensitiveContains(app)
                        || (window.bundleIdentifier?.localizedCaseInsensitiveContains(app) ?? false)
                        || (window.bundleIdentifier == app)
                }
                if let title = plan.windowTitle, !title.isEmpty {
                    matches = matches && window.title.localizedCaseInsensitiveContains(title)
                }
                return matches
            }
            guard let window = matched.first else {
                let description = [plan.windowApp, plan.windowTitle].compactMap { $0 }.joined(separator: " / ")
                throw CLIError("No window matched \(description.isEmpty ? "the query" : description).",
                               code: "no_window", exitCode: .target,
                               hint: "Run `irecord targets --json` to list available windows.")
            }
            if verbose {
                Log.write("Matched window \(window.id): \(window.displayTitle)")
            }
            return (.window(windowID: window.id, title: window.title), window.displayTitle)
        }
    }

    private static func windowsMatching(id: CGWindowID) async throws -> WindowInfo? {
        let windows = try await ShareableContentLoader.windows()
        return windows.first { $0.id == id }
    }

    // MARK: - Record

    static func runRecord(_ args: CLIArgs) async {
        let plan: RecordPlan
        do {
            plan = try buildPlan(args)
        } catch let error as CLIError {
            CLIOutput.error(error.message, code: error.code, json: args.wantsJSON, exitCode: error.exitCode, hint: error.hint)
        } catch {
            CLIOutput.error(error.localizedDescription, code: "invalid_arguments", json: args.wantsJSON, exitCode: .usage)
        }

        if plan.duration <= 0 && isatty(STDIN_FILENO) == 0 {
            CLIOutput.error(
                "A foreground recording without --duration would run forever in a non-interactive environment.",
                code: "missing_duration",
                json: plan.json,
                exitCode: .usage,
                hint: "Pass --duration <seconds>, or use `irecord start` for a session you can stop explicitly."
            )
        }

        await ensurePermissions(plan: plan, json: plan.json, quiet: plan.quiet)

        let target: CaptureTarget
        do {
            (target, _) = try await resolveTarget(plan, verbose: plan.verbose)
        } catch let error as CLIError {
            CLIOutput.error(error.message, code: error.code, json: plan.json, exitCode: error.exitCode, hint: error.hint)
        } catch let error as CaptureError {
            CLIOutput.error(
                error.errorDescription ?? "Could not resolve the capture target.",
                code: error.code,
                json: plan.json,
                exitCode: .target,
                hint: "Run `irecord targets --json`."
            )
        } catch {
            CLIOutput.error(error.localizedDescription, code: "no_target", json: plan.json, exitCode: .target)
        }

        let recorder = ScreenRecorder()
        if plan.verbose {
            recorder.onStateChange = { state in
                CLIOutput.info("state: \(state.rawValue)", quiet: plan.quiet)
            }
        }

        CLIOutput.info("iRecord \(AppInfo.version) — recording \(plan.mode.rawValue) → \(plan.outputURL.path)", quiet: plan.quiet)

        let stopState = StopCoordinator()
        signal(SIGINT, SIG_IGN)
        let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global(qos: .userInitiated))

        let outcome: Result<RecordingResult, Error> = await withCheckedContinuation { (continuation: CheckedContinuation<Result<RecordingResult, Error>, Never>) in
            let gate = CompletionGate(continuation)

            recorder.onError = { error in
                if stopState.beginStopping() {
                    CLIOutput.info("Capture error: \(error.errorDescription ?? "unknown")", quiet: plan.quiet)
                    gate.finish(.failure(error))
                }
            }

            signalSource.setEventHandler {
                if stopState.beginStopping() {
                    CLIOutput.info("Stopping…", quiet: plan.quiet)
                    Task {
                        do {
                            gate.finish(.success(try await recorder.stop()))
                        } catch {
                            gate.finish(.failure(error))
                        }
                    }
                } else {
                    CLIOutput.info("Force quit.", quiet: plan.quiet)
                    recorder.abort()
                    exit(CLIExit.cancelled.rawValue)
                }
            }
            signalSource.resume()

            Task {
                do {
                    _ = try await recorder.start(target: target, options: plan.options, outputURL: plan.outputURL)
                    if plan.verbose {
                        CLIOutput.info("Capture started.", quiet: plan.quiet)
                    }
                    if plan.duration > 0 {
                        try await Task.sleep(nanoseconds: UInt64(plan.duration * 1_000_000_000))
                        if stopState.beginStopping() {
                            gate.finish(.success(try await recorder.stop()))
                        }
                    }
                } catch {
                    gate.finish(.failure(error))
                }
            }
        }
        signalSource.cancel()

        switch outcome {
        case .success(let result):
            outputSuccess(result, session: nil, json: plan.json, quiet: plan.quiet)
        case .failure(let error):
            outputFailure(error, json: plan.json)
        }
    }

    static func outputSuccess(_ result: RecordingResult, session: String?, json: Bool, quiet: Bool) {
        if json {
            var object: [String: Any] = [
                "ok": true,
                "output": result.outputPath,
                "format": result.format.rawValue,
                "duration": (result.duration * 1000).rounded() / 1000,
                "width": result.width,
                "height": result.height,
                "fileSize": result.fileSize,
                "audio": result.hasAudio
            ]
            if let session { object["session"] = session }
            CLIOutput.json(object)
        }
        let size = ByteCountFormatter.string(fromByteCount: result.fileSize, countStyle: .file)
        CLIOutput.line("Saved \(result.outputPath)")
        CLIOutput.line("  \(result.format.rawValue) · \(result.width)×\(result.height) · \(String(format: "%.2f", result.duration))s · \(size)" + (result.hasAudio ? " · audio" : ""))
        exit(CLIExit.ok.rawValue)
    }

    static func outputFailure(_ error: Error, json: Bool) {
        var code = "recording_failed"
        var exitCode: CLIExit = .general
        var hint: String?
        if let cli = error as? CLIError {
            code = cli.code
            exitCode = cli.exitCode
            hint = cli.hint
        } else if let capture = error as? CaptureError {
            code = capture.code
            switch capture {
            case .screenPermission, .microphonePermission:
                exitCode = .permission
                hint = "Grant the permission in System Settings → Privacy & Security, then retry."
            case .noDisplay, .noWindow, .invalidRegion:
                exitCode = .target
                hint = "Run `irecord targets --json`."
            case .outputNotWritable, .outputExists:
                exitCode = .output
            default:
                exitCode = .general
            }
        }
        let message = (error as? CaptureError)?.errorDescription ?? (error as? CLIError)?.message ?? error.localizedDescription
        CLIOutput.error(message, code: code, json: json, exitCode: exitCode, hint: hint)
    }

    static func ensurePermissions(plan: RecordPlan, json: Bool, quiet: Bool) async {
        guard Permissions.hasScreenCapture else {
            CLIOutput.info("Requesting Screen Recording permission…", quiet: quiet)
            _ = Permissions.requestScreenCapture()
            if !Permissions.hasScreenCapture {
                CLIOutput.error(
                    "Screen Recording permission is not granted.",
                    code: "screen_permission_denied",
                    json: json,
                    exitCode: .permission,
                    hint: "Open System Settings → Privacy & Security → Screen Recording, enable the app running irecord (Terminal or your automation host), then run the command again. Some macOS versions require restarting the host process."
                )
            }
            return
        }
        if plan.options.capturesMicrophone {
            switch Permissions.microphoneAuthorization {
            case .authorized:
                return
            case .notDetermined:
                let granted = await Permissions.requestMicrophone()
                if !granted {
                    CLIOutput.error(
                        "Microphone permission is not granted.",
                        code: "microphone_permission_denied",
                        json: json,
                        exitCode: .permission,
                        hint: "Grant microphone access in System Settings → Privacy & Security → Microphone. The bundled CLI inside iRecord.app includes the required usage description."
                    )
                }
            default:
                CLIOutput.error(
                    "Microphone permission is not granted.",
                    code: "microphone_permission_denied",
                    json: json,
                    exitCode: .permission,
                    hint: "Grant microphone access in System Settings → Privacy & Security → Microphone."
                )
            }
        }
    }

    // MARK: - Targets

    static func runTargets(_ args: CLIArgs) async {
        guard Permissions.hasScreenCapture else {
            CLIOutput.error(
                "Screen Recording permission is not granted.",
                code: "screen_permission_denied",
                json: args.wantsJSON,
                exitCode: .permission,
                hint: "Enable the invoking process in System Settings → Privacy & Security → Screen Recording."
            )
        }
        do {
            let content = try await ShareableContentLoader.load()
            let mainID = CGMainDisplayID()
            let scales: [CGDirectDisplayID: Double] = Dictionary(
                uniqueKeysWithValues: NSScreen.screens.compactMap { screen in
                    guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
                    return (CGDirectDisplayID(number.uint32Value), Double(screen.backingScaleFactor))
                }
            )
            let displays: [[String: Any]] = content.displays
                .sorted { $0.displayID < $1.displayID }
                .map { display in
                    let pointWidth = Int(display.frame.width > 0 ? display.frame.width : CGFloat(display.width))
                    let pointHeight = Int(display.frame.height > 0 ? display.frame.height : CGFloat(display.height))
                    let scale = scales[display.displayID] ?? (Double(display.width) / max(1, Double(pointWidth)))
                    return [
                        "id": Int(display.displayID),
                        "width": Int((Double(pointWidth) * scale).rounded()),
                        "height": Int((Double(pointHeight) * scale).rounded()),
                        "point_width": pointWidth,
                        "point_height": pointHeight,
                        "scale": scale,
                        "main": display.displayID == mainID
                    ]
                }

            var windows: [[String: Any]] = []
            if !args.has("displays-only") {
                let list = try await ShareableContentLoader.windows(includeSystemWindows: args.has("include-system"))
                windows = list.map { window in
                    var item: [String: Any] = [
                        "id": Int(window.id),
                        "app": window.appName,
                        "title": window.title,
                        "width": window.width,
                        "height": window.height,
                        "on_screen": window.isOnScreen
                    ]
                    if let bundle = window.bundleIdentifier { item["bundle_id"] = bundle }
                    return item
                }
            }

            let object: [String: Any] = [
                "ok": true,
                "displays": displays,
                "windows": windows,
                "region_coordinates": "display-local points, top-left origin: x,y,width,height"
            ]
            if args.wantsJSON {
                CLIOutput.json(object)
            }
            CLIOutput.line("Displays:")
            for display in displays {
                let main = (display["main"] as? Bool) == true ? " (main)" : ""
                CLIOutput.line("  \(display["id"]!)\(main)  \(display["point_width"]!)×\(display["point_height"]!) pt  \(display["width"]!)×\(display["height"]!) px")
            }
            if !windows.isEmpty {
                CLIOutput.line("")
                CLIOutput.line("Windows:")
                for window in windows.prefix(60) {
                    CLIOutput.line("  \(window["id"]!)  \(window["app"]!) — \(window["title"]!)  [\(window["width"]!)×\(window["height"]!)]")
                }
            }
            exit(CLIExit.ok.rawValue)
        } catch {
            CLIOutput.error(
                "Could not enumerate capture targets: \(error.localizedDescription)",
                code: "targets_failed",
                json: args.wantsJSON,
                exitCode: .permission,
                hint: "Confirm Screen Recording permission with `irecord doctor --json`."
            )
        }
    }

    // MARK: - doctor / config / version

    static func runDoctor(_ args: CLIArgs) {
        let settings = SettingsStore.shared.current
        let directory = settings.outputDirectoryURL
        var writable = false
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let probe = directory.appendingPathComponent(".irecord-write-test-\(UUID().uuidString)")
            try Data("ok".utf8).write(to: probe)
            try? FileManager.default.removeItem(at: probe)
            writable = true
        } catch {
            writable = false
        }

        let screenGranted = Permissions.hasScreenCapture
        let micStatus: String
        switch Permissions.microphoneAuthorization {
        case .authorized: micStatus = "authorized"
        case .denied: micStatus = "denied"
        case .restricted: micStatus = "restricted"
        case .notDetermined: micStatus = "not_determined"
        @unknown default: micStatus = "unknown"
        }

        var issues: [String] = []
        if !screenGranted { issues.append("screen_recording_permission_missing") }
        if !writable { issues.append("output_folder_not_writable") }

        let active = SessionStore.latest(activeOnly: true)
        let ready = issues.isEmpty

        if args.wantsJSON {
            var object: [String: Any] = [
                "ok": true,
                "ready": ready,
                "tool": "irecord",
                "version": AppInfo.version,
                "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
                "architecture": architecture(),
                "executable": CommandLine.arguments.first ?? "irecord",
                "bundled": Bundle.main.bundleIdentifier != nil,
                "screenPermission": screenGranted,
                "microphonePermission": micStatus,
                "outputDirectory": directory.path,
                "outputWritable": writable,
                "settingsPath": AppPaths.settingsFile.path,
                "controlSocket": AppPaths.controlSocket.path,
                "formats": VideoFormat.allCases.map(\.rawValue),
                "formatsDetail": VideoFormat.allCases.map { [$0.rawValue, $0.displayName] },
                "defaultFormat": settings.format.rawValue,
                "issues": issues,
                "activeSession": active.map(sessionDictionary) ?? NSNull()
            ]
            object["bundleIdentifier"] = Bundle.main.bundleIdentifier ?? NSNull()
            object["hint"] = ready
                ? "Ready. Run `irecord targets --json`, then `irecord record ... --json`."
                : "Resolve the items in `issues` before recording."
            CLIOutput.json(object)
        }

        CLIOutput.line("iRecord \(AppInfo.version) — doctor")
        CLIOutput.line("  macOS:              \(ProcessInfo.processInfo.operatingSystemVersionString)")
        CLIOutput.line("  Screen Recording:   \(screenGranted ? "granted" : "MISSING")")
        CLIOutput.line("  Microphone:         \(micStatus)")
        CLIOutput.line("  Output folder:      \(directory.path) \(writable ? "(writable)" : "(not writable)")")
        CLIOutput.line("  Formats:            \(VideoFormat.supportedList)")
        if let active {
            CLIOutput.line("  Active session:     \(active.id) (\(active.state))")
        }
        if ready {
            CLIOutput.line("  Status:             ready")
        } else {
            CLIOutput.line("  Issues:             \(issues.joined(separator: ", "))")
        }
        exit(ready ? CLIExit.ok.rawValue : CLIExit.permission.rawValue)
    }

    static func architecture() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    static func runConfig(_ args: CLIArgs) {
        let settings = SettingsStore.shared.current
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var dictionary: [String: Any] = [:]
        if let data = try? encoder.encode(settings),
           let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            dictionary = raw
        }
        let object: [String: Any] = [
            "ok": true,
            "settings": dictionary,
            "settingsPath": AppPaths.settingsFile.path,
            "outputDirectory": settings.outputDirectoryURL.path,
            "formats": VideoFormat.allCases.map { ["id": $0.rawValue, "name": $0.displayName, "extension": $0.fileExtension] },
            "version": AppInfo.version
        ]
        if args.wantsJSON {
            CLIOutput.json(object)
        }
        CLIOutput.line("Settings: \(AppPaths.settingsFile.path)")
        CLIOutput.line("  Format:    \(settings.format.rawValue)")
        CLIOutput.line("  FPS:       \(settings.fps)")
        CLIOutput.line("  Quality:   \(settings.quality.rawValue)")
        CLIOutput.line("  Audio:     \(settings.audioSource.rawValue)")
        CLIOutput.line("  Output:    \(settings.outputDirectory)")
        CLIOutput.line("  Language:  \(settings.language.rawValue)")
        exit(CLIExit.ok.rawValue)
    }

    // MARK: - Control

    static func sessionDictionary(_ session: HeadlessSession) -> [String: Any] {
        var object: [String: Any] = [
            "ok": true,
            "session": session.id,
            "pid": Int(session.pid),
            "state": session.state,
            "mode": session.mode,
            "target": session.target,
            "outputPath": session.outputPath,
            "startedAt": CLIOutput.iso(session.startedAt),
            "updatedAt": CLIOutput.iso(session.updatedAt),
            "elapsed": (session.elapsed * 1000).rounded() / 1000
        ]
        if let result = session.result {
            object["result"] = [
                "output": result.outputPath,
                "format": result.format.rawValue,
                "duration": (result.duration * 1000).rounded() / 1000,
                "width": result.width,
                "height": result.height,
                "fileSize": result.fileSize,
                "audio": result.hasAudio
            ]
        }
        if let error = session.error { object["error"] = error }
        if let code = session.code { object["code"] = code }
        if let log = session.logFile { object["log"] = log }
        return object
    }

    static func targetSession(_ args: CLIArgs) -> HeadlessSession? {
        if let id = args.string("session") {
            return SessionStore.read(id: id)
        }
        return SessionStore.latest(activeOnly: true) ?? SessionStore.latest()
    }

    static func runControl(_ args: CLIArgs, action: String) {
        guard let session = targetSession(args) else {
            CLIOutput.error("No active recording session.", code: "no_session", json: args.wantsJSON, exitCode: .general,
                            hint: "Start one with `irecord start`.")
        }
        do {
            let response = try ControlClient.request(ControlRequest(command: action, session: session.id))
            if !response.ok {
                CLIOutput.error(response.error ?? "Control command failed.", code: response.code ?? "control_failed",
                                json: args.wantsJSON, exitCode: .general)
            }
            if args.wantsJSON {
                CLIOutput.json([
                    "ok": true,
                    "session": session.id,
                    "state": response.state ?? action,
                    "elapsed": response.elapsed ?? 0,
                    "outputPath": response.outputPath ?? session.outputPath
                ])
            }
            CLIOutput.line("\(action): \(session.id) \(response.state ?? "")")
            exit(CLIExit.ok.rawValue)
        } catch {
            if args.wantsJSON {
                CLIOutput.error(error.localizedDescription, code: "control_failed", json: true, exitCode: .general)
            }
            CLIOutput.error(error.localizedDescription, code: "control_failed", json: false, exitCode: .general)
        }
    }

    static func runStatus(_ args: CLIArgs) {
        guard let session = targetSession(args) else {
            CLIOutput.error("No recording session found.", code: "no_session", json: args.wantsJSON, exitCode: .general,
                            hint: "Start one with `irecord start`.")
        }
        var displayed = session
        if session.isActive {
            if let response = try? ControlClient.request(ControlRequest(command: "status", session: session.id), timeout: 3) {
                if let state = response.state { displayed.state = state }
                if let elapsed = response.elapsed { displayed.elapsed = elapsed }
                if let output = response.outputPath { displayed.outputPath = output }
            }
        }
        if args.wantsJSON {
            CLIOutput.json(sessionDictionary(displayed))
        }
        CLIOutput.line("Session \(displayed.id)")
        CLIOutput.line("  State:   \(displayed.state)")
        CLIOutput.line("  Mode:    \(displayed.mode) — \(displayed.target)")
        CLIOutput.line("  Elapsed: \(String(format: "%.1f", displayed.elapsed))s")
        CLIOutput.line("  Output:  \(displayed.outputPath)")
        if let error = displayed.error {
            CLIOutput.line("  Error:   \(error)")
        }
        exit(displayed.state == "failed" ? CLIExit.general.rawValue : CLIExit.ok.rawValue)
    }

    static func runStop(_ args: CLIArgs) async {
        guard let session = targetSession(args) else {
            CLIOutput.error("No recording session found.", code: "no_session", json: args.wantsJSON, exitCode: .general,
                            hint: "Start one with `irecord start`.")
        }
        if session.isTerminal {
            if args.wantsJSON { CLIOutput.json(sessionDictionary(session)) }
            if let result = session.result {
                CLIOutput.line("Already finished: \(result.outputPath)")
                exit(CLIExit.ok.rawValue)
            }
            CLIOutput.error(session.error ?? "Session finished with an error.", code: session.code ?? "session_failed",
                            json: args.wantsJSON, exitCode: .general)
        }

        do {
            let response = try ControlClient.request(ControlRequest(command: "stop", session: session.id), timeout: 10)
            if !response.ok {
                CLIOutput.error(response.error ?? "Stop failed.", code: response.code ?? "stop_failed",
                                json: args.wantsJSON, exitCode: .general)
            }
        } catch {
            CLIOutput.error(error.localizedDescription, code: "control_failed", json: args.wantsJSON, exitCode: .general)
        }

        let timeout = args.double("timeout") ?? 300
        let deadline = Date().addingTimeInterval(max(5, timeout))
        var latest = SessionStore.read(id: session.id)
        while Date() < deadline {
            latest = SessionStore.read(id: session.id)
            if let latest, latest.isTerminal { break }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        guard let latest else {
            CLIOutput.error("The session disappeared before it finished.", code: "session_lost", json: args.wantsJSON, exitCode: .general)
        }
        if latest.state == "completed", let result = latest.result {
            if args.wantsJSON {
                CLIOutput.json(sessionDictionary(latest))
            }
            let size = ByteCountFormatter.string(fromByteCount: result.fileSize, countStyle: .file)
            CLIOutput.line("Saved \(result.outputPath) (\(result.format.rawValue), \(String(format: "%.2f", result.duration))s, \(size))")
            exit(CLIExit.ok.rawValue)
        }
        if latest.state == "cancelled" {
            CLIOutput.error("The recording was cancelled.", code: "cancelled", json: args.wantsJSON, exitCode: .cancelled)
        }
        if !latest.isTerminal {
            CLIOutput.error(
                "Timed out waiting for the recording to finish. It may still be converting.",
                code: "timeout",
                json: args.wantsJSON,
                exitCode: .timeout,
                hint: "Check `irecord status --session \(session.id) --json` later, or increase --timeout."
            )
        }
        CLIOutput.error(latest.error ?? "The recording failed.", code: latest.code ?? "recording_failed",
                        json: args.wantsJSON, exitCode: .general)
    }
}

final class CompletionGate {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result<RecordingResult, Error>, Never>?

    init(_ continuation: CheckedContinuation<Result<RecordingResult, Error>, Never>) {
        self.continuation = continuation
    }

    func finish(_ value: Result<RecordingResult, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

final class StopCoordinator {
    private let lock = NSLock()
    private var stopping = false

    func beginStopping() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if stopping { return false }
        stopping = true
        return true
    }
}
