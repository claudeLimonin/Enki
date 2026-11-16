import Accelerate
import Foundation

/// Analyse le son de sortie (FFT) pendant que la fenêtre est visible
/// et publie la hauteur de chaque barre, entre 0 et 1.
final class SpectrumAnalyzer: ObservableObject {
    static let barCount = 48
    /// Mêmes bornes que l'axe de la courbe de réponse.
    static let minFrequency = 20.0
    static let maxFrequency = 20_000.0

    /// Plage affichée, en dBFS (après correction de pente).
    private static let floorDB: Float = -78
    private static let ceilingDB: Float = -12
    /// Remonte les aigus de 3 dB par octave (autour de 1 kHz) : sans ça, la musique
    /// paraît toujours dominée par les basses, car son énergie décroît avec la fréquence.
    private static let tiltPerOctave = 3.0
    /// Vitesse de retombée des barres (fraction de la hauteur par seconde).
    private static let fallPerSecond: Float = 1.4
    private static let fps = 30.0

    @Published private(set) var levels = [Float](repeating: 0, count: barCount)
    /// Effet actuel du mode nuit par bande (graves, voix, aigus), en dB, lissé ; nil s'il est coupé.
    @Published private(set) var levelerDB: [Double]?

    /// 8192 points : ~6 Hz de résolution à 48 kHz, nécessaire pour séparer les graves.
    private let size = 8192
    private let fft: vDSP.DiscreteFourierTransform<Float>
    private let window: [Float]
    private let scale: Float
    private var samples: [Float]
    private let zeros: [Float]
    private var timer: Timer?
    private var lastWritten = -1

    init() {
        fft = try! vDSP.DiscreteFourierTransform(
            count: size, direction: .forward, transformType: .complexComplex, ofType: Float.self)
        // Blackman : fuite vers les fréquences voisines bien plus faible que Hann,
        // sinon une note grave allume toute la moitié gauche du spectre.
        window = vDSP.window(ofType: Float.self, usingSequence: .blackman, count: size, isHalfWindow: false)
        // Une sinusoïde d'amplitude A donne un pic de A·Σfenêtre/2 : on ramène ce pic à A.
        scale = 2 / vDSP.sum(window)
        samples = [Float](repeating: 0, count: size)
        zeros = [Float](repeating: 0, count: size)
    }

    func start(processor: EQProcessor, sampleRate: @escaping () -> Double) {
        stop()
        let t = Timer(timeInterval: 1 / Self.fps, repeats: true) { [weak self] _ in
            self?.tick(processor: processor, sampleRate: sampleRate())
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        levels = [Float](repeating: 0, count: Self.barCount)
        levelerDB = nil
    }

    private func tick(processor: EQProcessor, sampleRate: Double) {
        let written = samples.withUnsafeMutableBufferPointer {
            processor.copyRecentSamples(size, into: $0.baseAddress!)
        }
        // Pas de nouveau son (égaliseur coupé, silence du moteur) : les barres retombent.
        let fresh = written != lastWritten
        lastWritten = written
        let target = fresh ? analyze(sampleRate: sampleRate) : [Float](repeating: 0, count: Self.barCount)

        let fall = Self.fallPerSecond / Float(Self.fps)
        var next = levels
        for i in 0..<Self.barCount {
            // Montée immédiate, descente progressive.
            next[i] = max(target[i], levels[i] - fall)
        }
        if next != levels { levels = next }

        // Volume nivelé : suivi doux (≈ 0,3 s) pour une courbe lisible, qui bouge avec la musique.
        if let target = processor.levelerGainsDB()?.map(Double.init) {
            let shown = levelerDB.map { old in zip(old, target).map { $0 + ($1 - $0) * 0.15 } } ?? target
            if levelerDB == nil || zip(shown, levelerDB!).contains(where: { abs($0 - $1) > 0.02 }) { levelerDB = shown }
        } else if levelerDB != nil {
            levelerDB = nil
        }
    }

    /// Hauteur cible (0…1) de chaque barre pour la fenêtre d'échantillons courante.
    func analyze(sampleRate: Double) -> [Float] {
        let windowed = vDSP.multiply(samples, window)
        let (re, im) = fft.transform(real: windowed, imaginary: zeros)
        let half = size / 2
        var mags = [Float](repeating: 0, count: half)
        for k in 0..<half {
            mags[k] = (re[k] * re[k] + im[k] * im[k]).squareRoot() * scale
        }

        let binWidth = sampleRate / Double(size)
        let ratio = Self.maxFrequency / Self.minFrequency
        var out = [Float](repeating: 0, count: Self.barCount)
        for b in 0..<Self.barCount {
            let f1 = Self.minFrequency * pow(ratio, Double(b) / Double(Self.barCount))
            let f2 = Self.minFrequency * pow(ratio, Double(b + 1) / Double(Self.barCount))
            let fc = (f1 * f2).squareRoot()
            guard fc < sampleRate / 2 else { continue }

            let k1 = Int((f1 / binWidth).rounded(.up))
            let k2 = min(Int((f2 / binWidth).rounded(.down)), half - 1)
            var m: Float
            if k2 >= k1 {
                m = mags[k1...k2].max() ?? 0
            } else {
                // Barre plus étroite qu'un point de la FFT (graves) : interpolation.
                let pos = fc / binWidth
                let i0 = min(Int(pos), half - 2)
                let frac = Float(pos - Double(i0))
                m = mags[i0] * (1 - frac) + mags[i0 + 1] * frac
            }
            let db = 20 * log10(m + 1e-9) + Float(Self.tiltPerOctave * log2(fc / 1000))
            out[b] = min(max((db - Self.floorDB) / (Self.ceilingDB - Self.floorDB), 0), 1)
        }
        return out
    }

    /// Pour les tests : analyse un signal donné plutôt que le son du moteur.
    func analyze(signal: [Float], sampleRate: Double) -> [Float] {
        let offset = signal.count - size
        for i in 0..<size { samples[i] = offset + i >= 0 ? signal[offset + i] : 0 }
        return analyze(sampleRate: sampleRate)
    }
}
