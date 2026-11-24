import AppKit
import Foundation
import Observation
import UserNotifications

// MARK: - Notifications

/// "Capture One — render finished · 42 min".
@MainActor
enum Notifier {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error { NSLog("awake.: notifications \(error)") }
        }
    }

    static func jobDone(_ rule: WatchRule, worked: TimeInterval, after: Awake.AfterDone) {
        let length = spoken(worked)
        var body: String
        switch rule.mode {
        case .download: body = tr("Загрузка завершена · %@", length)
        case .agent: body = tr("Задача выполнена · %@", length)
        default: body = tr("Рендер готов · %@", length)
        }
        switch after {
        case .sleep: body += "\n" + tr("Через минуту Mac уснёт — пошевели мышью, чтобы отменить.")
        case .display: body += "\n" + tr("Через минуту экран погаснет — пошевели мышью, чтобы отменить.")
        case .nothing: break
        }
        post(title: rule.title, body: body)
    }

    static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { NSLog("awake.: notification failed \(error)") }
        }
    }

    /// 42 мин · 1 ч 05 мин
    static func spoken(_ t: TimeInterval) -> String {
        let m = max(1, Int((t / 60).rounded()))
        return m < 60 ? tr("%ld мин", m) : tr("%ld ч %02ld мин", m / 60, m % 60)
    }
}

// MARK: - Updates

private struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browser_download_url: URL
    }
    let tag_name: String
    let assets: [Asset]
}

/// Looks for a newer release on GitHub once a day; installs it in place and restarts.
@MainActor
@Observable
final class Updater {
    static let api = URL(string: "https://api.github.com/repos/morphinephotographer/awake/releases/latest")!
    static let page = URL(string: "https://github.com/morphinephotographer/awake/releases/latest")!

    /// Newer version found on GitHub (nil = up to date or not checked yet).
    private(set) var available: String?
    private(set) var busy = false

    @ObservationIgnored private var zipURL: URL?
    @ObservationIgnored private var timer: Timer?

    static var current: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    init() {
        let t = Timer(timeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.check(manual: false) }
            }
        }
        t.tolerance = 3600
        RunLoop.main.add(t, forMode: .common)
        timer = t
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(30))
            await self?.check(manual: false)
        }
    }

    /// 1.10.0 > 1.9.2
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    func check(manual: Bool) async {
        var request = URLRequest(url: Self.api)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let release = try? JSONDecoder().decode(GitHubRelease.self, from: data) else {
            if manual { Self.alert(tr("Не удалось проверить обновления"), tr("Проверь интернет и попробуй ещё раз.")) }
            return
        }
        let version = release.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        if Self.isNewer(version, than: Self.current),
           let zip = release.assets.first(where: { $0.name.hasSuffix(".zip") })?.browser_download_url {
            available = version
            zipURL = zip
        } else {
            available = nil
            zipURL = nil
            if manual { Self.alert(tr("У тебя последняя версия"), tr("awake. %@ — новее пока нет.", Self.current)) }
        }
    }

    /// Downloads the zip, checks it is awake. and newer, swaps the app in place and starts the new one.
    /// If anything goes wrong, opens the release page instead.
    func install() {
        guard let zipURL, !busy else { return }
        busy = true
        Task { @MainActor in
            do {
                let (downloaded, response) = try await URLSession.shared.download(from: zipURL)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CocoaError(.fileReadUnknown) }
                let fm = FileManager.default
                let work = fm.temporaryDirectory.appendingPathComponent("awake-update-\(UUID().uuidString)")
                try fm.createDirectory(at: work, withIntermediateDirectories: true)
                let zip = work.appendingPathComponent("awake.zip")
                try fm.moveItem(at: downloaded, to: zip)
                try await Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])

                let fresh = work.appendingPathComponent("awake.app")
                guard let bundle = Bundle(url: fresh),
                      bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
                      let v = bundle.infoDictionary?["CFBundleShortVersionString"] as? String,
                      Self.isNewer(v, than: Self.current) else { throw CocoaError(.fileReadCorruptFile) }

                let target = Bundle.main.bundleURL
                let old = work.appendingPathComponent("old.app")
                try fm.moveItem(at: target, to: old)
                do {
                    try fm.moveItem(at: fresh, to: target)
                } catch {
                    try? fm.moveItem(at: old, to: target)
                    throw error
                }
                Self.relaunch(target)
            } catch {
                NSLog("awake.: update failed \(error)")
                self.busy = false
                NSWorkspace.shared.open(Self.page)
            }
        }
    }

    private static func run(_ tool: String, _ args: [String]) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            p.terminationHandler = { proc in
                if proc.terminationStatus == 0 { cont.resume() } else { cont.resume(throwing: CocoaError(.fileWriteUnknown)) }
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }

    /// A tiny shell waits until this process has quit, then opens the new app.
    private static func relaunch(_ app: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"",
                       app.path, String(getpid())]
        try? p.run()
        NSApp.terminate(nil)
    }

    private static func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}
