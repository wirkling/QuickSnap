import SwiftUI

struct HistoryGridView: View {
    @EnvironmentObject var screenshotManager: ScreenshotManager
    @Binding var selectedItemID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Recent")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(screenshotManager.history.count)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            if screenshotManager.history.isEmpty {
                Text("No captures yet")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 16)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(screenshotManager.history.prefix(20)) { item in
                            HistoryThumbnailView(
                                image: item.thumbnail,
                                fileURL: item.pdfURL ?? item.fileURL,
                                isSelected: selectedItemID == item.id,
                                onTap: {
                                    if selectedItemID == item.id {
                                        selectedItemID = nil
                                    } else {
                                        selectedItemID = item.id
                                    }
                                },
                                onDoubleTap: {
                                    screenshotManager.pin(item)
                                },
                                isStack: item.isStack
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 2)
                }
            }
        }
    }
}
