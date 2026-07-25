import FirebaseAuth
import FirebaseFirestore
import FirebaseMessaging
import UIKit
import UserNotifications

extension Notification.Name {
    static let runAlongFCMTokenDidChange = Notification.Name("runAlongFCMTokenDidChange")
}

@MainActor
final class PushNotificationManager: NSObject {
    static let shared = PushNotificationManager()

    private var subscribedRaceIds: Set<String> = []
    private var tokenObserver: NSObjectProtocol?

    func configure() {
        UNUserNotificationCenter.current().delegate = self
        Messaging.messaging().delegate = self
        tokenObserver = NotificationCenter.default.addObserver(
            forName: .runAlongFCMTokenDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let token = notification.object as? String else { return }
            Task { @MainActor [weak self] in
                await self?.save(token: token)
            }
        }
    }

    func subscribe(to raceId: String) {
        subscribedRaceIds.insert(raceId)
        Task {
            let granted = try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .badge, .sound])
            guard granted == true else { return }
            UIApplication.shared.registerForRemoteNotifications()
            if let token = Messaging.messaging().fcmToken {
                await save(token: token)
            }
        }
    }

    private func save(token: String) async {
        guard !token.isEmpty,
              token.count <= 4_096,
              let userId = Auth.auth().currentUser?.uid else { return }
        let database = Firestore.firestore()
        for raceId in subscribedRaceIds {
            do {
                try await database.collection("races")
                    .document(raceId)
                    .collection("members")
                    .document(userId)
                    .setData([
                        "pushToken": token,
                        "notificationsEnabled": true
                    ], merge: true)
            } catch {
                // A later token refresh or race re-entry retries this write.
            }
        }
    }
}

extension PushNotificationManager: MessagingDelegate {
    nonisolated func messaging(
        _ messaging: Messaging,
        didReceiveRegistrationToken fcmToken: String?
    ) {
        guard let fcmToken else { return }
        NotificationCenter.default.post(
            name: .runAlongFCMTokenDidChange,
            object: fcmToken
        )
    }
}

extension PushNotificationManager: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
