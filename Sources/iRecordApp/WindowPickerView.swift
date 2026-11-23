import AppKit
import iRecordCore
import SwiftUI

@MainActor
final class WindowPickerModel: ObservableObject {
    @Published var windows: [WindowInfo] = []
    @Published var loading = false
    @Published var errorMessage: String?
    @Published var search = ""
    @Published var selectedID: UInt32?

    private var iconCache: [String: NSImage] = [:]

    var filtered: [WindowInfo] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return windows }
        return windows.filter {
            $0.title.localizedCaseInsensitiveContains(query) ||
            $0.appName.localizedCaseInsensitiveContains(query)
        }
    }

    func load() async {
        loading = true
        errorMessage = nil
        do {
            windows = try await ShareableContentLoader.windows()
        } catch {
            errorMessage = (error as? CaptureError)?.localizedDescription(L10n.current) ?? error.localizedDescription
        }
        loading = false
    }

    func icon(for window: WindowInfo) -> NSImage {
        let key = window.bundleIdentifier ?? window.appName
        if let cached = iconCache[key] { return cached }
        var image: NSImage?
        if let bundle = window.bundleIdentifier,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        }
        let result = image ?? NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil) ?? NSImage()
        iconCache[key] = result
        return result
    }
}

struct WindowPickerView: View {
    @ObservedObject var model: WindowPickerModel
    let onSelect: (WindowInfo) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(L10n.t("window.search"), text: $model.search)
                    .textFieldStyle(.plain)
                Button {
                    Task { await model.load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(L10n.t("window.refresh"))
                .disabled(model.loading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            Group {
                if model.loading && model.windows.isEmpty {
                    VStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(L10n.t("window.loading"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = model.errorMessage {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.orange)
                        Text(L10n.t("permission.screenTitle"))
                            .font(.system(size: 13, weight: .semibold))
                        Text(L10n.t("permission.screenBody"))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 400)
                        HStack(spacing: 8) {
                            Button(L10n.t("permission.openSettings")) {
                                Permissions.openScreenCaptureSettings()
                            }
                            Button(L10n.t("window.refresh")) {
                                Task { await model.load() }
                            }
                        }
                        .controlSize(.small)
                        Text(error)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .frame(maxWidth: 400)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.filtered.isEmpty {
                    Text(L10n.t("window.empty"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(model.filtered) { window in
                                row(window)
                            }
                        }
                        .padding(6)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack(spacing: 8) {
                Text(selectedWindow?.displayTitle ?? "")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button(L10n.t("window.cancel")) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                Button(L10n.t("window.choose")) {
                    if let window = selectedWindow { onSelect(window) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedWindow == nil)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        .frame(width: 520, height: 440)
        .task {
            await model.load()
        }
    }

    private var selectedWindow: WindowInfo? {
        guard let id = model.selectedID else { return nil }
        return model.windows.first { $0.id == id }
    }

    private func row(_ window: WindowInfo) -> some View {
        HStack(spacing: 9) {
            Image(nsImage: model.icon(for: window))
                .resizable()
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(window.title.isEmpty ? window.appName : window.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(window.appName) · \(window.width)×\(window.height)")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if model.selectedID == window.id {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(model.selectedID == window.id ? Color.accentColor.opacity(0.13) : Color.clear)
        )
        .onTapGesture {
            model.selectedID = window.id
        }
        .onTapGesture(count: 2) {
            onSelect(window)
        }
    }
}

@MainActor
final class WindowPickerController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model = WindowPickerModel()
    var onSelect: ((WindowInfo) -> Void)?
    var onCancel: (() -> Void)?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = WindowPickerView(
            model: model,
            onSelect: { [weak self] window in
                DispatchQueue.main.async {
                    self?.close()
                    self?.onSelect?(window)
                }
            },
            onCancel: { [weak self] in
                DispatchQueue.main.async {
                    self?.close()
                    self?.onCancel?()
                }
            }
        )
        let hosting = NSHostingController(rootView: view)
        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = L10n.t("window.title")
        panel.isReleasedWhenClosed = false
        panel.contentViewController = hosting
        panel.setContentSize(NSSize(width: 520, height: 440))
        panel.delegate = self
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: visible.midX - panel.frame.width / 2,
                y: visible.midY - panel.frame.height / 2
            ))
        }
        window = panel
    }

    func close() {
        window?.delegate = nil
        window?.close()
        window = nil
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
