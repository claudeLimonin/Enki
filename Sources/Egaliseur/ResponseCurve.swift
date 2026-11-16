import SwiftUI

/// Courbe de réponse + spectre en temps réel. Isolée dans sa propre vue pour que
/// les 30 rafraîchissements par seconde ne redessinent pas toute la fenêtre.
struct SpectrumPanel: View {
    @EnvironmentObject var model: EQModel
    @StateObject private var analyzer = SpectrumAnalyzer()
    @Binding var selectedBand: UUID?
    /// Version compacte (vue rapide) : ni repères, ni étiquettes, ni points déplaçables.
    var compact = false

    var body: some View {
        ResponseCurve(
            settings: model.settings,
            correction: model.correctionEnabled && model.showCorrectionLayer ? (model.correction?.filters ?? []) : [],
            sampleRate: model.sampleRate,
            active: model.enabled,
            spectrum: model.showSpectrum || compact ? analyzer.levels : [],
            selected: selectedBand,
            onSelect: { selectedBand = $0 },
            onMove: { id, f, g in
                guard let i = model.filters.firstIndex(where: { $0.id == id }) else { return }
                model.filters[i].frequency = f
                model.filters[i].gain = g
            },
            onAdd: { f, g in
                if let id = model.addBand(at: f, gain: g) { selectedBand = id }
            },
            onDragEnd: { model.sortBands() },
            levelerDB: model.leveler > 0 ? analyzer.levelerDB : nil,
            levelerName: OutputOptions.levelerNames[model.leveler],
            compact: compact)
            .onAppear { startIfNeeded() }
            .onDisappear { analyzer.stop() }
            .onChange(of: model.enabled) { _, _ in startIfNeeded() }
    }

    private func startIfNeeded() {
        if model.enabled {
            let model = self.model
            analyzer.start(processor: model.engine.processor) { model.sampleRate }
        } else {
            analyzer.stop()
        }
    }
}

/// Courbe de réponse en fréquence de l'égaliseur, avec le spectre en fond.
/// En mode paramétrique, chaque bande est un point déplaçable (fréquence, gain).
struct ResponseCurve: View {
    let settings: EQSettings
    var correction: [EQFilter] = []
    let sampleRate: Double
    let active: Bool
    var spectrum: [Float] = []
    var selected: UUID? = nil
    var onSelect: ((UUID?) -> Void)? = nil
    var onMove: ((UUID, Double, Double) -> Void)? = nil
    var onAdd: ((Double, Double) -> Void)? = nil
    var onDragEnd: (() -> Void)? = nil
    /// Effet actuel du volume nivelé (dB) et nom de son niveau ; nil s'il est coupé.
    var levelerDB: [Double]? = nil
    var levelerName = ""
    var compact = false

    @Environment(\.colorScheme) private var colorScheme
    @State private var dragging: UUID?

    private static let fMin = 20.0, fMax = 20_000.0
    private var parametric: Bool { settings.mode == .parametric }
    /// Même échelle dans les deux modes (±20 dB) : la courbe ne change pas de taille
    /// quand on change de mode. Les points au-delà restent visibles, collés au bord.
    private let dbMax = 20.0
    /// Repères de niveau dessinés en fond.
    private let gridDB: [Double] = [-18, -12, -6, 6, 12, 18]
    private static let gridHz: [(Double, String)] = [(100, "100"), (1000, "1k"), (10_000, "10k")]
    private static let handleRadius: CGFloat = 9

    /// Couleurs de niveau, du bas vers le haut, façon VU-mètre :
    /// vert (faible) → jaune → orange → rouge (pic fort).
    static func levelGradient(dark: Bool) -> Gradient {
        let o = dark ? 0.85 : 0.75
        return Gradient(stops: [
            .init(color: Color(red: 0.20, green: 0.78, blue: 0.35).opacity(o * 0.55), location: 0),
            .init(color: Color(red: 0.20, green: 0.78, blue: 0.35).opacity(o), location: 0.45),
            .init(color: Color(red: 0.98, green: 0.82, blue: 0.10).opacity(o), location: 0.68),
            .init(color: Color(red: 1.00, green: 0.55, blue: 0.10).opacity(o), location: 0.82),
            .init(color: Color(red: 0.95, green: 0.20, blue: 0.18).opacity(o), location: 1),
        ])
    }

