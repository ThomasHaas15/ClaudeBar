import SwiftUI

struct ModelRow: View {
    let displayName: String
    let percent: Double
    let usage: TokenUsage
    let dotColor: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.body.weight(.medium))
                Text(breakdown)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monoDigits()
            }
            Spacer()
            Text("\(formattedPercent)%")
                .font(.callout)
                .foregroundStyle(.primary)
                .monoDigits()
        }
    }

    /// What the share is made of, input and output first: the cache columns are
    /// nearly all of it, and listed first they would bury what the model wrote.
    private var breakdown: String {
        var parts = [
            "In: \(TokenFormat.compact(usage.input))",
            "Out: \(TokenFormat.compact(usage.output))"
        ]
        let cache = usage.cacheRead + usage.cacheCreation
        if cache > 0 { parts.append("Cache: \(TokenFormat.compact(cache))") }
        return parts.joined(separator: "  ·  ")
    }

    private var formattedPercent: String {
        String(format: "%.1f", percent)
    }
}
