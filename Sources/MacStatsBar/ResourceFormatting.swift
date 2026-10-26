import SwiftUI

struct ResourceNotice: View {
    let title: String
    let message: String
    let symbol: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.title).foregroundStyle(.secondary)
            Text(verbatim: title).font(.headline)
            Text(verbatim: message).foregroundStyle(.secondary).multilineTextAlignment(.center).textSelection(.enabled)
        }.padding(24).frame(maxWidth: .infinity)
    }
}

enum ResourceFormat {
    static func size(_ value: UInt64?) -> String {
        guard let value else { return "—" }
        if value == 0 { return String(localized: "0 bytes") }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .decimal)
    }
}
