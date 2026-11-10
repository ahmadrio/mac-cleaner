import MacCleanerCore
import SwiftUI

/// The job's log, following new lines as they stream in. Shows nothing while the log is empty.
///
/// `maxLines` shows only the last lines (and says how many earlier ones are hidden), for jobs whose tools print
/// thousands of lines: the panel re-lays out on every new line, so a long log would make it sluggish.
struct LogPanel: View {
    @ObservedObject var job: JobModel
    var maxLines: Int?

    var body: some View {
        if !job.log.isEmpty {
            let tail = LogTail(job.log, limit: maxLines ?? job.log.count)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if tail.hidden > 0 {
                            Text(L("… \(tail.hidden) baris sebelumnya disembunyikan", "… \(tail.hidden) earlier lines hidden"))
                                .foregroundStyle(.secondary)
                        }
                        ForEach(tail.lines) { line in
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
