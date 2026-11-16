import CoreAudio
import Foundation
import os

struct AudioError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private func check(_ status: OSStatus, _ what: String) throws {
    guard status == noErr else { throw AudioError(message: "\(what) (code \(status))") }
}

private func address(_ selector: AudioObjectPropertySelector,
                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

private let systemObject = AudioObjectID(kAudioObjectSystemObject)
private let log = Logger(subsystem: "local.egaliseur.app", category: "audio")

/// Un processus connu de Core Audio (qui joue ou a joué du son).
struct AudioProcess: Equatable {
    let object: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let isPlaying: Bool
}

/// Applications à capter séparément : clé (identifiant d'app) → processus.
struct AppTapGroup: Equatable {
    let key: String
    let objects: [AudioObjectID]
}

/// Capte le son du système (process taps), le fait passer par l'égaliseur
/// et le rejoue sur le périphérique de sortie par défaut.
/// Tap 0 : tout le son sauf les applications réglées à part ; taps suivants : une par application.
final class AudioEngine {
    let processor = EQProcessor()

    private(set) var isRunning = false
    private(set) var sampleRate: Double = 48_000
    private(set) var outputName = ""

    /// Appelé (thread principal) quand la sortie ou sa fréquence change.
    var onRouteChange: (() -> Void)?
    /// Appelé (thread principal) quand la liste des processus audio change.
    var onProcessesChange: (() -> Void)?

    private var tapIDs: [AudioObjectID] = []
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var outputID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var rateListener: AudioObjectPropertyListenerBlock?

    init() {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(systemObject, &addr, .main) { [weak self] _, _ in
            guard let self, self.isRunning else { return }
            if (try? Self.defaultOutputDevice()) != self.outputID { self.onRouteChange?() }
        }
        var paddr = address(kAudioHardwarePropertyProcessObjectList)
        AudioObjectAddPropertyListenerBlock(systemObject, &paddr, .main) { [weak self] _, _ in
            self?.onProcessesChange?()
        }
    }

    // MARK: - Lecture de propriétés

    /// Identifiant stable et nom de la sortie audio par défaut actuelle.
    static func defaultOutputInfo() -> (uid: String, name: String)? {
        guard let id = try? defaultOutputDevice(),
              let uid = try? string(id, kAudioDevicePropertyDeviceUID), !uid.isEmpty else { return nil }
        return (uid, (try? string(id, kAudioObjectPropertyName)) ?? "")
    }

    private static func defaultOutputDevice() throws -> AudioObjectID {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &id),
                  String(localized: "Impossible de lire la sortie audio par défaut"))
        guard id != kAudioObjectUnknown else { throw AudioError(message: String(localized: "Aucune sortie audio")) }
        return id
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value),
                  String(localized: "Impossible de lire une propriété audio"))
        return (value?.takeRetainedValue() as String?) ?? ""
    }

    private static func scalar<T: BitwiseCopyable>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) -> T? {
        var addr = address(selector)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func nominalSampleRate(_ id: AudioObjectID) -> Double? {
        guard let rate: Float64 = scalar(id, kAudioDevicePropertyNominalSampleRate, 0), rate > 0 else { return nil }
        return rate
    }

    private static func ownProcessObject() throws -> AudioObjectID {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = getpid()
        var obj = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(systemObject, &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &obj),
                  String(localized: "Impossible d'identifier le processus audio"))
        guard obj != kAudioObjectUnknown else { throw AudioError(message: String(localized: "Processus audio introuvable")) }
        return obj
    }

    /// Tous les processus connus de Core Audio, sauf le nôtre.
    static func audioProcesses() -> [AudioProcess] {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        let me = getpid()
        return ids.compactMap { id in
            guard let pid: pid_t = scalar(id, kAudioProcessPropertyPID, 0), pid != me else { return nil }
            let bundle = (try? string(id, kAudioProcessPropertyBundleID)) ?? ""
            let playing: UInt32 = scalar(id, kAudioProcessPropertyIsRunningOutput, 0) ?? 0
            return AudioProcess(object: id, pid: pid, bundleID: bundle, isPlaying: playing != 0)
        }
    }

    private static func makeTap(_ description: CATapDescription) throws -> AudioObjectID {
        description.uuid = UUID()
        description.name = "Egaliseur"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        var id = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &id), String(localized: "Création du tap audio impossible"))
        return id
    }

    // MARK: - Démarrage / arrêt

    /// `groups` : applications à capter à part (7 au plus).
    /// `prepare` reçoit la fréquence d'échantillonnage et les clés des applications réellement captées,
    /// dans l'ordre des sources du moteur (après la source 0, le son général).
    func start(groups: [AppTapGroup] = [], prepare: (Double, [String]) -> Void) throws {
        stop()
        do {
            try startUnsafe(groups: groups, prepare: prepare)
        } catch {
            log.error("Démarrage impossible (\(groups.count, privacy: .public) app(s) à part) : \(error.localizedDescription, privacy: .public)")
            stop()
            throw error
        }
    }

    private func startUnsafe(groups: [AppTapGroup], prepare: (Double, [String]) -> Void) throws {
        outputID = try Self.defaultOutputDevice()
        let outputUID = try Self.string(outputID, kAudioDevicePropertyDeviceUID)
        outputName = (try? Self.string(outputID, kAudioObjectPropertyName)) ?? ""

        let appGroups = Array(groups.filter { !$0.objects.isEmpty }.prefix(EQProcessor.maxSources - 1))
        let separated = appGroups.flatMap(\.objects)

        // Tap 0 : tout le son sauf le nôtre et celui des applications captées à part.
        let globalTap = CATapDescription(stereoGlobalTapButExcludeProcesses: [try Self.ownProcessObject()] + separated)
        var descriptions = [globalTap]
        for g in appGroups {
            descriptions.append(CATapDescription(stereoMixdownOfProcesses: g.objects))
        }
        for d in descriptions { tapIDs.append(try Self.makeTap(d)) }

        var format = AudioStreamBasicDescription()
        var fsize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var faddr = address(kAudioTapPropertyFormat)
        try check(AudioObjectGetPropertyData(tapIDs[0], &faddr, 0, nil, &fsize, &format), String(localized: "Format du tap illisible"))
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32 else {
            throw AudioError(message: String(localized: "Format audio non pris en charge"))
        }
        let nonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        processor.buffersPerTap = nonInterleaved ? max(1, Int(format.mChannelsPerFrame)) : 1

        // Périphérique agrégé privé : entrées = taps, sortie = haut-parleurs.
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Egaliseur",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: descriptions.map { d -> [String: Any] in
                [kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: d.uuid.uuidString]
            },
        ]
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID),
                  String(localized: "Création du périphérique audio impossible"))

        sampleRate = Self.nominalSampleRate(aggregateID)
            ?? Self.nominalSampleRate(outputID)
            ?? (format.mSampleRate > 0 ? format.mSampleRate : 48_000)
        logInputLayout(expectedTaps: descriptions.count)
        prepare(sampleRate, appGroups.map(\.key))

        // Cycles de 512 échantillons (≈ 10 ms) plutôt que 128 : bien plus de marge, délai imperceptible.
        setBufferFrameSize(512)

        let processor = self.processor
        // File nil : le traitement s'exécute directement sur le fil temps réel de Core Audio.
        // (Une file GCD ajoute un délai d'ordonnancement → cycles manqués → craquements.)
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, inData, _, outData, _ in
            processor.process(inData, outData)
        }, String(localized: "Création du traitement audio impossible"))
        try check(AudioDeviceStart(aggregateID, procID), String(localized: "Démarrage audio impossible"))

        // Redémarre si la fréquence de la sortie change.
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.isRunning else { return }
            if Self.nominalSampleRate(self.outputID) != self.sampleRate { self.onRouteChange?() }
        }
        var raddr = address(kAudioDevicePropertyNominalSampleRate)
        AudioObjectAddPropertyListenerBlock(outputID, &raddr, .main, listener)
        rateListener = listener

        isRunning = true
    }

    /// Fixe la taille des cycles audio, dans les limites acceptées par le périphérique.
    private func setBufferFrameSize(_ wanted: UInt32) {
        var range = AudioValueRange()
        var rsize = UInt32(MemoryLayout<AudioValueRange>.size)
        var raddr = address(kAudioDevicePropertyBufferFrameSizeRange)
        var frames = wanted
        if AudioObjectGetPropertyData(aggregateID, &raddr, 0, nil, &rsize, &range) == noErr, range.mMaximum > 0 {
            frames = UInt32(min(max(Double(wanted), range.mMinimum), range.mMaximum))
        }
        var addr = address(kAudioDevicePropertyBufferFrameSize)
        let status = AudioObjectSetPropertyData(aggregateID, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)
        log.notice("Taille des cycles : \(frames, privacy: .public) échantillons (\(status == noErr ? "ok" : "refusée", privacy: .public))")
    }

    /// Journalise la disposition des flux d'entrée (pour diagnostiquer l'ordre des taps).
    private func logInputLayout(expectedTaps: Int) {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(aggregateID, &addr, 0, nil, &size) == noErr, size > 0 else { return }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(aggregateID, &addr, 0, nil, &size, raw) == noErr else { return }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        let channels = list.map { String($0.mNumberChannels) }.joined(separator: ",")
        log.notice("Entrées : \(list.count, privacy: .public) flux [\(channels, privacy: .public)], taps attendus : \(expectedTaps, privacy: .public), tampons par tap : \(self.processor.buffersPerTap, privacy: .public)")

        // Ordre réel des taps dans l'agrégat : doit suivre l'ordre déclaré (son général d'abord).
        var taddr = address(kAudioAggregateDevicePropertySubTapList)
        var tsize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(aggregateID, &taddr, 0, nil, &tsize) == noErr, tsize > 0 else { return }
        var subTaps = [AudioObjectID](repeating: 0, count: Int(tsize) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(aggregateID, &taddr, 0, nil, &tsize, &subTaps) == noErr else { return }
        let declared = tapIDs.map { (try? Self.string($0, kAudioTapPropertyUID)) ?? "?" }
        var actual = subTaps.map { (try? Self.string($0, kAudioDevicePropertyDeviceUID)) ?? "?" }
        if actual.contains("?") {
            // Repli : liste des UID de taps telle qu'enregistrée par l'agrégat.
            var laddr = address(kAudioAggregateDevicePropertyTapList)
            var list: Unmanaged<CFArray>?
            var lsize = UInt32(MemoryLayout<Unmanaged<CFArray>?>.size)
            if AudioObjectGetPropertyData(aggregateID, &laddr, 0, nil, &lsize, &list) == noErr,
               let uids = list?.takeRetainedValue() as? [String] {
                actual = uids
            }
        }
        let ordered = declared == actual
        log.notice("Ordre des taps : \(ordered ? "conforme" : "DIFFÉRENT", privacy: .public) (déclarés \(declared.map { $0.prefix(4) }, privacy: .public), agrégat \(actual.map { $0.prefix(4) }, privacy: .public))")
    }

    func stop() {
        isRunning = false
        if let listener = rateListener {
            var raddr = address(kAudioDevicePropertyNominalSampleRate)
            AudioObjectRemovePropertyListenerBlock(outputID, &raddr, .main, listener)
            rateListener = nil
        }
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        for id in tapIDs { AudioHardwareDestroyProcessTap(id) }
        tapIDs = []
    }
}
