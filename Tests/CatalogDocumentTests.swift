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

// Two published releases, one stable and one preview, plus a third from a
// future this build has never heard of and a fourth with nothing to fetch.
// Neither of the last two is a hypothetical shape: an index that lists a
// release published after this binary was built is the normal case the moment
// romwbw_disks publishes 3.7.0, and since romwbw_emu v1.44 the right answer is
// to OFFER it - there is no compile-time list of runnable releases left to
// check it against, and the interface the core depends on is versioned by the
// index's own name. 3.4.0, which publishes no `catalog_url`, is the only entry
// still dropped, and for a reason that has nothing to do with the release.
//
// `default: true` is deliberately on the SECOND entry, not the first, and that
// placement is the whole point of the "Which one is selected" section below.
// It used to sit on 3.5.1, which is also `romwbw_versions[0]`, so every
// assertion about the flagged default passed just as well for a `preferred()`
// that had quietly reverted to taking the first entry offered - the guard on
// the one decision a fresh install makes could not fail. The live index has
// flagged the later release since 2026-09-05 anyway, so this is also the more
// faithful shape. Nothing couples `status` to `default`: a preview release may
// be flagged, and keeping 3.6.0 preview here keeps the pickerLabel coverage.
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
      "default": false,
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
      "default": true,
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
          "every entry survives decoding, including the one from a future release and "
            + "the one with nothing to fetch")
    check(index.romwbwVersions.first?.romwbwVersion == "3.5.1",
          "romwbw_version is snake_case in the document and camelCase here - the one "
            + "mapping that decides whether anything at all is found")
    check(index.romwbwVersions.first?.isDefault == false
            && index.romwbwVersions[1].isDefault == true,
          "`default` is a Swift keyword and needs its CodingKey, or the preselection "
            + "silently becomes 'the first entry' - and the flag is on the SECOND entry "
            + "precisely so that 'the first entry' is a different answer")
    check(index.romwbwVersions.first?.catalogSize == 11826
            && index.romwbwVersions.first?.catalogSHA256?.hasPrefix("7a5411b3") == true,
          "the two values the second hop is verified against are read")
    check(index.romwbwVersions.first?.generation == 1,
          "and the generation, which is the only thing that may delete a disk")
    check(index.romwbwVersions[1].notes == nil,
          "an entry that omits an optional array gets nil, not a decode failure")

    // MARK: -

    section("The packed version bytes are still decoded, as strings")

    let entry351 = index.romwbwVersions[0]
    check(entry351.hbios?.verByte == "0x35" && entry351.hbios?.updByte == "0x10",
          "hex STRINGS, kept verbatim - 3.5.1 is what the HCB at 0x105/0x106 holds, and "
            + "making these integers would be a v0 break")
    check(index.romwbwVersions[1].hbios?.updByte == "0x00",
          "3.6.0's update byte is \"0x00\" and must not decode as 'no value'")
    check(index.romwbwVersions[3].hbios?.verByte == "0x34",
          "and an entry with nothing else in it still carries them")

    // These stopped being an emulator gate in romwbw_emu v1.44 and stayed in
    // the document, because they describe the axis that is real: the
    // ROM-to-disk-image pairing the guest enforces with
    // *** WARNING: HBIOS/CBIOS Version Mismatch ***. Nothing in this app reads
    // them today. `versionBytes` and `hexByte`, which unpacked them for the
    // deleted filter, went with the filter rather than staying alive on these
    // tests alone - the comparisons this app makes are in release STRINGS.

    // MARK: -

    section("Which releases are offered: every one there is a catalog for")

    // Explicit on both, because the signature has no defaults on purpose: a
    // caller that forgets the opt-in should not compile. The fixture carries no
    // prerelease entry, so these two say nothing about snapshots - that is
    // runPrereleaseOptInTests' job.
    let offered = RomWBWIndex.offered(index.romwbwVersions,
                                      includingPrereleases: false,
                                      keeping: nil)
    check(offered.map { $0.romwbwVersion } == ["3.5.1", "3.6.0", "9.9.9"],
          "three of the four, in index order")
    check(offered.contains(where: { $0.romwbwVersion == "9.9.9" }),
          "a release published after this binary was built IS offered - this is the check "
            + "that reversed in romwbw_emu v1.44, and it reversed on purpose: there is no "
            + "compile-time list to refuse it with, the core loads any ROM whose HBIOS "
            + "configuration block it can read, and filtering could only hide a release "
            + "the user could have booted")
    check(!offered.contains(where: { $0.romwbwVersion == "3.4.0" }),
          "the one entry still dropped is the one with no catalog_url, because there "
            + "would be nothing to fetch - that guard is not a release filter and had to "
            + "survive the deletion of the one that was")
    check(RomWBWIndex.offered([], includingPrereleases: false, keeping: nil).isEmpty,
          "an index with no entries offers nothing")

    // MARK: -

    section("Which one is selected")

    check(RomWBWIndex.preferred(among: offered, keeping: "3.5.1")?.romwbwVersion == "3.5.1",
          "a release already in play is kept, even against the flagged default - and 3.5.1 "
            + "is the one that is NOT flagged, so this cannot pass by agreeing with it")
    check(RomWBWIndex.preferred(among: offered, keeping: nil)?.romwbwVersion == "3.6.0",
          "with no preference, the entry flagged default: true - this app carries no ROM "
            + "of its own, so there is no release it can boot more cheaply than any other. "
            + "3.6.0 is offered SECOND, so 'the first entry' would answer 3.5.1 and fail")
    check(RomWBWIndex.preferred(among: offered, keeping: "")?.romwbwVersion == "3.6.0",
          "an empty stored choice is no choice, and falls through to the flagged default "
            + "rather than matching an entry whose version is somehow empty too")
    check(RomWBWIndex.preferred(among: offered, keeping: "3.3.0")?.romwbwVersion == "3.6.0",
          "a stored choice the index no longer offers does not select nothing; it falls "
            + "through to the flagged default. 3.3.0 and not 9.9.9: 9.9.9 IS offered now, "
            + "so it would be kept, which is the whole point of the change")
    check(RomWBWIndex.preferred(among: offered, keeping: "9.9.9")?.romwbwVersion == "9.9.9",
          "and a release this build predates is kept once chosen, exactly like any other")
    check(RomWBWIndex.preferred(among: [], keeping: "3.5.1") == nil,
          "nothing offered selects nothing, which the caller has to report rather than paper over")

    let unflagged = [RomWBWIndexEntry.placeholder(romwbwVersion: "3.6.0"),
                     RomWBWIndexEntry.placeholder(romwbwVersion: "3.7.0")]
    check(RomWBWIndex.preferred(among: unflagged, keeping: nil)?.romwbwVersion == "3.6.0",
          "an index with no default at all still selects its first entry")

    check(RomWBWIndex.preferred(among: Array(unflagged.reversed()), keeping: nil)?
            .romwbwVersion == "3.7.0",
          "and that last rule is order-sensitive, which is the whole reason `preferred` is "
            + "handed the INDEX order and never the picker's: give it the newest-first "
            + "order the picker draws and 'the first entry' becomes 'the newest published "
            + "entry', which is exactly where a beta gets appended")

    // MARK: -

    section("What order the picker draws them in")

    check(RomWBWIndex.displayOrder(offered).map { $0.romwbwVersion } == ["9.9.9", "3.6.0", "3.5.1"],
          "newest published first - the index's last entry is the picker's top row, so a "
            + "release added to the index is where a hand reaching for this control lands")
    check(offered.map { $0.romwbwVersion } == ["3.5.1", "3.6.0", "9.9.9"],
          "and the array the decisions read is untouched by that: display order is a "
            + "separate function precisely so reversing rows cannot reach `preferred`")
    check(RomWBWIndex.displayOrder(offered).map { $0.romwbwVersion }
            != offered.map { $0.romwbwVersion },
          "the two orders really do differ, so neither check above can pass by accident "
            + "on a list that was already in the order it was being compared against")
    check(RomWBWIndex.displayOrder([]).isEmpty,
          "an empty list reorders to an empty list rather than trapping")
    check(RomWBWIndex.displayOrder([entry351]).map { $0.romwbwVersion } == ["3.5.1"],
          "and one row is its own order - which is what a first offline launch shows, "
            + "where the only row is the placeholder for the release in play")

    // MARK: -

    section("A preview release is marked as one")

    check(entry351.pickerLabel == "RomWBW 3.5.1",
          "the stable release reads as its plain label")
    check(index.romwbwVersions[1].pickerLabel == "RomWBW 3.6.0 (preview)",
          "and a preview says so where the choice is made, not in a note further down")
    check(index.romwbwVersions[1].isPreview && !entry351.isPreview,
          "which is decided from `status`, the index's own field")
    // REVERSED 2026-09-18, and the old assertion is worth stating because it was
    // deliberate: the placeholder "claims nothing about itself", so its row read
    // "RomWBW 3.5.1" - identical to the published 3.5.1 above it.
    //
    // That is what makes a failed index hop unreadable. romwbwVersions collapses
    // to exactly one of these, seeded from the release last in play, which on a
    // fresh or migrated install is legacyRomWBWVersion = "3.5.1". A one-row menu
    // reading "RomWBW 3.5.1" looks like an app that has DECIDED, not one that
    // could not ask - the reported symptom being "it is stuck on 3.5.1 and there
    // is no way to change it".
    //
    // The old rule conflated two claims. Refusing to invent a STATUS the entry
    // does not carry is right, and still holds. Refusing to say the list did not
    // load is not modesty - the app knows that, and it is the only thing the row
    // can usefully say.
    let ph = RomWBWIndexEntry.placeholder(romwbwVersion: "3.5.1")
    check(ph.pickerLabel == "RomWBW 3.5.1 - release list not loaded",
          "the placeholder row says the list did not load, rather than passing for a release")
    check(ph.pickerLabel != entry351.pickerLabel,
          "so it cannot be confused with the published 3.5.1 - the point of the change")
    check(ph.isPlaceholder && !entry351.isPlaceholder,
          "and that is decided by an explicit marker, not by a missing catalog_url")
    check(index.romwbwVersions.allSatisfy { !$0.isPlaceholder },
          "nothing the index published is ever a placeholder, including the entry with no catalog_url")
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

    runHelpTests()
}

