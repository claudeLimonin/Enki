import CoreAudio
import Foundation
import os

/// Coefficients normalisés d'un biquad : [b0, b1, b2, a1, a2].
typealias Biquad = [Double]

/// Calculs de filtres (indépendants du temps réel). Formules : RBJ Audio EQ Cookbook.
enum EQMath {
    /// Largeur des bandes graphiques : assez larges pour une réponse lisse (≈ 1 dB d'ondulation)
    /// une fois compensées, tout en gardant une bande seule à environ une octave.
    static let graphicQ = 0.9
    static let identity: Biquad = [1, 0, 0, 0, 0]

    static func peaking(frequency: Double, gainDB: Double, q: Double = graphicQ, sampleRate: Double) -> Biquad {
        guard gainDB != 0, frequency < sampleRate * 0.49, q > 0 else { return identity }
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cosw = cos(w0)
        let a0 = 1 + alpha / a
        return [(1 + alpha * a) / a0, (-2 * cosw) / a0, (1 - alpha * a) / a0,
                (-2 * cosw) / a0, (1 - alpha / a) / a0]
    }

    static func shelf(high: Bool, frequency: Double, gainDB: Double, q: Double, sampleRate: Double) -> Biquad {
        guard gainDB != 0, frequency < sampleRate * 0.49, q > 0 else { return identity }
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * frequency / sampleRate
        let cosw = cos(w0)
        let alpha = sin(w0) / (2 * q)
        let s = 2 * a.squareRoot() * alpha
        let b0, b1, b2, a0, a1, a2: Double
        if high {
            b0 = a * ((a + 1) + (a - 1) * cosw + s)
            b1 = -2 * a * ((a - 1) + (a + 1) * cosw)
            b2 = a * ((a + 1) + (a - 1) * cosw - s)
            a0 = (a + 1) - (a - 1) * cosw + s
            a1 = 2 * ((a - 1) - (a + 1) * cosw)
            a2 = (a + 1) - (a - 1) * cosw - s
        } else {
            b0 = a * ((a + 1) - (a - 1) * cosw + s)
            b1 = 2 * a * ((a - 1) - (a + 1) * cosw)
            b2 = a * ((a + 1) - (a - 1) * cosw - s)
            a0 = (a + 1) + (a - 1) * cosw + s
            a1 = -2 * ((a - 1) + (a + 1) * cosw)
            a2 = (a + 1) + (a - 1) * cosw - s
        }
        return [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0]
    }

    static func coefficients(_ f: EQFilter, sampleRate: Double) -> Biquad {
        guard f.enabled else { return identity }
        switch f.kind {
        case .peak: return peaking(frequency: f.frequency, gainDB: f.gain, q: f.q, sampleRate: sampleRate)
        case .lowShelf: return shelf(high: false, frequency: f.frequency, gainDB: f.gain, q: f.q, sampleRate: sampleRate)
        case .highShelf: return shelf(high: true, frequency: f.frequency, gainDB: f.gain, q: f.q, sampleRate: sampleRate)
        }
    }

    /// Filtres d'un réglage complet (graphique ou paramétrique), sans les filtres neutres.
    static func chain(_ s: EQSettings, sampleRate: Double) -> [Biquad] {
        let all: [Biquad]
        switch s.mode {
        case .graphic:
            all = graphicFilters(s.gains, sampleRate: sampleRate)
        case .parametric:
            all = s.filters.map { coefficients($0, sampleRate: sampleRate) }
        }
        return all.filter { $0 != identity }
    }

    // MARK: - Égaliseur graphique compensé

    /// Bande `i` de l'égaliseur graphique : plateaux aux extrémités (ils couvrent tout le grave
    /// sous 32 Hz et tout l'aigu au-delà de 16 kHz), cloches d'une octave entre les deux.
    static func graphicBand(_ i: Int, gain: Double, sampleRate: Double) -> Biquad {
        let f = EQModel.frequencies[i]
        if i == 0 { return shelf(high: false, frequency: f * 2.squareRoot(), gainDB: gain, q: 0.7, sampleRate: sampleRate) }
        if i == EQModel.frequencies.count - 1 {
            return shelf(high: true, frequency: f / 2.squareRoot(), gainDB: gain, q: 0.7, sampleRate: sampleRate)
        }
        return peaking(frequency: f, gainDB: gain, sampleRate: sampleRate)
    }

