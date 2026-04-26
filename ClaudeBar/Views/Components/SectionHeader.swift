import SwiftUI

struct SectionHeader: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack {
            Text(title).sectionHeaderStyle()
            Spacer()
            if let trailing {
                Text(trailing)
                    .sectionHeaderStyle()
            }
        }
    }
}
