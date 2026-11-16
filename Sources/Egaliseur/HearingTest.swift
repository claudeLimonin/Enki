import AVFoundation
import SwiftUI

/// Générateur de bips intermittents (sinus), joué directement sur la sortie :
/// l'app est exclue de sa propre capture, le son du test ne passe donc pas par l'égaliseur.
final class TonePlayer {
    private let engine = AVAudioEngine()
    private var node: AVAudioSourceNode?
    // Lus par le thread audio ; écrits depuis le thread principal (valeurs simples).
    private var frequency = 1000.0
    private var amplitude = 0.0
    private var playing = false
    private var phase = 0.0
    private var time = 0.0
    private var envelope = 0.0

    func start() {
        guard node == nil else { return }
        let format = engine.outputNode.inputFormat(forBus: 0)
        let rate = format.sampleRate > 0 ? format.sampleRate : 48_000
        let mono = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let source = AVAudioSourceNode(format: mono) { [unowned self] _, _, count, data in
            let buffers = UnsafeMutableAudioBufferListPointer(data)
            guard let out = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let step = 2 * Double.pi * self.frequency / rate
            for i in 0..<Int(count) {
                // Bip de 0,4 s toutes les 0,8 s, fondu de 10 ms (pas de clic).
                let on = self.playing && self.time.truncatingRemainder(dividingBy: 0.8) < 0.4
                let target = on ? self.amplitude : 0
                self.envelope += (target - self.envelope) * (1 / (0.010 * rate))
                out[i] = Float(sin(self.phase) * self.envelope)
                self.phase = (self.phase + step).truncatingRemainder(dividingBy: 2 * Double.pi)
                self.time += 1 / rate
            }
            for b in buffers.dropFirst() {
                if let d = b.mData { memcpy(d, out, Int(b.mDataByteSize)) }
            }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: mono)
        node = source
        try? engine.start()
    }

    func play(frequency: Double, levelDB: Double) {
        self.frequency = frequency
        amplitude = pow(10, levelDB / 20)
        if !playing { time = 0 }
        playing = true
    }

    func silence() { playing = false }

    func stop() {
        playing = false
        engine.stop()
        if let node { engine.detach(node) }
        node = nil
    }
}

/// Déroulé du test et calcul de la courbe de compensation.
final class HearingTest: ObservableObject {
    static let frequencies: [Double] = [250, 500, 1000, 2000, 3000, 4000, 6000, 8000]
    static let levelRange: ClosedRange<Double> = -90 ... -10

    enum Phase: Equatable { case intro, measuring(Int), result }

    @Published var phase: Phase = .intro
    /// Niveau du bip en cours (dB, relatif au maximum de la sortie).
    @Published var level = -50.0 { didSet { replay() } }
    @Published private(set) var thresholds: [Double] = []
    let player = TonePlayer()

    func begin() {
        thresholds = []
        player.start()
        measure(0)
    }

    private func measure(_ i: Int) {
        phase = .measuring(i)
        level = -50
        replay()
    }

    private func replay() {
        if case .measuring(let i) = phase {
            player.play(frequency: Self.frequencies[i], levelDB: level)
        }
    }

    /// Valide le seuil pour la fréquence en cours.
    func next() {
        guard case .measuring(let i) = phase else { return }
        thresholds.append(level)
        if i + 1 < Self.frequencies.count {
            measure(i + 1)
        } else {
            player.silence()
            phase = .result
        }
    }

    func previous() {
        guard case .measuring(let i) = phase, i > 0 else { return }
        thresholds.removeLast()
        measure(i - 1)
    }

    func stop() { player.stop() }

    /// Gains de compensation : on renforce les fréquences entendues moins bien que la médiane
    /// (de la moitié de l'écart, au plus +10 dB) et on atténue à peine celles entendues mieux.
    var compensation: [Double] {
        guard thresholds.count == Self.frequencies.count else { return [] }
        let median = thresholds.sorted()[thresholds.count / 2]
        return thresholds.map { (($0 - median) * 0.5).clamped(to: -3...10).rounded(toPlaces: 1) }
    }

    func preset(named name: String) -> EQPreset {
        let filters = zip(Self.frequencies, compensation).map { EQFilter(kind: .peak, frequency: $0, gain: $1, q: 1.4) }
        let maxGain = compensation.max() ?? 0
        return EQPreset(name: name, gains: [Double](repeating: 0, count: EQModel.frequencies.count),
                        preamp: -(max(0, maxGain) / 2).rounded(), mode: .parametric, filters: filters)
    }
}

