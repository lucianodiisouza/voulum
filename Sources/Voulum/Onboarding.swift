import AppKit
import CoreAudio
import SwiftUI

// MARK: - Audio permission probe

/// Brings up macOS's audio-capture prompt on purpose, from the welcome tour,
/// instead of in the middle of the user's first volume change.
///
/// There's no public API to ask for (or read) this permission. The prompt
/// appears when a process tap first delivers audio, so the probe runs a
/// short-lived, *unmuted* global tap — it only listens, nothing the user hears
/// changes — and watches for real samples. Samples arriving means access was
/// granted. Silence is ambiguous (denied, or simply nothing playing), so
/// that's reported as `nil`.
final class AudioPermissionProbe {
    private var tapID: AudioObjectID = .unknown
    private var aggregateID: AudioObjectID = .unknown
    private var procID: AudioDeviceIOProcID?
    private let heard = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
    private let queue = DispatchQueue(label: "com.voulum.permission-probe", qos: .userInitiated)

    init() { heard.initialize(to: false) }
    deinit {
        stop()
        heard.deallocate()
    }

    /// Calls back on the main thread: true once audio came through, nil if
    /// the probe timed out without hearing anything.
    func run(timeout: TimeInterval = 20, completion: @escaping @MainActor (Bool?) -> Void) {
        do {
            try start()
        } catch {
            log.error("Permission probe failed to start: \(String(describing: error), privacy: .public)")
            Task { @MainActor in completion(nil) }
            return
        }
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self else { return }
                if self.heard.pointee || Date() > deadline {
                    let result: Bool? = self.heard.pointee ? true : nil
                    self.stop()
                    Task { @MainActor in completion(result) }
                } else {
                    poll()
                }
            }
        }
        poll()
    }

    private func start() throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "\(AppTap.tapNamePrefix)permission"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var tap: AudioObjectID = .unknown
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr, tap.isValid else { throw TapError.create("AudioHardwareCreateProcessTap", status) }
        tapID = tap
        guard let tapUID: String = try tapID.readCF(kAudioTapPropertyUID) else {
            throw TapError.setup("Could not read tap UID")
        }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Voulum permission check",
            // The shared prefix means a crash mid-probe is cleaned up at next launch.
            kAudioAggregateDeviceUIDKey: "\(AppTap.aggregateUIDPrefix)permission.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID]],
        ]
        var device: AudioObjectID = .unknown
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device)
        guard status == noErr, device.isValid else { throw TapError.create("AudioHardwareCreateAggregateDevice", status) }
        aggregateID = device

        let heard = self.heard
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, _, _, _ in
            guard !heard.pointee else { return }
            for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)) {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                for i in 0..<count where data[i] != 0 {
                    heard.pointee = true
                    return
                }
            }
        }
        guard status == noErr, let procID else { throw TapError.create("AudioDeviceCreateIOProcIDWithBlock", status) }
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else { throw TapError.create("AudioDeviceStart", status) }
    }

    private func stop() {
        if let procID, aggregateID.isValid {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID.isValid { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = .unknown
        if tapID.isValid { AudioHardwareDestroyProcessTap(tapID) }
        tapID = .unknown
    }
}

// MARK: - Window

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindowController()
    static let completedKey = "onboardingCompleted"

    private var window: NSWindow?

    static var needsOnboarding: Bool { !UserDefaults.standard.bool(forKey: completedKey) }

    func show() {
        if window == nil {
            let root = OnboardingView(finish: { [weak self] in self?.finish() })
                .environmentObject(Preferences.shared)
                .environmentObject(AudioEngine.shared)
            let host = NSHostingController(rootView: root)
            let window = NSWindow(contentViewController: host)
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.title = "Welcome to Voulum"
            window.setContentSize(NSSize(width: 600, height: 500))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func finish() {
        window?.close()
        // Point at where Voulum lives from now on.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { StatusItemController.shared.open() }
    }

    func windowWillClose(_ notification: Notification) {
        UserDefaults.standard.set(true, forKey: Self.completedKey)
        Preferences.shared.saveNow()
        NSApp.setActivationPolicy(.accessory)
        window = nil
    }
}

// MARK: - Tour

private enum OnboardingStep: Int, CaseIterable {
    case welcome, permission, style, shortcuts
}

struct OnboardingView: View {
    let finish: () -> Void

    @State private var step: OnboardingStep = .welcome
    @State private var forward = true

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                page(step)
                    .id(step)
                    .transition(.asymmetric(
                        insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                        removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            footer
        }
        .frame(width: 600, height: 500)
        .background(OnboardingBackdrop())
    }

    @ViewBuilder private func page(_ step: OnboardingStep) -> some View {
        switch step {
        case .welcome: WelcomePage()
        case .permission: PermissionPage()
        case .style: StylePage()
        case .shortcuts: ShortcutsPage()
        }
    }

    private var footer: some View {
        HStack {
            Button("Back") { go(-1) }
                .buttonStyle(.borderless)
                .opacity(step == .welcome ? 0 : 1)
                .disabled(step == .welcome)
            Spacer()
            HStack(spacing: 7) {
                ForEach(OnboardingStep.allCases, id: \.self) { s in
                    Capsule()
                        .fill(s == step ? Color.accentColor : Color.primary.opacity(0.18))
                        .frame(width: s == step ? 18 : 7, height: 7)
                }
            }
            .animation(.snappy, value: step)
            Spacer()
            if step == .shortcuts {
                Button("Start Using Voulum", action: finish)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Continue") { go(1) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
    }

    private func go(_ delta: Int) {
        guard let next = OnboardingStep(rawValue: step.rawValue + delta) else { return }
        forward = delta > 0
        withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) { step = next }
    }
}

/// A soft wash in the icon's indigo and violet behind the window material.
private struct OnboardingBackdrop: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Rectangle().fill(.background)
            RadialGradient(colors: [Color(red: 0.36, green: 0.24, blue: 0.86).opacity(scheme == .dark ? 0.45 : 0.18), .clear],
                           center: .topLeading, startRadius: 10, endRadius: 520)
            RadialGradient(colors: [Color(red: 0.2, green: 0.83, blue: 1).opacity(scheme == .dark ? 0.22 : 0.12), .clear],
                           center: .bottomTrailing, startRadius: 10, endRadius: 460)
        }
        .ignoresSafeArea()
    }
}

