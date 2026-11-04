import AppKit
import CoreAudio
import SwiftUI

// MARK: - Audio permission probe

/// Brings up macOS's audio-capture prompt on purpose, from the welcome tour,
/// instead of in the middle of the user's first volume change. It doubles as
/// the tour's microphone: while it runs, `level` follows whatever the Mac is
/// playing, which drives the visualizer.
///
/// There's no public API to ask for (or read) this permission. The prompt
/// appears when a process tap first delivers audio, so the probe runs an
/// *unmuted* global tap (it only listens, nothing the user hears changes) and
/// watches for real samples. Samples arriving means access was granted.
/// Silence is ambiguous (denied, or simply nothing playing), so that's
/// reported as `nil`.
final class AudioPermissionProbe {
    private var tapID: AudioObjectID = .unknown
    private var aggregateID: AudioObjectID = .unknown
    private var procID: AudioDeviceIOProcID?
    /// [0] heard anything (0/1), [1] smoothed loudness 0…1.
    private let shared = UnsafeMutablePointer<Float>.allocate(capacity: 2)
    private let queue = DispatchQueue(label: "com.voulum.permission-probe", qos: .userInitiated)
    private var running = false

    init() { shared.initialize(repeating: 0, count: 2) }
    deinit {
        stop()
        shared.deallocate()
    }

    /// Loudness of everything playing, 0…1. Read from any thread.
    var level: Float { shared[1] }
    var heard: Bool { shared[0] > 0 }

    /// Starts listening and calls back on the main thread: true as soon as
    /// audio comes through, nil if nothing was heard before `timeout`. Keeps
    /// listening after that until `stop()`, so the visualizer stays live.
    func run(timeout: TimeInterval = 20, completion: @escaping @MainActor (Bool?) -> Void) {
        if !running {
            do {
                try start()
            } catch {
                log.error("Permission probe failed to start: \(String(describing: error), privacy: .public)")
                stop()
                Task { @MainActor in completion(nil) }
                return
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, self.running else { return }
                if self.heard {
                    Task { @MainActor in completion(true) }
                } else if Date() > deadline {
                    Task { @MainActor in completion(nil) }
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

        let shared = self.shared
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, _, _, _ in
            var sum: Float = 0
            var count = 0
            for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)) {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let n = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                for i in 0..<n { sum += data[i] * data[i] }
                count += n
            }
            guard count > 0 else { return }
            let rms = (sum / Float(count)).squareRoot()
            if rms > 0 { shared[0] = 1 }
            // Same perceptual scale as the row meters: -54…-6 dB → 0…1.
            let db = 20 * log10(max(rms, 1e-6))
            let target = min(1, max(0, (db + 54) / 48))
            shared[1] = target > shared[1] ? target : shared[1] * 0.9 + target * 0.1
        }
        guard status == noErr, let procID else { throw TapError.create("AudioDeviceCreateIOProcIDWithBlock", status) }
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else { throw TapError.create("AudioDeviceStart", status) }
        running = true
    }

    func stop() {
        running = false
        if let procID, aggregateID.isValid {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID.isValid { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = .unknown
        if tapID.isValid { AudioHardwareDestroyProcessTap(tapID) }
        tapID = .unknown
        shared[1] = 0
    }
}

// MARK: - Window

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindowController()
    static let completedKey = "onboardingCompleted"

    private var window: NSWindow?
    private var model: OnboardingModel?

    static var needsOnboarding: Bool { !UserDefaults.standard.bool(forKey: completedKey) }

    func show() {
        if window == nil {
            let model = OnboardingModel()
            self.model = model
            let root = OnboardingView(finish: { [weak self] in self?.finish() },
                                      close: { [weak self] in self?.window?.close() })
                .environmentObject(model)
                .environmentObject(Preferences.shared)
                .environmentObject(AudioEngine.shared)
            let host = NSHostingController(rootView: root)
            let window = NSWindow(contentViewController: host)
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            // A stage, not a document: no traffic lights. Esc or ⌘W closes.
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(button)?.isHidden = true
            }
            window.isMovableByWindowBackground = true
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = .black
            window.title = String(localized: "Welcome to Voulum")
            window.setContentSize(NSSize(width: 640, height: 520))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        // Keeps the app list and level meters fresh for the tour.
        AudioEngine.shared.beginLiveUpdates()
    }

    private func finish() {
        guard let window else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.35
            window.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                window.close()
                window.alphaValue = 1
                // Show where Voulum lives from now on.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { StatusItemController.shared.open() }
            }
        })
    }

    func windowWillClose(_ notification: Notification) {
        model?.probe.stop()
        model = nil
        AudioEngine.shared.endLiveUpdates()
        UserDefaults.standard.set(true, forKey: Self.completedKey)
        Preferences.shared.saveNow()
        NSApp.setActivationPolicy(.accessory)
        window = nil
    }
}

