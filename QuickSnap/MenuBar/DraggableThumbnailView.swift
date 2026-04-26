import SwiftUI
import AppKit

/// A thumbnail image that can be dragged out of the menu bar into Finder, chat apps, etc.
struct DraggableThumbnailView: View {
    let image: NSImage
    let fileURL: URL
    let size: CGSize
    var burstImageURLs: [URL]? = nil
    var isStack: Bool = false
    var stackPageCount: Int = 0
    var pdfURL: URL? = nil

    /// The URL to use for drag-and-drop — PDF for stacks, fileURL otherwise.
    private var dragURL: URL { pdfURL ?? fileURL }

    var body: some View {
        ZStack {
            // Layered stack effect for stack items
            if isStack && stackPageCount > 1 {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.06))
                    .frame(width: size.width - 4, height: size.height - 4)
                    .offset(x: 4, y: -4)
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.1))
                    .frame(width: size.width - 2, height: size.height - 2)
                    .offset(x: 2, y: -2)
            }

            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .shadow(radius: 2)
        }
        .overlay(
            Group {
                if let burstURLs = burstImageURLs, !burstURLs.isEmpty {
                    badgeView(text: "\(burstURLs.count)", color: .red)
                } else if isStack && stackPageCount > 0 {
                    badgeView(text: "\(stackPageCount)", icon: "doc.on.doc", color: .blue)
                }
            },
            alignment: .topTrailing
        )
        .draggable(dragURL) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 80, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .opacity(0.8)
        }
        .help(isStack ? "Drag to share — PDF stack" : burstImageURLs != nil ? "Drag to share — burst folder" : "Drag to share — \(fileURL.lastPathComponent)")
    }

    private func badgeView(text: String, icon: String? = nil, color: Color) -> some View {
        HStack(spacing: 2) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 8, weight: .bold))
            }
            Text(text)
                .font(.caption2.bold())
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(color.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .padding(4)
    }
}

/// A smaller draggable thumbnail for the history grid.
/// Single tap: select (shows action bar). Double tap: enlarge in floating preview.
struct HistoryThumbnailView: View {
    let image: NSImage
    let fileURL: URL
    let isSelected: Bool
    let onTap: () -> Void
    var onDoubleTap: (() -> Void)? = nil
    var isStack: Bool = false

    var body: some View {
        ZStack {
            if isStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: 56, height: 42)
                    .offset(x: 2, y: -2)
            }

            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 60, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
                )
        }
        .draggable(fileURL) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 60, height: 45)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .opacity(0.8)
        }
        .onTapGesture(count: 2) {
            onDoubleTap?()
        }
        .onTapGesture(count: 1, perform: onTap)
    }
}

// Extension to create NSImage from thumbnail Data
extension ScreenshotRecord {
    var thumbnailImage: NSImage? {
        guard let data = thumbnailData else { return nil }
        return NSImage(data: data)
    }
}