    /// Fréquences où chaque curseur est respecté : le centre de sa bande,
    /// et les bords du spectre pour les deux plateaux.
    static func graphicControlPoints(sampleRate: Double) -> [Double] {
        var p = EQModel.frequencies
        p[0] = 20
        p[p.count - 1] = min(20_000, sampleRate * 0.45)
        return p
    }

    private static var graphicCache: (key: [Double], rate: Double, gains: [Double])?

    static func graphicFilters(_ targets: [Double], sampleRate: Double) -> [Biquad] {
        let gains = graphicInternalGains(targets, sampleRate: sampleRate)
        return gains.indices.map { graphicBand($0, gain: gains[$0], sampleRate: sampleRate) }
    }

    /// Les mêmes filtres que l'égaliseur graphique, sous forme de bandes paramétriques
    /// (même son, même courbe) : sert au passage du mode graphique au mode paramétrique.
    static func graphicAsParametric(_ targets: [Double], sampleRate: Double) -> [EQFilter] {
        let gains = graphicInternalGains(targets, sampleRate: sampleRate)
        let last = gains.count - 1
        return gains.indices.compactMap { i in
            let g = (gains[i] * 10).rounded() / 10
            guard g != 0 else { return nil }
            let f = EQModel.frequencies[i]
            switch i {
            case 0: return EQFilter(kind: .lowShelf, frequency: (f * 2.squareRoot()).rounded(), gain: g, q: 0.7)
            case last: return EQFilter(kind: .highShelf, frequency: (f / 2.squareRoot()).rounded(), gain: g, q: 0.7)
            default: return EQFilter(kind: .peak, frequency: f, gain: g, q: graphicQ)
            }
        }
    }

    /// Les bandes voisines se chevauchent : sans correction, tous les curseurs à −12 dB
    /// donnent environ −18 dB. On calcule donc les gains internes pour que la réponse
    /// réelle passe exactement par la valeur de chaque curseur.
    static func graphicInternalGains(_ targets: [Double], sampleRate: Double) -> [Double] {
        if let c = graphicCache, c.key == targets, c.rate == sampleRate { return c.gains }
        let n = EQModel.frequencies.count
        guard targets.count == n else { return [] }
        let points = graphicControlPoints(sampleRate: sampleRate)

        func response(_ gains: [Double]) -> [Double] {
            let filters = gains.indices.map { graphicBand($0, gain: gains[$0], sampleRate: sampleRate) }
            return points.map { f in filters.reduce(0) { $0 + magnitudeDB($1, at: f, sampleRate: sampleRate) } }
        }

        // Matrice d'interaction : effet de chaque bande (à +6 dB) sur chaque point de contrôle.
        let ref = 6.0
        var matrix = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for j in 0..<n {
            var g = [Double](repeating: 0, count: n)
            g[j] = ref
            let r = response(g)
            for i in 0..<n { matrix[i][j] = r[i] / ref }
        }

        var gains = solve(matrix, targets) ?? targets
        // L'effet en dB n'est pas parfaitement linéaire : quelques passes de correction.
        for _ in 0..<4 {
            let r = response(gains)
            let err = zip(targets, r).map { $0 - $1 }
            if err.allSatisfy({ abs($0) < 0.01 }) { break }
            guard let step = solve(matrix, err) else { break }
            gains = zip(gains, step).map { ($0 + $1).clamped(to: -30...30) }
        }
        graphicCache = (targets, sampleRate, gains)
        return gains
    }

