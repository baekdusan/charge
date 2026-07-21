import SwiftUI

struct OnboardingView: View {
    var onDone: () -> Void

    @State private var page = 0
    @State private var urlInput = ""
    @State private var validating = false
    @State private var validationError: String?

    var body: some View {
        TabView(selection: $page) {
            introPage.tag(0)
            collectorPage.tag(1)
            connectPage.tag(2)
        }
        .tabViewStyle(.page)
        .indexViewStyle(.page(backgroundDisplayMode: .always))
        .background(ChargeTheme.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .tint(ChargeTheme.accent)
    }

    // 1. 소개
    private var introPage: some View {
        VStack(spacing: 20) {
            Spacer()
            VStack(alignment: .leading, spacing: 14) {
                Capsule().fill(ChargeTheme.accent).frame(width: 150, height: 26)
                Capsule().fill(.white.opacity(0.28)).frame(width: 230, height: 26)
            }
            .padding(.bottom, 12)
            Text("Charge")
                .font(.system(size: 44, weight: .bold, design: .rounded))
            Text("AI 코딩 툴의 세션 한도, 주간 한도,\n오늘 쓴 비용을 iPhone에서 확인하세요.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
            Button("시작하기") { withAnimation { page = 1 } }
                .buttonStyle(.borderedProminent)
                .padding(.bottom, 60)
        }
        .padding()
    }

    // 2. 수집기 안내
    private var collectorPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("1. 데스크톱에 수집기 설치")
                .font(.title2.bold())
                .padding(.top, 60)
            Text("작업하는 컴퓨터에서 사용량을 모아 나의 시크릿 Gist에 올리는 작은 스크립트입니다. 터미널에서:")
                .foregroundStyle(.secondary)
            codeBlock("""
            git clone https://github.com/baekdusan/charge
            cd charge/collector
            cp .env.example .env   # GIST_ID 입력
            node collect.js && ./install.sh
            """)
            Text("자세한 안내는 GitHub README를 참고하세요.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Link("GitHub에서 가이드 보기", destination: URL(string: "https://github.com/baekdusan/charge")!)
                .font(.footnote.bold())
            Spacer()
            HStack {
                Spacer()
                Button("다음") { withAnimation { page = 2 } }
                    .buttonStyle(.borderedProminent)
                Spacer()
            }
            .padding(.bottom, 60)
        }
        .padding(.horizontal, 24)
    }

    // 3. Gist 연결
    private var connectPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("2. Gist 연결")
                .font(.title2.bold())
                .padding(.top, 60)
            Text("수집기가 올리는 Gist의 주소를 붙여넣으세요. gist.github.com 페이지 주소도 됩니다.")
                .foregroundStyle(.secondary)
            TextField("https://gist.github.com/user/abc123...", text: $urlInput)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
            if let validationError {
                Text(validationError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            Spacer()
            HStack {
                Spacer()
                Button {
                    Task { await validateAndSave() }
                } label: {
                    if validating {
                        ProgressView()
                    } else {
                        Text("연결하기")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(urlInput.isEmpty || validating)
                Spacer()
            }
            .padding(.bottom, 60)
        }
        .padding(.horizontal, 24)
    }

    private func codeBlock(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private func validateAndSave() async {
        guard let url = ChargeConfig.normalizeGistURL(urlInput) else {
            validationError = "Gist 주소 형식이 아닙니다."
            return
        }
        validating = true
        defer { validating = false }
        ChargeConfig.gistRawURL = url
        do {
            _ = try await ChargeAPI.fetchAll()
            validationError = nil
            onDone()
        } catch {
            ChargeConfig.gistRawURL = nil
            validationError = "데이터를 불러오지 못했어요. 수집기가 업로드를 했는지, 주소가 맞는지 확인해주세요."
        }
    }
}
