import SwiftUI

struct ProgressBar: View {
    let ratio: Double
    var color: Color = .limitBlue
    var trackHeight: CGFloat = Theme.progressTrackHeight

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.18))
                Capsule()
                    .fill(color)
                    .frame(width: max(2, min(geo.size.width, geo.size.width * CGFloat(min(ratio, 1.0)))))
            }
        }
        .frame(height: trackHeight)
    }
}
