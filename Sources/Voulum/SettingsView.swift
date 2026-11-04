import AppKit
import Combine
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, apps, devices, shortcuts, equalizer, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return String(localized: "General")
        case .apps: return String(localized: "Apps")
        case .devices: return String(localized: "Devices")
        case .shortcuts: return String(localized: "Shortcuts")
        case .equalizer: return String(localized: "Equalizer")
        case .about: return String(localized: "About")
        }
    }
    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .apps: return "square.grid.2x2.fill"
        case .devices: return "hifispeaker.2.fill"
        case .shortcuts: return "command"
        case .equalizer: return "slider.vertical.3"
        case .about: return "info"
        }
    }
    /// Sidebar tile colour, System Settings style.
    var tint: Color {
        switch self {
        case .general: return .gray
        case .apps: return .blue
        case .devices: return .orange
        case .shortcuts: return .purple
        case .equalizer: return .pink
        case .about: return .teal
        }
    }
}

/// One searchable setting: where it lives and the words people might type.
struct SettingsEntry: Identifiable {
    let id: String
    let title: String
    let tab: SettingsTab
    var keywords: String = ""

    static let all: [SettingsEntry] = [
        .init(id: "login", title: String(localized: "Open at login"), tab: .general, keywords: "launch startup start boot"),
        .init(id: "theme", title: String(localized: "Popup style"), tab: .general, keywords: "appearance liquid glass theme look translucent"),
        .init(id: "icon", title: String(localized: "Menu bar icon"), tab: .general, keywords: "status item style adaptive speaker waveform dial"),
        .init(id: "pinned-quiet", title: String(localized: "Keep pinned apps listed"), tab: .general, keywords: "behavior quiet idle"),
        .init(id: "pause-others", title: String(localized: "Pause other apps on play"), tab: .general, keywords: "behavior transport play pause"),
        .init(id: "step", title: String(localized: "Volume step"), tab: .general, keywords: "arrow keys scroll wheel increment"),
        .init(id: "updates", title: String(localized: "Updates"), tab: .general, keywords: "sparkle check version automatic"),
        .init(id: "primo-apps", title: String(localized: "More from Primo"), tab: .about, keywords: "apps primodock primoengine cleanuai flecha recta primorec notchy"),
        .init(id: "onboarding", title: String(localized: "Show welcome tour"), tab: .general, keywords: "onboarding intro tutorial setup watch again"),
        .init(id: "pinned", title: String(localized: "Pinned apps"), tab: .apps, keywords: "pin keep"),
        .init(id: "ignored", title: String(localized: "Ignored apps"), tab: .apps, keywords: "ignore hide exclude blacklist"),
        .init(id: "remembered", title: String(localized: "Remembered app settings"), tab: .apps, keywords: "forget reset volume saved"),
        .init(id: "auto-switch", title: String(localized: "Switch to preferred output"), tab: .devices, keywords: "automatic connect headphones airpods"),
        .init(id: "priority", title: String(localized: "Output priority"), tab: .devices, keywords: "order rank hide speakers"),
        .init(id: "inputs", title: String(localized: "Input devices"), tab: .devices, keywords: "microphone mic"),
        .init(id: "global", title: String(localized: "Global shortcuts"), tab: .shortcuts, keywords: "hotkey keyboard volume up down mute"),
        .init(id: "popup-keys", title: String(localized: "Keys in the popup"), tab: .shortcuts, keywords: "keyboard arrows navigation"),
        .init(id: "automation", title: String(localized: "Automation (voulum://)"), tab: .shortcuts, keywords: "url scheme raycast shortcuts terminal script"),
        .init(id: "my-presets", title: String(localized: "My EQ presets"), tab: .equalizer, keywords: "equalizer rename delete custom"),
        .init(id: "builtin-presets", title: String(localized: "Built-in EQ presets"), tab: .equalizer, keywords: "equalizer bass treble vocal"),
        .init(id: "about", title: String(localized: "Version & license"), tab: .about, keywords: "about github source mit"),
    ]