    // Conversions entre l'axe du graphique et les valeurs audio.
    private func x(_ f: Double, _ w: CGFloat) -> CGFloat { CGFloat(log(f / Self.fMin) / log(Self.fMax / Self.fMin)) * w }
    private func frequency(_ x: CGFloat, _ w: CGFloat) -> Double {
        let f = Self.fMin * pow(Self.fMax / Self.fMin, Double(min(max(x / max(w, 1), 0), 1)))
        // Arrondi à 3 chiffres significatifs (ex. 1 234 → 1 230 Hz).
        let p = pow(10, floor(log10(f)) - 2)
        return (f / p).rounded() * p
    }
    private func y(_ db: Double, _ h: CGFloat) -> CGFloat { h / 2 - CGFloat(db / dbMax) * h / 2 }
    private func gain(_ y: CGFloat, _ h: CGFloat) -> Double {
        let g = Double((h / 2 - y) / (h / 2)) * dbMax
        return (g * 10).rounded() / 10
    }

    /// Position d'un point de bande : sur la courbe (réponse totale à sa fréquence),
    /// toujours entièrement visible dans le cadre.
    private func handlePoint(_ f: EQFilter, _ size: CGSize) -> CGPoint {
        let r = Self.handleRadius + 1
        let db = EQMath.responseDB(settings.filters, at: f.frequency, sampleRate: sampleRate)
        return CGPoint(x: x(f.frequency, size.width).clamped(to: r...max(r, size.width - r)),
                       y: y(db, size.height).clamped(to: r...max(r, size.height - r)))
    }

    /// Gain de la bande `id` pour que la courbe passe par le point visé (fréquence, niveau).
    private func gainFor(_ id: UUID?, frequency: Double, targetDB: Double) -> Double {
        let band = settings.filters.first { $0.id == id } ?? EQFilter(kind: .peak, frequency: frequency, gain: 0, q: 1)
        let others = settings.filters.filter { $0.id != band.id }
        return (EQMath.bandGain(reaching: targetDB, band: band, at: frequency, others: others, sampleRate: sampleRate) * 10)
            .rounded() / 10
    }

    private func nearestBand(to p: CGPoint, in size: CGSize) -> UUID? {
        let hits = settings.filters.map { f -> (UUID, CGFloat) in
            let c = handlePoint(f, size)
            let dx = c.x - p.x, dy = c.y - p.y
            return (f.id, (dx * dx + dy * dy).squareRoot())
        }
        guard let best = hits.min(by: { $0.1 < $1.1 }), best.1 < 14 else { return nil }
        return best.0
    }

    var body: some View {
        GeometryReader { geo in
            canvas
                .contentShape(Rectangle())
                .gesture(dragGesture(geo.size), including: parametric && !compact && onMove != nil ? .all : .subviews)
                .simultaneousGesture(addGesture(geo.size), including: parametric && !compact && onAdd != nil ? .all : .subviews)
        }
        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
    }

