import SwiftUI

struct HistoryGridView: View {
    @EnvironmentObject var screenshotManager: ScreenshotManager
    @Binding var selectedItem: ScreenshotItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Recent")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(screenshotManager.history.count)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            if screenshotManager.history.isEmpty {
                Text("No captures yet")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(screenshotManager.history.prefix(20)) { item in
                            HistoryThumbnailView(
                                image: item.thumbnail,
                                fileURL: item.fileURL,
                                isSelected: selectedItem?.id == item.id,
                                onTap: {
                                    if selectedItem?.id == item.id {
                                        selectedItem = nil
                                    } else {
                                        selectedItem = item
                                    }
                                },
                                onDoubleTap: {
                                    screenshotManager.pin(item)
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 2)
                }
            }
        }
    }
}
