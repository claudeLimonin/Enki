import SwiftUI

// MARK: - Préréglages : menu et saisie d'un nom (partagés par la fenêtre)

/// Demande d'un nom de préréglage (enregistrer sous / renommer).
struct PresetNameRequest: Identifiable {
    enum Kind { case saveAs, rename(String) }
    let kind: Kind
    var id: String { if case .rename(let n) = kind { return "rename-" + n } else { return "save" } }
}

/// Feuille standard de saisie du nom, avec message d'erreur.
struct PresetNameSheet: View {
    @EnvironmentObject var model: EQModel
    @Environment(\.dismiss) private var dismiss
    let request: PresetNameRequest
    @State private var name = ""
    @State private var error: String?

    private var isRename: Bool { if case .rename = request.kind { return true } else { return false } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isRename ? "Renommer le préréglage" : "Enregistrer les réglages actuels").font(.headline)
            TextField("Nom du préréglage", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)
                .onChange(of: name) { _, _ in error = nil }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Annuler") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isRename ? "Renommer" : "Enregistrer", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { if case .rename(let n) = request.kind { name = n } }
    }

    private func commit() {
        let err: String?
        switch request.kind {
        case .saveAs: err = model.saveAs(name)
        case .rename(let old): err = model.renamePreset(old, to: name)
        }
        if let err { error = err } else { dismiss() }
    }
}

/// Menu local des préréglages (barre d'outils de la fenêtre).
struct PresetPicker: View {
    @EnvironmentObject var model: EQModel
    @Binding var nameRequest: PresetNameRequest?
    @State private var confirmDelete = false

    var body: some View {
        Menu {
            Section("Préréglages") {
                ForEach(EQModel.presets) { p in Button(p.displayName) { model.apply(p) } }
            }
            if !model.userPresets.isEmpty {
                Section("Mes préréglages") {
                    ForEach(model.userPresets) { p in Button(p.displayName) { model.apply(p) } }
                }
            }
            Divider()
            Button("Enregistrer sous…") { nameRequest = PresetNameRequest(kind: .saveAs) }
            if let p = model.selectedUserPreset {
                Button("Mettre à jour « \(p.name) »") { model.updateSelected() }.disabled(!model.isModified)
                Button("Renommer « \(p.name) »…") { nameRequest = PresetNameRequest(kind: .rename(p.name)) }
                Button("Supprimer « \(p.name) »…") { confirmDelete = true }
            }
        } label: {
            Text(model.presetTitle).lineLimit(1)
        }
        .frame(minWidth: 110, maxWidth: 170)
        .help("Préréglage")
        .confirmationDialog("Supprimer « \(model.selectedUserPreset?.name ?? "") » ?", isPresented: $confirmDelete) {
            Button("Supprimer", role: .destructive) { model.deleteSelected() }
        } message: {
            Text("Les réglages en cours restent tels quels.")
        }
    }
}

// MARK: - Page Égaliseur

struct EqualizerPage: View {
    @EnvironmentObject var model: EQModel
    @State private var selectedBand: UUID?
    @State private var nameRequest: PresetNameRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                Text("Afficher :").foregroundStyle(.secondary)
                Toggle("Correction casque", isOn: $model.showCorrectionLayer)
                    .disabled(model.correction == nil)
                Toggle("Mode nuit", isOn: $model.showNightLayer)
                    .disabled(model.leveler == 0)
                Toggle("Spectre", isOn: $model.showSpectrum)
                Spacer()
                if model.comparing {
                    Label("Son d'origine", systemImage: "speaker.wave.2")
                        .foregroundStyle(.orange)
                        .font(.callout.weight(.semibold))
                }
            }
            .toggleStyle(.checkbox)

            SeparateAppsNote()

            SpectrumPanel(selectedBand: $selectedBand)
                .frame(minHeight: 240, maxHeight: 520)

            Group {
                if model.mode == .graphic {
                    GraphicSliders()
                } else {
                    BandsTable(selected: $selectedBand)
                }
            }
            .opacity(model.enabled ? 1 : 0.5)
        }
        .padding(20)
        .navigationTitle("Égaliseur")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("Mode", selection: $model.mode) {
                    ForEach(EQMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Graphique : 10 bandes fixes. Paramétrique : bandes libres (fréquence, gain, largeur).")
                PresetPicker(nameRequest: $nameRequest)
                Toggle(isOn: $model.comparing) { Text("Comparer") }
                    .toggleStyle(.button)
                    .help("Écouter le son d'origine, sans aucun traitement, pour comparer.")
                Toggle("Égaliseur", isOn: $model.enabled)
                    .toggleStyle(.switch)
                    .help(model.enabled ? "Couper l'égaliseur" : "Activer l'égaliseur")
            }
        }
        .sheet(item: $nameRequest) { PresetNameSheet(request: $0) }
        .onChange(of: model.mode) { _, _ in selectedBand = nil }
    }
}

