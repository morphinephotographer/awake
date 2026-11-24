import AppKit
import Darwin
import IOKit.pwr_mgt
import Observation
import UniformTypeIdentifiers

/// How awake. follows one app.
enum WatchMode: String, CaseIterable {
    case render, download, open, off

    var title: String {
        switch self {
        case .render: return tr("Пока работает (рендер, экспорт)")
        case .download: return tr("Пока качает")
        case .open: return tr("Пока открыто")
        case .off: return tr("Не следить")
        }
    }

    var short: String {
        switch self {
        case .render: return tr("Рендер и экспорт")
        case .download: return tr("Загрузка")
        case .open: return tr("Пока открыта")
        case .off: return tr("Не следить")
        }
    }

    var verb: String {
        switch self {
        case .render: return tr("рендер")
        case .download: return tr("качает")
        case .open: return tr("открыт")
        case .off: return ""
        }
    }
}

struct WatchRule: Identifiable, Hashable {
    let id: String
    let title: String
    /// Bundle ID prefixes (catalog) or the exact bundle ID (custom).
    let bundles: [String]
    /// Lower-cased name fragments, used when the bundle ID is unknown.
    let names: [String]
    var mode: WatchMode
    let defaultMode: WatchMode
    let custom: Bool
}

/// An app outside the list that looks busy — awake. offers to follow it.
struct WatchSuggestion: Identifiable, Hashable {
    let id: String      // bundle ID
    let title: String
    let reason: String
}

/// Follows the user's apps and keeps the Mac awake while they render / download / are open.
/// Busy = the app (all processes inside its bundle) holds a "don't sleep" assertion, uses > 0.6 CPU core
/// or writes > 2 MB/s (render); writes > 150 KB/s (download). Holds 2 min after the last activity.
@MainActor
@Observable
final class Watcher {
    static let grace: TimeInterval = 120
    /// Weekly catalog refresh. The repository has to be public for other people to receive updates.
    static let catalogURL = URL(string: "https://raw.githubusercontent.com/morphinephotographer/awake./main/Resources/catalog.json")!

    private(set) var enabled: Bool
    private(set) var rules: [WatchRule] = []
    /// Rule IDs whose app is installed on this Mac.
    private(set) var installed: Set<String> = []
    /// Rule IDs whose app is open.
    private(set) var running: Set<String> = []
    /// Rule IDs that keep the Mac awake right now (in list order).
    private(set) var active: [String] = []
    /// Busy apps outside the list.
    private(set) var suggestions: [WatchSuggestion] = []

