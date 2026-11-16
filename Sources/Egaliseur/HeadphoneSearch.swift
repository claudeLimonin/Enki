import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Recherche d'un casque dans la base AutoEQ.
final class HeadphoneSearch: ObservableObject {
    @Published var query = "" { didSet { update() } }
    @Published private(set) var results: [AutoEQ.Entry] = []
    @Published private(set) var loadingIndex = false
    @Published private(set) var downloading: String?
    @Published var error: String?

    /// Gardé en mémoire tant que l'app tourne (8 000+ casques).
    private static var index: [AutoEQ.Entry]?

    func prepare() {
        guard Self.index == nil, !loadingIndex else { return }
        loadingIndex = true
        error = nil
        Task { @MainActor in
            do {
                Self.index = try await AutoEQ.loadIndex()
                update()
            } catch {
                self.error = String(localized: "Liste AutoEQ indisponible : \(error.localizedDescription)")
            }
            loadingIndex = false
        }
    }

    private func update() {
        results = AutoEQ.search(query, in: Self.index ?? [])
    }

    func choose(_ entry: AutoEQ.Entry, then apply: @escaping (HeadphoneProfile) -> Void) {
        guard downloading == nil else { return }
        downloading = entry.id
        error = nil
        Task { @MainActor in
            do {
                apply(try await AutoEQ.fetchProfile(entry))
            } catch {
                self.error = error.localizedDescription
            }
            downloading = nil
        }
    }
}

/// Importe un fichier « ParametricEQ.txt » choisi par l'utilisateur.
func importCorrectionFile(into model: EQModel) {
    let panel = NSOpenPanel()
    panel.title = String(localized: "Importer un profil de casque")
    panel.message = String(localized: "Choisissez un fichier « ParametricEQ.txt » (AutoEQ ou Equalizer APO).")
    panel.allowedContentTypes = [.plainText]
    panel.allowsMultipleSelection = false
    NSApp.activate(ignoringOtherApps: true)
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
        let text = try String(contentsOf: url, encoding: .utf8)
        let name = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: " ParametricEQ", with: "")
        model.setCorrection(try AutoEQ.parse(text, name: name))
    } catch {
        let alert = NSAlert()
        alert.messageText = String(localized: "Ce fichier ne peut pas être importé")
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}
