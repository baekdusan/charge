import SwiftUI
import AuthenticationServices

/// 첫 실행 셋업: Apple 로그인 → 페어링 코드 → `npx charge-connect <코드>` 한 줄.
struct OnboardingView: View {
    @State private var signedIn = ChargeAuth.session != nil
    @State private var pairingCode: String?
    @State private var issuingCode = false
    @State private var codeError: String?
    @State private var testing = false
    @State private var connectionCheckInFlight = false
    @State private var lastCheckFailed = false
    @State private var message: String?
    /// 가이드를 연 시점의 디바이스 목록 — "새" 기기가 추가돼야만 연결 성공으로 판정한다
    /// (이미 데이터가 있는 계정이 두 번째 컴퓨터를 페어링할 때 기존 데이터로 즉시 닫히는 것 방지)
    @State private var baselineDeviceIDs: Set<String>?
    /// 설정의 "다른 컴퓨터 페어링"은 true(새 기기 필수), 첫 실행 온보딩은 false —
    /// 재로그인한 기존 계정은 이미 연결된 기기만으로 바로 통과해야 한다
    var requiresNewDevice = true
    var onConnected: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if signedIn {
                        pairingView
                    } else {
                        welcome
                    }
                }
                .padding()
            }
            .refreshable {
                guard signedIn else { return }
                _ = await checkAccountData(showProgress: false, showFailure: true)
            }
            .background(ChargeTheme.background.ignoresSafeArea())
            .navigationTitle("Setup")
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
        .tint(ChargeTheme.accent)
        .task(id: signedIn) {
            guard signedIn else { return }
            // 기존 기기만으로 통과하는 모드에선 baseline이 쓰이지 않는다 — 조회 한 번을 아낀다
            if requiresNewDevice { await captureBaseline() }
            // 성공 폴링은 3초, 실패(네트워크·인증)가 이어지면 30초까지 백오프 —
            // 죽은 세션으로 3초마다 refresh를 시도하면 Auth rate limit에 걸린다
            var delaySeconds: Double = 3
            while !Task.isCancelled {
                if ChargeAuth.session == nil {
                    // 세션이 폐기됨(refresh 영구 실패) — 로그인 화면으로 복귀
                    signedIn = false
                    pairingCode = nil
                    return
                }
                if await checkAccountData(showProgress: false, showFailure: false) {
                    return
                }
                delaySeconds = lastCheckFailed ? min(delaySeconds * 2, 30) : 3
                do {
                    try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                } catch {
                    return
                }
            }
        }
    }

    // MARK: 로그인

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("⚡ Welcome to Charge")
                .font(.title2.bold())
            Text("See your AI coding usage on your iPhone. Sign in, run one command on your computer, done.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            SignInWithAppleButton(.signIn) { req in
                req.requestedScopes = [.email]
            } onCompletion: { result in
                handleAppleResult(result)
            }
            .signInWithAppleButtonStyle(.white)
            .frame(height: 48)
            Button {
                // setDemoMode가 캐시 정리·위젯 리로드까지 함께 처리한다
                ChargeConfig.setDemoMode(true)
                onConnected()
            } label: {
                Text("Browse the demo")
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.bordered)
            Text("Sample data only — sign in anytime to see your real usage.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func handleAppleResult(_ result: Result<ASAuthorization, Error>) {
        guard case .success(let auth) = result,
              let cred = auth.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = cred.identityToken,
              let idToken = String(data: tokenData, encoding: .utf8) else {
            message = String(localized: "Sign in failed. Please try again.")
            return
        }
        Task {
            do {
                try await ChargeAuth.signIn(appleIDToken: idToken)
                message = nil
                codeError = nil
                signedIn = true
            } catch {
                message = String(localized: "Sign in failed. Please try again.")
            }
        }
    }

    // MARK: 페어링

    private var pairingView: some View {
        Group {
            StepCard(number: 1, title: "Install Node.js") {
                Text("If you don’t have Node.js yet, install the LTS from nodejs.org.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Link(destination: URL(string: "https://nodejs.org")!) {
                    Label("nodejs.org", systemImage: "arrow.up.right.square")
                        .font(.footnote.bold())
                }
            }
            StepCard(number: 2, title: "Run the pairing command") {
                Text("Paste this into Terminal (Mac: ⌘ + Space → “Terminal”, Windows: Win + X → “Terminal”).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let pairingCode {
                    TerminalBlock(prompt: "$", lines: ["npx charge-connect \(pairingCode)"])
                    HStack {
                        Text("The code expires in 10 minutes.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("New code") { Task { await issueCode() } }
                            .font(.caption.bold())
                    }
                } else if let codeError {
                    // 발급 실패 — 스피너를 계속 돌리지 않고 원인 + 재시도 버튼을 보여준다
                    Text(codeError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button("Retry") { Task { await issueCode() } }
                        .font(.caption.bold())
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .task { await issueCode() }
                }
            }
            StepCard(number: 3, title: "Connect this app") {
                // 백그라운드 폴링이 조용히 돌고 있다는 것을 계속 보여준다 —
                // 인디케이터가 없으면 연결될 때까지 멈춘 화면처럼 보인다
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(connectionCheckInFlight ? "Checking now…" : "Waiting for your computer to connect…")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                }
                .animation(.default, value: connectionCheckInFlight)
                Text("It checks every few seconds and opens Charge as soon as your PC connects. Pull down to check now.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Button {
                    Task {
                        _ = await checkAccountData(showProgress: true, showFailure: true)
                    }
                } label: {
                    if testing {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text("Test connection")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(testing)
                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Button("Sign out") {
                ChargeAuth.signOut()
                signedIn = false
                pairingCode = nil
                // 이전 시도의 에러가 남으면 재로그인 후 자동 코드 발급이 막힌다
                codeError = nil
                message = nil
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private func issueCode() async {
        guard !issuingCode else { return }
        issuingCode = true
        codeError = nil
        defer { issuingCode = false }
        pairingCode = try? await ChargeAuth.createPairingCode()
        if pairingCode == nil {
            if ChargeAuth.session == nil {
                // refresh 영구 실패로 세션이 지워짐 — 로그인 화면으로 복귀
                signedIn = false
            } else {
                codeError = String(localized: "Couldn't get a code. Check your connection and retry.")
            }
        }
    }

    /// 기준선: 가이드를 연 시점에 이미 존재하던 디바이스들.
    /// 조회 실패 시 기준선을 비워두지 않고 nil로 남겨 다음 폴링에서 재시도한다
    /// (빈 기준선으로 오인하면 기존 디바이스가 전부 "새 기기"로 보여 가이드가 잘못 닫힌다)
    private func captureBaseline() async {
        guard baselineDeviceIDs == nil else { return }
        if let payload = try? await ChargeAPI.fetchAll() {
            baselineDeviceIDs = Set((payload.devices ?? []).map(\.id))
        }
    }

    @discardableResult
    private func checkAccountData(showProgress: Bool, showFailure: Bool) async -> Bool {
        guard !connectionCheckInFlight else { return false }
        connectionCheckInFlight = true
        if showProgress { testing = true }
        defer {
            connectionCheckInFlight = false
            if showProgress { testing = false }
        }

        if requiresNewDevice, baselineDeviceIDs == nil { await captureBaseline() }
        if requiresNewDevice, baselineDeviceIDs == nil {
            lastCheckFailed = true
            if showFailure {
                message = String(localized: "No data yet — run the command above, wait a moment, and try again.")
            }
            return false
        }
        do {
            let devices = try await ChargeAPI.fetchAll().devices ?? []
            lastCheckFailed = false
            let baseline = baselineDeviceIDs ?? []
            let connected = requiresNewDevice
                ? devices.contains { !baseline.contains($0.id) }
                : !devices.isEmpty
            if connected {
                message = nil
                onConnected()
                return true
            }
            if showFailure {
                message = String(localized: "No data yet — run the command above, wait a moment, and try again.")
            }
        } catch {
            lastCheckFailed = true
            if showFailure {
                message = String(localized: "Couldn't reach the server. Check your connection and try again.")
            }
        }
        return false
    }
}

// MARK: - 구성 요소

/// 번호 배지 + 제목 + 내용 카드
private struct StepCard<Content: View>: View {
    let number: Int
    let title: LocalizedStringKey
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("\(number)")
                    .font(.caption.bold().monospacedDigit())
                    .frame(width: 24, height: 24)
                    .background(ChargeTheme.accent.opacity(0.2), in: Circle())
                    .foregroundStyle(ChargeTheme.accent)
                Text(title)
                    .font(.headline)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(ChargeTheme.card, in: RoundedRectangle(cornerRadius: 16))
    }
}

/// 터미널풍 명령어 블록 — 복사 버튼 포함
private struct TerminalBlock: View {
    let prompt: String
    let lines: [String]
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                ForEach([Color.red, .yellow, .green], id: \.self) {
                    Circle().fill($0.opacity(0.8)).frame(width: 8, height: 8)
                }
                Spacer()
                Button {
                    UIPasteboard.general.string = lines.joined(separator: "\n")
                    copied = true
                } label: {
                    Label(copied ? "Copied ✓" : "Copy", systemImage: "doc.on.doc")
                        .font(.caption2)
                }
            }
            ForEach(lines, id: \.self) { line in
                HStack(alignment: .top, spacing: 6) {
                    Text(prompt)
                        .foregroundStyle(ChargeTheme.accent)
                    Text(line)
                        .textSelection(.enabled)
                }
                .font(.caption.monospaced())
            }
        }
        .padding(12)
        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
    }
}
