import MacCleanerCore
import SwiftUI

/// Placeholder: Task 13 builds the Uninstall screen on `job` (`AppState.uninstall`).
struct UninstallView: View {
    @ObservedObject var job: JobModel

    var body: some View {
        VStack(alignment: .leading) {
            Text(Screen.uninstall.title).font(.title2.weight(.semibold))
            EmptyState(symbol: Screen.uninstall.symbol,
                       text: L("Layar ini belum tersedia.", "This screen isn't available yet."))
        }
        .padding(20)
    }
}
