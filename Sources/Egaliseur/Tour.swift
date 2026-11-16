import SwiftUI

/// Éléments de la fenêtre que la visite guidée peut mettre en évidence.
enum TourAnchor: Hashable {
    case power, output, preset, graph, tiles, window
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
                 text: String(localized: "Enki Audio règle le son de tout votre Mac : musique, vidéos, jeux, visioconférences.\n\nIl vit dans la barre des menus, en haut à droite de l'écran. Un clic sur son icône ouvre cette vue rapide ; les réglages fins sont dans la fenêtre Enki Audio.")),
        TourStep(id: 1, anchor: .power,
                 title: String(localized: "Allumer ou couper"),
                 text: String(localized: "Cet interrupteur active l'égaliseur. Juste dessous, l'état indique ce qui se passe."),
                 tryIt: String(localized: "Essayez : coupez puis rallumez pour comparer avec le son d'origine.")),
        TourStep(id: 2, anchor: .output,
                 title: String(localized: "Votre sortie audio"),
                 text: String(localized: "Casque, haut-parleurs… chaque sortie garde son propre réglage. Cliquez ici pour la corriger : profil mesuré de votre casque (plus de 8 000) ou mesure de vos haut-parleurs avec l'iPhone.")),
        TourStep(id: 3, anchor: .preset,
                 title: String(localized: "Les préréglages"),
                 text: String(localized: "Choisissez un réglage tout prêt (Rock, Voix, Basses renforcées…). Vous pourrez enregistrer les vôtres depuis la fenêtre."),
                 tryIt: String(localized: "Essayez : choisissez « Basses renforcées ».")),
        TourStep(id: 4, anchor: .graph,
                 title: String(localized: "Ce que vous entendez"),
                 text: String(localized: "La courbe montre l'effet de vos réglages, et les barres les fréquences de la musique en direct.")),
        TourStep(id: 5, anchor: .tiles,
                 title: String(localized: "Les commandes rapides"),
                 text: String(localized: "Mode nuit pour écouter bas sans perdre les dialogues, spatialisation pour le casque, limiteur contre la saturation (orange quand il agit), mono. Un clic suffit.")),
        TourStep(id: 6, anchor: .window,
                 title: String(localized: "Aller plus loin"),
                 text: String(localized: "La fenêtre Enki Audio (⌃⌥⌘O) donne accès à l'égaliseur complet, au mode paramétrique, à la correction de la sortie audio (casque ou haut-parleurs) et au réglage par application. Les Réglages (⌘,) gardent les options et ce guide.")),
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
        let width: CGFloat = min(hole == nil ? 380 : 300, size.width - 24)
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
        case .window:
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
