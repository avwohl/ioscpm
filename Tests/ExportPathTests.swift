// ExportPathTests.swift - a W8 export cannot land outside the Exports folder
//
// This is the regression test for the worst bug this port has had. The old
// saveToExportsFolder took the guest's string whole, called
// exportsDir.appendingPathComponent(name), and then removeItem on the result.
// appendingPathComponent does NOT escape "..", and removeItem on a URL ending
// in ".." succeeds and deletes the parent recursively - Documents, which holds
// Disks, Imports and Exports. "W8 ANYFILE.TXT .." destroyed the user's entire
// disk library, the try? swallowed the error, and the guest was told the export
// succeeded.
//
// The first group below is the vulnerability itself, stated as the inputs that
// must never resolve. The last group proves the FileManager behaviour that made
// it destructive, so the reason these checks exist stays visible even to
// someone who has never seen the bug.
//
// Build and run:  Tests/run_tests.sh

import Foundation

var failures = 0
var checks = 0

func check(_ ok: Bool, _ what: String) {
    checks += 1
    print("\(ok ? "PASS" : "FAIL"): \(what)")
    if !ok { failures += 1 }
}

let exports = URL(fileURLWithPath: "/tmp/iocpmtest/Documents/Exports", isDirectory: true)

func runAllTests() {

    print("A W8 export cannot land outside the Exports folder")
    print(String(repeating: "-", count: 60))

    // --- the traversals -------------------------------------------------------
    // Every one of these is a string the guest can put on a W8 command line.
    for hostile in ["..", "../", "../..", "../evil.txt", "../../Documents",
                    "..\\..\\evil.txt", "/etc/passwd", "/tmp/elsewhere.txt",
                    "subdir/../../evil.txt", "Exports/../../evil.txt"] {
        let dest = ExportPath.destination(for: hostile, in: exports)
        let inside = dest.map {
            $0.standardizedFileURL.path.hasPrefix(exports.standardizedFileURL.path + "/")
                && $0.deletingLastPathComponent().standardizedFileURL.path
                    == exports.standardizedFileURL.path
        } ?? true   // refused counts as safe
        check(inside, "\"\(hostile)\" cannot escape Exports")
    }

    // A nested path is FLATTENED to its leaf, not refused. That is deliberate
    // and matches what the core already did to the string (emu_host_path_basename)
    // and what the browser backend does to a download name: a path cannot mean
    // here what it means on a desktop, so the last component is kept and the
    // rest dropped. Refusing would make this port disagree with the other two.
    check(ExportPath.destination(for: "sub/dir/out.txt", in: exports)?
            .standardizedFileURL.path == "/tmp/iocpmtest/Documents/Exports/out.txt",
          "a nested path is flattened to its leaf, as the core and the browser do")

    // --- ordinary names still work -------------------------------------------
    check(ExportPath.destination(for: "out.txt", in: exports)?.lastPathComponent == "out.txt",
          "an ordinary name resolves")
    check(ExportPath.destination(for: "MYFILE.COM", in: exports)?.lastPathComponent == "MYFILE.COM",
          "a CCP-uppercased name resolves unchanged - case is the core's business, not this")
    check(ExportPath.destination(for: "a.b.c", in: exports)?.lastPathComponent == "a.b.c",
          "a multi-dot name is a name, not a traversal")
    check(ExportPath.destination(for: "...", in: exports)?.lastPathComponent == "...",
          "three dots is a legal filename and is kept")
    check(ExportPath.destination(for: ".hidden", in: exports)?.lastPathComponent == ".hidden",
          "a leading-dot name is kept")

    // --- the fallback ---------------------------------------------------------
    check(ExportPath.leafName(from: "") == ExportPath.fallbackName, "an empty name falls back")
    check(ExportPath.leafName(from: "..") == ExportPath.fallbackName, "\"..\" falls back")
    check(ExportPath.leafName(from: ".") == ExportPath.fallbackName, "\".\" falls back")
    check(ExportPath.leafName(from: "///") == ExportPath.fallbackName, "separators only fall back")
    check(ExportPath.leafName(from: "/a/b/c.txt") == "c.txt", "a POSIX path reduces to its leaf")

    // --- a sibling folder must not pass a prefix test -------------------------
    // "/…/ExportsEvil/x" starts with "/…/Exports". Without the trailing separator
    // in the comparison this class of check looks right and is not.
    let sibling = URL(fileURLWithPath: "/tmp/iocpmtest/Documents/ExportsEvil", isDirectory: true)
    check(ExportPath.destination(for: "x.txt", in: sibling)?
            .standardizedFileURL.path == "/tmp/iocpmtest/Documents/ExportsEvil/x.txt",
          "a folder whose name merely starts the same is treated as its own folder")

    // --- why this matters: the Foundation behaviour behind the bug ------------
    // Not testing our code - testing the two platform behaviours that made the old
    // version destructive, so the danger stays legible.
    let naive = exports.appendingPathComponent("..")
    check(naive.standardizedFileURL.path == "/tmp/iocpmtest/Documents",
          "appendingPathComponent(\"..\") really does resolve to the PARENT of Exports")
    check(naive.standardizedFileURL.path != exports.standardizedFileURL.path,
          "...which is Documents - the folder holding Disks, Imports and Exports")
}

@main
enum ExportPathTestMain {
    static func main() {
        runAllTests()
        print("\n" + String(repeating: "=", count: 60))
        print("Results: \(checks - failures) passed, \(failures) failed")
        if failures > 0 {
            print("Some tests failed")
            exit(1)
        }
        print("All tests passed")
        exit(0)
    }
}
