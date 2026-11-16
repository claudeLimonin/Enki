import AppKit
import Combine
import SwiftUI

// MARK: - Casque

struct HeadphonesPage: View {
    @EnvironmentObject var model: EQModel
    @StateObject private var search = HeadphoneSearch()
    @FocusState private var searchFocused: Bool
    @State private var measuring = false

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 16) {
                outputCard
                VStack(alignment: .leading, spacing: 8) {
                    // Titre et bouton Avant | Après : écouter sans puis avec la correction (le reste du réglage ne change pas).
                    HStack(spacing: 10) {
                        Text("Avant / après").fontWeight(.semibold)
                        BeforeAfterPicker(after: Binding(
                            get: { model.correctionAudition != .without },
                            set: { model.correctionAudition = $0 ? .normal : .without }))
                            .disabled(model.correction == nil || !model.correctionEnabled)
                        if model.correctionAudition == .without {
                            Label("Vous écoutez sans la correction", systemImage: "ear")
                                .font(.caption.weight(.medium)).foregroundStyle(.orange)
                        } else if model.correction != nil, model.correctionEnabled {
                            Text("Basculez pour entendre la différence.").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 14) { legends; Spacer(minLength: 0) }
                        .font(.caption)
                    CorrectionCurveView(filters: model.correction?.filters ?? [], sampleRate: model.sampleRate,
                                        measured: model.correctionEnabled ? model.correction?.measured : nil)
                        .frame(minHeight: 240, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Trouver mon casque").fontWeight(.semibold)
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Marque ou modèle (ex. AirPods Pro, HD 650)", text: $search.query)
                            .textFieldStyle(.plain)
                            .focused($searchFocused)
                        if !search.query.isEmpty {
                            Button { search.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                                .accessibilityLabel("Effacer la recherche")
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(.background, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.separator))
                }
                if search.loadingIndex {
                    ProgressView("Chargement de la liste des casques…").controlSize(.small)
                }
                if let error = search.error {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
                if search.query.isEmpty {
                    emptyState
                } else {
                    results
                }
                Text("8 850 profils AutoEQ. Les mesures oratory1990 et crinacle sont les plus fiables.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Sorties mémorisées").fontWeight(.semibold)
                    remembered
                }
                if model.outputIsSpeakers || !model.currentMeasurements.isEmpty {
                    MeasurementHistory()
                }
            }
            .frame(minWidth: 260, idealWidth: 340, maxWidth: 360, maxHeight: .infinity, alignment: .top)
        }
        .padding(20)
        .navigationTitle("Sortie audio")
        .sheet(isPresented: $measuring) { MeasurementSheet() }
        .onDisappear { model.correctionAudition = .normal }
        .onAppear {
            model.refreshOutputKind()
            search.prepare()
            // Sans correction : on invite directement à chercher.
            if model.correction == nil { searchFocused = true }
        }
    }

    // MARK: Sortie actuelle

    private var outputCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "headphones").font(.title2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.currentDevice?.name ?? String(localized: "Aucune sortie")).fontWeight(.semibold).lineLimit(1)
                    Text("Sortie actuelle").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider().padding(.leading, 14)
            HStack {
                Text(model.outputIsSpeakers ? "Corriger le rendu des haut-parleurs" : "Corriger le rendu du casque")
                Spacer()
                Toggle("Corriger le rendu", isOn: $model.correctionEnabled)
                    .toggleStyle(.switch).labelsHidden()
                    .disabled(model.correction == nil)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            Divider().padding(.leading, 14)
            HStack {
                Text("Profil")
                Spacer()
                Menu {
                    Button("Importer un fichier ParametricEQ…") { importCorrectionFile(into: model) }
                    if model.correction != nil {
                        Divider()
                        Button("Retirer la correction", role: .destructive) { model.setCorrection(nil) }
                    }
                } label: {
                    Text(model.correction?.name ?? (model.outputIsSpeakers ? String(localized: "Aucune : mesurez vos haut-parleurs") : String(localized: "Aucun : cherchez votre casque")))
                        .lineLimit(1)
                }
                .fixedSize()
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            if model.outputIsSpeakers {
                Divider().padding(.leading, 14)
                // Haut-parleurs : correction mesurée à la place d'écoute (micro de l'iPhone).
                HStack(spacing: 10) {
                    Image(systemName: "waveform.badge.mic").font(.title3).foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Corriger ces haut-parleurs").fontWeight(.medium)
                        Text("Mesure à votre place d'écoute avec le micro de votre iPhone.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Mesurer…") { measuring = true }
                        .buttonStyle(.borderedProminent)
                        .accessibilityLabel("Mesurer les haut-parleurs")
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
        }
        .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }

    // MARK: Recherche

    private var results: some View {
        let recommended = search.results.filter { AutoEQ.isRecommended($0.source) }
        let others = search.results.filter { !AutoEQ.isRecommended($0.source) }
        return List {
            if search.results.isEmpty && !search.loadingIndex {
                Text("Aucun casque trouvé. Essayez avec moins de mots (ex. « HD 650 »).").foregroundStyle(.secondary)
            }
            if !recommended.isEmpty {
                Section("Mesures recommandées") { ForEach(recommended) { row($0) } }
            }
            if !others.isEmpty {
                Section("Autres mesures") { ForEach(others) { row($0) } }
            }
        }
        .listStyle(.inset)
        .frame(minHeight: 200, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
    }

    /// Avant toute recherche : une invite courte, et le nom de la sortie actuelle comme suggestion.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choisissez votre casque parmi les profils mesurés : son rendu devient plus neutre.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let suggestion = suggestedQuery {
                Button {
                    search.query = suggestion
                } label: {
                    Label("Chercher « \(suggestion) »", systemImage: "magnifyingglass")
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
    }

    /// Nom de la sortie sans le nom du propriétaire (« AirPods Pro de Claude » → « AirPods Pro »).
    private var suggestedQuery: String? {
        guard var name = model.currentDevice?.name, !name.isEmpty else { return nil }
        for sep in [" de ", " d’", " d'", "’s ", "'s "] {
            if let r = name.range(of: sep) { name = String(sep.hasSuffix("s ") ? name[r.upperBound...] : name[..<r.lowerBound]) }
        }
        let builtIn = ["MacBook", "Haut-parleurs", "Speakers", "iMac", "Studio Display"]
        return builtIn.contains(where: name.contains) ? nil : name.trimmingCharacters(in: .whitespaces)
    }

    private var remembered: some View {
        List(model.rememberedDevices, id: \.id) { d in
            HStack {
                Text(d.name).lineLimit(1)
                Spacer()
                Text("\(d.preset) · \(d.correction ?? String(localized: "sans correction"))")
                    .foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .overlay {
            if model.rememberedDevices.isEmpty {
                Text("Aucune sortie mémorisée pour l'instant.").foregroundStyle(.secondary)
            }
        }
        .frame(height: CGFloat(max(1, min(model.rememberedDevices.count, 4))) * 30 + 14)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
    }

    private func row(_ e: AutoEQ.Entry) -> some View {
        let isCurrent = model.correction?.name == "\(e.name) (\(e.source))"
        return Button {
            search.choose(e) { model.setCorrection($0) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(e.name)
                    Text([e.source, e.form].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if search.downloading == e.id { ProgressView().controlSize(.small) }
                if isCurrent { Image(systemName: "checkmark").fontWeight(.bold).foregroundStyle(Color.accentColor) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(search.downloading != nil)
    }

    @ViewBuilder private var legends: some View {
        legend(.orange, dashed: false, model.correction?.measured != nil ? "Rendu mesuré" : "Rendu du casque")
        legend(.purple, dashed: true, "Correction")
        legend(.primary, dashed: false, "Résultat")
    }

    private func legend(_ color: Color, dashed: Bool, _ text: LocalizedStringKey) -> some View {
        HStack(spacing: 6) {
            Rectangle().fill(.clear).frame(width: 14, height: 2)
                .overlay(Rectangle().stroke(color, style: StrokeStyle(lineWidth: 2, dash: dashed ? [4, 3] : [])))
            Text(text).fixedSize()
        }
    }
}

/// Rendu du casque ou des haut-parleurs, correction, et résultat après correction.
/// Profil AutoEQ : rendu estimé (inverse de la correction), résultat neutre.
/// Profil mesuré au micro : rendu réellement mesuré, résultat = mesure + correction.
struct CorrectionCurveView: View {
    let filters: [EQFilter]
    let sampleRate: Double
    var measured: [Double]? = nil

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height - 18, dbMax = 15.0
            func x(_ f: Double) -> CGFloat { CGFloat(log10(f / 20) / 3) * w }
            func y(_ db: Double) -> CGFloat { h / 2 - CGFloat(db.clamped(to: -dbMax...dbMax) / dbMax) * h / 2 }
            let grid = GraphicsContext.Shading.color(.secondary.opacity(0.18))
            for db in [-10.0, 10] {
                var l = Path(); l.move(to: CGPoint(x: 0, y: y(db))); l.addLine(to: CGPoint(x: w, y: y(db)))
                ctx.stroke(l, with: grid)
                ctx.draw(Text(db > 0 ? "+10 dB" : "−10 dB").font(.caption2).foregroundStyle(.secondary),
                         at: CGPoint(x: w - 4, y: y(db) - 2), anchor: .bottomTrailing)
            }
            for f in [100.0, 1000, 10000] {
                var l = Path(); l.move(to: CGPoint(x: x(f), y: 0)); l.addLine(to: CGPoint(x: x(f), y: h))
                ctx.stroke(l, with: grid)
            }
            var zero = Path(); zero.move(to: CGPoint(x: 0, y: h / 2)); zero.addLine(to: CGPoint(x: w, y: h / 2))
            ctx.stroke(zero, with: .color(.secondary.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            for (f, label) in [(20.0, "20 Hz"), (100, "100 Hz"), (1000, "1 kHz"), (10000, "10 kHz")] {
                ctx.draw(Text(label).font(.caption2).foregroundStyle(.secondary),
                         at: CGPoint(x: f == 20 ? 4 : x(f), y: size.height - 2), anchor: f == 20 ? .bottomLeading : .bottom)
            }
            guard !filters.isEmpty else {
                ctx.stroke(zero, with: .color(.primary), lineWidth: 2.4)
                return
            }
            let corr: (Double) -> Double = { EQMath.responseDB(filters, at: $0, sampleRate: sampleRate) }
            func path(_ points: [(Double, Double)]) -> Path {
                var p = Path()
                for (i, pt) in points.enumerated() {
                    let c = CGPoint(x: x(pt.0), y: y(pt.1))
                    i == 0 ? p.move(to: c) : p.addLine(to: c)
                }
                return p
            }
            let grid160 = (0...160).map { 20 * pow(1000, Double($0) / 160) }
            if let measured, measured.count == SpeakerAnalysis.frequencies.count {
                let fs = SpeakerAnalysis.frequencies
                ctx.stroke(path(zip(fs, measured).map { ($0, $1) }), with: .color(.orange), lineWidth: 2.2)
                ctx.stroke(path(grid160.map { ($0, corr($0)) }), with: .color(.purple), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                ctx.stroke(path(zip(fs, measured).map { ($0, $1 + corr($0)) }), with: .color(.primary), lineWidth: 2.4)
            } else {
                ctx.stroke(zero, with: .color(.primary), lineWidth: 2.4)
                ctx.stroke(path(grid160.map { ($0, -corr($0)) }), with: .color(.orange), lineWidth: 2.2)
                ctx.stroke(path(grid160.map { ($0, corr($0)) }), with: .color(.purple), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            }
        }
        .padding(8)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        .accessibilityLabel(Text("Rendu, correction et résultat"))
    }
}

// MARK: - Applications

struct AppsPage: View {
    @EnvironmentObject var model: EQModel
    @State private var filter = ""
    @State private var limitReached = false
    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var items: [AudioApp] {
        let all = model.appPageItems
        guard !filter.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Rechercher une application", text: $filter).textFieldStyle(.plain)
                if !filter.isEmpty {
                    Button { filter = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityLabel("Effacer la recherche")
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .frame(maxWidth: 280)
            .background(.background, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.separator))
            Table(items) {
                TableColumn("Application") { app in
                    HStack(spacing: 8) {
                        Image(nsImage: Self.icon(for: app.bundleID)).resizable().frame(width: 20, height: 20)
                        Text(app.name)
                    }
                }
                .width(min: 160, ideal: 260)
                TableColumn("Activité") { app in
                    HStack(spacing: 6) {
                        Circle().fill(app.isPlaying ? Color.green : Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
                        Text(app.isPlaying ? "Joue du son" : "Silencieuse").foregroundStyle(.secondary)
                    }
                }
                .width(min: 110, ideal: 130)
                TableColumn("Réglage") { app in
                    Picker("Réglage de \(app.name)", selection: Binding(
                        get: { model.choice(for: app.bundleID) },
                        set: { if !model.setChoice($0, for: app) { limitReached = true } })) {
                        Text("Égaliseur principal").tag(AppChoice.main)
                        Text("Sans égalisation").tag(AppChoice.bypass)
                        ForEach(EQModel.presetGroups, id: \.title) { g in
                            Section(g.title) { ForEach(g.presets) { Text($0.displayName).tag(AppChoice.preset($0.name)) } }
                        }
                        if !model.userPresets.isEmpty {
                            Section("Mes préréglages") { ForEach(model.userPresets) { Text($0.displayName).tag(AppChoice.preset($0.name)) } }
                        }
                    }
                    .labelsHidden()
                }
                .width(min: 180, ideal: 200)
            }
            Text("Une application réglée à part ne passe pas par l'égaliseur principal. La correction de la sortie audio et le mode nuit s'appliquent ensuite à toutes les applications.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .navigationTitle("Applications")
        .onAppear { model.refreshApps() }
        .onReceive(refresh) { _ in model.refreshApps() }
        .alert("7 applications au maximum", isPresented: $limitReached) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Remettez une application sur « Égaliseur principal » pour en régler une autre.")
        }
    }

    /// Icône de l'application (celle de Safari pour le son des pages web).
    static func icon(for bundleID: String) -> NSImage {
        let id = bundleID == AppAudio.webKitAudio ? "com.apple.Safari" : bundleID
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
    }
}

// MARK: - Écoute

struct ListeningPage: View {
    @EnvironmentObject var model: EQModel
    @State private var calibrating = false
    /// Largeur disponible, pour choisir une ou deux colonnes.
    @State private var pageWidth: CGFloat = 0


    var body: some View {
        ScrollView {
            // Deux colonnes indépendantes (pas de vide sous un bloc court), une seule si la fenêtre est étroite.
            Group {
                if pageWidth >= 820 {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 18) { nightCard; outputCard; protectionCard }
                            .frame(maxWidth: .infinity, alignment: .top)
                        VStack(alignment: .leading, spacing: 18) { spatialCard; hearingCard }
                            .frame(maxWidth: .infinity, alignment: .top)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 18) { nightCard; spatialCard; outputCard; protectionCard; hearingCard }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { pageWidth = g.size.width }
                    .onChange(of: g.size.width) { _, w in pageWidth = w }
            })
            .padding(20)
        }
        .navigationTitle("Écoute")
        .onAppear { model.refreshOutputKind() }
        .sheet(isPresented: $calibrating) { CalibrationSheet() }
    }

    private var nightCard: some View {
        ListeningCard(title: "Mode nuit",
                      footer: "Abaisse les graves trop forts (explosions) et remonte les dialogues calmes, pour écouter à faible volume. Raccourci : ⌃⌥⌘N.") {
            Picker("Niveau", selection: $model.leveler) {
                ForEach(0..<OutputOptions.levelerNames.count, id: \.self) { Text(OutputOptions.levelerNames[$0]).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var spatialCard: some View {
        ListeningCard(title: "Spatialisation",
                      footer: "Largeur, Immersif et distance sont mémorisés pour cette sortie.") {
            VStack(alignment: .leading, spacing: 12) {
                StereoWidthControl(width: $model.stereoWidth)
                if model.mono {
                    Label("Changer la largeur coupe le mono.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                // Casque : chaque oreille reçoit un peu de l'autre canal.
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Effet enceintes au casque", systemImage: "headphones")
                        Text("Mélange légèrement les canaux, pour un son moins fatigant, plus proche d'enceintes.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Effet enceintes au casque", isOn: $model.crossfeed).toggleStyle(.switch).labelsHidden()
                }
                Divider()
                // Haut-parleurs : annulation de diaphonie, réglée par la distance d'écoute.
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Immersif (haut-parleurs)", systemImage: "hifispeaker.2")
                        Text("Le son semble sortir bien au-delà du Mac. Asseyez-vous face à l'écran, au centre.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Immersif", isOn: $model.immersive).toggleStyle(.switch).labelsHidden()
                }
                if !model.outputIsSpeakers, model.immersive {
                    Label("La sortie actuelle semble être un casque : l'Immersif est fait pour des haut-parleurs.", systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Text("Distance d'écoute")
                    Spacer()
                    Text(OutputOptions.distanceHints[model.listeningDistance])
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                Picker("Distance d'écoute", selection: $model.listeningDistance) {
                    ForEach(0..<OutputOptions.distanceNames.count, id: \.self) { Text(OutputOptions.distanceNames[$0]).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Distance entre vous et l'écran : règle l'Immersif et, au-delà de 100 %, l'intensité de l'élargissement.")
                .disabled(!model.spatialActive)
                // Mesure par la caméra : encadré mis en avant, pour qu'on le remarque.
                HStack(spacing: 10) {
                    Image(systemName: "camera.viewfinder")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Vous ne connaissez pas votre distance ?").fontWeight(.medium)
                        Text("La caméra la mesure en 3 secondes, puis s'éteint.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button("Mesurer…") { calibrating = true }
                        .buttonStyle(.borderedProminent)
                        .help("La caméra s'allume 3 secondes pour estimer votre distance, puis s'éteint.")
                        .accessibilityLabel("Mesurer avec la caméra")
                }
                .padding(10)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor.opacity(0.25)))
            }
        }
    }

    private var outputCard: some View {
        ListeningCard(title: "Sortie",
                      footer: "La balance déplace le son vers la gauche ou la droite : utile si une oreille entend moins bien, ou si vous n'êtes pas au centre des haut-parleurs.") {
            VStack(alignment: .leading, spacing: 12) {
                toggleRow("Mono (même son des deux côtés)", isOn: $model.mono)
                Divider()
                BalanceControl(balance: $model.balance)
            }
        }
    }

    private var protectionCard: some View {
        ListeningCard(title: "Protection",
                      footer: "Baisse le volume un court instant pour éviter la saturation. Avec le mode nuit, il agit rarement : c'est normal.") {
            toggleRow("Limiteur anti-saturation", isOn: $model.limiterEnabled)
        }
    }

    private var hearingCard: some View {
        ListeningCard(title: "Audition", footer: nil) {
            HStack {
                Text("Test auditif")
                Spacer()
                Button("Faire le test…") { HearingTestWindow.show(model: model) }
            }
        }
    }

    /// Libellé à gauche, interrupteur à droite.
    private func toggleRow(_ title: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
            Spacer()
            Toggle(title, isOn: isOn).toggleStyle(.switch).labelsHidden()
        }
    }
}

/// Bloc de la page Écoute : titre, contenu encadré, explication.
struct ListeningCard<Content: View>: View {
    let title: LocalizedStringKey
    let footer: LocalizedStringKey?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).fontWeight(.semibold)
            content
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
            if let footer {
                Text(footer).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Balance gauche / droite, avec sa valeur en clair et des repères sous le curseur.
struct BalanceControl: View {
    @Binding var balance: Double

    private var valueText: String {
        let percent = Int((abs(balance) * 100).rounded())
        if percent == 0 { return String(localized: "Centrée") }
        return balance < 0
            ? String(localized: "Plus à gauche : \(percent) %")
            : String(localized: "Plus à droite : \(percent) %")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Balance gauche / droite")
                Spacer()
                Text(valueText).monospacedDigit().foregroundStyle(balance == 0 ? .secondary : .primary)
                Button("Recentrer") { balance = 0 }
                    .disabled(balance == 0)
                    .controlSize(.small)
            }
            HStack(spacing: 10) {
                Image(systemName: "l.circle").foregroundStyle(.secondary).accessibilityHidden(true)
                VStack(spacing: 2) {
                    Slider(value: $balance, in: -1...1, step: 0.05)
                        .accessibilityLabel("Balance gauche / droite")
                        .accessibilityValue(valueText)
                    HStack {
                        Text("Gauche"); Spacer(); Text("Centre"); Spacer(); Text("Droite")
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                }
                Image(systemName: "r.circle").foregroundStyle(.secondary).accessibilityHidden(true)
            }
        }
    }
}

/// Largeur stéréo : pourcentage, curseur Mono · Original · Élargi, illustration et message.
struct StereoWidthControl: View {
    @Binding var width: Double

    private var percent: Int { Int((width * 100).rounded()) }

    private var message: String {
        switch percent {
        case 0: return String(localized: "Son replié en mono.")
        case ..<100: return String(localized: "Image stéréo resserrée.")
        case 100: return String(localized: "Largeur d'origine.")
        case ..<170: return String(localized: "Image stéréo élargie : les voix restent au centre.")
        default: return String(localized: "Élargissement important : le son peut paraître moins naturel, surtout en mono.")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Largeur stéréo").fontWeight(.semibold)
                Spacer()
                Text("\(percent) %")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            Slider(value: Binding(
                get: { width },
                // Aimanté à 100 % : on retrouve facilement la largeur d'origine.
                set: { v in width = abs(v - 1) < 0.04 ? 1 : (v * 20).rounded() / 20 }),
                   in: OutputOptions.widthRange)
                .accessibilityLabel("Largeur stéréo")
                .accessibilityValue("\(percent) %")
            HStack {
                Button("Mono") { width = 0 }
                Spacer()
                Button("Original") { width = 1 }
                Spacer()
                Button("Élargi") { width = 2 }
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
            StereoWidthIllustration(width: width)
                .frame(height: 150)
            Text(message)
                .font(.caption)
                .foregroundStyle(percent >= 170 ? Color.orange : Color.secondary)
        }
    }
}

/// Illustration de la largeur : ellipses concentriques qui s'étirent avec la largeur (non mesurée sur le son).
struct StereoWidthIllustration: View {
    let width: Double

    var body: some View {
        VStack(spacing: 4) {
            Canvas { ctx, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                var axis = Path()
                axis.move(to: CGPoint(x: center.x, y: 6))
                axis.addLine(to: CGPoint(x: center.x, y: size.height - 6))
                ctx.stroke(axis, with: .color(.secondary.opacity(0.45)), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                let w = CGFloat(width)
                let rx = size.width * 0.21 * w, ry = min(size.height * 0.24 * (0.55 + 0.45 * w), size.height / 2 - 4)
                let colors: [Color] = [.purple, .cyan, .purple, .cyan, .purple]
                for (i, f) in [1.0, 0.84, 0.68, 0.52, 0.36].enumerated() where w > 0.01 {
                    let rect = CGRect(x: center.x - rx * f, y: center.y - ry * f, width: 2 * rx * f, height: 2 * ry * f)
                    ctx.stroke(Path(ellipseIn: rect), with: .color(colors[i].opacity(0.9 - Double(i) * 0.13)), lineWidth: 2)
                }
                ctx.fill(Path(ellipseIn: CGRect(x: center.x - 6, y: center.y - 6, width: 12, height: 12)), with: .color(.purple))
                ctx.draw(Text("G").font(.headline), at: CGPoint(x: 18, y: size.height - 16))
                ctx.draw(Text("D").font(.headline), at: CGPoint(x: size.width - 18, y: size.height - 16))
            }
            .animation(.easeOut(duration: 0.15), value: width)
            Text("Illustration de la largeur stéréo, non mesurée sur le son.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(8)
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
    }
}

// MARK: - Historique des mesures

/// Mesures de la sortie actuelle : mini-courbe, date, qualité ; réappliquer ou supprimer.
struct MeasurementHistory: View {
    @EnvironmentObject var model: EQModel
    @State private var toDelete: MeasurementRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Historique des mesures").fontWeight(.semibold)
                Spacer()
                if !model.currentMeasurements.isEmpty {
                    Text("\(model.currentMeasurements.count)").foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if model.currentMeasurements.isEmpty {
                Text("Aucune mesure pour cette sortie. Chaque mesure réalisée sera gardée ici, appliquée ou non.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quinary, in: RoundedRectangle(cornerRadius: 6))
            } else {
                List(model.currentMeasurements) { record in
                    row(record)
                        .contextMenu {
                            Button("Appliquer cette mesure") { model.setCorrection(record.profile) }
                                .disabled(isApplied(record))
                            Divider()
                            Button("Supprimer…", role: .destructive) { toDelete = record }
                        }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .frame(height: CGFloat(min(model.currentMeasurements.count, 4)) * 46 + 10)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            }
        }
        .confirmationDialog("Supprimer la mesure du \(toDelete.map { Self.dateText($0.date) } ?? "") ?",
                            isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } })) {
            Button("Supprimer", role: .destructive) {
                if let r = toDelete { model.deleteMeasurement(r.id) }
                toDelete = nil
            }
        } message: {
            Text("La correction en cours n'est pas modifiée.")
        }
    }

    private func isApplied(_ r: MeasurementRecord) -> Bool {
        model.correction?.filters == r.profile.filters && model.correction?.measured == r.profile.measured
    }

    static func dateText(_ d: Date) -> String { d.formatted(date: .abbreviated, time: .shortened) }

    private func row(_ r: MeasurementRecord) -> some View {
        HStack(spacing: 10) {
            MiniResponse(levels: r.profile.measured ?? [])
                .frame(width: 64, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.dateText(r.date)).lineLimit(1)
                Text(r.snr > 0 ? "Qualité \(Int(r.snr)) dB · \(r.profile.filters.count) filtres" : "\(r.profile.filters.count) filtres")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if isApplied(r) {
                Label("Appliquée", systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(Color.accentColor)
                    .help("Correction en cours")
            } else {
                Button("Appliquer") { model.setCorrection(r.profile) }
                    .controlSize(.small)
            }
            Button { toDelete = r } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Supprimer cette mesure")
                .accessibilityLabel("Supprimer cette mesure")
        }
        .padding(.vertical, 2)
    }
}

/// Petite courbe de la réponse mesurée (100 Hz – 10 kHz).
struct MiniResponse: View {
    let levels: [Double]

    var body: some View {
        Canvas { ctx, size in
            let fs = SpeakerAnalysis.frequencies
            guard levels.count == fs.count else { return }
            let lo = log(80.0), hi = log(12_000.0)
            var p = Path(), started = false
            for (f, l) in zip(fs, levels) where f >= 80 && f <= 12_000 {
                let pt = CGPoint(x: CGFloat((log(f) - lo) / (hi - lo)) * size.width,
                                 y: size.height / 2 - CGFloat(l.clamped(to: -12...12) / 12) * size.height / 2)
                if started { p.addLine(to: pt) } else { p.move(to: pt); started = true }
            }
            var mid = Path(); mid.move(to: CGPoint(x: 0, y: size.height / 2)); mid.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            ctx.stroke(mid, with: .color(.secondary.opacity(0.3)), style: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
            ctx.stroke(p, with: .color(.orange), lineWidth: 1.5)
        }
        .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
        .accessibilityHidden(true)
    }
}

/// Bouton « Avant | Après » : écouter le son sans puis avec la correction.
struct BeforeAfterPicker: View {
    @Binding var after: Bool

    var body: some View {
        Picker("Écoute", selection: $after) {
            Text("Avant").tag(false)
            Text("Après").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Avant : sans la correction. Après : avec la correction. Le reste du réglage ne change pas.")
        .accessibilityLabel("Écouter avant ou après la correction")
    }
}