    /// Résolution de A·x = b (élimination de Gauss avec pivot partiel).
    private static func solve(_ a: [[Double]], _ b: [Double]) -> [Double]? {
        let n = b.count
        var m = a
        var v = b
        for col in 0..<n {
            guard let pivot = (col..<n).max(by: { abs(m[$0][col]) < abs(m[$1][col]) }),
                  abs(m[pivot][col]) > 1e-9 else { return nil }
            m.swapAt(col, pivot)
            v.swapAt(col, pivot)
            for row in (col + 1)..<n {
                let factor = m[row][col] / m[col][col]
                for k in col..<n { m[row][k] -= factor * m[col][k] }
                v[row] -= factor * v[col]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var sum = v[row]
            for k in (row + 1)..<n { sum -= m[row][k] * x[k] }
            x[row] = sum / m[row][row]
        }
        return x
    }

    /// Réponse totale (dB) de plusieurs filtres à une fréquence.
    static func responseDB(_ filters: [EQFilter], at frequency: Double, sampleRate: Double) -> Double {
        filters.reduce(0) { $0 + magnitudeDB(coefficients($1, sampleRate: sampleRate), at: frequency, sampleRate: sampleRate) }
    }

    /// Gain à donner à `band`, placée à `frequency`, pour que la courbe totale
    /// (avec les autres bandes) vaille `target` dB à cette fréquence.
    /// Une cloche agit de tout son gain à sa fréquence, un plateau de la moitié : on en tient compte.
    static func bandGain(reaching target: Double, band: EQFilter, at frequency: Double,
                         others: [EQFilter], sampleRate: Double) -> Double {
        let othersDB = responseDB(others, at: frequency, sampleRate: sampleRate)
        var probe = band
        probe.frequency = frequency
        probe.enabled = true
        probe.gain = 6
        let k = magnitudeDB(coefficients(probe, sampleRate: sampleRate), at: frequency, sampleRate: sampleRate) / 6
        guard k > 0.05 else { return band.gain }
        return ((target - othersDB) / k).clamped(to: EQFilter.gainRange)
    }

    /// Gain (dB) d'un filtre à une fréquence donnée.
    static func magnitudeDB(_ c: Biquad, at frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        let c1 = cos(w), c2 = cos(2 * w)
        let num = c[0] * c[0] + c[1] * c[1] + c[2] * c[2] + 2 * (c[0] * c[1] + c[1] * c[2]) * c1 + 2 * c[0] * c[2] * c2
        let den = 1 + c[3] * c[3] + c[4] * c[4] + 2 * (c[3] + c[3] * c[4]) * c1 + 2 * c[4] * c2
        guard num > 0, den > 0 else { return 0 }
        return 10 * log10(num / den)
    }
}

/// Une chaîne de filtres à envoyer au moteur.
struct ChainConfig {
    var filters: [Biquad]
    var preampDB: Double
    static let neutral = ChainConfig(filters: [], preampDB: 0)
}

/// Une chaîne de biquads stéréo à mémoire préallouée (aucune allocation en temps réel).
private final class FilterChain {
    static let maxFilters = 40
    let coefs = UnsafeMutablePointer<Double>.allocate(capacity: maxFilters * 5)
    let state = UnsafeMutablePointer<Double>.allocate(capacity: 2 * maxFilters * 2)
    var count = 0
    var gain = 1.0

    init() {
        coefs.initialize(repeating: 0, count: Self.maxFilters * 5)
        state.initialize(repeating: 0, count: 2 * Self.maxFilters * 2)
    }

    deinit {
        coefs.deallocate()
        state.deallocate()
    }

    func set(_ config: ChainConfig) {
        count = min(config.filters.count, Self.maxFilters)
        for (b, c) in config.filters.prefix(count).enumerated() {
            for i in 0..<5 { coefs[b * 5 + i] = c[i] }
        }
        gain = pow(10, config.preampDB / 20)
    }

    func copy(from other: FilterChain) {
        coefs.update(from: other.coefs, count: Self.maxFilters * 5)
        count = other.count
        gain = other.gain
    }

    func resetState() {
        state.update(repeating: 0, count: 2 * Self.maxFilters * 2)
    }

    var isFinite: Bool { state[0].isFinite && state[Self.maxFilters * 2].isFinite }

    @inline(__always)
    func run(_ input: Double, channel: Int) -> Double {
        var x = input * gain
        let st = state + channel * Self.maxFilters * 2
        for b in 0..<count {
            let k = coefs + b * 5
            let s = st + b * 2
            let y = k[0] * x + s[0]
            s[0] = k[1] * x - k[3] * y + s[1]
            s[1] = k[2] * x - k[4] * y
            x = y
        }
        return x
    }
}

/// Coefficients des traitements de sortie, calculés hors du thread audio.
private struct OutputDSP {
    var leveler = false
    var threshold = -24.0, ratio = 3.0, makeup = 6.0
    var attack = 0.0, release = 0.0
    var crossfeed = false
    var crossCoef = 0.0, crossMix = 0.0, crossNorm = 1.0
    var mono = false
    var gainL = 1.0, gainR = 1.0

    init() {}

