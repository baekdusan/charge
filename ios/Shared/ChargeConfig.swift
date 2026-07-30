import Foundation
import WidgetKit

/// 앱과 위젯이 공유하는 런타임 설정 (App Group UserDefaults)
enum ChargeConfig {
    static let suite = "group.com.dusan.charge"
    /// suiteName 이니셜라이저는 호출마다 새 인스턴스를 만들므로 한 번만 생성해 재사용한다
    /// (providerOrder·demoMode가 렌더 경로에서 읽히면서 이 접근이 잦아졌다)
    static let defaults = UserDefaults(suiteName: suite) ?? .standard

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

    /// 사용자가 설정에서 드래그로 정한 표시 순서 (프로바이더 id 배열).
    /// 목록에 없는 새 id는 수집된 순서 그대로 뒤에 붙는다.
    static var providerOrder: [String] {
        get { defaults.stringArray(forKey: "providerOrder") ?? [] }
        set { defaults.set(newValue, forKey: "providerOrder") }
    }

    /// 저장된 표시 순서를 적용한다 — 앱 카드·세그먼트·위젯·설정 목록이 모두 이 순서를 따른다.
    /// 순서 목록에 없는 항목은 원래(수집) 순서를 유지한 채 뒤로 간다.
    static func sortedByUserOrder<T>(_ items: [T], id: (T) -> String, order: [String]? = nil) -> [T] {
        let order = order ?? providerOrder
        guard !order.isEmpty else { return items }
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return items.enumerated()
            .sorted { a, b in
                let ra = rank[id(a.element)] ?? order.count + a.offset
                let rb = rank[id(b.element)] ?? order.count + b.offset
                return ra == rb ? a.offset < b.offset : ra < rb
            }
            .map(\.element)
    }

    static func sortedByUserOrder(_ providers: [Provider]) -> [Provider] {
        sortedByUserOrder(providers, id: \.id)
    }

    /// 로그아웃·계정 삭제 시 함께 지워야 하는 계정 귀속 설정 —
    /// 키 목록의 정본은 여기 하나다 (demoMode는 계정 귀속이 아니라 의도적으로 제외)
    static func resetAccountScoped() {
        for key in ["knownProviders", "hiddenProviders", "providerOrder"] {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: 데모 모드

    /// 런치 인자 오버라이드 — 저장값을 건드리지 않는 프로세스 스코프.
    /// UI 테스트·스크린샷이 실기기의 실제 상태를 데모로 남겨두는 사고를 막는다.
    private static let demoOverride: Bool? = {
        if CommandLine.arguments.contains("-charge-demo") { return true }
        if CommandLine.arguments.contains("-charge-demo-off") { return false }
        return nil
    }()

    /// 로그인·페어링 없이 샘플 데이터로 앱을 둘러보는 모드 (App Store 심사용 겸 미리보기).
    /// App Group에 저장해 위젯도 같은 샘플 데이터를 보여준다. 전환은 setDemoMode로.
    static var demoMode: Bool { demoOverride ?? defaults.bool(forKey: "demoMode") }

    /// UI 테스트 전용: 데모 조회에 인위적 지연(초)을 넣어 느린 네트워크에서의
    /// 새로고침 인디케이터 동작을 관찰·검증할 수 있게 한다 (`-charge-demo-latency 3`)
    static let demoLatency: Double? = {
        guard let i = CommandLine.arguments.firstIndex(of: "-charge-demo-latency"),
              CommandLine.arguments.indices.contains(i + 1) else { return nil }
        return Double(CommandLine.arguments[i + 1])
    }()

    /// 데모 모드 전환의 단일 경로 — 플래그와 함께 캐시·위젯을 항상 같이 정리한다.
    /// (콜사이트마다 정리 항목을 따로 기억하면 하나씩 빠뜨리게 된다)
    static func setDemoMode(_ on: Bool) {
        defaults.set(on, forKey: "demoMode")
        ChargeAPI.clearCache()
        WidgetCenter.shared.reloadAllTimelines()
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
