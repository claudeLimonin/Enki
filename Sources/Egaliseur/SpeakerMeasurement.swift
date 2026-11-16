import AppKit
import AVFoundation
import CoreAudio
import SwiftUI

/// Micro disponible sur le Mac (y compris celui d'un iPhone via la Caméra de continuité).
struct InputDevice: Identifiable, Hashable {
    let id: AudioObjectID
    let name: String
    var isIPhone: Bool { name.localizedCaseInsensitiveContains("iphone") }
}

/// Mesure des haut-parleurs : joue un balayage de fréquences et l'enregistre avec le micro choisi.
/// Le son joué par Enki Audio n'est pas capté par son propre traitement : on mesure les haut-parleurs bruts.
@MainActor
final class SpeakerMeasurement: ObservableObject {
    enum State: Equatable {
        case ready
        case measuring(pass: Int, progress: Double)
        case analyzing
        case done(levels: [Double], snr: Double, correction: HeadphoneProfile)
        case failed(String)
        case denied
    }

    @Published private(set) var state: State = .ready
    @Published private(set) var devices: [InputDevice] = []
    @Published var selected: AudioObjectID?

    static let passes = 2
    private var cancelled = false

    // MARK: Micros

    func refreshDevices() {
        devices = Self.inputDevices()
        if selected == nil || !devices.contains(where: { $0.id == selected }) {
            // Le micro de l'iPhone en priorité : il mesure ce qui arrive à vos oreilles.
            selected = (devices.first(where: \.isIPhone) ?? devices.first)?.id
        }
    }

    static func inputDevices() -> [InputDevice] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                     mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var n: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &n) == noErr, n > 0 else { return nil }
            var nameAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var name: Unmanaged<CFString>?
            var s = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &s, &name) == noErr,
                  let n = name?.takeRetainedValue() as String?, !n.hasPrefix("CADefaultDevice") else { return nil }
            return InputDevice(id: id, name: n)
        }
    }

    // MARK: Mesure

    func start(outputName: String) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            Task { await run(outputName: outputName) }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    if granted { await self.run(outputName: outputName) } else { self.state = .denied }
                }
            }
        default:
            state = .denied
        }
    }

    func cancel() { cancelled = true }

    private func run(outputName: String) async {
        guard let device = selected else {
            state = .failed(String(localized: "Aucun micro choisi."))
            return
        }
        cancelled = false
        let player = AVAudioEngine(), node = AVAudioPlayerNode()
        player.attach(node)
        let rate = player.outputNode.outputFormat(forBus: 0).sampleRate > 0 ? player.outputNode.outputFormat(forBus: 0).sampleRate : 48_000
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else { return }
        player.connect(node, to: player.mainMixerNode, format: format)
        let signal = SpeakerAnalysis.testSignal(sampleRate: rate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(signal.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(signal.count)
        for ch in 0..<2 { signal.withUnsafeBufferPointer { buffer.floatChannelData![ch].update(from: $0.baseAddress!, count: signal.count) } }

        var recordings: [[Float]] = []
        var recordedRate = rate
        for pass in 1...Self.passes {
            state = .measuring(pass: pass, progress: 0)
            let recorder = AVAudioEngine()
            // Le micro choisi (et non celui par défaut du Mac).
            var id = device
            guard let unit = recorder.inputNode.audioUnit,
                  AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                       &id, UInt32(MemoryLayout<AudioObjectID>.size)) == noErr else {
                state = .failed(String(localized: "Impossible d'utiliser ce micro."))
                return
            }
            let inFormat = recorder.inputNode.inputFormat(forBus: 0)
            guard inFormat.sampleRate > 0 else {
                state = .failed(String(localized: "Le micro ne répond pas. Vérifiez que l'iPhone est proche, déverrouillé une fois, avec le Wi‑Fi et le Bluetooth."))
                return
            }
            recordedRate = inFormat.sampleRate
            let sink = SampleSink()
            recorder.inputNode.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { buf, _ in sink.append(buf) }
            do {
                try recorder.start()
                try player.start()
            } catch {
                recorder.inputNode.removeTap(onBus: 0)
                state = .failed(String(localized: "Mesure impossible : \(error.localizedDescription)"))
                return
            }
            try? await Task.sleep(for: .milliseconds(300))
            node.scheduleBuffer(buffer, completionHandler: nil)
            node.play()
            let total = Double(signal.count) / rate + 0.3
            let start = Date()
            while Date().timeIntervalSince(start) < total {
                if cancelled { break }
                state = .measuring(pass: pass, progress: Date().timeIntervalSince(start) / total)
                try? await Task.sleep(for: .milliseconds(100))
            }
            node.stop()
            player.stop()
            recorder.inputNode.removeTap(onBus: 0)
            recorder.stop()
            if cancelled { state = .ready; return }
            recordings.append(sink.samples)
            try? await Task.sleep(for: .milliseconds(400))
        }

        state = .analyzing
        let recs = recordings, inRate = recordedRate
        let result = await Task.detached(priority: .userInitiated) { () -> (SpeakerAnalysis.Response, HeadphoneProfile)? in
            guard let r = SpeakerAnalysis.response(played: signal, playedRate: rate, recordings: recs, recordedRate: inRate) else { return nil }
            return (r, SpeakerAnalysis.fitCorrection(levels: r.levels))
        }.value
        guard let (response, fit) = result else {
            state = .failed(String(localized: "Enregistrement trop court. Recommencez."))
            return
        }
        if response.clipped {
            state = .failed(String(localized: "Le micro a saturé : baissez un peu le volume du Mac, puis recommencez."))
        } else if response.snr < SpeakerAnalysis.minSNR {
            state = .failed(String(localized: "Le balayage s'entend trop peu par rapport au bruit ambiant. Montez le volume, rapprochez l'iPhone ou faites le silence, puis recommencez."))
        } else {
            var correction = fit
            let date = Date().formatted(date: .abbreviated, time: .omitted)
            correction.name = String(localized: "Mesure \(outputName) · \(date)")
            state = .done(levels: response.levels, snr: response.snr, correction: correction)
        }
    }
}

