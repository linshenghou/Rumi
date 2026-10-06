import SwiftUI

/// A persistent import affordance; file handling stays on the containing window.
struct PDFImportCard: View {
    var compact = false
    var isTargeted = false
    let action: () -> Void
    var linkAction: (() -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hovering = false

    private var highlighted: Bool { isTargeted || hovering }

    var body: some View {
        VStack(spacing: compact ? 9 : 12) {
            fileButton
            if let linkAction {
                Button("Add from Link…", action: linkAction)
                    .buttonStyle(.link)
                    .font(compact ? .caption : .callout)
                    .help("Add an arXiv paper from a link (⌘⇧O)")
                    .accessibilityLabel("Add Paper from Link")
            }
        }
    }

    private var fileButton: some View {
        Button(action: action) {
            Group {
                if compact {
                    HStack(spacing: 12) {
                        documentIcon(size: 36)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(L10n.text(isTargeted ? "Release to Add" : "Add PDF"))
                                .font(.system(size: 13, weight: .medium))
                            Text("or drop a PDF or folder")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }.padding(14)
                } else {
                    VStack(spacing: 17) {
                        documentIcon(size: 66).padding(.top, 4)
                        VStack(spacing: 7) {
                            Text(L10n.text(isTargeted ? "Release to Add PDF" : "Drop a PDF here"))
                                .font(.system(size: 17, weight: .medium))
                            Text("or click to choose a paper").font(.callout).foregroundStyle(.secondary)
                        }
                        Text("PDF or folder  ·  ⌘O")
                            .font(.caption).foregroundStyle(.secondary).padding(.top, 2)
                    }.frame(maxWidth: .infinity).padding(.vertical, 28).padding(.horizontal, 24)
                }
            }
            .foregroundStyle(.primary)
            .background {
                RoundedRectangle(cornerRadius: compact ? 16 : 24, style: .continuous)
                    .fill(reduceTransparency ? AnyShapeStyle(.background) : AnyShapeStyle(.thinMaterial))
                RoundedRectangle(cornerRadius: compact ? 16 : 24, style: .continuous)
                    .fill(Color.accentColor.opacity(highlighted ? 0.10 : 0.025))
            }
            .overlay {
                RoundedRectangle(cornerRadius: compact ? 16 : 24, style: .continuous)
                    .strokeBorder(highlighted ? Color.accentColor.opacity(0.7) : Color.primary.opacity(contrast == .increased ? 0.45 : 0.12),
                                  style: StrokeStyle(lineWidth: highlighted ? 1.5 : 1, dash: highlighted ? [] : [5, 4]))
            }
            .contentShape(RoundedRectangle(cornerRadius: compact ? 16 : 24, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: highlighted)
        .accessibilityLabel("Add PDF")
        .accessibilityHint("Choose a PDF or folder, or drag files into the window.")
        .help("Add PDF or Folder (⌘O)")
    }

    private func documentIcon(size: CGFloat) -> some View {
        Image(systemName: isTargeted ? "arrow.down.doc" : "doc.badge.plus")
            .font(.system(size: size * 0.66, weight: .light))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(Color.accentColor)
            .frame(width: size, height: size)
            .scaleEffect(highlighted && !reduceMotion ? 1.035 : 1)
            .accessibilityHidden(true)
    }
}
