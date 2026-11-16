import SwiftUI

func formatDB(_ v: Double) -> String {
    if v == 0 { return "0" }
    let s = v.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f", abs(v)) : String(format: "%.1f", abs(v))
    return (v > 0 ? "+" : "−") + s.replacingOccurrences(of: ".", with: ",")
}

/// Couleur d'une bande paramétrique (point du graphique et pastille).
func bandColor(_ index: Int) -> Color {
    let palette: [Color] = [.blue, .orange, .green, .pink, .purple, .teal, .yellow, .red, .indigo, .mint, .brown, .cyan]
    return palette[index % palette.count]
}

/// Curseur vertical, valeur par pas de 0,5 dB.
struct VerticalSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let label: String
    var tint: Color = .accentColor

    private let thumb: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height, w = geo.size.width
            let usable = max(h - thumb, 1)
            let span = range.upperBound - range.lowerBound
            let y = thumb / 2 + usable * (1 - (value - range.lowerBound) / span)
            let zeroY = thumb / 2 + usable * (1 - (0 - range.lowerBound) / span)
            ZStack {
                Capsule().fill(.quaternary)
                    .frame(width: 4, height: h)
                    .position(x: w / 2, y: h / 2)
                Rectangle().fill(.tertiary)
                    .frame(width: 12, height: 1)
                    .position(x: w / 2, y: zeroY)
                Capsule().fill(tint)
                    .frame(width: 4, height: max(abs(y - zeroY), 1))
                    .position(x: w / 2, y: (y + zeroY) / 2)
                Circle().fill(.white)
                    .overlay(Circle().strokeBorder(.black.opacity(0.15), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                    .frame(width: thumb, height: thumb)
                    .position(x: w / 2, y: y)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { g in
                    let f = min(max(1 - (g.location.y - thumb / 2) / usable, 0), 1)
                    value = ((range.lowerBound + f * span) * 2).rounded() / 2
                }
            )
        }
        .accessibilityElement()
        .accessibilityLabel(Text(label))
        .accessibilityValue("\(formatDB(value)) décibels")
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 0.5 : -0.5
            value = min(max(value + step, range.lowerBound), range.upperBound)
        }
    }
}

/// Champ numérique compact avec libellé et unité ; la valeur saisie est bornée.
struct NumberField: View {
    let label: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    var unit = ""
    var fraction = 1
    var width: CGFloat = 58

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 3) {
                // Pas de texte indicatif : sinon le libellé s'affiche, tronqué, quand le champ est vidé.
                TextField("", value: Binding(get: { value }, set: { value = $0.clamped(to: range) }),
                          format: .number.precision(.fractionLength(0...fraction)))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: width)
                    .accessibilityLabel(Text(label))
                if !unit.isEmpty {
                    Text(unit).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Interroge le limiteur dix fois par seconde tant que la fenêtre est visible.
final class LimiterMeter: ObservableObject {
    @Published private(set) var active = false
    private var timer: Timer?
    private var lastHit = Date.distantPast

    func start(_ processor: EQProcessor) {
        stop()
        _ = processor.takeLimiterGain()
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            // Plus de 0,5 dB de réduction : le limiteur travaille.
            if processor.takeLimiterGain() < 0.944 { self.lastHit = Date() }
            // Reste allumé un instant pour rester lisible.
            let on = Date().timeIntervalSince(self.lastHit) < 0.6
            if on != self.active { self.active = on }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        active = false
    }
}

/// Enki Audio est en version bêta : signalée dans la vue rapide, la fenêtre et « À propos ».
enum AppInfo {
    static let isBeta = true
}

/// Petite pastille « Bêta ».
struct BetaBadge: View {
    var body: some View {
        if AppInfo.isBeta {
            Text("Bêta")
                .font(.caption2.weight(.bold))
                .textCase(.uppercase)
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 6).padding(.vertical, 1.5)
                .background(Color.accentColor.opacity(0.12), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.35)))
                .help("Version bêta : l'app est encore en test. Vos retours sont les bienvenus.")
                .accessibilityLabel("Version bêta")
        }
    }
}
