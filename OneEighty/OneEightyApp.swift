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
        let activities = Activity<OneEightyActivityAttributes>.activities
        if !activities.isEmpty {
            let semaphore = DispatchSemaphore(value: 0)
            // Must use .detached — a regular Task inherits the main actor
            // context, deadlocking with the semaphore blocking the main thread.
            Task.detached {
                for activity in activities {
                    await activity.end(nil, dismissalPolicy: .immediate)
                }
                semaphore.signal()
            }
            semaphore.wait(timeout: .now() + 2)
        }
        AudioSessionManager.shared.deactivate()
    }
}

@main
struct OneEightyApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var engine = OneEightyEngine()
    @State private var phoneSession: PhoneSessionManager?

    init() {
        _ = AudioSessionManager.shared
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
