import AppKit
import Carbon
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
    /// The Mac is kept awake by a watched app right now.
    var appsMode = false
    /// Show the app's icon in the collapsed notch (setting). Off → only in the open panel.
    var iconInNotch = UserDefaults.standard.object(forKey: "iconInNotch") as? Bool ?? true
    /// The right ear of the collapsed notch is actually drawn.
    var earShown: Bool { earsVisible && !launching && !(appsMode && !iconInNotch) }
    var dotOn = false
    /// A popover over an app icon is open — keep the panel expanded.
    var popoverOpen = false
    /// Launch animation ("Восход").
    var intro = false
    var introGlow = false
    var introText = false
    var introLine = false
    /// First launch: "found N apps" card.
    var onboarding = false
    /// True until the launch animation has finished: nothing else is drawn in the notch.
    var launching = true
    /// Bumped when the interface language changes, so every view redraws.
    var langVersion = 0
    @ObservationIgnored var finishOnboarding: ((Bool) -> Void)?
}

/// Sizes shared by the SwiftUI view and the hover hit-testing.
@MainActor
enum Layout {
    /// One ear, on the right of the notch: app icons while rendering, otherwise the time left.
    static let ear: CGFloat = 44
    static let introWing: CGFloat = 62
    /// During the launch animation the shape drops this much below the notch: the notch itself has no pixels,
    /// so the inner glow lives in this band and in the side wings.
    static let introDrop: CGFloat = 10

    static func size(_ model: NotchModel) -> CGSize {
        let n = model.notchSize
        if model.isExpanded {
            return CGSize(width: max(n.width + 160, 352), height: n.height + (model.onboarding ? 116 : 80))
        }
        if model.intro { return CGSize(width: n.width + introWing * 2, height: n.height + introDrop) }
        if model.earShown { return CGSize(width: n.width + ear, height: n.height) }
        // Exactly the hardware notch (flares included), so it is invisible when idle.
        return CGSize(width: max(0, n.width - corners(false).top * 2), height: n.height)
    }

    /// Collapsed with the ear: the shape is shifted right so the notch stays in place.
    static func offsetX(_ model: NotchModel) -> CGFloat {
        (!model.isExpanded && !model.intro && model.earShown) ? ear / 2 : 0
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
    /// ⌘Q — only while the open panel is under the pointer.
    private var quitKey: HotKey?
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
        model.finishOnboarding = { [weak self] watch in MainActor.assumeIsolated { self?.finishOnboarding(watch: watch) } }
        hotKey = HotKey(id: 1, keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(cmdKey | optionKey)) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.awake.toggle()
                self.peek(ms: 1600)
            }
        }

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

        // Launch animation "Восход": the notch slowly opens, a soft green dawn rises under it,
        // "awake." appears out of a blur, a 1-px line of light shows along the bottom; all fades, then it closes.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self else { return }
            let ease = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 1.1)
            withAnimation(ease) { self.model.intro = true }
            try? await Task.sleep(for: .milliseconds(250))
            withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 1.3)) {
                self.model.introGlow = true
                self.model.introLine = true
            }
            try? await Task.sleep(for: .milliseconds(450))
            withAnimation(.easeOut(duration: 0.8)) { self.model.introText = true }
            try? await Task.sleep(for: .milliseconds(1500))
            withAnimation(.easeInOut(duration: 0.8)) {
                self.model.introText = false
                self.model.introGlow = false
                self.model.introLine = false
            }
            try? await Task.sleep(for: .milliseconds(350))
            withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.9)) { self.model.intro = false }
            try? await Task.sleep(for: .milliseconds(900))
            withAnimation(Motion.ears) { self.model.launching = false }
            self.startOnboardingIfNeeded()
        }
    }

    // MARK: First launch

    private func startOnboardingIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: "onboarded") else { return }
        guard !awake.watcher.installed.isEmpty else {
            UserDefaults.standard.set(true, forKey: "onboarded")
            return
        }
        model.onboarding = true
        expand()
    }

    /// Called by the onboarding card buttons.
    func finishOnboarding(watch: Bool) {
        UserDefaults.standard.set(true, forKey: "onboarded")
        awake.setWatchEnabled(watch)
        withAnimation(.easeInOut(duration: 0.25)) { model.onboarding = false }
        handleMouse()
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
        let size = CGSize(width: 440, height: h + 150)
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
            setQuitKey(inside || model.menuOpen)
            if inside || model.menuOpen || model.popoverOpen || model.onboarding { cancelPending() } else { schedule(.collapse, ms: 260) }
        } else {
            // With ears out only the notch itself expands the panel; the ears take clicks and scrolls.
            let hotSize = model.earShown ? model.notchSize : Layout.size(model)
            let hot = rect(hotSize).insetBy(dx: -4, dy: 0).contains(p)
            if hot { schedule(.expand, ms: 60) } else { cancelPending() }
        }
    }

    /// The single (right) ear of the collapsed notch, in screen coordinates.
    private func earRects() -> [CGRect] {
        guard model.earShown, !model.isExpanded, !model.intro else { return [] }
        let n = model.notchSize
        return [CGRect(x: midX + n.width / 2, y: top - n.height, width: Layout.ear, height: n.height + 2)]
    }

    private func setQuitKey(_ on: Bool) {
        if on, quitKey == nil {
            quitKey = HotKey(id: 2, keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(cmdKey)) {
                MainActor.assumeIsolated { NSApp.terminate(nil) }
            }
        } else if !on, quitKey != nil {
            quitKey = nil
        }
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
        guard model.isExpanded, !model.menuOpen, !model.popoverOpen, !model.onboarding else { return }
        setQuitKey(false)
        model.isExpanded = false
        panel?.ignoresMouseEvents = true
        watchdog?.invalidate()
        watchdog = nil
    }
}
