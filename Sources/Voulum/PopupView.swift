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
}

struct PopupView: View {
    @EnvironmentObject private var engine: AudioEngine
    @EnvironmentObject private var devices: DeviceController
    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var model: PopupModel

    @State private var listHeight: CGFloat = 0
    private let maxListHeight: CGFloat = 470

    var body: some View {
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

            Divider().padding(.horizontal, 12)
            footer
        }
        .frame(width: 380)
        .animation(.snappy(duration: 0.22), value: model.devicesExpanded)
        .animation(.snappy(duration: 0.22), value: model.expandedEQ)
    }

    // MARK: Apps

    private var appsSection: some View {
        let apps = engine.visibleApps
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Apps")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
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
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        VStack(spacing: 2) {
                            ForEach(apps) { app in
                                AppRowView(app: app, focused: model.focusedKey == app.key,
                                           expandedEQ: $model.expandedEQ)
                                    .id(app.key)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                        .background(GeometryReader { geo in
                            Color.clear
                                .onAppear { listHeight = geo.size.height }
                                .onChange(of: geo.size.height) { _, h in listHeight = h }
                        })
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(height: min(max(listHeight, 60), maxListHeight))
                    .onChange(of: model.focusedKey) { _, key in
                        guard let key else { return }
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(key, anchor: .center) }
                    }
                }
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
                .symbolEffect(.pulse, options: .repeating)
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

// MARK: - Output card

/// The current output at a glance, with its volume. Click to see every device.
struct OutputCard: View {
    @EnvironmentObject private var devices: DeviceController
    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var model: PopupModel

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
                        .background(Circle().fill(Color.accentColor.gradient))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(device?.name ?? "No output device")
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
            .help(model.devicesExpanded ? "Hide devices" : "Switch output or input device")

            if let device {
                if level.adjustable {
                    HStack(spacing: 6) {
                        IconButton(systemName: level.muted ? "speaker.slash.fill" : "speaker.fill",
                                   help: level.muted ? "Unmute output" : "Mute output",
                                   active: level.muted, tint: .red, size: 22) {
                            devices.toggleMute(device)
                        }
                        VolumeSlider(value: Binding(get: { level.volume },
                                                    set: { devices.setVolume($0, for: device) }),
                                     muted: level.muted, step: prefs.volumeStep.fraction)
                        Text(level.muted ? "Muted" : level.volume.percentLabel)
                            .font(.system(.caption, design: .rounded).weight(.semibold).monospacedDigit())
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
        }
    }

    private var subtitle: String {
        var parts = ["Output"]
        if let device = devices.defaultOutput { parts.append(device.transportLabel) }
        if let input = devices.defaultInput { parts.append("Mic: \(input.name)") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Device list

struct DeviceList: View {
    @EnvironmentObject private var devices: DeviceController
    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var model: PopupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("", selection: $model.showingInputs) {
                Text("Output").tag(false)
                Text("Input").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 4)
            .padding(.bottom, 2)

            let list = model.showingInputs ? devices.visibleInputs : devices.visibleOutputs
            ForEach(list) { device in
                DeviceRowView(device: device, input: model.showingInputs)
            }
            if list.isEmpty {
                Text(model.showingInputs ? "No microphones" : "No outputs")
                    .font(.caption).foregroundStyle(.secondary).padding(8)
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
}

struct DeviceRowView: View {
    let device: AudioDevice
    let input: Bool
    @EnvironmentObject private var devices: DeviceController
    @EnvironmentObject private var prefs: Preferences
    @State private var hovering = false

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
                        .foregroundStyle(isDefault ? .white : .primary)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(isDefault ? AnyShapeStyle(Color.accentColor.gradient)
                                                            : AnyShapeStyle(Color.primary.opacity(0.08))))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(device.name).font(.callout).lineLimit(1)
                        Text(isDefault ? "In use · \(device.transportLabel)" : device.transportLabel)
                            .font(.caption2)
                            .foregroundStyle(isDefault ? Color.accentColor : .secondary)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isDefault ? "Current \(input ? "input" : "output")" : "Use \(device.name)")

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
