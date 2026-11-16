import AppKit
import SwiftUI

/// Sections de la fenêtre principale (barre latérale).
enum MainSection: String, CaseIterable, Identifiable {
    case equalizer, headphones, apps, listening, presets
    var id: String { rawValue }

    var title: String {
        switch self {
        case .equalizer: return String(localized: "Égaliseur")
        case .headphones: return String(localized: "Casque")
        case .apps: return String(localized: "Applications")
        case .listening: return String(localized: "Écoute")
        case .presets: return String(localized: "Préréglages")
        }
    }

    var symbol: String {
        switch self {
        case .equalizer: return "slider.vertical.3"
        case .headphones: return "headphones"
        case .apps: return "square.grid.2x2"
        case .listening: return "ear"
        case .presets: return "list.bullet"
        }
    }
}

/// Section affichée dans la fenêtre principale (partagée avec la vue rapide et les menus).
final class Navigation: ObservableObject {
    static let shared = Navigation()
    @Published var section: MainSection = .equalizer
}

/// Fenêtre principale : créée à la demande, une seule à la fois.
/// Tant qu'elle est ouverte, l'app apparaît dans le Dock et dans ⌘-Tab, comme une app ordinaire.
final class MainWindowController: NSObject, NSWindowDelegate {
    static let shared = MainWindowController()
    private var window: NSWindow?

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
            w.setContentSize(NSSize(width: 1040, height: 700))
            w.contentMinSize = NSSize(width: 860, height: 560)
            w.setFrameAutosaveName("EnkiAudioMainWindow")
            w.isReleasedWhenClosed = false
            w.delegate = self
            if w.frame.origin == .zero { w.center() }
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
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
            .safeAreaInset(edge: .bottom) { outputSummary }
        } detail: {
            Group {
                switch nav.section {
                case .equalizer: EqualizerPage()
                case .headphones: HeadphonesPage()
                case .apps: AppsPage()
                case .listening: ListeningPage()
                case .presets: PresetsPage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// Sortie actuelle, rappelée en bas de la barre latérale : c'est elle qui décide du réglage chargé.
    private var outputSummary: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Sortie").font(.caption).foregroundStyle(.secondary)
            Text(model.currentDevice?.name ?? String(localized: "Aucune sortie")).fontWeight(.semibold).lineLimit(1)
            Text(model.correction != nil && model.correctionEnabled
                 ? String(localized: "Correction de casque activée") : String(localized: "Sans correction de casque"))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }
}
