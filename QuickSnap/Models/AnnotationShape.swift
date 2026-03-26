import AppKit
import Foundation

/// Represents a single annotation drawn on top of a screenshot.
enum AnnotationTool: String, CaseIterable, Identifiable {
    case arrow
    case rectangle
    case text
    case redact

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .text: return "textformat"
        case .redact: return "eye.slash"
        }
    }

    var label: String {
        switch self {
        case .arrow: return "Arrow"
        case .rectangle: return "Rectangle"
        case .text: return "Text"
        case .redact: return "Redact"
        }
    }
}

struct AnnotationShape: Identifiable {
    let id = UUID()
    let tool: AnnotationTool
    var startPoint: CGPoint
    var endPoint: CGPoint
    var color: NSColor
    var lineWidth: CGFloat
    var text: String? // Only for text tool

    var rect: CGRect {
        CGRect(
            x: min(startPoint.x, endPoint.x),
            y: min(startPoint.y, endPoint.y),
            width: abs(endPoint.x - startPoint.x),
            height: abs(endPoint.y - startPoint.y)
        )
    }
}