// MARK: - The help block
//
// Cut from the published index, with the sizes and hashes as they are served.
// Help is a block INSIDE index-v0.json rather than a document beside it, which
// is what makes the tolerance below load-bearing: a shape this build cannot
// read shares its document with romwbw_versions, so getting it wrong costs the
// release list, the ROM and every disk rather than costing a help topic.

let helpIndexJSON = """
{
  "schema": "romwbw-disks-index",
  "interface": "v0",
  "help": {
    "base_url": "https://github.com/avwohl/romwbw_disks/releases/download/help-v0/",
    "topics": [
      {
        "id": "quick_start",
        "filename": "help_quick_start.md",
        "name": "Quick Start Guide",
        "description": "Getting started with the emulator",
        "size": 7387,
        "sha256": "5948d8f451cc80761c3234caaff8d12cb7c30e7b7b6b4a4ee0f7c86ef2d1486d"
      },
      {
        "id": "cpm22",
        "filename": "help_cpm22.md",
        "name": "CP/M 2.2 User Guide",
        "description": "Complete guide to CP/M 2.2 operating system",
        "size": 6035,
        "sha256": "4f457c250b984f37a0468ccf99aa22c9223562f55385da93071e7ad46c9572a7",
        "future_field": 7
      }
    ]
  },
  "romwbw_versions": []
}
"""

