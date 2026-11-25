import AppKit
import iRecordCore
import ServiceManagement
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    private let state = AppState()
    private let recorder = ScreenRecorder()
    private let hotkeys = HotkeyManager()
    private let recordingBorder = RecordingBorderController()
    private var lastRecordingTarget: CaptureTarget?

    private var statusItem: NSStatusItem!
    private var headerItem: NSMenuItem?
    private var launcher: NSPanel?
    private var launcherEffectView: NSVisualEffectView?
    private var settingsWindowController: SettingsWindowController?
    private var windowPicker: WindowPickerController?
    private var regionSelector: RegionSelectorController?
    private var timer: Timer?
    private var startedAt: Date?
    private var pausedAt: Date?
    private var pausedAccumulated: TimeInterval = 0
    private var isStarting = false
    private var lastOutputURL: URL?
    private var didSetupNotifications = false

    private let launcherWidth: CGFloat = 252
    private let launcherHeight: CGFloat = 52

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppPaths.ensureDirectories()
        NSApp.setActivationPolicy(.accessory)
        state.reloadFromStore()

        configureActions()
        configureRecorder()
        configureHotkeys()
        buildMainMenu()
        buildStatusItem()
        updateMenu()
        setupLauncher()
        updateLauncherVisibility()
        updateStatusIcon()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        switch recorder.state {
        case .recording, .paused:
            recordingBorder.hide()
            Task { @MainActor in
                _ = try? await recorder.stop()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        case .preparing, .finishing, .converting:
            recorder.abort()
            DispatchQueue.main.async {
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        case .idle:
            return .terminateNow
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        recordingBorder.hide()
        hotkeys.unregisterAll()
    }

    private func configureActions() {
        state.actions.startFullScreen = { [weak self] in self?.beginFullScreen() }
        state.actions.startWindow = { [weak self] in self?.beginWindow() }
        state.actions.startRegion = { [weak self] in self?.beginRegion() }
        state.actions.toggleRecording = { [weak self] in self?.toggleRecording() }
        state.actions.stop = { [weak self] in self?.stopRecording() }
        state.actions.pauseResume = { [weak self] in self?.togglePause() }
        state.actions.openSettings = { [weak self] in self?.openSettings() }
        state.actions.openFolder = { [weak self] in self?.openOutputFolder() }
        state.actions.chooseOutputFolder = { [weak self] in self?.chooseOutputFolder() }
        state.actions.setLauncherVisible = { [weak self] visible in
            self?.state.updateSettings { $0.showFloatingButton = visible }
        }
        state.actions.settingsChanged = { [weak self] old, new in
            self?.settingsChanged(old: old, new: new)
        }
        state.actions.quit = { NSApp.terminate(nil) }
    }

    private func configureRecorder() {
        recorder.onStateChange = { [weak self] newState in
            DispatchQueue.main.async {
                self?.handleRecorderState(newState)
            }
        }
        recorder.onError = { [weak self] error in
            DispatchQueue.main.async {
                self?.presentError(error)
            }
        }
        recorder.onAudioLevel = { [weak self] level in
            DispatchQueue.main.async {
                self?.state.audioMeter.update(level)
            }
        }
    }

    private func configureHotkeys() {
        hotkeys.onAction = { [weak self] action in
            DispatchQueue.main.async {
                guard let self else { return }
                switch action {
                case .toggle: self.toggleRecording()
                case .pause: self.togglePause()
                case .stop: self.stopRecording()
                }
            }
        }
        registerHotkeys()
    }

    private func registerHotkeys() {
        let settings = state.settings
        let failures = hotkeys.register(
            toggle: settings.startHotkey,
            pause: settings.pauseHotkey,
            stop: settings.stopHotkey
        )
        if failures.isEmpty && settings.startHotkey != settings.pauseHotkey
            && settings.startHotkey != settings.stopHotkey
            && settings.pauseHotkey != settings.stopHotkey {
            state.hotkeyWarning = nil
        } else {
            state.hotkeyWarning = L10n.t("settings.hotkeyUnavailable")
        }
    }

    // MARK: - Main menu

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L10n.t("menu.about"), action: #selector(showAbout), keyEquivalent: "")
            .target = self
        appMenu.addItem(NSMenuItem.separator())
        let settings = appMenu.addItem(withTitle: L10n.t("menu.settings"), action: #selector(openSettingsMenu), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: L10n.t("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Status item & menu

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.toolTip = "iRecord"
        }
        updateStatusIcon()
    }

    private func updateMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let header = NSMenuItem(title: headerTitle(), action: nil, keyEquivalent: "")
        header.isEnabled = false
        headerItem = header
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        let active = recorder.state == .recording || recorder.state == .paused
        let busy = state.isBusy

        if active {
            let stop = NSMenuItem(
                title: "\(L10n.t("menu.stop"))  \(state.settings.stopHotkey.displayString)",
                action: #selector(stopRecordingMenu),
                keyEquivalent: ""
            )
            stop.target = self
            stop.isEnabled = recorder.state != .finishing && recorder.state != .converting
            menu.addItem(stop)

            let pause = NSMenuItem(
                title: recorder.state == .paused
                    ? "\(L10n.t("menu.resume"))  \(state.settings.pauseHotkey.displayString)"
                    : "\(L10n.t("menu.pause"))  \(state.settings.pauseHotkey.displayString)",
                action: #selector(togglePauseMenu),
                keyEquivalent: ""
            )
            pause.target = self
            pause.isEnabled = !busy
            menu.addItem(pause)
        } else {
            let start = NSMenuItem(
                title: "\(L10n.t("menu.start"))  \(state.settings.startHotkey.displayString)",
                action: #selector(startFullScreenMenu),
                keyEquivalent: ""
            )
            start.target = self
            start.isEnabled = !busy
            menu.addItem(start)
        }

        menu.addItem(NSMenuItem.separator())

        let newRecording = NSMenuItem(title: L10n.t("menu.capture"), action: nil, keyEquivalent: "")
        let modeMenu = NSMenu()
        let modes: [(String, Selector)] = [
            (L10n.t("menu.mode.screen"), #selector(startFullScreenMenu)),
            (L10n.t("menu.mode.window"), #selector(startWindowMenu)),
            (L10n.t("menu.mode.region"), #selector(startRegionMenu))
        ]
        for (title, selector) in modes {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            item.isEnabled = !active && !busy
            modeMenu.addItem(item)
        }
        newRecording.submenu = modeMenu
        newRecording.isEnabled = !active && !busy
        menu.addItem(newRecording)

        let formatItem = NSMenuItem(title: L10n.t("menu.format"), action: nil, keyEquivalent: "")
        let formatMenu = NSMenu()
        for format in VideoFormat.allCases {
            let item = NSMenuItem(title: format.displayName, action: #selector(selectFormat(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = format.rawValue
            item.state = state.settings.format == format ? .on : .off
            item.isEnabled = !active
            formatMenu.addItem(item)
        }
        formatItem.submenu = formatMenu
        formatItem.isEnabled = !active
        menu.addItem(formatItem)

        let audioItem = NSMenuItem(title: L10n.t("settings.audioSource"), action: nil, keyEquivalent: "")
        let audioMenu = NSMenu()
        for source in AudioSource.allCases {
            let item = NSMenuItem(title: source.displayName, action: #selector(selectAudioSource(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = source.rawValue
            item.state = state.settings.audioSource == source ? .on : .off
            item.isEnabled = !active
            audioMenu.addItem(item)
        }
        audioItem.submenu = audioMenu
        audioItem.isEnabled = !active
        menu.addItem(audioItem)

        menu.addItem(NSMenuItem.separator())

        let launcherItem = NSMenuItem(
            title: state.settings.showFloatingButton ? L10n.t("menu.hideLauncher") : L10n.t("menu.showLauncher"),
            action: #selector(toggleLauncher),
            keyEquivalent: ""
        )
        launcherItem.target = self
        menu.addItem(launcherItem)

        let openItem = NSMenuItem(title: L10n.t("menu.openFolder"), action: #selector(openFolderMenu), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let permissionItem = NSMenuItem(title: L10n.t("menu.permission"), action: #selector(openPermissionSettings), keyEquivalent: "")
        permissionItem.target = self
        permissionItem.isEnabled = !Permissions.hasScreenCapture
        menu.addItem(permissionItem)

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: L10n.t("menu.settings"), action: #selector(openSettingsMenu), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let aboutItem = NSMenuItem(title: L10n.t("menu.about"), action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: L10n.t("menu.quit"), action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func headerTitle() -> String {
        switch recorder.state {
        case .recording:
            return "● \(L10n.t("menu.recording"))  \(state.elapsedString)  ·  \(state.settings.format.shortName)"
        case .paused:
            return "❚❚ \(L10n.t("menu.paused"))  \(state.elapsedString)"
        case .preparing:
            return L10n.t("status.preparing")
        case .finishing:
            return L10n.t("status.saving")
        case .converting:
            return L10n.t("status.gifConverting")
        case .idle:
            return "iRecord — \(L10n.t("menu.ready"))"
        }
    }

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        switch recorder.state {
        case .recording:
            button.image = nil
            button.attributedTitle = NSAttributedString(
                string: "●",
                attributes: [
                    .foregroundColor: NSColor.systemRed,
                    .font: NSFont.systemFont(ofSize: 15, weight: .bold)
                ]
            )
        case .paused:
            button.image = nil
            button.attributedTitle = NSAttributedString(
                string: "❚❚",
                attributes: [
                    .foregroundColor: NSColor.systemOrange,
                    .font: NSFont.systemFont(ofSize: 11, weight: .bold)
                ]
            )
        case .preparing, .finishing, .converting:
            button.attributedTitle = NSAttributedString(string: "")
            button.image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: "iRecord")
            button.image?.isTemplate = true
        case .idle:
            button.attributedTitle = NSAttributedString(string: "")
            button.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "iRecord")
            button.image?.isTemplate = true
        }
        button.toolTip = headerTitle()
    }

    // MARK: - Launcher

    private func setupLauncher() {
        let panel = LauncherPanel(
            contentRect: NSRect(x: 0, y: 0, width: launcherWidth, height: launcherHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.sharingType = .none
        panel.delegate = self

        // Use a real NSVisualEffectView as the glass layer. It must be a
        // sibling of the SwiftUI host (not its parent), otherwise changing the
        // glass opacity would also fade the volume meter.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: launcherWidth, height: launcherHeight))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        container.layer?.cornerRadius = 14
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true

        let effectView = NSVisualEffectView(frame: container.bounds)
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.isEmphasized = true
        effectView.appearance = NSAppearance(named: .darkAqua)
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 14
        effectView.layer?.cornerCurve = .continuous
        effectView.layer?.masksToBounds = true
        effectView.autoresizingMask = [.width, .height]
        effectView.alphaValue = CGFloat(state.settings.launcherOpacity)
        container.addSubview(effectView)

        let hosting = FirstMouseHostingView(rootView: LauncherView(state: state))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        container.addSubview(hosting, positioned: .above, relativeTo: effectView)
        panel.contentView = container
        launcherEffectView = effectView

        positionLauncher(panel)
        launcher = panel
    }

    private func positionLauncher(_ panel: NSWindow) {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "launcherX") != nil {
            let origin = NSPoint(x: defaults.double(forKey: "launcherX"), y: defaults.double(forKey: "launcherY"))
            let candidate = NSRect(origin: origin, size: panel.frame.size)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(candidate.insetBy(dx: -20, dy: -20)) }) {
                panel.setFrameOrigin(origin)
                return
            }
        }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(
            x: visible.maxX - launcherWidth - 22,
            y: visible.minY + 22
        ))
    }

    private func updateLauncherVisibility() {
        guard let launcher else { return }
        if state.settings.showFloatingButton {
            launcher.orderFrontRegardless()
        } else {
            launcher.orderOut(nil)
        }
    }

    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === launcher else { return }
        let defaults = UserDefaults.standard
        defaults.set(window.frame.origin.x, forKey: "launcherX")
        defaults.set(window.frame.origin.y, forKey: "launcherY")
    }

    // MARK: - Recording actions

    private func screenUnderMouse() -> NSScreen {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(location, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    @objc private func startFullScreenMenu() { beginFullScreen() }
    @objc private func startWindowMenu() { beginWindow() }
    @objc private func startRegionMenu() { beginRegion() }
    @objc private func stopRecordingMenu() { stopRecording() }
    @objc private func togglePauseMenu() { togglePause() }
    @objc private func openSettingsMenu() { openSettings() }
    @objc private func openFolderMenu() { openOutputFolder() }
    @objc private func quitApp() { NSApp.terminate(nil) }

    private func beginFullScreen() {
        let screen = screenUnderMouse()
        let displayID = RegionSelectorController.displayID(for: screen)
        startRecording(target: .display(displayID: displayID), modeKey: "hud.modeScreen")
    }

    private func beginWindow() {
        guard !state.isBusy, recorder.state == .idle else { NSSound.beep(); return }
        let picker = WindowPickerController()
        picker.onSelect = { [weak self] window in
            self?.windowPicker = nil
            self?.startRecording(
                target: .window(windowID: window.id, title: window.title),
                modeKey: "hud.modeWindow"
            )
        }
        picker.onCancel = { [weak self] in
            self?.windowPicker = nil
        }
        windowPicker = picker
        picker.show()
    }

    private func beginRegion() {
        guard !state.isBusy, recorder.state == .idle else { NSSound.beep(); return }
        guard requireScreenPermission() else { return }
        let screen = screenUnderMouse()
        let selector = RegionSelectorController()
        selector.begin(
            on: screen,
            completion: { [weak self] target in
                self?.regionSelector = nil
                self?.startRecording(target: target, modeKey: "hud.modeRegion")
            },
            cancel: { [weak self] in
                self?.regionSelector = nil
            }
        )
        regionSelector = selector
    }

    private func startRecording(target: CaptureTarget, modeKey: String) {
        guard recorder.state == .idle, !isStarting else {
            NSSound.beep()
            return
        }
        isStarting = true
        state.preparing = true
        state.modeLabel = L10n.t(modeKey)
        Task { @MainActor in
            await startRecordingAsync(target: target)
        }
    }

    @MainActor
    private func startRecordingAsync(target: CaptureTarget) async {
        defer {
            isStarting = false
            state.preparing = false
        }

        if !Permissions.hasScreenCapture {
            if !UserDefaults.standard.bool(forKey: "didRequestScreenCapture") {
                UserDefaults.standard.set(true, forKey: "didRequestScreenCapture")
                _ = Permissions.requestScreenCapture()
                return
            }
            presentScreenPermissionAlert()
            return
        }

        let settings = state.settings
        state.recordingHasAudio = false
        state.audioMeter.reset()

        if settings.audioSource.captureMicrophone {
            if Permissions.microphoneAuthorization == .notDetermined {
                _ = await Permissions.requestMicrophone()
            }
            if !Permissions.hasMicrophone {
                presentMicPermissionAlert()
                return
            }
        }

        state.recordingHasAudio = settings.videoOptions.wantsAudio

        let directory = settings.outputDirectoryURL
        let outputURL = AppPaths.availableOutputURL(directory: directory, format: settings.format)
        do {
            let info = try await recorder.start(
                target: target,
                options: settings.videoOptions,
                outputURL: outputURL
            )
            lastOutputURL = URL(fileURLWithPath: info.outputPath)
            startedAt = Date()
            pausedAt = nil
            pausedAccumulated = 0
            state.startedAt = startedAt
            state.elapsed = 0
            // Keep the meter visible whenever audio was requested, even if the
            // writer reported no audio track (the meter then simply stays empty).
            state.recordingHasAudio = info.hasAudio || settings.videoOptions.wantsAudio
            state.audioMeter.reset()
            lastRecordingTarget = target
            if state.settings.showRecordingBorder {
                showRecordingBorder(for: target)
            }
            startTimer()
            updateMenu()
            updateStatusIcon()
        } catch {
            state.recordingHasAudio = false
            state.audioMeter.reset()
            lastRecordingTarget = nil
            recordingBorder.hide()
            presentError(error)
        }
    }

    private func showRecordingBorder(for target: CaptureTarget) {
        let color = NSColor(hex: state.settings.recordingBorderColorHex) ?? .systemRed
        recordingBorder.show(target: target, color: color)
    }

    private func stopRecording() {
        guard recorder.state == .recording || recorder.state == .paused else { return }
        recordingBorder.hide()
        Task { @MainActor in
            do {
                let result = try await recorder.stop()
                handleSaved(result)
            } catch {
                presentError(error)
            }
        }
    }

    private func togglePause() {
        switch recorder.state {
        case .recording:
            recorder.pause()
        case .paused:
            recorder.resume()
        default:
            break
        }
    }

    private func toggleRecording() {
        switch recorder.state {
        case .recording, .paused:
            stopRecording()
        case .idle:
            beginFullScreen()
        default:
            break
        }
    }

    private func handleRecorderState(_ newState: ScreenRecorder.State) {
        let previous = state.recorderState
        state.recorderState = newState
        state.preparing = newState == .preparing

        if newState == .paused, previous == .recording {
            pausedAt = Date()
        }
        if newState == .recording, previous == .paused, let pausedAt {
            pausedAccumulated += Date().timeIntervalSince(pausedAt)
            self.pausedAt = nil
        }
        if newState == .recording, startedAt == nil {
            startedAt = Date()
            state.startedAt = startedAt
            startTimer()
        }
        if newState == .recording, previous != .paused {
            // Reveal the floating launcher even when the user hid it, so the
            // recording controls are immediately available. Hiding it again
            // during the recording is still allowed.
            launcher?.orderFrontRegardless()
        }
        if newState != .recording {
            state.audioMeter.reset()
        }
        if newState == .finishing || newState == .converting || newState == .idle {
            recordingBorder.hide()
        }
        if newState == .idle {
            stopTimer()
            startedAt = nil
            pausedAt = nil
            pausedAccumulated = 0
            state.elapsed = 0
            state.modeLabel = ""
            state.recordingHasAudio = false
            lastRecordingTarget = nil
            // Restore the user's hidden-launcher preference after recording.
            updateLauncherVisibility()
        }
        updateStatusIcon()
        updateMenu()
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let startedAt else { return }
        guard recorder.state == .recording || recorder.state == .paused else { return }
        var elapsed = Date().timeIntervalSince(startedAt) - pausedAccumulated
        if recorder.state == .paused, let pausedAt {
            elapsed -= Date().timeIntervalSince(pausedAt)
        }
        state.elapsed = max(0, elapsed)
        headerItem?.title = headerTitle()
    }

    private func handleSaved(_ result: RecordingResult) {
        let url = URL(fileURLWithPath: result.outputPath)
        lastOutputURL = url
        state.lastSavedPath = result.outputPath
        let settings = state.settings
        if settings.playSoundWhenDone {
            NSSound(named: NSSound.Name("Glass"))?.play()
        }
        if settings.revealWhenDone {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        notifySaved(url: url)
        updateStatusIcon()
        updateMenu()
    }

    // MARK: - Settings & folders

    private func settingsChanged(old: AppSettings, new: AppSettings) {
        L10n.current = new.language.resolved
        if old.startHotkey != new.startHotkey ||
            old.pauseHotkey != new.pauseHotkey ||
            old.stopHotkey != new.stopHotkey {
            registerHotkeys()
        }
        if old.showFloatingButton != new.showFloatingButton {
            updateLauncherVisibility()
        }
        if old.launcherOpacity != new.launcherOpacity {
            launcherEffectView?.alphaValue = CGFloat(new.launcherOpacity)
        }
        if old.recordingBorderColorHex != new.recordingBorderColorHex {
            recordingBorder.updateColor(NSColor(hex: new.recordingBorderColorHex) ?? .systemRed)
        }
        if old.showRecordingBorder != new.showRecordingBorder {
            if new.showRecordingBorder,
               let target = lastRecordingTarget,
               recorder.state == .recording || recorder.state == .paused {
                showRecordingBorder(for: target)
            } else if !new.showRecordingBorder {
                recordingBorder.hide()
            }
        }
        if old.launchAtLogin != new.launchAtLogin {
            applyLoginItem(new.launchAtLogin)
        }
        if old.language != new.language {
            settingsWindowController?.updateTitle()
            buildMainMenu()
            updateStatusIcon()
        }
        updateMenu()
    }

    private func applyLoginItem(_ enabled: Bool) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            state.loginItemWarning = nil
        } catch {
            state.loginItemWarning = L10n.t("settings.startAtLoginError")
            Log.write("Login item update failed: \(error)")
        }
    }

    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = state.settings.outputDirectoryURL
        panel.prompt = L10n.t("settings.choose")
        if panel.runModal() == .OK, let url = panel.url {
            state.updateSettings { $0.outputDirectory = url.path }
        }
    }

    private func openOutputFolder() {
        let directory = state.settings.outputDirectoryURL
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let lastOutputURL, FileManager.default.fileExists(atPath: lastOutputURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([lastOutputURL])
        } else {
            NSWorkspace.shared.open(directory)
        }
    }

    @objc private func selectFormat(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let format = VideoFormat(rawValue: raw) else { return }
        state.updateSettings { $0.format = format }
    }

    @objc private func selectAudioSource(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let source = AudioSource(rawValue: raw) else { return }
        state.updateSettings { $0.audioSource = source }
    }

    @objc private func toggleLauncher() {
        state.updateSettings { $0.showFloatingButton.toggle() }
    }

    @objc private func openPermissionSettings() {
        Permissions.openScreenCaptureSettings()
    }

    private func openSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(state: state)
        }
        settingsWindowController?.show()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showAbout() {
        let repositoryURL = URL(string: "https://github.com/linimbus/irecordmacos")!
        let alert = NSAlert()
        alert.messageText = "iRecord \(AppInfo.version)"
        alert.informativeText = L10n.t("app.tagline") + "\n\n" + L10n.t("settings.aboutText") + "\n\n" + repositoryURL.absoluteString
        alert.addButton(withTitle: L10n.t("common.ok"))
        alert.addButton(withTitle: "GitHub")
        alert.icon = NSApp.applicationIconImage
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(repositoryURL)
        }
    }

    // MARK: - Alerts

    private func presentError(_ error: Error) {
        if let captureError = error as? CaptureError {
            if case .screenPermission = captureError {
                presentScreenPermissionAlert()
                return
            }
            if case .microphonePermission = captureError {
                presentMicPermissionAlert()
                return
            }
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.t("error.title")
        let description: String
        if let captureError = error as? CaptureError {
            description = captureError.localizedDescription(L10n.current)
        } else {
            description = error.localizedDescription
        }
        alert.informativeText = description
        alert.addButton(withTitle: L10n.t("error.ok"))
        alert.runModal()
    }

    /// Returns true when capture is allowed. On the first attempt we let macOS
    /// show its own consent dialog; later attempts explain how to enable the
    /// app in System Settings without stacking a second alert over the system
    /// prompt.
    private func requireScreenPermission() -> Bool {
        if Permissions.hasScreenCapture { return true }
        if !UserDefaults.standard.bool(forKey: "didRequestScreenCapture") {
            UserDefaults.standard.set(true, forKey: "didRequestScreenCapture")
            _ = Permissions.requestScreenCapture()
            return false
        }
        presentScreenPermissionAlert()
        return false
    }

    private func presentScreenPermissionAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.t("permission.screenTitle")
        alert.informativeText = L10n.t("permission.screenBody")
        alert.addButton(withTitle: L10n.t("permission.openSettings"))
        alert.addButton(withTitle: L10n.t("permission.later"))
        if alert.runModal() == .alertFirstButtonReturn {
            Permissions.openScreenCaptureSettings()
        }
    }

    private func presentMicPermissionAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.t("permission.micTitle")
        alert.informativeText = L10n.t("permission.micBody")
        alert.addButton(withTitle: L10n.t("permission.openSettings"))
        alert.addButton(withTitle: L10n.t("permission.later"))
        if alert.runModal() == .alertFirstButtonReturn {
            Permissions.openMicrophoneSettings()
        }
    }

    // MARK: - Notifications

    private func notifySaved(url: URL) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        if !didSetupNotifications {
            didSetupNotifications = true
            center.delegate = self
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        let content = UNMutableNotificationContent()
        content.title = L10n.t("notify.savedTitle")
        content.body = url.lastPathComponent
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }
}

final class SettingsWindowController {
    private var window: NSWindow?
    private let state: AppState

    init(state: AppState) {
        self.state = state
    }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(state: state))
            let panel = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 580, height: 460),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            panel.title = L10n.t("settings.title")
            panel.isReleasedWhenClosed = false
            panel.contentViewController = hosting
            panel.setContentSize(NSSize(width: 580, height: 460))
            center(panel)
            window = panel
        }
        window?.title = L10n.t("settings.title")
        window?.makeKeyAndOrderFront(nil)
        if let window {
            center(window)
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window else { return }
                self.center(window)
            }
        }
    }

    func updateTitle() {
        window?.title = L10n.t("settings.title")
    }

    private func center(_ window: NSWindow) {
        guard let screen = NSScreen.main else {
            window.center()
            return
        }
        let visible = screen.visibleFrame
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        ))
    }
}

private final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// A borderless, non-activating panel normally swallows the first click.
/// Forwarding the first mouse-down keeps the floating launcher responsive
/// without stealing focus from the user's current app.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
    }
}
