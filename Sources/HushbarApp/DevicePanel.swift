import DeviceRuntime
import SwiftUI
import AppKit
import DeviceProtocol
import Observation

enum PanelPage: String, Hashable, CaseIterable {
    case main, device, customEQ, advancedEQ
    var title: String {
        switch self { case .main: ""; case .device: "Device settings"; case .customEQ: "Custom EQ"; case .advancedEQ: "Advanced EQ" }
    }
}

@MainActor @Observable
final class PanelNavigation {
    var path: [PanelPage]
    var page: PanelPage { path.last ?? .main }
    init(page: PanelPage = .main) { path = page == .main ? [] : [page] }
    func selectEQ(_ value: UInt8, session: DeviceSession) {
        if value == 6 { path = [.advancedEQ] }
        session.setEQ(value)
    }
    func editEQ(session: DeviceSession) {
        path = [session.state.advancedEQ == true || session.capabilities?.customEQ != true ? .advancedEQ : .customEQ]
    }
}

struct DevicePanel: View {
    @Bindable var session: DeviceSession
    @Bindable var navigation: PanelNavigation
    @ViewState private var pageHeights: [PanelPage: CGFloat] = [:]
    @ViewState private var pendingCodec: UInt8?
    @ViewState private var pendingDual: Bool?
    @ViewState private var confirmingForget = false
    var onOpenSettings: @MainActor () -> Void
    var onSizeChange: (@MainActor (CGSize) -> Void)?
    static let width: CGFloat = 336
    private let maxContentHeight: CGFloat = 540

