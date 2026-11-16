import AppKit
import UniformTypeIdentifiers

/// Sauvegarde et restauration de tous les réglages dans un fichier « .egaliseur »
/// (copie de secours, ou transfert vers un autre Mac).
/// Les réglages sont de toute façon enregistrés automatiquement à chaque modification.
enum SettingsBackup {
    /// Clés de UserDefaults qui constituent les réglages de l'app.
    static let keys = [
        "gains", "preamp", "mode", "filters", "enabled", "preset", "modified",
        "userPresets", "perDevice", "limiter", "correction", "correctionOn",
        "appRules", "deviceSettings", "tourCompleted", "leveler", "crossfeed", "widening", "mono", "balance", "hotkeys", "notifications", "autoUpdateCheck", "skippedVersion",
    ]
    private static let format = "Egaliseur"
    private static let version = 1
    static let fileType = UTType(exportedAs: "local.egaliseur.settings", conformingTo: .propertyList)

    /// Contenu à écrire dans le fichier.
    static func snapshot() -> [String: Any] {
        let d = UserDefaults.standard
        var values: [String: Any] = [:]
        for k in keys { if let v = d.object(forKey: k) { values[k] = v } }
        return ["format": format, "version": version, "date": Date(), "settings": values]
    }

    /// Restaure les réglages contenus dans `data`. Lève une erreur si le fichier n'est pas valide.
    static func restore(_ data: Data) throws {
        guard let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              root["format"] as? String == format,
              let values = root["settings"] as? [String: Any] else {
            throw AudioError(message: String(localized: "Ce fichier n'est pas une sauvegarde d'Enki Audio."))
        }
        let d = UserDefaults.standard
        for k in keys {
            if let v = values[k] { d.set(v, forKey: k) } else { d.removeObject(forKey: k) }
        }
    }

    static func export() {
        let panel = NSSavePanel()
        panel.title = String(localized: "Sauvegarder les réglages")
        panel.message = String(localized: "Préréglages, correction de casque, réglages par sortie et par application.")
        panel.nameFieldStringValue = String(localized: "Réglages Enki Audio") + ".egaliseur"
        panel.allowedContentTypes = [fileType]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: snapshot(), format: .xml, options: 0)
            try data.write(to: url, options: .atomic)
        } catch {
            alert(String(localized: "La sauvegarde a échoué"), error.localizedDescription)
        }
    }

    static func importAndRelaunch() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Restaurer des réglages")
        panel.message = String(localized: "Choisissez un fichier « .egaliseur ». Vos réglages actuels seront remplacés.")
        panel.allowedContentTypes = [fileType, .propertyList]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try restore(try Data(contentsOf: url))
        } catch {
            alert(String(localized: "Ces réglages ne peuvent pas être restaurés"), error.localizedDescription)
            return
        }
        // Relance pour repartir proprement des réglages restaurés.
        let path = Bundle.main.bundlePath
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        try? relaunch.run()
        NSApp.terminate(nil)
    }

    private static func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}

/// Un seul préréglage dans un petit fichier « .egpreset » (JSON), à partager.
/// Un double-clic sur le fichier l'ajoute aux préréglages de l'app.
enum PresetFile {
    static let fileType = UTType(exportedAs: "local.egaliseur.preset", conformingTo: .json)
    private static let format = "EgaliseurPreset"

    private struct Wrapper: Codable {
        var format: String
        var version: Int
        var preset: EQPreset
    }

    static func encode(_ p: EQPreset) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(Wrapper(format: format, version: 1, preset: p))
    }

    static func decode(_ data: Data) throws -> EQPreset {
        guard let w = try? JSONDecoder().decode(Wrapper.self, from: data), w.format == format,
              w.preset.gains.count == EQModel.frequencies.count else {
            throw AudioError(message: String(localized: "Ce fichier n'est pas un préréglage d'Enki Audio."))
        }
        var p = w.preset
        // Bornes de sécurité (fichier modifié à la main).
        p.gains = p.gains.map { $0.clamped(to: EQModel.range) }
        p.preamp = p.preamp.map { $0.clamped(to: -24...12) }
        p.filters = p.filters.map { Array($0.prefix(EQModel.maxParametricBands)) }
        return p
    }

    /// Enregistre les réglages actuels dans un fichier à partager.
    static func export(from model: EQModel) {
        let name = model.selectedPreset.map(model.display) ?? String(localized: "Mon réglage")
        export(EQPreset(name: name, gains: model.gains, preamp: model.preamp, mode: model.mode,
                        filters: model.mode == .parametric ? model.filters : nil))
    }

    /// Enregistre un préréglage donné dans un fichier à partager (nom du fichier = nom du préréglage).
    static func export(_ preset: EQPreset) {
        let name = preset.displayName
        let panel = NSSavePanel()
        panel.title = String(localized: "Partager ce réglage")
        panel.message = String(localized: "Un fichier à envoyer : un double-clic dessus l'ajoute aux préréglages d'Enki Audio.")
        panel.nameFieldStringValue = "\(name).egpreset"
        panel.allowedContentTypes = [fileType]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let presetName = url.deletingPathExtension().lastPathComponent
        var p = preset
        p.name = presetName
        do { try encode(p).write(to: url, options: .atomic) } catch { alert(String(localized: "Le partage a échoué"), error.localizedDescription) }
    }

    static func chooseAndImport(into model: EQModel) {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Importer un préréglage")
        panel.allowedContentTypes = [fileType, .json]
        panel.allowsMultipleSelection = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { open(url, into: model) }
    }

    /// Ajoute le préréglage du fichier (nom rendu unique) et l'applique.
    static func open(_ url: URL, into model: EQModel) {
        do {
            var p = try decode(try Data(contentsOf: url))
            let base = p.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Préréglage importé" : p.name
            p.name = base
            var n = 2
            while model.validateName(p.name) != nil {
                p.name = "\(base.prefix(EQModel.maxNameLength - 4)) (\(n))"
                n += 1
            }
            model.addUserPreset(p)
            model.apply(p)
            model.notify("Préréglage ajouté : \(p.name)", symbol: "square.and.arrow.down")
        } catch {
            alert(String(localized: "Ce préréglage ne peut pas être importé"), error.localizedDescription)
        }
    }

    private static func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}
