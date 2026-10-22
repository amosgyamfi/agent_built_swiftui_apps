import Foundation

/// Splits streamed LLM text into speakable segments so TTS can start before the reply is finished.
nonisolated struct SentenceChunker {
    /// Shorter fragments are merged with the next sentence to avoid choppy prosody.
    var minimumSentenceLength = 12
    /// The first segment may break at a clause to get audio playing sooner.
    var firstClauseLength = 40
    /// Text without punctuation is force-split at a word boundary past this length.
    var maximumSegmentLength = 220

    private var buffer = ""
    private var emittedCount = 0

    mutating func append(_ text: String) -> [String] {
        buffer += text
        var segments: [String] = []
        while let boundary = nextBoundary() {
            let segment = buffer[..<boundary].trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = String(buffer[boundary...])
            if !segment.isEmpty {
                segments.append(segment)
                emittedCount += 1
            }
        }
        return segments
    }

    mutating func flush() -> String? {
        let segment = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        return segment.isEmpty ? nil : segment
    }

    private func nextBoundary() -> String.Index? {
        var index = buffer.startIndex
        var length = 0
        var lastSpace: String.Index?

        while index < buffer.endIndex {
            let character = buffer[index]
            let next = buffer.index(after: index)
            length += 1

            if character == "\n", length > 1 {
                return next
            }
            if next < buffer.endIndex, buffer[next].isWhitespace {
                if ".!?…".contains(character), length >= minimumSentenceLength {
                    return next
                }
                if emittedCount == 0, ",;:—".contains(character), length >= firstClauseLength {
                    return next
                }
            }
            if character.isWhitespace {
                lastSpace = index
            }
            if length >= maximumSegmentLength, let lastSpace {
                return buffer.index(after: lastSpace)
            }
            index = next
        }
        return nil
    }
}

nonisolated enum SpeechText {
    /// Removes markdown the model may still emit so the TTS voice doesn't read symbols aloud.
    static func speakable(_ text: String) -> String {
        let stripped = text
            .filter { !"*#`_~|".contains($0) }
            .replacingOccurrences(of: "•", with: "")
        return stripped
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "- ").union(.whitespaces))
    }
}