    init(session: DeviceSession, page: PanelPage = .main, navigation: PanelNavigation? = nil,
         onOpenSettings: @escaping @MainActor () -> Void = {}, onSizeChange: (@MainActor (CGSize) -> Void)? = nil) {
        self.session = session
        self.navigation = navigation ?? PanelNavigation(page: page)
        self.onOpenSettings = onOpenSettings
        self.onSizeChange = onSizeChange
    }
    var body: some View {
        VStack(spacing: 0) {
            if let page = navigation.path.last {
                HStack(spacing: 8) {
                    Button { navigation.path.removeLast() } label: { Image(systemName: "chevron.backward") }
                        .buttonStyle(.borderless).frame(width: 24, height: 28)
                        .accessibilityLabel("Back to device").help("Back to device")
                    Text(page.title).font(.system(size: 13, weight: .semibold))
                    Spacer()
                }.padding(.horizontal, 10).frame(height: 42)
                Divider()
            }
            // A NavigationStack reserves a window toolbar even on the root page.
            // Switch pages directly so the popover starts with the device header.
            panelPage(navigation.page)
                .frame(height: min(max(pageHeights[navigation.page] ?? 420, 180), maxContentHeight))
            Divider()
            HStack {
                Button("Settings…") {
                    if NSEvent.modifierFlags.contains(.option) { session.developerSettings = true }
                    onOpenSettings()
                }.help("Open Hushbar preferences. Option-click for developer options.")
                Spacer()
                Button("Quit Hushbar") { session.quit() }
            }.buttonStyle(.borderless).font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.horizontal, 16).frame(height: 34)
        }
        .frame(width: Self.width)
        .font(.body)
        .controlSize(.small)
        // The native NSPopover supplies its material, corners, shadow and anchor.
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSizeChange?($0) }
        .alert("Restart device to change codec?", isPresented: Binding(get: { pendingCodec != nil }, set: { if !$0 { pendingCodec = nil } })) {
            Button("Cancel", role: .cancel) { pendingCodec = nil }
            Button("Apply and restart") { if let value = pendingCodec { session.setCodec(value) }; pendingCodec = nil }
        } message: { Text("Audio will disconnect briefly. This changes the device's preferred codec; macOS chooses the codec used for playback.") }
        .alert("Restart device for dual connection?", isPresented: Binding(get: { pendingDual != nil }, set: { if !$0 { pendingDual = nil } })) {
            Button("Cancel", role: .cancel) { pendingDual = nil }
            Button("Apply and restart") { if let value = pendingDual { session.setDual(value) }; pendingDual = nil }
        } message: { Text("Hushbar will reconnect when your device is available.") }
        .alert("Forget this device?", isPresented: $confirmingForget) {
            Button("Cancel", role: .cancel) { }
            Button("Forget", role: .destructive) { navigation.path = []; session.forget() }
        } message: { Text("Removes Hushbar's saved selection. Bluetooth pairing stays in macOS.") }
        .onChange(of: session.model?.base) { _, _ in navigation.path = [] }
        .onChange(of: session.ready) { _, ready in if !ready { navigation.path = [] } }
    }
    private func panelPage(_ page: PanelPage) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: page == .main ? 9 : 14) {
                if page == .main { header }
                if let error = session.error {
                    HStack(alignment: .top) {
                        Label(error, systemImage: "exclamationmark.triangle").font(.caption).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button { session.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Dismiss error")
                    }.foregroundStyle(.secondary)
                }
                if session.ready, let c = session.capabilities {
                    switch page {
                    case .main: mainControls(c)
                    case .device: deviceControls(c)
                    case .customEQ: EqualizerEditor(session: session, advanced: false)
                    case .advancedEQ: EqualizerEditor(session: session, advanced: true)
                    }
                } else if session.connecting {
                    HStack { ProgressView().controlSize(.small); Text(session.status) }.padding(.vertical, 40)
                } else { emptyPanel }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                pageHeights[page] = height
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .defaultScrollAnchor(session.ringing.isEmpty ? .top : .bottom)
        .onAppear { if page == .device { session.refreshDualDevices() } }
        .id(page)
    }
    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: session.symbol).font(.system(size: 25, weight: .light)).frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(session.selectedName).font(.system(size: 13, weight: .semibold))
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(session.isDemo ? "Demo device" : session.status)
                    if session.ready, session.model?.singleBattery == true {
                        Text("·")
                        BatteryStatus(part: .stereo, battery: session.state.batteries[.stereo], compact: true)
                    }
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Menu {
                if session.isDemo {
                    Button("Nothing Ear") { session.setDemo("B171") }
                    Button("Headphone (1)") { session.setDemo("B170") }
                } else {
                    ForEach(session.devices) { device in
                        Button(device.name) { session.connect(device) }
                    }
                    Divider()
                    Button("Refresh devices") { session.refreshDevices() }
                    Button("Refresh device settings") { session.refreshSettings() }.disabled(!session.ready)
                }
            } label: { Image(systemName: "chevron.down") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Choose an audio device")
        }.padding(.vertical, 2)
    }
    @ViewBuilder private func mainControls(_ c: Capabilities) -> some View {
        if session.model?.singleBattery != true {
            HStack {
                ForEach([BatteryPart.left, .right, .chargingCase], id: \.self) { part in
                    BatteryStatus(part: part, battery: session.state.batteries[part])
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 2)
        }
        Divider()
        if c.anc {
            VStack(alignment: .leading, spacing: 8) {
                Text("Noise control").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Picker("Noise control", selection: Binding(get: { session.state.anc?.isCancellation == true ? ANCMode.high : session.state.anc ?? .off }, set: { session.setANC($0 == .high ? session.state.lastANC ?? .high : $0) })) {
                    Text("Off").tag(ANCMode.off)
                    if c.ancModes.contains(.transparency) { Text("Transparency").tag(ANCMode.transparency) }
                    Text("Cancellation").tag(ANCMode.high)
                }.pickerStyle(.segmented).labelsHidden().disabled(session.state.anc == nil)
                if session.state.anc?.isCancellation == true, c.ancModes.filter(\.isCancellation).count > 1 {
                    Picker("Strength", selection: Binding(get: { session.state.anc ?? .high }, set: { session.setANC($0) })) {
                        ForEach(c.ancModes.filter(\.isCancellation), id: \.self) { mode in Text(mode == .medium ? "Mid" : mode.label).tag(mode) }
                    }.pickerStyle(.segmented).labelsHidden().help("Noise cancellation strength")
                }
            }.disabled(!session.pending.isEmpty)
            Divider()
        }
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Text("Equalizer")
                if c.customEQ || c.advancedEQ {
                    Button("Edit…") { navigation.editEQ(session: session) }
                        .buttonStyle(.borderless).font(.system(size: 11)).foregroundStyle(Color.accentColor)
                        .accessibilityIdentifier("edit-equalizer")
                        .help("Adjust Custom or Advanced EQ bands")
                }
                Spacer(minLength: 8)
                Picker("Preset", selection: Binding(get: { session.state.advancedEQ == true ? UInt8(6) : session.state.eq ?? 0 }, set: { navigation.selectEQ($0, session: session) })) {
                    ForEach(c.audioChoices) { choice in
                        Text(choice.name).tag(choice.id).disabled(c.choiceBlock(choice.id, state: session.state) != nil)
                    }
                }.pickerStyle(.menu).labelsHidden().frame(width: 140).disabled(session.state.eq == nil || !session.pending.isEmpty)
            }.frame(minHeight: 28)
            if !c.spatialModes.isEmpty {
                HStack {
                    Text("Spatial audio")
                    Spacer(minLength: 8)
                    Picker("Spatial audio", selection: Binding(get: { session.state.spatial ?? 0 }, set: { session.setSpatial($0) })) {
                        ForEach(c.spatialModes.sorted { ($0.id == 2 ? 1 : $0.id == 1 ? 2 : $0.id) < ($1.id == 2 ? 1 : $1.id == 1 ? 2 : $1.id) }) { mode in
                            Text(mode.id == 1 ? "Head tracking" : mode.name).tag(mode.id).disabled(mode.id != 0 && c.spatialBlock(session.state) != nil)
                        }
                    }.pickerStyle(.menu).labelsHidden().frame(width: 140).disabled(session.state.spatial == nil || !session.pending.isEmpty)
                }.frame(minHeight: 28)
            }
        }
        if c.inEar || c.latency || c.bassReadable {
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                if c.inEar {
                    toggle("Automatic pause", value: session.state.inEar, action: session.setInEar)
                        .help(session.model?.singleBattery == true ? "Pause playback when you take them off" : "Pause playback when you remove an earbud")
                }
                if c.latency {
                    toggle("Low latency", value: session.state.latency, action: session.setLatency)
                        .help("Reduces audio delay for games and video")
                }
                if c.bassReadable {
                    toggle("Bass Enhance", value: session.state.bass, action: { session.setBass($0) }).disabled(!c.bassWritable || c.bassBlock(session.state) != nil)
                        .help("Boosts low frequencies. Some sound modes cannot be used together.")
                    if session.state.bass == true, c.bassWritable {
                        BassLevelSlider(session: session, capabilities: c)
                    }
                }
            }.disabled(!session.pending.isEmpty)
        }
        if c.find {
            Divider()
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(session.model?.singleBattery == true ? "Find headphones" : "Find earbuds")
                    Spacer(minLength: 0)
                    if !session.ringing.isEmpty { ProgressView().controlSize(.mini).help("Playing sound") }
                    if !session.ringing.isEmpty {
                        Button("Stop") { session.stopRinging() }.buttonStyle(.borderedProminent)
                    } else {
                        if session.model?.singleBattery == true || session.model?.base == "B181" {
                            Button("Play sound") { session.ring("both", enabled: true) }
                        } else {
                            Button("Left", systemImage: "speaker.wave.2") { session.ring("left", enabled: true) }.disabled(session.state.batteries[.left] == nil)
                            Button("Right", systemImage: "speaker.wave.2") { session.ring("right", enabled: true) }.disabled(session.state.batteries[.right] == nil)
                        }
                    }
                }
                Text(session.ringing.isEmpty ? "Plays a loud sound. Take them off first." : "Playing a sound on your device…")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        Divider()
        Button { navigation.path.append(.device) } label: {
            HStack {
                Text("Device settings")
                Spacer()
                Image(systemName: "chevron.forward").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            }.frame(maxWidth: .infinity, minHeight: 24, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    @ViewBuilder private func deviceControls(_ c: Capabilities) -> some View {
        Text(session.selectedName).font(.headline)
        PanelSection("Device information") {
            VStack(spacing: 8) {
                detail("Model", session.model?.base ?? "Unknown")
                detail("Firmware", session.state.firmware.isEmpty ? "Reading…" : session.state.firmware)
                detail("Bluetooth address", session.selectedID ?? (session.isDemo ? "Demo device" : "Unavailable"))
                if c.bassReadable && !c.bassWritable {
                    detail("Bass level", c.bassLevel(wire: session.state.bassWire).map(String.init) ?? "Unavailable")
                }
                ForEach(BatteryPart.allCases, id: \.self) { part in
                    if let battery = session.state.batteries[part] {
                        detail(part == .stereo ? "Headphones" : part.label, "\(battery.percent)%" + (battery.charging ? " · Charging" : ""))
                    }
                }
            }.font(.caption).textSelection(.enabled).padding(.top, 4)
        }
        if c.personalSoundRead != nil {
            PanelSection("Personal Sound Profile") {
                VStack(alignment: .leading, spacing: 6) {
                    toggle("Use saved profile", value: session.state.personalSound, action: session.setPersonalSound)
                    Text("Uses a hearing profile already saved on your device. Create one in Nothing X.").font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 4)
            }.disabled(!session.pending.isEmpty)
        }
        if c.personalizedANC {
            toggle("Personalized noise cancellation", value: session.state.personalizedANC, action: session.setPersonalized).disabled(!session.pending.isEmpty)
        }
        if c.dual {
            PanelSection("Connections") {
                VStack(alignment: .leading, spacing: 8) {
                    toggle("Dual connection", subtitle: "Connect to two devices at once", value: session.state.dual, action: { value in if c.dualNeedsReboot { pendingDual = value } else { session.setDual(value) } })
                    if session.state.dual == true, session.state.dualListSupported == true {
                        Divider()
                        ForEach(session.state.dualDevices) { device in
                            Toggle(isOn: Binding(get: { device.connected }, set: { session.setDualDevice(device, connected: $0) })) {
                                Text(device.name).frame(maxWidth: .infinity, alignment: .leading)
                            }.frame(maxWidth: .infinity, alignment: .leading).toggleStyle(.switch).controlSize(.small).disabled(session.loadingDual || !session.pending.isEmpty)
                        }
                        Button("Refresh connected devices") { session.refreshDualDevices() }.disabled(session.loadingDual)
                        if session.loadingDual { ProgressView().controlSize(.small) }
                    }
                }.padding(.top, 4)
            }.disabled(!session.pending.isEmpty)
        }
        if !c.codecChoices.isEmpty {
            PanelSection("Audio") {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("Preferred codec", selection: Binding(get: { session.state.codec ?? 0 }, set: { if $0 != session.state.codec { pendingCodec = $0 } })) {
                        ForEach(c.codecChoices) { choice in Text(choice.name).tag(choice.id) }
                    }.disabled(session.state.codec == nil)
                    Text("Changing codec restarts your device. macOS chooses the playback codec.").font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 4)
            }.disabled(!session.pending.isEmpty)
        }
        if c.earFit {
            PanelSection("Ear tip fit") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Insert both earbuds, then check the seal.").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Test fit") { session.runFitTest() }.disabled(session.testingFit)
                        if session.testingFit { ProgressView().controlSize(.small) }
                    }
                    if let left = session.state.fitLeft { LabeledContent("Left", value: left.label) }
                    if let right = session.state.fitRight { LabeledContent("Right", value: right.label) }
                }.padding(.top, 4)
            }
        }
        Button("Forget this device…", role: .destructive) { confirmingForget = true }.disabled(session.isDemo)
        Text("Removes the saved selection in Hushbar. Bluetooth pairing stays in macOS.").font(.caption).foregroundStyle(.secondary)
    }
    private func detail(_ title: String, _ value: String) -> some View {
        LabeledContent(title) { Text(value).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing) }
    }
    private func toggle(_ title: String, subtitle: String? = nil, value: Bool?, action: @escaping @MainActor @Sendable (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: { value ?? false }, set: { action($0) })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.toggleStyle(.switch).controlSize(.small).frame(minHeight: 28).disabled(value == nil)
    }
    private var emptyPanel: some View {
        ContentUnavailableView {
            Label(session.selectedID == nil ? "No audio device" : "Waiting for your device", systemImage: "earbuds")
        } description: {
            Text("Connect your Nothing or CMF device in macOS Bluetooth settings, then refresh.")
        } actions: {
            Button("Bluetooth settings…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") { NSWorkspace.shared.open(url) }
            }.buttonStyle(.borderedProminent)
            Button("Refresh") { session.retryConnection() }.disabled(session.scanning)
        }.frame(minHeight: 260)
    }
}

