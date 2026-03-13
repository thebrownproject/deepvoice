import AppKit
import SwiftUI

@MainActor
final class CompanionPanel: NSPanel {

    init(state: DevConsoleState, actions: DevConsoleActions, configStore: ConfigStore) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 550),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let rootView = CompanionView(state: state, actions: actions)
            .environment(configStore)

        let hostingView = FirstMouseHostingView(rootView: rootView)
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

/// NSHostingView subclass that accepts first mouse so clicks work without activating the app first.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
