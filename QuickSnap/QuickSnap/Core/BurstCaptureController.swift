import AppKit

@MainActor
final class BurstCaptureController {
    private let region: CGRect
    private let interval: TimeInterval = 2.0
    private let maxCaptures = 20
    private var capturedImages: [CGImage] = []
    private var timer: Timer?
    private var indicatorPanel: BurstIndicatorPanel?
    private var escapeMonitor: Any?
    private let completion: ([CGImage]) -> Void
    private var isStopped = false

    init(region: CGRect, completion: @escaping ([CGImage]) -> Void) {
        self.region = region
        self.completion = completion
    }

    func start() {
        // Capture first frame immediately
        captureOnce()

        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.captureOnce() }
        }

        indicatorPanel = BurstIndicatorPanel(onStop: { [weak self] in self?.stop() })
        indicatorPanel?.update(count: capturedImages.count, max: maxCaptures)

        // Escape key stops burst
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape
                self?.stop()
                return nil
            }
            return event
        }
    }

    private func captureOnce() {
        guard !isStopped else { return }
        Task {
            guard !isStopped else { return }
            if let image = await CaptureEngine.captureRegion(region) {
                guard !isStopped else { return }
                capturedImages.append(image)
                indicatorPanel?.update(count: capturedImages.count, max: maxCaptures)
                if capturedImages.count >= maxCaptures { stop() }
            }
        }
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true

        timer?.invalidate()
        timer = nil
        indicatorPanel?.dismiss()
        indicatorPanel = nil
        if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
            escapeMonitor = nil
        }
        let images = capturedImages
        completion(images)
    }
}
