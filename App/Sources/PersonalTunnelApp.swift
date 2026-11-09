import BackgroundTasks
import SwiftUI
import TunnelKit

@main
struct PersonalTunnelApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = AppModel.shared

    nonisolated static let refreshTaskIdentifier = "com.personaltunnelapp.refresh"

    init() {
        FontLibrary.applyAppearance(AppSettings.shared)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.launch() }
                .onOpenURL { url in model.open(url) }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                model.sceneBecameActive()
            case .background:
                model.sceneEnteredBackground()
                PersonalTunnelApp.scheduleRefresh()
            default:
                break
            }
        }
        .backgroundTask(.appRefresh(PersonalTunnelApp.refreshTaskIdentifier)) {
            await AppModel.shared.refreshDue()
            await MainActor.run { AppModel.shared.saveNow() }
            PersonalTunnelApp.scheduleRefresh()
        }
    }

    nonisolated static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 3 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }
}
