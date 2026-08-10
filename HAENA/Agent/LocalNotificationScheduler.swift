@preconcurrency import UserNotifications
import Foundation

enum LocalNotificationAuthorization: Equatable, Sendable {
    case notDetermined
    case denied
    case authorized
}

struct LocalNotificationRequest: Equatable, Sendable {
    static let reminderIDUserInfoKey = "haenaReminderID"

    let identifier: String
    let title: String
    let body: String
    let fireAt: Date
    /// Privacy-safe correlation only. Notification callbacks must never infer a reminder run from
    /// title/body, and an ActionItem identifier alone cannot distinguish a later re-schedule.
    let reminderID: UUID?

    init(
        identifier: String,
        title: String,
        body: String,
        fireAt: Date,
        reminderID: UUID? = nil
    ) {
        self.identifier = identifier
        self.title = title
        self.body = body
        self.fireAt = fireAt
        self.reminderID = reminderID
    }
}

protocol LocalNotificationScheduler: Sendable {
    func authorizationStatus() async -> LocalNotificationAuthorization
    func requestAuthorization() async throws -> Bool
    func schedule(_ request: LocalNotificationRequest) async throws
    func remove(identifier: String) async
    func pendingIdentifiers() async -> Set<String>
}

enum LocalNotificationLifecycleCallback: Equatable, Sendable {
    case presentedForeground(identifier: String, reminderID: UUID?)
    case openedFromNotification(identifier: String, reminderID: UUID?)

    var identifier: String {
        switch self {
        case .presentedForeground(let identifier, _), .openedFromNotification(let identifier, _):
            return identifier
        }
    }

    var reminderID: UUID? {
        switch self {
        case .presentedForeground(_, let reminderID), .openedFromNotification(_, let reminderID):
            return reminderID
        }
    }
}

/// Chooses an explicit presentation for notifications delivered while HAE.NA is active.
///
/// `UNUserNotificationCenter` suppresses its normal UI for foreground deliveries unless its
/// delegate opts into presentation. The center's `delegate` property is weak, so the scheduler
/// below owns this instance for exactly as long as the app owns the scheduler.
final class ForegroundNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let presentationOptions: UNNotificationPresentationOptions = [.banner, .list, .sound]

    private let onLifecycleCallback: @Sendable (LocalNotificationLifecycleCallback) -> Void

    init(
        onLifecycleCallback: @escaping @Sendable (LocalNotificationLifecycleCallback) -> Void = { _ in }
    ) {
        self.onLifecycleCallback = onLifecycleCallback
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        handleWillPresent(
            identifier: notification.request.identifier,
            reminderID: Self.reminderID(from: notification.request.content),
            completionHandler: completionHandler
        )
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        handleResponse(
            identifier: response.notification.request.identifier,
            reminderID: Self.reminderID(from: response.notification.request.content),
            completionHandler: completionHandler
        )
    }

    /// Completes the OS presentation path before starting best-effort observation. A slow or
    /// corrupt ledger can therefore never suppress the banner or sound.
    func handleWillPresent(
        identifier: String,
        reminderID: UUID? = nil,
        completionHandler: (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler(Self.presentationOptions)
        onLifecycleCallback(.presentedForeground(identifier: identifier, reminderID: reminderID))
    }

    /// The response completion handler is likewise called exactly once on every identifier path,
    /// including malformed and unrelated notifications; the bridge decides what is recordable.
    func handleResponse(
        identifier: String,
        reminderID: UUID? = nil,
        completionHandler: () -> Void
    ) {
        completionHandler()
        onLifecycleCallback(.openedFromNotification(identifier: identifier, reminderID: reminderID))
    }

    private static func reminderID(from content: UNNotificationContent) -> UUID? {
        guard let rawValue = content.userInfo[LocalNotificationRequest.reminderIDUserInfoKey] as? String else {
            return nil
        }
        return UUID(uuidString: rawValue)
    }
}

final class UserNotificationScheduler: LocalNotificationScheduler, @unchecked Sendable {
    private let center: UNUserNotificationCenter
    private let calendar: Calendar
    /// Strong ownership is intentional: `UNUserNotificationCenter.delegate` is weak.
    let foregroundDelegate: ForegroundNotificationDelegate

    init(
        center: UNUserNotificationCenter = .current(),
        calendar: Calendar = .current,
        foregroundDelegate: ForegroundNotificationDelegate = ForegroundNotificationDelegate()
    ) {
        self.center = center
        self.calendar = calendar
        self.foregroundDelegate = foregroundDelegate
        // `HAENAApp` creates the scheduler in its initializer, before the app finishes launching,
        // so foreground deliveries cannot race delegate installation.
        center.delegate = foregroundDelegate
    }

    func authorizationStatus() async -> LocalNotificationAuthorization {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .authorized, .provisional, .ephemeral:
            return .authorized
        @unknown default:
            return .denied
        }
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }

    func schedule(_ request: LocalNotificationRequest) async throws {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.sound = .default
        if let reminderID = request.reminderID {
            content.userInfo[LocalNotificationRequest.reminderIDUserInfoKey] = reminderID.uuidString.lowercased()
        }

        let components = calendar.dateComponents(
            [.calendar, .timeZone, .year, .month, .day, .hour, .minute, .second],
            from: request.fireAt
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        try await center.add(
            UNNotificationRequest(identifier: request.identifier, content: content, trigger: trigger)
        )
    }

    func remove(identifier: String) async {
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    func pendingIdentifiers() async -> Set<String> {
        Set(await center.pendingNotificationRequests().map(\.identifier))
    }
}

actor InMemoryLocalNotificationScheduler: LocalNotificationScheduler {
    private var authorization: LocalNotificationAuthorization
    private var requests: [String: LocalNotificationRequest]
    private let requestResult: Bool
    private let scheduleShouldFail: Bool

    init(
        authorization: LocalNotificationAuthorization = .authorized,
        requests: [LocalNotificationRequest] = [],
        requestResult: Bool = true,
        scheduleShouldFail: Bool = false
    ) {
        self.authorization = authorization
        self.requests = Dictionary(uniqueKeysWithValues: requests.map { ($0.identifier, $0) })
        self.requestResult = requestResult
        self.scheduleShouldFail = scheduleShouldFail
    }

    func authorizationStatus() -> LocalNotificationAuthorization { authorization }

    func requestAuthorization() -> Bool {
        authorization = requestResult ? .authorized : .denied
        return requestResult
    }

    func schedule(_ request: LocalNotificationRequest) throws {
        if scheduleShouldFail {
            throw CocoaError(.fileWriteUnknown)
        }
        requests[request.identifier] = request
    }

    func remove(identifier: String) {
        requests.removeValue(forKey: identifier)
    }

    func pendingIdentifiers() -> Set<String> {
        Set(requests.keys)
    }

    func scheduledRequest(identifier: String) -> LocalNotificationRequest? {
        requests[identifier]
    }
}
