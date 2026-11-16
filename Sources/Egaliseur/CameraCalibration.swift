import AppKit
import AVFoundation
import SwiftUI
import Vision

/// Résultat d'une mesure : distance de l'auditeur à l'écran et décalage latéral.
struct ListeningPosition: Equatable {
    /// Distance estimée (mètres).
    var distance: Double
    /// Décalage par rapport au centre de l'écran (mètres) : positif = vous êtes à votre droite.
    var offset: Double

    /// Écart moyen entre les pupilles d'un adulte (mètres).
    static let pupilDistance = 0.063
    /// Champ horizontal supposé de la caméra FaceTime d'un Mac (degrés).
    static let cameraFieldOfView = 70.0

    /// Distance et décalage à partir de la position des pupilles dans l'image.
    /// - Parameters:
    ///   - pupilGap: écart entre les pupilles, en fraction de la largeur de l'image.
    ///   - centerX: milieu des pupilles, en fraction de la largeur (0 = bord gauche de l'image).
    static func estimate(pupilGap: Double, centerX: Double, fieldOfView: Double = cameraFieldOfView) -> ListeningPosition? {
        guard pupilGap > 0.005, pupilGap < 0.6 else { return nil }
        // Focale exprimée en largeurs d'image : f = 0,5 / tan(champ / 2).
        let focal = 0.5 / tan(fieldOfView / 2 * .pi / 180)
        let distance = pupilDistance * focal / pupilGap
        // La caméra regarde l'utilisateur : s'il se décale vers sa droite, il apparaît à gauche de l'image.
        let angle = atan((0.5 - centerX) / focal)
        return ListeningPosition(distance: distance, offset: distance * tan(angle))
    }

    /// Réglage « Distance d'écoute » le plus proche : 0 proche (< 50 cm), 1 normale (< 80 cm), 2 loin.
    var distanceLevel: Int { distance < 0.5 ? 0 : (distance < 0.8 ? 1 : 2) }
    /// Assez centré pour le niveau Immersif (moins de 10 cm d'écart).
    var isCentered: Bool { abs(offset) < 0.10 }
}

/// Mesure ponctuelle par la caméra : allumée quelques secondes, puis éteinte.
/// Rien n'est enregistré ni envoyé : seules la position des yeux et la distance sont calculées, sur le Mac.
@MainActor
final class CameraCalibration: NSObject, ObservableObject {
    enum State: Equatable {
        case idle, measuring(progress: Double), done(ListeningPosition), failed(String), denied
    }

    @Published private(set) var state: State = .idle

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "EnkiAudio.calibration")
    private let collector = SampleCollector()
    private var timer: Timer?
    static let duration = 3.0

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            run()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in granted ? self.run() : (self.state = .denied) }
            }
        default:
            state = .denied
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        let session = self.session
        queue.async { if session.isRunning { session.stopRunning() } }
    }

    private func run() {
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
                ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: camera) else {
            state = .failed(String(localized: "Aucune caméra disponible (capot fermé, ou caméra utilisée par une autre app)."))
            return
        }
        session.beginConfiguration()
        session.sessionPreset = .high
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        if session.canAddInput(input) { session.addInput(input) }
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(collector, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()

        collector.reset()
        state = .measuring(progress: 0)
        let session = self.session
        queue.async { session.startRunning() }

        let start = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let elapsed = Date().timeIntervalSince(start)
                if elapsed < Self.duration {
                    self.state = .measuring(progress: elapsed / Self.duration)
                } else {
                    self.stop()
                    self.finish()
                }
            }
        }
    }

    private func finish() {
        let samples = collector.samples
        guard samples.count >= 5 else {
            state = .failed(String(localized: "Visage non détecté. Placez-vous face à l'écran, bien éclairé, puis recommencez."))
            return
        }
        // Médiane : quelques images floues ou un regard détourné ne faussent pas le résultat.
        func median(_ v: [Double]) -> Double { let s = v.sorted(); return s[s.count / 2] }
        let gap = median(samples.map(\.gap)), center = median(samples.map(\.center))
        if let position = ListeningPosition.estimate(pupilGap: gap, centerX: center) {
            state = .done(position)
        } else {
            state = .failed(String(localized: "Mesure impossible. Recommencez en restant immobile."))
        }
    }
}

