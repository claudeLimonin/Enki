import SwiftUI

/// Un traitement qui modifie encore le son, avec de quoi le couper.
struct ActiveEffect: Identifiable {
    let id: String
    let title: String
    let symbol: String
    var detail: String? = nil
    let turnOff: () -> Void
}

extension EQModel {
    /// Tout ce qui modifie le son en ce moment (hors bouton Comparer), pour que rien ne reste caché.
    var activeEffects: [ActiveEffect] {
        guard enabled else { return [] }
        var list: [ActiveEffect] = []
        let flat: Bool = {
            if abs(preamp) > 0.05 { return false }
            if mode == .graphic { return gains.allSatisfy { abs($0) < 0.05 } }
            return filters.allSatisfy { !$0.enabled || abs($0.gain) < 0.05 }
        }()
        if !flat {
            list.append(ActiveEffect(id: "eq", title: String(localized: "Égaliseur : \(presetTitle)"), symbol: "slider.vertical.3") {
                [weak self] in self.map { $0.apply(Self.presets[0]) }
            })
        }
        if correctionEnabled, let c = correction {
            list.append(ActiveEffect(id: "correction", title: String(localized: "Correction de la sortie"), symbol: "waveform.path.ecg", detail: c.name) {
                [weak self] in self?.correctionEnabled = false
            })
        }
        for rule in appRules {
            let what = rule.preset.map(display) ?? String(localized: "sans égaliseur")
            list.append(ActiveEffect(id: "app-" + rule.bundleID,
                                     title: String(localized: "\(AppAudio.displayName(for: rule.bundleID) ?? rule.name) : \(what)"),
                                     symbol: "square.grid.2x2") { [weak self] in
                self?.setChoice(.main, for: AudioApp(bundleID: rule.bundleID, name: rule.name, isPlaying: false, objects: []))
            })
        }
        if leveler > 0 {
            list.append(ActiveEffect(id: "night", title: String(localized: "Mode nuit : \(OutputOptions.levelerNames[leveler])"), symbol: "moon.fill") {
                [weak self] in self?.leveler = 0
            })
        }
        if abs(stereoWidth - 1) > 0.001 {
            list.append(ActiveEffect(id: "width", title: String(localized: "Largeur : \(Int((stereoWidth * 100).rounded())) %"), symbol: "arrow.left.and.right") {
                [weak self] in self?.stereoWidth = 1
            })
        }
        if immersive {
            list.append(ActiveEffect(id: "immersive", title: String(localized: "Immersif"), symbol: "hifispeaker.2") { [weak self] in self?.immersive = false })
        }
        if crossfeed {
            list.append(ActiveEffect(id: "crossfeed", title: String(localized: "Effet enceintes au casque"), symbol: "headphones") { [weak self] in self?.crossfeed = false })
        }
        if mono {
            list.append(ActiveEffect(id: "mono", title: String(localized: "Mono"), symbol: "speaker.wave.1.fill") { [weak self] in self?.mono = false })
        }
        if abs(balance) > 0.001 {
            list.append(ActiveEffect(id: "balance", title: String(localized: "Balance décentrée"), symbol: "dial.medium") { [weak self] in self?.balance = 0 })
        }
        if limiterEnabled {
            list.append(ActiveEffect(id: "limiter", title: String(localized: "Limiteur (crêtes au-dessus de −1 dB)"), symbol: "waveform.path") {
                [weak self] in self?.limiterEnabled = false
            })
        }
        return list
    }
}

/// « Agit aussi sur le son » : pastilles des traitements actifs, chacune avec sa croix pour le couper.
struct ActiveEffectsBar: View {
    @EnvironmentObject var model: EQModel
    /// Sans les pastilles « égaliseur » (déjà visible sur l'écran Égaliseur).
    var hideEqualizer = false

    var body: some View {
        let effects = model.activeEffects.filter { !(hideEqualizer && $0.id == "eq") }
        if !effects.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text("Agit aussi sur le son :")
                    .font(.caption).foregroundStyle(.secondary)
                FlowLayout(spacing: 6) {
                    ForEach(effects) { e in
                        Button(action: e.turnOff) {
                            HStack(spacing: 4) {
                                Image(systemName: e.symbol).imageScale(.small)
                                Text(e.title).lineLimit(1).truncationMode(.middle)
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .font(.caption)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.quinary, in: Capsule())
                            .overlay(Capsule().strokeBorder(.separator))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help(String(localized: "Couper : \(e.detail ?? e.title)"))
                        .accessibilityLabel(String(localized: "Couper : \(e.title)"))
                    }
                }
            }
        }
    }
}

/// Disposition en lignes qui reviennent à la ligne (pastilles).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = fitted(v, width)
            if x > 0, x + s.width > width { y += line + spacing; x = 0; line = 0 }
            x += s.width + spacing
            line = max(line, s.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }

    /// Taille idéale, ramenée à la largeur disponible si besoin (le texte se tronque).
    private func fitted(_ v: LayoutSubview, _ width: CGFloat) -> CGSize {
        let ideal = v.sizeThatFits(.unspecified)
        guard width.isFinite, ideal.width > width else { return ideal }
        return v.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for v in subviews {
            let s = fitted(v, bounds.width)
            if x > bounds.minX, x + s.width > bounds.maxX { y += line + spacing; x = bounds.minX; line = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            line = max(line, s.height)
        }
    }
}
