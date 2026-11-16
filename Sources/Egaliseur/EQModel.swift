import Foundation
import SwiftUI

struct EQPreset: Identifiable, Equatable, Codable {
    var name: String
    var gains: [Double]
    /// Préampli enregistré (préréglages personnels). Absent : calculé automatiquement.
    var preamp: Double? = nil
    /// Absent : préréglage graphique (anciennes versions, préréglages fournis).
    var mode: EQMode? = nil
    var filters: [EQFilter]? = nil
    var id: String { name }

    /// Nom affiché : les préréglages fournis sont traduits, les vôtres gardent leur nom.
    var displayName: String {
        EQModel.presets.contains { $0.name == name } ? NSLocalizedString(name, comment: "Préréglage fourni") : name
    }
}

/// Réglage mémorisé pour une sortie audio donnée.
struct DeviceSetting: Codable, Equatable {
    var name: String
    var gains: [Double]
    var preamp: Double
    var preset: String?
    var modified: Bool
    var mode: EQMode? = nil
    var filters: [EQFilter]? = nil
    var correction: HeadphoneProfile? = nil
    var correctionOn: Bool? = nil
    /// Élargissement stéréo de cette sortie (absent : coupé).
    var widening: Int? = nil
    /// Distance d'écoute de cette sortie (absent : normale).
    var distance: Int? = nil
}

/// Ce qu'une application reçoit : l'égaliseur principal, rien, ou un préréglage.
enum AppChoice: Hashable {
    case main, bypass, preset(String)
}

/// État de l'égaliseur : réglages, préréglages, sauvegarde, pilotage du moteur audio.
final class EQModel: ObservableObject {
    static let shared = EQModel()

