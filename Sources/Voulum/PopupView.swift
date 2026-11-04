import AppKit
import SwiftUI

/// UI state for the popup that outlives a single open/close.
@MainActor
final class PopupModel: ObservableObject {
    static let shared = PopupModel()

    @Published var focusedKey: String?
    @Published var expandedEQ: String?
    @Published var devicesExpanded = false
    @Published var showingInputs = false
    /// The tallest the popup may be on its screen, set as it opens.
    @Published var maxHeight: CGFloat = 10_000
    /// The popup is open. Its panel is only ordered out on close, so the
    /// views stay alive and use this to stop animating.
    @Published var isOpen = false
}

struct PopupView: View {
    @EnvironmentObject private var engine: AudioEngine
    @EnvironmentObject private var devices: DeviceController
    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var model: PopupModel

    @State private var contentHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0
    /// Past this the popup scrolls even on a tall screen.
    private let maxContentHeight: CGFloat = 760

    /// Everything above the footer scrolls as one: the output, the mic, the
    /// device list and the apps. It's as tall as it needs, up to what the
    /// screen leaves; the footer always stays in view.
    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    content
                        .background(GeometryReader { geo in
                            Color.clear
                                .onAppear { contentHeight = geo.size.height }
                                .onChange(of: geo.size.height) { _, h in contentHeight = h }
                        })
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(max(contentHeight, 1), maxContentHeight,
                                   max(160, model.maxHeight - footerHeight - 1)))
                .onChange(of: model.focusedKey) { _, key in
                    guard let key else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(key, anchor: .center) }
                }
            }

            Divider().padding(.horizontal, 12)
            footer
                .background(GeometryReader { geo in
                    Color.clear
                        .onAppear { footerHeight = geo.size.height }
                        .onChange(of: geo.size.height) { _, h in footerHeight = h }
                })
        }
        .frame(width: 380)
        .environment(\.deskStyle, prefs.popupStyle.effective == .desk)
        .environment(\.onScreen, model.isOpen)
        // Cream silkscreen instead of white; secondary text follows it.
        .foregroundStyle(prefs.popupStyle.effective == .desk ? AnyShapeStyle(Color.deskCream) : AnyShapeStyle(.primary))
        .animation(.snappy(duration: 0.22), value: model.devicesExpanded)
    }

    private var content: some View {
        VStack(spacing: 0) {
            OutputCard()
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, model.devicesExpanded ? 6 : 10)

            if model.devicesExpanded {
                DeviceList()
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Divider().padding(.horizontal, 12)

            appsSection
        }
    }

    // MARK: Apps

    private var appsSection: some View {
        let apps = engine.visibleApps
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                if prefs.popupStyle.effective == .desk {
                    // Silkscreen, like the labels printed on a desk.
                    Text("Apps")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .textCase(.uppercase)
                        .tracking(1.6)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Apps")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                if !apps.isEmpty {
                    Text("\(apps.count)")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)

            if apps.isEmpty {
                emptyState
            } else {
                VStack(spacing: 2) {
                    ForEach(apps) { app in
                        AppRowView(app: app, focused: model.focusedKey == app.key,
                                   expandedEQ: $model.expandedEQ)
                            .id(app.key)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }

            if !engine.audioPermissionGranted && !apps.isEmpty {
                Label("The first time you change an app, macOS asks to let Voulum handle its audio. Choose Allow.",
                      systemImage: "hand.raised.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
                .symbolEffect(.pulse, options: .repeating, isActive: model.isOpen)
            Text("Nothing is playing")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            Text("Apps appear here when they play sound.\nPin one from its ⋯ menu to keep it here.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 0) {
            controls
            Divider().padding(.horizontal, 16)
            UpdateRow(updater: AppDelegate.updater)
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                SettingsWindowController.shared.show()
            } label: {
                Label("Settings…", systemImage: "gearshape")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(",", modifiers: .command)

            Spacer()

            Text("↑↓ select · ←→ volume · M mute")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .help("E opens the equalizer, Space plays/pauses, Return shows the app, Esc closes")

            Spacer()

            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .keyboardShortcut("q", modifiers: .command)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }
}

/// The popup's last line: the version, and the update check one click away
/// instead of two windows deep.
private struct UpdateRow: View {
    @ObservedObject var updater: Updater

    var body: some View {
        HStack {
            Text(verbatim: "Voulum \(Updater.version)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer()
            if updater.isConfigured {
                Button {
                    updater.checkForUpdates()
                } label: {
                    Label("Check for Updates…", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderless)
                .disabled(!updater.canCheckForUpdates)
            }
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Output card

/// The current output at a glance, with its volume. Click to see every device.
struct OutputCard: View {
    @EnvironmentObject private var devices: DeviceController
    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var model: PopupModel
    @EnvironmentObject private var meters: LevelMeters
    @Environment(\.deskStyle) private var desk

    var body: some View {
        let device = devices.defaultOutput
        let level = devices.defaultOutputLevel
        VStack(spacing: 8) {
            Button {
                model.devicesExpanded.toggle()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: device?.symbol ?? "speaker.wave.2.fill")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(desk ? AnyShapeStyle(Color(red: 0.25, green: 0.23, blue: 0.2).gradient) : AnyShapeStyle(Color.accentColor.gradient)))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(device?.name ?? String(localized: "No output device"))
                            .font(.headline)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(model.devicesExpanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(model.devicesExpanded ? String(localized: "Hide devices") : String(localized: "Switch output or input device"))

            if let device {
                if level.adjustable {
                    HStack(spacing: 6) {
                        if desk {
                            DeskKey(label: "M",
                                    help: level.muted ? String(localized: "Unmute output") : String(localized: "Mute output"),
                                    active: level.muted) {
                                devices.toggleMute(device)
                            }
                        } else {
                            IconButton(systemName: level.muted ? "speaker.slash.fill" : "speaker.fill",
                                       help: level.muted ? String(localized: "Unmute output") : String(localized: "Mute output"),
                                       active: level.muted, tint: .red, size: 22) {
                                devices.toggleMute(device)
                            }
                        }
                        if desk {
                            // The master: everything that reaches this output.
                            VStack(spacing: 5) {
                                let stereo = meters.stereo[LevelMeters.masterKey] ?? StereoLevel()
                                LEDMeter(left: stereo.left, right: stereo.right,
                                         clipping: meters.hot.contains(LevelMeters.masterKey))
                                VolumeSlider(value: Binding(get: { level.volume },
                                                            set: { devices.setVolume($0, for: device) }),
                                             muted: level.muted, step: prefs.volumeStep.fraction)
                            }
                        } else {
                            VolumeSlider(value: Binding(get: { level.volume },
                                                        set: { devices.setVolume($0, for: device) }),
                                         muted: level.muted, step: prefs.volumeStep.fraction)
                        }
                        Text(level.muted ? String(localized: "Muted") : level.volume.percentLabel)
                            .font(.system(.caption, design: desk ? .monospaced : .rounded).weight(.semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .trailing)
                    }
                } else {
                    Text("This device sets its own volume.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if desk, let mic = devices.defaultInput {
                MicStrip(device: mic)
                    .padding(.top, 4)
            }
        }
    }

    private var subtitle: String {
        var parts = [String(localized: "Output")]
        if let device = devices.defaultOutput { parts.append(device.transportLabel) }
        if let input = devices.defaultInput { parts.append(String(localized: "Mic: \(input.name)")) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Desk tabs

/// The desk style's Output / Input switch: two silkscreened keys, the chosen
/// one lit amber.
struct DeskTab: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .textCase(.uppercase)
                .tracking(1.4)
                .foregroundStyle(selected ? Color.black.opacity(0.8) : Color.deskCream.opacity(hovering ? 0.85 : 0.55))
                .padding(.horizontal, 10)
                .frame(height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(selected ? AnyShapeStyle(Color.deskAmber.gradient)
                                       : AnyShapeStyle(LinearGradient(colors: [Color(white: hovering ? 0.3 : 0.26), Color(white: 0.15)],
                                                                      startPoint: .top, endPoint: .bottom)))
                        .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(Color.black.opacity(0.6), lineWidth: 0.75))
                        .shadow(color: selected ? Color.deskAmber.opacity(0.5) : .black.opacity(0.6),
                                radius: selected ? 4 : 1.5, y: selected ? 0 : 1.5)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Mic strip

/// The desk style's mic channel: what the current microphone hears, its
/// input volume and its mute key.
private struct MicStrip: View {
    let device: AudioDevice
    @EnvironmentObject private var devices: DeviceController
    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var meters: LevelMeters

    var body: some View {
        let level = devices.inputLevels[device.id] ?? DeviceLevel()
        VStack(alignment: .leading, spacing: 5) {
            Text("Mic · \(device.name)")
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .textCase(.uppercase)
                .tracking(1.4)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 6) {
                DeskKey(label: "M",
                        help: level.muted ? String(localized: "Unmute microphone") : String(localized: "Mute microphone"),
                        active: level.muted) {
                    devices.toggleMute(device, input: true)
                }
                VStack(spacing: 5) {
                    let stereo = level.muted ? StereoLevel() : meters.stereo[LevelMeters.micKey] ?? StereoLevel()
                    LEDMeter(left: stereo.left, right: stereo.right, clipping: meters.hot.contains(LevelMeters.micKey))
                    if level.adjustable {
                        VolumeSlider(value: Binding(get: { level.volume },
                                                    set: { devices.setVolume($0, for: device, input: true) }),
                                     muted: level.muted, step: prefs.volumeStep.fraction)
                    }
                }
                Text(level.muted ? String(localized: "Muted") : level.adjustable ? level.volume.percentLabel : "")
                    .font(.system(.caption, design: .monospaced).weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)
            }
            if !MicMeter.accessGranted && !MicMeter.accessUndecided {
                Button("Allow microphone access to see its level") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
    }
}

// MARK: - Device list

struct DeviceList: View {
    @EnvironmentObject private var devices: DeviceController
    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var model: PopupModel
    @Environment(\.deskStyle) private var desk

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if desk {
                    HStack(spacing: 6) {
                        DeskTab(title: String(localized: "Output"), selected: !model.showingInputs) { model.showingInputs = false }
                        DeskTab(title: String(localized: "Input"), selected: model.showingInputs) { model.showingInputs = true }
                        Spacer()
                    }
                } else {
                    Picker("", selection: $model.showingInputs) {
                        Text("Output").tag(false)
                        Text("Input").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 2)

            // Both lists stay laid out, one hidden: the panel keeps the taller
            // one's height, so switching never resizes the popup window.
            ZStack(alignment: .top) {
                devicesList(input: false)
                    .opacity(model.showingInputs ? 0 : 1)
                    .allowsHitTesting(!model.showingInputs)
                    .accessibilityHidden(model.showingInputs)
                devicesList(input: true)
                    .opacity(model.showingInputs ? 1 : 0)
                    .allowsHitTesting(model.showingInputs)
                    .accessibilityHidden(!model.showingInputs)
            }

            HStack {
                Spacer()
                Button("Arrange & Hide Devices…") { SettingsWindowController.shared.show(tab: .devices) }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            .padding(.horizontal, 6)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    private func devicesList(input: Bool) -> some View {
        let list = input ? devices.visibleInputs : devices.visibleOutputs
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(list) { device in
                DeviceRowView(device: device, input: input)
            }
            if list.isEmpty {
                Text(input ? String(localized: "No microphones") : String(localized: "No outputs"))
                    .font(.caption).foregroundStyle(.secondary).padding(8)
            }
        }
    }
}

struct DeviceRowView: View {
    let device: AudioDevice
    let input: Bool
    @EnvironmentObject private var devices: DeviceController
    @EnvironmentObject private var prefs: Preferences
    @Environment(\.deskStyle) private var desk
    @State private var hovering = false

    /// What marks the device in use: the system accent, or the desk's amber.
    private var mark: Color { desk ? .deskAmber : .accentColor }

    private var isDefault: Bool {
        input ? devices.defaultInputID == device.id : devices.defaultOutputID == device.id
    }
    private var level: DeviceLevel {
        (input ? devices.inputLevels : devices.outputLevels)[device.id] ?? DeviceLevel()
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                devices.setDefault(device)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: device.symbol)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isDefault ? (desk ? Color.black.opacity(0.8) : .white) : .primary)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(isDefault ? AnyShapeStyle(mark.gradient)
                                                            : AnyShapeStyle(Color.primary.opacity(0.08))))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(device.name).font(.callout).lineLimit(1)
                        Text(isDefault ? String(localized: "In use · \(device.transportLabel)") : device.transportLabel)
                            .font(.caption2)
                            .foregroundStyle(isDefault ? mark : .secondary)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isDefault ? (input ? String(localized: "Current input") : String(localized: "Current output")) : String(localized: "Use \(device.name)"))

            if level.adjustable {
                VolumeSlider(value: Binding(get: { level.volume },
                                            set: { devices.setVolume($0, for: device, input: input) }),
                             muted: level.muted, step: prefs.volumeStep.fraction)
                    .frame(width: 110)
                Text(level.muted ? "–" : level.volume.percentLabel)
                    .font(.system(.caption2, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(hovering ? 0.06 : 0)))
        .onHover { hovering = $0 }
    }
}