// MARK: - Model

@MainActor
final class OnboardingModel: ObservableObject {
    enum Step: Int, CaseIterable { case hello, listen, look }
    enum Access { case unknown, asking, granted, silent }

    @Published var step: Step = .hello
    @Published var access: Access = .unknown
    let probe = AudioPermissionProbe()

    /// What the visualizer follows: everything the Mac plays, through the
    /// probe, plus the apps Voulum is already adjusting. Those are muted at
    /// the source and replayed by Voulum, so the probe's tap can miss them.
    var liveLevel: Float {
        max(probe.level, AudioEngine.shared.meters.levels.values.max() ?? 0)
    }

    /// How hard the visualizer moves when it has no real audio to follow.
    var idleEnergy: Double {
        switch (step, access) {
        case (.hello, _): return 0.35
        case (_, .asking): return 0.55
        default: return 0.25
        }
    }

    func askForAccess(engine: AudioEngine) {
        access = .asking
        probe.run { [weak self] result in
            guard let self else { return }
            if result == true {
                engine.markPermissionGranted()
                NSSound(named: "Glass")?.play()
                withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { self.access = .granted }
            } else {
                withAnimation { self.access = .silent }
            }
        }
    }
}

// MARK: - Tour

struct OnboardingView: View {
    let finish: () -> Void
    let close: () -> Void

    @EnvironmentObject private var model: OnboardingModel

    var body: some View {
        ZStack {
            AudioStage(level: { model.liveLevel }, idleEnergy: model.idleEnergy, live: model.access == .granted)

            VStack(spacing: 0) {
                progress
                    .padding(.top, 22)
                ZStack {
                    switch model.step {
                    case .hello: HelloStep(next: { go(.listen) })
                    case .listen: ListenStep(next: { go(.look) })
                    case .look: LookStep(finish: finish)
                    }
                }
                .id(model.step)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 1.04)).combined(with: .offset(y: 12)),
                    removal: .opacity.combined(with: .scale(scale: 0.96))))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, 40)
            }
        }
        .frame(width: 640, height: 520)
        .preferredColorScheme(.dark)
        .onExitCommand(perform: close)
    }

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingModel.Step.allCases, id: \.self) { s in
                Capsule()
                    .fill(.white.opacity(s == model.step ? 0.9 : 0.25))
                    .frame(width: s == model.step ? 20 : 6, height: 6)
            }
        }
        .animation(.snappy, value: model.step)
    }

    private func go(_ step: OnboardingModel.Step) {
        withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) { model.step = step }
    }
}

// MARK: Stage

/// The backdrop: slow aurora blobs in the icon's colours over near-black,
/// and a spectrum along the bottom that idles gently and, once Voulum can
/// hear the Mac, dances to whatever is actually playing.
private struct AudioStage: View {
    let level: () -> Float
    let idleEnergy: Double
    let live: Bool

    @State private var smoothed: Double = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                drawAurora(&context, size: size, t: t)
                drawSpectrum(&context, size: size, t: t, energy: energy())
            }
        }
        .background(Color(red: 0.03, green: 0.03, blue: 0.08))
        .ignoresSafeArea()
    }

    private func energy() -> Double {
        guard live else { return idleEnergy }
        // A floor keeps it alive between songs; the gain makes ordinary
        // listening levels fill the stage.
        return max(0.15, min(1, Double(level()) * 1.6))
    }

    private func drawAurora(_ context: inout GraphicsContext, size: CGSize, t: Double) {
        let blobs: [(Color, Double, Double, Double)] = [
            (Color(red: 0.42, green: 0.27, blue: 0.95), 0.09, 0.0, 0.55),
            (Color(red: 0.18, green: 0.78, blue: 1.0), 0.07, 2.1, 0.42),
            (Color(red: 0.2, green: 0.95, blue: 0.7), 0.05, 4.2, 0.3),
        ]
        // Radial gradients rather than a blur filter: a filtered layer is
        // clipped to a rectangle, which showed as a hard edge.
        for (color, speed, phase, alpha) in blobs {
            let center = CGPoint(x: size.width * (0.5 + 0.32 * cos(t * speed + phase)),
                                 y: size.height * (0.38 + 0.2 * sin(t * speed * 1.3 + phase)))
            let radius = size.width * 0.55
            context.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .radialGradient(Gradient(colors: [color.opacity(alpha), color.opacity(alpha * 0.4), .clear]),
                                               center: center, startRadius: 0, endRadius: radius))
        }
    }

    private func drawSpectrum(_ context: inout GraphicsContext, size: CGSize, t: Double, energy: Double) {
        let bars = 56
        let gap: CGFloat = 4
        let width = (size.width - gap * CGFloat(bars + 1)) / CGFloat(bars)
        let baseline = size.height
        let maxHeight = size.height * 0.34
        // Bright at the floor, fading out toward the top so the text above
        // stays readable.
        let gradient = Gradient(colors: [
            Color(red: 0.2, green: 0.95, blue: 0.7).opacity(0.95),
            Color(red: 0.3, green: 0.8, blue: 1).opacity(0.6),
            Color(red: 0.55, green: 0.4, blue: 1).opacity(0.15),
        ])
        for i in 0..<bars {
            let p = Double(i) / Double(bars - 1)
            // A few drifting sines per bar read as music rather than noise.
            let wave = 0.5 + 0.5 * sin(t * 2.3 + p * 9) * cos(t * 1.1 + p * 4.7)
            let shimmer = 0.5 + 0.5 * sin(t * 7 + Double(i) * 1.7)
            // Bass-heavy shape, like a real spectrum.
            let tilt = 1 - 0.55 * p
            let h = maxHeight * CGFloat(min(1, energy * tilt * (0.35 + 0.5 * wave + 0.25 * shimmer)))
            let rect = CGRect(x: gap + CGFloat(i) * (width + gap), y: baseline - h, width: width, height: h + 8)
            let shape = Path(roundedRect: rect, cornerRadius: width / 2)
            context.fill(shape, with: .linearGradient(gradient, startPoint: CGPoint(x: 0, y: baseline),
                                                      endPoint: CGPoint(x: 0, y: baseline - maxHeight)))
        }
    }
}

