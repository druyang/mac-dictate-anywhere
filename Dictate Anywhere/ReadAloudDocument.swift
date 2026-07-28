//
//  ReadAloudDocument.swift
//  Dictate Anywhere
//
//  Word-addressable model of the text being read aloud. The reader UI renders
//  these words, playback progress maps onto their indices, and seeking hands
//  the tail of the document back to the speech engine.
//

import Foundation

nonisolated struct ReadAloudDocument: Equatable, Sendable {
    /// One spoken word, in document order.
    ///
    /// Every word in this list is spoken, so a word's `id` is both its position
    /// on screen and its position in the text handed to the speech engine.
    /// That equivalence is what lets a click on a word become a seek.
    struct Word: Equatable, Sendable, Identifiable {
        let id: Int
        let text: String
        let paragraph: Int
        let sentence: Int
    }

    struct Paragraph: Equatable, Sendable, Identifiable {
        let id: Int
        let range: Range<Int>
    }

    /// Reading pace used for the "about N min left" estimates. Speech models
    /// land between roughly 150 and 180 wpm; the label says "about" for a
    /// reason.
    static let wordsPerMinute = 165.0

    let words: [Word]
    let paragraphs: [Paragraph]
    /// First word index of each sentence, in order.
    let sentenceStarts: [Int]

    static let empty = ReadAloudDocument(source: "")

    var isEmpty: Bool { words.isEmpty }
    var wordCount: Int { words.count }
    var sentenceCount: Int { sentenceStarts.count }

    // MARK: - Parsing

    init(source: String) {
        var words: [Word] = []
        var paragraphs: [Paragraph] = []
        var sentenceStarts: [Int] = []
        var paragraphIndex = 0
        var sentenceIndex = 0
        var startsNewSentence = true
        var isInsideCodeFence = false

        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                isInsideCodeFence.toggle()
                continue
            }

            let cleaned = isInsideCodeFence
                ? line.trimmingCharacters(in: .whitespacesAndNewlines)
                : Self.cleanedLine(line)
            guard !cleaned.isEmpty else { continue }

            let paragraphStart = words.count
            for token in cleaned.split(whereSeparator: \.isWhitespace) {
                let text = String(token)
                if startsNewSentence {
                    sentenceStarts.append(words.count)
                    sentenceIndex = sentenceStarts.count - 1
                    startsNewSentence = false
                }
                words.append(
                    Word(
                        id: words.count,
                        text: text,
                        paragraph: paragraphIndex,
                        sentence: sentenceIndex
                    )
                )
                if Self.endsSentence(text) {
                    startsNewSentence = true
                }
            }

            guard words.count > paragraphStart else { continue }
            paragraphs.append(
                Paragraph(id: paragraphIndex, range: paragraphStart..<words.count)
            )
            paragraphIndex += 1
            // A line break ends the sentence even without closing punctuation,
            // so a heading or a list item never merges into the next line.
            startsNewSentence = true
        }

        self.words = words
        self.paragraphs = paragraphs
        self.sentenceStarts = sentenceStarts
    }

    /// Strips the markdown scaffolding that would otherwise be read out loud
    /// ("hash hash Key Findings") and collapses runs of whitespace.
    static func cleanedLine(_ line: String) -> String {
        var text = line

        for (pattern, replacement) in [
            (#"^\s{0,3}(?:>\s*)*(?:#{1,6}\s+|[-*+]\s+|\d+[.)]\s+)"#, ""),
            (#"\[([^\]]*)\]\([^)]*\)"#, "$1"),
            (#"!\[[^\]]*\]\([^)]*\)"#, ""),
        ] {
            text = text.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            )
        }

        text = text
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")

        // A horizontal rule carries no spoken content.
        if text.trimmingCharacters(in: .whitespaces)
            .allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" || $0 == "=" }),
            text.trimmingCharacters(in: .whitespaces).count >= 3 {
            return ""
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "vs", "etc",
        "approx", "fig", "no", "al", "inc", "ltd", "co", "dept", "est",
    ]

    /// Whether a token closes a sentence. Deliberately conservative: a missed
    /// boundary only makes a sentence jump longer, a false one splits mid-thought.
    static func endsSentence(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(
            in: CharacterSet(charactersIn: "\"')]}»”’*_")
        )
        guard let last = trimmed.last, ".!?…".contains(last) else { return false }
        guard last == "." else { return true }

        let core = String(trimmed.dropLast()).lowercased()
        if core.count <= 1 { return false }
        // "e.g.", "i.e.", "U.S." — an inner period means it is not a boundary.
        if core.contains(".") { return false }
        return !abbreviations.contains(core)
    }

    // MARK: - Playback helpers

    /// The text handed to the speech engine when playback starts at `wordIndex`.
    func spokenText(from wordIndex: Int = 0) -> String {
        let start = max(wordIndex, 0)
        guard start < words.count else { return "" }
        return words[start...].map(\.text).joined(separator: " ")
    }

    func clampedWordIndex(_ index: Int) -> Int {
        guard !words.isEmpty else { return 0 }
        return min(max(index, 0), words.count - 1)
    }

    func paragraph(containing wordIndex: Int) -> Int {
        guard !words.isEmpty else { return 0 }
        return words[clampedWordIndex(wordIndex)].paragraph
    }

    func sentence(containing wordIndex: Int) -> Int {
        guard !words.isEmpty else { return 0 }
        return words[clampedWordIndex(wordIndex)].sentence
    }

    /// Word range of a sentence, used to cap the ends of its highlight band.
    func sentenceRange(_ sentence: Int) -> Range<Int> {
        guard sentence >= 0, sentence < sentenceStarts.count else { return 0..<0 }
        let start = sentenceStarts[sentence]
        let end = sentence + 1 < sentenceStarts.count
            ? sentenceStarts[sentence + 1]
            : words.count
        return start..<end
    }

    func sentenceStart(containing wordIndex: Int) -> Int {
        guard !words.isEmpty else { return 0 }
        return sentenceStarts[sentence(containing: wordIndex)]
    }

    /// Track-previous behaviour: restart the current sentence unless playback
    /// only just entered it, in which case step back one sentence.
    func previousSentenceStart(from wordIndex: Int) -> Int {
        guard !words.isEmpty else { return 0 }
        let current = sentence(containing: wordIndex)
        let start = sentenceStarts[current]
        if wordIndex - start > 2 || current == 0 { return start }
        return sentenceStarts[current - 1]
    }

    /// First word of the next sentence, or `wordCount` when there is none left.
    func nextSentenceStart(from wordIndex: Int) -> Int {
        guard !words.isEmpty else { return 0 }
        let current = sentence(containing: wordIndex)
        guard current + 1 < sentenceStarts.count else { return words.count }
        return sentenceStarts[current + 1]
    }

    func estimatedSeconds(from wordIndex: Int = 0) -> TimeInterval {
        let remaining = max(words.count - max(wordIndex, 0), 0)
        return Double(remaining) / Self.wordsPerMinute * 60
    }

    /// "about 4 min", "about 2 min 40 s", "about 25 s".
    static func approximateDurationLabel(seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        guard total >= 60 else { return "about \(max(total, 1)) s" }
        let minutes = total / 60
        let remainder = (total % 60) / 5 * 5
        guard remainder > 0, minutes < 10 else { return "about \(minutes) min" }
        return "about \(minutes) min \(remainder) s"
    }
}
