//
//  OneEightyApp.swift
//  OneEighty
//
//  Created by Daniel Butler on 12/21/25.
//

import SwiftUI
import ActivityKit
import os

private let logger = Logger(subsystem: "com.danielbutler.OneEighty", category: "AppLifecycle")

class AppDelegate: NSObject, UIApplicationDelegate {
    func applicationWillTerminate(_ application: UIApplication) {
        logger.info("applicationWillTerminate — cleaning up")
        // Best-effort only: iOS does not guarantee this async work completes
        // before the process dies (and a SIGKILL skips this method entirely).
        // The real safety net is LiveActivityManager.startActivity() ending
        // any orphaned activities it finds on the next launch.
        for activity in Activity<OneEightyActivityAttributes>.activities {
            Task.detached {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
        AudioSessionManager.shared.deactivate()
    }
}

@main
struct OneEightyApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var engine: OneEightyEngine
    @State private var phoneSession: PhoneSessionManager?

    init() {
        // Reset MUST run before the engine is constructed, because
        // OneEightyEngine() touches AppGroupPlaybackStore.shared, which seeds its
        // in-memory projection from disk (state.json) on first access.
        if ProcessInfo.processInfo.arguments.contains("--reset-state") {
            if let defaults = UserDefaults(suiteName: "group.com.danielbutler.OneEighty") {
                defaults.removeObject(forKey: "bpm")
                defaults.removeObject(forKey: "isPlaying")
                defaults.removeObject(forKey: "volume")
            }
            // Delete the versioned store's backing file so it seeds from defaults.
            if let container = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: "group.com.danielbutler.OneEighty") {
                try? FileManager.default.removeItem(at: container.appendingPathComponent("state.json"))
            }
        }
        _ = AudioSessionManager.shared
        _engine = State(initialValue: OneEightyEngine())
    }

    var body: some Scene {
        WindowGroup {
            ContentView(engine: engine)
                .onAppear {
                    if phoneSession == nil {
                        let session = PhoneSessionManager(engine: engine)
                        session.activate()
                        phoneSession = session
                    }
                }
        }
    }
}
