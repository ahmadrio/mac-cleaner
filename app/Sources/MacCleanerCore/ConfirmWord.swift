/// The typed confirmation of the riskiest actions, like `confirm_word` in mac-cleaner.command:
/// the word must match exactly (case-sensitive, nothing trimmed).
public enum ConfirmWord {
    public static func matches(typed: String, required: String) -> Bool { typed == required }
}
