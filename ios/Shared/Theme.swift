import SwiftUI

// 앱 아이콘과 같은 터미널풍 플랫 다크 팔레트
enum ChargeTheme {
    static let bg = Color(red: 0.067, green: 0.071, blue: 0.078)    // #111214
    static let accent = Color(red: 0.55, green: 0.95, blue: 0.65)   // 충전 그린
    static let card = Color.white.opacity(0.07)

    static var background: Color { bg }
}

// 한도 배지의 아이콘, 색은 문구와 같은 범위 구분을 따른다: 계정 전체는 빨간 자물쇠, 모델 범위는 주황 경고 삼각형.
// 범위를 반드시 가르는 이유는 ProviderLimitState 주석에 있다. 앱은 배경에 투명도를 얹으므로 tint는 단색 Color로 둔다.
extension ProviderLimitState {
    var symbolName: String { isProviderWide ? "lock.fill" : "exclamationmark.triangle.fill" }
    var tint: Color { isProviderWide ? .red : .orange }
}
