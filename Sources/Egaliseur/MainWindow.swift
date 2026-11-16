import AppKit
import Combine
import SwiftUI

/// Sections de la fenêtre principale (barre latérale).
enum MainSection: String, CaseIterable, Identifiable {
    case equalizer, headphones, apps, listening
    var id: String { rawValue }

    var title: String {
        switch self {
        case .equalizer: return String(localized: "Égaliseur")
        case .headphones: return String(localized: "Sortie audio")
        case .apps: return String(localized: "Applications")
        case .listening: return String(localized: "Écoute")
        }
    }

    var symbol: String {
        switch self {
        case .equalizer: return "slider.vertical.3"
        case .headphones: return "hifispeaker.2"
        case .apps: return "square.grid.2x2"
        case .listening: return "ear"
        }
    }
}

/// Section affichée dans la fenêtre principale (partagée avec la vue rapide et les menus).
final class Navigation: ObservableObject {
    static let shared = Navigation()
    @Published var section: MainSection = .equalizer
    /// Plein écran : la barre de titre disparaît, le contenu a besoin d'une marge en haut.
    @Published var isFullScreen = false
}

/// Fenêtre principale : créée à la demande, une seule à la fois.
/// Tant qu'elle est ouverte, l'app apparaît dans le Dock et dans ⌘-Tab, comme une app ordinaire.
final class MainWindowController: NSObject, NSWindowDelegate {
    static let shared = MainWindowController()
    private var window: NSWindow?
    private var titleObserver: AnyCancellable?

    func show(_ section: MainSection? = nil) {
        if let section { Navigation.shared.section = section }
        if window == nil {
            let host = NSHostingController(rootView: MainView()
                .environmentObject(EQModel.shared)
                .environmentObject(Navigation.shared))
            host.sceneBridgingOptions = [.toolbars, .title]
            let w = NSWindow(contentViewController: host)
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.toolbarStyle = .unified
            // Titre et commandes sont en tête de page ; la barre de titre ne garde que les boutons de fenêtre.
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.contentMinSize = NSSize(width: 860, height: 600)
            w.setContentSize(NSSize(width: 1040, height: 700))
            w.isReleasedWhenClosed = false
            w.delegate = self
            if !w.setFrameUsingName("EnkiAudioMainWindow") { w.center() }
            w.setFrameAutosaveName("EnkiAudioMainWindow")
            // Fenêtre mémorisée trop grande ou hors écran : retour à la taille par défaut.
            if let screen = (w.screen ?? NSScreen.main)?.visibleFrame, !screen.contains(w.frame) {
                w.setContentSize(NSSize(width: 1040, height: 700))
                w.center()
            }
            titleObserver = Navigation.shared.$section.sink { [weak w] in w?.title = $0.title }
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    var isVisible: Bool { window?.isVisible == true }

    /// Repasse en app de barre des menus (sans icône dans le Dock) s'il ne reste aucune fenêtre ouverte.
    static func returnToMenuBarIfNoWindow(except closing: NSWindow? = nil) {
        let open = NSApp.windows.contains { $0 !== closing && $0.isVisible && $0.styleMask.contains(.titled) }
        if !open { NSApp.setActivationPolicy(.accessory) }
    }

    func windowDidEnterFullScreen(_ notification: Notification) { Navigation.shared.isFullScreen = true }
    func windowDidExitFullScreen(_ notification: Notification) { Navigation.shared.isFullScreen = false }

    func windowWillClose(_ notification: Notification) {
        // Plus de fenêtre : l'app redevient discrète (barre des menus seulement).
        DispatchQueue.main.async { Self.returnToMenuBarIfNoWindow(except: self.window) }
    }
}

struct MainView: View {
    @EnvironmentObject var model: EQModel
    @EnvironmentObject var nav: Navigation

    var body: some View {
        NavigationSplitView {
            List(MainSection.allCases, selection: Binding(get: { nav.section }, set: { if let s = $0 { nav.section = s } })) { s in
                Label(s.title, systemImage: s.symbol).tag(s)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                // Plein écran : pas de barre de titre au-dessus, la liste ne doit pas toucher le bord.
                Color.clear.frame(height: nav.isFullScreen ? 16 : 0)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
            .safeAreaInset(edge: .bottom) { outputSummary }
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                header
                Group {
                switch nav.section {
                case .equalizer: EqualizerPage()
                case .headphones: HeadphonesPage()
                case .apps: AppsPage()
                case .listening: ListeningPage()
                }
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(minWidth: 860, maxWidth: .infinity, minHeight: 600, maxHeight: .infinity)
        // Le titre est affiché en tête de page, aligné sur le contenu (voir header).
        .modifier(HideToolbarTitle())
    }

    /// Titre de la page, aligné sur le contenu (marge de 20 points comme les pages).
    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(nav.section.title).font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            if nav.section == .apps {
                Text("\(model.appRules.count) sur 7 réglées à part").foregroundStyle(.secondary)
            }
            Spacer()
            if nav.section == .equalizer {
                Picker("Mode", selection: $model.mode) {
                    ForEach(EQMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Graphique : 10 bandes fixes. Paramétrique : bandes libres (fréquence, gain, largeur).")
                Toggle(isOn: $model.comparing) { Text("Comparer") }
                    .toggleStyle(.button)
                    .help("Écouter le son d'origine, sans aucun traitement, pour comparer.")
            }
            Toggle("Égaliseur", isOn: $model.enabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .help(model.enabled ? "Couper l'égaliseur" : "Activer l'égaliseur")
                .accessibilityLabel("Égaliseur")
        }
        .padding(.horizontal, 20)
        .padding(.top, nav.isFullScreen ? 24 : 14)
    }

    /// Sortie actuelle, rappelée en bas de la barre latérale : c'est elle qui décide du réglage chargé.
    private var outputSummary: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Sortie").font(.caption).foregroundStyle(.secondary)
            Text(model.currentDevice?.name ?? String(localized: "Aucune sortie")).fontWeight(.semibold).lineLimit(1)
            Text(model.correction != nil && model.correctionEnabled
                 ? String(localized: "Correction activée") : String(localized: "Sans correction"))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }
}

/// Retire le titre de la barre d'outils (macOS 15 et plus) : il est déjà en tête de page.
private struct HideToolbarTitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.toolbar(removing: .title)
        } else {
            content
        }
    }
}
