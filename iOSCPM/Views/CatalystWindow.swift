//
//  CatalystWindow.swift
//  iOSCPM
//
//  The UIKit half of remembering the window: the calls that actually read and
//  move a Mac Catalyst window, kept apart from the decisions about what is
//  worth restoring, which are in WindowFrame.swift and are unit-tested.
//
//  Everything here is `#if targetEnvironment(macCatalyst)`. On iOS and iPadOS
//  the window is the screen or is managed by the system, there is nothing to
//  remember, and the whole file compiles to nothing.
//
//  ## What is and is not possible here
//
//  Catalyst does not hand an app an NSWindow. Two things it does hand it:
//
//    * `UIWindowScene.sizeRestrictions`, since Catalyst 13, which is how a
//      minimum size is expressed. This is the part that stops the terminal
//      being crushed to nothing.
//    * `requestGeometryUpdate(.Mac(systemFrame:))`, from iOS 16 / macOS 13,
//      which is the only supported way to place the window. The deployment
//      target is iOS 15, so this is behind an availability check and on an
//      older system the size is simply not restored - the minimum still is.
//
//  A request is a request: the window server may answer with something else,
//  which is why the saved frame is re-read from the scene rather than assumed.
//

import Foundation

#if targetEnvironment(macCatalyst)
import UIKit

enum CatalystWindow {

    /// Apply the minimum size, and the remembered frame if there is a usable
    /// one. Called once per scene, as soon as there is a scene to call it on.
    static func restore() {
        guard let scene = activeWindowScene() else { return }

        // The minimum first and unconditionally: it applies whether or not a
        // frame was ever saved, and it is what keeps a drag from crushing the
        // terminal into a sliver.
        scene.sizeRestrictions?.minimumSize = WindowFrame.minimumSize

        guard let saved = WindowFrame(defaultsValue:
                UserDefaults.standard.object(forKey: WindowFrame.defaultsKey)) else { return }

        let screen = usableScreenFrame(for: scene)
        guard let frame = saved.restorable(in: screen) else { return }

        if #available(iOS 16.0, *) {
            scene.requestGeometryUpdate(.Mac(systemFrame: frame))
        }
        // Below iOS 16 there is no supported way to place the window, so the
        // size is not restored. Saying so here rather than reaching for a
        // private API is the whole of the decision.
    }

    /// Remember where the window is now. Called when the app deactivates, which
    /// is the last moment the frame is still meaningful.
    static func save() {
        guard let scene = activeWindowScene() else { return }
        guard let window = scene.windows.first else { return }

        let frame: CGRect
        if #available(iOS 16.0, *) {
            frame = scene.effectiveGeometry.systemFrame
        } else {
            frame = window.frame
        }

        let candidate = WindowFrame(frame)
        // A frame that is not worth saving is not written, rather than written
        // and refused on the way back: a scene reports a zero size before it
        // has been laid out, and overwriting a good remembered frame with that
        // would lose it.
        guard candidate.isWorthSaving else { return }
        UserDefaults.standard.set(candidate.defaultsValue, forKey: WindowFrame.defaultsKey)
    }

    // MARK: -

    private static func activeWindowScene() -> UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState != .unattached }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    }

    private static func usableScreenFrame(for scene: UIWindowScene) -> CGRect {
        // Catalyst reports the display through the scene's screen. It is the
        // whole display rather than the menu-bar-excluded area, which is close
        // enough for the two things it is used for: refusing a window larger
        // than the display, and pulling one back that has landed off it.
        scene.screen.bounds
    }
}
#endif
