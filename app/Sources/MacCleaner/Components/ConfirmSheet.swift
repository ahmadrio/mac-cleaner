import MacCleanerCore
import SwiftUI

/// The confirmation every destructive action goes through: what will happen, the items, an optional
/// warning, and for the riskiest actions a word to type (`L("HAPUS","DELETE")`, `RESET`) before confirming.
/// Present it with `.sheet`; it dismisses itself, then calls `onConfirm`.
struct ConfirmSheet: View {
    let title: String
    let items: [String]
    let warning: String?
    /// Extra content under the warning, e.g. a permission callout. None by default.
    var accessory: AnyView? = nil
    let typedWord: String?
    let confirmLabel: String
    let onConfirm: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @ViewState private var typed = ""

    private static let rowHeight: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            if !items.isEmpty { itemList }
            if let warning {
                Label {
                    Text(warning)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            if let accessory { accessory }
            if let typedWord {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Ketik \(typedWord) untuk lanjut:", "Type \(typedWord) to continue:"))
                    TextField(typedWord, text: $typed)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        .onSubmit { if canConfirm { confirm() } }
                }
            }
            HStack {
                Spacer()
                Button(L("Batal", "Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                // No .defaultAction: Return must never confirm a destructive action. Esc still cancels.
                Button(confirmLabel) { confirm() }
                    .disabled(!canConfirm)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var itemList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Text(item)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(item)
                        .frame(maxWidth: .infinity, minHeight: Self.rowHeight, maxHeight: Self.rowHeight, alignment: .leading)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .frame(height: min(CGFloat(items.count) * Self.rowHeight + 12, 260))
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
    }

    private var canConfirm: Bool {
        typedWord.map { ConfirmWord.matches(typed: typed, required: $0) } ?? true
    }

    private func confirm() {
        dismiss()
        Task { await onConfirm() }  // not tied to the sheet: an action always runs to its end
    }
}
