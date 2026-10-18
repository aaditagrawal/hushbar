import DeviceRuntime
import SwiftUI
import DeviceProtocol

struct EqualizerEditor: View {
    @Bindable var session: DeviceSession
    let advanced: Bool
    @ViewState private var draft: EqualizerProfile?
    private var stored: EqualizerProfile? { advanced ? session.state.advancedBands : session.state.customEQ }
    private var active: Bool { advanced ? session.state.advancedEQ == true : session.state.eq == 5 && session.state.advancedEQ != true }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !active {
                Text(advanced ? "Select Advanced to adjust all eight bands." : "Select Custom to adjust bass, mid and treble.").font(.callout).foregroundStyle(.secondary)
                Button(advanced ? "Use Advanced EQ" : "Use Custom EQ") { session.setEQ(advanced ? 6 : 5) }.buttonStyle(.borderedProminent).disabled(!session.pending.isEmpty)
            }
            if let draft {
                PanelSection(advanced ? "Band gain" : "Tone") {
                    VStack(spacing: advanced ? 7 : 14) {
                        ForEach(indices(draft), id: \.self) { index in
                            gainRow(index, draft)
                        }
                    }.padding(.top, 6)
                }.disabled(!active || !session.pending.isEmpty)
                if advanced {
                    DisclosureGroup("Frequency and Q") {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(draft.bands.indices, id: \.self) { index in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Band \(index + 1)").font(.caption).foregroundStyle(.secondary)
                                    parameterSlider(index, frequency: true)
                                    parameterSlider(index, frequency: false)
                                }
                            }
                        }.padding(.top, 8)
                    }.disabled(!active || !session.pending.isEmpty)
                }
                HStack {
                    Button("Reset to flat") {
                        var flat = draft
                        for i in flat.bands.indices { flat.bands[i].gain = 0 }
                        if !advanced { flat.totalGain = -0.0 }
                        self.draft = flat
                        session.setEqualizer(flat, advanced: advanced)
                    }.disabled(!active || !session.pending.isEmpty)
                    Spacer()
                    if !session.pending.isEmpty { ProgressView().controlSize(.small) }
                }
                Text("Changes apply when you release a slider.").font(.caption).foregroundStyle(.secondary)
            } else {
                if session.pending.contains("eqLoad") || session.error == nil {
                    HStack { ProgressView().controlSize(.small); Text("Reading EQ bands…") }.padding(.vertical, 24)
                } else {
                    Label("EQ bands unavailable. Read from device to retry.", systemImage: "slider.horizontal.3")
                        .font(.callout).foregroundStyle(.secondary).padding(.vertical, 16)
                }
            }
            Button("Read from device") { Task { await session.loadEqualizer(advanced: advanced) } }.disabled(!session.pending.isEmpty)
        }
        .onAppear { draft = stored }
        .onChange(of: stored) { _, value in draft = value }
        .task(id: active) { await session.loadEqualizer(advanced: advanced) }
    }
    private func indices(_ profile: EqualizerProfile) -> [Int] {
        advanced ? Array(profile.bands.indices) : [UInt8(0), 1, 2].compactMap { filter in profile.bands.firstIndex { $0.filter == filter } }
    }
    private func gainRow(_ index: Int, _ profile: EqualizerProfile) -> some View {
        VStack(spacing: 1) {
            HStack {
                Text(advanced ? frequencyLabel(profile.bands[index].frequency) : [UInt8(0): "Bass", 1: "Mid", 2: "Treble"][profile.bands[index].filter] ?? "Band")
                Spacer()
                Text(String(format: "%+.1f dB", profile.bands[index].gain)).monospacedDigit().foregroundStyle(.secondary)
            }.font(.callout)
            Slider(value: bandBinding(index, field: \.gain), in: -6...6, step: 0.5, onEditingChanged: finishEditing)
                .accessibilityValue(String(format: "%+.1f decibels", profile.bands[index].gain))
                .accessibilityLabel(advanced ? frequencyLabel(profile.bands[index].frequency) : [UInt8(0): "Bass", 1: "Mid", 2: "Treble"][profile.bands[index].filter] ?? "Band")
        }
    }
    private func parameterSlider(_ index: Int, frequency: Bool) -> some View {
        HStack {
            Text(frequency ? "Hz" : "Q").frame(width: 24, alignment: .leading)
            Slider(value: bandBinding(index, field: frequency ? \.frequency : \.quality), in: frequency ? EqualizerProfile.frequencyRanges[index] : 0.1...10, step: frequency ? 1 : 0.1, onEditingChanged: finishEditing)
                .accessibilityLabel("Band \(index + 1) \(frequency ? "frequency" : "Q")")
                .help(frequency ? "Center frequency of this band" : "Higher Q narrows the band; lower Q widens it")
            Text(String(format: frequency ? "%.0f" : "%.1f", Double(frequency ? draft?.bands[index].frequency ?? 0 : draft?.bands[index].quality ?? 1)))
                .monospacedDigit().frame(width: 44, alignment: .trailing)
        }.font(.caption)
    }
    private func bandBinding(_ index: Int, field: WritableKeyPath<EqualizerBand, Float>) -> Binding<Double> {
        Binding(get: { Double(draft?.bands[index][keyPath: field] ?? 0) }, set: { value in
            guard var next = draft else { return }
            next.bands[index][keyPath: field] = Float(value)
            if !advanced { next.totalGain = -max(0, next.bands.map(\.gain).max() ?? 0) }
            draft = next
        })
    }
    private func finishEditing(_ editing: Bool) {
        if !editing, let draft { session.setEqualizer(draft, advanced: advanced) }
    }
    private func frequencyLabel(_ value: Float) -> String {
        value >= 1000 ? String(format: "%g kHz", value / 1000) : String(format: "%g Hz", value)
    }
}
