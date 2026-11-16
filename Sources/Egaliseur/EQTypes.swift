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

    static var levelerNames: [String] {
        [String(localized: "Coupé"), String(localized: "Léger"), String(localized: "Moyen"), String(localized: "Fort")]
    }
}
