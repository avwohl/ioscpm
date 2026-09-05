//
//  CatalogDocumentTests.swift
//
//  That the two interface-v0 documents are read the way romwbw_disks says they
//  must be read, and that a document which is not the one that was asked for is
//  refused rather than adopted.
//
//  The JSON below is cut down from the real published documents
//  (catalog/v0/index.json and catalog/v0/3.5.1/catalog.json in romwbw_disks),
//  with the field names, the hex-string version bytes, the trailing slash on
//  base_url and the sparse `defaultSlot` kept exactly as they are published -
//  those are the details that decode to nil in silence when they are got wrong.
//  Unknown fields are left in on purpose: adding one is explicitly not an
//  interface break, so a parser that choked on `upstream` or `hcb` would be
//  broken by the next release rather than by a mistake.
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

// Two published releases, one stable and one preview, plus a third that no
// core will admit to supporting and a fourth with nothing to fetch. The last
// two are not hypothetical shapes: an index that lists a release this build
// cannot run is the normal case the moment romwbw_disks publishes 3.7.0.
let indexJSON = """
{
  "schema": "romwbw-disks-index",
  "schema_version": 1,
  "interface": "v0",
  "repo": "https://github.com/avwohl/romwbw_disks",
  "romwbw_versions": [
    {
      "romwbw_version": "3.5.1",
      "label": "RomWBW 3.5.1",
      "status": "stable",
      "default": true,
      "released": "2025-05-21",
      "hbios": { "major": 3, "minor": 5, "ver_byte": "0x35", "upd_byte": "0x10",
                 "sysver_de": "0x3510" },
      "release_tag": "v0-romwbw-3.5.1",
      "catalog_url": "https://example.invalid/v0-romwbw-3.5.1/catalog-v0-3.5.1.json",
      "catalog_sha256": "7a5411b329be606c2bcc7b8d2b051b8fca9a2906f780d65fc98221cb6b61ed65",
      "catalog_size": 11826,
      "generation": 1,
      "disk_count": 20,
      "notes": ["The RomWBW release every shipped client is pinned to today."]
    },
    {
      "romwbw_version": "3.6.0",
      "label": "RomWBW 3.6.0",
      "status": "preview",
      "default": false,
      "hbios": { "ver_byte": "0x36", "upd_byte": "0x00" },
      "catalog_url": "https://example.invalid/v0-romwbw-3.6.0/catalog-v0-3.6.0.json",
      "catalog_sha256": "3907ba2f23f2307fdbc220fd20e3209b877357b5df1057b86db86a905090191f",
      "catalog_size": 14694,
      "generation": 1,
      "disk_count": 24
    },
    {
      "romwbw_version": "9.9.9",
      "status": "preview",
      "hbios": { "ver_byte": "0x99", "upd_byte": "0x90" },
      "catalog_url": "https://example.invalid/v0-romwbw-9.9.9/catalog-v0-9.9.9.json",
      "catalog_sha256": "0000000000000000000000000000000000000000000000000000000000000000",
      "catalog_size": 1
    },
    {
      "romwbw_version": "3.4.0",
      "status": "stable",
      "hbios": { "ver_byte": "0x34", "upd_byte": "0x00" },
      "generation": 4
    }
  ]
}
"""

