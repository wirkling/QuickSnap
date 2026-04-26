import SwiftUI

struct HistoryGridView: View {
    @EnvironmentObject var screenshotManager: ScreenshotManager
    @Binding var selectedItemID: UUID?
    @State private var filter: HistoryFilter = .all

    enum HistoryFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case stacks = "Stacks"
        case recordings = "Recordings"
        var id: String { rawValue }
    }

    private var filteredHistory: [ScreenshotItem] {
        switch filter {
        case .all: return screenshotManager.history
        case .stacks: return screenshotManager.history.filter { $0.isStack }
        case .recordings: return screenshotManager.history.filter { $0.isBurst }
        }
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 5)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Text("Recent")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("\(filteredHistory.count)")
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                FilterSegment(selection: $filter)
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)

            if filteredHistory.isEmpty {
                Text(emptyMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else {
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(filteredHistory.prefix(10)) { item in
                        HistoryGridCell(
                            item: item,
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
                            }
                        )
                    }
                }
                .padding(.horizontal, 12)
            }
        }
    }

    private var emptyMessage: String {
        switch filter {
        case .all: return "No captures yet"
        case .stacks: return "No stacks yet"
        case .recordings: return "No recordings yet"
        }
    }
}

// MARK: - Filter segmented control

private struct FilterSegment: View {
    @Binding var selection: HistoryGridView.HistoryFilter

    var body: some View {
        HStack(spacing: 2) {
            ForEach(HistoryGridView.HistoryFilter.allCases) { option in
                Button {
                    selection = option
                } label: {
                    Text(option.rawValue)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(selection == option ? .primary : .secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(selection == option ? Color.white.opacity(0.9) : .clear)
                                .shadow(color: .black.opacity(selection == option ? 0.05 : 0), radius: 1, y: 0.5)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.primary.opacity(0.05))
        )
    }
}

// MARK: - Grid cell

private struct HistoryGridCell: View {
    let item: ScreenshotItem
    let isSelected: Bool
    let onTap: () -> Void
    let onDoubleTap: () -> Void
    @State private var isHovered = false

    private var dragURL: URL {
        item.pdfURL ?? item.fileURL
    }

    private var typeBadge: (icon: String, tint: Color)? {
        if item.isBurst { return ("record.circle.fill", .red) }
        if item.isStack { return ("doc.on.doc.fill", .blue) }
        return nil
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Image(nsImage: item.thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity)
                .aspectRatio(4.0/3.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(
                            isSelected ? Color.accentColor : Color.primary.opacity(isHovered ? 0.12 : 0.06),
                            lineWidth: isSelected ? 2 : 0.5
                        )
                )
                .shadow(color: .black.opacity(isSelected ? 0.18 : 0), radius: 3, y: 1)

            if let badge = typeBadge {
                Image(systemName: badge.icon)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(3)
                    .background(Circle().fill(badge.tint.opacity(0.9)))
                    .padding(3)
            }

            VStack {
                Spacer()
                HStack {
                    Text(timeBadge)
                        .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1.5)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.black.opacity(0.55))
                        )
                    Spacer()
                    if item.isStack, let count = item.stackPageURLs?.count, count > 0 {
                        Text("\(count)")
                            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1.5)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.black.opacity(0.55))
                            )
                    } else if item.isBurst, let count = item.burstImageURLs?.count, count > 0 {
                        Text("\(count)")
                            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1.5)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.black.opacity(0.55))
                            )
                    }
                }
                .padding(3)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onDoubleTap() }
        .onTapGesture(count: 1) { onTap() }
        .onHover { isHovered = $0 }
        .draggable(dragURL) {
            Image(nsImage: item.thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 80, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .opacity(0.85)
        }
        .help(item.displayName)
    }

    private var timeBadge: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "h:mma"
        fmt.amSymbol = "a"
        fmt.pmSymbol = "p"
        return fmt.string(from: item.createdAt).lowercased()
    }
}
