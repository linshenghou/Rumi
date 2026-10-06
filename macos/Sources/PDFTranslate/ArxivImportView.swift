import SwiftUI

struct ArxivImportView: View {
    @ObservedObject var model: AppModel
    @State private var link = ""
    @FocusState private var linkFocused: Bool

    private var canSubmit: Bool {
        !model.linkImportBusy && !link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var progress: Double? {
        guard let value = model.linkImportProgress, value.isFinite else { return nil }
        return min(1, max(0, value))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Add from Link").font(.title3.weight(.semibold))
                Text("Paste an arXiv link to download a paper for reading or translation.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Paper Link").font(.callout)
                TextField("https://arxiv.org/pdf/2511.07820", text: $link)
                    .textFieldStyle(.roundedBorder)
                    .focused($linkFocused)
                    .disabled(model.linkImportBusy)
                    .onSubmit { submit(translate: true) }
                    .accessibilityLabel("arXiv Paper Link")
                    .accessibilityHint("Enter an arXiv abstract or PDF link.")
                Text("Supports arxiv.org /abs/ and /pdf/ links.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if model.linkImportBusy {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(model.linkImportMessage ?? L10n.text("Downloading paper…"))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        if let progress {
                            Text(L10n.format("%d%%", Int((progress * 100).rounded())))
                                .monospacedDigit()
                        }
                    }.font(.caption).foregroundStyle(.secondary)
                    if let progress {
                        ProgressView(value: progress, total: 1)
                            .accessibilityLabel("Download Progress")
                            .accessibilityValue(L10n.format("%d%%", Int((progress * 100).rounded())))
                    } else {
                        ProgressView().progressViewStyle(.linear)
                            .accessibilityLabel("Downloading Paper")
                    }
                }
            }

            if let error = model.linkImportError {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            HStack(spacing: 12) {
                Button("Cancel", action: model.cancelLinkImport)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityHint(L10n.text(model.linkImportBusy ? "Stop downloading and close this window." : "Close the link import window."))
                Spacer()
                Button("Download Only") { submit(translate: false) }
                    .disabled(!canSubmit)
                    .accessibilityHint("Download the paper and open it for reading.")
                Button("Download & Translate") { submit(translate: true) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
                    .accessibilityHint("Download the paper and translate it using your current settings.")
            }
        }
        .padding(24)
        .frame(width: 500)
        .interactiveDismissDisabled(model.linkImportBusy)
        .onAppear { DispatchQueue.main.async { linkFocused = true } }
        .onExitCommand(perform: model.cancelLinkImport)
        .onDisappear {
            if model.linkImportBusy { model.cancelLinkImport() }
        }
    }

    private func submit(translate: Bool) {
        guard canSubmit else { return }
        model.importArxiv(link.trimmingCharacters(in: .whitespacesAndNewlines), translate: translate)
    }
}
