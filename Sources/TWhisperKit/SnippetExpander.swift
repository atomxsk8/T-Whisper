import Foundation

/// Matches a whole spoken utterance against saved voice snippets and returns the exact
/// replacement text, entirely locally — the replacement body is never sent to Groq. Only
/// whole-utterance matches count: a trigger never matches as a substring within a longer
/// sentence.
enum SnippetExpander {
    private static let trailingPunctuation: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]
    private static let posix = Locale(identifier: "en_US_POSIX")

    /// Trims surrounding whitespace, strips trailing sentence punctuation, collapses internal
    /// whitespace to single spaces, and lowercases with a fixed POSIX locale. Never strips
    /// accents or alters internal punctuation.
    static func normalizedTrigger(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = trimmed.last, trailingPunctuation.contains(last) {
            trimmed.removeLast()
            trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let collapsed = trimmed
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return collapsed.lowercased(with: posix)
    }

    /// Returns the saved replacement when `transcript`, taken as a whole utterance, matches
    /// exactly one snippet's trigger. Returns `nil` for no match, an empty snippet list, or an
    /// ambiguous match against more than one snippet (which never happens for snippets saved
    /// through `AppModel.saveSnippet`, but is guarded here defensively).
    static func expansion(for transcript: String, snippets: [VoiceSnippet]) -> String? {
        guard !snippets.isEmpty else { return nil }
        let key = normalizedTrigger(transcript)
        guard !key.isEmpty else { return nil }
        let matches = snippets.filter { normalizedTrigger($0.trigger) == key }
        guard matches.count == 1 else { return nil }
        return matches[0].replacement
    }
}