    static func matching(_ query: String) -> [SettingsEntry] {
        let words = query.lowercased().split(separator: " ")
        guard !words.isEmpty else { return [] }
        return all.filter { entry in
            let haystack = "\(entry.title) \(entry.tab.title) \(entry.keywords)".lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private let selection = SettingsSelection()
    private var titleWatch: AnyCancellable?

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
            host.sceneBridgingOptions = [.toolbars, .title]
            let window = NSWindow(contentViewController: host)
            window.title = "Voulum Settings"
            // Full-height translucent sidebar under a unified toolbar.
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.toolbar = NSToolbar(identifier: "settings")
            window.toolbarStyle = .unified
            window.titlebarAppearsTransparent = true
            window.setContentSize(NSSize(width: 780, height: 540))
            window.contentMinSize = NSSize(width: 680, height: 440)
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("VoulumSettings")
            window.delegate = self
            if !window.setFrameUsingName("VoulumSettings") { window.center() }
            // The toolbar title names the page, like System Settings.
            titleWatch = selection.$tab.sink { [weak window] tab in window?.title = tab.title }
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
    /// The setting a search result pointed at; flashes, then clears.
    @Published var highlight: String?

    @MainActor func reveal(_ entry: SettingsEntry) {
        tab = entry.tab
        highlight = entry.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            if self?.highlight == entry.id { self?.highlight = nil }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var selection: SettingsSelection
    @State private var query = ""

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            ScrollViewReader { proxy in
                page
                    .navigationTitle(selection.tab.title)
                    .onChange(of: selection.highlight) { _, id in
                        guard let id else { return }
                        // Let the page switch first.
                        DispatchQueue.main.async {
                            withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
                        }
                    }
            }
        }
        .searchable(text: $query, placement: .sidebar, prompt: "Search")
        .frame(minWidth: 680, minHeight: 440)
    }

    private var sidebar: some View {
        List(selection: Binding<SettingsTab?>(get: { selection.tab },
                                              set: { if let t = $0 { selection.tab = t } })) {
            if query.isEmpty {
                ForEach(SettingsTab.allCases) { tab in
                    SidebarLabel(title: tab.title, symbol: tab.symbol, tint: tab.tint).tag(tab)
                }
            } else {
                let results = SettingsEntry.matching(query)
                if results.isEmpty {
                    Text("No results").foregroundStyle(.secondary)
                }
                ForEach(results) { entry in
                    Button {
                        selection.reveal(entry)
                    } label: {
                        HStack(spacing: 8) {
                            SettingsIconTile(symbol: entry.tab.symbol, tint: entry.tab.tint, size: 18)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(entry.title).lineLimit(1)
                                Text(entry.tab.title).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { sidebarFooter }
    }

    private var sidebarFooter: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text("Voulum").font(.caption.weight(.semibold))
                Text("Version \(Updater.version)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var page: some View {
        switch selection.tab {
        case .general: GeneralSettings()
        case .apps: AppsSettings()
        case .devices: DevicesSettings()
        case .shortcuts: ShortcutsSettings()
        case .equalizer: EqualizerSettings()
        case .about: AboutSettings()
        }
    }
}

/// White glyph on a coloured rounded square, like System Settings.
struct SettingsIconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).fill(tint.gradient))
    }
}

private struct SidebarLabel: View {
    let title: String
    let symbol: String
    let tint: Color

    var body: some View {
        Label {
            Text(title)
        } icon: {
            SettingsIconTile(symbol: symbol, tint: tint)
        }
    }
}

/// Marks a row a search result can jump to, and flashes it when it does.
private struct SettingsAnchor: ViewModifier {
    let id: String
    @EnvironmentObject private var selection: SettingsSelection

    func body(content: Content) -> some View {
        content
            .id(id)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(selection.highlight == id ? 0.22 : 0))
                    .padding(-5)
                    .animation(.easeInOut(duration: 0.3), value: selection.highlight)
            )
    }
}