// One ROM flagged default and one not, in the order that would give the wrong
// answer to anything reading roms[0]; one disk with a defaultSlot and one
// without; and the unknown fields the real document carries.
let catalogJSON = """
{
  "schema": "romwbw-disks-catalog",
  "schema_version": 1,
  "interface": "v0",
  "romwbw_version": "3.5.1",
  "generation": 1,
  "status": "stable",
  "release_tag": "v0-romwbw-3.5.1",
  "base_url": "https://example.invalid/v0-romwbw-3.5.1/",
  "hbios": { "ver_byte": "0x35", "upd_byte": "0x10" },
  "upstream": { "tag": "v3.5.1" },
  "notes": ["CBIOS banner in the boot slices reads 'CBIOS v3.5.1 [WBW]'."],
  "roms": [
    {
      "id": "emu_rcz80",
      "filename": "emu_rcz80-v0-3.5.1.rom",
      "name": "EMU RCZ80",
      "size": 524288,
      "sha256": "ee3adea5caa9b3da4005e6a3d627e3eaf4ebd56f5795a5c41f6a90492850c4a7",
      "default": false,
      "hcb": { "marker": "57 A8", "version": "0x35" }
    },
    {
      "id": "emu_avw",
      "filename": "emu_avw-v0-3.5.1.rom",
      "name": "EMU AVW",
      "size": 524288,
      "sha256": "c7abc580b3285a33e439c0d6724a9d64dd3e93733a4fc2c1b80b0bfd91f9c580",
      "default": true,
      "built_from": { "bank0": "src/emu_hbios.asm" }
    }
  ],
  "disks": [
    {
      "id": "hd1k_combo",
      "filename": "hd1k_combo-v0-3.5.1.img",
      "name": "Combo (Recommended)",
      "description": "Six-slice disk.",
      "size": 51380224,
      "sha256": "0ca4ec60cb8bca71b8f0287c4b634c3126887be483db9b59b41bdff424f89303",
      "license": "Mixed",
      "format": "hd1k_combo",
      "bootable": true,
      "cbios": "CBIOS v3.5.1 [WBW]",
      "host_transfer": true,
      "upstream": "Binary/hd1k_combo.img",
      "slices": 6,
      "defaultSlot": 0
    },
    {
      "id": "hd1k_zsdos",
      "filename": "hd1k_zsdos-v0-3.5.1.img",
      "name": "ZSDOS",
      "description": "ZSDOS 1.1.",
      "size": 8388608,
      "sha256": "1111111111111111111111111111111111111111111111111111111111111111",
      "license": "Mixed",
      "cbios": null,
      "bootable": true
    }
  ]
}
"""

/// A core that runs 3.5.1 and 3.6.0 and nothing else - what
/// src/romwbw_pin.h's ROMWBW_SUPPORTED_RELEASES says today.
func todaysCore(_ ver: UInt8, _ upd: UInt8) -> Bool {
    (ver == 0x35 && upd == 0x10) || (ver == 0x36 && upd == 0x00)
}

