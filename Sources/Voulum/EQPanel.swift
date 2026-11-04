import SwiftUI

/// Inline equalizer for one app: a live response curve you shape by dragging
/// the ten band handles, plus presets.
struct EQPanel: View {
    let app: AudioApp
    @EnvironmentObject private var engine: AudioEngine
    @EnvironmentObject private var prefs: Preferences

    @State private var savingName: String?
    @FocusState private var nameFocused: Bool

    private var eq: EQSettings { engine.settings(app.key).eq }

    private func update(_ change: (inout EQSettings) -> Void) {
        var value = eq
        change(&value)
        engine.setEQ(value, for: app)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            EQCurve(settings: eq) { band, gain in
                update {
                    $0.enabled = true
                    $0.gains[band] = gain
                    $0.presetID = nil
                }
            }
            .frame(height: 112)
            if let name = savingName {
                saveRow(name)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(get: { eq.enabled }, set: { on in update { $0.enabled = on } })) {
                Text("Equalizer").font(.subheadline.weight(.semibold))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)

            Spacer()

            Menu {
                presetMenuItems
            } label: {
                Text(presetName).font(.subheadline)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            IconButton(systemName: "arrow.counterclockwise", help: "Flatten all bands", size: 22) {
                update { $0.gains = Array(repeating: 0, count: EQBand.count); $0.presetID = EQPreset.flat.id }
            }
            .disabled(eq.isFlat)
        }
    }

    private var presetName: String {
        if let preset = prefs.preset(id: eq.presetID) { return preset.name }
        return eq.isFlat ? EQPreset.flat.name : "Custom"
    }

    @ViewBuilder private var presetMenuItems: some View {
        ForEach(EQPreset.Category.allCases.filter { $0 != .user }, id: \.self) { category in
            Section(category.rawValue) {
                ForEach(EQPreset.builtIn.filter { $0.category == category }) { preset in
                    presetButton(preset)
                }
            }
        }
        if !prefs.userPresets.isEmpty {
            Section(EQPreset.Category.user.rawValue) {
                ForEach(prefs.userPresets) { presetButton($0) }
            }
        }
        Divider()
        Button("Save Current as Preset…") {
            savingName = ""
            nameFocused = true
        }
        .disabled(eq.isFlat)
    }

    private func presetButton(_ preset: EQPreset) -> some View {
        Button {
            update {
                $0.gains = preset.gains
                $0.presetID = preset.id
                $0.enabled = true
            }
        } label: {
            if eq.presetID == preset.id {
                Label(preset.name, systemImage: "checkmark")
            } else {
                Text(preset.name)
            }
        }
    }

    private func saveRow(_ name: String) -> some View {
        HStack(spacing: 6) {
            TextField("Preset name", text: Binding(get: { savingName ?? "" }, set: { savingName = $0 }))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .focused($nameFocused)
                .onSubmit(save)
            Button("Save", action: save)
                .controlSize(.small)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel") { savingName = nil }
                .controlSize(.small)
        }
    }

    private func save() {
        let name = (savingName ?? "").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let preset = prefs.saveUserPreset(name: name, gains: eq.gains)
        update { $0.presetID = preset.id }
        savingName = nil
    }
}

/// The response curve. X is frequency (log, 20 Hz–20 kHz), Y is ±12 dB.
struct EQCurve: View {
    let settings: EQSettings
    let onChange: (Int, Float) -> Void

