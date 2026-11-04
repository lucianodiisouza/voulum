import SwiftUI

/// Inline equalizer for one app: a live response curve you shape by dragging
/// the ten band handles, plus presets.
struct EQPanel: View {
    let app: AudioApp
    @EnvironmentObject private var engine: AudioEngine
    @EnvironmentObject private var prefs: Preferences
    @Environment(\.deskStyle) private var desk

    @State private var savingName: String?
    @FocusState private var nameFocused: Bool

    private var eq: EQSettings { engine.settings(app.key).eq }

    private func setBand(_ band: Int, _ gain: Float) {
        update {
            $0.enabled = true
            $0.gains[band] = gain
            $0.presetID = nil
        }
    }

    private func update(_ change: (inout EQSettings) -> Void) {
        var value = eq
        change(&value)
        engine.setEQ(value, for: app)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if desk {
                GraphicEQ(settings: eq) { band, gain in setBand(band, gain) }
                    .frame(height: 132)
            } else {
                EQCurve(settings: eq) { band, gain in setBand(band, gain) }
                    .frame(height: 112)
            }
            if let name = savingName {
                saveRow(name)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(desk ? Color.black.opacity(0.3) : Color.primary.opacity(0.05)))
    }

    private var header: some View {
        HStack(spacing: 8) {
            if desk {
                DeskTab(title: String(localized: "Equalizer"), selected: eq.enabled) {
                    update { $0.enabled.toggle() }
                }
            } else {
                Toggle(isOn: Binding(get: { eq.enabled }, set: { on in update { $0.enabled = on } })) {
                    Text("Equalizer").font(.subheadline.weight(.semibold))
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
            }

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
        return eq.isFlat ? EQPreset.flat.name : String(localized: "Custom")
    }

    @ViewBuilder private var presetMenuItems: some View {
        ForEach(EQPreset.Category.allCases.filter { $0 != .user }, id: \.self) { category in
            Section(category.title) {
                ForEach(EQPreset.builtIn.filter { $0.category == category }) { preset in
                    presetButton(preset)
                }
            }
        }
        if !prefs.userPresets.isEmpty {
            Section(EQPreset.Category.user.title) {
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

/// The desk style's equalizer: a graphic EQ, one vertical fader per band,
/// like the front of an old hi-fi. Same bands, same ±12 dB, 0.5 dB steps.
struct GraphicEQ: View {
    let settings: EQSettings
    let onChange: (Int, Float) -> Void

    @State private var activeBand: Int?
    private let labelHeight: CGFloat = 14
    private let scaleWidth: CGFloat = 22
    private let cap = CGSize(width: 18, height: 11)

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height - labelHeight
            let column = (geo.size.width - scaleWidth) / CGFloat(EQBand.count)
            HStack(spacing: 0) {
                scale(height: height)
                ForEach(0..<EQBand.count, id: \.self) { band in
                    fader(band, height: height, width: column)
                        .frame(width: column)
                }
            }
        }
        .opacity(settings.enabled ? 1 : 0.55)
    }

    /// The dB marks down the left, printed like silkscreen.
    private func scale(height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach([12, 0, -12], id: \.self) { db in
                Text(verbatim: db > 0 ? "+\(db)" : "\(db)")
                    .font(.system(size: 7.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(db == 0 ? AnyShapeStyle(Color.deskAmber) : AnyShapeStyle(.tertiary))
                    .fixedSize()
                    .position(x: scaleWidth / 2 - 2, y: y(for: Float(db), height: height))
            }
        }
        .frame(width: scaleWidth, height: height)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func fader(_ band: Int, height: CGFloat, width: CGFloat) -> some View {
        let gain = settings.gains[band]
        let active = activeBand == band
        return VStack(spacing: 0) {
            ZStack {
                ForEach([12, 6, 0, -6, -12], id: \.self) { db in
                    Rectangle()
                        .fill(db == 0 ? Color.deskAmber.opacity(0.7) : Color.white.opacity(0.13))
                        .frame(width: db == 0 ? 20 : 14, height: 1)
                        .position(x: width / 2, y: y(for: Float(db), height: height))
                }
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.black)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
                    .frame(width: 4, height: height - cap.height)
                DeskFaderCap(muted: !settings.enabled, pressed: active, vertical: true)
                    .frame(width: cap.width, height: cap.height)
                    .position(x: width / 2, y: y(for: gain, height: height))
                if active {
                    Text(String(format: "%+.1f", gain))
                        .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.deskAmber)
                        .fixedSize()
                        .position(x: width / 2, y: max(5, y(for: gain, height: height) - cap.height))
                }
            }
            .frame(height: height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        activeBand = band
                        onChange(band, gainAt(y: g.location.y, height: height))
                    }
                    .onEnded { _ in activeBand = nil }
            )
            .onTapGesture(count: 2) { onChange(band, 0) }
            .help("\(EQBand.label(band)) Hz: \(String(format: "%+.1f", gain)) dB. Double-click to reset.")

            Text(EQBand.label(band))
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize()
                .frame(height: labelHeight)
        }
    }

    private func y(for db: Float, height: CGFloat) -> CGFloat {
        let r = EQBand.range.upperBound
        let t = CGFloat((r - max(-r, min(r, db))) / (2 * r))
        return cap.height / 2 + t * (height - cap.height)
    }

    private func gainAt(y: CGFloat, height: CGFloat) -> Float {
        let r = EQBand.range.upperBound
        let t = Float((y - cap.height / 2) / (height - cap.height))
        return (min(r, max(-r, r - t * 2 * r)) * 2).rounded() / 2
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
