import Foundation

/// The note about what a photo (or a series) should feel like — written down before choosing a
/// harmony, so the harmony serves the intention and not the other way round.
public enum Intention {
    /// Words offered as one-click moods.
    public static let moods = ["warm", "cool", "calm", "energetic", "dramatic", "nostalgic", "fresh", "moody", "soft"]

    /// The comma-separated words of the note, trimmed.
    public static func words(in text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    public static func contains(_ word: String, in text: String) -> Bool {
        words(in: text).contains { $0.caseInsensitiveCompare(word) == .orderedSame }
    }

    /// Adds `word` as a new comma-separated item, or removes it when it is already there.
    public static func toggling(_ word: String, in text: String) -> String {
        var items = words(in: text)
        if let index = items.firstIndex(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) {
            items.remove(at: index)
        } else {
            items.append(word)
        }
        return items.joined(separator: ", ")
    }

    /// The note for storing and exporting: trimmed, nil when empty.
    public static func cleaned(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    // MARK: Style

    /// Word beginnings (English and Dutch, so *warm* also finds *warme* and *koel* finds *koele*) that speak of warmth or cold.
    static let warmStems = ["warm", "gloed", "glow", "gold", "goud", "sunset", "zonsondergang", "sunny", "zonnig", "cozy", "gezellig",
                            "zomer", "summer", "herfst", "autumn", "avond", "evening"]
    static let coolStems = ["cool", "koel", "koud", "cold", "icy", "ijzig", "winter", "fresh", "fris", "blue", "blauw", "mist", "melanchol"]

    /// Words for the two styles that are not about temperature.
    static let cinematicStems = ["cinema", "filmisch", "film", "blockbuster", "teal"]
    static let fadedStems = ["fade", "vervaag", "vintage", "retro", "nostalg", "matte"]

    /// The grading style a note points to: warm words ask for warm highlights over cool shadows, cool words for the reverse.
    /// nil when the note has no temperature word, or has both kinds (it does not decide), and the words found are returned
    /// so the reason can be shown.
    public static func suggestedStyle(for text: String) -> (style: GradingStyle, words: [String])? {
        let tokens = text.lowercased().split { !$0.isLetter }.map(String.init)
        let warm = tokens.filter { token in warmStems.contains { token.hasPrefix($0) } }
        let cool = tokens.filter { token in coolStems.contains { token.hasPrefix($0) } }
        switch (warm.isEmpty, cool.isEmpty) {
        case (false, true): return (.warmHighlights, warm)
        case (true, false): return (.coolHighlights, cool)
        case (false, false): return nil
        case (true, true):
            // No temperature word: a word for one of the other styles decides, when it is the only kind there.
            let cinematic = tokens.filter { token in cinematicStems.contains { token.hasPrefix($0) } }
            let faded = tokens.filter { token in fadedStems.contains { token.hasPrefix($0) } }
            if !cinematic.isEmpty, faded.isEmpty { return (.tealOrange, cinematic) }
            if cinematic.isEmpty, !faded.isEmpty { return (.faded, faded) }
            return nil
        }
    }
}
