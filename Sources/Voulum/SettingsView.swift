import AppKit
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, apps, devices, shortcuts, equalizer, about
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .apps: return "square.grid.2x2"
        case .devices: return "hifispeaker.2"
        case .shortcuts: return "keyboard"
        case .equalizer: return "slider.vertical.3"
        case .about: return "info.circle"
        }
    }
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private let selection = SettingsSelection()

    func show(tab: SettingsTab? = nil) {
        if let tab { selection.tab = tab }
        StatusItemController.shared.close()
        if window == nil {
            let root = SettingsView()
                .environmentObject(selection)
                .environmentObject(Preferences.shared)
                .environmentObject(AudioEngine.shared)
                .environmentObject(DeviceController.shared)
                .environmentObject(AppDelegate.updater)
            let host = NSHostingController(rootView: root)
            let window = NSWindow(contentViewController: host)
            window.title = "Voulum Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.setContentSize(NSSize(width: 620, height: 500))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        // A menu-bar app has no Dock icon; show one while Settings is open so
        // the window can be found with ⌘-Tab.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        Preferences.shared.saveNow()
        NSApp.setActivationPolicy(.accessory)
    }
}

final class SettingsSelection: ObservableObject {
    @Published var tab: SettingsTab = .general
}

struct SettingsView: View {
    @EnvironmentObject private var selection: SettingsSelection

