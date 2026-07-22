import SwiftUI
import UserNotifications

@main
struct ChargeApp: App {
    // 델리게이트가 없으면 iOS는 포그라운드에서 알림을 표시하지 않는다 —
    // 앱을 보는 중에 리셋되면 알림이 소리 없이 사라지는 것 방지
    @UIApplicationDelegateAdaptor(NotificationDelegate.self) private var notificationDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

final class NotificationDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
