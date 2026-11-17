import Foundation

/// How the picker's search matches a name: anywhere in it, ignoring case
/// and accents, or in the pinyin of a Chinese name ("jisuanqi" or "jsq"
/// finds 计算器). Pinyin also matters because a Chinese input method shows
/// the letters typed (with spaces or apostrophes) until a word is chosen,
/// and the list filters on those as they're typed.
enum SearchMatch {
    static func matches(_ text: String, _ needle: String) -> Bool {
        if needle.isEmpty || text.localizedStandardContains(needle) { return true }
        guard text.unicodeScalars.contains(where: { !$0.isASCII }) else { return false }
        let letters = needle.lowercased().filter { $0.isLetter || $0.isNumber }
        guard !letters.isEmpty, letters.allSatisfy(\.isASCII) else { return false }
        let syllables = (text.applyingTransform(.toLatin, reverse: false) ?? text)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return syllables.joined().contains(letters)
            || String(syllables.compactMap(\.first)).contains(letters)
    }
}
