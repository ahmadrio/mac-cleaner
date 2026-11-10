/// The UI text in the current language, like `L "Indonesia" "English"` in mac-cleaner.command.
///
/// Every user-facing string goes through `L`, except names that read the same in both languages
/// ("Mac Cleaner", "Docker", "RAM", "Disk", "OK") and the language names in the language menu.
/// Views don't need to observe the language: RootView rebuilds the window content when it changes.
@MainActor func L(_ id: String, _ en: String) -> String {
    AppState.shared.lang == "id" ? id : en
}