/// Four entries, two usable: one with no id, one with nothing to fetch, and one
/// that is not an object at all. The last is the reason topics are decoded
/// through a wrapper that cannot throw - a plain `try?` inside an unkeyed
/// container does not reliably step past the element that failed.
let helpRaggedJSON = """
{
  "help": {
    "base_url": "https://example.invalid/help/",
    "topics": [
      {"id": "good", "filename": "good.md", "name": "Good"},
      {"filename": "orphan.md", "name": "No id at all"},
      {"id": "unreachable", "name": "Neither filename nor url"},
      3,
      {"id": "later", "filename": "later.md"}
    ]
  },
  "romwbw_versions": []
}
"""

/// `topics` is not an array, so the whole block is unreadable. The release list
/// beside it must survive that.
let helpBrokenJSON = """
{
  "help": {"base_url": "https://example.invalid/help/", "topics": 3},
  "romwbw_versions": [
    {"romwbw_version": "3.6.0", "catalog_url": "https://example.invalid/c.json",
     "hbios": {"ver_byte": "0x36", "upd_byte": "0x00"}}
  ]
}
"""

func runHelpTests() {
    let decoder = JSONDecoder()

    section("The help topics are catalog entries in the index")

    guard let index = try? decoder.decode(RomWBWIndex.self,
                                          from: Data(helpIndexJSON.utf8)),
          let help = index.help else {
        check(false, "the published help block decodes")
        return
    }

    check(help.ok, "the block is usable")
    check(help.baseURL == "https://github.com/avwohl/romwbw_disks/releases/download/help-v0/",
          "one base_url for all of them")
    check(help.topics.count == 2, "both topics decode, unknown fields and all")

    // Keyed on id, never on position - the rule the schema states for disks[]
    // and roms[], and it holds here for the same reason.
    let quickStart = help.topics.first { $0.topicID == "quick_start" }
    check(quickStart?.filename == "help_quick_start.md", "quick_start names its file")
    check(quickStart?.name == "Quick Start Guide", "with a display name")
    check(quickStart?.size == 7387, "a size to check a download against")
    check(quickStart?.sha256?.count == 64, "and a 64-character sha256")
    check(help.assetURL(for: "help_quick_start.md")
            == "https://github.com/avwohl/romwbw_disks/releases/download/"
             + "help-v0/help_quick_start.md",
          "a topic URL is base_url + filename, with nothing inserted")

    section("One unusable topic does not take the others with it")

    guard let ragged = try? decoder.decode(RomWBWIndex.self,
                                           from: Data(helpRaggedJSON.utf8)),
          let raggedHelp = ragged.help else {
        check(false, "a ragged block still decodes")
        return
    }
    let usable = raggedHelp.topics.filter { $0.usable }.map { $0.id }
    check(usable == ["good", "later"],
          "the entry with no id, the one with nothing to fetch and the one that is not "
            + "an object are dropped; the other two are kept")
    check(raggedHelp.ok, "and the block is still usable")

    section("A help block this build cannot read costs help and nothing else")

    // THE POINT of decoding `help` with try?. Before the block existed the
    // index decoded with no help key at all, and it has to go on doing that;
    // after it existed, a future shape must not take the release list with it.
    guard let broken = try? decoder.decode(RomWBWIndex.self,
                                           from: Data(helpBrokenJSON.utf8)) else {
        check(false, "an index with an unreadable help block still decodes")
        return
    }
    check(broken.help == nil, "the unreadable block reads as absent")
    check(broken.romwbwVersions.count == 1,
          "and the release beside it survives, so the app still has a catalog")

    // An index published before the block existed. The client shows the topics
    // it shipped with, which is the same thing it does with no network.
    let noHelp = try? decoder.decode(RomWBWIndex.self, from: Data(indexJSON.utf8))
    check(noHelp != nil && noHelp?.help == nil,
          "an index carrying no help block at all is not an error")
}

