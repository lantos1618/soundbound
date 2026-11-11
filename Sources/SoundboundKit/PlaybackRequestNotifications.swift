#if os(iOS)
import SwiftUI
import UserNotifications
import UIKit
import Combine

/// Notifications for requests that reach this process. Waking a suspended app
/// for a new network request still requires an APNs signaling service.
final class PlaybackRequestNotifications: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = PlaybackRequestNotifications()
    @Published private(set) var authorized = false
    @Published private(set) var status = "Allow notifications for playback requests."
    private weak var mesh: AudioMesh?
    private var observation: AnyCancellable?
    private var grace: UIBackgroundTaskIdentifier = .invalid
    private var notificationID: String?
    private var requestedPermission = false

    private override init() {
        super.init()
        let allow = UNNotificationAction(identifier: "allow-playback", title: "Allow audio", options: [.foreground, .authenticationRequired])
        let decline = UNNotificationAction(identifier: "decline-playback", title: "Decline", options: [.destructive])
        let category = UNNotificationCategory(identifier: "soundbound-playback", actions: [allow, decline], intentIdentifiers: [])
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([category])
    }
    func attach(to mesh: AudioMesh) {
        guard self.mesh !== mesh else { return }
        self.mesh = mesh
        observation = mesh.$incoming.sink { [weak self] request in self?.changed(request) }
        requestPermission()
    }
    func requestPermission() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self else { return }
                if settings.authorizationStatus == .notDetermined && !self.requestedPermission {
                    self.requestedPermission = true
                    center.requestAuthorization(options: [.alert, .sound, .badge]) { allowed, _ in
                        DispatchQueue.main.async { self.update(allowed) }
                    }
                } else { self.update(settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional) }
            }
        }
    }
    private func update(_ allowed: Bool) {
        authorized = allowed
        status = allowed ? "Playback request notifications are enabled." : "Allow notifications in iPhone Settings to see playback requests."
    }
    private func changed(_ request: IncomingAudioRequest?) {
        finishGrace()
        if let notificationID {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [notificationID])
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [notificationID])
            self.notificationID = nil
        }
        guard let request, UIApplication.shared.applicationState != .active else { return }
        grace = UIApplication.shared.beginBackgroundTask(withName: "Respond to playback request") { [weak self] in
            guard let self else { return }
            self.mesh?.decide(allow: false); self.finishGrace()
        }
        let content = UNMutableNotificationContent()
        content.title = "Allow audio from " + request.name + "?"
        content.body = "Tap to review playback on " + (request.outputName ?? "this device") + "."
        content.categoryIdentifier = "soundbound-playback"
        content.userInfo = ["requestID": request.id]
        content.sound = .default
        let id = "soundbound-audio-" + request.id
        notificationID = id
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
    private func finishGrace() {
        if grace != .invalid { UIApplication.shared.endBackgroundTask(grace); grace = .invalid }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completion: @escaping (UNNotificationPresentationOptions) -> Void) {
        completion(UIApplication.shared.applicationState == .active ? [] : [.banner, .sound])
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completion: @escaping () -> Void) {
        DispatchQueue.main.async {
            defer { completion() }
            guard let id = response.notification.request.content.userInfo["requestID"] as? String,
                  self.mesh?.incoming?.id == id else { self.status = "That playback request has expired."; return }
            if response.actionIdentifier == "allow-playback" { self.mesh?.decide(allow: true) }
            else if response.actionIdentifier == "decline-playback" { self.mesh?.decide(allow: false) }
            // Default tap opens Soundbound's in-app approval prompt.
        }
    }
}

struct PlaybackNotificationSettings: View {
    @ObservedObject private var notifications = PlaybackRequestNotifications.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(notifications.status).font(.subheadline)
            if !notifications.authorized {
                Button("Notification settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
            Text("Keep Soundbound open to receive new requests. Active audio can continue in the background; waking a suspended app needs push delivery, which is not connected yet.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
#endif
