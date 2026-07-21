import SwiftUI
import AuthenticationServices

/// 첫 실행 셋업: Apple 로그인 → 페어링 코드 → `npx charge-collector <코드>` 한 줄.
struct OnboardingView: View {
    @State private var signedIn = ChargeAuth.session != nil
    @State private var pairingCode: String?
    @State private var testing = false
    @State private var connectionCheckInFlight = false
    @State private var message: String?
    /// 가이드를 연 시점의 디바이스 목록 — "새" 기기가 추가돼야만 연결 성공으로 판정한다
    /// (이미 데이터가 있는 계정이 두 번째 컴퓨터를 페어링할 때 기존 데이터로 즉시 닫히는 것 방지)
    @State private var baselineDeviceIDs: Set<String>?
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
            await captureBaseline()
            while !Task.isCancelled {
                if await checkAccountData(showProgress: false, showFailure: false) {
                    return
                }
                do {
                    try await Task.sleep(nanoseconds: 3_000_000_000)
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
                    TerminalBlock(prompt: "$", lines: ["npx charge-collector \(pairingCode)"])
                    HStack {
                        Text("The code expires in 10 minutes.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("New code") { Task { await issueCode() } }
                            .font(.caption.bold())
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .task { await issueCode() }
                }
            }
            StepCard(number: 3, title: "Connect this app") {
                Text("It checks every few seconds and opens Charge as soon as your PC connects. Pull down to check now.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private func issueCode() async {
        pairingCode = try? await ChargeAuth.createPairingCode()
        if pairingCode == nil {
            message = String(localized: "Sign in failed. Please try again.")
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

        if baselineDeviceIDs == nil { await captureBaseline() }
        guard let baseline = baselineDeviceIDs else {
            if showFailure {
                message = String(localized: "No data yet — run the command above, wait a moment, and try again.")
            }
            return false
        }
        if let payload = try? await ChargeAPI.fetchAll(),
           let devices = payload.devices,
           devices.contains(where: { !baseline.contains($0.id) }) {
            message = nil
            onConnected()
            return true
        } else {
            if showFailure {
                message = String(localized: "No data yet — run the command above, wait a moment, and try again.")
            }
            return false
        }
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
