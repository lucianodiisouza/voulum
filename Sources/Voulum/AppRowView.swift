import AppKit
import SwiftUI

struct AppRowView: View {
    let app: AudioApp
    var focused = false
    @Binding var expandedEQ: String?

    @EnvironmentObject private var engine: AudioEngine
    @EnvironmentObject private var devices: DeviceController
    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var meters: LevelMeters

    @State private var hovering = false
    @State private var showingRoutes = false

    private var settings: AppAudioSettings { engine.settings(app.key) }
    private var eqOpen: Bool { expandedEQ == app.key }

    private var level: Binding<Float> {
        Binding(get: { settings.level }, set: { engine.setLevel($0, for: app) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button { app.bringToFront() } label: {
                    AppIconWithLevel(icon: app.icon, level: meters.levels[app.key] ?? 0,
                                     active: app.isRunning, playing: engine.isPlayingNow(app),
                                     clipping: meters.hot.contains(app.key))
                }
                .buttonStyle(.plain)
                .help(app.isRunning ? String(localized: "Show \(app.name)") : String(localized: "Open \(app.name)"))

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        MarqueeText(text: title, weight: .medium)
                        if prefs.isPinned(app.key) {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(.tertiary)
                                .help("Pinned")
                        }
                    }
                    subtitleView
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if engine.canControlTransport(app) { transport }

                Text(settings.muted ? String(localized: "Muted") : settings.level.percentLabel)
                    .font(.system(.caption, design: .rounded).weight(.semibold).monospacedDigit())
                    .foregroundStyle(settings.level > 1 && !settings.muted ? Color.orange : .secondary)
                    .frame(width: 42, alignment: .trailing)
                    .onTapGesture(count: 2) { engine.setLevel(1, for: app) }
                    .help("Double-click to reset to 100%")
            }

            HStack(spacing: 4) {
                IconButton(systemName: muteSymbol, help: settings.muted ? "Unmute" : "Mute",
                           active: settings.muted, tint: .red) {
                    engine.toggleMute(app)
                }
                VolumeSlider(value: level, maxValue: AppAudioSettings.maxLevel, muted: settings.muted,
                             step: prefs.volumeStep.fraction)
                    .padding(.horizontal, 4)
                IconButton(systemName: routeSymbol, help: "Choose where \(app.name) plays",
                           active: settings.route != .system) {
                    showingRoutes.toggle()
                }
                .popover(isPresented: $showingRoutes, arrowEdge: .bottom) {
                    RoutePicker(app: app)
                        .environmentObject(engine)
                        .environmentObject(devices)
                }
                IconButton(systemName: "slider.vertical.3", help: "Equalizer",
                           active: settings.eq.enabled && !settings.eq.isFlat) {
                    withAnimation(.snappy(duration: 0.22)) { expandedEQ = eqOpen ? nil : app.key }
                }
                moreMenu
            }

            if let message = problem {
                problemView(message)
            }

            if eqOpen {
                EQPanel(app: app)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(RowBackground(highlighted: focused || hovering || eqOpen))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.accentColor.opacity(focused ? 0.55 : 0), lineWidth: 1.5)
        )
        .onHover { hovering = $0 }
        .contextMenu { moreMenuItems }
    }

    // MARK: Text

    private var track: NowPlaying? { engine.nowPlaying[app.key] }
    private var title: String { track?.title ?? app.name }

    @ViewBuilder private var subtitleView: some View {
        let (text, color) = subtitle
        MarqueeText(text: text, font: .caption)
            .foregroundStyle(color)
    }

    private var subtitle: (String, Color) {
        if !app.isRunning { return (String(localized: "Not running · settings saved"), .secondary) }
        if engine.isRouteFallingBack(app) {
            return (String(localized: "Chosen output unavailable · using \(devices.defaultOutput?.name ?? String(localized: "system output"))"), .orange)
        }
        var parts: [String] = []
        if let track {
            parts.append(track.subtitle.isEmpty ? app.name : "\(track.subtitle) · \(app.name)")
        } else if engine.pausedAt[app.key] != nil || (!app.isPlaying && prefs.isPinned(app.key)) {
            parts.append(engine.pausedAt[app.key] != nil ? String(localized: "Paused") : String(localized: "Idle"))
        }
        let uids = settings.route.deviceUIDs
        if uids.count == 1, let device = devices.output(uid: uids[0]) {
            parts.append("→ \(device.name)")
        } else if uids.count > 1 {
            parts.append(String(localized: "→ \(uids.count) outputs"))
        }
        if settings.eq.enabled && !settings.eq.isFlat {
            parts.append(String(localized: "EQ: \(prefs.preset(id: settings.eq.presetID)?.name ?? String(localized: "Custom"))"))
        }
        if parts.isEmpty { return (String(localized: "Playing"), .green) }
        return (parts.joined(separator: " · "), .secondary)
    }

    private var muteSymbol: String {
        if settings.muted || settings.level == 0 { return "speaker.slash.fill" }
        if settings.level < 0.34 { return "speaker.wave.1.fill" }
        if settings.level < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    private var routeSymbol: String {
        let uids = settings.route.deviceUIDs
        if uids.count > 1 { return "square.stack.3d.up.fill" }
        if let uid = uids.first, let device = devices.output(uid: uid) { return device.symbol }
        return "arrow.triangle.branch"
    }

    // MARK: Transport

    private var transport: some View {
        let playing = engine.isPlayingNow(app)
        return HStack(spacing: 0) {
            if engine.canSkipTracks(app) {
                IconButton(systemName: "backward.fill", help: "Previous", size: 22) { engine.skip(.previous, app) }
            }
            IconButton(systemName: playing ? "pause.fill" : "play.fill",
                       help: playing ? String(localized: "Pause \(app.name)") : String(localized: "Play \(app.name)"), size: 24) {
                engine.togglePlayPause(app)
            }
            if engine.canSkipTracks(app) {
                IconButton(systemName: "forward.fill", help: "Next", size: 22) { engine.skip(.next, app) }
            }
        }
    }

    // MARK: Menu

    private var moreMenu: some View {
        Menu {
            moreMenuItems
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
    }

    @ViewBuilder private var moreMenuItems: some View {
        Button(app.isRunning ? String(localized: "Show \(app.name)") : String(localized: "Open \(app.name)")) { app.bringToFront() }
        Divider()
        if prefs.isPinned(app.key) {
            Button("Unpin") { engine.setPinned(app, false) }
        } else {
            Button("Keep in List When Quiet") { engine.setPinned(app, true) }
        }
        Button("Reset Volume, EQ & Output") { engine.reset(app) }
            .disabled(settings.isDefault)
        Divider()
        Button("Ignore \(app.name)…") { engine.setIgnored(app, true) }
    }

    // MARK: Problems

    private var problem: String? {
        if let error = engine.tapErrors[app.key] {
            return engine.audioPermissionGranted
                ? String(localized: "Couldn't take over this app's audio (\(error)).")
                : String(localized: "Voulum needs permission to adjust app audio.")
        }
        return engine.transportErrors[app.key]
    }

    private func problemView(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if engine.tapErrors[app.key] != nil {
                Button("Open Settings") { Permissions.openAudioCaptureSettings() }
                    .controlSize(.small)
            }
        }
        .font(.caption)
        .padding(.leading, 2)
    }
}

