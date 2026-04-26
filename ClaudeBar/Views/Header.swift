import SwiftUI

struct PopoverHeader: View {
    let todayTokens: Int
    let streakDays: Int

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            HStack(spacing: 8) {
                Image(nsImage: ClaudeMark.image(size: 12))
                    .renderingMode(.template)
                    .foregroundStyle(.secondary)
                Text("\(TokenFormat.compact(todayTokens)) tokens today")
                    .font(.callout)
                    .monoDigits()
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            Text("\(streakDays)d streak")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monoDigits()
                .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        )
    }
}
