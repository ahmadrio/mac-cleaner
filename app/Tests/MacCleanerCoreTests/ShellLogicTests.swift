import Testing
@testable import MacCleanerCore

@Test func confirmWordIsExact() {
    #expect(ConfirmWord.matches(typed: "DELETE", required: "DELETE"))
    #expect(ConfirmWord.matches(typed: "HAPUS", required: "HAPUS"))
    #expect(ConfirmWord.matches(typed: "RESET", required: "RESET"))
}

@Test func confirmWordIsCaseSensitiveAndUntrimmed() {
    #expect(!ConfirmWord.matches(typed: "delete", required: "DELETE"))
    #expect(!ConfirmWord.matches(typed: "Reset", required: "RESET"))
    #expect(!ConfirmWord.matches(typed: "RESET ", required: "RESET"))
    #expect(!ConfirmWord.matches(typed: " RESET", required: "RESET"))
    #expect(!ConfirmWord.matches(typed: "RESET\n", required: "RESET"))
    #expect(!ConfirmWord.matches(typed: "RESE", required: "RESET"))
    #expect(!ConfirmWord.matches(typed: "", required: "RESET"))
    #expect(!ConfirmWord.matches(typed: "DELETE", required: "HAPUS"))
}

@Test func uiLanguageMapsLikeTheScript() {
    for code in ["id", "id-ID", "id_ID", "ID", "in", "in-ID", "in_ID", "indonesian", "Indonesia"] {
        #expect(UILanguage.normalize(code) == "id", "\(code)")
    }
    for code in ["en", "en-US", "en-ID", "inh", "nl-ID", "", "fr"] {
        #expect(UILanguage.normalize(code) == "en", "\(code)")
    }
}

@Test func uiLanguageSavedChoiceWins() {
    #expect(UILanguage.initial(saved: "en\n", preferred: ["id-ID"]) == "en")
    #expect(UILanguage.initial(saved: "id\n", preferred: ["en-US"]) == "id")
    #expect(UILanguage.initial(saved: " id ", preferred: []) == "id")
}

@Test func uiLanguageFallsBackToMacOSThenEnglish() {
    #expect(UILanguage.initial(saved: nil, preferred: ["id-ID", "en-US"]) == "id")
    #expect(UILanguage.initial(saved: "\n", preferred: ["in-ID"]) == "id")
    #expect(UILanguage.initial(saved: nil, preferred: ["en-GB", "id-ID"]) == "en")
    #expect(UILanguage.initial(saved: nil, preferred: []) == "en")
}