private struct PageLayout<Hero: View, Body: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var hero: Hero
    @ViewBuilder var content: Body

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 24)
            hero
                .frame(height: 150)
            Text(title)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440)
            content
                .padding(.top, 6)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 40)
    }
}

// MARK: Pages

private struct WelcomePage: View {
    @State private var level: CGFloat = 0.2

    var body: some View {
        PageLayout(title: "Every app, its own volume",
                   subtitle: "Turn the music down without touching the call. Boost a quiet video. Send one app to your headphones.") {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.08), lineWidth: 7)
                Circle()
                    .trim(from: 0, to: level)
                    .stroke(AngularGradient(colors: [.mint, .cyan, .orange], center: .center),
                            style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 104, height: 104)
            }
            .frame(width: 140, height: 140)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { level = 0.85 }
            }
        } content: {
            HStack(spacing: 22) {
                feature("slider.horizontal.3", "Volume up to 400%")
                feature("arrow.triangle.branch", "Per-app outputs")
                feature("waveform", "10-band EQ")
            }
        }
    }

    private func feature(_ symbol: String, _ text: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.title2).foregroundStyle(Color.accentColor)
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
        .frame(width: 130)
    }
}

private struct PermissionPage: View {
    @EnvironmentObject private var engine: AudioEngine
    @State private var state: ProbeState = .idle
    @State private var probe: AudioPermissionProbe?

    enum ProbeState { case idle, asking, granted, unsure }

