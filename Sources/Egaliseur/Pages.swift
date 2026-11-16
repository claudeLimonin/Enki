import AppKit
import Combine
import SwiftUI

// MARK: - Casque

struct HeadphonesPage: View {
    @EnvironmentObject var model: EQModel
    @StateObject private var search = HeadphoneSearch()

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Form {
                Section {
                    LabeledContent("Sortie actuelle") { Text(model.currentDevice?.name ?? "—") }
                    Toggle("Corriger le rendu du casque", isOn: $model.correctionEnabled)
                        .disabled(model.correction == nil)
                    LabeledContent("Profil") {
                        Text(model.correction?.name ?? String(localized: "Aucun : choisissez votre casque à droite"))
                            .foregroundStyle(model.correction == nil ? .secondary : .primary)
                            .multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Button("Importer un fichier ParametricEQ…") { importCorrectionFile(into: model) }
                        Spacer()
                        if model.correction != nil {
                            Button("Retirer la correction", role: .destructive) { model.setCorrection(nil) }
                        }
                    }
                } footer: {
                    Text("La correction est mémorisée pour cette sortie uniquement.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Avant / après") {
                    CorrectionCurveView(filters: model.correction?.filters ?? [], sampleRate: model.sampleRate)
                        .frame(height: 230)
                    HStack(spacing: 16) {
                        legend(.orange, dashed: false, "Rendu estimé du casque")
                        legend(.purple, dashed: true, "Correction")
                        legend(.primary, dashed: false, "Cible neutre")
                    }
                    .font(.caption)
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 420)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Trouver mon casque").font(.headline)
                if search.loadingIndex {
                    ProgressView("Chargement de la liste des casques…").controlSize(.small)
                }
                if let error = search.error {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
                List {
                    if search.query.isEmpty {
                        Text("Tapez le nom de votre casque dans le champ de recherche, en haut à droite.")
                            .foregroundStyle(.secondary)
                    } else if search.results.isEmpty && !search.loadingIndex {
                        Text("Aucun casque trouvé. Essayez avec moins de mots (ex. « HD 650 »).").foregroundStyle(.secondary)
                    }
                    let recommended = search.results.filter { AutoEQ.isRecommended($0.source) }
                    let others = search.results.filter { !AutoEQ.isRecommended($0.source) }
                    if !recommended.isEmpty {
                        Section("Mesures recommandées") { ForEach(recommended) { row($0) } }
                    }
                    if !others.isEmpty {
                        Section("Autres mesures") { ForEach(others) { row($0) } }
                    }
                }
                .listStyle(.inset)
                .frame(minHeight: 220)
                Text("8 850 profils AutoEQ, calculés à partir de mesures en laboratoire.")
                    .font(.caption).foregroundStyle(.secondary)

                Text("Sorties mémorisées").font(.headline).padding(.top, 6)
                List(model.rememberedDevices, id: \.id) { d in
                    HStack {
                        Text(d.name).lineLimit(1)
                        Spacer()
                        Text(d.correction.map { "\(d.preset) · \($0)" } ?? d.preset)
                            .foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .listStyle(.inset)
                .overlay {
                    if model.rememberedDevices.isEmpty {
                        Text("Aucune sortie mémorisée pour l'instant.").foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: 100, maxHeight: 160)
            }
            .padding(16)
            .frame(width: 360)
        }
        .navigationTitle("Casque")
        .searchable(text: $search.query, placement: .toolbar, prompt: Text("Rechercher un casque"))
        .onAppear { search.prepare() }
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
                if isCurrent { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(search.downloading != nil)
    }

    private func legend(_ color: Color, dashed: Bool, _ text: LocalizedStringKey) -> some View {
        HStack(spacing: 6) {
            Rectangle().fill(.clear).frame(width: 16, height: 2)
                .overlay(Rectangle().stroke(color, style: StrokeStyle(lineWidth: 2, dash: dashed ? [4, 3] : [])))
            Text(text)
        }
    }
}

/// Rendu estimé du casque (inverse de la correction), correction et cible neutre.
struct CorrectionCurveView: View {
    let filters: [EQFilter]
    let sampleRate: Double

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height, dbMax = 15.0
            func x(_ t: Double) -> CGFloat { CGFloat(t) * w }
            func y(_ db: Double) -> CGFloat { h / 2 - CGFloat(db.clamped(to: -dbMax...dbMax) / dbMax) * h / 2 }
            for db in [-12.0, -6, 6, 12] {
                var l = Path(); l.move(to: CGPoint(x: 0, y: y(db))); l.addLine(to: CGPoint(x: w, y: y(db)))
                ctx.stroke(l, with: .color(.secondary.opacity(0.15)))
            }
            var target = Path(); target.move(to: CGPoint(x: 0, y: h / 2)); target.addLine(to: CGPoint(x: w, y: h / 2))
            ctx.stroke(target, with: .color(.primary), lineWidth: 2)
            guard !filters.isEmpty else { return }
            var corr = Path(), phones = Path()
            for i in 0...160 {
                let t = Double(i) / 160
                let f = 20 * pow(1000, t)
                let db = EQMath.responseDB(filters, at: f, sampleRate: sampleRate)
                let a = CGPoint(x: x(t), y: y(db)), b = CGPoint(x: x(t), y: y(-db))
                if i == 0 { corr.move(to: a); phones.move(to: b) } else { corr.addLine(to: a); phones.addLine(to: b) }
            }
            ctx.stroke(phones, with: .color(.orange), lineWidth: 2)
            ctx.stroke(corr, with: .color(.purple), style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
        }
        .background(.quinary, in: RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel(Text("Courbes avant et après correction"))
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
                .width(min: 200, ideal: 280)
                TableColumn("Activité") { app in
                    HStack(spacing: 6) {
                        Circle().fill(app.isPlaying ? Color.green : Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
                        Text(app.isPlaying ? "Joue du son" : "Silencieuse").foregroundStyle(.secondary)
                    }
                }
                .width(min: 120, ideal: 150)
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
                .width(min: 200, ideal: 240)
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
    }
}
