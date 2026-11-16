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

/// Choix possible dans les menus Type + Préréglage.
struct PresetChoiceItem: Identifiable {
    let tag: String
    let title: String
    var id: String { tag }
}

/// Deux menus : le type (Essentiels, Genres, Antilles…), puis les choix de ce type.
/// Sert pour l'égaliseur principal comme pour le réglage d'une application.
struct TypeAndChoicePicker: View {
    let groups: [(id: String, title: String, items: [PresetChoiceItem])]
    /// Choix en cours (tag), nil s'il n'y en a pas (réglage personnalisé).
    let current: String?
    /// Texte quand le choix en cours n'est pas dans la liste du type affiché.
    let placeholder: String
    let onSelect: (String) -> Void
    var typeWidth: CGFloat? = 170
    var choiceWidth: CGFloat? = 190
    var choiceLabel: LocalizedStringKey = "Préréglage"
    var showLabels = true

    /// Type choisi à la main ; nil : celui du choix en cours.
    @State private var chosenType: String?

    private func type(of tag: String?) -> String? {
        guard let tag else { return nil }
        return groups.first { $0.items.contains { $0.tag == tag } }?.id
    }
    private var currentType: String { chosenType ?? type(of: current) ?? groups.first?.id ?? "" }
    private var items: [PresetChoiceItem] { groups.first { $0.id == currentType }?.items ?? [] }
    private var currentInList: Bool { items.contains { $0.tag == current } }

    var body: some View {
        HStack(spacing: 8) {
            Picker("Type", selection: Binding(get: { currentType }, set: { chosenType = $0 })) {
                ForEach(groups, id: \.id) { Text($0.title).tag($0.id) }
            }
            .labelsHidden(!showLabels)
            .frame(width: typeWidth)
            Picker(choiceLabel, selection: Binding(
                get: { currentInList ? (current ?? "") : "" },
                set: { onSelect($0) })) {
                if !currentInList { Text(placeholder).tag("") }
                ForEach(items) { Text($0.title).tag($0.tag) }
            }
            .labelsHidden(!showLabels)
            .frame(width: choiceWidth)
        }
        // Choix changé ailleurs (raccourci, vue rapide…) : le type suit.
        .onChange(of: current) { _, _ in chosenType = nil }
    }
}

/// Type + Préréglage de l'égaliseur principal.
struct PresetTypePicker: View {
    @EnvironmentObject var model: EQModel
    var typeWidth: CGFloat? = 170
    var presetWidth: CGFloat? = 190
    var showLabels = true

    var body: some View {
        TypeAndChoicePicker(
            groups: model.presetChoiceGroups(title: { p in p.name == model.selectedPreset ? model.presetTitle : p.displayName }),
            current: model.selectedPreset,
            placeholder: model.selectedPreset == nil ? EQModel.customDisplayName : String(localized: "Choisir…"),
            onSelect: { name in if let p = model.preset(named: name) { model.apply(p) } },
            typeWidth: typeWidth, choiceWidth: presetWidth, showLabels: showLabels)
    }
}

extension EQModel {
    /// Préréglages fournis par catégorie, puis les vôtres, sous forme de choix.
    func presetChoiceGroups(title: (EQPreset) -> String = { $0.displayName },
                            tag: (EQPreset) -> String = { $0.name }) -> [(id: String, title: String, items: [PresetChoiceItem])] {
        var list = Self.presetGroups.map { g in
            (id: g.title, title: g.title, items: g.presets.map { PresetChoiceItem(tag: tag($0), title: title($0)) })
        }
        if !userPresets.isEmpty {
            list.append((id: "user", title: String(localized: "Mes préréglages"),
                         items: userPresets.map { PresetChoiceItem(tag: tag($0), title: title($0)) }))
        }
        return list
    }
}

private extension View {
    @ViewBuilder func labelsHidden(_ hidden: Bool) -> some View {
        if hidden { self.labelsHidden() } else { self }
    }
}

/// Menu déroulant des préréglages, avec un menu d'actions à côté (enregistrer, renommer, partager…).
struct PresetControls: View {
    @EnvironmentObject var model: EQModel
    @Binding var nameRequest: PresetNameRequest?
    @State private var confirmDelete = false

