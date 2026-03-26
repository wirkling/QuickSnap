import AppKit
import SwiftUI

/// Manages the annotation editor window.
@MainActor
final class AnnotationWindowController {
    private var window: NSWindow?
    private var canvasView: AnnotationCanvasView?

    // State
    private var shapes: [AnnotationShape] = []
    private var undoneShapes: [AnnotationShape] = [] // redo stack
    private var activeTool: AnnotationTool = .arrow
    private var activeColor: NSColor = .red
    private var lineWidth: CGFloat = 3.0
    private let sourceURL: URL

    /// Called after the annotated image is saved successfully.
    var onSaved: (() -> Void)?

    init(image: NSImage, sourceURL: URL) {
        self.sourceURL = sourceURL
        setupWindow(with: image)
    }

    private func setupWindow(with image: NSImage) {
        let imageSize = image.size
        let maxDimension: CGFloat = 900
        let scale = min(maxDimension / imageSize.width, maxDimension / imageSize.height, 1.0)
        let canvasSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let toolbarHeight: CGFloat = 44

        let canvas = AnnotationCanvasView(image: image)
        canvas.frame = NSRect(x: 0, y: 0, width: canvasSize.width, height: canvasSize.height)
        canvas.activeTool = activeTool
        canvas.activeColor = activeColor
        canvas.lineWidth = lineWidth
        canvas.onShapeCompleted = { [weak self] shape in
            self?.addShape(shape)
        }
        canvas.onTextRequested = { [weak self] point in
            self?.promptForText(at: point)
        }
        canvas.onColorSampled = { [weak self] color in
            self?.activeColor = color
            self?.canvasView?.activeColor = color
            self?.updateToolbar()
        }
        canvasView = canvas

        // Container with toolbar at top and canvas below
        let containerHeight = canvasSize.height + toolbarHeight
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: canvasSize.width, height: containerHeight))

        canvas.frame = NSRect(x: 0, y: 0, width: canvasSize.width, height: canvasSize.height)
        contentView.addSubview(canvas)

        // SwiftUI toolbar hosted in NSHostingView
        let toolbarView = createToolbarHostingView(width: canvasSize.width, height: toolbarHeight)
        toolbarView.frame = NSRect(x: 0, y: canvasSize.height, width: canvasSize.width, height: toolbarHeight)
        contentView.addSubview(toolbarView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: canvasSize.width, height: containerHeight),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Annotate — \(sourceURL.lastPathComponent)"
        window.contentView = contentView
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.level = .floating

        self.window = window
    }

    // MARK: - Shape Management

    private func addShape(_ shape: AnnotationShape) {
        shapes.append(shape)
        undoneShapes.removeAll()
        canvasView?.shapes = shapes
        updateToolbar()
    }

    func undo() {
        guard let last = shapes.popLast() else { return }
        undoneShapes.append(last)
        canvasView?.shapes = shapes
        updateToolbar()
    }

    func redo() {
        guard let last = undoneShapes.popLast() else { return }
        shapes.append(last)
        canvasView?.shapes = shapes
        updateToolbar()
    }

    // MARK: - Text Input

    private func promptForText(at point: CGPoint) {
        let alert = NSAlert()
        alert.messageText = "Add Text"
        alert.informativeText = "Enter the text annotation:"
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        textField.placeholderString = "Type here..."
        alert.accessoryView = textField
        alert.window.initialFirstResponder = textField

        if alert.runModal() == .alertFirstButtonReturn {
            let text = textField.stringValue
            if !text.isEmpty {
                var shape = AnnotationShape(
                    tool: .text,
                    startPoint: point,
                    endPoint: point,
                    color: activeColor,
                    lineWidth: lineWidth
                )
                shape.text = text
                addShape(shape)
            }
        }
    }

    // MARK: - Save

    func save() {
        guard let flatImage = canvasView?.flattenedImage() else { return }

        // Overwrite the original file
        guard let tiffData = flatImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else { return }

        do {
            try pngData.write(to: sourceURL, options: .atomic)
            print("[QuickSnap] Annotated image saved to: \(sourceURL.path)")
            onSaved?()
            window?.close()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Save Failed"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    // MARK: - Toolbar

    private var toolbarHostingView: NSHostingView<AnnotationToolbar>?

    private func createToolbarHostingView(width: CGFloat, height: CGFloat) -> NSView {
        let toolbar = AnnotationToolbar(
            activeTool: Binding(get: { [weak self] in self?.activeTool ?? .arrow },
                                set: { [weak self] in
                                    self?.activeTool = $0
                                    self?.canvasView?.activeTool = $0
                                }),
            activeColor: Binding(get: { [weak self] in self?.activeColor ?? .red },
                                 set: { [weak self] in
                                     self?.activeColor = $0
                                     self?.canvasView?.activeColor = $0
                                 }),
            lineWidth: Binding(get: { [weak self] in self?.lineWidth ?? 3.0 },
                               set: { [weak self] in
                                   self?.lineWidth = $0
                                   self?.canvasView?.lineWidth = $0
                               }),
            onUndo: { [weak self] in self?.undo() },
            onRedo: { [weak self] in self?.redo() },
            onEyedropper: { [weak self] in self?.canvasView?.activateEyedropper() },
            onSave: { [weak self] in self?.save() },
            canUndo: !shapes.isEmpty,
            canRedo: !undoneShapes.isEmpty
        )
        let hostingView = NSHostingView(rootView: toolbar)
        hostingView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        toolbarHostingView = hostingView
        return hostingView
    }

    private func updateToolbar() {
        // Recreate the toolbar with updated state
        guard let hosting = toolbarHostingView else { return }
        let toolbar = AnnotationToolbar(
            activeTool: Binding(get: { [weak self] in self?.activeTool ?? .arrow },
                                set: { [weak self] in
                                    self?.activeTool = $0
                                    self?.canvasView?.activeTool = $0
                                }),
            activeColor: Binding(get: { [weak self] in self?.activeColor ?? .red },
                                 set: { [weak self] in
                                     self?.activeColor = $0
                                     self?.canvasView?.activeColor = $0
                                 }),
            lineWidth: Binding(get: { [weak self] in self?.lineWidth ?? 3.0 },
                               set: { [weak self] in
                                   self?.lineWidth = $0
                                   self?.canvasView?.lineWidth = $0
                               }),
            onUndo: { [weak self] in self?.undo() },
            onRedo: { [weak self] in self?.redo() },
            onEyedropper: { [weak self] in self?.canvasView?.activateEyedropper() },
            onSave: { [weak self] in self?.save() },
            canUndo: !shapes.isEmpty,
            canRedo: !undoneShapes.isEmpty
        )
        hosting.rootView = toolbar
    }
}
