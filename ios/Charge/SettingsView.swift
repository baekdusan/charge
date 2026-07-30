import SwiftUI
import StoreKit
import WidgetKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.requestReview) private var requestReview
    @AppStorage("warnThreshold") private var warnThreshold = 70.0
    @AppStorage("critThreshold") private var critThreshold = 90.0
    @AppStorage("chartDays") private var chartDays = 14
    @State private var hidden = ChargeConfig.hiddenProviders
    @State private var showGuide = false
    @State private var accountRefresh = 0
    @State private var showDeleteConfirm = false
    @State private var deleteError: String?
    @State private var deviceToRemove: CollectorDevice?
    @State private var showUnpairConfirm = false
    @State private var removedDeviceIDs: Set<String> = []
    @State private var deviceError: String?
    @State private var resetAlerts = ResetNotifications.enabled
    @State private var mutedAlerts = ResetNotifications.mutedProviders
    @State private var notifPermissionDenied = false

    let generatedAt: Date?
    var providers: [Provider] = []
    var devices: [CollectorDevice] = []

    /// providers/devices 스냅샷을 조회한 시점의 세션 세대 — 부모가 페이로드와 함께 전달한다.
    /// 이 뷰에서 자체 계산하면 뷰 재생성 시 새 계정의 epoch가 이전 계정의 스냅샷에 붙는다.
    var snapshotEpoch: Int = 0

    /// 이 화면에서 새로 페어링하거나 기기를 지우면 부모 스냅샷 대신 직접 받아온 목록을 쓴다
    @State private var refreshedDevices: [CollectorDevice]?
    @State private var refreshedProviders: [Provider]?
    @State private var refreshedEpoch: Int?

    /// 이 화면에서 연결 해제한 기기는 목록에서 바로 뺀다 (부모 갱신은 시트 닫힐 때)
    private var visibleDevices: [CollectorDevice] {
        (refreshedDevices ?? devices)
            .filter { !removedDeviceIDs.contains($0.id) }
            .sorted { ($0.shortLabel ?? "", $0.id) < ($1.shortLabel ?? "", $1.id) }
    }

    /// 이 화면에서 갱신된 스냅샷이 있으면 부모의 (더 오래된) 스냅샷보다 우선한다 —
    /// 로그아웃 후에도 부모 값으로 폴백하면 이전 계정의 프로바이더가 그대로 노출된다
    private var effectiveProviders: [Provider] { refreshedProviders ?? providers }

    /// 페이로드의 프로바이더 + 과거에 관측했지만 지금은 빠진 프로바이더.
    /// 숨겼거나 수집이 잠시 실패해도 토글이 목록에서 사라지지 않는다.
    /// 드래그로 정한 순서를 그대로 따른다 — 메인 화면·위젯과 같은 정렬 헬퍼를 쓴다.
    private var providerRows: [(id: String, name: String)] {
        // 계정별 카드가 여러 개여도 표시 토글은 프로바이더당 하나
        var seen = Set<String>()
        var rows = effectiveProviders.compactMap { p in
            seen.insert(p.id).inserted ? (id: p.id, name: p.name) : nil
        }
        let missing = ChargeConfig.knownProviders
            .filter { id, _ in !seen.contains(id) }
            .sorted { $0.key < $1.key }
        rows.append(contentsOf: missing.map { (id: $0.key, name: $0.value) })
        return ChargeConfig.sortedByUserOrder(rows, id: \.id)
    }

    var body: some View {
        // 렌더당 한 번만 계산 — 이 목록은 토글·드래그마다 재평가되는 경로다
        let rows = providerRows
        return NavigationStack {
            Form {
                if ChargeConfig.demoMode {
                    Section {
                        Button("Exit demo mode") {
                            ChargeConfig.setDemoMode(false)
                            dismiss()
                        }
                    } footer: {
                        Text("You're viewing sample data. Exit to sign in and see your own usage.")
                    }
                }

                if !rows.isEmpty {
                    Section {
                        ForEach(rows, id: \.id) { p in
                            Toggle(p.name, isOn: Binding(
                                get: { !hidden.contains(p.id) },
                                set: { on in
                                    if on { hidden.remove(p.id) } else { hidden.insert(p.id) }
                                    ChargeConfig.hiddenProviders = hidden
                                    // 숨김/해제를 알림 예약에도 즉시 반영 — 다음 로드 성공을
                                    // 기다리면 그 사이 숨긴 프로바이더의 알림이 그대로 울린다
                                    if on {
                                        rescheduleAlerts()
                                    } else {
                                        ResetNotifications.cancelProvider(id: p.id)
                                    }
                                }
                            ))
                        }
                        .onMove { source, destination in
                            var ids = rows.map(\.id)
                            ids.move(fromOffsets: source, toOffset: destination)
                            ChargeConfig.providerOrder = ids
                            accountRefresh += 1  // 재렌더 트리거 (rows가 저장소를 읽으므로)
                            // 위젯도 같은 순서를 쓴다 — 닫기를 기다리지 않고 즉시 반영
                            WidgetCenter.shared.reloadAllTimelines()
                        }
                    } header: {
                        HStack {
                            Text("Providers")
                            Spacer()
                            if rows.count > 1 {
                                EditButton()
                                    .font(.caption)
                                    .textCase(nil)
                            }
                        }
                    } footer: {
                        Text("Toggles hide a provider from the app and widgets. Tap Edit to drag them into your preferred order. New tools appear here automatically.")
                    }
                }

                Section {
                    Toggle("Limit reset notifications", isOn: $resetAlerts)
                    if resetAlerts {
                        ForEach(rows, id: \.id) { p in
                            Toggle(p.name, isOn: Binding(
                                get: { !mutedAlerts.contains(p.id) },
                                set: { on in
                                    if on { mutedAlerts.remove(p.id) } else { mutedAlerts.insert(p.id) }
                                    ResetNotifications.mutedProviders = mutedAlerts
                                    if on {
                                        // 다시 켜면 현재 페이로드 기준으로 즉시 예약 복구
                                        rescheduleAlerts()
                                    } else {
                                        // 시트를 닫기 전에 백그라운드로 가도 울리지 않게 즉시 취소
                                        ResetNotifications.cancelProvider(id: p.id)
                                    }
                                }
                            ))
                        }
                    }
                } header: {
                    Text("Notifications")
                } footer: {
                    if notifPermissionDenied {
                        Text("Notifications are turned off in iOS Settings. Allow them for Charge to use this.")
                            .foregroundStyle(.red)
                    } else {
                        Text("Notifies when a rate window past the warning threshold resets. Reset times update whenever the app refreshes.")
                    }
                }
                .onChange(of: resetAlerts) { _, on in
                    if on {
                        Task {
                            let granted = await ResetNotifications.requestPermission()
                            // 권한 확인 중에 토글을 도로 껐으면 늦은 결과를 적용하지 않는다
                            guard resetAlerts else { return }
                            if granted {
                                notifPermissionDenied = false
                                ResetNotifications.enabled = true
                                // 켠 직후 바로 백그라운드로 가도 알림이 잡혀 있게 즉시 예약
                                rescheduleAlerts()
                            } else {
                                notifPermissionDenied = true
                                resetAlerts = false
                            }
                        }
                    } else {
                        ResetNotifications.enabled = false
                        ResetNotifications.cancelAll()
                    }
                }
                .onChange(of: warnThreshold) { _, _ in
                    // 임계값을 바꾸면 예약 대상 창이 달라진다 — 다음 로드를 기다리지 않고 즉시 반영
                    if resetAlerts { rescheduleAlerts() }
                }

                Section {
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Warning (orange)")
                            Spacer()
                            Text("\(Int(warnThreshold))%")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $warnThreshold, in: 50...90, step: 5)
                            .tint(.orange)
                    }
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Critical (red)")
                            Spacer()
                            Text("\(Int(critThreshold))%")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $critThreshold, in: 70...100, step: 5)
                            .tint(.red)
                    }
                } header: {
                    Text("Gauge color thresholds")
                } footer: {
                    Text("Gauge colors change when usage crosses these thresholds.")
                }

                Section("Chart") {
                    Picker("Period", selection: $chartDays) {
                        Text("7d").tag(7)
                        Text("14d").tag(14)
                        Text("30d").tag(30)
                    }
                    .pickerStyle(.segmented)
                }

                if let generatedAt {
                    Section {
                        LabeledContent("Last collected", value: generatedAt.formatted(date: .omitted, time: .shortened))
                    }
                }

                if ChargeAuth.cloud != nil {
                    Section {
                        if let session = ChargeAuth.session {
                            LabeledContent("Signed in", value: session.email ?? "Apple ID")
                            Button("Sign out", role: .destructive) {
                                ChargeAuth.signOut()
                                resetAccountLocalState()
                            }
                            Button("Delete account", role: .destructive) { showDeleteConfirm = true }
                        } else {
                            Button("Sign in") { showGuide = true }
                        }
                    } header: {
                        Text("Account")
                    } footer: {
                        if let deleteError {
                            Text(deleteError)
                                .foregroundStyle(.red)
                        }
                    }
                    .id(accountRefresh)

                    if ChargeAuth.session != nil {
                        Section {
                            // 각 기기가 독립된 Form 행이어야 스와이프 해제가 기기별로 동작한다 —
                            // TimelineView는 행 안쪽에 둬서 추적 점·상대 시각만 30초마다 다시 그린다
                            ForEach(visibleDevices) { device in
                                TimelineView(.periodic(from: .now, by: 30)) { timeline in
                                    deviceRow(device, now: timeline.date)
                                }
                            }
                            Button("Pair another computer") { showGuide = true }
                        } header: {
                            Text("Connected computers")
                        } footer: {
                            if let deviceError {
                                Text(deviceError)
                                    .foregroundStyle(.red)
                            } else if !visibleDevices.isEmpty {
                                Text("Green means the collector uploaded within the last few minutes. Swipe left to unpair a computer.")
                            }
                        }
                    }
                }

                Section {
                    Button("Setup guide") { showGuide = true }
                }

                Section {
                    LabeledContent("Version", value: "1.0")
                    // 시스템 별점 시트 (표시 여부는 iOS가 결정) — 앱스토어 등록 후
                    // ...?action=write-review 딥링크로 바꾸면 항상 리뷰 화면이 열린다
                    Button("Enjoying Charge? Leave a review") { requestReview() }
                    Link("GitHub repository", destination: URL(string: "https://github.com/baekdusan/charge")!)
                } header: {
                    Text("About")
                } footer: {
                    Text("Not affiliated with Anthropic, OpenAI, or any AI provider. Their marks identify data sources only.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .scrollContentBackground(.hidden)
            .background(ChargeTheme.background.ignoresSafeArea())
            .sheet(isPresented: $showGuide) {
                OnboardingView {
                    showGuide = false
                    // 새로 페어링된 기기가 부모 갱신 전에도 목록에 바로 보이게 다시 조회
                    Task {
                        if let fresh = try? await ChargeAPI.fetchAll().devices {
                            refreshedDevices = fresh
                        }
                    }
                }
            }
            .alert("Unpair this computer?", isPresented: $showUnpairConfirm, presenting: deviceToRemove) { device in
                Button("Unpair", role: .destructive) { unpair(device) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Usage history uploaded by this computer will also be deleted. Its collector stops syncing until you pair it again.")
            }
            .alert("Delete your account?", isPresented: $showDeleteConfirm) {
                Button("Delete", role: .destructive) { deleteAccount() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your account and all synced usage data are permanently deleted from the server. This cannot be undone.")
            }
        }
        .preferredColorScheme(.dark)
        .tint(ChargeTheme.accent)
        .task {
            // iOS 설정에서 권한을 회수했으면 토글이 켜진 것처럼 보이며
            // 전달 안 되는 알림을 계속 예약하는 상태를 바로잡는다
            if ResetNotifications.enabled, !(await ResetNotifications.permissionGranted()) {
                ResetNotifications.enabled = false
                ResetNotifications.cancelAll()
                resetAlerts = false
                notifPermissionDenied = true
            }
        }
    }

    private func deviceRow(_ device: CollectorDevice, now: Date) -> some View {
        let isTracking = device.isTracking(at: now)
        return HStack(spacing: 10) {
            Circle()
                .fill(device.lastSeenDate == nil ? Color.secondary : isTracking ? .green : .orange)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.shortLabel ?? String(localized: "Linked PC"))
                if let seen = device.lastSeenDate {
                    Text(seen.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Never synced")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .swipeActions {
            Button("Unpair", role: .destructive) {
                deviceToRemove = device
                showUnpairConfirm = true
            }
        }
    }

    /// 로그아웃·계정 삭제 공통: 계정에 귀속된 이 화면의 로컬 상태 리셋.
    /// nil이 아니라 빈 목록으로 — nil이면 visibleDevices가 이전 계정의
    /// 부모 스냅샷으로 폴백해 옛 기기 목록과 해제 버튼이 그대로 노출된다.
    private func resetAccountLocalState() {
        mutedAlerts = []
        refreshedDevices = []
        refreshedProviders = []
        refreshedEpoch = nil
        removedDeviceIDs = []
        deviceError = nil
        accountRefresh += 1
    }

    private func deleteAccount() {
        deleteError = nil
        Task {
            do {
                try await ChargeAuth.deleteAccount()
                resetAccountLocalState()
            } catch {
                deleteError = String(localized: "Couldn't delete your account. Check your connection and try again.")
            }
        }
    }

    private func unpair(_ device: CollectorDevice) {
        deviceError = nil
        Task {
            do {
                try await ChargeAPI.deleteDevice(id: device.id)
                removedDeviceIDs.insert(device.id)
                // cascade로 프로바이더 행이 지워졌을 수 있다 — 남은 목록 기준으로 알림 재예약
                let epoch = ChargeAuth.sessionEpoch
                do {
                    let payload = try await ChargeAPI.fetchAll()
                    refreshedDevices = payload.devices
                    // 삭제 후 스냅샷을 유지해 이후의 토글/임계값 변경도 최신 목록으로 예약하게 한다
                    refreshedProviders = payload.providers ?? []
                    refreshedEpoch = epoch
                    rescheduleAlerts(with: payload.providers ?? [], epoch: epoch)
                } catch is CancellationError {
                    // 뒤이은 다른 삭제/전환이 이 조회를 무효화했다 — 그쪽 결과가 최신이므로
                    // 여기서 예약을 건드리면 방금 갱신된 알림을 지울 수 있다. 아무것도 안 한다.
                } catch {
                    // 남은 프로바이더를 알 수 없으면 일단 전부 취소하고, 이 화면의 스냅샷도
                    // 빈 것으로 교체한다 — 이후의 토글/임계값 변경이 삭제 전 목록으로
                    // 예약을 되살리지 못하게 (다음 성공 로드가 새 스냅샷을 채운다)
                    ResetNotifications.cancelAll()
                    refreshedProviders = []
                    refreshedEpoch = epoch
                }
            } catch {
                deviceError = String(localized: "Couldn't unpair. Check your connection and try again.")
            }
        }
    }

    /// 숨김 필터 + epoch까지 포함한 재예약 한 줄 헬퍼 (콜사이트 5곳 공용).
    /// epoch 기본값은 이 화면이 열릴 때의 세대 — 시트가 떠 있는 동안 계정이 바뀌면
    /// 이전 계정의 providers 스냅샷으로 예약하려는 호출이 자동으로 무시된다.
    private func rescheduleAlerts(with list: [Provider]? = nil, epoch: Int? = nil) {
        ResetNotifications.reschedule(
            providers: (list ?? refreshedProviders ?? providers).filter { !hidden.contains($0.id) },
            warnThreshold: warnThreshold,
            sessionEpoch: epoch ?? refreshedEpoch ?? snapshotEpoch
        )
    }
}
