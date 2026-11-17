#if os(iOS)
import BackgroundTasks
import Foundation
import UserNotifications

/// Background refresh for Bot messages (10.1.1).
///
/// While Bothive is closed, iOS wakes it now and then (about every 15 minutes at best; it decides, not the app). Each time, this asks the
/// computer or server you use for the newest message in every chat and shows a notification for anything new, as if you had
/// been looking at the app. It is a periodic check, not a push service: a reply can wait until the next wake-up, and nothing
/// arrives if iOS Background App Refresh is off, Low Power Mode is on, the app was force-quit, or the computer is asleep.
enum BackgroundCheck {
    static let identifier = "org.opengrokbot.ios.refresh"
    static let enabledKey = "backgroundAlerts"
    private static let watermarkKey = "background.watermark"

    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    // MARK: Choosing what is new (pure, so it can be tested)

    /// Bot messages that arrived after `since` and are finished. A reply still being written waits for the next check.
    static func fresh(in entries: [Entry], since: Date) -> [Entry] {
        entries.filter { $0.kind == .bot && $0.date > since && $0.state != .streaming && $0.state != .stopped }
            .sorted { $0.date < $1.date }
    }

    /// Where the next check starts. Never past a reply that is still streaming, so that reply is announced once it finishes.
    static func nextWatermark(entries: [Entry], current: Date?) -> Date? {
        guard let newest = entries.map(\.date).max() else { return current }
        var next = max(newest, current ?? .distantPast)
        if let streaming = entries.filter({ $0.state == .streaming }).map(\.date).min() { next = min(next, streaming.addingTimeInterval(-0.001)) }
        return max(next, current ?? .distantPast)
    }

    private static var watermark: Date? {
        get { (UserDefaults.standard.object(forKey: watermarkKey) as? Double).map(Date.init(timeIntervalSince1970:)) }
        set { if let newValue { UserDefaults.standard.set(newValue.timeIntervalSince1970, forKey: watermarkKey) } }
    }

    /// The app is open and has seen these messages, so a later background check must not announce them again.
    static func markSeen(_ workspace: Workspace) {
        watermark = nextWatermark(entries: workspace.entries, current: watermark)
    }

    // MARK: Scheduling

    static func schedule() {
        guard enabled else { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier); return }
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Lets this phone read its saved sign-in while locked, which is when most background checks run. Safe to repeat.
    @MainActor static func prepare() {
        KeychainSecretStore(service: "org.opengrokbot.cloud.controller", availableInBackground: true).makeAvailableInBackground()
        KeychainSecretStore(service: "org.opengrokbot.ios.cloud-selection", availableInBackground: true).makeAvailableInBackground()
        schedule()
    }

    // MARK: The check

    /// Called by iOS in the background. Always plans the next check first.
    @MainActor static func handle() async {
        schedule()
        guard enabled else { return }
        await run()
    }

    @MainActor static func run() async {
        guard let response = await fetchOverview(), response.status == 200,
              let patch = try? CloudStatePatch.decode(response.body), let snapshot = try? patch.applying(to: nil) else { return }
        let entries = snapshot.workspace.entries
        let previous = watermark
        defer { watermark = nextWatermark(entries: entries, current: previous) }
        // The first check only learns where things stand; nothing old is announced.
        guard let previous else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        for entry in fresh(in: entries, since: previous).suffix(10) {
            guard let bot = snapshot.workspace.bots.first(where: { $0.id == entry.botID }) else { continue }
            let content = UNMutableNotificationContent()
            let who = bot.memberIDs != nil ? (entry.senderName ?? bot.name) : bot.name
            content.title = entry.state == .failed ? "\(who) couldn\u{2019}t finish" : (entry.headsUp != nil ? who : "\(who) replied")
            content.body = String(entry.text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).prefix(160))
            content.sound = .default
            content.threadIdentifier = bot.id.uuidString
            content.userInfo = ["botID": bot.id.uuidString]
            try? await center.add(UNNotificationRequest(identifier: entry.id.uuidString, content: content, trigger: nil))
        }
    }

    /// The newest message per chat from whatever this phone is connected to: a server by address, or a computer through the account.
    @MainActor private static func fetchOverview() async -> CloudResponse? {
        let target = "/v1/state?overview=true"
        let selection = KeychainSecretStore(service: "org.opengrokbot.ios.cloud-selection", availableInBackground: true)
        if let data = try? selection.read(account: "direct-server"), let server = try? JSONDecoder().decode(DirectServerClient.self, from: data) {
            return try? await server.fetch(target: target)
        }
        let account = CloudAccount(kind: "controller")
        guard account.signedIn, let owner = account.session?.user.id,
              let data = try? selection.read(account: "last-host-" + owner.uuidString),
              let device = try? JSONDecoder().decode(CloudDevice.self, from: data) else { return nil }
        return try? await CloudRelayClient(account: account).fetch(device, target: target)
    }
}
#endif