    var body: some View {
        PageLayout(title: "Allow audio access",
                   subtitle: "Voulum changes an app's volume by picking up its sound and playing it back at the level you set. macOS asks once. Nothing is recorded, and nothing leaves your Mac.") {
            Image(systemName: granted ? "checkmark.circle.fill" : "waveform.circle.fill")
                .font(.system(size: 96, weight: .regular))
                .foregroundStyle(granted ? AnyShapeStyle(Color.green) : AnyShapeStyle(LinearGradient(colors: [.indigo, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing)))
                .symbolEffect(.pulse, isActive: state == .asking)
                .contentTransition(.symbolEffect(.replace))
        } content: {
            VStack(spacing: 10) {
                switch state {
                case .idle where !granted:
                    Button("Allow Audio Access…") { ask() }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    Text("Play something first so Voulum can check that it worked.")
                        .font(.caption).foregroundStyle(.secondary)
                case .asking:
                    ProgressView().controlSize(.small)
                    Text("Choose Allow in the dialog.").font(.callout).foregroundStyle(.secondary)
                case .unsure:
                    Text("Voulum didn't hear any sound. If you chose Don't Allow, turn Voulum on in Privacy & Security ▸ Screen & System Audio Recording.")
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                    HStack {
                        Button("Try Again") { ask() }
                        Button("Open Privacy Settings") { Permissions.openAudioCaptureSettings() }
                    }
                default:
                    Label("All set", systemImage: "checkmark").font(.headline).foregroundStyle(.green)
                }
            }
        }
    }

    private var granted: Bool { state == .granted || (state == .idle && engine.audioPermissionGranted) }

    private func ask() {
        state = .asking
        let probe = AudioPermissionProbe()
        self.probe = probe
        probe.run { result in
            self.probe = nil
            if result == true {
                engine.markPermissionGranted()
                withAnimation { state = .granted }
            } else {
                withAnimation { state = .unsure }
            }
        }
    }
}

private struct StylePage: View {
    @EnvironmentObject private var prefs: Preferences
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        PageLayout(title: "Choose a look",
                   subtitle: "Light and dark follow your Mac. You can change this later in Settings.") {
            HStack(spacing: 18) {
                styleCard(.standard)
                styleCard(.glass)
            }
        } content: {
            Toggle("Open Voulum when you log in", isOn: Binding(
                get: { launchAtLogin }, set: { launchAtLogin = LoginItem.setEnabled($0) }))
                .toggleStyle(.switch)
        }
    }

    private func styleCard(_ style: PopupStyle) -> some View {
        let selected = prefs.popupStyle == style
        let available = style != .glass || PopupStyle.glassAvailable
        return Button {
            withAnimation(.snappy) { prefs.popupStyle = style }
        } label: {
            VStack(spacing: 8) {
                PopupThumbnail(style: style)
                    .frame(width: 150, height: 104)
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 3 : 1))
                Text(style.title).font(.callout.weight(selected ? .semibold : .regular))
                if !available {
                    Text("macOS 26 or later").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .opacity(available ? 1 : 0.5)
    }
}

/// A tiny drawing of the popup in each style.
private struct PopupThumbnail: View {
    let style: PopupStyle

    var body: some View {
        ZStack {
            // A colourful "desktop" so the difference reads.
            LinearGradient(colors: [.indigo, .purple, .orange], startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(.cyan.opacity(0.8)).frame(width: 60).offset(x: -40, y: 22)
            VStack(alignment: .leading, spacing: 7) {
                ForEach([0.8, 0.5, 0.65], id: \.self) { fill in
                    HStack(spacing: 6) {
                        Circle().fill(.green.opacity(0.9)).frame(width: 12, height: 12)
                        Capsule().fill(Color.primary.opacity(0.15)).frame(height: 5)
                            .overlay(alignment: .leading) {
                                GeometryReader { g in Capsule().fill(Color.accentColor).frame(width: g.size.width * fill) }
                            }
                    }
                }
            }
            .padding(12)
            .frame(width: 112, height: 74)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(style == .glass ? AnyShapeStyle(.ultraThinMaterial.opacity(0.55)) : AnyShapeStyle(.regularMaterial))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(.white.opacity(style == .glass ? 0.6 : 0.15), lineWidth: style == .glass ? 1.2 : 0.5))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct ShortcutsPage: View {
    @EnvironmentObject private var prefs: Preferences

    var body: some View {
        PageLayout(title: "Shortcuts",
                   subtitle: "Control the app that's playing without opening Voulum. Optional, and you can set them later.") {
            Image(systemName: "command.square.fill")
                .font(.system(size: 92))
                .foregroundStyle(LinearGradient(colors: [.purple, .indigo], startPoint: .top, endPoint: .bottom))
        } content: {
            VStack(spacing: 8) {
                ForEach(HotkeyAction.allCases) { action in
                    HStack {
                        Text(action.title).font(.callout)
                        Spacer()
                        ShortcutRecorder(hotkey: Binding(
                            get: { prefs.hotkeys[action] },
                            set: { prefs.hotkeys[action] = $0; HotkeyCenter.shared.apply(prefs.hotkeys) }))
                            .frame(width: 150)
                    }
                }
                Label("Voulum lives in your menu bar, next to the clock.", systemImage: "menubar.arrow.up.rectangle")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.top, 6)
            }
            .frame(maxWidth: 440)
        }
    }
}
