/*
 * iOSCPMApp.swift - Main app entry point
 */

import SwiftUI

// Notification for showing help from menu bar
extension Notification.Name {
    static let showHelp = Notification.Name("showHelp")
    /// A menu item was chosen. The `object` is an `EmulatorMenuCommand.rawValue`.
    static let emulatorCommand = Notification.Name("emulatorCommand")
}

/// The commands the Emulator menu offers.
///
/// The menu is Mac Catalyst's, and until now this app replaced only
/// CommandGroup(.help): every action was in the toolbar and had no keyboard
/// equivalent, which `todo.txt` listed as a parity gap alongside the window
/// state. Each case here mirrors a control that already exists on screen -
/// nothing on this menu is an action the toolbar or Settings cannot do - so the
/// menu adds reach, not behaviour.
///
/// The App struct does not own the view model (ContentView holds it as a
/// @StateObject), so a command travels by notification, exactly as the Help
/// item already did. That hop is the established pattern in this file and is
/// kept rather than restructuring ownership for a menu.
enum EmulatorMenuCommand: String {
    case startStop
    case reset
    case clearScreen
    case scrollToLive
    case saveAllDisks
    case openImports
    case openExports
    case settings

    func post() {
        NotificationCenter.default.post(name: .emulatorCommand, object: rawValue)
    }
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

            CommandMenu("Emulator") {
                Button("Start / Stop") { EmulatorMenuCommand.startStop.post() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Reset...") { EmulatorMenuCommand.reset.post() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])

                Divider()

                Button("Clear Screen") { EmulatorMenuCommand.clearScreen.post() }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Jump to Live") { EmulatorMenuCommand.scrollToLive.post() }
                    .keyboardShortcut("l", modifiers: .command)

                Divider()

                Button("Save All Disks") { EmulatorMenuCommand.saveAllDisks.post() }
                    .keyboardShortcut("s", modifiers: .command)
                Button("Open Imports Folder") { EmulatorMenuCommand.openImports.post() }
                Button("Open Exports Folder") { EmulatorMenuCommand.openExports.post() }

                Divider()

                Button("Settings...") { EmulatorMenuCommand.settings.post() }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
