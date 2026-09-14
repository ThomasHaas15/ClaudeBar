import Testing
@testable import ClaudeBar

struct ModelNamesTests {
    /// The ids Claude Code has actually written into session logs, current and
    /// historical, against the names Anthropic shows for them.
    @Test(arguments: [
        ("claude-opus-5", "Opus 5"),
        ("claude-sonnet-5", "Sonnet 5"),
        ("claude-fable-5-1", "Fable 5.1"),
        ("claude-fable-5", "Fable 5"),
        ("claude-mythos-5", "Mythos 5"),
        ("claude-opus-4-8", "Opus 4.8"),
        ("claude-opus-4-7", "Opus 4.7"),
        ("claude-opus-4-6", "Opus 4.6"),
        ("claude-opus-4-5-20251101", "Opus 4.5"),
        ("claude-opus-4-1-20250805", "Opus 4.1"),
        ("claude-opus-4-20250514", "Opus 4"),
        ("claude-sonnet-4-6", "Sonnet 4.6"),
        ("claude-sonnet-4-5-20250929", "Sonnet 4.5"),
        ("claude-sonnet-4-20250514", "Sonnet 4"),
        ("claude-haiku-4-5-20251001", "Haiku 4.5"),
        ("claude-3-7-sonnet-20250219", "Sonnet 3.7"),
        ("claude-3-5-sonnet-20241022", "Sonnet 3.5"),
        ("claude-3-5-haiku-20241022", "Haiku 3.5")
    ])
    func namesFirstPartyModels(id: String, expected: String) {
        #expect(ModelNames.display(for: id) == expected)
    }

    /// Bedrock and Vertex spellings of the same models.
    @Test(arguments: [
        ("us.anthropic.claude-opus-5", "Opus 5"),
        ("anthropic.claude-opus-4-7", "Opus 4.7"),
        ("us.anthropic.claude-opus-4-1-20250805-v1:0", "Opus 4.1"),
        ("us.anthropic.claude-haiku-4-5-20251001-v1:0", "Haiku 4.5"),
        ("claude-opus-4-5@20251101", "Opus 4.5"),
        ("claude-sonnet-4-5-v2@20250929", "Sonnet 4.5"),
        ("eu.anthropic.claude-sonnet-5", "Sonnet 5")
    ])
    func namesProviderSpellings(id: String, expected: String) {
        #expect(ModelNames.display(for: id) == expected)
    }

    /// The long-context variants carry a marker Claude Code appends to the id.
    @Test func marksTheLongContextVariants() {
        #expect(ModelNames.display(for: "claude-sonnet-4-5-20250929[1m]") == "Sonnet 4.5 (1M context)")
        #expect(ModelNames.display(for: "claude-opus-5[2m]") == "Opus 5 (2M context)")
    }

    /// A model whose id does not carry a version still has to read as a name,
    /// not as an id — this is what a newly launched model looks like to a
    /// build of ClaudeBar that predates it.
    @Test func fallsBackToATitleForUnversionedIds() {
        #expect(ModelNames.display(for: "claude-mythos-preview") == "Mythos Preview")
        #expect(ModelNames.display(for: "unknown") == "Unknown")
        #expect(ModelNames.display(for: "opus") == "Opus")
        #expect(ModelNames.display(for: "") == "Unknown model")
    }

    /// Two models of the same family must never collapse onto one label: that
    /// is what a `contains("opus")` rule does to an id it has never seen, and
    /// it silently merges their rows in the Models tab.
    @Test func keepsModelsOfOneFamilyApart() {
        let names = ["claude-opus-4-6", "claude-opus-4-7", "claude-opus-4-8", "claude-opus-5"]
            .map { ModelNames.display(for: $0) }
        #expect(Set(names).count == names.count)
    }

    @Test func hidesClaudeCodesOwnBookkeepingModel() {
        #expect(!ModelNames.isUserFacing(id: "<synthetic>"))
        #expect(ModelNames.isUserFacing(id: "claude-opus-5"))
    }
}