func runPrereleaseOptInTests() {
    section("Development snapshots are off unless asked for")

    // Built here rather than added to indexJSON so the shape is explicit: one
    // real release that is the default, one snapshot, one entry with no
    // catalog_url (which the pre-existing guard drops whatever the setting is).
    let json = """
    {
      "romwbw_versions": [
        { "romwbw_version": "3.6.0", "label": "RomWBW 3.6.0", "default": true,
          "catalog_url": "https://example.invalid/a.json" },
        { "romwbw_version": "3.7.0-dev.14",
          "label": "RomWBW 3.7.0-dev.14 (development snapshot)",
          "status": "snapshot", "default": false, "prerelease": true,
          "catalog_url": "https://example.invalid/b.json" },
        { "romwbw_version": "9.9.9", "label": "nowhere to fetch from" }
      ]
    }
    """
    guard let idx = try? JSONDecoder().decode(RomWBWIndex.self,
                                              from: Data(json.utf8)) else {
        print("FAIL: the prerelease fixture did not decode")
        failures += 1
        return
    }
    let all = idx.romwbwVersions

    check(all.count == 3, "all three entries decode, snapshot and unusable alike")
    check(all[1].isPrerelease, "prerelease: true decodes")
    check(!all[0].isPrerelease,
          "and an entry with no prerelease key is NOT a snapshot - absent means false")

    // OFF: the default, and what an upgrading install gets with no migration.
    let off = RomWBWIndex.offered(all, includingPrereleases: false, keeping: nil)
    check(off.map(\.romwbwVersion) == ["3.6.0"],
          "off: the snapshot is not offered, and neither is the entry with no catalog")

    // ON.
    let on = RomWBWIndex.offered(all, includingPrereleases: true, keeping: nil)
    check(on.map(\.romwbwVersion) == ["3.6.0", "3.7.0-dev.14"],
          "on: the snapshot is offered; the entry with no catalog still is not")

    // THE CASE THAT PROTECTS THE PICKER. A user on the snapshot who turns the
    // toggle off keeps it in the list: a SwiftUI Picker whose selection matches
    // no tag renders blank, and a release switch is refused outright while the
    // machine is running, so dropping it here would strand the control.
    let kept = RomWBWIndex.offered(all, includingPrereleases: false,
                                   keeping: "3.7.0-dev.14")
    check(kept.map(\.romwbwVersion) == ["3.6.0", "3.7.0-dev.14"],
          "off, but the snapshot IN USE stays offered so the picker keeps a row")

    // And it is only ever the one in use that is spared.
    let notMine = RomWBWIndex.offered(all, includingPrereleases: false,
                                      keeping: "3.6.0")
    check(notMine.map(\.romwbwVersion) == ["3.6.0"],
          "a snapshot the user is NOT on is still hidden")

    // A snapshot must never be what the app picks by itself. The publisher
    // enforces never-default in two independent checks; this is the client
    // half - with the snapshot hidden, preferred lands on the real default.
    check(RomWBWIndex.preferred(among: off, keeping: nil)?.romwbwVersion == "3.6.0",
          "with snapshots off, the app selects the default release")
    check(RomWBWIndex.preferred(among: on, keeping: nil)?.romwbwVersion == "3.6.0",
          "and with them ON it still selects the default, not the newest")
}