    init(_ o: OutputOptions, sampleRate: Double) {
        let presets: [(threshold: Double, ratio: Double, makeup: Double)] = [(-18, 2, 4), (-24, 3, 7), (-30, 4, 10)]
        if (1...3).contains(o.leveler) {
            leveler = true
            (threshold, ratio, makeup) = presets[o.leveler - 1]
        }
        attack = 1 - exp(-1 / (0.010 * sampleRate))   // 10 ms
        release = 1 - exp(-1 / (0.300 * sampleRate))  // 300 ms
        crossfeed = o.crossfeed
        crossCoef = 1 - exp(-2 * Double.pi * 700 / sampleRate)  // passe-bas 700 Hz
        crossMix = 0.45
        crossNorm = 1 / (1 + crossMix)
        mono = o.mono
        let b = o.balance.clamped(to: -1...1)
        gainL = b > 0 ? 1 - b : 1
        gainR = b < 0 ? 1 + b : 1
    }
}

/// Traitement temps réel : une chaîne par source (son général, applications réglées à part),
/// mélange, correction de casque, limiteur. Aucune allocation ni verrou bloquant dans `process`.
final class EQProcessor {
    /// Nombre maximal de sources : le son général + 7 applications.
    static let maxSources = 8
    /// Plafond du limiteur : −1 dBFS, pour garder une marge avant la saturation.
    static let ceiling = pow(10.0, -1.0 / 20)
    private static let releaseTime = 0.15

    private let sources = (0..<EQProcessor.maxSources).map { _ in FilterChain() }
    private let pendingSources = (0..<EQProcessor.maxSources).map { _ in FilterChain() }
    private let post = FilterChain()
    private let pendingPost = FilterChain()
    private var sourceCount = 1
    private var pendingSourceCount = 1

    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private let meter: UnsafeMutablePointer<Float>
    /// Gain appliqué en ce moment par le volume nivelé (dB) ; NaN quand il est coupé.
    private let levelMeter: UnsafeMutablePointer<Float>
    /// Tampon circulaire des derniers échantillons de sortie (mono), lu par l'analyseur de spectre.
    static let scopeSize = 16384
    private let scope: UnsafeMutablePointer<Float>
    /// Nombre total d'échantillons écrits dans `scope` depuis le début.
    private let scopeWritten: UnsafeMutablePointer<Int>
    private var activeRelease = 0.9999
    private var pendingRelease = 0.9999
    private var limiterGain = 1.0
    private var activeLimiterOn = true
    private var pendingLimiterOn = true
    private var activeOut = OutputDSP()
    private var pendingOut = OutputDSP()
    // États des traitements de sortie.
    private var levelEnv = 0.0
    private var crossLP = (0.0, 0.0)
    private var dirty = false
    private var resetRequested = false

    /// Nombre de tampons d'entrée occupés par chaque tap (1 entrelacé, 2 séparés).
    var buffersPerTap = 1

    init() {
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        meter = .allocate(capacity: 1)
        meter.initialize(to: 1)
        levelMeter = .allocate(capacity: 1)
        levelMeter.initialize(to: .nan)
        scope = .allocate(capacity: Self.scopeSize)
        scope.initialize(repeating: 0, count: Self.scopeSize)
        scopeWritten = .allocate(capacity: 1)
        scopeWritten.initialize(to: 0)
    }

    deinit {
        lock.deallocate()
        meter.deallocate()
        levelMeter.deallocate()
        scope.deallocate()
        scopeWritten.deallocate()
    }

    /// Thread principal. `sources[0]` : son général ; suivantes : applications, dans l'ordre des taps.
    func update(sources configs: [ChainConfig], post postConfig: ChainConfig, sampleRate: Double,
                limiter: Bool = true, output: OutputOptions = OutputOptions(), reset: Bool = false) {
        let out = OutputDSP(output, sampleRate: sampleRate)
        os_unfair_lock_lock(lock)
        pendingOut = out
        pendingSourceCount = max(1, min(configs.count, Self.maxSources))
        for (i, c) in configs.prefix(pendingSourceCount).enumerated() { pendingSources[i].set(c) }
        pendingPost.set(postConfig)
        pendingRelease = exp(-1 / (Self.releaseTime * sampleRate))
        pendingLimiterOn = limiter
        dirty = true
        if reset { resetRequested = true }
        os_unfair_lock_unlock(lock)
    }

    /// Compatibilité : une seule source en mode graphique.
    func update(gainsDB: [Double], preampDB: Double, frequencies: [Double], sampleRate: Double,
                limiter: Bool = true, reset: Bool = false) {
        let filters = zip(frequencies, gainsDB).map { EQMath.peaking(frequency: $0, gainDB: $1, sampleRate: sampleRate) }
        update(sources: [ChainConfig(filters: filters, preampDB: preampDB)], post: .neutral,
               sampleRate: sampleRate, limiter: limiter, reset: reset)
    }

