import SwiftUI

/// Réglages du mode paramétrique : liste des bandes, préampli, détail de la bande choisie.
struct ParametricEditor: View {
    @EnvironmentObject var model: EQModel
    @Binding var selected: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(Array(model.filters.enumerated()), id: \.element.id) { i, f in
                            chip(index: i, filter: f)
                        }
                        Button {
                            if let id = model.addBand() { selected = id }
                        } label: {
                            Image(systemName: "plus")
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.borderless)
                        .disabled(model.filters.count >= EQModel.maxParametricBands)
                        .help("Ajouter une bande (ou double-cliquez sur le graphique)")
                        .accessibilityLabel("Ajouter une bande")
                    }
                    .padding(.vertical, 2)
                }
                NumberField(label: "Préampli", value: $model.preamp, range: -24...12, unit: "dB", fraction: 1, width: 58)
            }

            if let id = selected, model.filters.contains(where: { $0.id == id }) {
                bandRow(id)
            } else {
                Text(model.filters.isEmpty
                     ? String(localized: "Aucune bande : double-cliquez sur le graphique ou cliquez sur + pour en ajouter une.")
                     : String(localized: "Glissez un point du graphique pour régler fréquence et gain. Cliquez sur une pastille pour le détail."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
            }
        }
        .opacity(model.enabled ? 1 : 0.5)
    }

    private func chip(index: Int, filter: EQFilter) -> some View {
        let isSel = filter.id == selected
        return Button {
            selected = isSel ? nil : filter.id
        } label: {
            Text("\(index + 1)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(bandColor(index).opacity(filter.enabled ? 1 : 0.35), in: Circle())
                .overlay(Circle().strokeBorder(Color.primary, lineWidth: isSel ? 2 : 0))
        }
        .buttonStyle(.plain)
        .help("\(filter.kind.label) · \(Int(filter.frequency)) Hz · \(formatDB(filter.gain)) dB")
        .accessibilityLabel("Bande \(index + 1)")
        .accessibilityValue("\(filter.kind.label), \(Int(filter.frequency)) hertz, \(formatDB(filter.gain)) décibels")
    }

    /// Accès à un champ d'une bande par son identifiant (robuste aux suppressions).
    private func binding<T>(_ id: UUID, _ kp: WritableKeyPath<EQFilter, T>, _ fallback: T) -> Binding<T> {
        Binding(
            get: { model.filters.first { $0.id == id }?[keyPath: kp] ?? fallback },
            set: { v in
                if let i = model.filters.firstIndex(where: { $0.id == id }) { model.filters[i][keyPath: kp] = v }
            })
    }

    private func bandRow(_ id: UUID) -> some View {
        HStack(alignment: .bottom, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Type").font(.caption2).foregroundStyle(.secondary)
                Picker("Type", selection: binding(id, \.kind, .peak)) {
                    ForEach(EQFilter.Kind.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .frame(width: 118)
            }
            NumberField(label: "Fréquence", value: Binding(
                            get: { binding(id, \.frequency, 1000).wrappedValue },
                            set: { binding(id, \.frequency, 1000).wrappedValue = $0; model.sortBands() }),
                        range: EQFilter.frequencyRange, unit: "Hz", fraction: 0, width: 62)
            NumberField(label: "Gain", value: binding(id, \.gain, 0),
                        range: EQFilter.gainRange, unit: "dB", fraction: 1, width: 58)
            NumberField(label: "Largeur (Q)", value: binding(id, \.q, 1),
                        range: EQFilter.qRange, fraction: 2, width: 50)
            Toggle("Active", isOn: binding(id, \.enabled, true))
                .toggleStyle(.checkbox)
                .padding(.bottom, 3)
            Spacer(minLength: 0)
            Button {
                model.removeBand(id)
                selected = nil
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .padding(.bottom, 4)
            .help("Supprimer la bande")
            .accessibilityLabel("Supprimer la bande")
        }
    }
}
