import Foundation
import NaturalLanguage

struct TopicExtraction: Sendable {
    let topics: [String]
    let entities: [String]
}

/// Cheap topic + entity extraction using `NLTagger`. Runs synchronously per finalized segment.
/// Embedding-based topic clustering is in the roadmap; the surface here stays the same.
struct TopicExtractor: Sendable {
    func extract(from text: String) -> TopicExtraction {
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .nameType])
        tagger.string = text
        let range = text.startIndex..<text.endIndex

        var topics: [String] = []
        var entities: [String] = []

        tagger.enumerateTags(
            in: range,
            unit: .word,
            scheme: .lexicalClass,
            options: [.omitWhitespace, .omitPunctuation, .joinNames]
        ) { tag, tokenRange in
            if tag == .noun {
                let token = String(text[tokenRange]).lowercased()
                if token.count >= 4, !Stopwords.contains(token) {
                    topics.append(token)
                }
            }
            return true
        }

        tagger.enumerateTags(
            in: range,
            unit: .word,
            scheme: .nameType,
            options: [.omitWhitespace, .omitPunctuation, .joinNames]
        ) { tag, tokenRange in
            if let tag, [NLTag.personalName, .placeName, .organizationName].contains(tag) {
                entities.append(String(text[tokenRange]))
            }
            return true
        }

        return TopicExtraction(topics: dedupe(topics), entities: dedupe(entities))
    }

    private func dedupe(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { value in
            let key = value.lowercased()
            return seen.insert(key).inserted
        }
    }
}

private enum Stopwords {
    static let set: Set<String> = [
        "thing", "things", "stuff", "okay", "yeah", "right", "really",
        "kind", "sort", "lot", "lots", "time", "times", "way", "ways",
        "people", "person", "thing", "guess", "actually", "mean", "going"
    ]

    static func contains(_ value: String) -> Bool {
        set.contains(value)
    }
}
