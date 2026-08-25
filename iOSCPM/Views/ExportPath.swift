import Foundation

/// Where a W8 export is allowed to land.
///
/// Split out of `EmulatorViewModel` for the reason `TerminalDialect`,
/// `ControlKey` and `KeyMap` were: it touches no UIKit and no emulator, so it
/// can be tested. This one is worth testing more than any of those, because
/// getting it wrong once already cost the user's whole disk library.
///
/// The history, so nobody simplifies it back: `saveToExportsFolder` took the
/// guest's string whole, called `exportsDir.appendingPathComponent(name)` on
/// it, and then `FileManager.removeItem(at:)` on the result.
/// `appendingPathComponent` does **not** escape `..` — it produces
/// `.../Exports/..` — and `removeItem` on that path succeeds and deletes the
/// parent *recursively*. `Documents` is the parent, and it holds `Disks`,
/// `Imports` and `Exports`. So a CP/M program, or a mistyped command, running
/// `W8 ANYFILE.TXT ..` destroyed every disk image the user had downloaded,
/// while `try?` swallowed the error and the guest was told the export
/// succeeded.
///
/// The core now reduces the string before it ever reaches Swift
/// (`emu_host_file_open_write`, via `emu_host_path_basename`). This is the
/// second line: it assumes nothing about that having happened, because this
/// type is also reachable from the picker-cancelled fallback path, and because
/// a check that only holds while another layer behaves is not a check.
enum ExportPath {

    /// The name to use when the guest's is unusable. Matches the core's own
    /// fallback behaviour rather than inventing a second convention.
    static let fallbackName = "export.txt"

    /// Reduce a guest-supplied string to a single filename component.
    ///
    /// Returns `fallbackName` for anything that cannot be a file *in* a
    /// directory: empty, `.`, `..`, or a string that is only separators.
    ///
    /// Split rather than `NSString.lastPathComponent`, for two reasons. It only
    /// knows about `/`, and this string comes off a guest command line that may
    /// have been typed on any host - the core treats `\` as a separator too, so
    /// this has to agree. And `lastPathComponent` of `"///"` is `"/"`, not `""`:
    /// a separator-only string does not reduce to nothing the way an empty one
    /// does, so a test for empty misses it and a lone `"/"` reaches the join.
    /// `split` drops empty components, which handles both.
    static func leafName(from guestName: String) -> String {
        let parts = guestName.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        guard let leaf = parts.last.map(String.init),
              !leaf.isEmpty, leaf != ".", leaf != ".." else {
            return fallbackName
        }
        return leaf
    }

    /// Where `guestName` may be written inside `exportsDir`, or `nil` if it
    /// resolves anywhere else.
    ///
    /// Callers must treat `nil` as "refuse and tell the user" — never as "write
    /// it somewhere else instead".
    static func destination(for guestName: String, in exportsDir: URL) -> URL? {
        let url = exportsDir.appendingPathComponent(leafName(from: guestName))

        // Standardize both sides before comparing: that is what resolves any
        // "." or ".." still present in either path, and comparing unresolved
        // strings is what makes a containment check look right and not be.
        let dir = exportsDir.standardizedFileURL.path
        let dest = url.standardizedFileURL.path

        // The trailing separator matters: without it "/…/ExportsEvil/x" passes
        // a prefix test against "/…/Exports".
        let prefix = dir.hasSuffix("/") ? dir : dir + "/"
        guard dest.hasPrefix(prefix) else { return nil }

        // And it has to be a file directly in that folder, not nested deeper -
        // nothing creates intermediate directories, so a nested path would be a
        // failed write. Unreachable given leafName above, which cannot return
        // anything containing a separator; kept because this method's contract
        // is "the result is safe to write", and that should not depend on
        // reading the other method.
        guard url.deletingLastPathComponent().standardizedFileURL.path == dir else {
            return nil
        }

        return url
    }
}