/// Reçoit les images de la caméra (file dédiée) et y repère les pupilles avec Vision.
private final class SampleCollector: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    struct Sample { let gap: Double; let center: Double }
    private let lock = NSLock()
    private var collected: [Sample] = []

    var samples: [Sample] { lock.lock(); defer { lock.unlock() }; return collected }
    func reset() { lock.lock(); collected = []; lock.unlock() }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let request = VNDetectFaceLandmarksRequest()
        try? VNImageRequestHandler(cvPixelBuffer: pixels, options: [:]).perform([request])
        // Le visage le plus grand : la personne devant l'écran.
        guard let face = request.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }),
              let left = face.landmarks?.leftPupil?.normalizedPoints.first,
              let right = face.landmarks?.rightPupil?.normalizedPoints.first else { return }
        // Points relatifs au cadre du visage → coordonnées de l'image (fractions de largeur et de hauteur).
        let box = face.boundingBox
        let width = Double(CVPixelBufferGetWidth(pixels)), height = Double(CVPixelBufferGetHeight(pixels))
        func image(_ p: CGPoint) -> (x: Double, y: Double) {
            (Double(box.minX + p.x * box.width), Double(box.minY + p.y * box.height))
        }
        let a = image(left), b = image(right)
        // Écart exprimé en largeurs d'image (la hauteur est convertie selon le format de l'image).
        let dx = a.x - b.x, dy = (a.y - b.y) * height / width
        let gap = (dx * dx + dy * dy).squareRoot()
        lock.lock()
        collected.append(Sample(gap: gap, center: (a.x + b.x) / 2))
        lock.unlock()
    }
}

/// Feuille « Mesurer avec la caméra » (page Écoute).
struct CalibrationSheet: View {
    @EnvironmentObject var model: EQModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var calibration = CameraCalibration()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Mesurer votre position", systemImage: "person.crop.square.badge.camera").font(.headline)
            content
            HStack {
                Spacer()
                switch calibration.state {
                case .done(let p):
                    Button("Recommencer") { calibration.start() }
                    Button("Appliquer") {
                        model.listeningDistance = p.distanceLevel
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                case .measuring:
                    Button("Annuler") { calibration.stop(); dismiss() }.keyboardShortcut(.cancelAction)
                case .denied:
                    Button("Annuler") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Ouvrir les Réglages Système…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                default:
                    Button("Annuler") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Mesurer") { calibration.start() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 420)
        .onDisappear { calibration.stop() }
    }

    @ViewBuilder private var content: some View {
        switch calibration.state {
        case .idle:
            Text("Asseyez-vous comme d'habitude, face à l'écran, puis cliquez sur Mesurer. La caméra s'allume 3 secondes pour estimer votre distance, puis s'éteint.")
                .fixedSize(horizontal: false, vertical: true)
            Label("Aucune image n'est enregistrée ni envoyée : seule la distance est calculée, sur ce Mac.", systemImage: "lock")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .measuring(let progress):
            Text("Regardez l'écran sans bouger…")
            ProgressView(value: progress)
        case .done(let p):
            let cm = Int((p.distance * 100).rounded())
            Text("Vous êtes à environ \(cm) cm de l'écran.").font(.title3.weight(.semibold))
            Text("Distance d'écoute conseillée : \(OutputOptions.distanceNames[p.distanceLevel]) (\(OutputOptions.distanceHints[p.distanceLevel])).")
            if p.isCentered {
                Label("Vous êtes bien centré : idéal pour le niveau Immersif.", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            } else {
                let side = p.offset > 0 ? String(localized: "vers la gauche") : String(localized: "vers la droite")
                Label("Décalez-vous d'environ \(Int((abs(p.offset) * 100).rounded())) cm \(side) pour être au centre.", systemImage: "arrow.left.and.right")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Estimation approximative (environ ±10 cm), d'après l'écart moyen entre les yeux.")
                .font(.caption).foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .denied:
            Text("Enki Audio n'a pas accès à la caméra. Autorisez-le dans Réglages Système → Confidentialité et sécurité → Caméra.")
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
