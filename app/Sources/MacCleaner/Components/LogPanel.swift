import MacCleanerCore
import SwiftUI

/// The job's log, following new lines as they stream in. Shows nothing while the log is empty.
struct LogPanel: View {
    @ObservedObject var job: JobModel

    var body: some View {
        if !job.log.isEmpty {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(job.log) { line in
                            row(line).id(line.id)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onAppear { scrollToEnd(proxy) }
                .onChange(of: job.log.last?.id) { _ in scrollToEnd(proxy) }
            }
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .frame(minHeight: 90, idealHeight: 160, maxHeight: 220)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        if let last = job.log.last?.id { proxy.scrollTo(last, anchor: .bottom) }
    }

    /// The CLI's marks: › info, ✓ ok, ! warn, ✗ err; raw tool output and stderr are dimmed.
    private func row(_ line: LogLine) -> some View {
        let (mark, color): (String, Color) = switch line.level {
        case .info: ("›", .blue)
        case .ok: ("✓", .green)
        case .warn: ("!", .orange)
        case .err: ("✗", .red)
        case .say, nil: ("", .clear)
        }
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: mark).foregroundStyle(color).frame(width: 12)
            Text(line.text).foregroundStyle(line.level == nil ? .secondary : .primary)
        }
    }
}