/// "Where should this app play?" — the system output, or any mix of devices.
struct RoutePicker: View {
    let app: AudioApp
    @EnvironmentObject private var engine: AudioEngine
    @EnvironmentObject private var devices: DeviceController

    private var route: OutputRoute { engine.settings(app.key).route }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Play \(app.name) on")
                .font(.headline)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)

            row(symbol: "arrow.triangle.branch", title: String(localized: "System Output"),
                detail: devices.defaultOutput.map { String(localized: "Now: \($0.name)") },
                checked: route == .system, radio: true) {
                engine.setRoute(.system, for: app)
            }
            Divider().padding(.vertical, 4)
            ForEach(devices.visibleOutputs) { device in
                row(symbol: device.symbol, title: device.name, detail: device.transportLabel,
                    checked: route.deviceUIDs.contains(device.uid), radio: false) {
                    toggle(device)
                }
            }
            // Chosen devices that are currently disconnected stay listed, so the
            // choice is visible and reversible.
            ForEach(route.deviceUIDs.filter { devices.output(uid: $0) == nil }, id: \.self) { uid in
                row(symbol: "bolt.horizontal.circle", title: String(localized: "Disconnected device"),
                    detail: String(localized: "Returns here when it reconnects"), checked: true, radio: false) {
                    var uids = route.deviceUIDs
                    uids.removeAll { $0 == uid }
                    engine.setRoute(uids.isEmpty ? .system : .devices(uids), for: app)
                }
            }
            Text("Pick more than one device to play on all of them.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 6)
        }
        .padding(8)
        .frame(width: 280)
    }

    private func toggle(_ device: AudioDevice) {
        var uids = route.deviceUIDs
        if let i = uids.firstIndex(of: device.uid) { uids.remove(at: i) } else { uids.append(device.uid) }
        engine.setRoute(uids.isEmpty ? .system : .devices(uids), for: app)
    }

    private func row(symbol: String, title: String, detail: String?, checked: Bool, radio: Bool,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: radio ? (checked ? "largecircle.fill.circle" : "circle")
                                        : (checked ? "checkmark.square.fill" : "square"))
                    .foregroundStyle(checked ? Color.accentColor : .secondary)
                Image(systemName: symbol).frame(width: 18)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).lineLimit(1)
                    if let detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowButtonStyle())
    }
}

struct HoverRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverRow(configuration: configuration)
    }

    private struct HoverRow: View {
        let configuration: Configuration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : (hovering ? 0.07 : 0))))
                .onHover { hovering = $0 }
        }
    }
}

enum Permissions {
    /// System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording
    /// (the "audio capture" pane process taps fall under).
    static func openAudioCaptureSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
        ]
        for string in urls {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
    }
}
