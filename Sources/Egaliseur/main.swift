import AppKit

// Démarrage AppKit pur : pas de scène SwiftUI, donc aucune fenêtre ouverte au lancement.
// L'app vit dans la barre des menus (LSUIElement), via StatusBarController.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
