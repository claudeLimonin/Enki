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
    /// Largeur stéréo : 0 = mono, 1 = original, 2 = élargie au maximum.
    var width = 1.0
    /// Immersif : annulation de diaphonie, pour des haut-parleurs proches (portable).
    var immersive = false

    static let widthRange = 0.0...2.0
    /// À 200 %, renfort des « côtés » au-dessus de 200 Hz (la largeur maximale de l'ancien niveau « Fort »).
    static let maxWidening = 1.3

    /// Anciens niveaux d'élargissement (Coupé, Léger, Moyen, Fort, Immersif) → largeur et Immersif.
    static func migrate(widening level: Int) -> (width: Double, immersive: Bool) {
        switch level {
        case 1: return (1 + 0.4 / maxWidening, false)
        case 2: return (1 + 0.8 / maxWidening, false)
        case 3: return (2, false)
        case 4: return (1, true)
        default: return (1, false)
        }
    }

    /// Annulation de diaphonie : chaque oreille entend aussi le haut-parleur opposé, un peu plus tard.
    /// On envoie l'inverse de ce « débordement », retardé d'autant, pour l'effacer (méthode RACE,
    /// appliquée aux côtés seulement : voix au centre intactes).
    static let ctcGain = 0.7
    static let ctcBand = (low: 250.0, high: 6000.0)
    /// Écart supposé entre les haut-parleurs (MacBook) et demi-écart entre les oreilles, en mètres.
    static let speakerSpacing = 0.30, halfEarSpacing = 0.0875
    static let distanceMeters = [0.4, 0.6, 1.0]

    /// Retard (secondes) entre le son du haut-parleur proche et celui du haut-parleur opposé, pour une oreille.
    static func crosstalkDelay(distance: Int) -> Double {
        let d = distanceMeters[distance.clamped(to: 0...2)], half = speakerSpacing / 2
        let far = (d * d + pow(half + halfEarSpacing, 2)).squareRoot()
        let near = (d * d + pow(half - halfEarSpacing, 2)).squareRoot()
        return (far - near) / 343
    }
    /// Sous cette fréquence, les côtés ne sont pas renforcés : graves intacts, pas d'effet de phase.
    static let wideningCutoff = 200.0

    /// Distance d'écoute : 0 proche (~40 cm), 1 normale (~60 cm), 2 loin (~1 m).
    var distance = 1
    /// Plus on s'éloigne, plus les deux haut-parleurs paraissent proches l'un de l'autre
    /// (angle d'environ 40° à 40 cm, 28° à 60 cm, 17° à 1 m pour 30 cm d'écart) :
    /// l'élargissement est donc plus fort de loin et plus doux de près.
    static let distanceFactors = [0.75, 1.0, 1.4]
    static var distanceNames: [String] {
        [String(localized: "Proche"), String(localized: "Normale"), String(localized: "Loin")]
    }
    static var distanceHints: [String] {
        [String(localized: "≈ 40 cm"), String(localized: "≈ 60 cm"), String(localized: "≈ 1 m")]
    }

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
