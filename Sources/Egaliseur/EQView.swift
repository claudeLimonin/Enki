import Combine
import SwiftUI

private enum PresetEditor: Equatable {
    case saveAs, rename, confirmDelete
}

struct EQView: View {
    @EnvironmentObject var model: EQModel
    @StateObject private var meter = LimiterMeter()
    @ObservedObject private var tour = Tour.shared
    @ObservedObject private var updater = Updater.shared
    @State private var editor: PresetEditor?
    @State private var draftName = ""
    @State private var nameError: String?
    @State private var selectedBand: UUID?
    @State private var searchingHeadphone = false
    @State private var appLimitReached = false
    @FocusState private var nameFocused: Bool

    private let appsTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    static let graphHeight: CGFloat = 130
    static let controlsHeight: CGFloat = 172

    /// Du plus utilisé au moins utilisé : état et interrupteur, préréglage et mode,
    /// graphique, réglages, puis casque / applications / options dans le pied.
    var body: some View {
        VStack(spacing: 12) {
            header

            // Barre de réglage : remplacée par la saisie d'un nom ou la confirmation de suppression.
            Group {
                switch editor {
                case .saveAs, .rename: nameEditor
                case .confirmDelete: deleteConfirmation
                case nil: toolbar
                }
            }
            .frame(minHeight: 24)

            // Même graphique et même hauteur de zone de réglage dans les deux modes :
            // la fenêtre garde sa taille quand on change de mode.
            SpectrumPanel(selectedBand: $selectedBand)
                .frame(height: Self.graphHeight)
                .tourAnchor(.graph)

            Group {
                if searchingHeadphone {
                    HeadphoneSearchView { searchingHeadphone = false }
                        .frame(maxHeight: .infinity, alignment: .top)
                } else if model.mode == .parametric {
                    ParametricEditor(selected: $selectedBand)
                        .padding(.top, 4)
                        .frame(maxHeight: .infinity, alignment: .top)
                } else {
                    graphicSliders
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .frame(height: Self.controlsHeight)
            .tourAnchor(.controls)

            Divider()

            footer
        }
        .padding(16)
        .frame(width: 540)
        // Visite guidée : voile et bulle par-dessus toute la fenêtre.
        .overlayPreferenceValue(TourAnchorKey.self) { anchors in
            TourOverlay(tour: tour, anchors: anchors)
        }
        .onChange(of: tour.index) { _, _ in
            // La visite parle des curseurs : on ferme la recherche de casque si elle est ouverte.
            if tour.index != nil { searchingHeadphone = false; editor = nil }
        }
        .onAppear {
            meter.start(model.engine.processor)
            model.refreshApps()
            if model.openHeadphoneSearch {
                searchingHeadphone = true
                model.openHeadphoneSearch = false
            }
        }
        .onDisappear {
            meter.stop()
            editor = nil
            searchingHeadphone = false
        }
        .onReceive(appsTimer) { _ in model.refreshApps() }
        .onChange(of: model.mode) { _, _ in selectedBand = nil }
    }

    // MARK: - En-tête

    /// Titre, état de fonctionnement juste dessous, interrupteur général à droite.
    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "Enki Audio").font(.headline)
                HStack(spacing: 5) {
                    Circle()
                        .fill(model.hasError ? Color.red : (model.enabled ? Color.green : Color.secondary))
                        .frame(width: 7, height: 7)
                    Text(model.status)
                        .font(.caption)
                        .foregroundStyle(model.hasError ? .primary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if model.hasError {
                        Button("Autoriser l'accès", action: openAudioPermission)
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            }
            Spacer()
            Toggle("Activé", isOn: $model.enabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .help(model.enabled ? String(localized: "Couper l'égaliseur") : String(localized: "Activer l'égaliseur"))
                .accessibilityLabel("Activer l'égaliseur")
                .tourAnchor(.power)
        }
    }

    /// Préréglage (à gauche) et mode (à droite) : ce que l'on change le plus souvent.
    private var toolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                presetMenu
                Button {
                    model.reset()
                    selectedBand = nil
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .help(model.mode == .graphic ? String(localized: "Réinitialiser : tous les curseurs à 0") : String(localized: "Réinitialiser : bandes à 0 dB"))
                .accessibilityLabel("Réinitialiser")
            }
            .tourAnchor(.preset)
            Spacer()
            Picker("Mode", selection: $model.mode) {
                ForEach(EQMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Graphique : 10 bandes fixes. Paramétrique : bandes libres (fréquence, gain, largeur).")
            .tourAnchor(.mode)
        }
    }

    /// Pied : casque et applications à gauche ; limiteur et options à droite.
    private var footer: some View {
        // Seul le menu Casque peut rétrécir (nom raccourci) : les autres éléments gardent leur taille,
        // pour qu'aucun ne soit écrasé quand un nom de casque est long.
        HStack(spacing: 12) {
            correctionMenu.tourAnchor(.headphone)
            appsMenu.tourAnchor(.apps).fixedSize().layoutPriority(1)
            listeningMenu.fixedSize().layoutPriority(1)
            Spacer(minLength: 0)
            if model.enabled && !model.hasError {
                limiterBadge.fixedSize().layoutPriority(2).tourAnchor(.limiter)
            }
            settingsMenu.fixedSize().layoutPriority(2).tourAnchor(.settings)
        }
        .font(.callout)
        .alert("7 applications au maximum", isPresented: $appLimitReached) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Remettez une application sur « Égaliseur principal » pour en régler une autre.")
        }
    }

    private func openAudioPermission() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Options secondaires (les mêmes que le clic droit sur l'icône).
    private var settingsMenu: some View {
        Menu {
            Toggle("Limiteur anti-saturation", isOn: $model.limiterEnabled)
            Toggle("Un réglage par sortie audio", isOn: $model.perDevice)
            if model.perDevice, let device = model.currentDevice, !device.name.isEmpty {
                Text("Réglage actuel : \(device.name)")
            }
            Toggle("Ouvrir au démarrage du Mac", isOn: Binding(
                get: { LaunchAtLogin.isEnabled },
                set: { _ in LaunchAtLogin.toggle() }))
            Menu("Raccourcis clavier") {
                Toggle("Raccourcis activés", isOn: $model.hotkeysEnabled)
                Divider()
                Text("⌃⌥⌘E   Activer / couper l'égaliseur")
                Text("⌃⌥⌘→   Préréglage suivant")
                Text("⌃⌥⌘←   Préréglage précédent")
                Text("⌃⌥⌘N   Volume nivelé (mode nuit)")
            }
            Toggle("Notifications discrètes", isOn: $model.notificationsEnabled)
            Divider()
            Button("Sauvegarder les réglages…") { SettingsBackup.export() }
            Button("Restaurer des réglages…") { SettingsBackup.importAndRelaunch() }
            Divider()
            Button("Pas de son ? Autorisation audio…", action: openAudioPermission)
            if let r = updater.available {
                Button("Installer la version \(r.version)…") { updater.install(r) }
            }
            Button("Rechercher les mises à jour…") { updater.check(interactive: true) }
            Toggle("Vérifier automatiquement les mises à jour", isOn: $updater.automatic)
            Divider()
            Button("Guide de démarrage") { tour.start() }
            Button("À propos d'Enki Audio", action: showAboutPanel)
            Divider()
            Button("Quitter Enki Audio") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: updater.available == nil ? "gearshape" : "gearshape.badge.exclamationmark")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Options (aussi accessibles par clic droit sur l'icône de la barre des menus)")
        .accessibilityLabel("Options")
    }

    private var graphicSliders: some View {
        HStack(alignment: .top, spacing: 0) {
            band(value: $model.preamp, label: String(localized: "Préampli"), caption: String(localized: "Préampli"), tint: .secondary)
                .frame(width: 58)
            Divider().frame(height: Self.controlsHeight).padding(.horizontal, 6)
            ForEach(EQModel.frequencies.indices, id: \.self) { i in
                band(value: $model.gains[i], label: "\(EQModel.labels[i]) hertz",
                     caption: EQModel.labels[i], tint: .accentColor)
                    .frame(maxWidth: .infinity)
            }
        }
        .opacity(model.enabled ? 1 : 0.5)
    }

    private func band(value: Binding<Double>, label: String, caption: String, tint: Color) -> some View {
        VStack(spacing: 6) {
            Text(formatDB(value.wrappedValue))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            VerticalSlider(value: value, range: EQModel.range, label: label, tint: tint)
                .frame(width: 28, height: Self.controlsHeight - 44)
            Text(caption)
                .font(.caption)
                .lineLimit(1)
                .fixedSize()
        }
    }

    // MARK: - Casque et applications

    private var correctionMenu: some View {
        Menu {
            if let c = model.correction {
                Toggle("Corriger : \(c.name)", isOn: $model.correctionEnabled)
                Button("Retirer la correction") { model.setCorrection(nil) }
                Divider()
            }
            Button("Rechercher mon casque (AutoEQ)…") { searchingHeadphone = true }
            Button("Importer un fichier ParametricEQ…") { importCorrectionFile(into: model) }
        } label: {
            Label(correctionTitle, systemImage: "headphones")
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .menuStyle(.borderlessButton)
        .frame(minWidth: 90, maxWidth: 190, alignment: .leading)
        .help(model.correction.map { String(localized: "Correction de casque : \($0.name). Elle s'applique avant l'égaliseur et est mémorisée pour cette sortie audio.") }
              ?? String(localized: "Corrige le rendu de votre casque pour un son plus neutre (profils AutoEQ)."))
    }

    private var correctionTitle: String {
        guard let c = model.correction else { return String(localized: "Casque") }
        // Sans la source de la mesure entre parenthèses (« (Rtings) »…), visible dans l'info-bulle.
        let base = c.name.replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression)
        let short = base.isEmpty ? c.name : base
        return model.correctionEnabled ? String(short) : String(localized: "\(String(short)) (coupée)")
    }

    private var appsMenu: some View {
        let items = model.appMenuItems
        return Menu {
            if items.isEmpty {
                Text("Aucune application ne joue de son pour le moment")
            }
            ForEach(items) { app in
                Picker(selection: Binding(
                    get: { model.choice(for: app.bundleID) },
                    set: { if !model.setChoice($0, for: app) { appLimitReached = true } }
                )) {
                    Text("Égaliseur principal").tag(AppChoice.main)
                    Text("Sans égalisation").tag(AppChoice.bypass)
                    Divider()
                    ForEach(model.allPresets) { Text($0.displayName).tag(AppChoice.preset($0.name)) }
                } label: {
                    Text(appLabel(app))
                }
                .pickerStyle(.menu)
            }
            Divider()
            Text("Une application réglée à part ne passe pas par l'égaliseur principal.")
        } label: {
            Label(model.appRules.isEmpty ? String(localized: "Applications") : String(localized: "Applications · \(model.appRules.count)"),
                  systemImage: "macwindow.on.rectangle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Donnez à une application son propre réglage (ex. « Voix » pour les visioconférences).")
    }

    // MARK: - Écoute

    static let balanceSteps: [(Double, String)] = [
        (-1, "Tout à gauche"), (-0.5, "Gauche 50 %"), (-0.25, "Gauche 25 %"), (0, "Centre"),
        (0.25, "Droite 25 %"), (0.5, "Droite 50 %"), (1, "Tout à droite"),
    ]

    /// Volume nivelé, spatialisation casque, mono, balance, test auditif.
    private var listeningMenu: some View {
        let active = (model.leveler > 0 ? 1 : 0) + (model.crossfeed ? 1 : 0) + (model.mono ? 1 : 0) + (model.balance != 0 ? 1 : 0)
        return Menu {
            Picker("Volume nivelé (mode nuit)", selection: $model.leveler) {
                ForEach(0..<OutputOptions.levelerNames.count, id: \.self) { Text(OutputOptions.levelerNames[$0]).tag($0) }
            }
            .pickerStyle(.menu)
            Toggle("Spatialisation casque", isOn: $model.crossfeed)
            Toggle("Mono", isOn: $model.mono)
            Picker("Balance", selection: $model.balance) {
                ForEach(Self.balanceSteps, id: \.0) { Text($0.1).tag($0.0) }
            }
            .pickerStyle(.menu)
            Divider()
            Button("Test auditif…") { HearingTestWindow.show(model: model) }
        } label: {
            Label(active == 0 ? String(localized: "Écoute") : String(localized: "Écoute · \(active)"), systemImage: "ear")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Volume nivelé pour les films la nuit, spatialisation au casque, mono, balance, test auditif.")
    }

    private func appLabel(_ app: AudioApp) -> String {
        let suffix: String
        switch model.choice(for: app.bundleID) {
        case .main: suffix = ""
        case .bypass: suffix = " — " + String(localized: "sans égalisation")
        case .preset(let n): suffix = " — " + model.display(n)
        }
        return app.name + suffix + (app.isPlaying ? "  ♪" : "")
    }

    // MARK: - Préréglages

    private var presetMenu: some View {
        Menu {
                Section("Préréglages") {
                    ForEach(EQModel.presets) { preset in
                        Button(preset.displayName) { model.apply(preset) }
                    }
                }
                if !model.userPresets.isEmpty {
                    Section("Mes préréglages") {
                        ForEach(model.userPresets) { preset in
                            Button(preset.mode == .parametric ? String(localized: "\(preset.name) (paramétrique)") : preset.name) {
                                model.apply(preset)
                            }
                        }
                    }
                }
                Divider()
                Button("Enregistrer sous…") { openEditor(.saveAs) }
                Button("Partager ce réglage…") { PresetFile.export(from: model) }
                Button("Importer un préréglage…") { PresetFile.chooseAndImport(into: model) }
                if let preset = model.selectedUserPreset {
                    Button("Mettre à jour « \(preset.name) »") { model.updateSelected() }
                        .disabled(!model.isModified)
                    Button("Renommer « \(preset.name) »…") { openEditor(.rename) }
                    Button("Supprimer « \(preset.name) »…") { editor = .confirmDelete }
                }
        } label: {
            Text(shortTitle)
        }
        .fixedSize()
        .help("Préréglages : choisir, enregistrer vos réglages, renommer, supprimer")
        .accessibilityLabel("Préréglage")
    }

    private var nameEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                TextField(editor == .rename ? String(localized: "Nouveau nom") : String(localized: "Nom du préréglage"), text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onSubmit(commitName)
                    .onChange(of: draftName) { _, _ in nameError = nil }
                Button("Annuler") { editor = nil }
                    .keyboardShortcut(.cancelAction)
                Button(editor == .rename ? String(localized: "Renommer") : String(localized: "Enregistrer"), action: commitName)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draftName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let nameError {
                Text(nameError).font(.caption).foregroundStyle(.red)
            }
        }
        .onAppear { nameFocused = true }
    }

    private var deleteConfirmation: some View {
        HStack(spacing: 10) {
            Text("Supprimer « \(model.selectedUserPreset?.name ?? "") » ? Les réglages restent tels quels.")
                .font(.callout)
                .lineLimit(2)
            Spacer()
            Button("Annuler") { editor = nil }
                .keyboardShortcut(.cancelAction)
            Button("Supprimer", role: .destructive) {
                model.deleteSelected()
                editor = nil
            }
        }
    }

    /// Titre du menu, raccourci pour ne pas déborder de la fenêtre.
    private var shortTitle: String {
        guard let name = model.selectedPreset.map(model.display) else { return EQModel.customDisplayName }
        let short = name.count > 22 ? name.prefix(21) + "…" : name
        return model.isModified ? String(localized: "\(String(short)) (modifié)") : String(short)
    }

    private func openEditor(_ mode: PresetEditor) {
        draftName = mode == .rename ? (model.selectedUserPreset?.name ?? "") : ""
        nameError = nil
        editor = mode
    }

    private func commitName() {
        let error = editor == .rename ? model.renameSelected(to: draftName) : model.saveAs(draftName)
        if let error {
            nameError = error
        } else {
            editor = nil
        }
    }

    // MARK: - Limiteur

    /// Voyant cliquable : allume ou coupe le limiteur.
    /// Allumé : gris au repos, orange quand il travaille.
    /// Coupé : contour seul, rouge quand le son sature.
    private var limiterBadge: some View {
        let on = model.limiterEnabled
        let title = on ? String(localized: "Limiteur") : (meter.active ? String(localized: "Saturation") : String(localized: "Limiteur coupé"))
        let fill: Color = on
            ? (meter.active ? .orange : Color.secondary.opacity(0.15))
            : (meter.active ? .red : .clear)
        return Button {
            model.limiterEnabled.toggle()
        } label: {
            Text(title)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .foregroundStyle(meter.active ? Color.white : Color.secondary)
                .background(fill, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.secondary.opacity(on ? 0 : 0.5), lineWidth: 1))
                .contentShape(Capsule())
                .animation(.easeOut(duration: 0.15), value: meter.active)
        }
        .buttonStyle(.plain)
        .help(on
              ? String(localized: "Limiteur actif : il baisse le volume un court instant pour éviter la saturation (orange quand il agit). Cliquez pour le couper.")
              : String(localized: "Limiteur coupé : le son n'est plus protégé contre la saturation (rouge quand elle se produit). Cliquez pour le réactiver."))
        .accessibilityLabel("Limiteur")
        .accessibilityValue(on ? (meter.active ? String(localized: "activé, en action") : String(localized: "activé")) : (meter.active ? String(localized: "désactivé, saturation") : String(localized: "désactivé")))
        .accessibilityHint("Active ou désactive le limiteur")
    }
}
