import Accelerate
import Foundation

/// Analyse d'une mesure de haut-parleurs : réponse en fréquence et correction proposée.
/// Aucun accès au son ici (fonctions pures, testables).
enum SpeakerAnalysis {
    /// Balayage : de 20 Hz à 20 kHz, fréquence qui croît de façon exponentielle (même énergie par octave).
    static let sweepRange = (low: 20.0, high: 20_000.0)
    static let sweepDuration = 8.0
    /// Silence avant (mesure du bruit de fond) et après (écho de la pièce).
    static let leadIn = 0.6, tail = 1.0
    /// Niveau du balayage (−12 dBFS) : assez fort pour dominer le bruit, sans saturer.
    static let sweepLevel: Float = 0.25

    /// Zone de correction : le micro d'un iPhone est fiable entre ces fréquences, et des
    /// haut-parleurs de portable ne descendent pas plus bas. Hors zone, aucune correction.
    static let correctionBand = (low: 100.0, high: 10_000.0)
    /// Correction prudente : on baisse volontiers les pics, on remonte peu les creux.
    static let maxCut = -9.0, maxBoost = 4.0
    /// Pas de renfort sous cette fréquence : les haut-parleurs d'un portable ne descendent pas
    /// plus bas, les pousser ne ferait que saturer (on se contente de baisser les résonances).
    static let minBoostFrequency = 150.0
    /// Filtres assez larges pour une correction douce (pas de pics étroits qui se contredisent).
    static let maxQ = 2.5
    static let maxFilters = 8
    /// En dessous de ce rapport signal/bruit (dB), la mesure n'est pas fiable.
    static let minSNR = 15.0

    /// Points d'analyse : 1/12 d'octave de 20 Hz à 20 kHz.
    static let frequencies: [Double] = stride(from: 0.0, through: 10 * 12, by: 1).map { 20 * pow(2, $0 / 12) }.filter { $0 <= 20_000 }

    // MARK: Balayage

