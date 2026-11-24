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
        if model.isExpanded { return CGSize(width: max(n.width + 160, 352), height: n.height + 106) }
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
    private var hotKey: HotKey?
    private var scrollAccum: CGFloat = 0
    private var lastScrollStep = Date.distantPast

    func start() {
        let panel = NotchPanel()
        let host = FirstMouseHostingView(rootView: NotchView(model: model, awake: awake))
        host.sizingOptions = []
        panel.contentView = host
        self.panel = panel
        layout()
        panel.orderFrontRegardless()

        let globalMask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseDown, .scrollWheel]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: globalMask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handleEvent(event) }
        }) { monitors.append(g) }
        let localMask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .scrollWheel]
        if let l = NSEvent.addLocalMonitorForEvents(matching: localMask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handleEvent(event) }
            return event
        }) { monitors.append(l) }

        // ⌥⌘A toggles from anywhere.
        HotKey.action = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.awake.toggle()
                self.peek(ms: 1600)
            }
        }
        hotKey = HotKey()

        // One minute left → show the panel with "+15м" for a few seconds.
        awake.onEndingSoon = { [weak self] in
            MainActor.assumeIsolated { self?.peek(ms: 6000) }
        }

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
            self?.peek(ms: 2000)
        }
    }

    // MARK: Outside control

    /// awake://toggle · stop · start?minutes=N · until?time=HH:mm · activity
    func handle(_ url: URL) {
        guard url.scheme?.lowercased() == "awake" else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        switch (url.host ?? "").lowercased() {
        case "toggle":
            awake.toggle()
        case "stop", "off":
            awake.stop()
        case "start", "on":
            if let m = value("minutes").flatMap(Double.init), m >= 0 {
                let d = m * 60
                if Awake.durations.contains(d) { awake.start(preset: d) } else { awake.start(until: Date().addingTimeInterval(d)) }
            } else {
                awake.start(preset: awake.savedPreset)
            }
        case "until":
            if let t = value("time"), let date = Self.nextOccurrence(of: t) { awake.start(until: date) }
        case "activity":
            awake.startActivity()
        default:
            return
        }
        peek(ms: 1600)
    }

    /// "18:30" → the next moment the clock shows it.
    static func nextOccurrence(of text: String) -> Date? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 1, (0..<24).contains(parts[0]) else { return nil }
        let minute = parts.count > 1 ? parts[1] : 0
        guard (0..<60).contains(minute) else { return nil }
        return Calendar.current.nextDate(after: Date(), matching: DateComponents(hour: parts[0], minute: minute, second: 0),
                                         matchingPolicy: .nextTime)
    }

    /// Next whole hours for "До времени" (1…8 hours ahead).
    static func untilChoices() -> [Date] {
        let cal = Calendar.current
        guard let nextHour = cal.nextDate(after: Date().addingTimeInterval(10 * 60),
                                          matching: DateComponents(minute: 0, second: 0), matchingPolicy: .nextTime) else { return [] }
        return (0..<8).compactMap { cal.date(byAdding: .hour, value: $0, to: nextHour) }
    }

    /// Expand for a moment, then collapse unless the pointer is over the panel.
    private func peek(ms: Int) {
        expand()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(ms))
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
        let size = CGSize(width: 440, height: h + 156)
        panel?.setFrame(NSRect(x: midX - size.width / 2, y: top - size.height, width: size.width, height: size.height), display: true)
    }

    private func rect(_ size: CGSize) -> CGRect {
        CGRect(x: midX - size.width / 2, y: top - size.height, width: size.width, height: size.height + 2)
    }

    // MARK: Hover

    private func handleEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown: handleClick()
        case .scrollWheel: handleScroll(event)
        default: handleMouse()
        }
    }

    private func handleMouse() {
        let p = NSEvent.mouseLocation
        if model.isExpanded {
            let inside = rect(Layout.size(model)).insetBy(dx: -16, dy: -16).contains(p)
            if inside || model.menuOpen { cancelPending() } else { schedule(.collapse, ms: 260) }
        } else {
            // With ears out only the notch itself expands the panel; the ears take clicks and scrolls.
            let hotSize = model.earsVisible ? model.notchSize : Layout.size(model)
            let hot = rect(hotSize).insetBy(dx: -4, dy: 0).contains(p)
            if hot { schedule(.expand, ms: 60) } else { cancelPending() }
        }
    }

    /// Left and right ears of the collapsed notch (screen coordinates).
    private func earRects() -> [CGRect] {
        guard model.earsVisible, !model.isExpanded else { return [] }
        let n = model.notchSize
        let full = Layout.size(model)
        let w = (full.width - n.width) / 2
        return [
            CGRect(x: midX - full.width / 2, y: top - n.height, width: w, height: n.height + 2),
            CGRect(x: midX + n.width / 2, y: top - n.height, width: w, height: n.height + 2)
        ]
    }

    private func handleClick() {
        let p = NSEvent.mouseLocation
        if earRects().contains(where: { $0.contains(p) }) { awake.stop() }
    }

    private func handleScroll(_ event: NSEvent) {
        let p = NSEvent.mouseLocation
        let overEars = earRects().contains { $0.contains(p) }
        let overPanel = model.isExpanded && rect(Layout.size(model)).contains(p)
        guard overEars || overPanel, awake.isActive, awake.endDate != nil else { return }
        if event.phase == .began { scrollAccum = 0 }
        var dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 10 : event.scrollingDeltaY
        if event.isDirectionInvertedFromDevice { dy = -dy }
        scrollAccum += dy
        guard abs(scrollAccum) >= 1, Date().timeIntervalSince(lastScrollStep) > 0.2 else { return }
        awake.adjust(by: scrollAccum > 0 ? 15 * 60 : -15 * 60)
        scrollAccum = 0
        lastScrollStep = Date()
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
