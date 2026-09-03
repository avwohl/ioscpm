//
//  DiskSize.swift
//  iOSCPM
//
//  The sizes a newly created disk image is allowed to be, and why the list is
//  not simply 8/16/32/64 MB.
//
//  This lives apart from the views for the same reason TerminalDialect,
//  ControlKey, ExportPath, CGAColor, TerminalRendition and TerminalScreen do:
//  it is a pure value with no UIKit behind it, which is the only reason
//  Tests/DiskSizeTests.swift can check the one thing that actually matters
//  here - that every size the picker offers is a size the emulator will accept.
//
//  ## The trap
//
//  The core does not take an image of any size. emu_check_disk_size() in
//  emu_init.cc rejects everything but four shapes:
//
//      exactly HD1K_SINGLE_SIZE                  (8388608)   one hd1k slice
//      HD1K_PREFIX_SIZE + N * HD1K_SINGLE_SIZE   (1 MB + Nx8 MB)  hd1k combo
//      exactly HD512_SINGLE_SIZE                 (8519680)   one hd512 slice
//      any multiple of HD512_SINGLE_SIZE                     hd512, N slices
//
//  A picker offering a round 16, 32 or 64 MB would therefore hand the user an
//  image the emulator refuses to load: 16777216 is none of those four. The
//  round numbers are exactly the wrong answer, which is why this list is
//  expressed in slices and the test suite re-derives the rule from the C header
//  rather than trusting the numbers written here.
//
//  ## Why the big ones are hd512 and not hd1k
//
//  A multi-slice hd1k image is a 1 MB prefix holding an MBR with a type-0x2E
//  partition, and HBIOS finds the slices by reading it (see the HBF_EXTSLICE
//  handler in hbios_dispatch.cc). A created disk is 0xE5 fill with no MBR, so
//  that partition would not be there and the slices could not be found.
//
//  With no MBR the same handler falls back on size alone: exactly 8 MB is read
//  as one hd1k slice, and anything else is read as hd512 with 16640-sector
//  slices. So a plain N x 8519680 image needs no partition table to work, and
//  each of its slices comes up as its own CP/M drive letter. That is the one
//  multi-slice shape this app can lay down honestly.
//
//  ## What a created disk still is not
//
//  0xE5 fill and nothing else. That is a blank CP/M directory - 0xE5 is the
//  empty-entry marker - so a slice of it comes up as an empty drive, but no
//  boot track and no system are written. KNOWN_PROBLEMS.md carries the cpmtools
//  recipe for a properly built bootable image, and this does not replace it.
//

import Foundation

/// One entry in the "New Disk" size picker.
struct DiskSize: Identifiable, Hashable {

    // The three constants from emu_init.h, restated here because Swift cannot
    // see that header. Tests/DiskSizeTests.swift pins them against it.
    static let hd1kSingleSize = 8_388_608    // HD1K_SINGLE_SIZE, 8 MB exactly
    static let hd1kPrefixSize = 1_048_576    // HD1K_PREFIX_SIZE, the MBR prefix
    static let hd512SingleSize = 8_519_680   // HD512_SINGLE_SIZE, 8.32 MB

    /// The app's own ceiling on an image it will load, from
    /// EmulatorViewModel.maxDiskSize. Restated rather than referenced so this
    /// type stays free of the view model.
    static let maxDiskSize = 64 * 1024 * 1024

    let bytes: Int
    /// How many CP/M drives the image comes up as.
    let slices: Int
    /// "hd1k" or "hd512" - what HBIOS will decide this image is, from its size.
    let format: String

    var id: Int { bytes }

    /// What the picker shows. Sizes are quoted in MB the way DownloadableDisk
    /// quotes them, so a created disk and a catalog disk read the same way.
    var label: String {
        let mb = Double(bytes) / 1_000_000
        let drives = slices == 1 ? "1 drive" : "\(slices) drives"
        return String(format: "%.1f MB (%@)", mb, drives)
    }

    /// The sizes offered, smallest first.
    ///
    /// 8 MB stays first and stays the default: it is what every disk in the
    /// catalog is, it is the one size the fallback reads as hd1k, and it is
    /// what this app has always created.
    ///
    /// The rest are hd512 slice counts. 7 is the largest that fits under
    /// `maxDiskSize`; 8 would be 68157440 bytes, which the app itself would
    /// then refuse to import.
    static let offered: [DiskSize] = [
        DiskSize(bytes: hd1kSingleSize, slices: 1, format: "hd1k"),
        DiskSize(bytes: hd512SingleSize * 2, slices: 2, format: "hd512"),
        DiskSize(bytes: hd512SingleSize * 4, slices: 4, format: "hd512"),
        DiskSize(bytes: hd512SingleSize * 7, slices: 7, format: "hd512"),
    ]

    /// The one the app creates unless the user says otherwise.
    static let `default` = DiskSize.offered[0]

    /// The offered size with this byte count, or the default.
    ///
    /// This is the door a persisted preference comes back through, so it has to
    /// answer for a number that is no longer offered - a shrunken list, a
    /// hand-edited defaults plist - rather than trust it. Falling back is the
    /// whole point: an unrecognised size would otherwise reach the writer and
    /// produce an image the emulator rejects.
    static func offered(bytes: Int) -> DiskSize {
        offered.first { $0.bytes == bytes } ?? .default
    }

    /// The rule emu_check_disk_size() applies, in Swift.
    ///
    /// Nothing in the app calls this - the offered list is fixed and every
    /// entry satisfies it. It exists so the test suite can assert that, which
    /// is the check that stops someone adding a round 16 MB to the list above.
    static func isAcceptableToCore(_ size: Int) -> Bool {
        if size == hd1kSingleSize { return true }
        if size > hd1kPrefixSize && (size - hd1kPrefixSize) % hd1kSingleSize == 0 { return true }
        if size == hd512SingleSize { return true }
        if size > 0 && size % hd512SingleSize == 0 { return true }
        return false
    }
}
