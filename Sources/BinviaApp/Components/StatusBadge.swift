import SwiftUI

/// 状态指示灯（圆点）。
struct StatusBadge: View {
    let color: Color
    var tooltip: String? = nil

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .help(tooltip ?? "")
    }
}

enum BadgeColor {
    static let running = Color.green
    static let stopped = Color.gray
    static let connected = Color.green
    static let unconfigured = Color.gray
    static let testing = Color.orange
    static let error = Color.red
}
