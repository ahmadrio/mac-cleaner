import MacCleanerCore
import SwiftUI

/// Placeholder: Task 11 builds the Clean caches screen on `job` (`AppState.cache`).
struct CacheView: View {
    @ObservedObject var job: JobModel

    var body: some View {
        VStack(alignment: .leading) {
            Text(Screen.cache.title).font(.title2.weight(.semibold))
            EmptyState(symbol: Screen.cache.symbol,
                       text: L("Layar ini belum tersedia.", "This screen isn't available yet."))
        }
        .padding(20)
    }
}