    static let frequencies: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let labels = ["32", "64", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
    static let range: ClosedRange<Double> = -12...12
    /// Nom réservé (enregistré tel quel) ; affiché via `customDisplayName`.
    static let customName = "Personnalisé"
    static var customDisplayName: String { String(localized: "Personnalisé") }
    static let maxNameLength = 40
    static let maxParametricBands = 20
    static let maxAppRules = EQProcessor.maxSources - 1

    /// Préréglages fournis, par catégorie (gains des 10 bandes : 32, 64, 125, 250, 500, 1k, 2k, 4k, 8k, 16k Hz).
    static let presetGroups: [(title: String, presets: [EQPreset])] = [
        (String(localized: "Essentiels"), [
            EQPreset(name: "Plat", gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
            EQPreset(name: "Basses renforcées", gains: [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]),
            EQPreset(name: "Aigus renforcés", gains: [0, 0, 0, 0, 0, 1, 2, 4, 5, 6]),
            EQPreset(name: "Aigus adoucis", gains: [0, 0, 0, 0, 0, 0, -1, -3, -3, -2]),
            EQPreset(name: "Voix", gains: [-2, -2, -1, 1, 3, 4, 3, 1, 0, -1]),
            EQPreset(name: "Loudness", gains: [6, 4, 1, 0, -1, -1, 0, 1, 3, 5]),
            // Petits haut-parleurs : pas de grave profond (qu'ils ne peuvent pas rendre), plutôt le haut-grave.
            EQPreset(name: "Petits haut-parleurs", gains: [0, 2, 4, 3, 1, 0, 0, 1, 2, 2]),
        ]),
        (String(localized: "Genres"), [
            EQPreset(name: "Rock", gains: [5, 4, 2, 0, -1, -1, 1, 3, 4, 5]),
            EQPreset(name: "Pop", gains: [-1, 0, 2, 3, 4, 3, 1, 0, -1, -1]),
            EQPreset(name: "Jazz", gains: [3, 2, 1, 2, -1, -1, 0, 1, 2, 3]),
            EQPreset(name: "Classique", gains: [4, 3, 2, 1, 0, 0, 0, 1, 2, 3]),
            EQPreset(name: "Électro", gains: [5, 4, 1, 0, -2, 1, 0, 1, 4, 5]),
            EQPreset(name: "Hip-hop", gains: [6, 5, 2, 1, -1, -1, 1, 1, 2, 3]),
            EQPreset(name: "R&B", gains: [5, 6, 3, -1, -2, 1, 2, 2, 3, 3]),
            EQPreset(name: "Métal", gains: [4, 3, 1, -1, -2, 0, 2, 4, 4, 3]),
            EQPreset(name: "Acoustique", gains: [3, 2, 1, 1, 2, 1, 2, 3, 2, 1]),
            EQPreset(name: "Piano", gains: [1, 1, 0, 2, 3, 1, 3, 4, 3, 2]),
            EQPreset(name: "Lounge", gains: [-2, -1, 0, 2, 3, 2, 0, -1, 1, 1]),
            EQPreset(name: "Latino", gains: [3, 2, 0, 0, -1, -1, -1, 0, 3, 4]),
        ]),
        (String(localized: "Usages"), [
            EQPreset(name: "Podcast", gains: [-6, -4, -1, 1, 3, 4, 3, 1, -1, -3]),
            EQPreset(name: "Cinéma", gains: [5, 4, 2, 0, -1, 1, 2, 2, 3, 2]),
            EQPreset(name: "Jeux vidéo", gains: [3, 3, 1, 0, -1, 1, 3, 4, 3, 2]),
        ]),
        (String(localized: "Antilles"), [
            // Zouk : basse ronde, voix douces et présentes.
            EQPreset(name: "Zouk", gains: [4, 4, 2, 0, -1, 1, 2, 2, 3, 3]),
            // Kompa : groove chaloupé, basse et guitares.
            EQPreset(name: "Kompa", gains: [4, 3, 2, 1, 0, 1, 1, 2, 2, 2]),
            // Gwoka : tambours ka, frappe et résonance.
            EQPreset(name: "Gwoka", gains: [5, 4, 2, 0, -1, 0, 2, 3, 2, 1]),
            // Biguine : clarinette, cuivres et banjo dans le médium.
            EQPreset(name: "Biguine", gains: [1, 1, 1, 2, 3, 3, 2, 2, 1, 0]),
        ]),
        (String(localized: "Caraïbes"), [
            // Reggae : basse profonde, médium en retrait.
            EQPreset(name: "Reggae", gains: [6, 5, 3, 0, -2, -1, 0, 1, 1, 1]),
            EQPreset(name: "Dancehall", gains: [6, 6, 3, 0, -2, 0, 2, 2, 3, 3]),
            EQPreset(name: "Soca", gains: [4, 4, 2, 0, -1, 1, 2, 3, 4, 4]),
            // Calypso : steel drums dans le haut-médium.
            EQPreset(name: "Calypso", gains: [2, 2, 1, 0, 1, 2, 3, 3, 3, 2]),
        ]),
        (String(localized: "Afrique"), [
            EQPreset(name: "Afrobeat", gains: [4, 4, 2, 1, 0, 1, 2, 3, 3, 2]),
            // Amapiano : « log drum » très grave.
            EQPreset(name: "Amapiano", gains: [6, 6, 3, 0, -2, -1, 1, 2, 3, 2]),
            EQPreset(name: "Coupé-décalé", gains: [4, 4, 2, 0, -1, 1, 3, 3, 4, 3]),
            // Rumba congolaise : guitares en avant.
            EQPreset(name: "Rumba congolaise", gains: [3, 2, 1, 1, 2, 2, 3, 3, 2, 1]),
            // Mandingue : kora et balafon, détails dans les aigus.
            EQPreset(name: "Mandingue", gains: [0, 0, 1, 2, 2, 2, 3, 4, 3, 2]),
        ]),
        (String(localized: "Amérique du Sud"), [
            EQPreset(name: "Salsa", gains: [3, 3, 1, 0, 0, 1, 3, 3, 4, 4]),
            EQPreset(name: "Samba", gains: [3, 3, 2, 0, -1, 1, 2, 3, 4, 4]),
            EQPreset(name: "Bossa nova", gains: [1, 1, 1, 2, 2, 1, 1, 2, 2, 1]),
            EQPreset(name: "Reggaeton", gains: [6, 6, 3, 0, -2, 0, 2, 2, 3, 2]),
            EQPreset(name: "Cumbia", gains: [3, 3, 1, 1, 0, 1, 2, 3, 3, 3]),
            // Tango : bandonéon et violons dans le médium.
            EQPreset(name: "Tango", gains: [1, 1, 1, 2, 3, 3, 2, 2, 1, 0]),
        ]),
    ]

    /// Tous les préréglages fournis, dans l'ordre des catégories (« Plat » en premier).
    static let presets: [EQPreset] = presetGroups.flatMap(\.presets)


    // MARK: Réglage principal

    @Published var mode: EQMode {
        didSet {
            guard mode != oldValue else { return }
            // Passage en paramétrique avec des bandes encore à plat : on reprend la courbe
            // graphique à l'identique, pour que le son ne change pas au changement de mode.
            if !applyingPreset, mode == .parametric,
               filters.allSatisfy({ $0.gain == 0 || !$0.enabled }), gains.contains(where: { $0 != 0 }) {
                applyingPreset = true
                filters = EQMath.graphicAsParametric(gains, sampleRate: sampleRate)
                applyingPreset = false
                push()
                save()
                return
            }
            // Retour au graphique sans avoir touché aux bandes reprises : même son, rien de modifié.
            if !applyingPreset, mode == .graphic, Self.sameBands(filters, EQMath.graphicAsParametric(gains, sampleRate: sampleRate)) {
                push()
                save()
                return
            }
            settingsChanged()
        }
    }

    /// Mêmes bandes (type, fréquence, gain, Q, état), quels que soient leurs identifiants.
    private static func sameBands(_ a: [EQFilter], _ b: [EQFilter]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy {
            $0.kind == $1.kind && $0.frequency == $1.frequency && $0.gain == $1.gain && $0.q == $1.q && $0.enabled == $1.enabled
        }
    }
    @Published var gains: [Double] { didSet { if gains != oldValue { settingsChanged() } } }
    @Published var preamp: Double { didSet { if preamp != oldValue { settingsChanged() } } }
    @Published var filters: [EQFilter] { didSet { if filters != oldValue { settingsChanged() } } }

    @Published var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            save()
            enabled ? startEngine() : stopEngine()
        }
    }
    @Published private(set) var userPresets: [EQPreset]
    /// Préréglage chargé en dernier (nil : réglage libre).
    @Published private(set) var selectedPreset: String?
    /// Les réglages ont bougé depuis le chargement du préréglage.
    @Published private(set) var isModified: Bool
    /// Limiteur anti-saturation (commun à toutes les sorties).
    @Published var limiterEnabled: Bool { didSet { if limiterEnabled != oldValue { push(); save() } } }

