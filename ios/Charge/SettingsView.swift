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

                Section {
                    TextField("Gist URL", text: $gistInput)
                        .font(.footnote.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button(gistSaved ? "Saved ✓" : "Save URL") {
                        if let url = ChargeConfig.normalizeGistURL(gistInput) {
                            ChargeConfig.gistRawURL = url
                            gistInput = url.absoluteString
                            gistSaved = true
                        }
                    }
                    .disabled(ChargeConfig.normalizeGistURL(gistInput) == nil)
                    if let generatedAt {
                        LabeledContent("Last collected", value: generatedAt.formatted(date: .omitted, time: .shortened))
                    }
                } header: {
                    Text("Data source")
                } footer: {
                    Text("The secret Gist your desktop collector uploads to.")
                }

                Section("About") {
                    LabeledContent("Version", value: "1.0")
                    LabeledContent("Name", value: "charge = battery + billing")
                    Link("GitHub repository", destination: URL(string: "https://github.com/baekdusan/charge")!)
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
        }
        .preferredColorScheme(.dark)
        .tint(ChargeTheme.accent)
    }
}
