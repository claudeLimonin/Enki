import AppKit
import SwiftUI

extension Notification.Name {
    /// Demande d'afficher la vue rapide (ex. « Revoir le guide » depuis les Réglages).
    static let showQuickView = Notification.Name("EnkiAudioShowQuickView")
}

/// Vue rapide de la barre des menus : l'essentiel en un clic. Les réglages fins sont dans la fenêtre.
struct QuickView: View {
    @EnvironmentObject var model: EQModel
    @StateObject private var meter = LimiterMeter()
    @ObservedObject private var tour = Tour.shared
    /// Ferme la bulle (avant d'ouvrir une fenêtre).
    var close: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header.tourAnchor(.power)
            outputCard.tourAnchor(.output)
            VStack(alignment: .leading, spacing: 6) {
                presetRow
                SeparateAppsNote { close() }
            }
            .tourAnchor(.preset)
            graph.tourAnchor(.graph)
            tiles.tourAnchor(.tiles)
            Divider()
            VStack(spacing: 0) {
                MenuRow(title: String(localized: "Ouvrir Enki Audio"), shortcut: "⌃⌥⌘O") { close(); MainWindowController.shared.show() }
                MenuRow(title: String(localized: "Réglages…"), shortcut: "⌘,") { close(); SettingsWindowController.shared.show() }
            }
            .tourAnchor(.window)
        }
        .padding(14)
        .frame(width: 340)
        .overlayPreferenceValue(TourAnchorKey.self) { anchors in
            TourOverlay(tour: tour, anchors: anchors)
        }
        .onAppear {
            meter.start(model.engine.processor)
            model.refreshApps()
        }
        .onDisappear { meter.stop() }
    }

    // MARK: Éléments

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: "Enki Audio").font(.headline)
                HStack(spacing: 4) {
                    if model.hasError {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
                    }
                    Text(model.comparing ? String(localized: "Comparaison : son d'origine") : model.status)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if model.hasError {
                        Button("Autoriser l'accès", action: openAudioPermission).buttonStyle(.link).font(.caption)
                    }
                }
            }
            Spacer()
            Toggle("Égaliseur", isOn: $model.enabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .help(model.enabled ? "Couper l'égaliseur" : "Activer l'égaliseur")
                .accessibilityLabel("Égaliseur")
        }
    }

    private var outputCard: some View {
        Button {
            close()
            MainWindowController.shared.show(.headphones)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "headphones").font(.title3).frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.currentDevice?.name ?? String(localized: "Aucune sortie")).fontWeight(.semibold).lineLimit(1)
                    Text(model.correction != nil && model.correctionEnabled
                         ? String(localized: "Correction de casque activée")
                         : String(localized: "Sans correction de casque"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.background, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Sortie actuelle : chaque sortie garde son propre réglage. Cliquez pour la correction de casque.")
    }

    private var presetRow: some View {
        HStack {
            Text("Préréglage")
            Spacer()
            PresetTypePicker(typeWidth: 110, presetWidth: 150, showLabels: false)
        }
    }

    private var graph: some View {
        VStack(alignment: .leading, spacing: 4) {
            SpectrumPanel(selectedBand: .constant(nil), compact: true)
                .frame(height: 88)
            Text("Ce que vous entendez")
                .font(.caption).foregroundStyle(.secondary)
        }
        .opacity(model.enabled ? 1 : 0.5)
    }

    private var tiles: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            ControlTile(title: String(localized: "Mode nuit"), symbol: "moon.fill",
                        detail: model.leveler > 0 ? OutputOptions.levelerNames[model.leveler] : String(localized: "Désactivé"),
                        isOn: model.leveler > 0) { model.toggleLevelerFromShortcut() }
            ControlTile(title: String(localized: "Spatialisation"), symbol: "headphones",
                        detail: model.crossfeed ? String(localized: "Casque") : String(localized: "Désactivée"),
                        isOn: model.crossfeed) { model.crossfeed.toggle() }
            ControlTile(title: String(localized: "Limiteur"), symbol: "waveform.path",
                        detail: !model.limiterEnabled ? (meter.active ? String(localized: "Saturation !") : String(localized: "Désactivé"))
                            : (meter.active ? String(localized: "En action") : String(localized: "Au repos")),
                        isOn: model.limiterEnabled, alert: meter.active) { model.limiterEnabled.toggle() }
            ControlTile(title: String(localized: "Mono"), symbol: "speaker.wave.1.fill",
                        detail: model.mono ? String(localized: "Activé") : String(localized: "Stéréo"),
                        isOn: model.mono) { model.mono.toggle() }
        }
    }

    private func openAudioPermission() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Tuile façon Centre de contrôle : pastille ronde allumée de la couleur d'accentuation quand c'est actif.
struct ControlTile: View {
    let title: String
    let symbol: String
    let detail: String
    let isOn: Bool
    var alert = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isOn ? Color.white : Color.primary)
                    .frame(width: 28, height: 28)
                    .background(alert ? Color.orange : (isOn ? Color.accentColor : Color.secondary.opacity(0.18)), in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.caption.weight(.semibold)).lineLimit(1)
                    Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(.background, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(detail))
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}

/// Ligne de commande façon menu (survol en couleur d'accentuation), avec son raccourci.
struct MenuRow: View {
    let title: String
    let shortcut: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                Text(shortcut).foregroundStyle(hover ? Color.white.opacity(0.85) : Color.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(hover ? Color.white : Color.primary)
            .background(hover ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Rappel des applications réglées à part (le préréglage principal ne les concerne pas).
struct SeparateAppsNote: View {
    @EnvironmentObject var model: EQModel
    var beforeOpen: () -> Void = {}

    var body: some View { separateAppsNote }

    /// Applications réglées à part : le préréglage principal ne s'applique pas à elles.
    var separateApps: [(app: AudioApp, setting: String)] {
        model.appPageItems.compactMap { app in
            switch model.choice(for: app.bundleID) {
            case .main: return nil
            case .bypass: return (app, String(localized: "sans égaliseur"))
            case .preset(let name): return (app, model.display(name))
            }
        }
        .sorted { $0.app.isPlaying && !$1.app.isPlaying }
    }

    @ViewBuilder
    private var separateAppsNote: some View {
        let items = separateApps
        if !items.isEmpty {
            let playing = items.contains { $0.app.isPlaying }
            let list = items.map { "\($0.app.name) (\($0.setting))" }.joined(separator: ", ")
            Button {
                beforeOpen()
                MainWindowController.shared.show(.apps)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: playing ? "exclamationmark.circle.fill" : "info.circle")
                        .foregroundStyle(playing ? Color.orange : Color.secondary)
                    Text("Réglées à part, non concernées par ce préréglage : \(list)")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                .font(.caption)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Ces applications gardent leur propre réglage. Cliquez pour les modifier.")
        }
    }

}
