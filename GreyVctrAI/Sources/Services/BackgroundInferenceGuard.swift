import Foundation
import os

#if canImport(UIKit)
import UIKit
#endif

/// Monitors app lifecycle transitions and manages GPU inference across
/// foreground/background transitions.
///
/// iOS revokes Metal GPU execution permission when an app is backgrounded.
/// The LiteRT-LM C engine's decode loop gets stuck in an infinite retry loop
/// when this happens. This guard:
///
/// - On `willResignActive`: cancels any active inference so the GPU decode loop
///   doesn't keep running after Metal execution permission is revoked.
/// - On `willTerminate`: does not synchronously tear down LiteRT-LM. The native
///   engine destructor can block in ThreadPool::WaitUntilDone(), causing
///   0x8BADF00D process-exit watchdog kills. iOS will reclaim process memory.
///
/// The engine is NOT torn down on background entry — only the conversation is
/// released. This prevents creating duplicate engine instances when the app
/// returns to foreground quickly (e.g., notification banners, control center).
final class BackgroundInferenceGuard {

    private let sessionCoordinator: SessionCoordinator
    private var resignActiveObserver: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?

    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "GreyVctr AI",
        category: "BackgroundGuard"
    )

    /// Create a guard that watches for background transitions.
    /// - Parameters:
    ///   - sessionCoordinator: The session coordinator to cancel/release on background.
    init(sessionCoordinator: SessionCoordinator) {
        self.sessionCoordinator = sessionCoordinator

        #if canImport(UIKit) && !os(watchOS)
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: nil  // Deliver on posting thread for minimal latency
        ) { [weak self] _ in
            self?.handleWillResignActive()
        }

        terminateObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.handleWillTerminate()
        }
        #endif
    }

    deinit {
        if let resignActiveObserver {
            NotificationCenter.default.removeObserver(resignActiveObserver)
        }
        if let terminateObserver {
            NotificationCenter.default.removeObserver(terminateObserver)
        }
    }

    // MARK: - Private

    private func handleWillResignActive() {
        Self.log.info("App resigning active — cancelling active inference if needed")

        Task.detached(priority: .userInitiated) { [sessionCoordinator] in
            // Only cancel active inference so the GPU decode loop doesn't get
            // stuck when Metal permissions are revoked. Do NOT release the
            // conversation or force state changes — let the ViewModel's catch
            // block handle the cancellation gracefully on its own timeline.
            // Forcing state changes here races with SwiftUI's view graph
            // suspension and causes null-pointer crashes in view updates.
            if await sessionCoordinator.hasActiveInference() {
                Self.log.warning("Active inference detected — cancelling")
                try? await sessionCoordinator.cancelIfActive()
            }
        }
    }

    private func handleWillTerminate() {
        Self.log.warning("App terminating — retaining LiteRT session objects to avoid blocking native teardown")
        ProcessExitRetainer.retain(sessionCoordinator)
    }
}

/// Intentionally leaks objects during process exit.
///
/// LiteRT-LM engine/conversation destructors can block while joining native
/// worker threads. During normal app termination that can exceed FrontBoard's
/// 5-second process-exit watchdog. Retaining the coordinator lets process
/// teardown reclaim memory without running the blocking native deinit path.
private enum ProcessExitRetainer {
    private static let lock = NSLock()
    private static var retainedObjects: [UnsafeMutableRawPointer] = []

    static func retain(_ object: AnyObject) {
        let pointer = Unmanaged.passRetained(object).toOpaque()
        lock.lock()
        retainedObjects.append(pointer)
        lock.unlock()
    }
}