    var body: some View {
        HStack(spacing: 6) {
            PresetTypePicker(typeWidth: EqualizerPage.typeWidth, presetWidth: EqualizerPage.choiceWidth, showLabels: false)
            Menu {
                if let name = model.selectedPreset, model.isModified, let p = model.preset(named: name) {
                    Button("Revenir à « \(p.displayName) »") { model.apply(p) }
                    Divider()
                }
                Button("Enregistrer sous…") { nameRequest = PresetNameRequest(kind: .saveAs) }
                if let p = model.selectedUserPreset {
                    Button("Mettre à jour « \(p.name) »") { model.updateSelected() }.disabled(!model.isModified)
                    Button("Renommer « \(p.name) »…") { nameRequest = PresetNameRequest(kind: .rename(p.name)) }
                    Button("Supprimer « \(p.name) »…") { confirmDelete = true }
                }
                Divider()
                Button("Importer un préréglage…") { PresetFile.chooseAndImport(into: model) }
                Button("Partager les réglages actuels…") { PresetFile.export(from: model) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Actions sur les préréglages")
            .accessibilityLabel("Actions sur les préréglages")
        }
        .confirmationDialog("Supprimer « \(model.selectedUserPreset?.name ?? "") » ?", isPresented: $confirmDelete) {
            Button("Supprimer", role: .destructive) { model.deleteSelected() }
        } message: {
            Text("Les réglages en cours restent tels quels.")
        }
    }

}

/// Interrupteur du limiteur, avec son état : orange quand il agit (ou quand le son sature sans lui).
struct LimiterControl: View {
    @EnvironmentObject var model: EQModel
    var showLabel = true
    @StateObject private var meter = LimiterMeter()

    private var state: (text: String, alert: Bool) {
        if model.limiterEnabled {
            return meter.active ? (String(localized: "En action"), true) : (String(localized: "Au repos"), false)
        }
        return meter.active ? (String(localized: "Saturation !"), true) : (String(localized: "Désactivé"), false)
    }

    var body: some View {
        HStack(spacing: 8) {
            Toggle("Limiteur", isOn: $model.limiterEnabled)
                .toggleStyle(.switch)
                .labelsHidden(!showLabel)
                .controlSize(.small)
            Text(state.text)
                .font(.caption.weight(state.alert ? .semibold : .regular))
                .foregroundStyle(state.alert ? Color.orange : Color.secondary)
                .frame(minWidth: 70, alignment: .leading)
        }
        .fixedSize()
        .help("Baisse le volume un court instant pour éviter la saturation. Avec le mode nuit, il agit rarement : c'est normal.")
        .onAppear { meter.start(model.engine.processor) }
        .onDisappear { meter.stop() }
    }
}

// MARK: - Page Égaliseur

struct EqualizerPage: View {
    @EnvironmentObject var model: EQModel
    @State private var selectedBand: UUID?
    @State private var nameRequest: PresetNameRequest?
    /// Application ciblée (nil : toutes les applications, c'est-à-dire l'égaliseur principal).
    @State private var target: String?
    @State private var limitReached = false

    static let typeWidth: CGFloat = 170
    static let choiceWidth: CGFloat = 200

    private func rowLabel(_ text: LocalizedStringKey) -> some View {
        Text(text).gridColumnAlignment(.leading)
    }

    @ViewBuilder private var settingControls: some View {
        if let app = targetApp {
            appSettingPicker(app)
        } else {
            PresetControls(nameRequest: $nameRequest)
        }
    }

    private var nightPicker: some View {
        Picker("Mode nuit", selection: $model.leveler) {
            ForEach(OutputOptions.levelerNames.indices, id: \.self) { Text(OutputOptions.levelerNames[$0]).tag($0) }
        }
        .labelsHidden()
        .frame(width: Self.typeWidth)
        .help("Abaisse les graves trop forts et remonte les dialogues calmes, pour écouter à faible volume. S'applique à toutes les applications.")
    }

    /// Ce que montre le graphique : dans un coin du graphique, puisqu'il ne concerne que lui.
    private var displayMenu: some View {
        Menu {
            Toggle("Spectre en direct", isOn: $model.showSpectrum)
            Toggle("Correction de la sortie", isOn: $model.showCorrectionLayer)
                .disabled(model.correction == nil)
        } label: {
            Label("Afficher", systemImage: "eye")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .font(.caption)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .help("Choisir ce qu'affiche le graphique")
    }

    private var targetApp: AudioApp? { target.flatMap { id in model.appPageItems.first { $0.bundleID == id } } }

    /// Réglage effectivement utilisé par l'application ciblée (pour le graphique).
    private var targetSettings: EQSettings? {
        guard let app = targetApp else { return nil }
        switch model.choice(for: app.bundleID) {
        case .main: return nil
        case .bypass: return EQSettings(mode: .graphic, gains: Array(repeating: 0, count: EQModel.frequencies.count), preamp: 0, filters: [])
        case .preset(let name): return model.preset(named: name).map(model.settings(of:))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 0) {
                // Deux colonnes si la place le permet (réglage | écoute), sinon empilées.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 36) {
                        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                            GridRow { rowLabel("Appliquer à"); targetPicker }
                            GridRow { rowLabel(targetApp == nil ? "Préréglage" : "Réglage"); settingControls }
                        }
                        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                            GridRow { rowLabel("Mode nuit"); nightPicker }
                            GridRow { rowLabel("Limiteur"); LimiterControl(showLabel: false) }
                        }
                    }
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                        GridRow { rowLabel("Appliquer à"); targetPicker }
                        GridRow { rowLabel(targetApp == nil ? "Préréglage" : "Réglage"); settingControls }
                        GridRow {
                            rowLabel("Mode nuit")
                            HStack(spacing: 20) { nightPicker; LimiterControl() }
                        }
                    }
                }
                Spacer(minLength: 0)
                if model.comparing {
                    Label("Son d'origine", systemImage: "speaker.wave.2")
                        .foregroundStyle(.orange)
                        .font(.callout.weight(.semibold))
                }
            }

            SpectrumPanel(selectedBand: $selectedBand, showing: targetSettings)
                .frame(minHeight: 170, maxHeight: .infinity)
                .overlay(alignment: .bottomLeading) { displayMenu.padding(8) }

            if let app = targetApp {
                appExplanation(app)
            } else {
                Group {
                    if model.mode == .graphic {
                        GraphicSliders()
                    } else {
                        BandsTable(selected: $selectedBand)
                    }
                }
                .opacity(model.enabled ? 1 : 0.5)
            }
        }
        .alert("7 applications au maximum", isPresented: $limitReached) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Remettez une autre application sur « Égaliseur principal » pour en régler une nouvelle.")
        }
        .padding(20)
        .navigationTitle("Égaliseur")
        .sheet(item: $nameRequest) { PresetNameSheet(request: $0) }
        .onChange(of: model.mode) { _, _ in selectedBand = nil }
        .onAppear { model.refreshApps() }
    }

    /// « Appliquer à » : toutes les applications, ou une seule.
    private var targetPicker: some View {
        Picker("Appliquer à", selection: $target) {
            Text("Toutes les applications").tag(String?.none)
            let apps = model.appPageItems
            if !apps.isEmpty {
                Section("Une seule application") {
                    ForEach(apps) { app in
                        Text(app.isPlaying ? "\(app.name)  ♪" : app.name).tag(Optional(app.bundleID))
                    }
                }
            }
        }
        .labelsHidden()
        .frame(width: Self.typeWidth + 8 + Self.choiceWidth)
        .help("Choisissez à quelles applications s'applique le réglage")
    }

    /// Réglage d'une application : égaliseur principal, sans égaliseur, ou un préréglage.
    private func appSettingPicker(_ app: AudioApp) -> some View {
        let main = "#main", bypass = "#bypass"
        let groups = [(id: "#general", title: String(localized: "Général"),
                       items: [PresetChoiceItem(tag: main, title: String(localized: "Égaliseur principal")),
                               PresetChoiceItem(tag: bypass, title: String(localized: "Sans égaliseur"))])]
            + model.presetChoiceGroups()
        let current: String = {
            switch model.choice(for: app.bundleID) {
            case .main: return main
            case .bypass: return bypass
            case .preset(let name): return name
            }
        }()
        return TypeAndChoicePicker(
            groups: groups,
            current: current,
            placeholder: String(localized: "Choisir…"),
            onSelect: { tag in
                let choice: AppChoice = tag == main ? .main : (tag == bypass ? .bypass : .preset(tag))
                if !model.setChoice(choice, for: app) { limitReached = true }
            },
            typeWidth: Self.typeWidth, choiceWidth: Self.choiceWidth,
            choiceLabel: "Réglage", showLabels: false)
        .id(app.bundleID)  // type remis à zéro quand on change d'application
    }

    /// À la place des curseurs quand une application est ciblée.
    private func appExplanation(_ app: AudioApp) -> some View {
        let text: String = {
            switch model.choice(for: app.bundleID) {
            case .main:
                return String(localized: "\(app.name) suit l'égaliseur principal. Choisissez un préréglage ci-dessus pour lui donner son propre réglage.")
            case .bypass:
                return String(localized: "\(app.name) n'est pas égalisée. La correction de la sortie audio, le mode nuit et le limiteur s'appliquent quand même.")
            case .preset(let name):
                return String(localized: "\(app.name) utilise le préréglage « \(model.display(name)) ». Pour un réglage sur mesure : réglez les curseurs dans « Toutes les applications », enregistrez-les comme préréglage, puis choisissez-le ici.")
            }
        }()
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Text(text).foregroundStyle(.secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Revenir à toutes les applications") { target = nil }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
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
