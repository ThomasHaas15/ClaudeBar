import SwiftUI

struct StatCard: View {
    let title: String
    let value: String
    var subtitle: String? = nil
    var delta: Delta? = nil

    /// A change against an earlier figure, shown beside the value.
    struct Delta: Equatable {
        /// Signed fraction: 0.18 is eighteen percent up.
        let change: Double

        enum Direction { case up, down, flat }

        /// A change that rounds away to nothing gets no arrow: a green "0%"
        /// pointing up reads as a bug rather than as a quiet week.
        var direction: Direction {
            if abs(change) < 0.005 { return .flat }
            return change > 0 ? .up : .down
        }

        var symbol: String? {
            switch direction {
            case .up:   return "arrow.up"
            case .down: return "arrow.down"
            case .flat: return nil
            }
        }

        var tint: Color {
            switch direction {
            case .up:   return .trendUp
            case .down: return .trendDown
            case .flat: return .secondary
            }
        }

        /// Percent up to a tenfold rise, multiples past it — "1400%" is not a
        /// number anyone reads, "14×" is. Only a rise can get there: a fall
        /// bottoms out at 100%.
        var label: String {
            let magnitude = abs(change)
            if magnitude < 10 { return "\(Int((magnitude * 100).rounded()))%" }
            return "\(Int((magnitude + 1).rounded()))×"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value)
                    .font(.title2.weight(.semibold))
                    .monoDigits()
                if let delta {
                    HStack(spacing: 1) {
                        if let symbol = delta.symbol {
                            Image(systemName: symbol)
                                .imageScale(.small)
                        }
                        Text(delta.label)
                            .monoDigits()
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(delta.tint)
                }
            }
            .lineLimit(1)
            Text(subtitle ?? " ")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        )
    }
}