    private func dragGesture(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if dragging == nil {
                    dragging = nearestBand(to: v.startLocation, in: size)
                    if let d = dragging { onSelect?(d) }
                }
                if let id = dragging {
                    // Le point suit la souris sur la courbe : on calcule le gain qui y mène.
                    let f = frequency(v.location.x, size.width).clamped(to: EQFilter.frequencyRange)
                    onMove?(id, f, gainFor(id, frequency: f, targetDB: gain(v.location.y, size.height)))
                }
            }
            .onEnded { v in
                // Clic dans le vide : désélection.
                if dragging == nil, abs(v.translation.width) + abs(v.translation.height) < 3 { onSelect?(nil) }
                // Point lâché : les numéros se remettent dans l'ordre de gauche à droite.
                if dragging != nil { onDragEnd?() }
                dragging = nil
            }
    }

    private func addGesture(_ size: CGSize) -> some Gesture {
        SpatialTapGesture(count: 2).onEnded { e in
            guard nearestBand(to: e.location, in: size) == nil else { return }
            // La nouvelle bande fait passer la courbe par le point double-cliqué.
            let f = frequency(e.location.x, size.width)
            onAdd?(f, gainFor(nil, frequency: f, targetDB: gain(e.location.y, size.height)))
        }
    }

    private var canvas: some View {
        Canvas { ctx, size in
            let dark = colorScheme == .dark
            let w = size.width, h = size.height, mid = h / 2

            // Spectre : barres sur le même axe logarithmique que la courbe.
            if !spectrum.isEmpty {
                let slot = w / CGFloat(spectrum.count)
                let gap = min(2, slot * 0.25)
                let maxH = h * 0.92
                // Un seul dégradé pour toute la hauteur : une barre n'atteint le rouge
                // que si son pic monte jusque-là.
                let shading = GraphicsContext.Shading.linearGradient(
                    Self.levelGradient(dark: dark),
                    startPoint: CGPoint(x: 0, y: h), endPoint: CGPoint(x: 0, y: h - maxH))
                for (i, level) in spectrum.enumerated() where level > 0.005 {
                    let bh = CGFloat(level) * maxH
                    let rect = CGRect(x: CGFloat(i) * slot + gap / 2, y: h - bh, width: slot - gap, height: bh)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: shading)
                }
            }

            // Repères de niveau et de fréquence, très discrets.
            let gridColor = Color.secondary.opacity(0.14)
            let labelColor = Color.secondary.opacity(0.75)
            for db in (compact ? [] : gridDB) {
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y(db, h)))
                line.addLine(to: CGPoint(x: w, y: y(db, h)))
                ctx.stroke(line, with: .color(gridColor), lineWidth: 1)
                // Pas d'étiquette sur les lignes collées au bord (elles seraient coupées).
                guard abs(db) < dbMax - 4 else { continue }
                ctx.draw(Text(db > 0 ? "+\(Int(db))" : "−\(Int(-db))").font(.system(size: 8)).foregroundColor(labelColor),
                         at: CGPoint(x: w - 3, y: y(db, h) - 1), anchor: .bottomTrailing)
            }
            for (f, label) in (compact ? [] : Self.gridHz) {
                var line = Path()
                line.move(to: CGPoint(x: x(f, w), y: 0))
                line.addLine(to: CGPoint(x: x(f, w), y: h))
                ctx.stroke(line, with: .color(gridColor), lineWidth: 1)
                ctx.draw(Text(label).font(.system(size: 8)).foregroundColor(labelColor),
                         at: CGPoint(x: x(f, w) + 3, y: 2), anchor: .topLeading)
            }

            // Repère 0 dB.
            var zero = Path()
            zero.move(to: CGPoint(x: 0, y: mid))
            zero.addLine(to: CGPoint(x: w, y: mid))
            ctx.stroke(zero, with: .color(.secondary.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

            let steps = 180
            func curve(_ filters: [Biquad]) -> Path {
                var p = Path()
                for i in 0...steps {
                    let t = Double(i) / Double(steps)
                    let f = Self.fMin * pow(Self.fMax / Self.fMin, t)
                    let db = filters.reduce(0) { $0 + EQMath.magnitudeDB($1, at: f, sampleRate: sampleRate) }
                    let pt = CGPoint(x: t * w, y: y(db.clamped(to: -dbMax...dbMax), h))
                    i == 0 ? p.move(to: pt) : p.addLine(to: pt)
                }
                return p
            }

            // Correction de casque : pointillés violets.
            if !correction.isEmpty {
                let c = curve(correction.map { EQMath.coefficients($0, sampleRate: sampleRate) })
                ctx.stroke(c, with: .color(Color.purple.opacity(dark ? 0.9 : 0.75)),
                           style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 3]))
            }

            // Égaliseur : courbe pleine, contour clair (ou sombre) dessous pour ressortir sur les barres.
            let main = curve(EQMath.chain(settings, sampleRate: sampleRate))
            var fill = main
            fill.addLine(to: CGPoint(x: w, y: mid))
            fill.addLine(to: CGPoint(x: 0, y: mid))
            fill.closeSubpath()
            let color: Color = active ? (dark ? .white : Color(white: 0.12)) : .secondary
            let halo: Color = dark ? .black.opacity(0.55) : .white.opacity(0.85)
            ctx.fill(fill, with: .color(color.opacity(0.08)))
            ctx.stroke(main, with: .color(halo), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            ctx.stroke(main, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

            // Mode nuit : effet actuel à chaque fréquence (3 bandes : graves, voix, aigus), ajouté à la courbe.
            // Bleu : fréquences abaissées en ce moment ; orange : fréquences renforcées.
            if let gains = levelerDB, gains.count == 3 {
                let night = Color(red: 0.42, green: 0.45, blue: 1.0)
                let lowered = Color(red: 0.30, green: 0.45, blue: 1.0)
                let raised = Color(red: 1.0, green: 0.55, blue: 0.15)
                let eq = EQMath.chain(settings, sampleRate: sampleRate)
                var base: [CGPoint] = [], shifted: [CGPoint] = [], offsets: [Double] = []
                for i in 0...steps {
                    let t = Double(i) / Double(steps)
                    let f = Self.fMin * pow(Self.fMax / Self.fMin, t)
                    let db = eq.reduce(0) { $0 + EQMath.magnitudeDB($1, at: f, sampleRate: sampleRate) }
                    let off = OutputOptions.nightOffsetDB(at: f, gains: gains)
                    base.append(CGPoint(x: t * w, y: y(db.clamped(to: -dbMax...dbMax), h)))
                    shifted.append(CGPoint(x: t * w, y: y((db + off).clamped(to: -dbMax...dbMax), h)))
                    offsets.append(off)
                }
                // Zone entre les deux courbes, colorée tranche par tranche selon le sens de l'effet.
                for i in 0..<steps {
                    let off = (offsets[i] + offsets[i + 1]) / 2
                    guard abs(off) > 0.05 else { continue }
                    var q = Path()
                    q.move(to: base[i]); q.addLine(to: base[i + 1]); q.addLine(to: shifted[i + 1]); q.addLine(to: shifted[i]); q.closeSubpath()
                    ctx.fill(q, with: .color((off < 0 ? lowered : raised).opacity(dark ? 0.32 : 0.24)))
                }
                var line = Path()
                line.addLines(shifted)
                ctx.stroke(line, with: .color(night), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: [5, 3]))

                func fmt(_ v: Double) -> String {
                    String(format: "%+.1f", v).replacingOccurrences(of: ".", with: Locale.current.decimalSeparator ?? ",")
                }
                // Étiquette sur un fond, pour rester lisible par-dessus les repères et le spectre.
                if !compact {
                let label = ctx.resolve(Text("☾ " + String(localized: "Mode nuit (\(levelerName)) · graves \(fmt(gains[0])) · voix \(fmt(gains[1])) · aigus \(fmt(gains[2])) dB"))
                    .font(.system(size: 10, weight: .semibold)).foregroundColor(night))
                let size = label.measure(in: CGSize(width: w, height: 20))
                let origin = CGPoint(x: 6, y: correction.isEmpty ? 5 : 19)
                ctx.fill(Path(roundedRect: CGRect(x: origin.x - 4, y: origin.y - 2, width: size.width + 8, height: size.height + 4),
                              cornerRadius: 5),
                         with: .color(dark ? Color.black.opacity(0.55) : Color.white.opacity(0.85)))
                ctx.draw(label, at: origin, anchor: .topLeading)
                }
            }

            // Points des bandes paramétriques.
            if parametric && !compact {
                for (i, f) in settings.filters.enumerated() {
                    let isSel = f.id == selected
                    let r: CGFloat = isSel ? Self.handleRadius : 7
                    let c = handlePoint(f, size)
                    let dot = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
                    ctx.fill(dot, with: .color(bandColor(i).opacity(f.enabled ? 1 : 0.35)))
                    ctx.stroke(dot, with: .color(isSel ? (dark ? .white : .black) : .white), lineWidth: isSel ? 2 : 1.5)
                    ctx.draw(Text("\(i + 1)").font(.system(size: isSel ? 10 : 9, weight: .bold)).foregroundColor(.white), at: c)
                }
            }

            // Légende de la correction.
            if !correction.isEmpty && !compact {
                ctx.draw(Text("Correction casque").font(.system(size: 9, weight: .medium))
                            .foregroundColor(Color.purple.opacity(0.9)),
                         at: CGPoint(x: 6, y: 5), anchor: .topLeading)
            }
        }
    }
}
