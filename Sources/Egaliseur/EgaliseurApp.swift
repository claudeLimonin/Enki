import Carbon.HIToolbox
import Combine
import ServiceManagement
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainMenu.install()
        statusBar = StatusBarController(model: EQModel.shared)
        EQModel.shared.launch()
        Updater.shared.startAutomaticChecks()
        // Premier lancement : la fenêtre s'ouvre seule (sa flèche montre l'icône) et la visite démarre.
        if !Tour.shared.completed {
            Tour.shared.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.statusBar?.showPopover() }
        }
    }

    /// Double-clic sur un fichier « .egpreset » dans le Finder.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.pathExtension.lowercased() == "egpreset" {
            PresetFile.open(url, into: EQModel.shared)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        EQModel.shared.shutdown()
    }
}

/// Icône de la barre des menus : clic gauche → fenêtre de l'égaliseur, clic droit → menu des paramètres.
final class StatusBarController: NSObject, NSMenuDelegate {
    private let model: EQModel
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let menu = NSMenu()
    private let hud = HUD()
    private var hotkeys: Hotkeys!
    private var observers: [AnyCancellable] = []

    init(model: EQModel) {
        self.model = model
        super.init()
        model.onNotify = { [weak self] text, symbol in
            guard let self, !self.popover.isShown else { return }
            self.hud.show(text, symbol: symbol, below: self.item.button)
        }
        hotkeys = Hotkeys([
            .init(keyCode: UInt32(kVK_ANSI_E), label: "\(Hotkeys.modifierLabel)E", title: String(localized: "Activer / couper l'égaliseur")) { model.toggleEnabledFromShortcut() },
            .init(keyCode: UInt32(kVK_RightArrow), label: "\(Hotkeys.modifierLabel)→", title: String(localized: "Préréglage suivant")) { model.stepPreset(1) },
            .init(keyCode: UInt32(kVK_LeftArrow), label: "\(Hotkeys.modifierLabel)←", title: String(localized: "Préréglage précédent")) { model.stepPreset(-1) },
            .init(keyCode: UInt32(kVK_ANSI_N), label: "\(Hotkeys.modifierLabel)N", title: String(localized: "Volume nivelé (mode nuit)")) { model.toggleLevelerFromShortcut() },
            .init(keyCode: UInt32(kVK_ANSI_O), label: "\(Hotkeys.modifierLabel)O", title: String(localized: "Ouvrir la fenêtre Enki Audio")) { MainWindowController.shared.show() },
        ])
        SettingsWindowController.shared.shortcuts = hotkeys.shortcuts.map { ($0.label, $0.title) }
        NotificationCenter.default.addObserver(forName: .showQuickView, object: nil, queue: .main) { [weak self] _ in
            self?.showPopover()
        }
        observers.append(model.$hotkeysEnabled.sink { [weak self] on in
            on ? self?.hotkeys.register() : self?.hotkeys.unregister()
        })
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "slider.vertical.3", accessibilityDescription: "Enki Audio")
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = String(localized: "Enki Audio — clic droit pour les paramètres")
        }
        popover.behavior = .transient
        popover.animates = false
        menu.delegate = self
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        let secondary = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        secondary ? showMenu() : togglePopover()
    }

    // MARK: - Fenêtre de l'égaliseur

    @objc func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    @objc func showPopover() {
        guard let button = item.button else { return }
        // Vue recréée à chaque ouverture : état propre (éditeurs fermés, minuteries relancées).
        let host = NSHostingController(rootView: QuickView(close: { [weak self] in self?.popover.performClose(nil) }).environmentObject(model))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    // MARK: - Menu des paramètres (clic droit)

    private func showMenu() {
        if popover.isShown { popover.performClose(nil) }
        // Affiché à la demande : le clic gauche garde la fenêtre de l'égaliseur.
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        handlers.removeAll()

        menu.addItem(toggle(String(localized: "Égaliseur activé"), model.enabled) { $0.model.enabled.toggle() })
        let presets = NSMenu()
        for g in EQModel.presetGroups {
            let sub = NSMenu()
            for p in g.presets { sub.addItem(presetItem(p)) }
            let item = submenu(g.title, sub)
            if g.presets.contains(where: { $0.name == model.selectedPreset }) { item.state = .mixed }
            presets.addItem(item)
        }
        if !model.userPresets.isEmpty {
            presets.addItem(.separator())
            presets.addItem(header(String(localized: "Mes préréglages")))
            for p in model.userPresets { presets.addItem(presetItem(p)) }
        }
        menu.addItem(submenu(String(localized: "Préréglage : \(model.presetTitle)"), presets))
        menu.addItem(.separator())

        let open = action(String(localized: "Ouvrir Enki Audio")) { _ in MainWindowController.shared.show() }
        menu.addItem(open)
        menu.addItem(action(String(localized: "Sortie audio et correction…")) { _ in MainWindowController.shared.show(.headphones) })
        let settings = action(String(localized: "Réglages…")) { _ in SettingsWindowController.shared.show() }
        settings.keyEquivalent = ","
        menu.addItem(settings)
        menu.addItem(.separator())
        if let r = Updater.shared.available {
            menu.addItem(action(String(localized: "Installer la version \(r.version)…")) { _ in Updater.shared.install(r) })
        }
        menu.addItem(action(String(localized: "À propos d'Enki Audio")) { _ in showAboutPanel() })
        menu.addItem(NSMenuItem(title: String(localized: "Quitter Enki Audio"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    // MARK: - Construction des éléments de menu

    private var handlers: [Int: (StatusBarController) -> Void] = [:]

    private func action(_ title: String, _ handler: @escaping (StatusBarController) -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: "")
        item.target = self
        item.tag = handlers.count + 1
        handlers[item.tag] = handler
        return item
    }

    private func toggle(_ title: String, _ on: Bool, _ handler: @escaping (StatusBarController) -> Void) -> NSMenuItem {
        let item = action(title, handler)
        item.state = on ? .on : .off
        return item
    }

    private func presetItem(_ p: EQPreset) -> NSMenuItem {
        let title = p.mode == .parametric ? String(localized: "\(p.name) (paramétrique)") : p.displayName
        return toggle(title, model.selectedPreset == p.name) { $0.model.apply(p) }
    }

    private func submenu(_ title: String, _ sub: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = sub
        return item
    }

    private func header(_ title: String) -> NSMenuItem {
        if #available(macOS 14, *) { return NSMenuItem.sectionHeader(title: title) }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func run(_ sender: NSMenuItem) {
        handlers[sender.tag]?(self)
    }
}

/// Fenêtre « À propos » : version, auteur, crédits.
func showAboutPanel() {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let small: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 11),
        .foregroundColor: NSColor.secondaryLabelColor,
        .paragraphStyle: paragraph,
    ]
    let credits = NSMutableAttributedString(string: String(localized: "Auteur : "), attributes: small)
    credits.append(NSAttributedString(string: "Claude Limonin", attributes: small.merging([
        .font: NSFont.boldSystemFont(ofSize: 11), .foregroundColor: NSColor.labelColor,
    ]) { $1 }))
    credits.append(NSAttributedString(string: "\n\n" + String(localized: "Égaliseur graphique et paramétrique pour tout le son du Mac.")
        + "\n" + String(localized: "Profils de correction de casque : AutoEQ (Jaakko Pasanen)."), attributes: small))
    NSApp.activate(ignoringOtherApps: true)
    NSApp.orderFrontStandardAboutPanel(options: [
        .credits: credits,
        NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "© 2026 Claude Limonin",
    ])
}

/// Lancement automatique à l'ouverture de session (Réglages Système → Général → Ouverture).
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func toggle() {
        do {
            if isEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = String(localized: "Impossible de modifier l'ouverture au démarrage")
            alert.informativeText = error.localizedDescription + "\n\n" + String(localized: "Vous pouvez l'ajouter à la main : Réglages Système → Général → Ouverture.")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        if SMAppService.mainApp.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}
