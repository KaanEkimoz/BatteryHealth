import AppKit
import Combine
import Sparkle

/// Sparkle auto-updates. The feed (SUFeedURL) is the appcast attached to the
/// newest GitHub release; every update is checked against SUPublicEDKey.
@MainActor
final class Updater: NSObject, ObservableObject {
    static let shared = Updater()

    @Published private(set) var canCheck = false
    private var controller: SPUStandardUpdaterController?
    private var bag = Set<AnyCancellable>()

    private override init() {
        super.init()
        // Only inside the real .app (it carries SUFeedURL); not in `swift run`
        // or the --snapshot debug mode.
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        let c = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
        controller = c
        c.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheck = $0 }
            .store(in: &bag)
    }

    var isAvailable: Bool { controller != nil }

    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }

    var automaticallyInstalls: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set {
            objectWillChange.send()
            controller?.updater.automaticallyDownloadsUpdates = newValue
            if newValue { controller?.updater.automaticallyChecksForUpdates = true }
        }
    }
}

extension Updater: SPUStandardUserDriverDelegate {
    // A menu bar app has no Dock icon or main window, so bring the update
    // window forward when Sparkle shows it.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                               forUpdate update: SUAppcastItem,
                                                               state: SPUUserUpdateState) {
        guard handleShowingUpdate else { return }
        Task { @MainActor in NSApp.activate(ignoringOtherApps: true) }
    }
}
