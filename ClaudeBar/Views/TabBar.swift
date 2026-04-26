import SwiftUI

enum PopoverTab: String, CaseIterable, Identifiable {
    case usage = "Usage"
    case stats = "Stats"
    case models = "Models"
    case status = "Status"

    var id: String { rawValue }
}

struct TabBar: View {
    @Binding var selection: PopoverTab

    var body: some View {
        HStack(spacing: 8) {
            ForEach(PopoverTab.allCases) { tab in
                Button {
                    selection = tab
                } label: {
                    Text(tab.rawValue)
                        .font(.callout.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.clear)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(
                                            selection == tab ? Color.primary.opacity(0.85) : Color.secondary.opacity(0.25),
                                            lineWidth: selection == tab ? 1.5 : 1
                                        )
                                )
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }
        }
    }
}
