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

    private let colors: [NSColor] = [.red, .yellow, .green, .blue, .white, .black]

    var body: some View {
        HStack(spacing: 10) {
            // Tools
            ForEach(AnnotationTool.allCases) { tool in
                Button(action: { activeTool = tool }) {
                    VStack(spacing: 2) {
                        Image(systemName: tool.icon)
                            .font(.system(size: 14))
                        Text(tool.label)
                            .font(.system(size: 8))
                    }
                    .frame(width: 40, height: 34)
                    .background(activeTool == tool ? Color.accentColor.opacity(0.3) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }

            Divider()
                .frame(height: 28)

            // Colors
            ForEach(colors, id: \.self) { color in
                Circle()
                    .fill(Color(nsColor: color))
                    .frame(width: 18, height: 18)
                    .overlay(
                        Circle()
                            .stroke(activeColor == color ? Color.white : Color.clear, lineWidth: 2)
                    )
                    .overlay(
                        Circle()
                            .stroke(Color.gray.opacity(0.3), lineWidth: 0.5)
                    )
                    .onTapGesture { activeColor = color }
            }

            // Eyedropper
            Button(action: onEyedropper) {
                Image(systemName: "eyedropper")
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)

            Divider()
                .frame(height: 28)

            // Line width
            Slider(value: $lineWidth, in: 1...8, step: 1)
                .frame(width: 60)

            Divider()
                .frame(height: 28)

            // Undo/Redo
            Button(action: onUndo) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .disabled(!canUndo)

            Button(action: onRedo) {
                Image(systemName: "arrow.uturn.forward")
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .disabled(!canRedo)

            Spacer()

            // Save
            Button(action: onSave) {
                Label("Save", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial)
    }
}