    /// Signal joué : silence, balayage avec fondu, silence.
    static func testSignal(sampleRate: Double) -> [Float] {
        let n = Int(sweepDuration * sampleRate)
        let k = log(sweepRange.high / sweepRange.low)
        let fade = Int(0.05 * sampleRate)
        var sweep = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let phase = 2 * Double.pi * sweepRange.low * sweepDuration / k * (exp(t * k / sweepDuration) - 1)
            var g = 1.0
            if i < fade { g = Double(i) / Double(fade) }
            if i > n - fade { g = Double(n - i) / Double(fade) }
            sweep[i] = sweepLevel * Float(sin(phase) * g)
        }
        return [Float](repeating: 0, count: Int(leadIn * sampleRate)) + sweep + [Float](repeating: 0, count: Int(tail * sampleRate))
    }

    // MARK: Spectre

    /// Énergie par bande d'un tiers d'octave, centrée sur chaque point d'analyse.
    static func bandEnergies(_ samples: [Float], sampleRate: Double) -> [Double] {
        let log2n = vDSP_Length(ceil(log2(Double(max(samples.count, 2)))))
        let n = 1 << Int(log2n)
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }
        var padded = samples + [Float](repeating: 0, count: n - samples.count)
        var real = [Float](repeating: 0, count: n / 2), imag = [Float](repeating: 0, count: n / 2)
        var power = [Float](repeating: 0, count: n / 2)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                padded.withUnsafeMutableBufferPointer { pp in
                    pp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(n / 2))
            }
        }
        // Somme cumulée : énergie d'une bande en deux lectures.
        var cumulative = [Double](repeating: 0, count: n / 2 + 1)
        for i in 0..<(n / 2) { cumulative[i + 1] = cumulative[i] + Double(power[i]) }
        let binHz = sampleRate / Double(n)
        let half = pow(2, 1.0 / 6)   // ± 1/6 d'octave = largeur d'un tiers d'octave
        return frequencies.map { f in
            let a = min(max(Int(f / half / binHz), 1), n / 2), b = min(max(Int(f * half / binHz) + 1, a + 1), n / 2)
            return (cumulative[b] - cumulative[a]) / Double(b - a)
        }
    }

    // MARK: Mesure

    struct Response {
        /// Réponse mesurée (dB) aux points d'analyse, ramenée à 0 dB en moyenne entre 300 Hz et 3 kHz.
        var levels: [Double]
        /// Rapport signal/bruit (dB) : niveau pendant le balayage comparé au silence qui le précède.
        var snr: Double
        /// L'enregistrement a saturé (crête au plafond).
        var clipped: Bool
        var reliable: Bool { snr >= SpeakerAnalysis.minSNR && !clipped }
    }

    /// Réponse des haut-parleurs : ce que le micro a entendu, divisé par ce qui a été joué.
    /// Plusieurs enregistrements du même balayage sont moyennés.
    static func response(played: [Float], playedRate: Double, recordings: [[Float]], recordedRate: Double) -> Response? {
        guard !recordings.isEmpty else { return nil }
        let reference = bandEnergies(played, sampleRate: playedRate)
        var sum = [Double](repeating: 0, count: frequencies.count)
        var snrs: [Double] = [], clipped = false
        for rec in recordings {
            let lead = Int(leadIn * recordedRate * 0.8)
            guard rec.count > lead * 2 else { return nil }
            let noise = rms(rec[0..<lead]), signal = rms(rec[lead...])
            snrs.append(20 * log10(max(signal, 1e-9) / max(noise, 1e-9)))
            if rec.contains(where: { abs($0) >= 0.999 }) { clipped = true }
            let e = bandEnergies(rec, sampleRate: recordedRate)
            for i in sum.indices { sum[i] += e[i] / max(reference[i], 1e-30) }
        }
        var levels = sum.map { 10 * log10(max($0 / Double(recordings.count), 1e-30)) }
        let mid = frequencies.indices.filter { frequencies[$0] >= 300 && frequencies[$0] <= 3000 }
        let offset = mid.map { levels[$0] }.reduce(0, +) / Double(max(mid.count, 1))
        levels = levels.map { $0 - offset }
        return Response(levels: levels, snr: snrs.min() ?? 0, clipped: clipped)
    }

    private static func rms(_ s: ArraySlice<Float>) -> Double {
        guard !s.isEmpty else { return 0 }
        return (s.reduce(0) { $0 + Double($1) * Double($1) } / Double(s.count)).squareRoot()
    }

    // MARK: Correction

    /// Poids de la zone de correction : 1 dans la zone, fondu sur une demi-octave à chaque bout.
    static func weight(_ f: Double) -> Double {
        let lo = log2(f / correctionBand.low), hi = log2(correctionBand.high / f)
        return min(max(min(lo, hi) * 2 + 1, 0), 1)
    }

    /// Renfort permis à une fréquence : nul sous 150 Hz, puis progressif jusqu'à 300 Hz
    /// (une limite brusque créerait une marche que les filtres essaieraient de suivre).
    static func boostLimit(_ f: Double) -> Double {
        maxBoost * min(max(log2(f / minBoostFrequency), 0), 1)
    }

    /// Correction visée en chaque point : l'inverse de l'écart mesuré, bornée et limitée à la zone fiable.
    static func target(for levels: [Double]) -> [Double] {
        zip(frequencies, levels).map { f, l in (-l * weight(f)).clamped(to: maxCut...boostLimit(f)) }
    }

    /// Correction sous forme de filtres en cloche (8 au plus), ajustés un par un sur le plus grand écart restant.
    static func fitCorrection(levels: [Double], sampleRate: Double = 48_000) -> HeadphoneProfile {
        let goal = target(for: levels)
        var filters: [EQFilter] = []
        func residual() -> [Double] {
            frequencies.indices.map { goal[$0] - EQMath.responseDB(filters, at: frequencies[$0], sampleRate: sampleRate) }
        }
        for _ in 0..<maxFilters {
            let r = residual()
            // Un seul filtre par tiers d'octave : pas de filtres empilés qui se contredisent.
            let candidates = frequencies.indices.filter { i in
                weight(frequencies[i]) > 0.5
                    && filters.allSatisfy { abs(log2($0.frequency / frequencies[i])) >= 1.0 / 3 }
            }
            guard let i = candidates.max(by: { abs(r[$0]) < abs(r[$1]) }), abs(r[i]) >= 1 else { break }
            // Largeur : là où l'écart retombe à la moitié, de part et d'autre.
            var a = i, b = i
            while a > 0, abs(r[a - 1]) > abs(r[i]) / 2, r[a - 1].sign == r[i].sign { a -= 1 }
            while b < r.count - 1, abs(r[b + 1]) > abs(r[i]) / 2, r[b + 1].sign == r[i].sign { b += 1 }
            let octaves = max(log2(frequencies[b] / frequencies[a]), 1.0 / 6)
            let q = (pow(2, octaves).squareRoot() / (pow(2, octaves) - 1)).clamped(to: 0.7...maxQ)
            let gain = (r[i] * 0.9).clamped(to: maxCut...boostLimit(frequencies[i]))
            guard abs(gain) >= 1 else { break }
            filters.append(EQFilter(kind: .peak, frequency: frequencies[i], gain: gain, q: q))
        }
        filters.sort { $0.frequency < $1.frequency }
        // Préampli : les renforts ne doivent pas faire saturer.
        let peak = frequencies.map { EQMath.responseDB(filters, at: $0, sampleRate: sampleRate) }.max() ?? 0
        return HeadphoneProfile(name: "", preamp: -max(peak, 0), filters: filters)
    }

    /// Écart restant (dB, moyenne des valeurs absolues dans la zone) après correction.
    static func flatness(levels: [Double], correction: HeadphoneProfile, sampleRate: Double = 48_000) -> Double {
        let idx = frequencies.indices.filter { weight(frequencies[$0]) >= 1 }
        guard !idx.isEmpty else { return 0 }
        return idx.map { abs(levels[$0] + EQMath.responseDB(correction.filters, at: frequencies[$0], sampleRate: sampleRate)) }
            .reduce(0, +) / Double(idx.count)
    }
}
