import SwiftUI
import AppKit

/// A thumbnail image that can be dragged out of the menu bar into Finder, chat apps, etc.
struct DraggableThumbnailView: View {
    let image: NSImage
    let fileURL: URL
    let size: CGSize
    var burstImageURLs: [URL]? = nil

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .shadow(radius: 2)
            .overlay(
                Group {
                    if let burstURLs = burstImageURLs, !burstURLs.isEmpty {
                        Text("\(burstURLs.count)")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.red.opacity(0.85))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .padding(4)
                    }
                },
                alignment: .topTrailing
            )
            .draggable(fileURL) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 80, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .opacity(0.8)
            }
            .help(burstImageURLs != nil ? "Drag to share — burst folder" : "Drag to share — \(fileURL.lastPathComponent)")
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

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: 52, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
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
