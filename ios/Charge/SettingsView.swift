import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("warnThreshold") private var warnThreshold = 70.0
    @AppStorage("critThreshold") private var critThreshold = 90.0
    @AppStorage("chartDays") private var chartDays = 14
    @State private var hidden = ChargeConfig.hiddenProviders
    @State private var showGuide = false
    @State private var accountRefresh = 0

    let generatedAt: Date?
    var providers: [Provider] = []

    /// 페이로드의 프로바이더 + 과거에 관측했지만 지금은 빠진 프로바이더.
    /// 숨겼거나 수집이 잠시 실패해도 토글이 목록에서 사라지지 않는다.
    private var providerRows: [(id: String, name: String)] {
        // 계정별 카드가 여러 개여도 표시 토글은 프로바이더당 하나
        var seen = Set<String>()
        var rows = providers.compactMap { p in
            seen.insert(p.id).inserted ? (id: p.id, name: p.name) : nil
        }
        let missing = ChargeConfig.knownProviders
            .filter { id, _ in !seen.contains(id) }
            .sorted { $0.key < $1.key }
        rows.append(contentsOf: missing.map { (id: $0.key, name: $0.value) })
        return rows
    }

    var body: some View {
        NavigationStack {
            Form {
                if !providerRows.isEmpty {
                    Section {
                        ForEach(providerRows, id: \.id) { p in
                            Toggle(p.name, isOn: Binding(
                                get: { !hidden.contains(p.id) },
                                set: { on in
                                    if on { hidden.remove(p.id) } else { hidden.insert(p.id) }
                                    ChargeConfig.hiddenProviders = hidden
                                }
                            ))
                        }
                    } header: {
                        Text("Providers")
                    } footer: {
                        Text("Hidden providers disappear from the app and widgets. New tools are detected by the desktop collector and appear here automatically.")
                    }
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
                    Section("Account") {
                        if let session = ChargeAuth.session {
                            LabeledContent("Signed in", value: session.email ?? "Apple ID")
                            Button("Pair another computer") { showGuide = true }
                            Button("Sign out", role: .destructive) {
                                ChargeAuth.signOut()
                                accountRefresh += 1
                            }
                        } else {
                            Button("Sign in") { showGuide = true }
                        }
                    }
                    .id(accountRefresh)
                }

                Section {
                    Button("Setup guide") { showGuide = true }
                }

                Section {
                    LabeledContent("Version", value: "1.0")
                    LabeledContent("Name", value: "charge = battery + billing")
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
                OnboardingView { showGuide = false }
            }
        }
        .preferredColorScheme(.dark)
        .tint(ChargeTheme.accent)
    }
}
