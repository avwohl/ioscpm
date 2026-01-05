/*
 * iOSCPMApp.swift - Main app entry point
 */

import SwiftUI

// Notification for showing help from menu bar
extension Notification.Name {
    static let showHelp = Notification.Name("showHelp")
}

@main
struct iOSCPMApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            CommandGroup(replacing: .help) {
                Button("Z80CPM Help") {
                    NotificationCenter.default.post(name: .showHelp, object: nil)
                }
                .keyboardShortcut("?", modifiers: .command)
            }
        }
    }
}
