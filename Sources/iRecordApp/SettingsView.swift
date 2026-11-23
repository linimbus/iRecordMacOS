import AppKit
import iRecordCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var state: AppState
    @State private var tab: Tab = .general

    enum Tab: String, CaseIterable, Identifiable {
        case general, video, audio, shortcuts, language, about
        var id: String { rawValue }

        var icon: String {
            switch self {
            case .general: return "slider.horizontal.3"
            case .video: return "film"
            case .audio: return "waveform"
            case .shortcuts: return "command"
            case .language: return "globe"
            case .about: return "info.circle"
            }
        }

        var title: String {
            switch self {
            case .general: return L10n.t("settings.general")
            case .video: return L10n.t("settings.video")
            case .audio: return L10n.t("settings.audio")
            case .shortcuts: return L10n.t("settings.shortcuts")
            case .language: return L10n.t("settings.language")
            case .about: return L10n.t("settings.about")
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider().opacity(0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch tab {
                    case .general: generalTab
                    case .video: videoTab
                    case .audio: audioTab
                    case .shortcuts: shortcutsTab
                    case .language: languageTab
                    case .about: aboutTab
                    }
                }
                .padding(14)
            }
            Divider().opacity(0.5)
            footer
        }
        .frame(width: 580, height: 460)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(Tab.allCases) { item in
                Button {
                    tab = item
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: item.icon)
                            .font(.system(size: 13, weight: .medium))
                        Text(item.title)
                            .font(.system(size: 9.5, weight: .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(tab == item ? Color.accentColor.opacity(0.16) : Color.clear)
                    )
                    .foregroundStyle(tab == item ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let warning = state.hotkeyWarning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(warning)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else if let warning = state.loginItemWarning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(warning)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                Text("iRecord \(AppInfo.version)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                NSApp.keyWindow?.close()
            } label: {
                Text(L10n.t("common.close"))
                    .frame(minWidth: 52)
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    // MARK: - General

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            section(L10n.t("settings.saveTo")) {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text(state.settings.outputDirectory)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(state.settings.outputDirectory)
                    Spacer(minLength: 8)
                    Button(L10n.t("settings.choose")) {
                        state.actions.chooseOutputFolder?()
                    }
                    .controlSize(.small)
                    Button {
                        state.actions.openFolder?()
                    } label: {
                        Image(systemName: "arrow.up.forward.app")
                    }
                    .controlSize(.small)
                    .help(L10n.t("settings.openFolder"))
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
            }

            section(L10n.t("settings.appearance")) {
                SettingRow(title: L10n.t("settings.launcherOpacity")) {
                    HStack(spacing: 8) {
                        Slider(value: $state.settings.launcherOpacity, in: 0.3...1.0, step: 0.05)
                            .controlSize(.small)
                            .frame(width: 170)
                        Text("\(Int((state.settings.launcherOpacity * 100).rounded()))%")
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                    }
                }
                Text(L10n.t("settings.launcherOpacityNote"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            section(L10n.t("settings.behavior")) {
                toggleRow(L10n.t("settings.floatingButton"), isOn: $state.settings.showFloatingButton)
                toggleRow(L10n.t("settings.launchAtLogin"), isOn: $state.settings.launchAtLogin)
                toggleRow(L10n.t("settings.revealWhenDone"), isOn: $state.settings.revealWhenDone)
                toggleRow(L10n.t("settings.playSound"), isOn: $state.settings.playSoundWhenDone)
            }
        }
    }

    // MARK: - Video

    private var videoTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            section(L10n.t("settings.video")) {
                SettingRow(title: L10n.t("settings.format")) {
                    Picker("", selection: $state.settings.format) {
                        ForEach(VideoFormat.allCases) { format in
                            Text(format.displayName).tag(format)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }
                SettingRow(title: L10n.t("settings.scale")) {
                    Picker("", selection: $state.settings.scale) {
                        Text("100%").tag(1.0)
                        Text("75%").tag(0.75)
                        Text("50%").tag(0.5)
                    }
                    .labelsHidden()
                    .frame(width: 110)
                }
                SettingRow(title: L10n.t("settings.fps")) {
                    Picker("", selection: $state.settings.fps) {
                        ForEach([10, 15, 24, 30, 60, 120], id: \.self) { value in
                            Text("\(value) fps").tag(value)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                }
                SettingRow(title: L10n.t("settings.quality")) {
                    Picker("", selection: $state.settings.quality) {
                        ForEach(CaptureQuality.allCases) { quality in
                            Text(quality.displayName).tag(quality)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 190)
                }
            }

            if state.settings.format.isGIF {
                section("GIF") {
                    SettingRow(title: L10n.t("settings.gifWidth")) {
                        Picker("", selection: $state.settings.gifMaxWidth) {
                            ForEach([320, 480, 640, 720, 960, 1280], id: \.self) { value in
                                Text("\(value) px").tag(value)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 110)
                    }
                    SettingRow(title: L10n.t("settings.gifFPS")) {
                        Picker("", selection: $state.settings.gifFPS) {
                            ForEach([5, 8, 10, 12, 15, 20], id: \.self) { value in
                                Text("\(value) fps").tag(value)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 110)
                    }
                    Text(L10n.t("settings.gifNote"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            section(L10n.t("settings.mouse")) {
                toggleRow(L10n.t("settings.showCursor"), isOn: $state.settings.showCursor)
                toggleRow(L10n.t("settings.highlightClicks"), isOn: $state.settings.highlightClicks)
                Text(L10n.t("settings.mouseNote"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Audio

    private var audioTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            section(L10n.t("settings.audioSource")) {
                Picker("", selection: $state.settings.audioSource) {
                    ForEach(AudioSource.allCases) { source in
                        Text(source.displayName).tag(source)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 280, alignment: .leading)
                Text(L10n.t("settings.audioNote"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L10n.t("settings.audioScope"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if state.settings.audioSource.captureMicrophone {
                    Divider().opacity(0.5)
                    HStack(spacing: 8) {
                        Image(systemName: Permissions.hasMicrophone ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(Permissions.hasMicrophone ? Color.green : Color.orange)
                        Text(Permissions.hasMicrophone ? L10n.t("audio.microphone") : L10n.t("permission.micTitle"))
                            .font(.system(size: 11))
                        Spacer()
                        if !Permissions.hasMicrophone {
                            Button(L10n.t("permission.openSettings")) {
                                Permissions.openMicrophoneSettings()
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }

            if state.settings.format.isGIF {
                HStack(spacing: 8) {
                    Image(systemName: "speaker.slash.fill")
                        .foregroundStyle(.secondary)
                    Text(L10n.t("settings.gifNote"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
            }
        }
    }

    // MARK: - Shortcuts

    private var shortcutsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            section(L10n.t("settings.hotkeys")) {
                shortcutRow(
                    title: L10n.t("settings.hotkeyStart"),
                    hotkey: $state.settings.startHotkey,
                    conflict: conflicts(with: state.settings.startHotkey, ignoring: .toggle)
                )
                shortcutRow(
                    title: L10n.t("settings.hotkeyPause"),
                    hotkey: $state.settings.pauseHotkey,
                    conflict: conflicts(with: state.settings.pauseHotkey, ignoring: .pause)
                )
                shortcutRow(
                    title: L10n.t("settings.hotkeyStop"),
                    hotkey: $state.settings.stopHotkey,
                    conflict: conflicts(with: state.settings.stopHotkey, ignoring: .stop)
                )
                Text(L10n.t("settings.hotkeyHint"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button(L10n.t("settings.resetHotkeys")) {
                        state.updateSettings {
                            $0.startHotkey = .startDefault
                            $0.pauseHotkey = .pauseDefault
                            $0.stopHotkey = .stopDefault
                        }
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private enum ShortcutAction {
        case toggle, pause, stop
    }

    private func conflicts(with hotkey: Hotkey, ignoring action: ShortcutAction) -> Bool {
        let s = state.settings
        var others: [Hotkey] = []
        if action != .toggle { others.append(s.startHotkey) }
        if action != .pause { others.append(s.pauseHotkey) }
        if action != .stop { others.append(s.stopHotkey) }
        return others.contains(hotkey)
    }

    private func shortcutRow(title: String, hotkey: Binding<Hotkey>, conflict: Bool) -> some View {
        HStack {
            Text(title)
                .frame(width: 170, alignment: .leading)
            ShortcutField(hotkey: hotkey, isConflicting: conflict)
                .frame(width: 150, height: 24)
            if conflict {
                Text(L10n.t("settings.hotkeyConflict"))
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Language

    private var languageTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            section(L10n.t("settings.languageLabel")) {
                Picker("", selection: $state.settings.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .labelsHidden()
                .frame(width: 220)
                Text(L10n.t("settings.languageNote"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("English · 简体中文 · 日本語 · 한국어 · Deutsch · Français · Español")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        }
    }

    // MARK: - About

    private var aboutTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                appIcon
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text("iRecord")
                        .font(.system(size: 20, weight: .bold))
                    Text(L10n.t("app.tagline"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    Text(String(format: L10n.t("settings.version"), AppInfo.version))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            )

            section("iRecord") {
                Text(L10n.t("settings.aboutText"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider().opacity(0.5)
                Text(L10n.t("settings.aboutCLI"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("MP4 · MOV · ProRes · GIF")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var appIcon: Image {
        if let image = NSApp.applicationIconImage, image.size.width > 0 {
            return Image(nsImage: image)
        }
        return Image(systemName: "record.circle")
    }

    // MARK: - Building blocks

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .font(.system(size: 12))
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.5)
            content()
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
    }
}

struct SettingRow<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title)
                .font(.system(size: 12))
                .frame(width: 160, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            content
            Spacer(minLength: 0)
        }
    }
}
