import MacCleanerCore
import SwiftUI

/// Placeholder: Task 15 builds the Updates screen on `job` (`AppState.updates`).
struct UpdatesView: View {
    @ObservedObject var job: JobModel

    var body: some View {
        VStack(alignment: .leading) {
            Text(Screen.updates.title).font(.title2.weight(.semibold))
            EmptyState(symbol: Screen.updates.symbol,
                       text: L("Layar ini belum tersedia.", "This screen isn't available yet."))
        }
        .padding(20)
    }
}
