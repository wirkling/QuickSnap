import SwiftUI

struct AnnotationToolbar: View {
    @Binding var activeTool: AnnotationTool
    @Binding var activeColor: NSColor
    @Binding var lineWidth: CGFloat
    let onUndo: () -> Void
    let onRedo: () -> Void
    let onEyedropper: () -> Void
    let onSave: () -> Void
    let canUndo: Bool
    let canRedo: Bool

    private let colors: [NSColor] = [.red, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple, .white, .black]

    var body: some View {
        HStack(spacing: 8) {
            toolsGroup
            separator
            colorsGroup
            separator
            lineWidthGroup
            separator
            historyGroup
            Spacer(minLength: 8)
            saveButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.separator.opacity(0.4))
                .frame(height: 0.5)
        }
    }

    // MARK: - Tools

    private var toolsGroup: some View {
        HStack(spacing: 2) {
            ForEach(AnnotationTool.allCases) { tool in
                toolButton(tool)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(.quaternary.opacity(0.5))
        )
    }

    private func toolButton(_ tool: AnnotationTool) -> some View {
        let isActive = activeTool == tool
        return Button {
            activeTool = tool
        } label: {
            Image(systemName: tool.icon)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 32, height: 28)
                .foregroundStyle(isActive ? Color.white : Color.primary.opacity(0.75))
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isActive ? Color.accentColor : Color.clear)
                        .shadow(color: isActive ? .black.opacity(0.15) : .clear, radius: 2, y: 1)
                )
        }
        .buttonStyle(.plain)
        .help(tool.label)
    }

    // MARK: - Colors

    private var colorsGroup: some View {
        HStack(spacing: 6) {
            ForEach(colors, id: \.self) { color in
                colorSwatch(color)
            }
            Button(action: onEyedropper) {
                Image(systemName: "eyedropper")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .foregroundStyle(.primary.opacity(0.75))
                    .background(
                        Circle().fill(.quaternary.opacity(0.5))
                    )
            }
            .buttonStyle(.plain)
            .help("Pick color from image")
        }
    }

    private func colorSwatch(_ color: NSColor) -> some View {
        let isActive = activeColor == color
        return Button {
            activeColor = color
        } label: {
            ZStack {
                Circle()
                    .fill(Color(nsColor: color))
                    .frame(width: 18, height: 18)
                    .overlay(
                        Circle().strokeBorder(.primary.opacity(0.2), lineWidth: 0.5)
                    )
                if isActive {
                    Circle()
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .frame(width: 24, height: 24)
                }
            }
            .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Line width

    private var lineWidthGroup: some View {
        HStack(spacing: 6) {
            Image(systemName: "lineweight")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Slider(value: $lineWidth, in: 1...8, step: 1)
                .frame(width: 72)
                .controlSize(.mini)
            Text("\(Int(lineWidth))")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 12)
        }
    }

    // MARK: - History

    private var historyGroup: some View {
        HStack(spacing: 2) {
            glyphButton("arrow.uturn.backward", help: "Undo", enabled: canUndo, action: onUndo)
            glyphButton("arrow.uturn.forward", help: "Redo", enabled: canRedo, action: onRedo)
        }
    }

    private func glyphButton(_ icon: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(enabled ? Color.primary.opacity(0.75) : Color.primary.opacity(0.25))
                .frame(width: 28, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.quaternary.opacity(enabled ? 0.5 : 0.2))
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }

    // MARK: - Save

    private var saveButton: some View {
        Button(action: onSave) {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                Text("Save")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor)
                    .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
            )
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.return, modifiers: .command)
    }

    // MARK: - Shared

    private var separator: some View {
        Rectangle()
            .fill(.separator.opacity(0.5))
            .frame(width: 1, height: 22)
            .padding(.horizontal, 2)
    }
}