private extension Double {
    func rounded(toPlaces p: Int) -> Double {
        let m = pow(10, Double(p))
        return (self * m).rounded() / m
    }
}

struct HearingTestView: View {
    @EnvironmentObject var model: EQModel
    @StateObject private var test = HearingTest()
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch test.phase {
            case .intro: intro
            case .measuring(let i): measuring(i)
            case .result: result
            }
        }
        .padding(22)
        .frame(width: 460)
        .onDisappear { test.stop() }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Test auditif", systemImage: "ear").font(.title2.bold())
            Text("Le test mesure à quel niveau vous entendez 8 sons, des graves aux aigus. Enki Audio en déduit une courbe qui renforce les fréquences que vous percevez moins bien.")
            VStack(alignment: .leading, spacing: 6) {
                Label("Mettez le casque ou les écouteurs que vous utilisez d'habitude.", systemImage: "headphones")
                Label("Installez-vous au calme.", systemImage: "speaker.slash")
                Label("Réglez le volume du Mac à votre niveau d'écoute habituel, et ne le changez plus pendant le test.", systemImage: "speaker.wave.2")
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            Text("Durée : environ 2 minutes. Les sons commencent très bas.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Annuler", action: close).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Commencer") { test.begin() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func measuring(_ i: Int) -> some View {
        let f = HearingTest.frequencies[i]
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Son \(i + 1) sur \(HearingTest.frequencies.count)").font(.headline)
                Spacer()
                Text(f >= 1000 ? "\(Int(f / 1000)) kHz" : "\(Int(f)) Hz")
                    .font(.headline.monospacedDigit()).foregroundStyle(.secondary)
            }
            ProgressView(value: Double(i), total: Double(HearingTest.frequencies.count))
            Text("Réglez le curseur pour que le bip soit **tout juste audible** : baissez-le jusqu'à ne plus l'entendre, puis remontez doucement jusqu'à ce qu'il réapparaisse.")
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                Slider(value: $test.level, in: HearingTest.levelRange, step: 1)
                Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
            }
            HStack {
                Button("Arrêter", action: close).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Précédent") { test.previous() }.disabled(i == 0)
                Button(i + 1 == HearingTest.frequencies.count ? String(localized: "Voir le résultat") : String(localized: "Je l'entends tout juste")) { test.next() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var result: some View {
        let gains = test.compensation
        return VStack(alignment: .leading, spacing: 12) {
            Label("Votre courbe", systemImage: "checkmark.circle.fill").font(.title2.bold()).foregroundStyle(.primary)
            Text("Les barres montrent le renfort proposé pour chaque zone. Plus une barre est haute, moins vous entendiez ce son.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(Array(zip(HearingTest.frequencies, gains).enumerated()), id: \.offset) { _, pair in
                    VStack(spacing: 4) {
                        Text(formatDB(pair.1)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(pair.1 >= 0 ? Color.accentColor : Color.secondary)
                            .frame(height: max(3, abs(pair.1) * 9))
                        Text(pair.0 >= 1000 ? "\(Int(pair.0 / 1000))k" : "\(Int(pair.0))").font(.caption2)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 120, alignment: .bottom)
            Text("Ce n'est pas un diagnostic médical. En cas de gêne auditive, consultez un professionnel.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Refaire le test") { test.begin() }
                Spacer()
                Button("Fermer", action: close).keyboardShortcut(.cancelAction)
                Button("Appliquer « Mon audition »") {
                    let base = String(localized: "Mon audition")
                    var name = base
                    var n = 2
                    while model.validateName(name) != nil { name = "\(base) \(n)"; n += 1 }
                    let p = test.preset(named: name)
                    model.addUserPreset(p)
                    model.apply(p)
                    close()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// Fenêtre du test auditif (une seule à la fois).
enum HearingTestWindow {
    private static var window: NSWindow?

    static func show(model: EQModel) {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = String(localized: "Test auditif")
        w.isReleasedWhenClosed = false
        w.contentViewController = NSHostingController(rootView:
            HearingTestView(close: { w.close() }).environmentObject(model))
        w.center()
        window = w
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            // Libère la vue (et coupe le son du test).
            DispatchQueue.main.async {
                window?.contentViewController = nil
                window = nil
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}
