import DeviceRuntime
import AppKit
import SwiftUI
import Testing
@testable import HushbarApp

/// Sizes the live (non-snapshot) panel the way the native popover does: with a minimal
/// height proposal. A ScrollView with only a maxHeight collapses to zero there, leaving just
/// the header and footer (~106pt). Snapshots also use this exact layout.
@MainActor
private func liveHeight(base: String, page: PanelPage) async throws -> CGFloat {
    let session = DeviceSession(demoBase: base)
    if page == .customEQ { session.setEQ(5) }
    if page == .advancedEQ { session.setEQ(6) }
    let controller = NSHostingController(rootView: DevicePanel(session: session, page: page))
    // onGeometryChange feeds the measured height back into state; give it a few passes.
    for _ in 0..<5 {
        controller.view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
    }
    return controller.sizeThatFits(in: CGSize(width: DevicePanel.width, height: 0)).height
}

@Test @MainActor func livePanelShowsContentOnEveryPage() async throws {
    for base in ["B171", "B170"] {
        for page in PanelPage.allCases {
            let height = try await liveHeight(base: base, page: page)
            print("Live layout \(base) \(page): \(height)pt")
            #expect(height > (page == .main ? 400 : 220), "\(base) \(page) collapsed to \(height)pt")
            #expect(height < 650, "\(base) \(page) exceeds menu bar height: \(height)pt")
            if page == .main {
                #expect(height < 500, "\(base) main controls should fit without scrolling: \(height)pt")
            }
        }
    }
}

@Test @MainActor func emptyAndSettingsViewsHaveNativeIdealHeight() async throws {
    let empty = DeviceSession(demoBase: nil, snapshot: true)
    let panel = NSHostingController(rootView: DevicePanel(session: empty))
    for _ in 0..<5 {
        panel.view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(panel.sizeThatFits(in: CGSize(width: DevicePanel.width, height: 0)).height > 300)
    for (about, diagnostics) in [(false, false), (true, false), (false, true)] {
        let settings = NSHostingController(rootView: AppSettings(session: DeviceSession(demoBase: "B170", snapshot: true),
                                                                 about: about, diagnostics: diagnostics))
        settings.view.layoutSubtreeIfNeeded()
        let size = settings.sizeThatFits(in: CGSize(width: AppSettings.width, height: 0))
        #expect(size.width == AppSettings.width && size.height == AppSettings.height)
    }
}
