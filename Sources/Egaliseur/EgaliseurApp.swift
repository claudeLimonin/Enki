import Carbon.HIToolbox
import Combine
import ServiceManagement
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        ])
        observers.append(model.$hotkeysEnabled.sink { [weak self] on in
            on ? self?.hotkeys.register() : self?.hotkeys.unregister()
        })
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "slider.vertical.3", accessibilityDescription: "Égaliseur")
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = String(localized: "Égaliseur — clic droit pour les paramètres")
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
        let host = NSHostingController(rootView: EQView().environmentObject(model))
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
        menu.addItem(.separator())

        // Préréglages
        let presets = NSMenu()
        for p in EQModel.presets { presets.addItem(presetItem(p)) }
        if !model.userPresets.isEmpty {
            presets.addItem(.separator())
            presets.addItem(header(String(localized: "Mes préréglages")))
            for p in model.userPresets { presets.addItem(presetItem(p)) }
        }
        menu.addItem(submenu(String(localized: "Préréglage : \(model.presetTitle)"), presets))

        // Mode
        let modes = NSMenu()
        for m in EQMode.allCases {
            modes.addItem(toggle(m.label, model.mode == m) { $0.model.mode = m })
        }
        menu.addItem(submenu(String(localized: "Mode : \(model.mode.label)"), modes))

        // Correction de casque
        let headphone = NSMenu()
        if let c = model.correction {
            headphone.addItem(toggle(String(localized: "Corriger : \(c.name)"), model.correctionEnabled) { $0.model.correctionEnabled.toggle() })
            headphone.addItem(action(String(localized: "Retirer la correction")) { $0.model.setCorrection(nil) })
            headphone.addItem(.separator())
        }
        headphone.addItem(action(String(localized: "Rechercher mon casque (AutoEQ)…")) {
            $0.model.openHeadphoneSearch = true
            $0.showPopover()
        })
        headphone.addItem(action(String(localized: "Importer un fichier ParametricEQ…")) { importCorrectionFile(into: $0.model) })
        menu.addItem(submenu(model.correction.map { "Casque : \($0.name)" } ?? "Correction casque", headphone))

        // Écoute
        let listening = NSMenu()
        let leveler = NSMenu()
        for (i, name) in OutputOptions.levelerNames.enumerated() {
            leveler.addItem(toggle(name, model.leveler == i) { $0.model.leveler = i })
        }
        listening.addItem(submenu(String(localized: "Volume nivelé (mode nuit)"), leveler))
        listening.addItem(toggle(String(localized: "Spatialisation casque"), model.crossfeed) { $0.model.crossfeed.toggle() })
        listening.addItem(toggle(String(localized: "Mono"), model.mono) { $0.model.mono.toggle() })
        let balance = NSMenu()
        for (value, name) in EQView.balanceSteps {
            balance.addItem(toggle(name, model.balance == value) { $0.model.balance = value })
        }
        listening.addItem(submenu(String(localized: "Balance"), balance))
        listening.addItem(.separator())
        listening.addItem(action(String(localized: "Test auditif…")) { HearingTestWindow.show(model: $0.model) })
        menu.addItem(submenu(String(localized: "Écoute"), listening))

        menu.addItem(.separator())
        menu.addItem(toggle(String(localized: "Limiteur anti-saturation"), model.limiterEnabled) { $0.model.limiterEnabled.toggle() })
        menu.addItem(toggle(String(localized: "Un réglage par sortie audio"), model.perDevice) { $0.model.perDevice.toggle() })
        menu.addItem(toggle(String(localized: "Ouvrir au démarrage du Mac"), LaunchAtLogin.isEnabled) { _ in LaunchAtLogin.toggle() })
        let keys = NSMenu()
        keys.addItem(toggle(String(localized: "Raccourcis activés"), model.hotkeysEnabled) { $0.model.hotkeysEnabled.toggle() })
        keys.addItem(.separator())
        for s in hotkeys.shortcuts {
            let item = NSMenuItem(title: "\(s.label)   \(s.title)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            keys.addItem(item)
        }
        menu.addItem(submenu(String(localized: "Raccourcis clavier"), keys))
        menu.addItem(toggle(String(localized: "Notifications discrètes"), model.notificationsEnabled) { $0.model.notificationsEnabled.toggle() })

        menu.addItem(.separator())
        menu.addItem(action(String(localized: "Sauvegarder les réglages…")) { _ in SettingsBackup.export() })
        menu.addItem(action(String(localized: "Restaurer des réglages…")) { _ in SettingsBackup.importAndRelaunch() })
        menu.addItem(.separator())
        menu.addItem(action(String(localized: "Ouvrir l'égaliseur")) { $0.showPopover() })
        menu.addItem(action(String(localized: "Autorisation audio…")) { _ in
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
                NSWorkspace.shared.open(url)
            }
        })
        menu.addItem(.separator())
        menu.addItem(action(String(localized: "Guide de démarrage")) {
            Tour.shared.start()
            $0.showPopover()
        })
        let updater = Updater.shared
        if let r = updater.available {
            menu.addItem(action(String(localized: "Installer la version \(r.version)…")) { _ in updater.install(r) })
        }
        menu.addItem(action(String(localized: "Rechercher les mises à jour…")) { _ in updater.check(interactive: true) })
        menu.addItem(toggle(String(localized: "Vérifier automatiquement les mises à jour"), updater.automatic) { _ in updater.automatic.toggle() })
        menu.addItem(.separator())
        menu.addItem(action(String(localized: "À propos d'Égaliseur")) { _ in showAboutPanel() })
        let quit = NSMenuItem(title: String(localized: "Quitter Égaliseur"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
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
