import AppKit
import SwiftUI

@MainActor
final class CompanionPanel: NSPanel {

    init(state: DevConsoleState, actions: DevConsoleActions, configStore: ConfigStore) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 520),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let rootView = CompanionView(state: state, actions: actions)
            .environment(configStore)

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = contentRect(forFrameRect: frame)
        hostingView.autoresizingMask = [.width, .height]

        contentView = hostingView

        positionOnScreen()
    }

    // Accept mouse events even when app is not focused
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    private func positionOnScreen() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.maxX - frame.width - 24
        let y = screenFrame.midY - frame.height / 2
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}
