// UNVERIFIED: written on Linux, never compiled or run — requires macOS + Xcode
//
// Automatic subscription refresh without a polling loop. At launch the app refreshes subscriptions whose
// interval has passed. On iOS, when the app goes to the background, it asks the system for one app-refresh
// task at the earliest due time (`BGAppRefreshTaskRequest`); the system decides when (or whether) it runs.
// The task refreshes what is due and asks for the next one. The identifier is listed in Info.plist
// (`BGTaskSchedulerPermittedIdentifiers`). Other platforms refresh at launch and on request only.

import Foundation
#if os(iOS)
import BackgroundTasks
#endif

@MainActor
enum SubscriptionBackgroundRefresh {
    /// `<bundle id>.subscriptions`, as in Info.plist (`$(PRODUCT_BUNDLE_IDENTIFIER).subscriptions`).
    nonisolated static var identifier: String {
        (Bundle.main.bundleIdentifier ?? "NetworkPlatform") + ".subscriptions"
    }

    /// The model the background task works on; set by the app at launch.
    static weak var library: ProfileLibraryModel?

    /// Runs inside the system's background task.
    static func perform() async {
        guard let library = library else { return }
        await library.refreshStaleSubscriptions()
        schedule(library: library)
    }

    /// Asks the system for the next refresh, or cancels the request when nothing is due.
    static func schedule(library: ProfileLibraryModel) {
        #if os(iOS)
        let scheduler = BGTaskScheduler.shared
        scheduler.cancel(taskRequestWithIdentifier: identifier)
        guard let next = library.nextSubscriptionRefresh else { return }
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = max(next, Date().addingTimeInterval(15 * 60))
        // Refused when background refresh is off for the app; the next launch refreshes instead.
        try? scheduler.submit(request)
        #endif
    }
}
