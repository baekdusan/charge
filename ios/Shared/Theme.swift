import SwiftUI

// 앱 아이콘과 같은 터미널풍 플랫 다크 팔레트
enum ChargeTheme {
    static let bg = Color(red: 0.067, green: 0.071, blue: 0.078)    // #111214
    static let accent = Color(red: 0.55, green: 0.95, blue: 0.65)   // 충전 그린
    static let card = Color.white.opacity(0.07)

    static var background: Color { bg }
}
