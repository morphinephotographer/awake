import AppKit
import Darwin
import Foundation
import IOKit.ps
import IOKit.pwr_mgt
import Observation
import ServiceManagement

/// Keeps the Mac awake with IOKit power assertions (the same mechanism Amphetamine uses).
@MainActor
@Observable
final class Awake {
    /// Why the current session runs.
    enum Reason { case manual, apps, activity }

    /// 0 = without limit.
    static let durations: [TimeInterval] = [15 * 60, 60 * 60, 2 * 3600, 4 * 3600, 0]
    /// Activity mode: stop after this long without load.
    static let idleGrace: TimeInterval = 3 * 60

    static func label(_ d: TimeInterval) -> String {
        switch d {
        case 0: return "∞"
        case ..<3600: return "\(Int(d / 60))м"
        default: return "\(Int(d / 3600))ч"
        }
    }

    private(set) var isActive = false
    private(set) var reason: Reason = .manual
    private(set) var endDate: Date?
    private(set) var now = Date()
    /// Length of the current timed session (for the clock).
    private(set) var duration: TimeInterval = 3600
    /// Preset the current session was started from (nil for "until", auto modes, after ±15 min).
    private(set) var activePreset: TimeInterval?
    /// Last chosen preset — what ⏻ starts.
    private(set) var savedPreset: TimeInterval
    private(set) var keepDisplay: Bool
    private(set) var startDate: Date?
    /// Keep working with the lid closed (via the root guard + pmset disablesleep).
    private(set) var lidMode: Bool
    /// Follows the user's apps (render / download / open).
    let watcher: Watcher
    /// Stop when on battery at or below this percent (0 = never).
    private(set) var batteryLimit: Int

    /// Called once per timed session when one minute is left.
    @ObservationIgnored var onEndingSoon: (() -> Void)?

    @ObservationIgnored private var lastLidWrite: Date?
    @ObservationIgnored private var systemID: IOPMAssertionID = 0
    @ObservationIgnored private var displayID: IOPMAssertionID = 0
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var tickCount = 0
    @ObservationIgnored private var warned = false
    @ObservationIgnored private var appSuppressed = false
    @ObservationIgnored private var lastBusy = Date()
    @ObservationIgnored private var lastCPU: (busy: UInt64, total: UInt64) = (0, 0)
    @ObservationIgnored private var lastNet: UInt64 = 0
    @ObservationIgnored private var watchTimer: Timer?