func runAllTests() {

    let decoder = JSONDecoder()
    guard let index = try? decoder.decode(RomWBWIndex.self,
                                          from: Data(indexJSON.utf8)) else {
        print("FAIL: the index did not decode at all - nothing below can run")
        exit(1)
    }
    guard let catalog = try? decoder.decode(RomWBWCatalogDocument.self,
                                            from: Data(catalogJSON.utf8)) else {
        print("FAIL: the catalog did not decode at all - nothing below can run")
        exit(1)
    }

    section("The index decodes, unknown fields and all")

    check(index.interface == "v0" && index.romwbwVersions.count == 4,
          "every entry survives, including the two this build cannot use")
    check(index.romwbwVersions.first?.romwbwVersion == "3.5.1",
          "romwbw_version is snake_case in the document and camelCase here - the one "
            + "mapping that decides whether anything at all is found")
    check(index.romwbwVersions.first?.isDefault == true,
          "`default` is a Swift keyword and needs its CodingKey, or the preselection "
            + "silently becomes 'the first entry'")
    check(index.romwbwVersions.first?.catalogSize == 11826
            && index.romwbwVersions.first?.catalogSHA256?.hasPrefix("7a5411b3") == true,
          "the two values the second hop is verified against are read")
    check(index.romwbwVersions.first?.generation == 1,
          "and the generation, which is the only thing that may delete a disk")
    check(index.romwbwVersions[1].notes == nil,
          "an entry that omits an optional array gets nil, not a decode failure")

    // MARK: -

    section("Hex version bytes, which are strings and not numbers")

    check(RomWBWIndexEntry.hexByte("0x35") == 0x35, "the published spelling")
    check(RomWBWIndexEntry.hexByte("0X36") == 0x36, "and an upper-case prefix")
    check(RomWBWIndexEntry.hexByte("35") == 0x35, "a bare pair of hex digits")
    check(RomWBWIndexEntry.hexByte("0x00") == 0x00, "0x00 is a value, not 'missing'")
    check(RomWBWIndexEntry.hexByte(nil) == nil, "absent is nil")
    check(RomWBWIndexEntry.hexByte("") == nil, "so is empty")
    check(RomWBWIndexEntry.hexByte("0x350") == nil,
          "and so is a number that does not fit in a byte - a wrong answer here would "
            + "be handed to the core as a release it has never heard of")
    check(RomWBWIndexEntry.hexByte("three") == nil, "and so is nonsense")

    let entry351 = index.romwbwVersions[0]
    check(entry351.versionBytes?.ver == 0x35 && entry351.versionBytes?.upd == 0x10,
          "3.5.1 packs to 35 10, which is what the HCB at 0x105/0x106 holds")
    check(index.romwbwVersions[1].versionBytes?.upd == 0x00,
          "3.6.0's update byte is 0x00 and must not be read as 'no value'")

    // MARK: -

    section("Which releases are offered, asked of the core and not assumed")

    let offered = RomWBWIndex.offered(index.romwbwVersions, supported: todaysCore)
    check(offered.map { $0.romwbwVersion } == ["3.5.1", "3.6.0"],
          "the two the core says it can run, in index order")
    check(!offered.contains(where: { $0.romwbwVersion == "9.9.9" }),
          "a published release this build has never been checked against is not offered - "
            + "the core would refuse its ROM anyway, with a message about an untested release")
    check(!offered.contains(where: { $0.romwbwVersion == "3.4.0" }),
          "and neither is one with no catalog_url, because there would be nothing to fetch")
    check(RomWBWIndex.offered(index.romwbwVersions, supported: { _, _ in false }).isEmpty,
          "a core that supports nothing offers nothing - a real, reportable condition and "
            + "not a reason to fall back to a hardcoded tag")
    check(RomWBWIndex.offered([], supported: todaysCore).isEmpty,
          "an index with no entries offers nothing")

    // MARK: -

    section("Which one is selected")

    check(RomWBWIndex.preferred(among: offered, keeping: "3.6.0",
                                bundledROMRelease: "3.5.1")?.romwbwVersion == "3.6.0",
          "a release already in play is kept, even against the bundled ROM's own")
    check(RomWBWIndex.preferred(among: offered, keeping: nil,
                                bundledROMRelease: "3.6.0")?.romwbwVersion == "3.6.0",
          "with no preference, the release the BUNDLED ROM declares wins - this app ships "
            + "one ROM and cannot download another, so what it can boot outranks a hint")
    check(RomWBWIndex.preferred(among: offered, keeping: nil,
                                bundledROMRelease: nil)?.romwbwVersion == "3.5.1",
          "and with no bundled ROM either, the entry flagged default: true")
    check(RomWBWIndex.preferred(among: offered, keeping: "9.9.9",
                                bundledROMRelease: "9.9.9")?.romwbwVersion == "3.5.1",
          "a stored choice the index no longer offers does not select nothing; it falls "
            + "through to the flagged default")
    check(RomWBWIndex.preferred(among: [], keeping: "3.5.1",
                                bundledROMRelease: "3.5.1") == nil,
          "nothing offered selects nothing, which the caller has to report rather than paper over")

    let unflagged = [RomWBWIndexEntry.placeholder(romwbwVersion: "3.6.0"),
                     RomWBWIndexEntry.placeholder(romwbwVersion: "3.7.0")]
    check(RomWBWIndex.preferred(among: unflagged, keeping: nil,
                                bundledROMRelease: nil)?.romwbwVersion == "3.6.0",
          "an index with no default at all still selects its first entry")

    // MARK: -

    section("A preview release is marked as one")

    check(entry351.pickerLabel == "RomWBW 3.5.1",
          "the stable release reads as its plain label")
    check(index.romwbwVersions[1].pickerLabel == "RomWBW 3.6.0 (preview)",
          "and a preview says so where the choice is made, not in a note further down")
    check(index.romwbwVersions[1].isPreview && !entry351.isPreview,
          "which is decided from `status`, the index's own field")
    check(RomWBWIndexEntry.placeholder(romwbwVersion: "3.5.1").pickerLabel == "RomWBW 3.5.1",
          "an entry with no status claims nothing about itself")
    check(RomWBWIndexEntry.placeholder(romwbwVersion: "3.5.1").displayLabel == "RomWBW 3.5.1",
          "and one with no label is still named after its release")

    // MARK: -

    section("The catalog is verified before it is parsed")

    let rightHash = "7a5411b329be606c2bcc7b8d2b051b8fca9a2906f780d65fc98221cb6b61ed65"
    check(entry351.payloadProblem(byteCount: 11826, sha256: rightHash) == nil,
          "the size and the checksum the index promised")
    check(entry351.payloadProblem(byteCount: 11826, sha256: rightHash.uppercased()) == nil,
          "compared case-insensitively, because hex is hex")
    check(entry351.payloadProblem(byteCount: 11825, sha256: rightHash) != nil,
          "one byte short is refused - a truncated document parses to a short disk list, "
            + "and a short list makes start() refuse to boot a slot it can no longer resolve")
    check(entry351.payloadProblem(byteCount: 11826,
                                  sha256: String(repeating: "0", count: 64)) != nil,
          "and so is the right length with the wrong bytes")
    check(RomWBWIndexEntry.placeholder(romwbwVersion: "3.5.1")
            .payloadProblem(byteCount: 10, sha256: rightHash) != nil,
          "an entry that carries no checksum cannot be verified, and a gate that cannot "
            + "verify must not say yes")

    // MARK: -

    section("...and refused when it is the wrong document")

    check(entry351.documentProblem(catalog, expectedInterface: "v0") == nil,
          "the 3.5.1 catalog is what the 3.5.1 entry asked for")
    check(index.romwbwVersions[1].documentProblem(catalog, expectedInterface: "v0") != nil,
          "the 3.5.1 catalog under the 3.6.0 entry is refused - the hash cannot catch this, "
            + "it says only that the bytes are the ones the index pointed at")
    check(entry351.documentProblem(catalog, expectedInterface: "v1") != nil,
          "and so is a document from an interface this app does not read")

    // MARK: -

    section("The catalog decodes, and the URL join is the document's")

    check(catalog.romwbwVersion == "3.5.1" && catalog.generation == 1
            && catalog.status == "stable",
          "the three fields outside the arrays that anything acts on")
    check(catalog.diskEntries.count == 2 && catalog.romEntries.count == 2,
          "both arrays, with their unknown fields ignored rather than rejected")
    check(catalog.assetURL(for: "hd1k_combo-v0-3.5.1.img")
            == "https://example.invalid/v0-romwbw-3.5.1/hd1k_combo-v0-3.5.1.img",
          "base_url ends in / and is concatenated - the old parser appended its own and "
            + "would produce a doubled separator here")
    check(!catalog.assetURL(for: "x.img").contains("//v0-"),
          "no doubled separator anywhere in the join")

    let noSlash = try? decoder.decode(RomWBWCatalogDocument.self, from: Data("""
    { "base_url": "https://example.invalid/tag", "disks": [] }
    """.utf8))
    check(noSlash?.assetURL(for: "a.img") == "https://example.invalid/tag/a.img",
          "a document that somehow lost its trailing slash still yields the right URL "
            + "instead of turning every download into a 404")

    // MARK: -

    section("Disk entries: the fields the download path cannot do without")

    let combo = catalog.diskEntries[0]
    check(combo.id == "hd1k_combo" && combo.filename == "hd1k_combo-v0-3.5.1.img",
          "id and filename are different things and both are read")
    check(combo.size == 51_380_224,
          "the field is `size`, not `sizeBytes` - a wrong key here decodes to nil and the "
            + "app displays every disk as 0 KB")
    check(combo.sha256?.hasPrefix("0ca4ec60") == true,
          "and `sha256`, without which the download path refuses the disk outright")
    check(combo.defaultSlot == 0,
          "defaultSlot is camelCase in the document, and 0 is a slot number, not 'unset'")
    check(catalog.diskEntries[1].defaultSlot == nil,
          "19 of the 20 published disks carry no defaultSlot at all")
    check(catalog.diskEntries[1].description != nil,
          "a description is present even on the entries with no slot")

    // MARK: -

    section("ROM entries: keyed on the flag, never on position")

    check(catalog.defaultROM?.id == "emu_avw",
          "the default ROM is the one flagged default: true, which is not roms[0] here")
    check(catalog.defaultROM?.filename == "emu_avw-v0-3.5.1.rom",
          "and it names a versioned file, not the emu_avw.rom in the app bundle")

    let noROMs = try? decoder.decode(RomWBWCatalogDocument.self, from: Data("""
    { "base_url": "https://example.invalid/tag/", "disks": [] }
    """.utf8))
    check(noROMs?.romEntries.isEmpty == true && noROMs?.defaultROM == nil,
          "a catalog with no roms[] at all is a shape to survive, not to fail on - the "
            + "schema promises neither that it is present nor that emu_avw is in it")
    check(noROMs?.diskEntries.isEmpty == true,
          "and an empty disks array decodes to an empty array")

    let oneROM = try? decoder.decode(RomWBWCatalogDocument.self, from: Data("""
    { "base_url": "https://example.invalid/tag/",
      "roms": [{ "id": "only", "filename": "only.rom" }] }
    """.utf8))
    check(oneROM?.defaultROM?.id == "only",
          "with nothing flagged, the first ROM stands in rather than nothing at all")

    // MARK: -

    section("A ROM is checked before it is used, every time")

    guard let avw = catalog.defaultROM else {
        print("FAIL: the catalog's default ROM is missing - the checks below cannot run")
        exit(1)
    }
    let goodHash = "c7abc580b3285a33e439c0d6724a9d64dd3e93733a4fc2c1b80b0bfd91f9c580"

    check(catalog.assetURL(for: avw.filename)
            == "https://example.invalid/v0-romwbw-3.5.1/emu_avw-v0-3.5.1.rom",
          "a ROM's URL is base_url + filename, the same concatenation a disk gets")

    check(avw.problem(byteCount: 524288, sha256: goodHash) == nil,
          "the size and the checksum the catalog published, and nothing to say")
    check(avw.problem(byteCount: 524288, sha256: goodHash.uppercased()) == nil,
          "hex case is not a difference - the catalog writes lower case and CryptoKit "
            + "could be formatted either way")
    check(avw.problem(byteCount: 262144, sha256: goodHash)?.contains("524288") == true,
          "a truncated file is caught on its size, which is the cheap half and names "
            + "the likeliest fault - a download that stopped early")
    check(avw.problem(byteCount: 524288,
                      sha256: String(repeating: "0", count: 64)) != nil,
          "and a file of the right length whose bytes are not the published ones is "
            + "refused: this is the check that catches a ROM corrupted after it landed, "
            + "which verifying only on download would never look at again")

    let unhashed = try? decoder.decode(RomWBWCatalogDocument.self, from: Data("""
    { "base_url": "https://example.invalid/tag/",
      "roms": [{ "id": "nohash", "filename": "nohash.rom", "size": 524288 }] }
    """.utf8))
    check(unhashed?.defaultROM?.problem(byteCount: 524288, sha256: goodHash) != nil,
          "an entry with no sha256 fails rather than being waved through - a gate that "
            + "cannot verify must not say yes, and the disk path refuses one for the "
            + "same reason")

    let unsized = try? decoder.decode(RomWBWCatalogDocument.self, from: Data("""
    { "base_url": "https://example.invalid/tag/",
      "roms": [{ "id": "nosize", "filename": "nosize.rom",
                 "sha256": "\(goodHash)" }] }
    """.utf8))
    // Asserted separately because the check below reads `== nil`, and every
    // step of `unsized?.defaultROM?.problem(...)` answers nil when the one
    // before it did. A document that failed to decode would satisfy it without
    // the gate ever running - a green line for a test that tested nothing.
    check(unsized?.defaultROM?.filename == "nosize.rom",
          "the sizeless entry decoded and was found, so the check below is about the "
            + "gate rather than about an optional chain giving up early")
    check(unsized?.defaultROM?.problem(byteCount: 999, sha256: goodHash) == nil,
          "an entry with no size is judged on its checksum alone: nothing in the schema "
            + "promises a size, and upstream 3.6.0 already ships ROMs that are not 512KB")

    // MARK: -

    section("A remembered ROM name is matched by catalog id")

    check(avw.answersTo("emu_avw-v0-3.5.1.rom"),
          "its own filename, which is what a profile saved under this release carries")
    check(avw.answersTo("EMU_AVW-V0-3.5.1.ROM"),
          "case-folded, like every other name comparison in this app")
    check(avw.answersTo("emu_avw.rom"),
          "the BUNDLE name a build before catalog ROMs wrote down - it means emu_avw, "
            + "and reporting every existing profile's ROM as unresolved would be the "
            + "cost of insisting on an exact filename")
    check(avw.answersTo("emu_avw-v0-3.6.0.rom"),
          "and the same ROM under another release: a profile is not per release, so "
            + "what it names is the ROM and not one release's file")
    check(avw.answersTo("emu_avw"),
          "the bare id, which is what the remembered choice is stored as")
    check(!avw.answersTo("emu_rcz80-v0-3.5.1.rom"),
          "but never the OTHER published ROM - the two ids differ, which is the whole "
            + "reason to key on the id")
    check(!avw.answersTo("emu_avwx"),
          "and not a name that merely starts with the id: the boundary is the '-' the "
            + "filename convention puts there")
    check(!avw.answersTo(""),
          "an empty name matches nothing, so a profile that carries no ROM is left alone")

    // MARK: -

    section("What to say when a fetch does not produce a document")

    check(CatalogTransfer.problem(errorDescription: nil, statusCode: 200,
                                  byteCount: 11826) == nil,
          "200 with bytes is worth parsing")
    check(CatalogTransfer.problem(errorDescription: "The Internet connection appears to be offline.",
                                  statusCode: nil, byteCount: nil) != nil,
          "a transport error is reported as itself")
    check(CatalogTransfer.problem(errorDescription: nil, statusCode: 404,
                                  byteCount: 9)?.contains("404") == true,
          "a 404 names itself: for the second hop it means the tag is there and the "
            + "catalog asset is not, which no amount of reconnecting fixes")
    check(CatalogTransfer.problem(errorDescription: nil, statusCode: 503, byteCount: 9) != nil,
          "and so does any other non-2xx status")
    check(CatalogTransfer.problem(errorDescription: nil, statusCode: 200, byteCount: 0) != nil,
          "an empty 200 is not a catalog - GitHub serves one for an asset that is still "
            + "uploading, and parsing it would report zero disks as though that were news")
    check(CatalogTransfer.problem(errorDescription: nil, statusCode: nil,
                                  byteCount: 11826) == nil,
          "a response with no HTTP status but with bytes is still worth parsing")

    check(CatalogTransfer.sentence("The Internet connection appears to be offline.")
            == "The Internet connection appears to be offline.",
          "a reason that already ends in a full stop keeps exactly one")
    check(CatalogTransfer.sentence("the server answered HTTP 503")
            == "the server answered HTTP 503.",
          "and a clause gets one, so the two can be joined into a message that does not "
            + "read as a typo in the one place a user sees when nothing works")
    check(CatalogTransfer.sentence("  spaced  ") == "spaced.",
          "trimmed first, so the stop lands against the text")
    check(CatalogTransfer.sentence("") == "",
          "and an empty reason stays empty rather than becoming a lone full stop")
}

@main
enum CatalogDocumentTestMain {
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
