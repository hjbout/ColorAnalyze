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
    static let monochromeStems = ["monochro", "eenkleur", "minimal", "tone-on-tone"]
    static let blueHourStems = ["twilight", "schemer", "dusk", "dawn", "bluehour"]

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
            let monochrome = tokens.filter { token in monochromeStems.contains { token.hasPrefix($0) } }
            let blueHour = tokens.filter { token in blueHourStems.contains { token.hasPrefix($0) } }
            let kinds: [(GradingStyle, [String])] = [(.tealOrange, cinematic), (.faded, faded), (.monochrome, monochrome),
                                                    (.blueHour, blueHour)].filter { !$0.1.isEmpty }
            return kinds.count == 1 ? (kinds[0].0, kinds[0].1) : nil
        }
    }

    // MARK: Contrasts

    /// Which way a contrast should go for a mood.
    public enum ContrastAim: String, Sendable, Equatable { case high, low }

    /// Moods and the contrasts they ask for (Itten's, see `ContrastProfile`), by word beginnings in English and Dutch.
    /// Temperature words are left out: whether *warm* means warm light over cool shade or warmth throughout is the
    /// style's question.
    static let contrastMoods: [(stems: [String], aims: [ContrastProfile.Kind: ContrastAim])] = [
        // Calm: one family of hues, little to clash.
        (["calm", "kalm", "rustig", "seren", "sereen", "peace", "vredig", "quiet", "stil", "tranquil"],
         [.hue: .low, .saturation: .low, .complementary: .low, .lightDark: .low]),
        // Soft and misty: a short tonal range, muted color.
        (["soft", "zacht", "gentle", "dream", "droom", "pastel", "airy", "luchtig", "mist", "nevel", "fog", "haz", "dauw"],
         [.lightDark: .low, .saturation: .low]),
        // Dramatic: light against dark, one accent, few hues to distract.
        (["drama", "bold", "krachtig", "intens", "power", "stoer", "graphic", "grafisch", "punch", "contrast"],
         [.lightDark: .high, .extension: .high, .hue: .low]),
        // Moody: deep shadows, held-back color.
        (["moody", "somber", "duister", "dark", "donker", "myster", "noir", "brood"],
         [.lightDark: .high, .saturation: .low]),
        // Energetic: vivid color, many hues.
        (["energ", "lively", "levendig", "vibrant", "vrolijk", "cheer", "playful", "speels", "kleurrijk", "colorful", "colourful"],
         [.saturation: .high, .hue: .high]),
        // Cinematic: warm against cool, complementary pairs.
        (cinematicStems, [.warmCool: .high, .complementary: .high]),
        // Nostalgic and faded: muted color, lifted darks.
        (fadedStems, [.saturation: .low, .lightDark: .low]),
        // Fresh: one temperature, not warm against cool.
        (["fresh", "fris", "crisp", "clean", "schoon"], [.warmCool: .low]),
        // Minimal: few hues.
        (monochromeStems + ["simpel", "simple", "eenvoud", "sober"], [.hue: .low]),
    ]

    /// The contrasts a note asks for, with the words that ask; a contrast that one word wants high and another low is
    /// left out (the note does not decide).
    public static func contrastAims(for text: String) -> [ContrastProfile.Kind: (aim: ContrastAim, words: [String])] {
        let tokens = text.lowercased().split { !$0.isLetter }.map(String.init)
        var found: [ContrastProfile.Kind: [ContrastAim: [String]]] = [:]
        for mood in contrastMoods {
            let words = tokens.filter { token in mood.stems.contains { token.hasPrefix($0) } }
            guard !words.isEmpty else { continue }
            for (kind, aim) in mood.aims {
                for word in words where !(found[kind]?[aim]?.contains(word) ?? false) { found[kind, default: [:]][aim, default: []].append(word) }
            }
        }
        return found.compactMapValues { aims in
            guard aims.count == 1, let (aim, words) = aims.first else { return nil }
            return (aim, words)
        }
    }
}
