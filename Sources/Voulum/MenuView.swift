import AppKit
import SwiftUI

struct MenuView: View {
    @EnvironmentObject var controller: AudioProcessController
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            let rows = controller.visible
            if rows.isEmpty {
                emptyState
            } else {
                ForEach(rows) { process in
                    AudioProcessRow(process: process)
                    if process.id != rows.last?.id {
                        Divider().padding(.horizontal, 12)
                    }
                }
            }

            Divider()
            footer
        }
        .frame(width: 320)
        // Refresh on open, poll while open, stop when the menu closes.
        .onAppear { controller.beginLiveUpdates() }
        .onDisappear { controller.endLiveUpdates() }
    }

    private var header: some View {
        HStack {
            Text("Playing Audio")
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "speaker.slash")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text("Nothing is playing")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Pause others when I press play", isOn: $controller.pauseOthersOnPlay)
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .help("Starting one app pauses every other app Voulum can control.")

            Toggle("Launch at login", isOn: launchAtLoginBinding)
                .toggleStyle(.checkbox)
                .controlSize(.small)

            if !controller.audioPermissionGranted {
                Label("First volume change asks for audio permission.",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Quit Voulum") { NSApp.terminate(nil) }
                    .buttonStyle(.borderless)
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// Reconciles the toggle with the system's actual login-item state — if the
    /// register/unregister call fails, the switch snaps back to reality.
    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { launchAtLogin = LoginItem.setEnabled($0) }
        )
    }
}

struct AudioProcessRow: View {
    let process: AudioProcess
    @EnvironmentObject var controller: AudioProcessController

    private var isMuted: Bool { controller.isMuted(process) }
    private var volume: Binding<Double> {
        Binding(
            // While muted, show the slider parked at 0 rather than the stored
            // level, so the thumb matches the audible state. Moving it un-mutes
            // (setVolume clears mute for any value > 0).
            get: { isMuted ? 0 : Double(controller.volume(for: process)) },
            set: { controller.setVolume(Float($0), for: process) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                appIcon

                VStack(alignment: .leading, spacing: 2) {
                    if let track = controller.nowPlaying(for: process) {
                        // Rich metadata from a scriptable media app: show the
                        // track and artist, with the app name as the quiet line.
                        MarqueeText(text: track.title, weight: .medium)
                        MarqueeText(text: track.subtitle.isEmpty ? process.name : "\(track.subtitle) · \(process.name)",
                                    font: .caption)
                            .foregroundStyle(.secondary)
                    } else {
                        MarqueeText(text: process.name, weight: .medium)
                        Text(statusLabel)
                            .font(.caption)
                            .foregroundStyle(controller.isPlayingNow(process) ? Color.green : .secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if controller.canControlTransport(process) {
                    transportControls
                }

                Button {
                    process.activate()
                } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.borderless)
                .help("Bring \(process.name) to front")
            }

            HStack(spacing: 8) {
                Button {
                    controller.toggleMute(process)
                } label: {
                    Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.fill")
                        .foregroundStyle(isMuted ? Color.red : .primary)
                        .frame(width: 16)
                }
                .buttonStyle(.borderless)
                .help(isMuted ? "Unmute" : "Mute")

                Slider(value: volume, in: 0...Double(AudioProcessController.maxGain))
                    .controlSize(.small)

                Text(percentLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
            }

            if let error = controller.tapErrors[process.id] {
                hint(errorHint(error))
            }
            if let hintText = controller.transportErrors[process.id] {
                hint(hintText)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.red)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// "Playing" / "Paused" / "Idle". Paused is only ever something *we* did —
    /// an app the user paused elsewhere simply stops being listed.
    private var statusLabel: String {
        if controller.isPlayingNow(process) { return "Playing" }
        return controller.pausedAt[process.id] != nil ? "Paused" : "Idle"
    }

    private var percentLabel: String {
        if isMuted { return "muted" }
        return "\(Int((controller.volume(for: process) * 100).rounded()))%"
    }

    /// Turn a raw Core Audio failure into something actionable — the common one
    /// is the audio-recording permission not being granted yet.
    private func errorHint(_ raw: String) -> String {
        "Couldn't tap audio. Grant Voulum permission in System Settings ▸ Privacy & Security ▸ Microphone, then retry."
    }

    /// Previous / play-pause / next for any app we can script. Skip buttons only
    /// appear where they mean something — a browser can be paused and resumed,
    /// but has no notion of a next track.
    @ViewBuilder private var transportControls: some View {
        let isPlaying = controller.isPlayingNow(process)
        let canSkip = controller.canSkipTracks(process)
        HStack(spacing: 8) {
            if canSkip {
                Button {
                    controller.skip(.previous, to: process)
                } label: {
                    Image(systemName: "backward.fill")
                }
                .help("Previous track")
            }

            Button {
                controller.togglePlayPause(process)
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
            }
            .help(isPlaying ? "Pause \(process.name)" : "Play \(process.name)")

            if canSkip {
                Button {
                    controller.skip(.next, to: process)
                } label: {
                    Image(systemName: "forward.fill")
                }
                .help("Next track")
            }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    @ViewBuilder private var appIcon: some View {
        if let icon = process.icon {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 28, height: 28)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: 22))
                .frame(width: 28, height: 28)
                .foregroundStyle(.secondary)
        }
    }
}
