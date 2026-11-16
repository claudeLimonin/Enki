import AppKit
import CoreAudio

/// Une application qui produit (ou a produit) du son, avec tous ses processus audio.
struct AudioApp: Identifiable, Equatable {
    /// Identifiant de l'application (ex. « com.spotify.client »).
    let bundleID: String
    let name: String
    let isPlaying: Bool
    let objects: [AudioObjectID]
    var id: String { bundleID }
}

enum AppAudio {
    /// Le son des pages web de Safari (et des autres apps WebKit) passe par ce processus.
    static let webKitAudio = "com.apple.WebKit.GPU"

    /// Regroupe les processus audio par application. Les processus auxiliaires
    /// (« com.google.Chrome.helper »…) sont rattachés à l'application dont ils dépendent.
    static func apps(from processes: [AudioProcess]) -> [AudioApp] {
        let running = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier != nil }
        var groups: [String: (name: String, playing: Bool, objects: [AudioObjectID])] = [:]

        for p in processes {
            guard let key = appKey(for: p, running: running) else { continue }
            var g = groups[key.id] ?? (key.name, false, [])
            g.playing = g.playing || p.isPlaying
            g.objects.append(p.object)
            groups[key.id] = g
        }
        return groups.map { AudioApp(bundleID: $0.key, name: $0.value.name, isPlaying: $0.value.playing, objects: $0.value.objects) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func appKey(for p: AudioProcess, running: [NSRunningApplication]) -> (id: String, name: String)? {
        if p.bundleID == webKitAudio { return (webKitAudio, String(localized: "Safari et pages web")) }
        // Le processus est lui-même une application visible.
        if let app = NSRunningApplication(processIdentifier: p.pid),
           app.activationPolicy == .regular, let id = app.bundleIdentifier {
            return (id, app.localizedName ?? id)
        }
        guard !p.bundleID.isEmpty else { return nil }
        // Processus auxiliaire : application dont l'identifiant est un préfixe du sien.
        if let parent = running
            .filter({ $0.activationPolicy == .regular && p.bundleID.hasPrefix($0.bundleIdentifier! + ".") })
            .max(by: { $0.bundleIdentifier!.count < $1.bundleIdentifier!.count }),
           let id = parent.bundleIdentifier {
            return (id, parent.localizedName ?? id)
        }
        // Service système sans application visible : on l'ignore.
        return nil
    }

    /// Nom d'une application absente (règle enregistrée, app fermée).
    static func displayName(for bundleID: String) -> String? {
        if bundleID == webKitAudio { return String(localized: "Safari et pages web") }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}
