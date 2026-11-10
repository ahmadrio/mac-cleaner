import MacCleanerCore
import SwiftUI

/// The coloured cache kind label: green safe, orange heavy (slow to rebuild), red permanent (can't be undone).
struct KindBadge: View {
    let kind: CacheKind

    var body: some View {
        Text(label)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
    }

    private var label: String {
        switch kind {
        case .safe: L("aman", "safe")
        case .heavy: L("berat", "heavy")
        case .permanent: L("permanen", "permanent")
        }
    }

    private var color: Color {
        switch kind {
        case .safe: .green
        case .heavy: .orange
        case .permanent: .red
        }
    }
}