    init() {
        let d = UserDefaults.standard
        let saved = d.object(forKey: "duration") as? Double ?? 3600
        savedPreset = Self.durations.contains(saved) ? saved : 3600
        keepDisplay = d.object(forKey: "keepDisplay") as? Bool ?? true
        lidMode = (d.object(forKey: "lidMode") as? Bool ?? false) && LidGuard.isInstalled
        batteryLimit = d.object(forKey: "batteryLimit") as? Int ?? 10
        watcher = Watcher()
        LidGuard.clear()

        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.watchTick() }
        }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        watchTimer = t
        watchTick()
    }

    // MARK: Actions

    func toggle() {
        if isActive { stop() } else { start(preset: savedPreset) }
    }

    /// Start from one of the presets (15м…∞).
    func start(preset d: TimeInterval) {
        savedPreset = d
        UserDefaults.standard.set(d, forKey: "duration")
        begin(length: d, reason: .manual, preset: d)
    }

    /// Start until a wall-clock time.
    func start(until date: Date) {
        let d = date.timeIntervalSinceNow
        guard d > 30 else { return }
        begin(length: d, reason: .manual, preset: nil)
    }

    /// Stay awake while the CPU or the network is busy.
    func startActivity() {
        lastBusy = Date()
        lastCPU = Self.cpuTicks()
        lastNet = Self.netBytes()
        begin(length: 0, reason: .activity, preset: nil)
    }

    /// Stops the session. A watched app that is still open will not restart it
    /// until the set of running watched apps changes.
    func stop() {
        if !watcher.active.isEmpty { appSuppressed = true }
        end()
    }

    /// ±15 min from the scroll wheel / "+15м". Only for timed sessions.
    func adjust(by delta: TimeInterval) {
        guard isActive, let end = endDate, let start = startDate else { return }
        now = Date()
        let newEnd = max(now.addingTimeInterval(60), end.addingTimeInterval(delta))
        guard newEnd.timeIntervalSince(start) <= 24 * 3600 else { return }
        endDate = newEnd
        duration = newEnd.timeIntervalSince(start)
        activePreset = nil
        if newEnd.timeIntervalSince(now) > 60 { warned = false }
        renewAssertions()
        syncLid(force: true)
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

    func setLidMode(_ on: Bool) {
        if on && !LidGuard.isInstalled {
            guard LidGuard.install() else { return }
        }
        lidMode = on
        UserDefaults.standard.set(on, forKey: "lidMode")
        syncLid(force: true)
    }

    func uninstallLidGuard() {
        guard LidGuard.uninstall() else { return }
        lidMode = false
        UserDefaults.standard.set(false, forKey: "lidMode")
        lastLidWrite = nil
    }

    func setWatchEnabled(_ on: Bool) {
        watcher.setEnabled(on)
        appSuppressed = false
        watchTick()
    }

    func setWatchMode(_ mode: WatchMode, for id: String) {
        watcher.setMode(mode, for: id)
        watchTick()
    }

    func setBatteryLimit(_ pct: Int) {
        batteryLimit = pct
        UserDefaults.standard.set(pct, forKey: "batteryLimit")
        checkBattery()
    }

    // MARK: Text

    var remaining: TimeInterval? {
        endDate.map { max(0, $0.timeIntervalSince(now)) }
    }

    var endingSoon: Bool {
        guard isActive, let r = remaining else { return false }
        return r <= 60
    }

    /// Compact text for the collapsed notch ears.
    var shortText: String {
        guard isActive else { return "" }
        switch reason {
        case .apps: return watchVerb
        case .activity: return "раб"
        case .manual: break
        }
        guard let r = remaining else { return "∞" }
        let s = Int(r.rounded(.up))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? "\(h)ч\(String(format: "%02d", m))" : String(format: "%d:%02d", m, sec)
    }

    var longText: String {
        guard isActive else { return "выкл" }
        switch reason {
        case .apps: return watchVerb
        case .activity: return "работа"
        case .manual: break
        }
        guard let r = remaining else { return "не спит" }
        let s = Int(r.rounded(.up))
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    /// "рендер" / "качает" / "открыт" for the first app that keeps the Mac awake.
    var watchVerb: String {
        watcher.active.first.flatMap { watcher.rule($0)?.mode.verb } ?? "авто"
    }

    var untilText: String {
        guard isActive else { return "" }
        guard let end = endDate else { return "без ограничений" }
        return "до \(Self.hm.string(from: end))"
    }

    static let hm: DateFormatter = {
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

    // MARK: Session core

    private func begin(length d: TimeInterval, reason: Reason, preset: TimeInterval?) {
        releaseAll()
        guard let id = makeAssertion(display: false, timeout: d) else {
            NSLog("awake.: could not create system assertion")
            end()
            return
        }
        systemID = id
        if keepDisplay { displayID = makeAssertion(display: true, timeout: d) ?? 0 }
        now = Date()
        startDate = now
        duration = d
        endDate = d > 0 ? now.addingTimeInterval(d) : nil
        self.reason = reason
        activePreset = preset
        warned = d > 0 && d <= 60
        isActive = true
        startTicker()
        syncLid(force: true)
    }

    private func end() {
        releaseAll()
        isActive = false
        reason = .manual
        endDate = nil
        startDate = nil
        activePreset = nil
        ticker?.invalidate()
        ticker = nil
        syncLid(force: true)
    }

    /// Every 3 s: ask the watcher which apps work, start or end the "apps" session.
    /// A manual stop is respected until all watched apps calm down.
    private func watchTick() {
        watcher.sample(now: Date())
        if !watcher.active.isEmpty {
            if !isActive && !appSuppressed && !batteryLow { begin(length: 0, reason: .apps, preset: nil) }
        } else {
            appSuppressed = false
            if isActive && reason == .apps { end() }
        }
    }

    /// On battery at or below the chosen limit — auto modes must not start.
    private var batteryLow: Bool {
        guard batteryLimit > 0, let b = Self.battery() else { return false }
        return b.onBattery && b.percent <= batteryLimit
    }

    // MARK: Ticker

    private func startTicker() {
        ticker?.invalidate()
        tickCount = 0
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func tick() {
        now = Date()
        tickCount += 1
        if let r = remaining {
            if r <= 0 {
                // Natural end: an open watched app may take over again.
                end()
                appSuppressed = false
                watchTick()
                return
            }
            if r <= 60 && !warned {
                warned = true
                onEndingSoon?()
            }
        }
        if reason == .activity && tickCount % 5 == 0 { sampleActivity() }
        if tickCount % 30 == 0 { checkBattery() }
        syncLid()
    }

    private func sampleActivity() {
        let cpu = Self.cpuTicks()
        let net = Self.netBytes()
        let dTotal = cpu.total &- lastCPU.total
        let load = dTotal > 0 ? Double(cpu.busy &- lastCPU.busy) / Double(dTotal) : 0
        let bytesPerSec = net >= lastNet ? Double(net - lastNet) / 5 : 0
        lastCPU = cpu
        lastNet = net
        if load > 0.25 || bytesPerSec > 300_000 { lastBusy = now }
        if now.timeIntervalSince(lastBusy) > Self.idleGrace { end() }
    }

    private func checkBattery() {
        guard isActive, batteryLimit > 0, let b = Self.battery(), b.onBattery, b.percent <= batteryLimit else { return }
        NSLog("awake.: battery \(b.percent)% ≤ \(batteryLimit)% — stopping")
        stop()
    }

    // MARK: Assertions

    private func renewAssertions() {
        let r = remaining ?? 0
        releaseAll()
        systemID = makeAssertion(display: false, timeout: r) ?? 0
        if keepDisplay { displayID = makeAssertion(display: true, timeout: r) ?? 0 }
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

    /// Writes / renews / removes the request the root lid guard watches.
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

    // MARK: System readings

    static func battery() -> (onBattery: Bool, percent: Int)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let cap = d[kIOPSCurrentCapacityKey] as? Int,
                  let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let onBattery = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSBatteryPowerValue
            return (onBattery, cap * 100 / max)
        }
        return nil
    }

    static func cpuTicks() -> (busy: UInt64, total: UInt64) {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (0, 0) }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        return (user + system + nice, user + system + idle + nice)
    }

    static func netBytes() -> UInt64 {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return 0 }
        defer { freeifaddrs(head) }
        var total: UInt64 = 0
        var cursor = head
        while let entry = cursor {
            let ifa = entry.pointee
            if let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK), let data = ifa.ifa_data,
               !String(cString: ifa.ifa_name).hasPrefix("lo") {
                let stats = data.assumingMemoryBound(to: if_data.self).pointee
                total += UInt64(stats.ifi_ibytes) + UInt64(stats.ifi_obytes)
            }
            cursor = ifa.ifa_next
        }
        return total
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
        return runAsAdmin(cmd, prompt: "awake. хочет, чтобы Mac работал с закрытой крышкой.") && isInstalled
    }

    /// Removes the guard (admin password prompt) and turns disablesleep off if it was on.
    @MainActor
    static func uninstall() -> Bool {
        guard let res = Bundle.main.resourcePath else { return false }
        let cmd = "/bin/sh " + quote(res + "/uninstall-guard.sh")
        return runAsAdmin(cmd, prompt: "awake. удалит помощник для закрытой крышки.") && !isInstalled
    }

    @MainActor
    private static func runAsAdmin(_ cmd: String, prompt: String) -> Bool {
        let escaped = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with prompt \"\(prompt)\" with administrator privileges"
        var error: NSDictionary?
        NSApp.activate(ignoringOtherApps: true)
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { NSLog("awake.: admin script failed \(error)"); return false }
        return true
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
