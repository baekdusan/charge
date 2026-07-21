import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("warnThreshold") private var warnThreshold = 70.0
    @AppStorage("critThreshold") private var critThreshold = 90.0
    @AppStorage("chartDays") private var chartDays = 14
    @State private var hidden = ChargeConfig.hiddenProviders
    @State private var gistInput = ChargeConfig.gistRawURL?.absoluteString ?? ""
    @State private var gistSaved = false

    let generatedAt: Date?
    var providers: [Provider] = []

    var body: some View {
        NavigationStack {
            Form {
                if !providers.isEmpty {
                    Section {
                        ForEach(providers) { p in
                            Toggle(p.name, isOn: Binding(
                                get: { !hidden.contains(p.id) },
                                set: { on in
                                    if on { hidden.remove(p.id) } else { hidden.insert(p.id) }
                                    ChargeConfig.hiddenProviders = hidden
                                }
                            ))
                        }
                    } header: {
                        Text("프로바이더")
                    } footer: {
                        Text("끄면 앱과 위젯에서 숨겨집니다. 새 프로바이더 추가는 데스크톱 수집기에서 이루어집니다 — 수집기가 감지한 도구가 이 목록에 자동으로 나타납니다.")
                    }
                }

                Section {
                    VStack(alignment: .leading) {
                        Text("경고 (주황) — \(Int(warnThreshold))%")
                        Slider(value: $warnThreshold, in: 50...90, step: 5)
                            .tint(.orange)
                    }
                    VStack(alignment: .leading) {
                        Text("위험 (빨강) — \(Int(critThreshold))%")
                        Slider(value: $critThreshold, in: 70...100, step: 5)
                            .tint(.red)
                    }
                } header: {
                    Text("게이지 색상 임계값")
                } footer: {
                    Text("사용률이 임계값을 넘으면 게이지 색이 바뀝니다.")
                }

                Section("차트") {
                    Picker("표시 기간", selection: $chartDays) {
                        Text("7일").tag(7)
                        Text("14일").tag(14)
                        Text("30일").tag(30)
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    TextField("Gist 주소", text: $gistInput)
                        .font(.footnote.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button(gistSaved ? "저장됨 ✓" : "주소 저장") {
                        if let url = ChargeConfig.normalizeGistURL(gistInput) {
                            ChargeConfig.gistRawURL = url
                            gistInput = url.absoluteString
                            gistSaved = true
                        }
                    }
                    .disabled(ChargeConfig.normalizeGistURL(gistInput) == nil)
                    if let generatedAt {
                        LabeledContent("마지막 수집", value: generatedAt.formatted(date: .omitted, time: .shortened))
                    }
                } header: {
                    Text("데이터 소스")
                } footer: {
                    Text("데스크톱 수집기가 업로드하는 시크릿 Gist 주소입니다.")
                }

                Section("정보") {
                    LabeledContent("버전", value: "1.0")
                    LabeledContent("이름의 뜻", value: "충전 + 청구")
                    Link("GitHub 저장소", destination: URL(string: "https://github.com/baekdusan/charge")!)
                }
            }
            .navigationTitle("설정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("완료") { dismiss() }
                }
            }
            .scrollContentBackground(.hidden)
            .background(ChargeTheme.background.ignoresSafeArea())
        }
        .preferredColorScheme(.dark)
        .tint(ChargeTheme.accent)
    }
}
