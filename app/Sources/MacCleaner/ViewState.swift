import SwiftUI

/// Write `@ViewState` where SwiftUI code says `@State`.
///
/// In the macOS 27 SDK `@State` resolves to a macro whose plugin (SwiftUIMacros) ships only with Xcode, so it
/// doesn't build with the Command Line Tools. This alias names the same `State` property wrapper (same type,
/// same behaviour) and bypasses the macro. No other SwiftUI attribute this app uses is affected.
typealias ViewState = SwiftUI.State
