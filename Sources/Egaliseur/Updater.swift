import AppKit
import Foundation

/// Mises à jour automatiques depuis les « Releases » GitHub du projet.
/// Chaque version publiée contient l'image disque « Egaliseur-<version>.dmg ».
final class Updater: ObservableObject {
    static let shared = Updater()

    /// Dépôt GitHub où sont publiées les versions (doit être public pour être consulté sans compte).
    static let repository = "claudeLimonin/Enki"
    private static let checkInterval: TimeInterval = 24 * 3600

    struct Release: Equatable {
        let version: String
        let notes: String
        let dmg: URL
        let page: URL
    }

    struct UpdateError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Version plus récente trouvée (nil : à jour, ou pas encore vérifié).
    @Published private(set) var available: Release?
    @Published private(set) var installing = false
    @Published var automatic: Bool {
        didSet { UserDefaults.standard.set(automatic, forKey: "autoUpdateCheck") }
    }
    private var timer: Timer?

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private init() {
        automatic = UserDefaults.standard.object(forKey: "autoUpdateCheck") as? Bool ?? true
    }

    // MARK: - Vérification

    /// Vérification discrète : quelques secondes après le lancement, puis une fois par jour.
    func startAutomaticChecks() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.checkIfDue() }
        let t = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in self?.checkIfDue() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func checkIfDue() {
        guard automatic else { return }
        let last = UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > Self.checkInterval else { return }
        check(interactive: false)
    }

    /// `interactive` : demandé par l'utilisateur (menu) → on affiche toujours un résultat.
    func check(interactive: Bool) {
        Task { @MainActor in
            do {
                let release = try await Self.latestRelease()
                UserDefaults.standard.set(Date(), forKey: "lastUpdateCheck")
                guard let release, Self.isVersion(release.version, newerThan: Self.currentVersion) else {
                    available = nil
                    if interactive {
                        alert(String(localized: "Enki Audio est à jour"),
                              String(localized: "Vous utilisez la dernière version (\(Self.currentVersion))."))
                    }
                    return
                }
                available = release
                let skipped = UserDefaults.standard.string(forKey: "skippedVersion")
                if interactive || skipped != release.version { offer(release) }
            } catch {
                if interactive {
                    alert(String(localized: "Impossible de vérifier les mises à jour"), error.localizedDescription)
                }
            }
        }
    }

    static func latestRelease() async throws -> Release? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!,
                                 timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Egaliseur", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }   // aucune version publiée (ou dépôt inaccessible)
        guard status == 200 else {
            throw UpdateError(message: String(localized: "GitHub ne répond pas (erreur \(status))."))
        }
        return parseRelease(data)
    }

    /// Lit la réponse de l'API GitHub « releases/latest ».
    static func parseRelease(_ data: Data) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)),
              let assets = json["assets"] as? [[String: Any]],
              let dmg = assets.first(where: { ($0["name"] as? String)?.lowercased().hasSuffix(".dmg") == true })?["browser_download_url"] as? String,
              let dmgURL = URL(string: dmg) else { return nil }
        let version = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
        return Release(version: version, notes: json["body"] as? String ?? "", dmg: dmgURL, page: page)
    }

    /// Compare des versions « 2.1 », « 2.10.1 »… numériquement, composant par composant.
    static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }, pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Proposition et installation

    private func offer(_ r: Release) {
        let a = NSAlert()
        a.messageText = String(localized: "Enki Audio \(r.version) est disponible")
        let notes = r.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        a.informativeText = String(localized: "Vous avez la version \(Self.currentVersion). Vos réglages et l'autorisation audio sont conservés.")
            + (notes.isEmpty ? "" : "\n\n" + String(notes.prefix(600)))
        a.addButton(withTitle: String(localized: "Installer et relancer"))
        a.addButton(withTitle: String(localized: "Plus tard"))
        a.addButton(withTitle: String(localized: "Ignorer cette version"))
        NSApp.activate(ignoringOtherApps: true)
        switch a.runModal() {
        case .alertFirstButtonReturn: install(r)
        case .alertThirdButtonReturn: UserDefaults.standard.set(r.version, forKey: "skippedVersion")
        default: break
        }
    }

    /// Télécharge l'image disque, en extrait l'app, puis remplace l'app actuelle et relance.
    func install(_ r: Release) {
        guard !installing else { return }
        installing = true
        EQModel.shared.notify(String(localized: "Téléchargement d'Enki Audio \(r.version)…"), symbol: "arrow.down.circle")
        Task { @MainActor in
            defer { installing = false }
            do {
                let newApp = try await Self.download(r)
                try Self.replaceAndRelaunch(with: newApp)
            } catch {
                let a = NSAlert()
                a.messageText = String(localized: "La mise à jour n'a pas pu être installée")
                a.informativeText = error.localizedDescription
                    + "\n\n" + String(localized: "Vous pouvez la télécharger à la main depuis la page de la version.")
                a.addButton(withTitle: String(localized: "Ouvrir la page"))
                a.addButton(withTitle: String(localized: "Fermer"))
                NSApp.activate(ignoringOtherApps: true)
                if a.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(r.page) }
            }
        }
    }

    /// Renvoie le chemin de la nouvelle app, copiée dans un dossier temporaire.
    static func download(_ r: Release) async throws -> URL {
        let (file, response) = try await URLSession.shared.download(from: r.dmg)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError(message: String(localized: "Téléchargement impossible."))
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("egaliseur-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let dmg = work.appendingPathComponent("update.dmg")
        try FileManager.default.moveItem(at: file, to: dmg)

        // Monter l'image (sans l'afficher), copier l'app, démonter.
        let mount = work.appendingPathComponent("volume")
        try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-mountpoint", mount.path])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: mount.path)) ?? []
        let appName = ["Enki Audio.app", "Egaliseur.app"].first(where: names.contains) ?? names.first { $0.hasSuffix(".app") }
        guard let appName else {
            throw UpdateError(message: String(localized: "L'image disque ne contient pas l'app Enki Audio."))
        }
        let source = mount.appendingPathComponent(appName)
        let copy = work.appendingPathComponent(appBundleName)
        try run("/usr/bin/ditto", [source.path, copy.path])

        // Contrôles : même app (identifiant), signature intacte, version annoncée.
        let info = NSDictionary(contentsOf: copy.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else {
            throw UpdateError(message: String(localized: "L'app téléchargée n'est pas Enki Audio."))
        }
        try run("/usr/bin/codesign", ["--verify", "--strict", copy.path])
        return copy
    }

    /// Nom du paquet de l'app installée (l'app s'appelait « Egaliseur.app » jusqu'à la 2.1).
    static let appBundleName = "Enki Audio.app"

    /// Un petit script attend la fermeture de l'app, la remplace, puis rouvre la nouvelle.
    private static func replaceAndRelaunch(with newApp: URL) throws {
        let current = Bundle.main.bundleURL
        let parent = current.deletingLastPathComponent()
        let destination = parent.appendingPathComponent(appBundleName)
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw UpdateError(message: String(localized: "Le dossier « \(parent.path) » n'est pas modifiable."))
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", replacementScript(current: current, destination: destination, newApp: newApp, pid: getpid(), relaunch: true)]
        try p.run()
        NSApp.terminate(nil)
    }

    /// Remplace `current` par `newApp`, installée à `destination` (nouveau nom si l'app a été renommée).
    static func replacementScript(current: URL, destination: URL, newApp: URL, pid: pid_t, relaunch: Bool) -> String {
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return """
            while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done
            /bin/rm -rf \(q(current.path)) \(q(destination.path)) && /usr/bin/ditto \(q(newApp.path)) \(q(destination.path))
            /usr/bin/xattr -dr com.apple.quarantine \(q(destination.path)) 2>/dev/null
            \(relaunch ? "/usr/bin/open " + q(destination.path) : "true")
            /bin/rm -rf \(q(newApp.deletingLastPathComponent().path))
            """
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        p.waitUntilExit()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard p.terminationStatus == 0 else {
            throw UpdateError(message: "\((tool as NSString).lastPathComponent) : \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return text
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}
