import AppKit
import SwiftUI

struct MenuView: View {
    @EnvironmentObject var controller: AudioProcessController
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            let playing = controller.playing
            if playing.isEmpty {
                emptyState
            } else {
                ForEach(playing) { process in
                    AudioProcessRow(process: process)
                    if process.id != playing.last?.id {
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
                    Text(process.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text(process.isPlaying ? "Playing" : "Idle")
                        .font(.caption)
                        .foregroundStyle(process.isPlaying ? Color.green : .secondary)
                }

                Spacer()

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
                Text(errorHint(error))
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
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
