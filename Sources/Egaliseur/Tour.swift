import SwiftUI

/// Éléments de la fenêtre que la visite guidée peut mettre en évidence.
enum TourAnchor: Hashable {
    case power, preset, mode, graph, controls, headphone, apps, limiter, settings
}

/// Une étape de la visite guidée.
struct TourStep: Identifiable {
    let id: Int
    let anchor: TourAnchor?
    let title: String
    let text: String
    var tryIt: String? = nil
}

/// Visite guidée de la fenêtre, affichée au premier lancement et relançable depuis ⚙︎.
final class Tour: ObservableObject {
    static let shared = Tour()

    @Published private(set) var index: Int?
    private let defaults = UserDefaults.standard

    /// La visite a été terminée ou passée au moins une fois.
    var completed: Bool { defaults.bool(forKey: "tourCompleted") }

    static let steps: [TourStep] = [
        TourStep(id: 0, anchor: nil,
                 title: String(localized: "Bienvenue dans Enki Audio"),
                 text: String(localized: "Enki Audio règle le son de tout votre Mac : musique, vidéos, jeux, visioconférences.\n\nIl vit dans la barre des menus, en haut à droite de l'écran : la petite flèche au-dessus de cette fenêtre pointe vers son icône. Clic gauche pour ouvrir cette fenêtre, clic droit pour les options.")),
        TourStep(id: 1, anchor: .power,
                 title: String(localized: "Allumer ou couper"),
                 text: String(localized: "Cet interrupteur active l'égaliseur. Juste à gauche, l'état indique la sortie audio utilisée (haut-parleurs, casque…)."),
                 tryIt: String(localized: "Essayez : coupez puis rallumez pour comparer avec le son d'origine.")),
        TourStep(id: 2, anchor: .preset,
                 title: String(localized: "Les préréglages"),
                 text: String(localized: "Choisissez un réglage tout prêt (Rock, Voix, Basses renforcées…), ou enregistrez les vôtres avec « Enregistrer sous… ». Le bouton ↺ remet tout à zéro."),
                 tryIt: String(localized: "Essayez : ouvrez le menu et choisissez « Basses renforcées ».")),
        TourStep(id: 3, anchor: .mode,
                 title: String(localized: "Deux façons de régler"),
                 text: String(localized: "Graphique : 10 curseurs fixes, simple et rapide.\nParamétrique : des bandes libres dont vous choisissez la fréquence, le gain et la largeur, comme en studio. Votre courbe est reprise d'un mode à l'autre.")),
        TourStep(id: 4, anchor: .graph,
                 title: String(localized: "Ce que vous entendez"),
                 text: String(localized: "La courbe montre l'effet de vos réglages. Les barres derrière montrent en direct les fréquences de la musique : vert au repos, jaune puis rouge sur les pics.\n\nEn mode paramétrique, glissez les points numérotés ; double-cliquez pour en ajouter un.")),
        TourStep(id: 5, anchor: .controls,
                 title: String(localized: "Les réglages"),
                 text: String(localized: "Montez un curseur pour renforcer une zone, baissez-le pour l'atténuer : à gauche les graves, à droite les aigus. Le préampli baisse le volume global pour éviter la saturation."),
                 tryIt: String(localized: "Essayez : montez le curseur 64 et écoutez les basses.")),
        TourStep(id: 6, anchor: .headphone,
                 title: String(localized: "Correction de casque"),
                 text: String(localized: "Choisissez votre modèle de casque parmi plus de 8 000 profils mesurés (AutoEQ) : son rendu devient plus neutre. La correction est mémorisée pour ce casque uniquement.")),
        TourStep(id: 7, anchor: .apps,
                 title: String(localized: "Un réglage par application"),
                 text: String(localized: "Donnez à une application son propre réglage : « Voix » pour vos visioconférences, « Rock » pour Spotify… Les autres gardent l'égaliseur principal.")),
        TourStep(id: 8, anchor: .limiter,
                 title: String(localized: "Le limiteur"),
                 text: String(localized: "Il évite que le son sature quand vous renforcez des fréquences. Il s'allume en orange quand il agit ; s'il reste souvent allumé, baissez le préampli. Cliquez dessus pour le couper.")),
        TourStep(id: 9, anchor: .settings,
                 title: String(localized: "Les options"),
                 text: String(localized: "Ouverture au démarrage du Mac, réglage mémorisé par sortie audio, autorisation audio, et ce guide, que vous pourrez revoir à tout moment.")),
    ]

    var step: TourStep? { index.map { Self.steps[$0] } }

    func start() { index = 0 }

    func next() {
        guard let i = index else { return }
        if i + 1 < Self.steps.count { index = i + 1 } else { finish() }
    }

    func previous() {
        guard let i = index, i > 0 else { return }
        index = i - 1
    }

    func finish() {
        index = nil
        defaults.set(true, forKey: "tourCompleted")
    }
}

