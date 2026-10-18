import DeviceRuntime
import SupportDiagnostics
import AppKit
import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers

struct AppSettings: View {
    static let width: CGFloat = 520
    static let height: CGFloat = 500
    @Bindable var session: DeviceSession
    @ViewState private var selection: Int
    init(session: DeviceSession, about: Bool = false, diagnostics: Bool = false) {
        self.session = session; _selection = ViewState(initialValue: diagnostics ? 2 : about ? 1 : 0)
    }
    var body: some View {
        TabView(selection: $selection) {
            GeneralSettings(session: session).tabItem { Label("General", systemImage: "gearshape") }.tag(0)
            AboutSettings().tabItem { Label("About", systemImage: "info.circle") }.tag(1)
            DiagnosticsSettings(session: session).tabItem { Label("Diagnostics", systemImage: "stethoscope") }.tag(2)
        }.frame(width: Self.width, height: Self.height)
    }
}
private struct GeneralSettings: View {
    @Bindable var session: DeviceSession
    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(get: { session.loginEnabled }, set: { session.setLogin($0) }))
                Toggle("Show battery in menu bar", isOn: $session.showBattery)
                Toggle("Auto-connect devices", isOn: $session.autoConnectLast)
                if session.loginNeedsApproval && !session.isDemo && !session.isSnapshot {
                    Button("Approve in Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                }
            }
            if session.developerSettings || session.isDemo {
                Section("Developer") {
                    Toggle("Demo mode", isOn: Binding(get: { session.isDemo }, set: { session.setDemoEnabled($0) }))
                    Text("Preview controls without connecting to Bluetooth.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = session.error { Text(error).font(.caption).foregroundStyle(.secondary) }
        }.formStyle(.grouped).toggleStyle(.switch).controlSize(.small)
            .onAppear { session.refreshLoginStatus() }
    }
}
private struct AboutSettings: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("Hushbar", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0")
                Text("An independent companion for Nothing and CMF audio.").foregroundStyle(.secondary)
            }
            Section("Credits") {
                Text("Built on the Ear project by RapidZapper and its contributors. Upstream authorship and license notices are preserved.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Read upstream notices") { openDocument("NOTICE", extension: "md", repositoryName: "README.md#credits-and-licence") }
            }
            Section("Legal") {
                Text("GNU Affero General Public License v3.0. Independent software; not affiliated with or endorsed by Nothing or CMF. Product names belong to their respective owners.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Read the AGPL-3.0 license") { openDocument("LICENSE", extension: nil, repositoryName: "LICENSE") }
            }
        }.formStyle(.grouped)
    }
    private func openDocument(_ name: String, extension suffix: String?, repositoryName: String) {
        if let bundled = Bundle.main.url(forResource: name, withExtension: suffix), NSWorkspace.shared.open(bundled) { return }
        if let source = URL(string: "https://github.com/aaditagrawal/hushbar/blob/main/\(repositoryName)") {
            NSWorkspace.shared.open(source)
        }
    }
}

private struct DiagnosticsSettings: View {
    @Bindable var session: DeviceSession
    @ViewState private var review: String? = nil
    @ViewState private var showingReview = false
    @ViewState private var exporting = false
    @ViewState private var feedback: String? = nil
    @ViewState private var failed = false

    private var capture: DiagnosticCapture { session.diagnostics }
    private var hasReport: Bool { capture.startedAt != nil }
    private var canReview: Bool { hasReport && !capture.isCapturing && !exporting }

    var body: some View {
        Form {
            Section("Capture a problem") {
                Text("Start capture, reproduce the issue, then stop and review the report before sharing it on GitHub.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("Capture is off by default and stays in memory. Reports include app, OS, model and firmware details, connection events and command metadata. They exclude raw packets, Bluetooth addresses, device and host names, paths and system logs. Nothing is uploaded.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Label(capture.isCapturing ? "Capturing" : hasReport ? "Capture stopped" : "Capture is off",
                          systemImage: capture.isCapturing ? "record.circle" : "stop.circle")
                    Spacer()
                    if capture.isCapturing {
                        Button("Stop capture") { capture.stop(); feedback = nil }.keyboardShortcut(.cancelAction)
                    } else {
                        Button(hasReport ? "Start new capture" : "Start capture") {
                            session.startDiagnosticCapture(); review = nil; feedback = nil
                        }
                    }
                }.disabled(exporting)
                Text("\(capture.events.count) events · \(capture.storedEventBytes.formatted()) bytes · \(capture.discardedEvents) discarded")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                Text("Keeps the latest \(capture.maximumEvents.formatted()) events within \(capture.maximumEventBytes.formatted()) event bytes. Starting again clears the previous capture.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Support report") {
                HStack {
                    Button("Review report…") { prepareReview() }.disabled(!canReview)
                    Button("Export support report…") { exportReport() }
                        .disabled(!canReview || session.isSnapshot)
                }
                HStack {
                    Button("Copy summary") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(capture.report().summary, forType: .string)
                        failed = false; feedback = "Summary copied."
                    }.disabled(!canReview || session.isSnapshot)
                    Spacer()
                    Button("Reset capture", role: .destructive) {
                        capture.reset(); review = nil; feedback = nil
                    }.disabled(!hasReport || exporting)
                    if exporting { ProgressView().controlSize(.small).accessibilityLabel("Saving report") }
                }
                if capture.isCapturing {
                    Text("Stop capture to review or export a stable report.").font(.caption).foregroundStyle(.secondary)
                }
                if session.isSnapshot {
                    Text("Snapshot preview. Export and clipboard access are disabled.").font(.caption).foregroundStyle(.secondary)
                }
                if let feedback {
                    Label(feedback, systemImage: failed ? "exclamationmark.triangle" : "checkmark.circle")
                        .font(.caption).foregroundStyle(failed ? Color.red : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped).controlSize(.small)
        .sheet(isPresented: $showingReview) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Review support report").font(.headline)
                Text("This is the complete JSON file that Export saves. Share it only when you are comfortable with its contents.")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView([.vertical, .horizontal]) {
                    Text(review ?? "").font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.border(.separator)
                HStack {
                    Spacer()
                    Button("Done") { showingReview = false }.keyboardShortcut(.defaultAction)
                }
            }.padding(20).frame(width: 640, height: 480)
        }
    }

    private func prepareReview() {
        do {
            review = String(decoding: try capture.report().jsonData(), as: UTF8.self)
            showingReview = true; feedback = nil
        } catch {
            failed = true; feedback = "The report could not be prepared. Stop and start a new capture to retry."
        }
    }

    private func exportReport() {
        guard !session.isSnapshot, canReview else { return }
        let data: Data
        do { data = try capture.report().jsonData() }
        catch { failed = true; feedback = "The report could not be prepared."; return }
        exporting = true; feedback = nil
        Task { @MainActor in
            let panel = NSSavePanel()
            panel.title = "Export Hushbar support report"
            panel.message = "Save this metadata-only report locally. Hushbar does not upload it."
            panel.nameFieldStringValue = "Hushbar-support-report.json"
            panel.allowedContentTypes = [.json]
            panel.canCreateDirectories = true
            let response = await panel.begin()
            guard response == .OK, let url = panel.url else { exporting = false; return }
            do {
                try await Task.detached(priority: .userInitiated) { try data.write(to: url, options: .atomic) }.value
                failed = false; feedback = "Support report saved. You can attach it to a GitHub issue."
            } catch {
                failed = true; feedback = "The report could not be saved. Check folder permissions and try again."
            }
            exporting = false
        }
    }
}
