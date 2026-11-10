import MacCleanerCore
import SwiftUI

/// Placeholder: Task 13 builds the Rarely used apps screen on `job` (`AppState.apps`).
struct AppsView: View {
    @ObservedObject var job: JobModel

    var body: some View {
        VStack(alignment: .leading) {
            Text(Screen.apps.title).font(.title2.weight(.semibold))
            EmptyState(symbol: Screen.apps.symbol,
                       text: L("Layar ini belum tersedia.", "This screen isn't available yet."))
        }
        .padding(20)
    }
}
