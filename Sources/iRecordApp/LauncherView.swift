import iRecordCore
import SwiftUI

struct LauncherView: View {
    @ObservedObject var state: AppState

    private var isActive: Bool { state.isRecording || state.isBusy }
    private var isPaused: Bool { state.recorderState == .paused }
    private var accent: Color { isPaused ? .orange : .red }
    private var interfaceOpacity: Double { state.settings.launcherOpacity }

    var body: some View {
        HStack(spacing: 9) {
            if isActive {
                recordingControls
            } else {
                idleControls
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 252, height: 52)
        .background(Color.clear)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.34), Color.white.opacity(0.08)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
                .opacity(interfaceOpacity)
        )
        .environment(\.colorScheme, .dark)
    }

    private var idleControls: some View {
        HStack(spacing: 6) {
            Button {
                state.actions.startFullScreen?()
            } label: {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 1.0, green: 0.29, blue: 0.25),
                                Color(red: 0.88, green: 0.12, blue: 0.10)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 20, height: 20)
                    .overlay(
                        Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
                    )
                    .shadow(color: .red.opacity(0.45), radius: 4, y: 1)
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .frame(width: 30, height: 30)
            .help(L10n.t("menu.start") + " (\(state.settings.startHotkey.displayString))")
            .disabled(state.isBusy)

            Text(state.elapsedString)
                .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(.white)

            Spacer(minLength: 0)

            launcherIconButton(systemName: "display", help: L10n.t("menu.mode.screen")) {
                state.actions.startFullScreen?()
            }
            launcherIconButton(systemName: "macwindow", help: L10n.t("menu.mode.window")) {
                state.actions.startWindow?()
            }
            launcherIconButton(systemName: "rectangle.dashed", help: L10n.t("menu.mode.region")) {
                state.actions.startRegion?()
            }
            launcherIconButton(systemName: "gearshape.fill", help: L10n.t("menu.settings")) {
                state.actions.openSettings?()
            }
        }
        .opacity(interfaceOpacity)
    }

    private func launcherIconButton(systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.66))
                .frame(width: 22, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .disabled(state.isBusy)
    }

    private var recordingControls: some View {
        HStack(spacing: 9) {
            HStack(spacing: 9) {
                ZStack {
                    Circle()
                        .fill(accent.opacity(0.2))
                        .frame(width: 30, height: 30)
                    if state.isBusy {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Circle()
                            .fill(accent)
                            .frame(width: 9, height: 9)
                    }
                }

                Text(state.elapsedString)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(.white)
            }
            .opacity(interfaceOpacity)

            if state.recordingHasAudio {
                AudioLevelColumn(meter: state.audioMeter)
            }

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                if !state.isBusy {
                    Button {
                        state.actions.pauseResume?()
                    } label: {
                        Image(systemName: isPaused ? "play.fill" : "pause.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Color.white.opacity(0.13)))
                    }
                    .buttonStyle(.plain)
                    .help(isPaused ? L10n.t("hud.resume") : L10n.t("hud.pause"))
                }

                Button {
                    state.actions.stop?()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color.red.opacity(0.85)))
                }
                .buttonStyle(.plain)
                .disabled(state.recorderState == .finishing || state.recorderState == .converting)
                .help(L10n.t("hud.stop") + " (\(state.settings.stopHotkey.displayString))")
            }
            .opacity(interfaceOpacity)
        }
    }
}

private struct AudioLevelColumn: View {
    @ObservedObject var meter: AudioMeter

    private let segmentCount = 5

    var body: some View {
        VStack(spacing: 1) {
            ForEach(0..<segmentCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 0.9, style: .continuous)
                    .fill(isLit(index) ? Color(white: 0.68) : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 0.9, style: .continuous)
                            .strokeBorder(
                                Color(white: 0.55).opacity(isLit(index) ? 0 : 0.55),
                                lineWidth: 0.5
                            )
                    )
                    .frame(width: 8, height: 3.4)
            }
        }
        .animation(.easeOut(duration: 0.12), value: meter.level)
    }

    private var litCount: Int {
        guard meter.level > 0.005 else { return 0 }
        return max(1, min(segmentCount, Int(ceil(Double(meter.level) * Double(segmentCount)))))
    }

    private func isLit(_ index: Int) -> Bool {
        index >= segmentCount - litCount
    }

}
