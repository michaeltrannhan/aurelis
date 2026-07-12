import AppKit
import SwiftUI

/// Hosts the volume HUD in a floating borderless panel near the top-right of the
/// active screen and auto-hides it after a short delay.
@MainActor
final class VolumeHUDWindowController {
    private var panel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?
    private let visibleDuration: TimeInterval

    init(visibleDuration: TimeInterval = 0.9) {
        self.visibleDuration = visibleDuration
    }

    func show(_ state: VolumeHUDState) {
        let panel = ensurePanel()
        panel.contentView = NSHostingView(rootView: VolumeHUDView(state: state))
        positionPanel(panel)
        panel.orderFrontRegardless()

        hideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.panel?.orderOut(nil)
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + visibleDuration, execute: work)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 180),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.panel = panel
        return panel
    }

    private func positionPanel(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(
            x: visible.maxX - size.width - 24,
            y: visible.maxY - size.height - 24
        )
        panel.setFrameOrigin(origin)
    }
}