    // MARK: Écoute (traitements de sortie)

    /// Volume nivelé : 0 coupé, 1 léger, 2 moyen, 3 fort.
    @Published var leveler: Int { didSet { if leveler != oldValue { push(); save() } } }
    @Published var crossfeed: Bool { didSet { if crossfeed != oldValue { push(); save() } } }
    @Published var mono: Bool {
        didSet {
            guard mono != oldValue else { return }
            // Mono et élargissement s'excluent : en mono, il n'y a plus de stéréo à élargir.
            if mono, widening > 0, !loading {
                lastWidening = widening
                widening = 0
                notify(String(localized: "Mono : élargissement stéréo coupé"), symbol: "speaker.wave.1.fill")
            }
            push(); save()
        }
    }
    @Published var balance: Double { didSet { if balance != oldValue { push(); save() } } }
    /// Élargissement stéréo pour haut-parleurs : 0 coupé, 1 léger, 2 moyen, 3 fort. Mémorisé par sortie.
    @Published var widening: Int {
        didSet {
            guard widening != oldValue else { return }
            if widening > 0, mono, !loading {
                mono = false
                notify(String(localized: "Élargissement stéréo : mono coupé"), symbol: "arrow.left.and.right")
            }
            push(); save()
        }
    }
    /// Distance d'écoute (0 proche, 1 normale, 2 loin) : ajuste l'élargissement. Mémorisée par sortie.
    @Published var listeningDistance: Int { didSet { if listeningDistance != oldValue { push(); save() } } }
    /// La sortie actuelle est des haut-parleurs (et non un casque) : décide de la tuile proposée.
    @Published private(set) var outputIsSpeakers = false
    private var lastWidening = 2

    /// Relit le type de sortie (un casque branché sur la prise du Mac ne change pas de sortie).
    func refreshOutputKind() {
        let speakers = AudioEngine.defaultOutputIsSpeakers()
        if speakers != outputIsSpeakers { outputIsSpeakers = speakers }
    }

    /// Tuile de la vue rapide : coupe l'élargissement, ou le remet au dernier niveau.
    func toggleWidening() {
        if widening > 0 { lastWidening = widening; widening = 0 } else { widening = lastWidening }
    }

    /// Raccourcis clavier globaux (⌃⌥⌘E, ⌃⌥⌘←/→, ⌃⌥⌘N).
    @Published var hotkeysEnabled: Bool { didSet { if hotkeysEnabled != oldValue { save() } } }
    /// Petite bulle sous l'icône quand le réglage change (raccourci, casque branché…).
    @Published var notificationsEnabled: Bool { didSet { if notificationsEnabled != oldValue { save() } } }

    /// Comparer A/B : tant que c'est vrai, le son passe sans aucun traitement (limiteur excepté),
    /// sans redémarrer le moteur. Jamais enregistré.
    @Published var comparing = false { didSet { if comparing != oldValue { push() } } }

    /// Calques affichés sur le graphique de la fenêtre.
    @Published var showSpectrum: Bool { didSet { if showSpectrum != oldValue { save() } } }
    @Published var showCorrectionLayer: Bool { didSet { if showCorrectionLayer != oldValue { save() } } }
    @Published var showNightLayer: Bool { didSet { if showNightLayer != oldValue { save() } } }
    /// Affiche la bulle (fourni par l'icône de la barre des menus).
    var onNotify: ((String, String) -> Void)?
    private var lastLeveler = 2

    func notify(_ text: String, symbol: String) {
        if notificationsEnabled { onNotify?(text, symbol) }
    }

