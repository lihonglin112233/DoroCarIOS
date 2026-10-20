import SwiftUI

@main
struct DoroCarApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var repo = GwmRepository.shared
    @StateObject private var alerts = StatusAlertCenter.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(repo)
                .environmentObject(alerts)
                .onChange(of: scenePhase) { phase in
                    switch phase {
                    case .active:
                        alerts.clearUnread()
                        Task {
                            await repo.start()
                            await repo.refreshNow()
                        }
                    case .background:
                        BackgroundRefresh.schedule(after: repo.pollIntervalSeconds)
                    case .inactive:
                        break
                    @unknown default:
                        break
                    }
                }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        BackgroundRefresh.register()
        StatusAlertCenter.shared.requestAuthorizationIfNeeded()
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        // 预留：如将来接入 APNs 推送车况变化
    }
}
