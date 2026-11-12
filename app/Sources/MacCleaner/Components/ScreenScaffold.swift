import SwiftUI

/// Every screen's frame: `header` (the ScanBar…) stays at the top, `footer` (result banners, the log) at the bottom,
/// and `content` scrolls between them once the window is too short for it. Without the scroll area a screen taller
/// than the window was squeezed: its tables shrank to nothing and the overflow was cut off at the top and bottom.
struct ScreenScaffold<Header: View, Content: View, Footer: View>: View {
    private let header: Header
    private let content: Content
    private let footer: Footer

    init(@ViewBuilder header: () -> Header, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.header = header()
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            GeometryReader { viewport in
                ScrollView {
                    AtLeastViewport(height: viewport.size.height) {
                        VStack(alignment: .leading, spacing: 12) { content }
                            .padding(.horizontal, 20)
                    }
                }
            }
            .padding(.horizontal, -20)  // the scroll area runs to the window's edges, so its scroller sits there
            .layoutPriority(1)          // it gets the room first; the log in the footer keeps its minimum height
            footer
        }
        .padding(20)
    }
}

/// The scroll area's content: proposed the viewport's height, so a table or an empty state fills a window that is
/// tall enough, and as tall as the content needs when that is more, which is what the ScrollView then scrolls.
/// (A frame with the viewport's ideal height stays at that height whatever its content needs, and cuts the rest off.)
private struct AtLeastViewport: Layout {
    let height: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let size = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: height))
        return CGSize(width: proposal.width ?? size.width, height: max(height, size.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

extension ScreenScaffold where Footer == EmptyView {
    init(@ViewBuilder header: () -> Header, @ViewBuilder content: () -> Content) {
        self.init(header: header, content: content, footer: { EmptyView() })
    }
}

extension View {
    /// A screen's main table. In the scroll area a Table has no height of its own: it gets this minimum and grows
    /// into whatever room the window has left.
    func screenTable() -> some View { frame(minHeight: 160) }
}