    // MARK: Actions des raccourcis clavier

    func toggleEnabledFromShortcut() {
        enabled.toggle()
        notify(enabled ? String(localized: "Égaliseur activé") : String(localized: "Égaliseur coupé : son d'origine"),
               symbol: enabled ? "slider.vertical.3" : "speaker.slash")
    }

    /// Passe au préréglage suivant (+1) ou précédent (−1), en boucle.
    func stepPreset(_ delta: Int) {
        let list = allPresets
        guard !list.isEmpty else { return }
        let current = selectedPreset.flatMap { name in list.firstIndex { $0.name == name } }
        let next = current.map { ($0 + delta + list.count) % list.count } ?? (delta > 0 ? 0 : list.count - 1)
        apply(list[next])
        notify(String(localized: "Préréglage : \(list[next].displayName)"), symbol: delta > 0 ? "forward.fill" : "backward.fill")
    }

    func toggleLevelerFromShortcut() {
        if leveler > 0 { lastLeveler = leveler; leveler = 0 } else { leveler = lastLeveler }
        notify(leveler > 0 ? String(localized: "Volume nivelé : \(OutputOptions.levelerNames[leveler])") : String(localized: "Volume nivelé coupé"),
               symbol: leveler > 0 ? "moon.fill" : "moon")
    }

    var outputOptions: OutputOptions {
        OutputOptions(leveler: leveler, crossfeed: crossfeed, mono: mono, balance: balance, widening: widening, distance: listeningDistance)
    }

    // MARK: Correction de casque

    @Published private(set) var correction: HeadphoneProfile?
    /// Demande (depuis le menu clic droit) d'ouvrir directement la recherche de casque.
    @Published var correctionEnabled: Bool { didSet { if correctionEnabled != oldValue { push(); save() } } }

    // MARK: Sorties audio

    /// Chaque sortie audio garde son propre réglage.
    @Published var perDevice: Bool { didSet { if perDevice != oldValue { save() } } }
    /// Sortie audio à laquelle le réglage actuel appartient.
    @Published private(set) var currentDevice: (uid: String, name: String)?
    private var deviceSettings: [String: DeviceSetting]

    // MARK: Applications

    @Published private(set) var appRules: [AppRule]
    /// Applications qui produisent ou ont produit du son (pour le menu).
    @Published private(set) var audioApps: [AudioApp] = []
    /// Applications captées à part par le moteur en ce moment (ordre des sources).
    private var activeGroups: [AppTapGroup] = []
    private var activeAppKeys: [String] = []

    @Published private(set) var status = String(localized: "Désactivé")
    @Published private(set) var hasError = false

    let engine = AudioEngine()
    private var applyingPreset = false
    private var loading = true
    private let defaults = UserDefaults.standard

    var sampleRate: Double { engine.sampleRate }

    var settings: EQSettings { EQSettings(mode: mode, gains: gains, preamp: preamp, filters: filters) }

    /// Le préréglage sélectionné est un préréglage personnel (modifiable).
    var selectedUserPreset: EQPreset? {
        guard let name = selectedPreset else { return nil }
        return userPresets.first { $0.name == name }
    }

    var allPresets: [EQPreset] { Self.presets + userPresets }

    /// Nom affiché d'un préréglage (traduit s'il est fourni avec l'app).
    func display(_ name: String) -> String { preset(named: name)?.displayName ?? name }

    var presetTitle: String {
        guard let name = selectedPreset else { return Self.customDisplayName }
        return isModified ? String(localized: "\(display(name)) (modifié)") : display(name)
    }

    func preset(named name: String) -> EQPreset? { allPresets.first { $0.name == name } }