    var body: some View {
        TabView(selection: $selection.tab) {
            GeneralSettings().tabItem { Label("General", systemImage: SettingsTab.general.symbol) }.tag(SettingsTab.general)
            AppsSettings().tabItem { Label("Apps", systemImage: SettingsTab.apps.symbol) }.tag(SettingsTab.apps)
            DevicesSettings().tabItem { Label("Devices", systemImage: SettingsTab.devices.symbol) }.tag(SettingsTab.devices)
            ShortcutsSettings().tabItem { Label("Shortcuts", systemImage: SettingsTab.shortcuts.symbol) }.tag(SettingsTab.shortcuts)
            EqualizerSettings().tabItem { Label("Equalizer", systemImage: SettingsTab.equalizer.symbol) }.tag(SettingsTab.equalizer)
            AboutSettings().tabItem { Label("About", systemImage: SettingsTab.about.symbol) }.tag(SettingsTab.about)
        }
        .padding(20)
        .frame(width: 620, height: 500)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var updater: Updater
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        Form {
            Section {
                Toggle("Open Voulum when you log in", isOn: Binding(
                    get: { launchAtLogin }, set: { launchAtLogin = LoginItem.setEnabled($0) }))
            }
            Section("Menu bar icon") {
                Picker("Style", selection: $prefs.iconStyle) {
                    ForEach(MenuBarIconStyle.allCases) { style in
                        Label {
                            Text(style.title)
                        } icon: {
                            Image(systemName: StatusItemController.symbol(style: style, device: nil, volume: 0.6, muted: false))
                        }
                        .tag(style)
                    }
                }
                .pickerStyle(.radioGroup)
                Text("Adaptive shows the kind of device you're listening on. Every style turns into a slashed speaker when the output is muted.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Behaviour") {
                Toggle("Keep pinned apps in the list when they're quiet", isOn: $prefs.showInactivePinned)
                Toggle("Pressing play in Voulum pauses other apps", isOn: $prefs.pauseOthersOnPlay)
                Picker("Volume step", selection: $prefs.volumeStep) {
                    ForEach(VolumeStep.allCases) { Text($0.title).tag($0) }
                }
                Text("Used by the arrow keys, the scroll wheel and the volume shortcuts.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if updater.isConfigured {
                Section("Updates") {
                    Toggle("Check for updates automatically", isOn: Binding(
                        get: { updater.automaticallyChecks }, set: { updater.automaticallyChecks = $0 }))
                    Button("Check for Updates Now") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: prefs.iconStyle) { _, _ in StatusItemController.shared.updateIcon() }
    }
}

// MARK: - Apps

private struct AppsSettings: View {
    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var engine: AudioEngine

    var body: some View {
        Form {
            Section {
                if prefs.pinned.isEmpty {
                    Text("Pin an app from its ⋯ menu in the popup to keep it listed — handy for setting its volume before it starts playing.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(prefs.pinned) { app in
                    knownRow(app) {
                        Button("Unpin") { prefs.setPinned(app, false) }
                    }
                }
            } header: { Text("Pinned apps") }

            Section {
                if prefs.ignored.isEmpty {
                    Text("Ignored apps are left completely alone — Voulum won't list them or touch their audio.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(prefs.ignored) { app in
                    knownRow(app) {
                        Button("Stop Ignoring") {
                            prefs.setIgnored(app, false)
                            engine.reload()
                        }
                    }
                }
            } header: { Text("Ignored apps") }

            Section {
                let keys = prefs.apps.keys.sorted()
                if keys.isEmpty {
                    Text("Nothing yet. Voulum remembers each app's volume, EQ and output once you change them.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(keys, id: \.self) { key in
                    let s = prefs.settings(for: key)
                    HStack {
                        Text(displayName(key))
                        Spacer()
                        Text(summary(s)).foregroundStyle(.secondary).font(.caption)
                        Button("Forget") {
                            if let app = engine.app(key: key) { engine.reset(app) } else { prefs.apps.removeValue(forKey: key) }
                        }
                    }
                }
            } header: { Text("Remembered settings") }
        }
        .formStyle(.grouped)
    }

    private func displayName(_ key: String) -> String {
        engine.app(key: key)?.name
            ?? prefs.pinned.first { $0.key == key }?.name
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: key).map {
                FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "")
            }
            ?? key
    }

    private func summary(_ s: AppAudioSettings) -> String {
        var parts: [String] = [s.muted ? "Muted" : s.level.percentLabel]
        if s.eq.enabled && !s.eq.isFlat { parts.append("EQ") }
        if s.route != .system { parts.append("Custom output") }
        return parts.joined(separator: " · ")
    }

    private func knownRow<Trailing: View>(_ app: KnownApp, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack {
            Image(nsImage: app.bundlePath.map { NSWorkspace.shared.icon(forFile: $0) }
                  ?? NSWorkspace.shared.icon(for: .application))
                .resizable().frame(width: 20, height: 20)
            Text(app.name)
            Spacer()
            trailing()
        }
    }
}

// MARK: - Devices

private struct DevicesSettings: View {
    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var devices: DeviceController

    var body: some View {
        Form {
            Section {
                Toggle("Switch to a higher-ranked output as soon as it connects", isOn: $prefs.autoSwitchToPreferred)
                List {
                    ForEach(rankedOutputs, id: \.uid) { device in
                        deviceRow(device, rank: (rankedOutputs.firstIndex(of: device) ?? 0) + 1)
                    }
                    .onMove { from, to in
                        var uids = rankedOutputs.map(\.uid)
                        uids.move(fromOffsets: from, toOffset: to)
                        // Keep ranks of devices that aren't connected right now.
                        prefs.devicePriority = uids + prefs.devicePriority.filter { !uids.contains($0) }
                        devices.refresh()
                    }
                }
                .frame(minHeight: 150)
            } header: {
                Text("Output priority")
            } footer: {
                Text("Drag to rank. The eye hides a device from the popup (the device you're using always shows).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Inputs") {
                ForEach(devices.inputs) { device in
                    deviceRow(device, rank: nil)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var rankedOutputs: [AudioDevice] { devices.outputs }

    private func deviceRow(_ device: AudioDevice, rank: Int?) -> some View {
        HStack {
            if let rank {
                Text("\(rank)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 16)
            }
            Image(systemName: device.symbol).frame(width: 20)
            VStack(alignment: .leading) {
                Text(device.name)
                Text(device.transportLabel).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            let hidden = prefs.hiddenDevices.contains(device.uid)
            Button {
                if hidden { prefs.hiddenDevices.remove(device.uid) } else { prefs.hiddenDevices.insert(device.uid) }
            } label: {
                Image(systemName: hidden ? "eye.slash" : "eye")
                    .foregroundStyle(hidden ? Color.secondary : .accentColor)
            }
            .buttonStyle(.plain)
            .help(hidden ? "Show in popup" : "Hide from popup")
        }
    }
}

// MARK: - Shortcuts

private struct ShortcutsSettings: View {
    @EnvironmentObject private var prefs: Preferences

    var body: some View {
        Form {
            Section {
                ForEach(HotkeyAction.allCases) { action in
                    LabeledContent(action.title) {
                        ShortcutRecorder(hotkey: Binding(
                            get: { prefs.hotkeys[action] },
                            set: { prefs.hotkeys[action] = $0; HotkeyCenter.shared.apply(prefs.hotkeys) }))
                    }
                }
            } header: {
                Text("Global shortcuts")
            } footer: {
                Text("“The app that's playing” is whichever app is making sound — so turning down a video in a background tab works while you type elsewhere. Hold the volume keys to keep going; turning up a muted app unmutes it.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("In the popup") {
                Text("↑ ↓ choose an app · ← → volume (⇧ for bigger steps) · M mute · E equalizer · Space play/pause · Return show app · 0 reset to 100% · Tab devices · Esc close")
                    .font(.callout)
            }

            Section("Automation") {
                Text("Control Voulum from Shortcuts, Raycast or Terminal with voulum:// links, e.g.")
                    .font(.callout)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(URLCommands.examples, id: \.self) { Text($0).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Equalizer

private struct EqualizerSettings: View {
    @EnvironmentObject private var prefs: Preferences

    var body: some View {
        Form {
            Section {
                if prefs.userPresets.isEmpty {
                    Text("Shape an app's EQ in the popup, then choose “Save Current as Preset…” from the preset menu.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(prefs.userPresets) { preset in
                    HStack {
                        TextField("Name", text: Binding(
                            get: { preset.name }, set: { prefs.renameUserPreset(preset.id, to: $0) }))
                            .textFieldStyle(.plain)
                        Spacer()
                        Text(preset.gains.map { String(format: "%+.0f", $0) }.joined(separator: " "))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Button(role: .destructive) { prefs.deleteUserPreset(preset.id) } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            } header: { Text("My presets") }

            Section("Built-in presets") {
                Text(EQPreset.builtIn.map(\.name).joined(separator: " · "))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - About

private struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
            Text("Voulum").font(.title.weight(.semibold))
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")")
                .foregroundStyle(.secondary)
            Text("Per-app volume, routing and EQ for macOS.\nFree and open source under the MIT license.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Link("github.com/lucianodiisouza/voulum", destination: URL(string: "https://github.com/lucianodiisouza/voulum")!)
            Spacer()
        }
        .padding(.top, 30)
        .frame(maxWidth: .infinity)
    }
}
