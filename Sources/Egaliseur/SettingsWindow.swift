import AppKit
import SwiftUI

/// Fenêtre Réglages (⌘,) : onglets dans la barre d'outils, comme les Réglages des apps Apple.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private var window: NSWindow?
    /// Raccourcis globaux affichés dans l'onglet « Raccourcis » (fournis par la barre des menus).
    var shortcuts: [(label: String, title: String)] = []

    func show() {
        if window == nil {
            let tabs = NSTabViewController()
            tabs.tabStyle = .toolbar
            tabs.addTabViewItem(tab(String(localized: "Général"), "gearshape", GeneralSettings()))
            tabs.addTabViewItem(tab(String(localized: "Raccourcis"), "keyboard", ShortcutSettings(shortcuts: shortcuts)))
            tabs.addTabViewItem(tab(String(localized: "Mises à jour"), "arrow.triangle.2.circlepath", UpdateSettings()))
            let w = NSWindow(contentViewController: tabs)
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func tab<V: View>(_ title: String, _ symbol: String, _ view: V) -> NSTabViewItem {
        let host = NSHostingController(rootView: view.environmentObject(EQModel.shared).frame(width: 520))
        host.sizingOptions = .preferredContentSize
        let item = NSTabViewItem(viewController: host)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return item
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { MainWindowController.returnToMenuBarIfNoWindow(except: self.window) }
    }
}

private struct GeneralSettings: View {
    @EnvironmentObject var model: EQModel
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        Form {
            Section("Démarrage") {
                Toggle("Ouvrir Enki Audio au démarrage du Mac", isOn: Binding(
                    get: { launchAtLogin },
                    set: { _ in LaunchAtLogin.toggle(); launchAtLogin = LaunchAtLogin.isEnabled }))
                LabeledContent("Guide de démarrage") {
                    Button("Revoir le guide") {
                        Tour.shared.start()
                        NotificationCenter.default.post(name: .showQuickView, object: nil)
                    }
                }
            }
            Section("Comportement") {
                Toggle(isOn: $model.perDevice) {
                    Text("Un réglage par sortie audio")
                    Text("Casque et haut-parleurs gardent chacun leur réglage.")
                }
                Toggle(isOn: $model.notificationsEnabled) {
                    Text("Notifications discrètes")
                    Text("Une bulle sous l'icône quand le réglage change.")
                }
            }
            Section("Autorisation") {
                LabeledContent("Capture du son") {
                    Button("Ouvrir les Réglages Système…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
            Section("Sauvegarde") {
                LabeledContent("Tous les réglages dans un fichier") {
                    Button("Sauvegarder…") { SettingsBackup.export() }
                }
                LabeledContent("Depuis un fichier « .egaliseur »") {
                    Button("Restaurer…") { SettingsBackup.importAndRelaunch() }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ShortcutSettings: View {
    @EnvironmentObject var model: EQModel
    let shortcuts: [(label: String, title: String)]

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $model.hotkeysEnabled) {
                    Text("Raccourcis globaux")
                    Text("Utilisables depuis n'importe quelle application.")
                }
            }
            Section("Raccourcis") {
                ForEach(shortcuts.indices, id: \.self) { i in
                    LabeledContent(shortcuts[i].title) {
                        Text(shortcuts[i].label).monospaced().foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(!model.hotkeysEnabled)
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct UpdateSettings: View {
    @ObservedObject private var updater = Updater.shared

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Version installée", value: version)
                if let r = updater.available {
                    LabeledContent("Nouvelle version disponible : \(r.version)") {
                        Button("Installer…") { updater.install(r) }
                    }
                }
                Toggle("Vérifier automatiquement les mises à jour", isOn: $updater.automatic)
                LabeledContent("Rechercher maintenant") {
                    Button("Rechercher les mises à jour…") { updater.check(interactive: true) }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Barre des menus de l'app (visible quand une fenêtre est au premier plan)

enum MainMenu {
    static func install() {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(item(String(localized: "À propos d'Enki Audio"), #selector(AppActions.about)))
        app.addItem(.separator())
        app.addItem(item(String(localized: "Réglages…"), #selector(AppActions.settings), ","))
        app.addItem(.separator())
        app.addItem(withTitle: String(localized: "Masquer Enki Audio"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = app.addItem(withTitle: String(localized: "Masquer les autres"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: String(localized: "Tout afficher"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: String(localized: "Quitter Enki Audio"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(app, "Enki Audio", to: main)

        let file = NSMenu(title: String(localized: "Fichier"))
        file.addItem(item(String(localized: "Importer un préréglage…"), #selector(AppActions.importPreset), "o"))
        file.addItem(.separator())
        file.addItem(withTitle: String(localized: "Fermer"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        add(file, file.title, to: main)

        let edit = NSMenu(title: String(localized: "Édition"))
        edit.addItem(withTitle: String(localized: "Annuler"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: String(localized: "Rétablir"), action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: String(localized: "Couper"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: String(localized: "Copier"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: String(localized: "Coller"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: String(localized: "Tout sélectionner"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        add(edit, edit.title, to: main)

        let window = NSMenu(title: String(localized: "Fenêtre"))
        window.addItem(withTitle: String(localized: "Réduire"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(.separator())
        window.addItem(item(String(localized: "Fenêtre Enki Audio"), #selector(AppActions.mainWindow), "0"))
        add(window, window.title, to: main)
        NSApp.windowsMenu = window

        NSApp.mainMenu = main
    }

    private static func item(_ title: String, _ action: Selector, _ key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = AppActions.shared
        return i
    }

    private static func add(_ menu: NSMenu, _ title: String, to main: NSMenu) {
        let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        top.submenu = menu
        main.addItem(top)
    }
}

/// Cibles des commandes du menu de l'app.
final class AppActions: NSObject {
    static let shared = AppActions()
    @objc func about() { showAboutPanel() }
    @objc func settings() { SettingsWindowController.shared.show() }
    @objc func mainWindow() { MainWindowController.shared.show() }
    @objc func importPreset() { PresetFile.chooseAndImport(into: EQModel.shared) }
}
