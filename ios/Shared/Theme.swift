import SwiftUI

// 앱 아이콘과 같은 다크 네이비 팔레트
enum ChargeTheme {
    static let bgTop = Color(red: 0.07, green: 0.11, blue: 0.19)
    static let bgBottom = Color(red: 0.16, green: 0.28, blue: 0.40)
    static let accent = Color(red: 0.55, green: 0.95, blue: 0.65)   // 충전 그린
    static let card = Color.white.opacity(0.08)

    static var background: LinearGradient {
        LinearGradient(colors: [bgTop, bgBottom], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
