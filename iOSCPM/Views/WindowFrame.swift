//
//  WindowFrame.swift
//  iOSCPM
//
//  Remembering how big the window was, and refusing to restore a size that
//  would strand it.
//
//  Under Mac Catalyst the app is a resizable desktop window, and it opened at
//  the system default every single launch: `todo.txt` had this as a parity gap
//  and noted that it is not N/A the way it is on a phone. This is the half of
//  fixing that which can be checked without a Mac - what is stored, what is
//  refused, and what a stored frame is clamped to - so it lives apart from the
//  UIKit call that actually moves the window (see CatalystWindow.swift), for
//  the same reason TerminalScreen and DiskSize do.
//
//  ## Why a stored frame cannot simply be handed back
//
//  A window frame is remembered on one machine and restored on whatever machine
//  the defaults come back on. Between the two the display can have gone away, a
//  laptop can have been undocked, or the plist can have been edited. The three
//  ways that ends badly are all worth refusing:
//
//    * a frame smaller than the terminal, which opens the app already unusable
//    * a frame larger than the screen, which pins the title bar off the top
//    * a frame entirely outside every display, which opens a window nobody can
//      find, on a Mac, with no way to drag it back
//
//  So a restore is a request, not an instruction: `restorable(in:)` answers
//  with the frame to use, or with nil meaning "open at the system default".
//

import Foundation
import CoreGraphics

struct WindowFrame: Equatable {

    /// The smallest window worth opening.
    ///
    /// An 80-column terminal at the smallest font the app offers, plus the side
    /// toolbar, the key row and the status bar. Below this the terminal is
    /// clipped rather than scaled, so a smaller saved frame is a frame that was
    /// already wrong.
    static let minimumSize = CGSize(width: 640, height: 480)

    /// How much of a restored window must land on a screen for it to count as
    /// reachable. A title bar is about 28 points; 60 x 60 of visible window is
    /// enough to grab and drag.
    static let minimumVisible = CGSize(width: 60, height: 60)

    static let defaultsKey = "catalystWindowFrame"

    var origin: CGPoint
    var size: CGSize

    var rect: CGRect { CGRect(origin: origin, size: size) }

    init(_ rect: CGRect) {
        self.origin = rect.origin
        self.size = rect.size
    }

    // MARK: Persistence
    //
    // Four numbers in an array rather than NSKeyedArchiver or a Codable blob:
    // a defaults value a person can read, and one that cannot fail to decode in
    // an interesting way. Anything that is not four finite numbers is simply
    // not a frame.

    var defaultsValue: [Double] {
        [Double(origin.x), Double(origin.y), Double(size.width), Double(size.height)]
    }

    init?(defaultsValue: Any?) {
        guard let numbers = defaultsValue as? [Double], numbers.count == 4 else { return nil }
        guard numbers.allSatisfy({ $0.isFinite }) else { return nil }
        self.origin = CGPoint(x: numbers[0], y: numbers[1])
        self.size = CGSize(width: numbers[2], height: numbers[3])
    }

    // MARK: Deciding whether to use it

    /// Is this a frame worth saving at all? A zero or negative size is what a
    /// scene reports before it has been laid out, and saving one would restore
    /// an invisible window on the next launch.
    var isWorthSaving: Bool {
        size.width >= WindowFrame.minimumSize.width
            && size.height >= WindowFrame.minimumSize.height
            && origin.x.isFinite && origin.y.isFinite
    }

    /// The frame to actually open at on a display of `screen`, or nil for "use
    /// the system default".
    ///
    /// `screen` is the usable area in the window server's own coordinates, so
    /// the caller passes whatever its platform calls that and this stays a
    /// function of two rectangles.
    func restorable(in screen: CGRect) -> CGRect? {
        guard isWorthSaving else { return nil }
        guard screen.width > 0, screen.height > 0 else { return nil }

        // Never larger than the screen it is opening on: a frame saved on a
        // 6K display and restored on a laptop would otherwise put the title bar
        // out of reach.
        var result = rect
        result.size.width = min(result.size.width, screen.width)
        result.size.height = min(result.size.height, screen.height)

        // ...and never below the minimum, even after that clamp.
        result.size.width = max(result.size.width, min(WindowFrame.minimumSize.width, screen.width))
        result.size.height = max(result.size.height, min(WindowFrame.minimumSize.height, screen.height))

        // If enough of it lands on the screen to grab, leave it where the user
        // put it. Otherwise pull it back on rather than refusing outright: a
        // remembered size is still worth honouring when only the position has
        // stopped making sense.
        let visible = result.intersection(screen)
        if visible.width < WindowFrame.minimumVisible.width
            || visible.height < WindowFrame.minimumVisible.height {
            result.origin.x = min(max(result.origin.x, screen.minX), screen.maxX - result.width)
            result.origin.y = min(max(result.origin.y, screen.minY), screen.maxY - result.height)
        }
        return result
    }
}
