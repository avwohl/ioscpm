//
//  DiskSizeTests.swift
//
//  That every size the "New Disk" picker offers is a size the emulator will
//  actually load.
//
//  `todo.txt` carried "new disks are always 8 MB and the size is hardcoded
//  twice" from build 51. The obvious fix - offer 8, 16, 32 and 64 MB - would
//  have produced three images the core refuses: emu_check_disk_size() in
//  emu_init.cc takes exactly 8388608, or a 1 MB prefix plus a whole number of
//  8 MB hd1k slices, or a whole number of 8519680-byte hd512 slices, and
//  16777216 is none of them. So the interesting assertion is not "the picker
//  has four entries", it is "the emulator would take all four", and that is
//  what this file checks.
//
//  The three constants are re-read out of the C header rather than copied, so
//  a change upstream fails here instead of at a user's file picker.
//
//  Run with Tests/run_tests.sh.
//

import Foundation

var failures = 0
var checks = 0

func check(_ condition: Bool, _ label: String) {
    checks += 1
    if !condition { failures += 1 }
    print("\(condition ? "PASS" : "FAIL"): \(label)")
}

func section(_ title: String) {
    print("\n\(title)")
    print(String(repeating: "-", count: 60))
}

func section(_ title: String, _ body: () -> Void) {
    section(title)
    body()
}

/// Pull `static constexpr size_t NAME = <digits>;` out of iOSCPM/Core/emu_init.h.
///
/// The header is a symlink into ../romwbw_emu/src, so this is the check that
/// notices when the shared core changes a disk geometry out from under this
/// port - the same job Tests/run_tests.sh's symlink check does for the files.
func constantFromEmuInitHeader(_ name: String) -> Int? {
    let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let header = here.deletingLastPathComponent()
        .appendingPathComponent("iOSCPM/Core/emu_init.h")
    guard let text = try? String(contentsOf: header, encoding: .utf8) else { return nil }
    // split(whereSeparator: \.isNewline), not split(separator: "\n"). The shared
    // core is authored with CRLF line endings, and Swift folds "\r\n" into a
    // single grapheme that is not equal to Character("\n") - so splitting on
    // "\n" hands back the whole file as one line and every constant below reads
    // as the first number in the header.
    for line in text.split(whereSeparator: \.isNewline) {
        guard line.contains(name), line.contains("constexpr") else { continue }
        guard let eq = line.firstIndex(of: "=") else { continue }
        let rhs = line[line.index(after: eq)...]
        let digits = rhs.drop { !$0.isNumber }.prefix { $0.isNumber }
        if let v = Int(digits) { return v }
    }
    return nil
}