extension View {
    fileprivate func settingsAnchor(_ id: String) -> some View { modifier(SettingsAnchor(id: id)) }
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
                    .settingsAnchor("login")
            }
            Section {
                Picker("Popup style", selection: $prefs.popupStyle) {
                    ForEach(PopupStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(!PopupStyle.glassAvailable)
                .settingsAnchor("theme")
            } header: {
                Text("Appearance")
            } footer: {
                Text(PopupStyle.glassAvailable
                     ? String(localized: "Liquid Glass lets your desktop show through the popup. Light and dark follow your Mac.")
                     : String(localized: "Liquid Glass needs macOS 26 or later. Light and dark follow your Mac."))
                    .font(.caption).foregroundStyle(.secondary)
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
                .settingsAnchor("icon")
                Text("Adaptive shows the kind of device you're listening on. Every style turns into a slashed speaker when the output is muted.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Behavior") {
                Toggle("Keep pinned apps in the list when they're quiet", isOn: $prefs.showInactivePinned)
                    .settingsAnchor("pinned-quiet")
                Toggle("Pressing play in Voulum pauses other apps", isOn: $prefs.pauseOthersOnPlay)
                    .settingsAnchor("pause-others")
                Picker("Volume step", selection: $prefs.volumeStep) {
                    ForEach(VolumeStep.allCases) { Text($0.title).tag($0) }
                }
                .settingsAnchor("step")
                Text("Used by the arrow keys, the scroll wheel and the volume shortcuts.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent {
                    Button("Watch Again") { OnboardingWindowController.shared.show() }
                } label: {
                    Text("Welcome tour")
                    Text("The short intro from the first launch.")
                }
                .settingsAnchor("onboarding")
            }
            Section {
                LabeledContent("Version") {
                    HStack(spacing: 10) {
                        Text(verbatim: Updater.version).monospacedDigit()
                        Button("Check for Updates Now") { updater.checkForUpdates() }
                            .disabled(!updater.canCheckForUpdates)
                    }
                }
                .settingsAnchor("updates")
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { updater.automaticallyChecks }, set: { updater.automaticallyChecks = $0 }))
                    .disabled(!updater.isConfigured)
            } header: {
                Text("Updates")
            } footer: {
                if !updater.isConfigured {
                    Text("This build can't update itself. New versions are on GitHub.")
                        .font(.caption).foregroundStyle(.secondary)
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
                    Text("Pinned apps stay in the popup when they're quiet, so you can set their volume before they play. Pin one from its ⋯ menu.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(prefs.pinned) { app in
                    knownRow(app) {
                        Button("Unpin") { prefs.setPinned(app, false) }
                    }
                }
            } header: { Text("Pinned apps").settingsAnchor("pinned") }

            Section {
                if prefs.ignored.isEmpty {
                    Text("Voulum won't list ignored apps or touch their audio.")
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
            } header: { Text("Ignored apps").settingsAnchor("ignored") }

            Section {
                let keys = prefs.apps.keys.sorted()
                if keys.isEmpty {
                    Text("Nothing saved yet. Voulum keeps an app's volume, EQ and output after you change them.")
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
            } header: { Text("Remembered settings").settingsAnchor("remembered") }
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
        var parts: [String] = [s.muted ? String(localized: "Muted") : s.level.percentLabel]
        if s.eq.enabled && !s.eq.isFlat { parts.append("EQ") }
        if s.route != .system { parts.append(String(localized: "Custom output")) }
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
                    .settingsAnchor("auto-switch")
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
                Text("Output priority").settingsAnchor("priority")
            } footer: {
                Text("Drag to rank. The eye hides a device from the popup (the device you're using always shows).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                ForEach(devices.inputs) { device in
                    deviceRow(device, rank: nil)
                }
            } header: { Text("Inputs").settingsAnchor("inputs") }
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
            .help(hidden ? String(localized: "Show in popup") : String(localized: "Hide from popup"))
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
                Text("Global shortcuts").settingsAnchor("global")
            } footer: {
                Text("These act on the app that's making sound, even in a background tab. Hold a volume shortcut to keep going. Turning up a muted app unmutes it.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                ForEach(Self.popupKeys, id: \.0) { keys, action in
                    LabeledContent(action) { KeyCaps(keys) }
                }
            } header: { Text("In the popup").settingsAnchor("popup-keys") }

            Section {
                ForEach(URLCommands.examples, id: \.self) { example in
                    HStack {
                        Text(example)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(example, forType: .string)
                        } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                        .help("Copy")
                    }
                }
            } header: {
                Text("Automation").settingsAnchor("automation")
            } footer: {
                Text("Open these links from Shortcuts, Raycast or Terminal (`open \"voulum://…\"`).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

extension ShortcutsSettings {
    static let popupKeys: [(String, String)] = [
        ("↑ ↓", String(localized: "Choose an app")),
        ("← →", String(localized: "Volume (⇧ for bigger steps)")),
        ("M", String(localized: "Mute")),
        ("E", String(localized: "Equalizer")),
        (String(localized: "Space"), String(localized: "Play / pause")),
        ("↩", String(localized: "Show the app")),
        ("0", String(localized: "Back to 100%")),
        ("⇥", String(localized: "Devices")),
        ("esc", String(localized: "Close")),
    ]
}

/// "↑ ↓" drawn as little keycaps.
private struct KeyCaps: View {
    let keys: [String]
    init(_ keys: String) { self.keys = keys.split(separator: " ").map(String.init) }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .padding(.horizontal, 6)
                    .frame(minWidth: 22, minHeight: 20)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
            }
        }
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
            } header: { Text("My presets").settingsAnchor("my-presets") }

            Section {
                Text(EQPreset.builtIn.map(\.name).joined(separator: " · "))
                    .font(.callout).foregroundStyle(.secondary)
            } header: { Text("Built-in presets").settingsAnchor("builtin-presets") }
        }
        .formStyle(.grouped)
    }
}

// MARK: - About

private struct AboutSettings: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                header
                VStack(alignment: .leading, spacing: 8) {
                    Text("More from Primo")
                        .font(.headline)
                        .padding(.leading, 4)
                        .settingsAnchor("primo-apps")
                    PrimoAppsList()
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 12).fill(.background.secondary))
                }
                .frame(maxWidth: 460)
                .padding(.top, 28)
            }
            .padding(.vertical, 30)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
            Text("Voulum").font(.title.weight(.semibold)).settingsAnchor("about")
            Text("Version \(Updater.version)")
                .foregroundStyle(.secondary)
            Text("Per-app volume, routing and EQ for macOS.\nFree and open source under the MIT license.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Link("github.com/lucianodiisouza/voulum", destination: URL(string: "https://github.com/lucianodiisouza/voulum")!)
            Button("Watch the Welcome Tour") { OnboardingWindowController.shared.show() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 12)
        }
    }
}