// MARK: - Repérage des éléments

struct TourAnchorKey: PreferenceKey {
    static var defaultValue: [TourAnchor: Anchor<CGRect>] = [:]
    static func reduce(value: inout [TourAnchor: Anchor<CGRect>], nextValue: () -> [TourAnchor: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Déclare cet élément comme cible possible de la visite guidée.
    func tourAnchor(_ anchor: TourAnchor) -> some View {
        anchorPreference(key: TourAnchorKey.self, value: .bounds) { [anchor: $0] }
    }
}

// MARK: - Affichage

/// Voile sombre percé autour de l'élément présenté, et bulle d'explication.
/// L'élément mis en évidence reste utilisable : on peut essayer pendant la visite.
struct TourOverlay: View {
    @EnvironmentObject var model: EQModel
    @ObservedObject var tour: Tour
    let anchors: [TourAnchor: Anchor<CGRect>]

    var body: some View {
        GeometryReader { geo in
            if let step = tour.step {
                let hole = step.anchor.flatMap { anchors[$0] }.map { geo[$0].insetBy(dx: -6, dy: -6) }
                ZStack(alignment: .topLeading) {
                    // Voile : bloque les clics partout sauf dans le trou.
                    HoleShape(hole: hole)
                        .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
                        .contentShape(HoleShape(hole: hole), eoFill: true)
                        .onTapGesture {}
                    if let hole {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                            .frame(width: hole.width, height: hole.height)
                            .offset(x: hole.minX, y: hole.minY)
                            .allowsHitTesting(false)
                    }
                    callout(step, hole: hole, size: geo.size)
                }
                .animation(.easeInOut(duration: 0.2), value: tour.index)
            }
        }
    }

    @ViewBuilder
    private func callout(_ step: TourStep, hole: CGRect?, size: CGSize) -> some View {
        let width: CGFloat = hole == nil ? 380 : 300
        let card = card(step, width: width)
        if let hole {
            // Sous l'élément s'il est dans la moitié haute, au-dessus sinon.
            let below = hole.midY < size.height / 2
            let x = (hole.midX - width / 2).clamped(to: 12...max(12, size.width - width - 12))
            VStack(spacing: 0) {
                if below {
                    Color.clear.frame(height: hole.maxY + 10)
                    card
                    Spacer(minLength: 0)
                } else {
                    Spacer(minLength: 0)
                    card
                    Color.clear.frame(height: size.height - hole.minY + 10)
                }
            }
            .padding(.leading, x)
            .frame(width: size.width, height: size.height, alignment: .leading)
        } else {
            card.frame(width: size.width, height: size.height)
        }
    }

    private func card(_ step: TourStep, width: CGFloat) -> some View {
        let isFirst = step.id == 0
        let isLast = step.id == Tour.steps.count - 1
        return VStack(alignment: .leading, spacing: 10) {
            if isFirst {
                HStack {
                    Spacer()
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                    Spacer()
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Text(step.title).font(.headline)
                Spacer()
                if !isFirst {
                    Text("\(step.id)/\(Tour.steps.count - 1)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Text(step.text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if let tryIt = step.tryIt {
                Label(tryIt, systemImage: "hand.point.up.left")
                    .font(.callout)
                    .foregroundStyle(Color.accentColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            extra(for: step)
            HStack {
                Button(isLast ? "" : String(localized: "Passer le guide")) { tour.finish() }
                    .buttonStyle(.link)
                    .font(.caption)
                    .opacity(isLast ? 0 : 1)
                    .disabled(isLast)
                Spacer()
                if !isFirst {
                    Button("Précédent") { tour.previous() }
                }
                Button(isFirst ? String(localized: "Commencer la visite") : (isLast ? String(localized: "Terminer") : String(localized: "Suivant"))) { tour.next() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
    }

    /// Commandes intégrées à certaines étapes (guide interactif).
    @ViewBuilder
    private func extra(for step: TourStep) -> some View {
        switch step.anchor {
        case .power where model.hasError:
            VStack(alignment: .leading, spacing: 6) {
                Text("macOS n'a pas encore autorisé Enki Audio à capter le son.")
                    .font(.callout).foregroundStyle(.red)
                Button("Autoriser l'accès audio…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        case .settings:
            Toggle("Ouvrir Enki Audio au démarrage du Mac", isOn: Binding(
                get: { LaunchAtLogin.isEnabled },
                set: { _ in LaunchAtLogin.toggle() }))
                .toggleStyle(.checkbox)
        default:
            EmptyView()
        }
    }
}

/// Rectangle plein percé d'un trou arrondi (remplissage pair-impair).
private struct HoleShape: Shape {
    let hole: CGRect?
    func path(in rect: CGRect) -> Path {
        var p = Path(rect)
        if let hole { p.addRoundedRect(in: hole, cornerSize: CGSize(width: 10, height: 10)) }
        return p
    }
}