    @State private var activeBand: Int?
    private let labelHeight: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let plot = CGRect(x: 0, y: 0, width: geo.size.width, height: geo.size.height - labelHeight)
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    drawGrid(context, plot)
                    drawCurve(context, plot)
                }
                ForEach(0..<EQBand.count, id: \.self) { band in
                    handle(band, plot)
                }
                ForEach(0..<EQBand.count, id: \.self) { band in
                    Text(EQBand.label(band))
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .position(x: x(for: EQBand.frequencies[band], in: plot), y: plot.maxY + labelHeight / 2 + 1)
                }
            }
        }
        .opacity(settings.enabled ? 1 : 0.55)
    }

    private func handle(_ band: Int, _ plot: CGRect) -> some View {
        let gain = settings.gains[band]
        let isActive = activeBand == band
        return Circle()
            .fill(isActive ? Color.accentColor : Color.white)
            .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
            .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
            .frame(width: isActive ? 13 : 10, height: isActive ? 13 : 10)
            .overlay(alignment: .top) {
                if isActive {
                    Text(String(format: "%+.1f dB", gain))
                        .font(.system(size: 9, weight: .semibold).monospacedDigit())
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(.regularMaterial))
                        .fixedSize()
                        .offset(y: gain > 6 ? 16 : -18)
                }
            }
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .position(x: x(for: EQBand.frequencies[band], in: plot), y: y(for: Double(gain), in: plot))
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { g in
                        activeBand = band
                        onChange(band, gainFor(y: g.location.y, plot: plot))
                    }
                    .onEnded { _ in activeBand = nil }
            )
            .onTapGesture(count: 2) { onChange(band, 0) }
            .help("\(EQBand.label(band)) Hz: \(String(format: "%+.1f", gain)) dB. Double-click to reset.")
    }

    // MARK: Geometry

    private func x(for frequency: Double, in rect: CGRect) -> CGFloat {
        let t = (log10(frequency) - log10(20)) / (log10(20_000) - log10(20))
        return rect.minX + CGFloat(t) * rect.width
    }

    private func y(for db: Double, in rect: CGRect) -> CGFloat {
        let r = Double(EQBand.range.upperBound)
        let t = (r - max(-r, min(r, db))) / (2 * r)
        return rect.minY + 6 + CGFloat(t) * (rect.height - 12)
    }

    private func gainFor(y: CGFloat, plot: CGRect) -> Float {
        let r = EQBand.range.upperBound
        let t = Float((y - plot.minY - 6) / (plot.height - 12))
        let raw = r - t * 2 * r
        return (min(r, max(-r, raw)) * 2).rounded() / 2   // 0.5 dB steps
    }

    // MARK: Drawing

    private func drawGrid(_ context: GraphicsContext, _ plot: CGRect) {
        for db in [-12.0, -6, 0, 6, 12] {
            var line = Path()
            let yy = y(for: db, in: plot)
            line.move(to: CGPoint(x: plot.minX, y: yy))
            line.addLine(to: CGPoint(x: plot.maxX, y: yy))
            context.stroke(line, with: .color(.primary.opacity(db == 0 ? 0.18 : 0.07)),
                           style: StrokeStyle(lineWidth: 1, dash: db == 0 ? [] : [2, 3]))
        }
    }

    private func drawCurve(_ context: GraphicsContext, _ plot: CGRect) {
        let steps = 120
        var curve = Path()
        for i in 0...steps {
            let f = 20 * pow(1_000, Double(i) / Double(steps))
            let db = settings.withEnabled.responseDB(at: f)
            let p = CGPoint(x: x(for: f, in: plot), y: y(for: db, in: plot))
            i == 0 ? curve.move(to: p) : curve.addLine(to: p)
        }
        var fill = curve
        let zero = y(for: 0, in: plot)
        fill.addLine(to: CGPoint(x: plot.maxX, y: zero))
        fill.addLine(to: CGPoint(x: plot.minX, y: zero))
        fill.closeSubpath()
        context.fill(fill, with: .color(.accentColor.opacity(0.14)))
        context.stroke(curve, with: .color(.accentColor), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
    }
}

private extension EQSettings {
    /// The shape the bands describe, drawn even while the EQ is bypassed so the
    /// user can see what turning it on would do.
    var withEnabled: EQSettings {
        var copy = self
        copy.enabled = true
        return copy
    }
}
