import MacCleanerCore
import SwiftUI

/// Placeholder: Task 12 builds the RAM screen on `job` (`AppState.ram`).
struct RAMView: View {
    @ObservedObject var job: JobModel

    var body: some View {
        VStack(alignment: .leading) {
            Text(Screen.ram.title).font(.title2.weight(.semibold))
            EmptyState(symbol: Screen.ram.symbol,
                       text: L("Layar ini belum tersedia.", "This screen isn't available yet."))
        }
        .padding(20)
    }
}