/// Curseurs de l'égaliseur graphique (10 bandes + préampli).
struct GraphicSliders: View {
    @EnvironmentObject var model: EQModel

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            band(value: $model.preamp, label: String(localized: "Préampli"), caption: String(localized: "Préampli"), tint: .secondary)
                .frame(width: 64)
            Divider().frame(height: 170).padding(.horizontal, 6)
            ForEach(EQModel.frequencies.indices, id: \.self) { i in
                band(value: $model.gains[i], label: "\(EQModel.labels[i]) hertz", caption: EQModel.labels[i], tint: .accentColor)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 180)
    }

    private func band(value: Binding<Double>, label: String, caption: String, tint: Color) -> some View {
        VStack(spacing: 6) {
            Text(formatDB(value.wrappedValue))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            VerticalSlider(value: value, range: EQModel.range, label: label, tint: tint)
                .frame(width: 28, height: 130)
            Text(caption).font(.caption).lineLimit(1).fixedSize()
        }
    }
}

/// Tableau des bandes du mode paramétrique (cellules modifiables).
struct BandsTable: View {
    @EnvironmentObject var model: EQModel
    @Binding var selected: UUID?

    private func binding<T>(_ id: UUID, _ kp: WritableKeyPath<EQFilter, T>, _ fallback: T) -> Binding<T> {
        Binding(
            get: { model.filters.first { $0.id == id }?[keyPath: kp] ?? fallback },
            set: { v in if let i = model.filters.firstIndex(where: { $0.id == id }) { model.filters[i][keyPath: kp] = v } })
    }

    private func number(_ id: UUID, _ kp: WritableKeyPath<EQFilter, Double>, _ range: ClosedRange<Double>, fraction: Int, sort: Bool = false) -> some View {
        TextField("", value: Binding(
            get: { binding(id, kp, 0).wrappedValue },
            set: { binding(id, kp, 0).wrappedValue = $0.clamped(to: range); if sort { model.sortBands() } }),
                  format: .number.precision(.fractionLength(0...fraction)))
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Table(model.filters, selection: $selected) {
                TableColumn("N°") { f in
                    let i = model.filters.firstIndex(where: { $0.id == f.id }) ?? 0
                    Text("\(i + 1)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(bandColor(i), in: Circle())
                }
                .width(36)
                TableColumn("Type") { f in
                    Picker("Type", selection: binding(f.id, \.kind, .peak)) {
                        ForEach(EQFilter.Kind.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                }
                .width(min: 120, ideal: 140)
                TableColumn("Fréquence (Hz)") { f in number(f.id, \.frequency, EQFilter.frequencyRange, fraction: 0, sort: true) }
                TableColumn("Gain (dB)") { f in number(f.id, \.gain, EQFilter.gainRange, fraction: 1) }
                TableColumn("Largeur (Q)") { f in number(f.id, \.q, EQFilter.qRange, fraction: 2) }
                TableColumn("Active") { f in
                    Toggle("Active", isOn: binding(f.id, \.enabled, true)).labelsHidden().toggleStyle(.checkbox)
                }
                .width(56)
            }
            .frame(minHeight: 150, idealHeight: 190)

            HStack(spacing: 0) {
                Button { if let id = model.addBand() { selected = id } } label: { Image(systemName: "plus") }
                    .help("Ajouter une bande")
                    .accessibilityLabel("Ajouter une bande")
                    .disabled(model.filters.count >= EQModel.maxParametricBands)
                Button { if let id = selected { model.removeBand(id); selected = nil } } label: { Image(systemName: "minus") }
                    .help("Supprimer la bande")
                    .accessibilityLabel("Supprimer la bande")
                    .disabled(selected == nil)
                Text("Glissez un point du graphique, ou modifiez une valeur dans le tableau.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.leading, 12)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}
