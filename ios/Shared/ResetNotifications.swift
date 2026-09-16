import Foundation
import UserNotifications

/// 레이트리밋 창이 리셋되는 시각에 맞춰 로컬 알림을 예약한다.
/// resetsAt을 미리 알고 있으므로 서버 푸시 없이 로컬 예약으로 충분하다 —
/// 앱이 데이터를 받아올 때마다 최신 리셋 시각으로 예약을 갈아끼운다.
enum ResetNotifications {
    static var enabled: Bool {
        get { ChargeConfig.defaults.bool(forKey: "resetAlertsEnabled") }
        set { ChargeConfig.defaults.set(newValue, forKey: "resetAlertsEnabled") }
    }

    /// 마스터 토글이 켜진 상태에서 개별적으로 끈 프로바이더
    static var mutedProviders: Set<String> {
        get { Set(ChargeConfig.defaults.stringArray(forKey: "resetAlertMuted") ?? []) }
        set { ChargeConfig.defaults.set(Array(newValue).sorted(), forKey: "resetAlertMuted") }
    }

    /// 토글을 켤 때 호출 — 시스템 설정에서 거부된 상태면 false
    static func requestPermission() async -> Bool {
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        default:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        }
    }

    /// 프롬프트 없이 현재 허용 상태만 조회 — 설정 화면이 열릴 때
    /// iOS 설정에서 권한을 회수한 경우를 감지하는 데 쓴다
    static func permissionGranted() async -> Bool {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        default:
            return false
        }
    }

    // MARK: 예약 상태

    /// 예약해둔 식별자 목록 — 사라진 창(프로바이더 숨김 등)의 예약을 지우기 위해 기억한다.
    /// App Group 파일로 저장한다 — UserDefaults는 프로세스 간 전파가 비동기라,
    /// 위젯이 로그아웃 정리를 할 때 앱이 방금 기록한 id를 못 볼 수 있다.
    private static var idsFileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: ChargeConfig.suite)?
            .appendingPathComponent("reset-alert-ids.json")
    }

    private static var storedIDs: [String] {
        get {
            guard let url = idsFileURL, let data = try? Data(contentsOf: url) else {
                // 구버전 저장 위치 폴백 (다음 기록 때 파일로 이행)
                return ChargeConfig.defaults.stringArray(forKey: "resetAlertIds") ?? []
            }
            return (try? JSONDecoder().decode([String].self, from: data)) ?? []
        }
        set {
            if let url = idsFileURL, let data = try? JSONEncoder().encode(newValue) {
                try? data.write(to: url, options: .atomic)
                ChargeConfig.defaults.removeObject(forKey: "resetAlertIds")
            } else {
                ChargeConfig.defaults.set(newValue, forKey: "resetAlertIds")
            }
        }
    }

    /// 예약 변경(추가·취소)을 한 줄로 세우는 체인 — 겹치는 reschedule/cancel이 서로의
    /// id 기록과 보류 요청을 덮어쓰지 않게 한다. UI 호출은 모두 MainActor에서 오므로
    /// 제출 순서가 곧 실행 순서다.
    @MainActor private static var chain: Task<Void, Never>?

    @MainActor private static func enqueue(_ op: @escaping @MainActor () async -> Void) {
        let prev = chain
        chain = Task {
            await prev?.value
            await op()
        }
    }

    // MARK: 예약 변경

    @MainActor
    static func cancelAll() {
        enqueue { performCancelAll() }
    }

    private static func performCancelAll() {
        let old = storedIDs
        if !old.isEmpty {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: old)
        }
        storedIDs = []
    }

    /// 개별 프로바이더를 끌 때 즉시 반영 — 다음 reschedule을 기다리면
    /// 그 사이 앱이 백그라운드로 가거나 갱신이 실패했을 때 알림이 그대로 울린다
    @MainActor
    static func cancelProvider(id providerID: String) {
        enqueue {
            var ids = storedIDs
            let mine = ids.filter { $0.hasPrefix("reset-\(providerID)#") }
            guard !mine.isEmpty else { return }
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: mine)
            ids.removeAll { mine.contains($0) }
            storedIDs = ids
        }
    }

    /// 매 로드 성공 후 호출. 경고 임계값을 넘긴 창만 예약한다 —
    /// 여유가 많은 창의 리셋은 소음이라 "언제 풀리나"가 궁금한 창만 알린다.
    /// `sessionEpoch`: providers를 조회하기 시작한 시점의 `ChargeAuth.sessionEpoch` —
    /// 로그아웃(또는 계정 전환)을 건너온 늦은 응답이 이전 계정의 알림을 되살리지 못하게 한다.
    @MainActor
    static func reschedule(providers: [Provider], warnThreshold: Double, sessionEpoch: Int) {
        enqueue { await performReschedule(providers: providers, warnThreshold: warnThreshold, sessionEpoch: sessionEpoch) }
    }

    /// 예약할 알림 한 건
    struct PlannedAlert: Equatable {
        let id: String
        let title: String
        let body: String
        let reset: Date
    }

    /// 예약할 알림 목록. 시스템 알림 센터와 무관한 순수 계산이라 로직 테스트가 직접 부른다.
    /// - 화면에서 뺀 오래된 카드(hidingOutdatedCards)의 창은 예약하지 않는다, 보이지 않는 카드의 알림은 설명이 안 된다.
    /// - 리셋 시각이 이미 지난 창(수집 지연으로 남은 낡은 스냅샷)도 예약하지 않는다.
    /// - iOS는 앱당 보류 알림을 64개까지만 유지한다, 초과분은 조용히 버려지므로 임박한 리셋부터 고른다.
    static func plannedAlerts(
        providers: [Provider],
        warnThreshold: Double,
        muted: Set<String>,
        now: Date = Date()
    ) -> [PlannedAlert] {
        var candidates: [PlannedAlert] = []
        for p in providers.hidingOutdatedCards(at: now) where !muted.contains(p.id) {
            var windows: [(slot: String, name: String, window: RateWindow)] = []
            if let s = p.session {
                windows.append(("session", s.label ?? String(localized: "Session"), s))
            }
            if let w = p.weekly {
                windows.append(("weekly", w.label ?? String(localized: "Weekly"), w))
            }
            for e in p.extras ?? [] {
                windows.append(("extra-\(e.name)", e.name, e.window))
            }
            for (slot, name, window) in windows {
                guard window.percent >= warnThreshold,
                      let reset = window.resetDate,
                      reset.timeIntervalSince(now) > 1 else { continue }
                candidates.append(PlannedAlert(
                    id: "reset-\(p.uid)-\(slot)",
                    title: p.name,
                    body: String(localized: "\(name) limit just reset."),
                    reset: reset
                ))
            }
        }
        return Array(candidates.sorted { $0.reset < $1.reset }.prefix(64))
    }

    private static func performReschedule(providers: [Provider], warnThreshold: Double, sessionEpoch: Int) async {
        // 데모 모드에선 예약하지 않고, 남아 있던 실계정 알림도 지운다 —
        // 가짜 리셋 시각으로 울리거나 데모 중에 실계정 알림이 도착하면 안 된다
        guard enabled, ChargeAuth.session != nil, !ChargeConfig.demoMode else {
            performCancelAll()
            return
        }
        // 다른 세션에서 얻은 데이터 — 예약도 취소도 하지 않는다 (다음 로드가 바로잡는다)
        guard sessionEpoch == ChargeAuth.sessionEpoch else { return }
        let center = UNUserNotificationCenter.current()
        let old = storedIDs
        let planned = plannedAlerts(providers: providers, warnThreshold: warnThreshold, muted: mutedProviders)
        let plannedIDs = planned.map(\.id)
        // 사라진 창의 예약을 먼저 제거해 슬롯을 비운다 — 64개가 찬 상태에서 추가부터 하면
        // 새 요청이 조용히 버려진다. 같은 id의 add는 기존 예약을 원자적으로 교체하므로
        // 유지되는 창은 지우지 않아도 임박한 알림이 유실되지 않는다.
        let stale = old.filter { !plannedIDs.contains($0) }
        if !stale.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: stale)
        }
        // add를 await로 완료시킨 뒤에야 id를 기록하고 재확인한다 — 미완료 add가
        // 로그아웃의 cancelAll 뒤에 수리되면 이전 계정의 알림이 남는다
        for c in planned {
            // 앞선 add를 기다리는 사이 리셋이 지났을 수 있다. 지난 리셋은 예약하지 않는다
            // (0 이하 간격의 트리거는 만들 수조차 없다)
            let interval = c.reset.timeIntervalSinceNow
            guard interval > 1 else { continue }
            let content = UNMutableNotificationContent()
            content.title = c.title
            content.body = c.body
            content.sound = .default
            try? await center.add(UNNotificationRequest(
                identifier: c.id,
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(
                    timeInterval: interval,
                    repeats: false
                )
            ))
        }
        storedIDs = plannedIDs
        // 예약하는 사이 로그아웃(다른 프로세스 포함)·토글 꺼짐·데모 진입이 있었으면 되돌린다
        if !enabled || ChargeAuth.session == nil || ChargeConfig.demoMode || ChargeAuth.sessionEpoch != sessionEpoch {
            performCancelAll()
        }
    }
}
