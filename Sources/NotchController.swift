import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class NotchModel {
    var isExpanded = false
    var notchSize = CGSize(width: 185, height: 32)
    var hasNotch = true
    var menuOpen = false
    var loginEnabled = LoginItem.isEnabled
    /// Side "ears" with the eye and the timer (lag behind Awake.isActive for the closing-eye animation).
    var earsVisible = false
    var dotOn = false
}

/// Sizes shared by the SwiftUI view and the hover hit-testing.
@MainActor
enum Layout {
    static let ear: CGFloat = 50

    static func size(_ model: NotchModel) -> CGSize {
        let n = model.notchSize
        if model.isExpanded { return CGSize(width: max(n.width + 160, 352), height: n.height + 80) }
        if model.earsVisible { return CGSize(width: n.width + ear * 2, height: n.height) }
        // Exactly the hardware notch (flares included), so it is invisible when idle.
        return CGSize(width: max(0, n.width - corners(false).top * 2), height: n.height)
    }

    static func corners(_ expanded: Bool) -> (top: CGFloat, bottom: CGFloat) {
        expanded ? (12, 22) : (6, 11)
    }
}

final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 440, height: 140),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 8)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class NotchController {
    let model = NotchModel()
    let awake = Awake()

    private var panel: NotchPanel?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var midX: CGFloat = 0
    private var top: CGFloat = 0
    private enum Pending { case expand, collapse }
    private var pendingKind: Pending?
    private var pendingTask: Task<Void, Never>?
    private var watchdog: Timer?

    func start() {
        let panel = NotchPanel()
        let host = FirstMouseHostingView(rootView: NotchView(model: model, awake: awake))
        host.sizingOptions = []
        panel.contentView = host
        self.panel = panel
        layout()
        panel.orderFrontRegardless()

        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.handleMouse() }
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handleMouse() }
            return event
        }) { monitors.append(l) }

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        })
        observers.append(nc.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.menuOpen = true }
        })
        observers.append(nc.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.model.menuOpen = false
                self?.handleMouse()
            }
        })

        // A short peek on launch so it is clear where the app lives.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            self?.expand()
            try? await Task.sleep(for: .milliseconds(2000))
            self?.handleMouse()
        }
    }

    // MARK: Geometry

    private func targetScreen() -> NSScreen? {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func layout() {
        guard let screen = targetScreen() else { return }
        let hasNotch = screen.safeAreaInsets.top > 0
        var w: CGFloat = 185
        var h: CGFloat
        if hasNotch {
            h = screen.safeAreaInsets.top
            if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
                w = screen.frame.width - l.width - r.width
            }
        } else {
            let bar = screen.frame.maxY - screen.visibleFrame.maxY
            h = bar > 0 ? bar : 24
        }
        model.notchSize = CGSize(width: w, height: h)
        model.hasNotch = hasNotch
        midX = screen.frame.midX
        top = screen.frame.maxY
        let size = CGSize(width: 440, height: h + 130)
        panel?.setFrame(NSRect(x: midX - size.width / 2, y: top - size.height, width: size.width, height: size.height), display: true)
    }

    private func rect(_ size: CGSize) -> CGRect {
        CGRect(x: midX - size.width / 2, y: top - size.height, width: size.width, height: size.height + 2)
    }

    // MARK: Hover

    private func handleMouse() {
        let p = NSEvent.mouseLocation
        if model.isExpanded {
            let inside = rect(Layout.size(model)).insetBy(dx: -16, dy: -16).contains(p)
            if inside || model.menuOpen { cancelPending() } else { schedule(.collapse, ms: 260) }
        } else {
            let hot = rect(Layout.size(model)).insetBy(dx: -4, dy: 0).contains(p)
            if hot { schedule(.expand, ms: 60) } else { cancelPending() }
        }
    }

    private func schedule(_ kind: Pending, ms: Int) {
        guard pendingKind != kind else { return }
        pendingTask?.cancel()
        pendingKind = kind
        pendingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(ms))
            guard let self, !Task.isCancelled else { return }
            self.pendingKind = nil
            if kind == .expand { self.expand() } else { self.collapse() }
        }
    }

    private func cancelPending() {
        pendingTask?.cancel()
        pendingTask = nil
        pendingKind = nil
    }

    private func expand() {
        guard !model.isExpanded else { return }
        model.loginEnabled = LoginItem.isEnabled
        model.isExpanded = true
        panel?.ignoresMouseEvents = false
        // Safety net: re-check the pointer even if no mouse events arrive.
        watchdog?.invalidate()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleMouse() }
        }
        RunLoop.main.add(t, forMode: .common)
        watchdog = t
    }

    private func collapse() {
        guard model.isExpanded, !model.menuOpen else { return }
        model.isExpanded = false
        panel?.ignoresMouseEvents = true
        watchdog?.invalidate()
        watchdog = nil
    }
}