    private init() {
        let defaults = UserDefaults.standard
        func decode<T: Decodable>(_ key: String, _ type: T.Type) -> T? {
            defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
        }
        let saved = defaults.array(forKey: "gains") as? [Double]
        gains = (saved?.count == Self.frequencies.count) ? saved! : Self.presets[0].gains
        preamp = defaults.object(forKey: "preamp") as? Double ?? 0
        mode = defaults.string(forKey: "mode").flatMap(EQMode.init(rawValue:)) ?? .graphic
        filters = decode("filters", [EQFilter].self) ?? EQFilter.defaultBands
        enabled = defaults.object(forKey: "enabled") as? Bool ?? true
        userPresets = decode("userPresets", [EQPreset].self) ?? []
        isModified = defaults.bool(forKey: "modified")
        perDevice = defaults.object(forKey: "perDevice") as? Bool ?? true
        limiterEnabled = defaults.object(forKey: "limiter") as? Bool ?? true
        leveler = defaults.integer(forKey: "leveler").clamped(to: 0...3)
        crossfeed = defaults.bool(forKey: "crossfeed")
        mono = defaults.bool(forKey: "mono")
        balance = (defaults.object(forKey: "balance") as? Double ?? 0).clamped(to: -1...1)
        widening = defaults.integer(forKey: "widening").clamped(to: 0...4)
        listeningDistance = (defaults.object(forKey: "listeningDistance") as? Int ?? 1).clamped(to: 0...2)
        hotkeysEnabled = defaults.object(forKey: "hotkeys") as? Bool ?? true
        notificationsEnabled = defaults.object(forKey: "notifications") as? Bool ?? true
        showSpectrum = defaults.object(forKey: "showSpectrum") as? Bool ?? true
        showCorrectionLayer = defaults.object(forKey: "showCorrectionLayer") as? Bool ?? true
        showNightLayer = defaults.object(forKey: "showNightLayer") as? Bool ?? true
        deviceSettings = decode("deviceSettings", [String: DeviceSetting].self) ?? [:]
        correction = decode("correction", HeadphoneProfile.self)
        correctionEnabled = defaults.object(forKey: "correctionOn") as? Bool ?? true
        appRules = decode("appRules", [AppRule].self) ?? []
        // Ancienne version : « Personnalisé » était enregistré comme nom de préréglage.
        let name = defaults.string(forKey: "preset") ?? Self.presets[0].name
        let known = Self.presets.contains { $0.name == name } || userPresets.contains { $0.name == name }
        selectedPreset = known ? name : nil
        loading = false

        engine.onRouteChange = { [weak self] in
            guard let self, self.enabled else { return }
            self.startEngine()
        }
        engine.onProcessesChange = { [weak self] in self?.processesChanged() }
    }

    /// À appeler une fois l'app lancée.
    func launch() {
        refreshApps()
        if enabled { startEngine() }
    }

    func shutdown() {
        engine.stop()
    }

    private func settingsChanged() {
        guard !loading else { return }
        if !applyingPreset { isModified = true }
        push()
        save()
    }

    // MARK: - Préréglages

    /// Réglage complet décrit par un préréglage.
    func settings(of p: EQPreset) -> EQSettings {
        let m = p.mode ?? .graphic
        let fs = p.filters ?? EQFilter.defaultBands
        let maxGain = m == .graphic ? (p.gains.max() ?? 0) : (fs.filter(\.enabled).map(\.gain).max() ?? 0)
        // Préréglages fournis : marge pour éviter la saturation quand des bandes sont amplifiées.
        return EQSettings(mode: m, gains: p.gains, preamp: p.preamp ?? -(max(0, maxGain) / 2).rounded(), filters: fs)
    }

    func apply(_ preset: EQPreset) {
        let s = settings(of: preset)
        applyingPreset = true
        mode = s.mode
        gains = s.gains
        if s.mode == .parametric { filters = s.filters }
        preamp = s.preamp
        applyingPreset = false
        selectedPreset = preset.name
        isModified = false
        push()
        save()
    }

    /// Graphique : préréglage « Plat ». Paramétrique : bandes remises à 0 dB.
    func reset() {
        if mode == .graphic {
            apply(Self.presets[0])
        } else {
            applyingPreset = true
            filters = EQFilter.defaultBands
            preamp = 0
            applyingPreset = false
            selectedPreset = nil
            isModified = false
            push()
            save()
        }
    }

