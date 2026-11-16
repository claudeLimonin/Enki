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

struct HeadphoneSearchView: View {
    @EnvironmentObject var model: EQModel
    @StateObject private var search = HeadphoneSearch()
    @FocusState private var focused: Bool
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "headphones").foregroundStyle(.secondary)
                TextField("Modèle de casque (ex. AirPods Pro, HD 650)", text: $search.query)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                Button("Fermer", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }

            if search.loadingIndex {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Chargement de la liste des casques…").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = search.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(search.results) { entry in
                        row(entry)
                        Divider()
                    }
                }
            }
            .frame(height: 104)
            .overlay {
                if search.results.isEmpty && !search.loadingIndex {
                    Text(search.query.isEmpty
                         ? String(localized: "Tapez le nom de votre casque. Les profils viennent d'AutoEQ, calculés à partir de mesures en laboratoire.")
                         : String(localized: "Aucun casque trouvé. Essayez avec moins de mots (ex. « HD 650 »)."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                }
            }

            Text("Plusieurs mesures du même casque ? Préférez oratory1990 ou crinacle, les plus fiables.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .onAppear {
            search.prepare()
            focused = true
        }
    }

    private func row(_ entry: AutoEQ.Entry) -> some View {
        Button {
            search.choose(entry) { profile in
                model.setCorrection(profile)
                onClose()
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.name)
                    Text([entry.source, entry.form].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if search.downloading == entry.id {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(search.downloading != nil)
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
