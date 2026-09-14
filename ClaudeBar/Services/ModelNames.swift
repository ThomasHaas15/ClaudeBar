import Foundation

/// Turns the model ids Claude Code writes into session logs into the names
/// Anthropic shows for them.
///
/// Deliberately derived from the id's shape rather than a table of known
/// models: Anthropic ships new ones between ClaudeBar releases, and a table
/// that has not been updated yet degrades in the worst way — `claude-opus-5`
/// matching a `contains("opus")` rule renders as "Opus", silently merging two
/// different models under one label in the Models tab, while an id no rule
/// matches at all renders raw. The shape, in contrast, has been stable across
/// every model Claude Code has shipped:
///
///     claude-<family>-<major>[-<minor>][-<date>]   claude-opus-4-1-20250805
///     claude-<major>[-<minor>]-<family>[-<date>]   claude-3-5-sonnet-20241022
///
/// around which providers wrap prefixes (`us.anthropic.…`) and suffixes
/// (`@20251101`, `-v1:0`), and Claude Code appends a `[1m]` context marker.
enum ModelNames {
    /// Whether a model id belongs in a usage breakdown at all. Claude Code
    /// books the odd bookkeeping message — an interrupt, a compaction notice —
    /// against `<synthetic>`, which is not a model anyone chose or paid for.
    static func isUserFacing(id: String) -> Bool {
        let lowered = id.lowercased()
        if lowered.isEmpty { return false }
        return !lowered.contains("synthetic")
    }

    static func display(for id: String) -> String {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Unknown model" }

        let (base, contextSuffix) = splitContextMarker(trimmed.lowercased())
        let core = stripDecorations(stripProviderPrefix(base))
        return (version(of: core) ?? titleCased(core)) + contextSuffix
    }

    /// `claude-sonnet-4-5-20250929[1m]` → the id, and " (1M context)".
    private static func splitContextMarker(_ id: String) -> (String, String) {
        for width in ["1", "2"] where id.hasSuffix("[\(width)m]") {
            return (String(id.dropLast(4)), " (\(width)M context)")
        }
        return (id, "")
    }

    /// Bedrock and Vertex serve the same models under a prefixed id:
    /// `us.anthropic.claude-opus-5`, `anthropic.claude-haiku-4-5`.
    private static func stripProviderPrefix(_ id: String) -> String {
        guard let marker = id.range(of: "anthropic.") else { return id }
        // Only a prefix, never a mid-id match: the part before it has to be
        // empty or a single region-ish segment.
        let head = id[id.startIndex..<marker.lowerBound]
        guard head.isEmpty || (head.hasSuffix(".") && !head.dropLast().contains(".")) else { return id }
        return String(id[marker.upperBound...])
    }

    /// Drops the training-date and provider-revision tails: `-20250805`,
    /// `@20251101`, `-v1:0`, `-latest`, `-fast`.
    private static func stripDecorations(_ id: String) -> String {
        var out = id
        var changed = true
        while changed {
            changed = false
            for suffix in ["-latest", "-fast"] where out.hasSuffix(suffix) {
                out.removeLast(suffix.count)
                changed = true
            }
            if let separator = out.lastIndex(where: { $0 == "-" || $0 == "@" }) {
                let tail = out[out.index(after: separator)...]
                // A training date (8 digits) or a revision (`v1`, `v1:0`).
                let isDate = tail.count == 8 && tail.allSatisfy(\.isNumber)
                let isRevision = tail.first == "v"
                    && tail.dropFirst().allSatisfy { $0.isNumber || $0 == ":" }
                    && tail.count > 1
                if isDate || isRevision {
                    out = String(out[out.startIndex..<separator])
                    changed = true
                }
            }
        }
        return out
    }

    /// `claude-opus-4-6` → "Opus 4.6"; `claude-3-5-sonnet` → "Sonnet 3.5".
    /// Nil for anything that is not one word and one or two version numbers,
    /// so `claude-mythos-preview` falls through to the plain title case.
    private static func version(of id: String) -> String? {
        let parts = id.split(separator: "-")
        guard parts.first == "claude", parts.count >= 3 else { return nil }

        var family: Substring?
        var numbers: [Substring] = []
        for part in parts.dropFirst() {
            if part.allSatisfy(\.isNumber) {
                // Two digits at most: an 8-digit tail is a date that survived
                // `stripDecorations`, not a version.
                guard part.count <= 2, numbers.count < 2 else { return nil }
                numbers.append(part)
            } else if family == nil, part.allSatisfy(\.isLetter) {
                family = part
            } else {
                return nil
            }
        }
        guard let family, !numbers.isEmpty else { return nil }
        return "\(family.capitalized) \(numbers.joined(separator: "."))"
    }

    private static func titleCased(_ id: String) -> String {
        let words = id.split(separator: "-").drop { $0 == "claude" }
        guard !words.isEmpty else { return id }
        return words.map(\.capitalized).joined(separator: " ")
    }
}
