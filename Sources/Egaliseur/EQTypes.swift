import Foundation

/// Mode de l'égaliseur principal.
enum EQMode: String, Codable, CaseIterable, Identifiable {
    case graphic, parametric
    var id: String { rawValue }
    var label: String { self == .graphic ? String(localized: "Graphique") : String(localized: "Paramétrique") }
}

/// Un filtre libre (mode paramétrique, correction de casque).
struct EQFilter: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case peak, lowShelf, highShelf
        var id: String { rawValue }
        var label: String {
            switch self {
            case .peak: return String(localized: "Cloche")
            case .lowShelf: return String(localized: "Plateau grave")
            case .highShelf: return String(localized: "Plateau aigu")
            }
        }
    }

    static let frequencyRange: ClosedRange<Double> = 20...20_000
    static let gainRange: ClosedRange<Double> = -24...24
    static let qRange: ClosedRange<Double> = 0.1...20

    var id = UUID()
    var kind: Kind
    var frequency: Double
    var gain: Double
    var q: Double
    var enabled = true

    /// Bandes de départ du mode paramétrique, toutes à 0 dB.
    static var defaultBands: [EQFilter] {
        [
            EQFilter(kind: .lowShelf, frequency: 80, gain: 0, q: 0.7),
            EQFilter(kind: .peak, frequency: 250, gain: 0, q: 1),
            EQFilter(kind: .peak, frequency: 1000, gain: 0, q: 1),
            EQFilter(kind: .peak, frequency: 4000, gain: 0, q: 1),
            EQFilter(kind: .highShelf, frequency: 10_000, gain: 0, q: 0.7),
        ]
    }
}

/// Profil de correction d'un casque (format AutoEQ / Equalizer APO).
struct HeadphoneProfile: Codable, Equatable {
    var name: String
    var preamp: Double
    var filters: [EQFilter]
}

/// Réglage particulier d'une application. `preset == nil` : son non égalisé.
struct AppRule: Codable, Equatable, Identifiable {
    var bundleID: String
    var name: String
    var preset: String?
    var id: String { bundleID }
}

/// Tout ce qui décrit le réglage de l'égaliseur principal.
struct EQSettings: Equatable {
    var mode: EQMode
    var gains: [Double]
    var preamp: Double
    var filters: [EQFilter]
}

/// Traitements de sortie, appliqués après l'égaliseur et la correction de casque.
struct OutputOptions: Equatable {
    /// Volume nivelé (« mode nuit ») : 0 coupé, 1 léger, 2 moyen, 3 fort.
    var leveler = 0
    /// Spatialisation casque : mélange doux des canaux, comme des enceintes.
    var crossfeed = false
    var mono = false
    /// −1 (tout à gauche) … 0 (centre) … +1 (tout à droite).
    var balance = 0.0
    /// Élargissement stéréo (haut-parleurs proches, comme ceux d'un portable) : 0 coupé, 1 léger, 2 moyen, 3 fort.
    var widening = 0

    /// Renfort des « côtés » (différence gauche − droite) pour Léger, Moyen, Fort.
    static let wideningAmounts = [0.0, 0.4, 0.8, 1.3]
    /// Sous cette fréquence, les côtés ne sont pas renforcés : graves intacts, pas d'effet de phase.
    static let wideningCutoff = 200.0

    /// Fréquences de séparation du mode nuit : graves | voix | aigus.
    static let nightCrossovers = (200.0, 4000.0)

    /// Réglages des 3 bandes pour Léger, Moyen, Fort.
    /// Graves : réduits quand ils sont forts, jamais remontés. Voix : remontées sur les passages calmes.
    static let nightBands: [[NightBand]] = [
        [NightBand(threshold: -28, ratio: 2, makeup: 0), NightBand(threshold: -24, ratio: 2, makeup: 2), NightBand(threshold: -26, ratio: 2, makeup: 0)],
        [NightBand(threshold: -32, ratio: 3, makeup: 0), NightBand(threshold: -28, ratio: 2.5, makeup: 4), NightBand(threshold: -30, ratio: 2.5, makeup: 1)],
        [NightBand(threshold: -36, ratio: 4, makeup: 0), NightBand(threshold: -32, ratio: 3, makeup: 6), NightBand(threshold: -34, ratio: 3, makeup: 2)],
    ]

    /// Effet du mode nuit (dB) à une fréquence, d'après le gain actuel des 3 bandes :
    /// mélange pondéré par la part de chaque bande à cette fréquence (filtres de séparation).
    static func nightOffsetDB(at f: Double, gains: [Double]) -> Double {
        guard gains.count == 3 else { return 0 }
        let (f1, f2) = nightCrossovers
        let wLow = 1 / (1 + pow(f / f1, 4))
        let wHigh = pow(f / f2, 4) / (1 + pow(f / f2, 4))
        let wMid = max(0, 1 - wLow - wHigh)
        let lin = wLow * pow(10, gains[0] / 20) + wMid * pow(10, gains[1] / 20) + wHigh * pow(10, gains[2] / 20)
        return 20 * log10(max(lin, 1e-6))
    }

    static var levelerNames: [String] {
        [String(localized: "Coupé"), String(localized: "Léger"), String(localized: "Moyen"), String(localized: "Fort")]
    }
}

/// Réglage d'une bande du mode nuit.
struct NightBand: Equatable {
    var threshold = -30.0
    var ratio = 2.0
    var makeup = 0.0
}
