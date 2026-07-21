import Foundation

/// 앱과 위젯이 공유하는 런타임 설정 (App Group UserDefaults)
enum ChargeConfig {
    static let suite = "group.com.dusan.charge"
    static var defaults: UserDefaults { UserDefaults(suiteName: suite) ?? .standard }

    // MARK: 프로바이더 표시 관리

    static var hiddenProviders: Set<String> {
        get { Set(defaults.stringArray(forKey: "hiddenProviders") ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: "hiddenProviders") }
    }

    static func isHidden(_ id: String) -> Bool { hiddenProviders.contains(id) }

    static func setHidden(_ id: String, _ hidden: Bool) {
        var set = hiddenProviders
        if hidden { set.insert(id) } else { set.remove(id) }
        hiddenProviders = set
    }

    /// 지금까지 관측한 프로바이더 id → 이름.
    /// 숨기거나 수집이 일시적으로 실패해 페이로드에서 빠져도 설정 목록에서 다시 켤 수 있게 기억한다.
    static var knownProviders: [String: String] {
        get { (defaults.dictionary(forKey: "knownProviders") as? [String: String]) ?? [:] }
        set { defaults.set(newValue, forKey: "knownProviders") }
    }

    static func rememberProviders(_ providers: [Provider]) {
        guard !providers.isEmpty else { return }
        var known = knownProviders
        for p in providers { known[p.id] = p.name }
        if known != knownProviders { knownProviders = known }
    }
}
