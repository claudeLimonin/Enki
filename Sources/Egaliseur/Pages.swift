import AppKit
import Combine
import SwiftUI

// MARK: - Casque

struct HeadphonesPage: View {
    @EnvironmentObject var model: EQModel
    @StateObject private var search = HeadphoneSearch()
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 16) {
                outputCard
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 16) {
                        Text("Avant / après").fontWeight(.semibold)
                        Spacer()
                        legend(.orange, dashed: false, "Rendu du casque")
                        legend(.purple, dashed: true, "Correction")
                        legend(.primary, dashed: false, "Résultat")
                    }
                    .font(.caption)
                    CorrectionCurveView(filters: model.correction?.filters ?? [], sampleRate: model.sampleRate)
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
            }
            .frame(minWidth: 260, idealWidth: 340, maxWidth: 360, maxHeight: .infinity, alignment: .top)
        }
        .padding(20)
        .navigationTitle("Casque")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Toggle("Égaliseur", isOn: $model.enabled)
                    .toggleStyle(.switch)
                    .help(model.enabled ? "Couper l'égaliseur" : "Activer l'égaliseur")
            }
        }
        .onAppear {
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
                Text("Corriger le rendu du casque")
                Spacer()
                Toggle("Corriger le rendu du casque", isOn: $model.correctionEnabled)
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
                    Text(model.correction?.name ?? String(localized: "Aucun : cherchez votre casque"))
                        .lineLimit(1)
                }
                .fixedSize()
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
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

    private func legend(_ color: Color, dashed: Bool, _ text: LocalizedStringKey) -> some View {
        HStack(spacing: 6) {
            Rectangle().fill(.clear).frame(width: 14, height: 2)
                .overlay(Rectangle().stroke(color, style: StrokeStyle(lineWidth: 2, dash: dashed ? [4, 3] : [])))
            Text(text)
        }
    }
}

/// Rendu estimé du casque (inverse de la correction), correction, et résultat après correction (neutre).
struct CorrectionCurveView: View {
    let filters: [EQFilter]
    let sampleRate: Double

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height - 18, dbMax = 15.0
            func x(_ f: Double) -> CGFloat { CGFloat(log10(f / 20) / 3) * w }
            func y(_ db: Double) -> CGFloat { h / 2 - CGFloat(db.clamped(to: -dbMax...dbMax) / dbMax) * h / 2 }
            let grid = GraphicsContext.Shading.color(.secondary.opacity(0.18))
            for db in [-10.0, 10] {
                var l = Path(); l.move(to: CGPoint(x: 0, y: y(db))); l.addLine(to: CGPoint(x: w, y: y(db)))
                ctx.stroke(l, with: grid)
            }
            for f in [100.0, 1000, 10000] {
                var l = Path(); l.move(to: CGPoint(x: x(f), y: 0)); l.addLine(to: CGPoint(x: x(f), y: h))
                ctx.stroke(l, with: grid)
            }
            var zero = Path(); zero.move(to: CGPoint(x: 0, y: h / 2)); zero.addLine(to: CGPoint(x: w, y: h / 2))
            ctx.stroke(zero, with: .color(.secondary.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            for (f, label) in [(20.0, "20 Hz"), (100, "100"), (1000, "1 k"), (10000, "10 k"), (20000, "20 kHz")] {
                let anchor: UnitPoint = f == 20 ? .bottomLeading : (f == 20000 ? .bottomTrailing : .bottom)
                let px = f == 20 ? 8 : (f == 20000 ? w - 8 : x(f))
                ctx.draw(Text(label).font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: px, y: size.height - 2), anchor: anchor)
            }
            // Résultat : rendu du casque + correction ≈ neutre.
            ctx.stroke(zero, with: .color(.primary), lineWidth: 2.4)
            guard !filters.isEmpty else { return }
            var corr = Path(), phones = Path()
            for i in 0...160 {
                let f = 20 * pow(1000, Double(i) / 160)
                let db = EQMath.responseDB(filters, at: f, sampleRate: sampleRate)
                let a = CGPoint(x: x(f), y: y(db)), b = CGPoint(x: x(f), y: y(-db))
                if i == 0 { corr.move(to: a); phones.move(to: b) } else { corr.addLine(to: a); phones.addLine(to: b) }
            }
            ctx.stroke(phones, with: .color(.orange), lineWidth: 2.2)
            ctx.stroke(corr, with: .color(.purple), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
        }
        .padding(8)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        .accessibilityLabel(Text("Rendu du casque, correction et résultat"))
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
                        Divider()
                        ForEach(model.allPresets) { Text($0.displayName).tag(AppChoice.preset($0.name)) }
                    }
                    .labelsHidden()
                }
                .width(min: 180, ideal: 200)
            }
            Text("Une application réglée à part ne passe pas par l'égaliseur principal. La correction de casque et le mode nuit s'appliquent ensuite à toutes les applications.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .navigationTitle("Applications")
        .navigationSubtitle(Text("\(model.appRules.count) sur 7 réglées à part"))
        .searchable(text: $filter, placement: .toolbar, prompt: Text("Rechercher"))
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

    var body: some View {
        Form {
            Section {
                Picker("Niveau", selection: $model.leveler) {
                    ForEach(0..<OutputOptions.levelerNames.count, id: \.self) { Text(OutputOptions.levelerNames[$0]).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Mode nuit")
            } footer: {
                Text("Abaisse les graves trop forts (explosions) et remonte les dialogues calmes, pour écouter à faible volume. Raccourci : ⌃⌥⌘N.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Spatialisation casque", isOn: $model.crossfeed)
            } header: {
                Text("Casque")
            } footer: {
                Text("Mélange légèrement les canaux gauche et droit, pour un son moins fatigant, plus proche d'enceintes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Sortie") {
                Toggle("Mono", isOn: $model.mono)
                LabeledContent("Balance") {
                    HStack(spacing: 8) {
                        Text("G").foregroundStyle(.secondary)
                        Slider(value: $model.balance, in: -1...1, step: 0.05).frame(width: 220)
                        Text("D").foregroundStyle(.secondary)
                        Button("Centrer") { model.balance = 0 }.disabled(model.balance == 0)
                    }
                }
            }
            Section {
                Toggle("Limiteur anti-saturation", isOn: $model.limiterEnabled)
            } header: {
                Text("Protection")
            } footer: {
                Text("Baisse le volume un court instant pour éviter la saturation. Avec le mode nuit, il agit rarement : c'est normal.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Audition") {
                LabeledContent("Test auditif") {
                    Button("Faire le test…") { HearingTestWindow.show(model: model) }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Écoute")
        .toolbar {
            // Même barre d'outils que les autres pages : la fenêtre ne change pas d'aspect.
            ToolbarItem(placement: .primaryAction) {
                Toggle("Égaliseur", isOn: $model.enabled)
                    .toggleStyle(.switch)
                    .help(model.enabled ? "Couper l'égaliseur" : "Activer l'égaliseur")
            }
        }
    }
}
