import AppKit
import SwiftUI

/// The other oprimo.dev apps, listed under Settings ▸ About ▸ "More from Primo".
/// A click opens the app when it's installed on this Mac, otherwise its site
/// (or its GitHub page when it has no site), in the language Voulum is showing.
enum PrimoApp: String, CaseIterable, Identifiable {
    case dock, engine, cleanuai, flecha, recta, rec, notchy

    var id: Self { self }

    /// Product names, never translated.
    var name: String {
        switch self {
        case .dock: "PrimoDock"
        case .engine: "PrimoEngine"
        case .cleanuai: "CleanUai"
        case .flecha: "Flecha"
        case .recta: "Recta"
        case .rec: "PrimoRec"
        case .notchy: "Notchy"
        }
    }

    var blurb: LocalizedStringKey {
        switch self {
        case .dock: "A Dock with workspaces and live widgets"
        case .engine: "Living wallpapers that pause when nobody's looking"
        case .cleanuai: "A native Mac cleaner with a one-time price"
        case .flecha: "An open source browser for developers"
        case .recta: "Personal and household finances in one place"
        case .rec: "Shoot landscape, post vertical, on iPhone"
        case .notchy: "A teleprompter in your Mac's notch"
        }
    }

    /// Mac bundle identifiers, newest first. Recta and PrimoRec aren't Mac apps.
    private var bundleIDs: [String] {
        switch self {
        case .dock: ["dev.oprimo.PrimoDock"]
        case .engine: ["dev.oprimo.PrimoEngine", "com.livewallpaper.app"]
        case .cleanuai: ["dev.oprimo.cleanuai"]
        case .flecha: ["dev.oprimo.flecha.browser"]
        case .notchy: ["dev.oprimo.notchyPrompter"]
        case .recta, .rec: []
        }
    }

    /// Notchy has no site yet; its repository stands in.
    var hasSite: Bool { self != .notchy }

    var site: URL {
        let pt = Bundle.main.preferredLocalizations.first?.hasPrefix("pt") == true
        let address = switch self {
        case .dock: pt ? "https://dock.oprimo.dev/" : "https://dock.oprimo.dev/en/"
        case .engine: pt ? "https://engine.oprimo.dev/" : "https://engine.oprimo.dev/en/"
        case .cleanuai: pt ? "https://clean.oprimo.dev/" : "https://clean.oprimo.dev/en/"
        case .flecha: pt ? "https://flecha.dev/pt-br/" : "https://flecha.dev/"
        case .recta: "https://www.recta.app/"
        case .rec: pt ? "https://rec.oprimo.dev/" : "https://rec.oprimo.dev/en/"
        case .notchy: "https://github.com/lucianodiisouza/notchy-desktop-macos"
        }
        return URL(string: address)!
    }

    var installedURL: URL? {
        bundleIDs.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
    }

    var icon: NSImage? {
        Bundle.main.url(forResource: "primo-\(iconName)", withExtension: "png").flatMap(NSImage.init(contentsOf:))
    }

    /// These icons fill their whole square (iPhone, Windows or web icons).
    /// The rest already carry the Mac icon's margin and rounded body.
    var iconIsFullBleed: Bool { [.dock, .engine, .recta, .rec].contains(self) }

    private var iconName: String {
        switch self {
        case .dock: "primodock"
        case .engine: "primoengine"
        case .rec: "primorec"
        default: rawValue
        }
    }

    func open() {
        if let app = installedURL {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(site)
        }
    }
}

/// One row per app: icon, name, a line about it and what a click does.
struct PrimoAppsList: View {
    @State private var installed: Set<PrimoApp> = []

    var body: some View {
        VStack(spacing: 0) {
            ForEach(PrimoApp.allCases) { app in
                if app != PrimoApp.allCases.first { Divider().padding(.leading, 52) }
                PrimoAppRow(app: app, isInstalled: installed.contains(app))
            }
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    private func refresh() {
        installed = Set(PrimoApp.allCases.filter { $0.installedURL != nil })
    }
}

private struct PrimoAppRow: View {
    let app: PrimoApp
    let isInstalled: Bool
    @State private var hovering = false

    private var action: LocalizedStringKey {
        if isInstalled { return "Open" }
        return app.hasSite ? "Website" : "GitHub"
    }

    var body: some View {
        Button(action: app.open) {
            HStack(spacing: 12) {
                icon.frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: app.name).fontWeight(.medium)
                    Text(app.blurb).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 3) {
                    Text(action)
                    Image(systemName: isInstalled ? "arrow.up.forward.app" : "arrow.up.right")
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(hovering ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Color.primary.opacity(0.05) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: app.name))
        .accessibilityValue(Text(app.blurb))
        .accessibilityHint(Text(action))
        .accessibilityAddTraits(.isButton)
    }

    /// Full-bleed icons get the Mac grid's margin (about 10%) and its
    /// continuous corner, so all seven read as the same size and shape.
    @ViewBuilder private var icon: some View {
        let inset: CGFloat = 36 * 0.1
        if let image = app.icon {
            if app.iconIsFullBleed {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .clipShape(RoundedRectangle(cornerRadius: (36 - inset * 2) * 0.225, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
                    .padding(inset)
            } else {
                Image(nsImage: image).resizable().interpolation(.high)
            }
        } else {
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.quaternary).padding(inset)
        }
    }
}
