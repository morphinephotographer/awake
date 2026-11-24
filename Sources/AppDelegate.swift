import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: NotchController?
    private var pendingURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = NotchController()
        controller.start()
        self.controller = controller
        pendingURLs.forEach(controller.handle)
        pendingURLs.removeAll()
    }

    /// awake://toggle · awake://stop · awake://start?minutes=90 · awake://until?time=18:30 · awake://activity
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let controller else { pendingURLs += urls; return }
        urls.forEach(controller.handle)
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.awake.stop()
    }
}
