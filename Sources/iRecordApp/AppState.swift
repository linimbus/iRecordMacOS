import AppKit
import Combine
import Foundation
import iRecordCore
import SwiftUI

final class AudioMeter: ObservableObject {
    @Published var level: Double = 0

    func update(_ info: AudioLevelInfo) {
        level = Double(max(0, min(1, info.level)))
    }

    func reset() {
        level = 0
    }
}

final class AppState: ObservableObject {
    struct Actions {
        var startFullScreen: (() -> Void)?
        var startWindow: (() -> Void)?
        var startRegion: (() -> Void)?
        var toggleRecording: (() -> Void)?
        var stop: (() -> Void)?
        var pauseResume: (() -> Void)?
        var openSettings: (() -> Void)?
        var openFolder: (() -> Void)?
        var chooseOutputFolder: (() -> Void)?
        var setLauncherVisible: ((Bool) -> Void)?
        var settingsChanged: ((AppSettings, AppSettings) -> Void)?
        var quit: (() -> Void)?
    }

    @Published var settings: AppSettings {
        didSet {
            guard !isLoading else { return }
            let old = previousSettings
            previousSettings = settings
            SettingsStore.shared.replace(with: settings)
            actions.settingsChanged?(old, settings)
        }
    }
    @Published var recorderState: ScreenRecorder.State = .idle
    @Published var recordingHasAudio = false
    @Published var elapsed: TimeInterval = 0
    @Published var startedAt: Date?
    @Published var modeLabel: String = ""
    @Published var preparing: Bool = false
    @Published var hotkeyWarning: String?
    @Published var loginItemWarning: String?
    @Published var lastSavedPath: String?
    @Published var permissionWarning: Bool = false

    let audioMeter = AudioMeter()
    var actions = Actions()
    private var isLoading = false
    private var previousSettings: AppSettings

    init(settings: AppSettings = SettingsStore.shared.current) {
        previousSettings = settings
        isLoading = true
        self.settings = settings
        isLoading = false
        L10n.current = settings.language.resolved
    }

    var isRecording: Bool {
        recorderState == .recording || recorderState == .paused
    }

    var isBusy: Bool {
        preparing || recorderState == .preparing || recorderState == .finishing || recorderState == .converting
    }

    var stateTitle: String {
        if preparing || recorderState == .preparing { return L10n.t("status.preparing") }
        if recorderState == .finishing { return L10n.t("status.saving") }
        if recorderState == .converting { return L10n.t("status.gifConverting") }
        switch recorderState {
        case .paused: return L10n.t("menu.paused")
        case .recording: return L10n.t("menu.recording")
        default: return L10n.t("menu.ready")
        }
    }

    var elapsedString: String {
        let total = Int(max(0, elapsed))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    func updateSettings(_ transform: (inout AppSettings) -> Void) {
        var copy = settings
        transform(&copy)
        settings = copy
    }

    func reloadFromStore() {
        isLoading = true
        settings = SettingsStore.shared.current
        previousSettings = settings
        isLoading = false
    }
}
