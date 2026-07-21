import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("warnThreshold") private var warnThreshold = 70.0
    @AppStorage("critThreshold") private var critThreshold = 90.0
    @AppStorage("chartDays") private var chartDays = 14

    let generatedAt: Date?

    var body: some View {
        NavigationStack {
            Form {
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

                Section("데이터") {
                    LabeledContent("소스", value: "GitHub Gist")
                    LabeledContent("수집", value: "Mac 수집기 · 5분 간격")
                    if let generatedAt {
                        LabeledContent("마지막 수집", value: generatedAt.formatted(date: .omitted, time: .shortened))
                    }
                }

                Section("정보") {
                    LabeledContent("버전", value: "1.0")
                    LabeledContent("이름의 뜻", value: "충전 + 청구")
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
