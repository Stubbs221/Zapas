import AppKit
import SwiftUI

/// MenuBarExtra scene lifetime is not its visibility; observe the actual AppKit window.
struct WindowVisibility: NSViewRepresentable {
    let changed: @MainActor (ObjectIdentifier, Bool) -> Void
    func makeNSView(context: Context) -> VisibilityView { VisibilityView(changed: changed) }
    func updateNSView(_ view: VisibilityView, context: Context) {}
    static func dismantleNSView(_ view: VisibilityView, coordinator: ()) { view.detach() }
}

@MainActor final class VisibilityView: NSView {
    let changed: @MainActor (ObjectIdentifier, Bool) -> Void
    private var tokens: [NSObjectProtocol] = []
    private var trackedWindow: ObjectIdentifier?
    init(changed: @escaping @MainActor (ObjectIdentifier, Bool) -> Void) { self.changed = changed; super.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); detach()
        guard let window else { return }
        trackedWindow = ObjectIdentifier(window)
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            tokens.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            })
        }
        report()
    }
    func report() {
        if let trackedWindow { changed(trackedWindow, window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false) }
    }
    func detach() {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
        tokens.removeAll()
        if let trackedWindow { changed(trackedWindow, false) }; trackedWindow = nil
    }
}
