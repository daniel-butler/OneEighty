//
//  OneEightyApp.swift
//  OneEighty
//
//  Created by Daniel Butler on 12/21/25.
//

import SwiftUI
import ActivityKit
import os

private let logger = Logger(subsystem: "app.rekuro.OneEighty", category: "AppLifecycle")

class AppDelegate: NSObject, UIApplicationDelegate {
    func applicationWillTerminate(_ application: UIApplication) {
        logger.info("applicationWillTerminate — cleaning up")
        // Block (bounded) so the end requests actually dispatch before the
        // process dies, instead of firing a Task that may never run. This is
        // called only when the app is still executing at termination (a SIGKILL
        // of a suspended app skips it entirely); the safety net for that case is
        // apply()'s invariant, which ends orphaned activities on the next launch
        // or store update.
        LiveActivityManager.shared.endAllActivitiesBlocking(timeout: 3)
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
            if let defaults = UserDefaults(suiteName: "group.app.rekuro.OneEighty") {
                defaults.removeObject(forKey: "bpm")
                defaults.removeObject(forKey: "isPlaying")
                defaults.removeObject(forKey: "volume")
            }
            // Delete the versioned store's backing file so it seeds from defaults.
            if let container = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: "group.app.rekuro.OneEighty") {
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