// MARK: Steps

private struct StepText: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey

    var body: some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(LinearGradient(colors: [.white, Color(white: 0.78)], startPoint: .top, endPoint: .bottom))
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(.title3)
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 460)
        }
    }
}

/// The big pill button at the bottom of each step.
private struct StageButton: View {
    let title: LocalizedStringKey
    let action: () -> Void
    @State private var hovering = false
    /// During a step change both steps' buttons are on screen and both answer
    /// Return, so one key press could run through the whole tour. A new
    /// button only starts listening once its step has settled.
    @State private var armed = false

    var body: some View {
        Button { if armed { action() } } label: {
            Text(title)
                .font(.headline)
                .foregroundStyle(.black)
                .padding(.horizontal, 28)
                .padding(.vertical, 12)
                .background(Capsule().fill(.white))
                .shadow(color: Color(red: 0.4, green: 0.8, blue: 1).opacity(hovering ? 0.7 : 0.35), radius: hovering ? 22 : 14)
                .scaleEffect(hovering ? 1.04 : 1)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
        .onHover { h in withAnimation(.snappy(duration: 0.18)) { hovering = h } }
        .task {
            try? await Task.sleep(for: .milliseconds(600))
            armed = true
        }
    }
}

/// Expanding rings, like sound leaving a speaker.
private struct SoundRings: View {
    var speed: Double = 1
    var color: Color = .white

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate * speed
            ZStack {
                ForEach(0..<3) { i in
                    let phase = (t / 2.4 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                    Circle()
                        .stroke(color.opacity(0.5 * (1 - phase)), lineWidth: 2)
                        .scaleEffect(0.55 + phase * 0.75)
                }
            }
        }
    }
}

private struct HelloStep: View {
    let next: () -> Void
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 26) {
            Spacer(minLength: 30)
            ZStack {
                SoundRings()
                    .frame(width: 260, height: 260)
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 128, height: 128)
                    .shadow(color: Color(red: 0.45, green: 0.3, blue: 1).opacity(0.6), radius: 30)
                    .scaleEffect(appeared ? 1 : 0.6)
                    .opacity(appeared ? 1 : 0)
            }
            .frame(height: 190)
            StepText(title: "Every app, its own volume",
                     subtitle: "Turn the music down without touching the call. Boost a quiet video. Send one app to your headphones.")
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 14)
            StageButton(title: "Get Started", action: next)
                .opacity(appeared ? 1 : 0)
            Spacer(minLength: 0)
        }
        .onAppear {
            withAnimation(.spring(response: 0.8, dampingFraction: 0.65).delay(0.1)) { appeared = true }
        }
    }
}

