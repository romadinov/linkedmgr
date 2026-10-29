import Foundation

/// Converts the editor's text into what LinkedIn's APIs expect.
///
/// In the editor a mention is written as `@[Display Name](urn:li:person:abc)` or
/// `@[Acme](urn:li:organization:123)`. A mention with empty parentheses, `@[Jane Doe]()`,
/// is "unresolved": we know who to tag but have no URN, so it is published as plain
/// text and the user is reminded to tag that person by hand.
///
/// Post commentary uses LinkedIn's "little" format, where reserved characters must be
/// backslash-escaped. Comments use plain text plus mention attributes instead.
/// https://learn.microsoft.com/en-us/linkedin/marketing/community-management/shares/little-text-format
enum LittleText {
    enum Segment: Equatable {
        case text(String)
        case mention(name: String, urn: String?)
    }

    struct Attribute: Equatable {
        var start: Int
        var length: Int
        var urn: String
    }

    static let reserved: Set<Character> = ["\\", "|", "{", "}", "@", "[", "]", "(", ")", "<", ">", "#", "*", "_", "~"]

    private static let mentionPattern = #/@\[([^\]\n]+)\]\(([^)\s]*)\)/#

    static func segments(_ text: String) -> [Segment] {
        var result: [Segment] = []
        var cursor = text.startIndex
        for match in text.matches(of: mentionPattern) {
            if cursor < match.range.lowerBound {
                result.append(.text(String(text[cursor..<match.range.lowerBound])))
            }
            let urn = String(match.output.2)
            result.append(.mention(name: String(match.output.1), urn: urn.isEmpty ? nil : urn))
            cursor = match.range.upperBound
        }
        if cursor < text.endIndex {
            result.append(.text(String(text[cursor...])))
        }
        return result
    }

    /// The `commentary` value for the Posts API.
    static func commentary(_ text: String) -> String {
        segments(text).map { segment in
            switch segment {
            case .text(let s):
                return escape(s)
            case .mention(let name, let urn?):
                return "@[\(escape(name, keepHashtags: false))](\(urn))"
            case .mention(let name, nil):
                return escape(name, keepHashtags: false)
            }
        }.joined()
    }

    /// Plain text plus mention attributes for the Comments API. Offsets are UTF-16 based.
    static func commentMessage(_ text: String) -> (text: String, attributes: [Attribute]) {
        var plain = ""
        var attributes: [Attribute] = []
        for segment in segments(text) {
            switch segment {
            case .text(let s):
                plain += s
            case .mention(let name, let urn):
                if let urn {
                    attributes.append(Attribute(start: plain.utf16.count, length: name.utf16.count, urn: urn))
                }
                plain += name
            }
        }
        return (plain, attributes)
    }

    /// Names that will be published as plain text because they have no URN.
    static func unresolvedMentions(_ text: String) -> [String] {
        segments(text).compactMap {
            if case .mention(let name, nil) = $0 { return name }
            return nil
        }
    }

    /// Text as a reader will see it on LinkedIn (mentions rendered as names).
    static func displayText(_ text: String) -> String {
        commentMessage(text).text
    }

    static func mentionToken(name: String, urn: String?) -> String {
        "@[\(name)](\(urn ?? ""))"
    }

    /// Escapes reserved characters. A `#` directly followed by a letter or digit is left
    /// alone so it still becomes a hashtag, as in LinkedIn's own `#coding` example.
    static func escape(_ s: String, keepHashtags: Bool = true) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        let chars = Array(s)
        for (i, c) in chars.enumerated() {
            if keepHashtags, c == "#", i + 1 < chars.count, chars[i + 1].isLetter || chars[i + 1].isNumber {
                out.append(c)
            } else if reserved.contains(c) {
                out.append("\\")
                out.append(c)
            } else {
                out.append(c)
            }
        }
        return out
    }
}
