import MacCleanerCore
import SwiftUI

/// Placeholder: Task 14 builds the Docker screen on `job` (`AppState.docker`).
struct DockerView: View {
    @ObservedObject var job: JobModel

    var body: some View {
        VStack(alignment: .leading) {
            Text(Screen.docker.title).font(.title2.weight(.semibold))
            EmptyState(symbol: Screen.docker.symbol,
                       text: L("Layar ini belum tersedia.", "This screen isn't available yet."))
        }
        .padding(20)
    }
}