private struct ListenStep: View {
    let next: () -> Void
    @EnvironmentObject private var model: OnboardingModel
    @EnvironmentObject private var engine: AudioEngine

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 30)
            hero
                .frame(height: 170)
            switch model.access {
            case .granted:
                StepText(title: "Voulum can hear your Mac",
                         subtitle: playing.isEmpty ? "Play something and watch it move." : "These are playing right now. Each one gets its own slider.")
                StageButton(title: "Continue", action: next)
            case .silent:
                StepText(title: "Nothing came through",
                         subtitle: "Start some music and try again. If you chose Don't Allow, turn Voulum on in Privacy & Security ▸ Screen & System Audio Recording.")
                HStack(spacing: 14) {
                    Button("Open Privacy Settings") { Permissions.openAudioCaptureSettings() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.75))
                    StageButton(title: "Try Again") { model.askForAccess(engine: engine) }
                }
                Button("Skip for now", action: next)
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.5))
            default:
                StepText(title: "Let Voulum listen",
                         subtitle: "Voulum sets an app's volume by playing its sound back at the level you choose. macOS asks once. Nothing is recorded, and nothing leaves your Mac.")
                if model.access == .asking {
                    Text("Choose Allow in the dialog. Have something playing so Voulum can hear it.")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.vertical, 12)
                } else {
                    StageButton(title: "Allow Audio Access") { model.askForAccess(engine: engine) }
                }
            }
            Spacer(minLength: 0)
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: model.access)
    }

    private var playing: [AudioApp] {
        Array(engine.visibleApps.filter { $0.isPlaying }.prefix(5))
    }

    @ViewBuilder private var hero: some View {
        if model.access == .granted && !playing.isEmpty {
            HStack(spacing: 18) {
                ForEach(Array(playing.enumerated()), id: \.element.key) { index, app in
                    VStack(spacing: 8) {
                        ZStack {
                            SoundRings(speed: 1.4, color: .mint)
                                .frame(width: 104, height: 104)
                            Image(nsImage: app.icon).resizable().frame(width: 64, height: 64)
                        }
                        Text(app.name).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    }
                    .frame(width: 104)
                    .transition(.scale(scale: 0.3).combined(with: .opacity)
                        .animation(.spring(response: 0.5, dampingFraction: 0.6).delay(Double(index) * 0.08)))
                }
            }
        } else {
            ZStack {
                SoundRings(speed: model.access == .asking ? 2 : 1, color: model.access == .granted ? .mint : .white)
                    .frame(width: 220, height: 220)
                Image(systemName: model.access == .granted ? "checkmark" : "ear.and.waveform")
                    .font(.system(size: 54, weight: .semibold))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
    }
}

private struct LookStep: View {
    let finish: () -> Void
    @EnvironmentObject private var prefs: Preferences
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 30)
            HStack(spacing: 20) {
                card(.standard)
                card(.glass)
            }
            .frame(height: 170)
            StepText(title: "Pick a look",
                     subtitle: "Light and dark follow your Mac. Shortcuts and everything else are in Settings.")
            Toggle("Open Voulum when you log in", isOn: Binding(
                get: { launchAtLogin }, set: { launchAtLogin = LoginItem.setEnabled($0) }))
                .toggleStyle(.switch)
                .foregroundStyle(.white.opacity(0.8))
            StageButton(title: "Open Voulum", action: finish)
            Spacer(minLength: 0)
        }
    }

    private func card(_ style: PopupStyle) -> some View {
        let selected = prefs.popupStyle == style
        let available = style != .glass || PopupStyle.glassAvailable
        return Button {
            withAnimation(.snappy) { prefs.popupStyle = style }
        } label: {
            VStack(spacing: 10) {
                PopupThumbnail(style: style)
                    .frame(width: 180, height: 120)
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(.white.opacity(selected ? 0.95 : 0.15), lineWidth: selected ? 2.5 : 1))
                    .shadow(color: .white.opacity(selected ? 0.25 : 0), radius: 16)
                    .scaleEffect(selected ? 1.04 : 1)
                Text(style.title)
                    .font(.callout.weight(selected ? .semibold : .regular))
                    .foregroundStyle(.white.opacity(selected ? 1 : 0.6))
                if !available {
                    Text("macOS 26 or later").font(.caption2).foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .opacity(available ? 1 : 0.45)
    }
}

/// A tiny drawing of the popup in each style, over a colourful "desktop" so
/// the difference reads.
private struct PopupThumbnail: View {
    let style: PopupStyle

    var body: some View {
        ZStack {
            LinearGradient(colors: [.indigo, .purple, .orange], startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(.cyan.opacity(0.8)).frame(width: 70).offset(x: -50, y: 26)
            VStack(alignment: .leading, spacing: 8) {
                ForEach([0.8, 0.5, 0.65], id: \.self) { fill in
                    HStack(spacing: 6) {
                        Circle().fill(.green.opacity(0.9)).frame(width: 12, height: 12)
                        Capsule().fill(Color.white.opacity(0.25)).frame(height: 5)
                            .overlay(alignment: .leading) {
                                GeometryReader { g in Capsule().fill(Color.accentColor).frame(width: g.size.width * fill) }
                            }
                    }
                }
            }
            .padding(12)
            .frame(width: 130, height: 84)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(style == .glass ? AnyShapeStyle(.ultraThinMaterial.opacity(0.5)) : AnyShapeStyle(.regularMaterial))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.white.opacity(style == .glass ? 0.6 : 0.15), lineWidth: style == .glass ? 1.2 : 0.5))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
