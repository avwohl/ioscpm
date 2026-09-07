/*
 * ViewModelHostStubs.swift - stand-ins so EmulatorViewModel can be type-checked
 *
 * EmulatorViewModel.swift imports SwiftUI, Combine, AVFoundation, CryptoKit and
 * Network - all of which exist on the macosx SDK - so it can be type-checked on
 * a machine that has only Command Line Tools. Two symbols stop it: one type it
 * shares with ContentView.swift, and UIApplication. Both are declared here.
 *
 * Why this is worth a stub rather than being left unchecked: the bug that made
 * this file necessary was `loadROM(fromData:)` in build 65's ROM path, on the
 * one line that hands a catalog-fetched ROM to the core. Objective-C's
 * `loadROMFromData:` imports into Swift as `loadROM(from:)` - the importer drops
 * "Data" from the label because it is the parameter's type - so the app target
 * did not compile at all. Nothing in this repo noticed for two days, because
 * run_tests.sh compiled every OTHER file and the only thing that compiles this
 * one is Xcode, which is not installed on the machine the migration was written
 * on. Type-checking EmulatorViewModel here closes that hole for every bridge
 * call it makes, not just the one that was wrong.
 *
 * These are deliberately minimal: they exist to satisfy the type checker, and
 * nothing here runs. A stub that drifts from the real declaration will start
 * failing this suite, which is the right outcome - it means the real one moved.
 */

import Foundation

/// The real one is a SwiftUI `FileDocument` in ContentView.swift, which imports
/// UIKit and so cannot be compiled here. The view model only ever constructs one
/// and reads `.data` back.
struct DiskImageDocument {
    var data: Data
    init(data: Data) { self.data = data }
}

/// UIKit does not exist on the macosx SDK. The view model uses exactly two
/// members, both on the "reveal this file in the Files app" path.
enum UIApplication {
    struct Stub {
        func canOpenURL(_ url: URL) -> Bool { false }
        func open(_ url: URL) {}
    }
    static let shared = Stub()
}