    /// Message d'erreur si le nom ne convient pas, sinon nil.
    func validateName(_ raw: String, excluding current: String? = nil) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return String(localized: "Donnez un nom au préréglage.") }
        if name.count > Self.maxNameLength { return String(localized: "Nom trop long (\(Self.maxNameLength) caractères max).") }
        if name.compare(Self.customName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
            return String(localized: "Ce nom est réservé.")
        }
        let taken = allPresets.contains {
            $0.name != current
                && $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        return taken ? String(localized: "Un préréglage porte déjà ce nom.") : nil
    }

    private func currentAsPreset(named name: String) -> EQPreset {
        EQPreset(name: name, gains: gains, preamp: preamp, mode: mode,
                 filters: mode == .parametric ? filters : nil)
    }

    /// Enregistre les réglages actuels comme nouveau préréglage. Renvoie un message d'erreur éventuel.
    @discardableResult
    func saveAs(_ raw: String) -> String? {
        if let error = validateName(raw) { return error }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        userPresets.append(currentAsPreset(named: name))
        sortUserPresets()
        selectedPreset = name
        isModified = false
        save()
        return nil
    }

    /// Remplace le préréglage personnel sélectionné par les réglages actuels.
    func updateSelected() {
        guard let name = selectedUserPreset?.name,
              let i = userPresets.firstIndex(where: { $0.name == name }) else { return }
        userPresets[i] = currentAsPreset(named: name)
        isModified = false
        push()  // les applications qui utilisent ce préréglage en profitent
        save()
    }

    @discardableResult
    func renameSelected(to raw: String) -> String? {
        guard let old = selectedUserPreset?.name else { return nil }
        return renamePreset(old, to: raw)
    }

    /// Renomme un préréglage personnel. Renvoie un message d'erreur éventuel.
    @discardableResult
    func renamePreset(_ old: String, to raw: String) -> String? {
        guard let i = userPresets.firstIndex(where: { $0.name == old }) else { return nil }
        if let error = validateName(raw, excluding: old) { return error }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        userPresets[i].name = name
        sortUserPresets()
        // Les sorties et applications qui utilisaient ce préréglage suivent le nouveau nom.
        for (uid, setting) in deviceSettings where setting.preset == old {
            deviceSettings[uid]?.preset = name
        }
        for i in appRules.indices where appRules[i].preset == old { appRules[i].preset = name }
        if selectedPreset == old { selectedPreset = name }
        save()
        return nil
    }

    func deleteSelected() {
        guard let name = selectedUserPreset?.name else { return }
        deletePreset(name)
    }

    /// Supprime un préréglage personnel. Les réglages en cours ne bougent pas.
    func deletePreset(_ name: String) {
        guard userPresets.contains(where: { $0.name == name }) else { return }
        userPresets.removeAll { $0.name == name }
        // Les applications qui l'utilisaient reviennent à l'égaliseur principal.
        appRules.removeAll { $0.preset == name }
        if selectedPreset == name {
            selectedPreset = nil
            isModified = false
        }
        restartIfGroupsChanged()
        push()
        save()
    }

    /// Ajoute un préréglage personnel tout fait (test auditif, fichier importé).
    func addUserPreset(_ p: EQPreset) {
        userPresets.append(p)
        sortUserPresets()
        save()
    }

    private func sortUserPresets() {
        userPresets.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - Mode paramétrique

    /// Ajoute une bande. Sans fréquence imposée (bouton +), elle se place à la suite
    /// de la dernière bande (une octave au-dessus), ou à défaut dans le plus grand espace libre.
    func addBand(at frequency: Double? = nil, gain: Double = 0) -> UUID? {
        guard filters.count < Self.maxParametricBands else { return nil }
        let f = frequency ?? nextBandFrequency()
        let band = EQFilter(kind: .peak, frequency: f.clamped(to: EQFilter.frequencyRange),
                            gain: gain.clamped(to: EQFilter.gainRange), q: 1)
        var list = filters
        list.append(band)
        filters = Self.sortedByFrequency(list)
        return band.id
    }

    /// Fréquence proposée pour une nouvelle bande.
    func nextBandFrequency() -> Double {
        let freqs = filters.map(\.frequency).sorted()
        guard let highest = freqs.last else { return 1000 }
        // À la suite de la dernière, si on reste sous 16 kHz.
        if highest * 2 <= 16_000 { return Self.roundFrequency(highest * 2) }
        // Sinon, au milieu (en octaves) du plus grand espace libre entre 20 Hz et 20 kHz.
        let bounds = [EQFilter.frequencyRange.lowerBound] + freqs + [EQFilter.frequencyRange.upperBound]
        let gaps = zip(bounds, bounds.dropFirst()).map { ($0, $1, log2($1 / $0)) }
        let widest = gaps.max { $0.2 < $1.2 }!
        return Self.roundFrequency((widest.0 * widest.1).squareRoot())
    }

    /// Remet les bandes dans l'ordre des fréquences : numéros 1, 2, 3… de gauche à droite.
    func sortBands() {
        let sorted = Self.sortedByFrequency(filters)
        if sorted.map(\.id) != filters.map(\.id) { filters = sorted }
    }

    private static func sortedByFrequency(_ list: [EQFilter]) -> [EQFilter] {
        list.enumerated().sorted { a, b in
            a.element.frequency != b.element.frequency ? a.element.frequency < b.element.frequency : a.offset < b.offset
        }.map(\.element)
    }

    /// 3 chiffres significatifs (ex. 1 234 → 1 230 Hz).
    private static func roundFrequency(_ f: Double) -> Double {
        let p = pow(10, floor(log10(f)) - 2)
        return (f / p).rounded() * p
    }

    func removeBand(_ id: UUID) {
        filters.removeAll { $0.id == id }
    }

    // MARK: - Correction de casque

    func setCorrection(_ profile: HeadphoneProfile?) {
        correction = profile
        if profile != nil { correctionEnabled = true }
        push()
        save()
    }

    // MARK: - Réglage par sortie audio

    /// Bascule sur la sortie `uid` : charge son réglage mémorisé s'il existe.
    /// Une sortie jamais vue reprend le réglage en cours, mais pas la correction de casque.
    func switchDevice(to uid: String, name: String) {
        let changed = uid != currentDevice?.uid
        let hadDevice = currentDevice != nil
        defer {
            // Pas de bulle au lancement : seulement quand on change vraiment de sortie.
            if changed, hadDevice {
                let what = perDevice ? (correction.map { "\(presetTitle) + \($0.name)" } ?? presetTitle) : String(localized: "même réglage")
                notify("\(name) · \(what)", symbol: "hifispeaker.2")
            }
        }
        // D'abord changer de sortie : chaque modification ci-dessous déclenche save(),
        // qui doit écrire dans la nouvelle sortie et non écraser l'ancienne.
        currentDevice = (uid, name)
        outputIsSpeakers = AudioEngine.defaultOutputIsSpeakers()
        defer { push(); save() }
        guard perDevice, changed else { return }
        guard let setting = deviceSettings[uid] else {
            // La correction d'un casque ne s'applique pas à un autre appareil, ni l'élargissement.
            correction = nil
            widening = 0
            listeningDistance = 1
            return
        }
        applyingPreset = true
        mode = setting.mode ?? .graphic
        if setting.gains.count == Self.frequencies.count { gains = setting.gains }
        if let fs = setting.filters { filters = fs }
        preamp = setting.preamp
        applyingPreset = false
        let known = setting.preset.map { preset(named: $0) != nil } ?? false
        selectedPreset = known ? setting.preset : nil
        isModified = known ? setting.modified : false
        correction = setting.correction
        correctionEnabled = setting.correctionOn ?? true
        widening = setting.widening ?? 0
        listeningDistance = setting.distance ?? 1
    }

    /// Nombre de sorties ayant un réglage mémorisé (pour l'affichage).
    var rememberedDeviceCount: Int { deviceSettings.count }

    /// Sorties mémorisées, pour l'affichage : nom, préréglage, correction éventuelle.
    var rememberedDevices: [(id: String, name: String, preset: String, correction: String?)] {
        deviceSettings.map { uid, s in
            (uid, s.name, s.preset.map(display) ?? Self.customDisplayName, s.correction.map(\.name))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - Égaliseur par application

    func choice(for bundleID: String) -> AppChoice {
        guard let rule = appRules.first(where: { $0.bundleID == bundleID }) else { return .main }
        return rule.preset.map(AppChoice.preset) ?? .bypass
    }

    /// Faux si la limite d'applications réglées à part est atteinte.
    @discardableResult
    func setChoice(_ choice: AppChoice, for app: AudioApp) -> Bool {
        let existing = appRules.firstIndex { $0.bundleID == app.bundleID }
        switch choice {
        case .main:
            if let i = existing { appRules.remove(at: i) }
        case .bypass, .preset:
            let presetName: String? = { if case .preset(let n) = choice { return n } else { return nil } }()
            if let i = existing {
                appRules[i].preset = presetName
            } else {
                guard appRules.count < Self.maxAppRules else { return false }
                appRules.append(AppRule(bundleID: app.bundleID, name: app.name, preset: presetName))
            }
        }
        save()
        if !restartIfGroupsChanged() { push() }
        return true
    }

    /// Applications à afficher : celles qui jouent du son, plus celles déjà réglées.
    /// Applications de la page Applications : toutes celles qui ont utilisé le son, plus celles déjà réglées.
    var appPageItems: [AudioApp] {
        var items = audioApps
        for rule in appRules where !items.contains(where: { $0.bundleID == rule.bundleID }) {
            items.append(AudioApp(bundleID: rule.bundleID, name: AppAudio.displayName(for: rule.bundleID) ?? rule.name,
                                  isPlaying: false, objects: []))
        }
        return items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var appMenuItems: [AudioApp] {
        var items = audioApps.filter { app in
            app.isPlaying || appRules.contains { $0.bundleID == app.bundleID }
        }
        for rule in appRules where !items.contains(where: { $0.bundleID == rule.bundleID }) {
            items.append(AudioApp(bundleID: rule.bundleID,
                                  name: AppAudio.displayName(for: rule.bundleID) ?? rule.name,
                                  isPlaying: false, objects: []))
        }
        return items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func refreshApps() {
        let apps = AppAudio.apps(from: AudioEngine.audioProcesses())
        if apps != audioApps { audioApps = apps }
    }

    private func processesChanged() {
        refreshApps()
        restartIfGroupsChanged()
    }

    /// Groupes de processus à capter à part, d'après les règles et les applications présentes.
    private func desiredGroups() -> [AppTapGroup] {
        appRules.compactMap { rule in
            guard let app = audioApps.first(where: { $0.bundleID == rule.bundleID }), !app.objects.isEmpty else { return nil }
            return AppTapGroup(key: rule.bundleID, objects: app.objects.sorted())
        }
    }

    /// Redémarre le moteur si les applications à capter à part ont changé. Vrai si redémarré.
    @discardableResult
    private func restartIfGroupsChanged() -> Bool {
        guard enabled, engine.isRunning else { return false }
        refreshApps()
        guard desiredGroups() != activeGroups else { return false }
        startEngine()
        return true
    }

    // MARK: - Moteur audio

    private func chainConfig(_ s: EQSettings, rate: Double) -> ChainConfig {
        ChainConfig(filters: EQMath.chain(s, sampleRate: rate), preampDB: s.preamp)
    }

    private func push(reset: Bool = false, sampleRate: Double? = nil) {
        guard !loading else { return }
        let rate = sampleRate ?? engine.sampleRate
        var sources = [chainConfig(settings, rate: rate)]
        for key in activeAppKeys {
            switch choice(for: key) {
            case .main: sources.append(sources[0])
            case .bypass: sources.append(.neutral)
            case .preset(let name):
                sources.append(preset(named: name).map { chainConfig(settings(of: $0), rate: rate) } ?? .neutral)
            }
        }
        var post = ChainConfig.neutral
        if correctionEnabled, let c = correction {
            post = ChainConfig(filters: c.filters.map { EQMath.coefficients($0, sampleRate: rate) }, preampDB: c.preamp)
        }
        if comparing {
            engine.processor.update(sources: sources.map { _ in .neutral }, post: .neutral, sampleRate: rate,
                                    limiter: limiterEnabled, output: OutputOptions(), reset: reset)
            return
        }
        engine.processor.update(sources: sources, post: post, sampleRate: rate,
                                limiter: limiterEnabled, output: outputOptions, reset: reset)
    }

    private func startEngine() {
        // Charger le réglage de la sortie avant de démarrer : pas d'instant avec le mauvais réglage.
        if let output = AudioEngine.defaultOutputInfo() {
            switchDevice(to: output.uid, name: output.name)
        }
        refreshApps()
        let groups = desiredGroups()
        do {
            try engine.start(groups: groups) { rate, keys in
                self.activeAppKeys = keys
                self.push(reset: true, sampleRate: rate)
            }
            activeGroups = groups
            status = engine.outputName.isEmpty ? String(localized: "Actif") : String(localized: "Actif · \(engine.outputName)")
            hasError = false
        } catch {
            activeGroups = []
            activeAppKeys = []
            status = error.localizedDescription
            hasError = true
        }
        objectWillChange.send()
    }

    private func stopEngine() {
        engine.stop()
        activeGroups = []
        activeAppKeys = []
        status = String(localized: "Désactivé")
        hasError = false
    }

    private func save() {
        guard !loading else { return }
        func encode<T: Encodable>(_ value: T?, _ key: String) {
            if let value, let data = try? JSONEncoder().encode(value) {
                defaults.set(data, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        defaults.set(gains, forKey: "gains")
        defaults.set(preamp, forKey: "preamp")
        defaults.set(mode.rawValue, forKey: "mode")
        encode(filters, "filters")
        defaults.set(enabled, forKey: "enabled")
        // « Personnalisé » plutôt que rien : une clé absente ramènerait « Plat » au lancement.
        defaults.set(selectedPreset ?? Self.customName, forKey: "preset")
        defaults.set(isModified, forKey: "modified")
        encode(userPresets, "userPresets")
        defaults.set(perDevice, forKey: "perDevice")
        defaults.set(limiterEnabled, forKey: "limiter")
        defaults.set(leveler, forKey: "leveler")
        defaults.set(crossfeed, forKey: "crossfeed")
        defaults.set(widening, forKey: "widening")
        defaults.set(listeningDistance, forKey: "listeningDistance")
        defaults.set(mono, forKey: "mono")
        defaults.set(balance, forKey: "balance")
        defaults.set(hotkeysEnabled, forKey: "hotkeys")
        defaults.set(notificationsEnabled, forKey: "notifications")
        defaults.set(showSpectrum, forKey: "showSpectrum")
        defaults.set(showCorrectionLayer, forKey: "showCorrectionLayer")
        defaults.set(showNightLayer, forKey: "showNightLayer")
        encode(correction, "correction")
        defaults.set(correctionEnabled, forKey: "correctionOn")
        encode(appRules, "appRules")
        if let device = currentDevice {
            // Toujours tenu à jour, même option coupée : la réactiver repart d'un état juste.
            deviceSettings[device.uid] = DeviceSetting(
                name: device.name, gains: gains, preamp: preamp,
                preset: selectedPreset, modified: isModified,
                mode: mode, filters: filters,
                correction: correction, correctionOn: correctionEnabled,
                widening: widening, distance: listeningDistance)
        }
        encode(deviceSettings, "deviceSettings")
    }
}

extension Comparable {
    func clamped(to r: ClosedRange<Self>) -> Self { min(max(self, r.lowerBound), r.upperBound) }
}
