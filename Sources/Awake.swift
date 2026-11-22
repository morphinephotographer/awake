import AppKit
import Foundation
import IOKit.pwr_mgt
import Observation
import ServiceManagement

/// Keeps the Mac awake with IOKit power assertions (the same mechanism Amphetamine uses).
@MainActor
@Observable
final class Awake {
    /// 0 = without limit.
    static let durations: [TimeInterval] = [15 * 60, 60 * 60, 2 * 3600, 4 * 3600, 0]

    static func label(_ d: TimeInterval) -> String {
        switch d {
        case 0: return "∞"
        case ..<3600: return "\(Int(d / 60))м"
        default: return "\(Int(d / 3600))ч"
        }
    }

    private(set) var isActive = false
    private(set) var endDate: Date?
    private(set) var now = Date()
    private(set) var duration: TimeInterval
    private(set) var keepDisplay: Bool
    private(set) var startDate: Date?
    /// Keep working with the lid closed (via the root guard + pmset disablesleep).
    private(set) var lidMode: Bool
    @ObservationIgnored private var lastLidWrite: Date?

    @ObservationIgnored private var systemID: IOPMAssertionID = 0
    @ObservationIgnored private var displayID: IOPMAssertionID = 0
    @ObservationIgnored private var ticker: Timer?

    init() {
        let d = UserDefaults.standard
        duration = d.object(forKey: "duration") as? Double ?? 3600
        keepDisplay = d.object(forKey: "keepDisplay") as? Bool ?? true
        lidMode = (d.object(forKey: "lidMode") as? Bool ?? false) && LidGuard.isInstalled
        LidGuard.clear()
    }

    // MARK: Actions

    func toggle() {
        if isActive { stop() } else { start(duration) }
    }

    func start(_ d: TimeInterval) {
        releaseAll()
        duration = d
        UserDefaults.standard.set(d, forKey: "duration")
        guard let id = makeAssertion(display: false, timeout: d) else {
            NSLog("awake.: could not create system assertion")
            stop()
            return
        }
        systemID = id
        if keepDisplay { displayID = makeAssertion(display: true, timeout: d) ?? 0 }
        now = Date()
        startDate = now
        endDate = d > 0 ? now.addingTimeInterval(d) : nil
        isActive = true
        startTicker()
        syncLid(force: true)
    }

    func stop() {
        releaseAll()
        isActive = false
        endDate = nil
        startDate = nil
        ticker?.invalidate()
        ticker = nil
        syncLid(force: true)
    }

    func setLidMode(_ on: Bool) {
        if on && !LidGuard.isInstalled {
            guard LidGuard.install() else { return }
        }
        lidMode = on
        UserDefaults.standard.set(on, forKey: "lidMode")
        syncLid(force: true)
    }

    /// Writes / renews / removes the request the root guard watches.
    private func syncLid(force: Bool = false) {
        guard isActive, lidMode else {
            if lastLidWrite != nil || force { LidGuard.clear() }
            lastLidWrite = nil
            return
        }
        if !force, let last = lastLidWrite, now.timeIntervalSince(last) < 60 { return }
        let horizon = now.addingTimeInterval(300)
        let deadline = endDate.map { min($0, horizon) } ?? horizon
        LidGuard.write(deadline: deadline)
        lastLidWrite = now
    }

    func setKeepDisplay(_ on: Bool) {
        keepDisplay = on
        UserDefaults.standard.set(on, forKey: "keepDisplay")
        guard isActive else { return }
        if on, displayID == 0 {
            displayID = makeAssertion(display: true, timeout: remaining ?? 0) ?? 0
        } else if !on, displayID != 0 {
            IOPMAssertionRelease(displayID)
            displayID = 0
        }
    }

    // MARK: Text

    var remaining: TimeInterval? {
        endDate.map { max(0, $0.timeIntervalSince(now)) }
    }

    /// Compact text for the collapsed notch ears.
    var shortText: String {
        guard isActive else { return "" }
        guard let r = remaining else { return "∞" }
        let s = Int(r.rounded(.up))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? "\(h)ч\(String(format: "%02d", m))" : String(format: "%d:%02d", m, sec)
    }

    var longText: String {
        guard isActive else { return "спит по расписанию" }
        guard let r = remaining else { return "не спит" }
        let s = Int(r.rounded(.up))
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    var untilText: String {
        guard isActive else { return "" }
        guard let end = endDate else { return "без ограничений" }
        return "до \(Self.hm.string(from: end))"
    }

    private static let hm: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    /// Whole seconds since start — drives the clock's second hand.
    var elapsed: Double {
        startDate.map { max(0, now.timeIntervalSince($0)).rounded() } ?? 0
    }

    /// Part of the session that is left (1 for an unlimited session).
    var fraction: Double {
        guard isActive, duration > 0, let r = remaining else { return 1 }
        return min(1, r / duration)
    }

    // MARK: Private

    private func startTicker() {
        ticker?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func tick() {
        now = Date()
        if let r = remaining, r <= 0 { stop() } else { syncLid() }
    }

    private func releaseAll() {
        if displayID != 0 { IOPMAssertionRelease(displayID); displayID = 0 }
        if systemID != 0 { IOPMAssertionRelease(systemID); systemID = 0 }
    }

    private func makeAssertion(display: Bool, timeout: TimeInterval) -> IOPMAssertionID? {
        var props: [String: Any] = [
            kIOPMAssertionTypeKey: display ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep,
            kIOPMAssertionNameKey: display ? "awake. — экран не гаснет" : "awake. — Mac не засыпает",
            kIOPMAssertionLevelKey: kIOPMAssertionLevelOn
        ]
        if timeout > 0 {
            props[kIOPMAssertionTimeoutKey] = max(1, ceil(timeout))
            props[kIOPMAssertionTimeoutActionKey] = kIOPMAssertionTimeoutActionTurnOff
        }
        var id: IOPMAssertionID = 0
        let code = IOPMAssertionCreateWithProperties(props as CFDictionary, &id)
        return code == kIOReturnSuccess ? id : nil
    }
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func toggle() {
        do {
            if isEnabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch {
            NSLog("awake.: login item error \(error)")
        }
    }
}

/// Root helper that turns `pmset disablesleep` on while awake. asks for it.
enum LidGuard {
    static let helper = "/Library/PrivilegedHelperTools/local.morphine.awake.guard"
    static let plist = "/Library/LaunchDaemons/local.morphine.awake.guard.plist"
    static let dir = "/Users/Shared/awake"
    static let request = "/Users/Shared/awake/lid-request"

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: helper) && FileManager.default.fileExists(atPath: plist)
    }

    /// Shows the standard macOS admin password prompt once and installs the guard.
    @MainActor
    static func install() -> Bool {
        guard let res = Bundle.main.resourcePath else { return false }
        let cmd = "/bin/sh " + quote(res + "/install-guard.sh") + " \(getuid()) " + quote(res)
        let escaped = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with prompt \"awake. хочет, чтобы Mac работал с закрытой крышкой.\" with administrator privileges"
        var error: NSDictionary?
        NSApp.activate(ignoringOtherApps: true)
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { NSLog("awake.: guard install failed \(error)"); return false }
        return isInstalled
    }

    static func write(deadline: Date) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        }
        let line = "\(Int(deadline.timeIntervalSince1970.rounded(.up))) \(getpid())\n"
        try? line.write(toFile: request, atomically: true, encoding: .utf8)
    }

    static func clear() {
        try? FileManager.default.removeItem(atPath: request)
    }

    private static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
