import MacCleanerCore
import SwiftUI

/// Placeholder: Task 11 builds the Largest folders screen on `job` (`AppState.folders`).
struct FoldersView: View {
    @ObservedObject var job: JobModel

    var body: some View {
        VStack(alignment: .leading) {
            Text(Screen.folders.title).font(.title2.weight(.semibold))
            EmptyState(symbol: Screen.folders.symbol,
                       text: L("Layar ini belum tersedia.", "This screen isn't available yet."))
        }
        .padding(20)
    }
}