    @ObservationIgnored private var lastBusy: [String: Date] = [:]
    @ObservationIgnored private var previous: [String: (cpu: Double, disk: UInt64, at: Date)] = [:]
    @ObservationIgnored private var icons: [String: NSImage] = [:]
    @ObservationIgnored private var installedApps: [(url: URL, bundleID: String?, name: String)] = []
    @ObservationIgnored private var strangerCPU: [String: (cpu: Double, at: Date)] = [:]
    @ObservationIgnored private var strangerBusySince: [String: Date] = [:]
    @ObservationIgnored private var dismissed: Set<String>
    private let ticksToSeconds: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom) / 1_000_000_000
    }()

    init() {
        let d = UserDefaults.standard
        enabled = d.object(forKey: "watchEnabled") as? Bool ?? true
        dismissed = Set(d.stringArray(forKey: "watchDismissed") ?? [])
        installedApps = Self.scanInstalledApps()
        rebuild(catalog: Self.loadCatalog())
        refreshCatalogIfNeeded()
    }

    /// Rules worth showing in the menu: installed, open, added by hand or changed by the user.
    var visibleRules: [WatchRule] {
        rules.filter { installed.contains($0.id) || running.contains($0.id) || $0.custom || $0.mode != $0.defaultMode }
    }

    // MARK: Settings

    func setEnabled(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(on, forKey: "watchEnabled")
        if !on { active = []; lastBusy = [:]; suggestions = [] }
    }

    func setMode(_ mode: WatchMode, for id: String) {
        guard let i = rules.firstIndex(where: { $0.id == id }) else { return }
        if mode == .off && rules[i].custom {
            rules.remove(at: i)
        } else {
            rules[i].mode = mode
        }
        lastBusy[id] = nil
        active.removeAll { $0 == id }
        save()
    }

    /// Lets the user pick any app in /Applications.
    func addCustomApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.prompt = tr("Следить")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url,
              let id = Bundle(url: url)?.bundleIdentifier else { return }
        addCustom(id: id, title: url.deletingPathExtension().lastPathComponent)
    }

    /// Accept a suggestion: follow this app while it works.
    func accept(_ s: WatchSuggestion) {
        addCustom(id: s.id, title: s.title)
        suggestions.removeAll { $0.id == s.id }
    }

    /// Decline a suggestion for good.
    func dismiss(_ s: WatchSuggestion) {
        dismissed.insert(s.id)
        UserDefaults.standard.set(Array(dismissed), forKey: "watchDismissed")
        suggestions.removeAll { $0.id == s.id }
    }

    private func addCustom(id: String, title: String) {
        guard !rules.contains(where: { $0.id == id }) else { return }
        rules.append(WatchRule(id: id, title: title, bundles: [id], names: [], mode: .render, defaultMode: .render, custom: true))
        save()
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(Dictionary(uniqueKeysWithValues: rules.map { ($0.id, $0.mode.rawValue) }), forKey: "watchModes")
        d.set(rules.filter(\.custom).map { ["id": $0.id, "title": $0.title] }, forKey: "watchCustom")
    }

    // MARK: Catalog

    private struct Catalog: Decodable {
        struct App: Decodable {
            let id: String
            let title: String
            let bundles: [String]
            let names: [String]
            let mode: String
        }
        let version: Int
        let apps: [App]
    }

    private static var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("awake", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("catalog.json")
    }

    /// The newer of the bundled catalog and the downloaded one.
    private static func loadCatalog() -> Catalog? {
        let decoder = JSONDecoder()
        let bundled = Bundle.main.url(forResource: "catalog", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }.flatMap { try? decoder.decode(Catalog.self, from: $0) }
        let cached = (try? Data(contentsOf: cacheURL)).flatMap { try? decoder.decode(Catalog.self, from: $0) }
        switch (bundled, cached) {
        case let (b?, c?): return c.version > b.version ? c : b
        case let (b?, nil): return b
        case let (nil, c?): return c
        default: return nil
        }
    }

    private func rebuild(catalog: Catalog?) {
        let d = UserDefaults.standard
        let modes = d.dictionary(forKey: "watchModes") as? [String: String] ?? [:]
        var list: [WatchRule] = (catalog?.apps ?? []).map { a in
            let def = WatchMode(rawValue: a.mode) ?? .render
            return WatchRule(id: a.id, title: a.title, bundles: a.bundles, names: a.names.map { $0.lowercased() },
                             mode: modes[a.id].flatMap(WatchMode.init(rawValue:)) ?? def, defaultMode: def, custom: false)
        }
        for c in d.array(forKey: "watchCustom") as? [[String: String]] ?? [] {
            guard let id = c["id"], let title = c["title"], !list.contains(where: { $0.id == id }) else { continue }
            list.append(WatchRule(id: id, title: title, bundles: [id], names: [],
                                  mode: modes[id].flatMap(WatchMode.init(rawValue:)) ?? .render, defaultMode: .render, custom: true))
        }
        rules = list
        installed = Set(list.filter { rule in installedApps.contains { matches(rule, bundleID: $0.bundleID, name: $0.name) } }.map(\.id))
        icons = [:]
    }

    /// Downloads a newer catalog at most once a week.
    private func refreshCatalogIfNeeded() {
        let d = UserDefaults.standard
        if let last = d.object(forKey: "catalogChecked") as? Date, Date().timeIntervalSince(last) < 7 * 24 * 3600 { return }
        d.set(Date(), forKey: "catalogChecked")
        Task { @MainActor [weak self] in
            guard let (data, response) = try? await URLSession.shared.data(from: Self.catalogURL),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let fresh = try? JSONDecoder().decode(Catalog.self, from: data),
                  fresh.version > (Self.loadCatalog()?.version ?? 0) else { return }
            try? data.write(to: Self.cacheURL, options: .atomic)
            self?.rebuild(catalog: fresh)
        }
    }

    // MARK: Text and icons

    func rule(_ id: String) -> WatchRule? { rules.first { $0.id == id } }

    func icon(for rule: WatchRule) -> NSImage? {
        if let cached = icons[rule.id] { return cached }
        let url = installedApps.first { matches(rule, bundleID: $0.bundleID, name: $0.name) }?.url
            ?? NSWorkspace.shared.runningApplications.first { matches(rule, app: $0) }?.bundleURL
        guard let url else { return nil }
        return cacheIcon(NSWorkspace.shared.icon(forFile: url.path), id: rule.id)
    }

    func icon(for s: WatchSuggestion) -> NSImage? {
        if let cached = icons[s.id] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: s.id) else { return nil }
        return cacheIcon(NSWorkspace.shared.icon(forFile: url.path), id: s.id)
    }

    private func cacheIcon(_ image: NSImage, id: String) -> NSImage {
        image.size = NSSize(width: 40, height: 40)
        icons[id] = image
        return image
    }

    // MARK: Sampling (every few seconds)

    func sample(now: Date) {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        var open: [String: [String]] = [:] // rule id → bundle paths
        for rule in rules {
            let hits = apps.filter { matches(rule, app: $0) }
            if !hits.isEmpty { open[rule.id] = hits.compactMap { $0.bundleURL?.path } }
        }
        if Set(open.keys) != running { running = Set(open.keys) }
        guard enabled else {
            if !active.isEmpty { active = [] }
            return
        }

        // Paths of processes that ask macOS not to sleep (export / render in many apps).
        let blockers = Self.sleepBlockerPaths()

        // Resource use only for render / download apps that are open.
        var targets: [String: [String]] = [:]
        for rule in rules where rule.mode == .render || rule.mode == .download {
            if let paths = open[rule.id] { targets[rule.id] = paths.map { $0.hasSuffix("/") ? $0 : $0 + "/" } }
        }
        let usage = targets.isEmpty ? [:] : measure(targets)

        var next: [String] = []
        for rule in rules {
            guard open[rule.id] != nil else {
                previous[rule.id] = nil
                lastBusy[rule.id] = nil
                continue
            }
            switch rule.mode {
            case .off:
                continue
            case .open:
                next.append(rule.id)
            case .render, .download:
                let prefixes = targets[rule.id] ?? []
                if blockers.contains(where: { path in prefixes.contains { path.hasPrefix($0) } }) {
                    lastBusy[rule.id] = now
                }
                if let u = usage[rule.id] {
                    if let p = previous[rule.id] {
                        let dt = now.timeIntervalSince(p.at)
                        if dt > 0.5 {
                            let cores = max(0, u.cpu - p.cpu) / dt
                            let disk = u.disk >= p.disk ? Double(u.disk - p.disk) / dt : 0
                            let busy = rule.mode == .render
                                ? (cores > 0.6 || disk > 2_000_000)
                                : (disk > 150_000 || cores > 0.15)
                            if busy { lastBusy[rule.id] = now }
                        }
                    }
                    previous[rule.id] = (u.cpu, u.disk, now)
                }
                if let last = lastBusy[rule.id], now.timeIntervalSince(last) < Self.grace { next.append(rule.id) }
            }
        }
        if next != active { active = next }

        lookForStrangers(apps: apps, blockers: blockers, now: now)
    }

    /// Apps outside the list that hold a "don't sleep" assertion or use > 1.2 cores for a minute.
    private func lookForStrangers(apps: [NSRunningApplication], blockers: [String], now: Date) {
        var found: [WatchSuggestion] = []
        let me = Bundle.main.bundleIdentifier
        for app in apps {
            guard let id = app.bundleIdentifier, id != me, !dismissed.contains(id),
                  !rules.contains(where: { matches($0, app: app) }),
                  let path = app.bundleURL?.path else { continue }
            let name = app.localizedName ?? id
            let prefix = path.hasSuffix("/") ? path : path + "/"
            if blockers.contains(where: { $0.hasPrefix(prefix) }) {
                found.append(WatchSuggestion(id: id, title: name, reason: tr("сам просит Mac не засыпать")))
                continue
            }
            let cpu = cpuSeconds(pid: app.processIdentifier)
            if let p = strangerCPU[id], now.timeIntervalSince(p.at) > 0.5 {
                let cores = max(0, cpu - p.cpu) / now.timeIntervalSince(p.at)
                if cores > 1.2 {
                    if strangerBusySince[id] == nil { strangerBusySince[id] = now }
                } else {
                    strangerBusySince[id] = nil
                }
            }
            strangerCPU[id] = (cpu, now)
            if let since = strangerBusySince[id], now.timeIntervalSince(since) >= 60 {
                found.append(WatchSuggestion(id: id, title: name, reason: tr("больше минуты сильно грузит процессор")))
            }
        }
        let runningIDs = Set(apps.compactMap(\.bundleIdentifier))
        strangerCPU = strangerCPU.filter { runningIDs.contains($0.key) }
        strangerBusySince = strangerBusySince.filter { runningIDs.contains($0.key) }
        // Keep a suggestion while the app is open, even if it calmed down.
        let kept = suggestions.filter { s in runningIDs.contains(s.id) && !found.contains { $0.id == s.id } && !rules.contains { $0.id == s.id } }
        let next = kept + found
        if next != suggestions { suggestions = next }
    }

    // MARK: Matching

    private func matches(_ rule: WatchRule, app: NSRunningApplication) -> Bool {
        if matches(rule, bundleID: app.bundleIdentifier, name: app.localizedName ?? "") { return true }
        if let file = app.bundleURL?.deletingPathExtension().lastPathComponent {
            return matches(rule, bundleID: app.bundleIdentifier, name: file)
        }
        return false
    }

    private func matches(_ rule: WatchRule, bundleID: String?, name: String) -> Bool {
        if rule.custom { return bundleID == rule.id }
        if let bundleID, rule.bundles.contains(where: { bundleID.hasPrefix($0) }) { return true }
        let n = name.lowercased()
        return rule.names.contains { n.contains($0) }
    }

    /// .app bundles in /Applications and ~/Applications, one folder deep (Adobe, DaVinci…).
    private static func scanInstalledApps() -> [(url: URL, bundleID: String?, name: String)] {
        let fm = FileManager.default
        var urls: [URL] = []
        let roots = [URL(fileURLWithPath: "/Applications"), fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        for root in roots {
            guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
            for item in items {
                if item.pathExtension == "app" {
                    urls.append(item)
                } else if let inner = try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil) {
                    urls += inner.filter { $0.pathExtension == "app" }
                }
            }
        }
        return urls
            .filter { !$0.lastPathComponent.lowercased().contains("uninstall") }
            .map { (url: $0, bundleID: Bundle(url: $0)?.bundleIdentifier, name: $0.deletingPathExtension().lastPathComponent) }
    }

    // MARK: Process accounting

    /// Executable paths of processes holding a system-sleep assertion (not awake. itself).
    private static func sleepBlockerPaths() -> [String] {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
              let dict = unmanaged?.takeRetainedValue() as NSDictionary? else { return [] }
        let me = getpid()
        let types: Set<String> = [kIOPMAssertionTypePreventUserIdleSystemSleep, kIOPMAssertionTypePreventSystemSleep, "NoIdleSleepAssertion"]
        var result: [String] = []
        var buffer = [CChar](repeating: 0, count: 4096)
        for (key, value) in dict {
            guard let pid = (key as? NSNumber)?.int32Value, pid != me,
                  let list = value as? [[String: Any]] else { continue }
            let blocks = list.contains { a in
                guard let type = a[kIOPMAssertionTypeKey] as? String, types.contains(type) else { return false }
                return ((a[kIOPMAssertionLevelKey] as? Int) ?? 255) != 0
            }
            guard blocks, proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
            result.append(String(cString: buffer))
        }
        return result
    }

    private func cpuSeconds(pid: pid_t) -> Double {
        var info = rusage_info_v2()
        let ok = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        guard ok == 0 else { return 0 }
        return Double(info.ri_user_time &+ info.ri_system_time) * ticksToSeconds
    }

    /// Total CPU seconds and bytes written for all processes whose executable lives inside the given bundles.
    private func measure(_ targets: [String: [String]]) -> [String: (cpu: Double, disk: UInt64)] {
        var result: [String: (cpu: Double, disk: UInt64)] = [:]
        for id in targets.keys { result[id] = (0, 0) }

        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return result }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = pids.withUnsafeMutableBufferPointer { buf in
            proc_listallpids(buf.baseAddress, Int32(buf.count * MemoryLayout<pid_t>.stride))
        }
        var pathBuffer = [CChar](repeating: 0, count: 4096)
        for pid in pids.prefix(Int(max(0, filled))) where pid > 0 {
            let len = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            guard len > 0 else { continue }
            let path = String(cString: pathBuffer)
            guard let id = targets.first(where: { $0.value.contains { path.hasPrefix($0) } })?.key else { continue }
            var info = rusage_info_v2()
            let ok = withUnsafeMutablePointer(to: &info) { ptr in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
                }
            }
            guard ok == 0 else { continue }
            let cpu = Double(info.ri_user_time &+ info.ri_system_time) * ticksToSeconds
            let current = result[id] ?? (0, 0)
            result[id] = (current.cpu + cpu, current.disk &+ info.ri_diskio_byteswritten)
        }
        return result
    }
}
