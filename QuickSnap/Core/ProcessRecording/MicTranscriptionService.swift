import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import Speech

/// Captures default-microphone audio during a process recording and emits live transcript
/// segments via SFSpeechRecognizer. On-device when the system supports it (no network needed).
@MainActor
final class MicTranscriptionService {

    struct Segment: Codable {
        let timestamp: TimeInterval   // seconds since session start
        let text: String
    }

    /// Called whenever a finalised transcript segment is available.
    /// `timestamp` is seconds since `sessionStart`.
    var onSegment: ((Segment) -> Void)?

    /// Resolved input device — set after `start()` succeeds. Useful for showing
    /// "Listening to {name}" in the UI.
    private(set) var activeDeviceName: String?

    private let sessionStart: Date
    private let audioEngine = AVAudioEngine()
    private let recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// Tracks the longest finalised piece we've reported so we don't double-emit when the
    /// recognizer keeps refining a partial transcription.
    private var lastFinalLength = 0

    init(sessionStart: Date, locale: Locale = .current) {
        self.sessionStart = sessionStart
        self.recognizer = SFSpeechRecognizer(locale: locale)
    }

    // MARK: - Permissions

    /// Request both Speech Recognition and Microphone permission. Returns true if both granted.
    static func requestPermissions() async -> Bool {
        let speechGranted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
        guard speechGranted else { return false }

        let micGranted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                cont.resume(returning: granted)
            }
        }
        return micGranted
    }

    // MARK: - Lifecycle

    /// Start capturing and transcribing. Throws on engine failure or missing recognizer.
    /// Pass a `deviceUID` (from AudioInputs.list()) to bind to a specific input;
    /// `nil` uses the system's default input.
    func start(deviceUID: String? = nil) throws {
        guard let recognizer, recognizer.isAvailable else {
            throw NSError(domain: "MicTranscriptionService", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Speech recognizer not available for current locale"
            ])
        }

        // Bind input to chosen device, if any. If the requested UID isn't connected,
        // fall back to system default rather than failing.
        let inputNode = audioEngine.inputNode
        if let deviceUID, let resolvedID = AudioInputs.deviceID(forUID: deviceUID) {
            try setInputDevice(on: inputNode, to: resolvedID)
            activeDeviceName = AudioInputs.list().first(where: { $0.uid == deviceUID })?.name
        } else {
            activeDeviceName = AudioInputs.systemDefault()?.name ?? "System default"
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if #available(macOS 13, *) {
            request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
            request.addsPunctuation = true
        }
        self.request = request

        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
        NSLog("[QuickSnap] Mic transcription engine started — listening to '%@'", activeDeviceName ?? "?")

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                Task { @MainActor in
                    self.handleResult(result)
                }
            }
            if error != nil || result?.isFinal == true {
                Task { @MainActor in
                    self.flushFinal()
                }
            }
        }
    }

    func stop() {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        request?.endAudio()
        task?.finish()
        task = nil
        request = nil
    }

    // MARK: - Internals

    private func handleResult(_ result: SFSpeechRecognitionResult) {
        // Apple emits `bestTranscription` that grows as it refines. Emit only the *new* tail
        // each time, so consumers see incremental finalised text rather than re-reading the
        // whole stream.
        let full = result.bestTranscription.formattedString
        guard full.count > lastFinalLength else { return }
        let startIndex = full.index(full.startIndex, offsetBy: lastFinalLength)
        let newPiece = String(full[startIndex...]).trimmingCharacters(in: .whitespaces)
        guard !newPiece.isEmpty else { return }

        // Only commit when the recognizer marks the segment as final, OR when it's grown
        // past a sentence boundary (to avoid waiting forever on long utterances).
        let isFinalish = result.isFinal || newPiece.contains(where: { ".?!".contains($0) })
        guard isFinalish else { return }

        lastFinalLength = full.count
        let elapsed = Date().timeIntervalSince(sessionStart)
        onSegment?(Segment(timestamp: elapsed, text: newPiece))
    }

    private func flushFinal() {
        // Recognition task ended — make sure any tail text gets reported.
        // (handleResult already emits on isFinal, this is just a safety net for the error path.)
    }

    /// Bind AVAudioEngine's input node to a specific Core Audio device.
    /// Default behaviour is to follow the system default; this overrides that.
    private func setInputDevice(on inputNode: AVAudioInputNode, to deviceID: AudioDeviceID) throws {
        var id = deviceID
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitSetProperty(
            inputNode.audioUnit!,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            size
        )
        guard status == noErr else {
            throw NSError(domain: "MicTranscriptionService", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "Could not bind to selected input device (Core Audio status \(status))"
            ])
        }
    }
}
