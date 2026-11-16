import Foundation

/// Accès à la base de profils de correction AutoEQ (github.com/jaakkopasanen/AutoEq).
enum AutoEQ {
    struct Entry: Identifiable, Hashable {
        let name: String
        let source: String
        /// Chemin relatif dans `results/`, ex. « oratory1990/over-ear/Sennheiser HD 650 ».
        let path: String
        var id: String { path }
        /// « Intra-auriculaire », « Circum-auriculaire »… déduit du chemin.
        var form: String {
            let p = path.lowercased()
            if p.contains("in-ear") { return String(localized: "intra") }
            if p.contains("earbud") { return String(localized: "écouteurs") }
            if p.contains("over-ear") { return String(localized: "circum") }
            if p.contains("on-ear") { return String(localized: "supra") }
            return ""
        }
    }

    struct ParseError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static let base = "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/"
    /// Sources aux mesures les plus fiables d'abord (classement des résultats).
    private static let preferredSources = ["oratory1990", "crinacle", "Rtings", "Innerfidelity", "Super Review"]
    private static let cacheLifetime: TimeInterval = 30 * 24 * 3600

    private static var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Egaliseur", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("autoeq-index.md")
    }

    // MARK: - Index

    /// Liste de tous les casques. Téléchargée une fois puis gardée en cache 30 jours.
    static func loadIndex() async throws -> [Entry] {
        let url = cacheURL
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let date = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(date) < cacheLifetime,
           let text = try? String(contentsOf: url, encoding: .utf8) {
            let entries = parseIndex(text)
            if !entries.isEmpty { return entries }
        }
        do {
            let text = try await download(base + "INDEX.md")
            let entries = parseIndex(text)
            guard !entries.isEmpty else { throw ParseError(message: String(localized: "Liste des casques illisible.")) }
            try? text.write(to: url, atomically: true, encoding: .utf8)
            return entries
        } catch {
            // Hors ligne : on se contente d'un cache périmé s'il existe.
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                let entries = parseIndex(text)
                if !entries.isEmpty { return entries }
            }
            throw error
        }
    }

    /// Lignes de la forme « - [Nom](./source/banc/Nom%20encodé) by Source on Banc ».
    static func parseIndex(_ text: String) -> [Entry] {
        text.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("- ["), let sep = line.range(of: "](./"),
                  let close = line.range(of: ") by ", range: sep.upperBound..<line.endIndex) else { return nil }
            let name = String(line[line.index(line.startIndex, offsetBy: 3)..<sep.lowerBound])
            guard let path = String(line[sep.upperBound..<close.lowerBound]).removingPercentEncoding else { return nil }
            var source = String(line[close.upperBound...])
            if let on = source.range(of: " on ") { source = String(source[..<on.lowerBound]) }
            return Entry(name: name, source: source, path: path)
        }
    }

    /// Tous les mots doivent apparaître (sans tenir compte des accents ni de la casse).
    static func search(_ query: String, in entries: [Entry], limit: Int = 60) -> [Entry] {
        let words = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        let matches = entries.filter { e in
            let hay = e.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            return words.allSatisfy { hay.contains($0) }
        }
        func rank(_ e: Entry) -> Int { preferredSources.firstIndex(of: e.source) ?? preferredSources.count }
        return Array(matches.sorted {
            if $0.name.count != $1.name.count { return $0.name.count < $1.name.count }
            if rank($0) != rank($1) { return rank($0) < rank($1) }
            return $0.source < $1.source
        }.prefix(limit))
    }

    // MARK: - Profils

    static func fetchProfile(_ entry: Entry) async throws -> HeadphoneProfile {
        let folder = (entry.path as NSString).lastPathComponent
        let raw = "\(entry.path)/\(folder) ParametricEQ.txt"
        guard let encoded = raw.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw ParseError(message: String(localized: "Adresse du profil invalide."))
        }
        let text = try await download(base + encoded)
        return try parse(text, name: "\(entry.name) (\(entry.source))")
    }

    /// Lit un fichier « ParametricEQ.txt » (AutoEQ / Equalizer APO).
    static func parse(_ text: String, name: String) throws -> HeadphoneProfile {
        var preamp = 0.0
        var filters: [EQFilter] = []
        var skipped = 0
        let number = #"(-?\d+(?:[.,]\d+)?)"#
        let preampRx = try! NSRegularExpression(pattern: #"^\s*Preamp:\s*"# + number + #"\s*dB"#, options: .caseInsensitive)
        let filterRx = try! NSRegularExpression(
            pattern: #"^\s*Filter\s*\d*\s*:\s*(ON|OFF)\s+([A-Z]+)\s+Fc\s+"# + number + #"\s*Hz"#
                + #"(?:\s+Gain\s+"# + number + #"\s*dB)?(?:\s+Q\s+"# + number + ")?",
            options: .caseInsensitive)

        func value(_ m: NSTextCheckingResult, _ i: Int, in line: String) -> Double? {
            guard let r = Range(m.range(at: i), in: line) else { return nil }
            return Double(line[r].replacingOccurrences(of: ",", with: "."))
        }

        for line in text.components(separatedBy: .newlines) {
            let ns = NSRange(line.startIndex..., in: line)
            if let m = preampRx.firstMatch(in: line, range: ns) {
                preamp = value(m, 1, in: line) ?? 0
            } else if let m = filterRx.firstMatch(in: line, range: ns) {
                let on = (Range(m.range(at: 1), in: line).map { line[$0].uppercased() } ?? "ON") == "ON"
                let type = Range(m.range(at: 2), in: line).map { line[$0].uppercased() } ?? ""
                let kind: EQFilter.Kind
                switch type {
                case "PK", "PEQ": kind = .peak
                case "LSC", "LS": kind = .lowShelf
                case "HSC", "HS": kind = .highShelf
                default:
                    skipped += 1
                    continue
                }
                guard let fc = value(m, 3, in: line) else { continue }
                let gain = value(m, 4, in: line) ?? 0
                let q = value(m, 5, in: line) ?? (kind == .peak ? 1.41 : 0.71)
                filters.append(EQFilter(kind: kind, frequency: fc, gain: gain, q: q, enabled: on))
            }
        }
        guard !filters.isEmpty else {
            throw ParseError(message: skipped > 0
                ? String(localized: "Ce profil n'utilise que des types de filtres non pris en charge.")
                : String(localized: "Aucun filtre trouvé : ce n'est pas un fichier « ParametricEQ » AutoEQ."))
        }
        guard filters.count <= 30 else { throw ParseError(message: String(localized: "Profil trop long (30 filtres maximum).")) }
        return HeadphoneProfile(name: name, preamp: preamp, filters: filters)
    }

    private static func download(_ address: String) async throws -> String {
        guard let url = URL(string: address) else { throw ParseError(message: String(localized: "Adresse invalide.")) }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Egaliseur", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ParseError(message: http.statusCode == 404
                ? String(localized: "Profil introuvable sur AutoEQ.")
                : String(localized: "AutoEQ ne répond pas (erreur \(http.statusCode))."))
        }
        guard let text = String(data: data, encoding: .utf8) else { throw ParseError(message: String(localized: "Réponse illisible.")) }
        return text
    }
}