    /// Thread principal : copie les `count` derniers échantillons de sortie dans `dst`.
    /// Renvoie le compteur d'écriture, qui ne bouge plus quand aucun son n'est traité.
    func copyRecentSamples(_ count: Int, into dst: UnsafeMutablePointer<Float>) -> Int {
        let end = scopeWritten.pointee
        let mask = Self.scopeSize - 1
        for i in 0..<min(count, Self.scopeSize) {
            dst[i] = scope[(end - count + i) & mask]
        }
        return end
    }

    /// Thread principal : plus petit gain appliqué par le limiteur depuis le dernier appel
    /// (1 = aucune réduction ; < 1 aussi en cas de saturation, limiteur coupé). Remet à zéro.
    /// Thread principal : gain actuel du volume nivelé (dB), nil s'il est coupé.
    func levelerGainDB() -> Float? {
        let v = levelMeter.pointee
        return v.isNaN ? nil : v
    }

    func takeLimiterGain() -> Float {
        let g = meter.pointee
        meter.pointee = 1
        return g
    }

    private typealias Channel = (ptr: UnsafeMutablePointer<Float>, stride: Int, frames: Int)

    @inline(__always)
    private func channel(_ list: UnsafeMutableAudioBufferListPointer, start: Int, _ c: Int) -> Channel? {
        guard start < list.count else { return nil }
        let first = list[start]
        let nch = Int(first.mNumberChannels)
        guard nch > 0 else { return nil }
        if nch == 1 {
            let idx = min(start + c, list.count - 1)
            guard let d = list[idx].mData else { return nil }
            return (d.assumingMemoryBound(to: Float.self), 1, Int(list[idx].mDataByteSize) / 4)
        }
        guard let d = first.mData else { return nil }
        return (d.assumingMemoryBound(to: Float.self) + min(c, nch - 1), nch, Int(first.mDataByteSize) / (4 * nch))
    }

    /// Thread audio : lit chaque tap, égalise, mélange, corrige, limite, écrit vers la sortie.
    func process(_ inList: UnsafePointer<AudioBufferList>, _ outList: UnsafeMutablePointer<AudioBufferList>) {
        if os_unfair_lock_trylock(lock) {
            if dirty {
                for i in 0..<pendingSourceCount { sources[i].copy(from: pendingSources[i]) }
                // Une source qui apparaît repart d'un état propre.
                for i in sourceCount..<max(sourceCount, pendingSourceCount) { sources[i].resetState() }
                sourceCount = pendingSourceCount
                post.copy(from: pendingPost)
                activeRelease = pendingRelease
                activeLimiterOn = pendingLimiterOn
                activeOut = pendingOut
                dirty = false
            }
            if resetRequested {
                for s in sources { s.resetState() }
                post.resetState()
                limiterGain = 1
                levelEnv = 0
                crossLP = (0, 0)
                resetRequested = false
            }
            os_unfair_lock_unlock(lock)
        }

        let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inList))
        let output = UnsafeMutableAudioBufferListPointer(outList)
        for buf in output {
            if let d = buf.mData { memset(d, 0, Int(buf.mDataByteSize)) }
        }
        guard input.count > 0, output.count > 0,
              let dstL = channel(output, start: 0, 0) else { return }
        let dstR = channel(output, start: 0, 1) ?? dstL
        let monoOut = dstL.ptr == dstR.ptr

        // Les taps sont les derniers flux d'entrée (après un éventuel micro du périphérique),
        // dans l'ordre où ils ont été déclarés : son général, puis applications.
        let per = max(1, buffersPerTap)
        let nSources = min(sourceCount, input.count / per)
        guard nSources > 0 else { return }
        let firstTap = input.count - nSources * per
        var frames = min(dstL.frames, dstR.frames)
        var srcs: Tuple8 = (nil, nil, nil, nil, nil, nil, nil, nil)
        var srcsR = srcs
        for s in 0..<nSources {
            guard let l = channel(input, start: firstTap + s * per, 0) else { return }
            let r = channel(input, start: firstTap + s * per, 1) ?? l
            frames = min(frames, l.frames, r.frames)
            setTuple(&srcs, s, l)
            setTuple(&srcsR, s, r)
        }

        let release = activeRelease
        // Limiteur coupé : plafond hors d'atteinte, le gain reste à 1.
        let ceiling = activeLimiterOn ? Self.ceiling : .greatestFiniteMagnitude
        var g = limiterGain
        var minGain = 1.0
        let o = activeOut
        var env = levelEnv
        var levelDB = 0.0
        var (lpL, lpR) = crossLP
        var written = scopeWritten.pointee
        let scopeMask = Self.scopeSize - 1