/// Reçoit l'enregistrement (fil audio) : premier canal, ajouté sous verrou.
private final class SampleSink: @unchecked Sendable {
    private let lock = NSLock()
    private var data: [Float] = []
    var samples: [Float] { lock.lock(); defer { lock.unlock() }; return data }
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData?[0] else { return }
        let chunk = Array(UnsafeBufferPointer(start: ch, count: Int(buffer.frameLength)))
        lock.lock(); data += chunk; lock.unlock()
    }
}

// MARK: - Assistant de mesure

struct MeasurementSheet: View {
    @EnvironmentObject var model: EQModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var measure = SpeakerMeasurement()

    private var outputName: String { model.currentDevice?.name ?? String(localized: "haut-parleurs") }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Mesurer vos haut-parleurs", systemImage: "waveform.badge.mic").font(.headline)
            content
            HStack {
                if case .ready = measure.state {
                    Button("Vérifier le mode micro…") { AVCaptureDevice.showSystemUserInterface(.microphoneModes) }
                        .help("Ouvre le réglage de macOS : choisissez « Standard » (ni isolement de la voix, ni large spectre).")
                }
                Spacer()
                buttons
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { measure.refreshDevices() }
        .onDisappear { measure.cancel() }
    }

    @ViewBuilder private var buttons: some View {
        switch measure.state {
        case .ready:
            Button("Annuler") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Lancer la mesure") { measure.start(outputName: outputName) }
                .keyboardShortcut(.defaultAction)
                .disabled(measure.selected == nil)
        case .measuring, .analyzing:
            Button("Annuler") { measure.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
        case .done(_, _, let correction):
            Button("Recommencer") { measure.start(outputName: outputName) }
            Button("Appliquer la correction") {
                model.setCorrection(correction)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        case .failed:
            Button("Fermer") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Recommencer") { measure.start(outputName: outputName) }.keyboardShortcut(.defaultAction)
        case .denied:
            Button("Fermer") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Ouvrir les Réglages Système…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch measure.state {
        case .ready:
            Text("Enki Audio joue un balayage de fréquences (2 × 10 secondes) et l'enregistre à votre place d'écoute, pour corriger les défauts de vos haut-parleurs et de la pièce.")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                step(1, "Posez l'iPhone à votre place, à hauteur d'oreilles, micro du bas tourné vers l'écran. Verrouillez-le.")
                step(2, "Faites le silence et mettez le volume du Mac à un niveau d'écoute normal.")
                step(3, "Choisissez le micro ci-dessous, puis lancez la mesure sans bouger.")
            }
            HStack {
                Picker("Micro", selection: $measure.selected) {
                    ForEach(measure.devices) { d in
                        Text(d.isIPhone ? "\(d.name) (recommandé)" : d.name).tag(Optional(d.id))
                    }
                }
                Button { measure.refreshDevices() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Actualiser la liste des micros")
                    .accessibilityLabel("Actualiser la liste des micros")
            }
            if !measure.devices.contains(where: \.isIPhone) {
                Label("iPhone non détecté : même compte Apple, Wi‑Fi et Bluetooth activés, iPhone proche du Mac. Puis actualisez.", systemImage: "iphone.slash")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .measuring(let pass, let progress):
            Text("Mesure \(pass) sur \(SpeakerMeasurement.passes)… Silence, s'il vous plaît.")
            ProgressView(value: progress)
        case .analyzing:
            HStack { ProgressView().controlSize(.small); Text("Analyse…") }
        case .done(let levels, let snr, let correction):
            MeasurementChart(levels: levels, correction: correction)
                .frame(height: 200)
            HStack(spacing: 14) {
                legend(.orange, false, "Mesuré")
                legend(.purple, true, "Correction")
                legend(.primary, false, "Résultat")
            }
            .font(.caption)
            Text("\(correction.filters.count) filtres, prudents : les pics sont baissés, les creux à peine remontés. Qualité de la mesure : \(Int(snr)) dB au-dessus du bruit.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("La correction est mémorisée pour « \(outputName) » et se règle ensuite comme une correction de casque.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .denied:
            Text("Enki Audio n'a pas accès au micro. Autorisez-le dans Réglages Système → Confidentialité et sécurité → Micro.")
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)").font(.caption.weight(.bold)).foregroundStyle(.white)
                .frame(width: 18, height: 18).background(Color.accentColor, in: Circle())
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func legend(_ color: Color, _ dashed: Bool, _ text: LocalizedStringKey) -> some View {
        HStack(spacing: 6) {
            Rectangle().fill(.clear).frame(width: 14, height: 2)
                .overlay(Rectangle().stroke(color, style: StrokeStyle(lineWidth: 2, dash: dashed ? [4, 3] : [])))
            Text(text)
        }
    }
}

/// Réponse mesurée, correction proposée et résultat attendu.
struct MeasurementChart: View {
    let levels: [Double]
    let correction: HeadphoneProfile

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height - 16, dbMax = 15.0
            let f0 = SpeakerAnalysis.frequencies.first!, f1 = SpeakerAnalysis.frequencies.last!
            func x(_ f: Double) -> CGFloat { CGFloat(log(f / f0) / log(f1 / f0)) * w }
            func y(_ db: Double) -> CGFloat { h / 2 - CGFloat(db.clamped(to: -dbMax...dbMax) / dbMax) * h / 2 }
            // Zone corrigée (fiable) en léger fond.
            let band = CGRect(x: x(SpeakerAnalysis.correctionBand.low), y: 0,
                              width: x(SpeakerAnalysis.correctionBand.high) - x(SpeakerAnalysis.correctionBand.low), height: h)
            ctx.fill(Path(band), with: .color(.accentColor.opacity(0.06)))
            for f in [100.0, 1000, 10000] {
                var l = Path(); l.move(to: CGPoint(x: x(f), y: 0)); l.addLine(to: CGPoint(x: x(f), y: h))
                ctx.stroke(l, with: .color(.secondary.opacity(0.2)))
            }
            var zero = Path(); zero.move(to: CGPoint(x: 0, y: h / 2)); zero.addLine(to: CGPoint(x: w, y: h / 2))
            ctx.stroke(zero, with: .color(.secondary.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            for (f, label) in [(100.0, "100 Hz"), (1000, "1 kHz"), (10000, "10 kHz")] {
                ctx.draw(Text(label).font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: x(f), y: size.height - 2), anchor: .bottom)
            }
            func curve(_ values: [Double]) -> Path {
                var p = Path()
                for (i, f) in SpeakerAnalysis.frequencies.enumerated() {
                    let pt = CGPoint(x: x(f), y: y(values[i]))
                    i == 0 ? p.move(to: pt) : p.addLine(to: pt)
                }
                return p
            }
            let corr = SpeakerAnalysis.frequencies.map { EQMath.responseDB(correction.filters, at: $0, sampleRate: 48_000) }
            ctx.stroke(curve(levels), with: .color(.orange), lineWidth: 2)
            ctx.stroke(curve(corr), with: .color(.purple), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            ctx.stroke(curve(zip(levels, corr).map(+)), with: .color(.primary), lineWidth: 2)
        }
        .padding(8)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel(Text("Réponse mesurée, correction et résultat"))
    }
}
