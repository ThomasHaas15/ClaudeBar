import SwiftUI

struct ModelRow: View {
    let displayName: String
    let percent: Double
    let inputTokens: Int
    let outputTokens: Int
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
                Text("In: \(TokenFormat.compact(inputTokens))  ·  Out: \(TokenFormat.compact(outputTokens))")
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

    private var formattedPercent: String {
        if percent >= 10 { return String(format: "%.1f", percent) }
        return String(format: "%.1f", percent)
    }
}
