import AppKit
import Darwin
import Observation
import UniformTypeIdentifiers

/// How awake. follows one app.
enum WatchMode: String, CaseIterable {
    case render, download, open, off

    var title: String {
        switch self {
        case .render: return "Пока работает (рендер, экспорт)"
        case .download: return "Пока качает"
        case .open: return "Пока открыто"
        case .off: return "Не следить"
        }
    }

    var short: String {
        switch self {
        case .render: return "Рендер и экспорт"
        case .download: return "Загрузка"
        case .open: return "Пока открыта"
        case .off: return "Не следить"
        }
    }

    var verb: String {
        switch self {
        case .render: return "рендер"
        case .download: return "качает"
        case .open: return "открыт"
        case .off: return ""
        }
    }
}

struct WatchRule: Identifiable, Hashable {
    let id: String
    let title: String
    /// Lower-cased name fragments matched against the app name (built-in rules).
    let tokens: [String]
    var mode: WatchMode
    /// Added by the user: matched by bundle ID (= id).
    let custom: Bool
}

/// Follows the user's apps: keeps the Mac awake while they render / download / are open.
/// Render = the app (all processes inside its bundle) uses > 0.6 CPU core or writes > 2 MB/s.
/// Download = writes > 150 KB/s to disk or uses > 0.15 core. Both hold for 2 min after the last activity.
@MainActor
@Observable
final class Watcher {
    static let grace: TimeInterval = 120

    private static let builtIn: [(id: String, title: String, tokens: [String], mode: WatchMode)] = [
        ("photoshop", "Photoshop", ["photoshop"], .render),
        ("lightroom", "Lightroom", ["lightroom"], .render),
        ("bridge", "Bridge", ["adobe bridge"], .render),
        ("captureone", "Capture One", ["capture one"], .render),
        ("dodgeburn", "Retouch4me Dodge & Burn", ["dodge burn", "dodge & burn", "dodge&burn"], .render),
        ("reblum", "Reblum", ["reblum"], .render),
        ("capcut", "CapCut", ["capcut"], .render),
        ("davinci", "DaVinci Resolve", ["davinci resolve"], .render),
        ("teleo", "Teleo.", ["teleo"], .open),
        ("toreo", "toreo.", ["toreo"], .download)
    ]

    private(set) var enabled: Bool
    private(set) var rules: [WatchRule]
    /// Rule IDs whose app is open.
    private(set) var running: Set<String> = []
    /// Rule IDs that keep the Mac awake right now (in list order).
    private(set) var active: [String] = []

    @ObservationIgnored private var lastBusy: [String: Date] = [:]
    @ObservationIgnored private var previous: [String: (cpu: Double, disk: UInt64, at: Date)] = [:]
    @ObservationIgnored private var icons: [String: NSImage] = [:]
    @ObservationIgnored private var installedCache: [URL]?
    private let ticksToSeconds: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom) / 1_000_000_000
    }()

    init() {
        let d = UserDefaults.standard
        enabled = d.object(forKey: "watchEnabled") as? Bool ?? true
        let modes = d.dictionary(forKey: "watchModes") as? [String: String] ?? [:]
        var list = Self.builtIn.map { b in
            WatchRule(id: b.id, title: b.title, tokens: b.tokens,
                      mode: modes[b.id].flatMap(WatchMode.init(rawValue:)) ?? b.mode, custom: false)
        }
        for c in d.array(forKey: "watchCustom") as? [[String: String]] ?? [] {
            guard let id = c["id"], let title = c["title"] else { continue }
            list.append(WatchRule(id: id, title: title, tokens: [],
                                  mode: modes[id].flatMap(WatchMode.init(rawValue:)) ?? .render, custom: true))
        }
        rules = list
    }

    // MARK: Settings

    func setEnabled(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(on, forKey: "watchEnabled")
        if !on { active = []; lastBusy = [:] }
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
        panel.prompt = "Следить"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url,
              let id = Bundle(url: url)?.bundleIdentifier,
              !rules.contains(where: { $0.id == id }) else { return }
        rules.append(WatchRule(id: id, title: url.deletingPathExtension().lastPathComponent, tokens: [], mode: .render, custom: true))
        save()
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(Dictionary(uniqueKeysWithValues: rules.map { ($0.id, $0.mode.rawValue) }), forKey: "watchModes")
        d.set(rules.filter(\.custom).map { ["id": $0.id, "title": $0.title] }, forKey: "watchCustom")
    }

    // MARK: Text and icons

    func rule(_ id: String) -> WatchRule? { rules.first { $0.id == id } }

    func icon(for rule: WatchRule) -> NSImage? {
        if let cached = icons[rule.id] { return cached }
        let url: URL?
        if rule.custom {
            url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: rule.id)
        } else {
            if installedCache == nil { installedCache = Self.scanInstalledApps() }
            url = installedCache?.first { matches(rule, name: $0.deletingPathExtension().lastPathComponent) }
        }
        guard let url else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 40, height: 40)
        icons[rule.id] = image
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
                guard let u = usage[rule.id] else { continue }
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
                if let last = lastBusy[rule.id], now.timeIntervalSince(last) < Self.grace { next.append(rule.id) }
            }
        }
        if next != active { active = next }
    }

    // MARK: Matching

    private func matches(_ rule: WatchRule, app: NSRunningApplication) -> Bool {
        if rule.custom { return app.bundleIdentifier == rule.id }
        if let name = app.localizedName, matches(rule, name: name) { return true }
        if let file = app.bundleURL?.deletingPathExtension().lastPathComponent, matches(rule, name: file) { return true }
        return false
    }

    private func matches(_ rule: WatchRule, name: String) -> Bool {
        let n = name.lowercased()
        return rule.tokens.contains { n.contains($0) }
    }

    /// .app bundles in /Applications and ~/Applications, one folder deep (Adobe, DaVinci…).
    private static func scanInstalledApps() -> [URL] {
        let fm = FileManager.default
        var result: [URL] = []
        let roots = [URL(fileURLWithPath: "/Applications"), fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        for root in roots {
            guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
            for item in items {
                if item.pathExtension == "app" {
                    result.append(item)
                } else if let inner = try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil) {
                    result += inner.filter { $0.pathExtension == "app" }
                }
            }
        }
        return result.filter { !$0.lastPathComponent.lowercased().contains("uninstall") }
    }

    // MARK: Process accounting

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
