import AppKit
import CoreImage

/// NSView that renders the screenshot as a base layer with annotation shapes on top.
/// Handles mouse events for drawing with the active tool.
class AnnotationCanvasView: NSView {
    var image: NSImage {
        didSet { needsDisplay = true }
    }

    var shapes: [AnnotationShape] = [] {
        didSet { needsDisplay = true }
    }

    var currentShape: AnnotationShape? {
        didSet { needsDisplay = true }
    }

    var activeTool: AnnotationTool = .arrow
    var activeColor: NSColor = .red
    var lineWidth: CGFloat = 3.0

    // Callbacks
    var onShapeCompleted: ((AnnotationShape) -> Void)?
    var onTextRequested: ((CGPoint) -> Void)?
    var onColorSampled: ((NSColor) -> Void)?

    var isEyedropperActive = false

    private var mouseDownPoint: CGPoint?

    init(image: NSImage) {
        self.image = image
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Draw the base image
        image.draw(in: bounds)

        // Draw completed shapes
        for shape in shapes {
            drawShape(shape)
        }

        // Draw current shape being drawn
        if let current = currentShape {
            drawShape(current)
        }
    }

    private func drawShape(_ shape: AnnotationShape) {
        switch shape.tool {
        case .arrow:
            drawArrow(shape)
        case .rectangle:
            drawRectangle(shape)
        case .text:
            drawText(shape)
        case .redact:
            drawRedact(shape)
        }
    }

    private func drawArrow(_ shape: AnnotationShape) {
        let path = NSBezierPath()
        path.move(to: shape.startPoint)
        path.line(to: shape.endPoint)
        path.lineWidth = shape.lineWidth
        path.lineCapStyle = .round
        shape.color.setStroke()
        path.stroke()

        // Arrowhead
        let angle = atan2(shape.endPoint.y - shape.startPoint.y,
                          shape.endPoint.x - shape.startPoint.x)
        let arrowLength: CGFloat = 15
        let arrowAngle: CGFloat = .pi / 6

        let p1 = CGPoint(
            x: shape.endPoint.x - arrowLength * cos(angle - arrowAngle),
            y: shape.endPoint.y - arrowLength * sin(angle - arrowAngle)
        )
        let p2 = CGPoint(
            x: shape.endPoint.x - arrowLength * cos(angle + arrowAngle),
            y: shape.endPoint.y - arrowLength * sin(angle + arrowAngle)
        )

        let arrowHead = NSBezierPath()
        arrowHead.move(to: shape.endPoint)
        arrowHead.line(to: p1)
        arrowHead.line(to: p2)
        arrowHead.close()
        shape.color.setFill()
        arrowHead.fill()
    }

    private func drawRectangle(_ shape: AnnotationShape) {
        let path = NSBezierPath(rect: shape.rect)
        path.lineWidth = shape.lineWidth
        shape.color.setStroke()
        path.stroke()
    }

    private func drawText(_ shape: AnnotationShape) {
        guard let text = shape.text, !text.isEmpty else { return }

        let fontSize: CGFloat = max(14, shape.lineWidth * 5)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: shape.color,
            .strokeColor: NSColor.black,
            .strokeWidth: -2.0 // Negative = fill + stroke
        ]
        let attrStr = NSAttributedString(string: text, attributes: attributes)
        attrStr.draw(at: shape.startPoint)
    }

    private func drawRedact(_ shape: AnnotationShape) {
        let rect = shape.rect
        guard rect.width > 0, rect.height > 0 else { return }

        // Draw a pixelated/blurred overlay
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()

        // Fill with mosaic pattern
        let blockSize: CGFloat = 10
        for x in stride(from: rect.minX, to: rect.maxX, by: blockSize) {
            for y in stride(from: rect.minY, to: rect.maxY, by: blockSize) {
                let samplePoint = CGPoint(x: x + blockSize / 2, y: y + blockSize / 2)
                let color = samplePixelColor(at: samplePoint) ?? .gray
                color.setFill()
                NSBezierPath(rect: CGRect(x: x, y: y, width: blockSize, height: blockSize)).fill()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if isEyedropperActive {
            if let color = samplePixelColor(at: point) {
                onColorSampled?(color)
            }
            isEyedropperActive = false
            NSCursor.arrow.set()
            return
        }

        mouseDownPoint = point

        if activeTool == .text {
            onTextRequested?(point)
            return
        }

        currentShape = AnnotationShape(
            tool: activeTool,
            startPoint: point,
            endPoint: point,
            color: activeColor,
            lineWidth: lineWidth
        )
    }

    override func mouseDragged(with event: NSEvent) {
        guard var shape = currentShape else { return }
        let point = convert(event.locationInWindow, from: nil)
        shape.endPoint = point
        currentShape = shape
    }

    override func mouseUp(with event: NSEvent) {
        guard var shape = currentShape else { return }
        let point = convert(event.locationInWindow, from: nil)
        shape.endPoint = point

        // Only add if the shape has meaningful size
        let dx = abs(shape.endPoint.x - shape.startPoint.x)
        let dy = abs(shape.endPoint.y - shape.startPoint.y)
        if dx > 2 || dy > 2 {
            onShapeCompleted?(shape)
        }

        currentShape = nil
    }

    // MARK: - Eyedropper Cursor

    func activateEyedropper() {
        isEyedropperActive = true
        NSCursor.crosshair.set()
    }

    // MARK: - Pixel Sampling

    func samplePixelColor(at point: CGPoint) -> NSColor? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let imageSize = CGSize(width: cgImage.width, height: cgImage.height)
        let scaleX = imageSize.width / bounds.width
        let scaleY = imageSize.height / bounds.height
        let pixelX = Int(point.x * scaleX)
        let pixelY = Int(point.y * scaleY)

        guard pixelX >= 0, pixelX < cgImage.width, pixelY >= 0, pixelY < cgImage.height else { return nil }

        guard let dataProvider = cgImage.dataProvider,
              let data = dataProvider.data,
              let ptr = CFDataGetBytePtr(data) else { return nil }

        let bytesPerPixel = cgImage.bitsPerPixel / 8
        let bytesPerRow = cgImage.bytesPerRow
        let offset = pixelY * bytesPerRow + pixelX * bytesPerPixel

        let r = CGFloat(ptr[offset]) / 255.0
        let g = CGFloat(ptr[offset + 1]) / 255.0
        let b = CGFloat(ptr[offset + 2]) / 255.0

        return NSColor(red: r, green: g, blue: b, alpha: 1.0)
    }

    /// Returns a contrasting color based on the luminance at the given point.
    func autoContrastColor(at point: CGPoint) -> NSColor {
        guard let sampled = samplePixelColor(at: point) else { return .red }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        sampled.getRed(&r, green: &g, blue: &b, alpha: nil)
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b
        return luminance > 0.5 ? .red : .yellow
    }

    // MARK: - Export

    func flattenedImage() -> NSImage? {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        rep.size = bounds.size
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }
}