        for i in 0..<frames {
            var l = 0.0, r = 0.0
            for s in 0..<nSources {
                let a = getTuple(srcs, s)!, b = getTuple(srcsR, s)!
                let chain = sources[s]
                l += chain.run(Double(a.ptr[i * a.stride]), channel: 0)
                r += chain.run(Double(b.ptr[i * b.stride]), channel: 1)
            }
            l = post.run(l, channel: 0)
            r = post.run(r, channel: 1)

            // Spatialisation casque : chaque oreille reçoit un peu de l'autre canal, adouci
            // (filtre passe-bas), comme avec des enceintes. Niveau des sons centrés inchangé.
            if o.crossfeed {
                lpL += (l - lpL) * o.crossCoef
                lpR += (r - lpR) * o.crossCoef
                (l, r) = ((l + o.crossMix * lpR) * o.crossNorm, (r + o.crossMix * lpL) * o.crossNorm)
            }
            if o.mono {
                let m = 0.5 * (l + r)
                (l, r) = (m, m)
            }
            l *= o.gainL
            r *= o.gainR

            // Volume nivelé : compresseur doux lié stéréo, puis remontée du niveau général.
            // Le limiteur, juste après, rattrape les éventuels dépassements.
            if o.leveler {
                let x = max(abs(l), abs(r))
                env += (x - env) * (x > env ? o.attack : o.release)
                let envDB = 20 * log10(env + 1e-9)
                var gainDB = envDB > o.threshold ? (o.threshold - envDB) * (1 - 1 / o.ratio) : 0
                // Pas de remontée sur le silence (on n'amplifie pas le souffle).
                gainDB += o.makeup * min(max((envDB + 70) / 20, 0), 1)
                levelDB = gainDB
                let lg = pow(10, gainDB / 20)
                l *= lg
                r *= lg
            }

            // Limiteur lié stéréo : réduction instantanée à la crête, retour progressif.
            let peak = max(abs(l), abs(r))
            let target = peak > ceiling ? ceiling / peak : 1
            g = target < g ? target : target - (target - g) * release
            if g < minGain { minGain = g }
            if peak > 1, 1 / peak < minGain { minGain = 1 / peak }

            if monoOut {
                dstL.ptr[i * dstL.stride] = Float(max(-1, min(1, 0.5 * (l + r) * g)))
            } else {
                dstL.ptr[i * dstL.stride] = Float(max(-1, min(1, l * g)))
                dstR.ptr[i * dstR.stride] = Float(max(-1, min(1, r * g)))
            }
            scope[written & scopeMask] = Float(0.5 * (l + r) * g)
            written &+= 1
        }
        scopeWritten.pointee = written

        // Sécurité : si un filtre a divergé, on repart de zéro plutôt que de rester muet.
        var broken = !g.isFinite || !post.isFinite
        for s in 0..<nSources where !sources[s].isFinite { broken = true }
        if broken {
            for s in sources { s.resetState() }
            post.resetState()
            g = 1
        }
        limiterGain = g
        levelEnv = env.isFinite ? env : 0
        levelMeter.pointee = o.leveler && levelDB.isFinite ? Float(levelDB) : .nan
        crossLP = lpL.isFinite && lpR.isFinite ? (lpL, lpR) : (0, 0)
        let m = Float(minGain)
        if m < meter.pointee { meter.pointee = m }
    }

    // Accès indexé à un tuple de 8 éléments (pile, pas d'allocation).
    private typealias Tuple8 = (Channel?, Channel?, Channel?, Channel?, Channel?, Channel?, Channel?, Channel?)

    @inline(__always)
    private func setTuple(_ t: inout Tuple8, _ i: Int, _ v: Channel) {
        switch i {
        case 0: t.0 = v
        case 1: t.1 = v
        case 2: t.2 = v
        case 3: t.3 = v
        case 4: t.4 = v
        case 5: t.5 = v
        case 6: t.6 = v
        default: t.7 = v
        }
    }

    @inline(__always)
    private func getTuple(_ t: Tuple8, _ i: Int) -> Channel? {
        switch i {
        case 0: return t.0
        case 1: return t.1
        case 2: return t.2
        case 3: return t.3
        case 4: return t.4
        case 5: return t.5
        case 6: return t.6
        default: return t.7
        }
    }
}