struct PanelSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            content
        }.padding(.vertical, 4)
    }
}

private struct BatteryStatus: View {
    let part: BatteryPart
    let battery: Battery?
    var compact = false
    var body: some View {
        HStack(spacing: 4) {
            if !compact {
                Image(systemName: part == .chargingCase ? "earbuds.case" : part == .left ? "earbud.left" : "earbud.right")
                Text(part.label)
            }
            if compact {
                Image(systemName: battery?.charging == true ? "battery.100percent.bolt" : "battery.100percent")
            } else if battery?.charging == true {
                Image(systemName: "bolt.fill").font(.system(size: 8))
            }
            Text(battery.map { "\($0.percent)%" } ?? "—").monospacedDigit()
        }.font(.system(size: 11)).lineLimit(1).fixedSize()
            .foregroundStyle(battery?.percent ?? 100 < 20 ? Color.red : Color.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(part == .stereo ? "Headphones battery" : "\(part.label) battery")
            .accessibilityValue(battery.map { "\($0.percent) percent" + ($0.charging ? ", charging" : "") } ?? "Unavailable")
    }
}

private struct BassLevelSlider: View {
    @Bindable var session: DeviceSession
    let capabilities: Capabilities
    @ViewState private var level: Double = 1
    private var stored: Double { Double(capabilities.bassLevel(wire: session.state.bassWire) ?? 1) }
    var body: some View {
        HStack {
            Text("Level").foregroundStyle(.secondary)
            Slider(value: $level, in: capabilities.threeStageBass ? 1...2 : 1...5, step: 1) { editing in
                if !editing { session.setBass(true, level: Int(level)) }
            }.accessibilityLabel("Bass enhancement level")
            Text("\(Int(level))").monospacedDigit()
        }.font(.caption)
            .onAppear { level = stored }
            .onChange(of: stored) { _, value in level = value }
    }
}
