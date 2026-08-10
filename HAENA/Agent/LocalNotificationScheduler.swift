@preconcurrency import UserNotifications
import Foundation

enum LocalNotificationAuthorization: Equatable, Sendable {
    case notDetermined
    case denied
    case authorized
}

struct LocalNotificationRequest: Equatable, Sendable {
    let identifier: String
    let title: String
    let body: String
    let fireAt: Date
}

protocol LocalNotificationScheduler: Sendable {
    func authorizationStatus() async -> LocalNotificationAuthorization
    func requestAuthorization() async throws -> Bool
    func schedule(_ request: LocalNotificationRequest) async throws
    func remove(identifier: String) async
    func pendingIdentifiers() async -> Set<String>
}

/// Chooses an explicit presentation for notifications delivered while HAE.NA is active.
///
/// `UNUserNotificationCenter` suppresses its normal UI for foreground deliveries unless its
/// delegate opts into presentation. The center's `delegate` property is weak, so the scheduler
/// below owns this instance for exactly as long as the app owns the scheduler.
final class ForegroundNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let presentationOptions: UNNotificationPresentationOptions = [.banner, .list, .sound]

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        Self.presentationOptions
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