func runReleaseMatchTests() {
    section("A ROM declares three numbers; a snapshot's catalog entry has four")

    // The case that was broken: the ROM can only read "3.7.0" out of its two
    // HCB bytes, and the catalog entry for the snapshot says "3.7.0-dev.14".
    check(RomWBWRelease.romServes(catalogVersion: "3.7.0-dev.14",
                                  declaredByROM: "3.7.0"),
          "a 3.7.0 ROM serves the 3.7.0-dev.14 entry it was published under")

    // The ordinary case, which must keep working.
    check(RomWBWRelease.romServes(catalogVersion: "3.6.0", declaredByROM: "3.6.0"),
          "a 3.6.0 ROM serves the 3.6.0 entry")
    check(RomWBWRelease.romServes(catalogVersion: "3.5.1", declaredByROM: "3.5.1"),
          "a 3.5.1 ROM serves the 3.5.1 entry")

    // THE REFUSALS. This is the half worth testing: the whole point of the
    // check is to refuse a mismatched pair, and loosening it must not loosen
    // that.
    check(!RomWBWRelease.romServes(catalogVersion: "3.7.0-dev.14",
                                   declaredByROM: "3.6.0"),
          "a 3.6.0 ROM does NOT serve the 3.7.0-dev.14 entry")
    check(!RomWBWRelease.romServes(catalogVersion: "3.6.0", declaredByROM: "3.5.1"),
          "a 3.5.1 ROM does NOT serve the 3.6.0 entry")
    check(!RomWBWRelease.romServes(catalogVersion: "3.5.1", declaredByROM: "3.6.0"),
          "a 3.6.0 ROM does NOT serve the 3.5.1 entry")

    // The forgiveness runs one way only. A ROM cannot declare a suffix, but if
    // some future one did, it must not be accepted against the bare release -
    // that direction would mean running a snapshot ROM on release disks.
    check(!RomWBWRelease.romServes(catalogVersion: "3.7.0",
                                   declaredByROM: "3.7.0-dev.14"),
          "and the rule is not symmetric: a 3.7.0-dev.14 ROM does not serve 3.7.0")

    // The separator is load-bearing. Without the "-" in the prefix test, a
    // hypothetical "3.7.01" would match a "3.7.0" ROM.
    check(!RomWBWRelease.romServes(catalogVersion: "3.7.01", declaredByROM: "3.7.0"),
          "a longer release number is not a pre-release of a shorter one")
    check(!RomWBWRelease.romServes(catalogVersion: "3.7.0dev", declaredByROM: "3.7.0"),
          "and neither is one that omits the separator")
}

@main
enum CatalogDocumentTestMain {
    static func main() {
        runAllTests()
        runReleaseMatchTests()
        runPrereleaseOptInTests()
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
