import AppKit
import Foundation

/// How a screenshot was triggered during recording.
enum CaptureTrigger: String, Codable {
    case click       // mouseDown-triggered
    case appSwitch   // active app changed
    case diffGated   // periodic capture that passed diff threshold
    case manual      // user pressed capture button
}

/// A keyboard/mouse/clipboard event captured during recording.
enum InputEventKind {
    case mouseClick(position: CGPoint, axLabel: String?, appName: String?)
    case keyboardShortcut(keys: String)   // e.g. "⌘C", "⌘⇧S"
    case clipboardChange(preview: String) // first 200 chars
}

/// A single timestamped event in the recording timeline.
enum RecordingEvent {
    case screenshot(id: UUID, timestamp: TimeInterval, trigger: CaptureTrigger,
                    appName: String?, windowTitle: String?)
    case inputEvent(timestamp: TimeInterval, kind: InputEventKind)
    case userNote(timestamp: TimeInterval, text: String)

    var timestamp: TimeInterval {
        switch self {
        case .screenshot(_, let t, _, _, _): return t
        case .inputEvent(let t, _): return t
        case .userNote(let t, _): return t
        }
    }
}

/// A screenshot captured during a recording session.
struct RecordingScreenshot {
    let id: UUID
    let timestamp: TimeInterval
    let trigger: CaptureTrigger
    let fileURL: URL          // full-res PNG in session folder
    let apiImage: NSImage     // downscaled 1280×800 for API
    let appName: String?
    let windowTitle: String?
}

/// Accumulated recording data. Mutated by ProcessRecordingController.
@MainActor
final class ProcessRecordingSession: ObservableObject {
    let id = UUID()
    let startedAt = Date()
    @Published var events: [RecordingEvent] = []
    @Published var screenshots: [RecordingScreenshot] = []
    @Published var isRecording: Bool = true
    @Published var isPaused: Bool = false
    @Published var elapsed: TimeInterval = 0
    @Published var isMicEnabled: Bool = false // Phase 2

    /// Folder where this session's screenshots are saved.
    let sessionFolder: URL

    init() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickSnap-Recording-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        self.sessionFolder = tmp
    }

    var frameCount: Int { screenshots.count }
    var eventCount: Int { events.count }
}