func runAllTests() {

    section("The geometry constants still say what this file thinks they say") {
        let single = constantFromEmuInitHeader("HD1K_SINGLE_SIZE")
        let prefix = constantFromEmuInitHeader("HD1K_PREFIX_SIZE")
        let hd512 = constantFromEmuInitHeader("HD512_SINGLE_SIZE")
        check(single != nil && prefix != nil && hd512 != nil,
              "all three constants are readable from iOSCPM/Core/emu_init.h")
        check(single == DiskSize.hd1kSingleSize, "HD1K_SINGLE_SIZE still is \(DiskSize.hd1kSingleSize)")
        check(prefix == DiskSize.hd1kPrefixSize, "HD1K_PREFIX_SIZE still is \(DiskSize.hd1kPrefixSize)")
        check(hd512 == DiskSize.hd512SingleSize, "HD512_SINGLE_SIZE still is \(DiskSize.hd512SingleSize)")
    }

    section("Every offered size is one the emulator will load") {
        check(!DiskSize.offered.isEmpty, "the picker offers something")
        for size in DiskSize.offered {
            check(DiskSize.isAcceptableToCore(size.bytes),
                  "\(size.label) (\(size.bytes) bytes) passes emu_check_disk_size")
            check(size.bytes <= DiskSize.maxDiskSize,
                  "\(size.label) is within the app's own \(DiskSize.maxDiskSize)-byte ceiling")
            check(size.bytes > 0, "\(size.label) is not empty")
            check(size.slices >= 1, "\(size.label) is at least one drive")
        }
        let bytes = DiskSize.offered.map { $0.bytes }
        check(Set(bytes).count == bytes.count, "no size is offered twice")
        check(bytes == bytes.sorted(), "and they are offered smallest first")
    }

    section("Each offered size is the shape its `format` claims") {
        for size in DiskSize.offered where size.format == "hd1k" {
            check(size.bytes == DiskSize.hd1kSingleSize,
                  "an hd1k created disk is exactly one 8 MB slice - with no MBR, nothing else is read as hd1k")
            check(size.slices == 1, "and is one drive")
        }
        for size in DiskSize.offered where size.format == "hd512" {
            check(size.bytes % DiskSize.hd512SingleSize == 0,
                  "\(size.label) is a whole number of hd512 slices")
            check(size.bytes / DiskSize.hd512SingleSize == size.slices,
                  "and its slice count matches the drives it claims")
            check(size.bytes != DiskSize.hd1kSingleSize,
                  "and is not 8 MB, which the no-MBR fallback would read as hd1k instead")
        }
        check(DiskSize.offered.contains { $0.format == "hd512" && $0.slices > 1 },
              "at least one multi-drive size is offered - that was the point of the item")
    }

    section("The round numbers a naive picker would have offered") {
        // These are the trap. Each is a plausible menu entry and each produces
        // an image emu_check_disk_size() refuses.
        check(!DiskSize.isAcceptableToCore(16 * 1024 * 1024), "a round 16 MB image is refused by the core")
        check(!DiskSize.isAcceptableToCore(32 * 1024 * 1024), "and a round 32 MB one")
        check(!DiskSize.isAcceptableToCore(64 * 1024 * 1024), "and a round 64 MB one")
        check(!DiskSize.offered.contains { $0.bytes == 16 * 1024 * 1024 }, "so 16 MB is not offered")
        check(!DiskSize.offered.contains { $0.bytes == 32 * 1024 * 1024 }, "nor 32 MB")
        check(!DiskSize.offered.contains { $0.bytes == 64 * 1024 * 1024 }, "nor 64 MB")
    }

    section("isAcceptableToCore agrees with emu_check_disk_size on the four shapes") {
        check(DiskSize.isAcceptableToCore(DiskSize.hd1kSingleSize), "one hd1k slice is accepted")
        check(DiskSize.isAcceptableToCore(DiskSize.hd512SingleSize), "one hd512 slice is accepted")
        check(DiskSize.isAcceptableToCore(DiskSize.hd512SingleSize * 6), "six hd512 slices are accepted")
        check(DiskSize.isAcceptableToCore(DiskSize.hd1kPrefixSize + DiskSize.hd1kSingleSize),
              "a 1-slice hd1k combo (1 MB prefix + 8 MB) is accepted")
        check(DiskSize.isAcceptableToCore(DiskSize.hd1kPrefixSize + DiskSize.hd1kSingleSize * 6),
              "and the 49 MB 6-slice combo KNOWN_PROBLEMS.md documents")
        check(!DiskSize.isAcceptableToCore(0), "an empty image is refused")
        check(!DiskSize.isAcceptableToCore(512), "a single sector is refused")
        check(!DiskSize.isAcceptableToCore(DiskSize.hd1kSingleSize - 1), "one byte short of a slice is refused")
        check(!DiskSize.isAcceptableToCore(DiskSize.hd1kSingleSize + 1), "one byte over is refused")
        check(!DiskSize.isAcceptableToCore(DiskSize.hd1kPrefixSize), "the bare prefix with no slice is refused")
    }

    section("Coming back from a stored preference") {
        for size in DiskSize.offered {
            check(DiskSize.offered(bytes: size.bytes) == size, "\(size.label) round-trips through its byte count")
        }
        check(DiskSize.offered(bytes: 16 * 1024 * 1024) == DiskSize.default,
              "a stored size that is no longer offered falls back to the default")
        check(DiskSize.offered(bytes: 0) == DiskSize.default, "and so does a missing one")
        check(DiskSize.offered(bytes: -1) == DiskSize.default, "and a nonsensical one")
        check(DiskSize.default.bytes == DiskSize.hd1kSingleSize,
              "the default is still the 8 MB single slice every catalog disk is")
    }

    section("Labels") {
        check(DiskSize.default.label.contains("1 drive"), "a single-slice size says one drive")
        check(DiskSize.offered.allSatisfy { $0.label.contains("MB") }, "every label quotes a size in MB")
        check(DiskSize.offered.filter { $0.slices > 1 }.allSatisfy { $0.label.contains("drives") },
              "and every multi-slice one says how many drives it comes up as")
        check(Set(DiskSize.offered.map { $0.label }).count == DiskSize.offered.count,
              "no two entries read the same in the menu")
    }
}

@main
enum DiskSizeTestMain {
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
