/// What a screen shows for its job, decided in one place so every screen behaves the same.
///
/// Screens switch on `job.screenContent` and nothing else:
/// - `.idle`: nothing scanned yet (or the scan was cancelled): show a "press Scan" prompt;
/// - `.scanning`: a scan is running: show a progress message, never rows (they may be incomplete);
/// - `.empty`: the scan finished and found nothing: show the empty state;
/// - `.failed(message)`: the scan failed: show no list (`ScanBar` shows the message, with "Try again");
/// - `.list`: show the rows and their controls. This includes an action running over the list, or
///   having failed: disable the action controls with `job.isBusy`, and keep the list.
public enum ScreenContent: Equatable, Sendable {
    case idle, scanning, empty, failed(String), list

    @MainActor public init(_ job: JobModel) {
        if job.phase == .scanning {
            self = .scanning
        } else if job.scanFailed, case .failed(let message) = job.phase {
            self = .failed(message)
        } else if !job.rows.isEmpty {
            self = .list
        } else {
            self = job.phase == .done ? .empty : .idle
        }
    }
}

extension JobModel {
    public var screenContent: ScreenContent { ScreenContent(self) }
}
