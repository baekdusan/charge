import Foundation

/// 앱과 위젯이 공유하는 런타임 설정 (App Group UserDefaults)
enum ChargeConfig {
    static let suite = "group.com.dusan.charge"
    static var defaults: UserDefaults { UserDefaults(suiteName: suite) ?? .standard }

    // MARK: 데이터 소스

    static var gistRawURL: URL? {
        get {
            guard let s = defaults.string(forKey: "gistRawURL"), !s.isEmpty else { return nil }
            return URL(string: s)
        }
        set { defaults.set(newValue?.absoluteString ?? "", forKey: "gistRawURL") }
    }

    /// gist 페이지 URL / raw URL 어떤 형태를 붙여넣어도 raw URL로 정규화
    static func normalizeGistURL(_ input: String) -> URL? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: s), let host = url.host else { return nil }
        if host == "gist.githubusercontent.com" {
            return url
        }
        if host == "gist.github.com" {
            // https://gist.github.com/<user>/<id> → raw URL
            let parts = url.path.split(separator: "/").map(String.init)
            guard parts.count >= 2 else { return nil }
            return URL(string: "https://gist.githubusercontent.com/\(parts[0])/\(parts[1])/raw/charge.json")
        }
        return nil
    }

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
}
