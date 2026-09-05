//
//  CatalogMigrationTests.swift
//
//  That renaming `hd1k_combo.img` to `hd1k_combo-v0-3.5.1.img` moves everything
//  the app remembers about it, and touches nothing else.
//
//  The four stores have to move together or the app is worse off than before
//  the rename: `start()` refuses to boot when a selected disk is neither on
//  disk nor in the catalog, and `saveDownloadedDisks()` silently discards the
//  running machine's image when the file its slot names is missing. So most of
//  the assertions here are about what is NOT renamed - the empty string that
//  means "bound to a local file", a user's own import, a name that has already
//  been through this pass - because those are the ones that lose data when they
//  are wrong.
//
//  The FileManager half is driven through `renames(in:)`, which takes a
//  directory listing and returns moves. That is the only way to check it here:
//  the machine this was written on has no Xcode, and `Tests/run_tests.sh` skips
//  every Swift suite on it.
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

// The two hashes this repository actually shipped for hd1k_combo, so the ledger
// half is driving the real case. `89b8ae1a…` is what v1.4.12's disks.xml claims;
// `0ca4ec60…` is what catalog-v0-3.5.1.json claims for the same disk, whose
// bytes genuinely did change. Nineteen of the twenty are byte-identical across
// the two catalogs; this is the one that is not.
let pinnedCombo = "89b8ae1aaa6867dc515c3511b34c4f0c311a77e99ff71066f5a774bef99cde1d"
let v0Combo = "0ca4ec60cb8bca71b8f0287c4b634c3126887be483db9b59b41bdff424f89303"

let legacyCombo = "hd1k_combo.img"
let v0Name = "hd1k_combo-v0-3.5.1.img"

func runAllTests() {

    section("One name at a time")

    check(CatalogMigration.migratedName(legacyCombo) == v0Name,
          "a catalog disk takes the version into its filename")
    check(CatalogMigration.migratedName("hd1k_zsdos.img") == "hd1k_zsdos-v0-3.5.1.img",
          "and so does every other one of the twenty")
    check(CatalogMigration.migratedName(legacyCombo, romwbwVersion: "3.6.0")
            == "hd1k_combo-v0-3.6.0.img",
          "the release is a parameter, so the version picker does not need a second table")

    // MARK: -

    section("What is left alone, which is the half that loses data")

    check(CatalogMigration.migratedName("") == nil,
          "\"\" is not a filename - it means BOTH \"no disk\" and \"this slot is bound to a local file\"")
    check(CatalogMigration.migratedName("my_stuff.img") == nil,
          "a disk the user imported through Files keeps the name they gave it")
    check(CatalogMigration.migratedName("hd1k_infocom.img") == nil,
          "a disk the catalog served and then dropped is not renamed into a provenance it does not have")
    check(CatalogMigration.migratedName("disks_catalog.xml") == nil,
          "the cached catalog lives in the same directory and is not a disk")
    check(CatalogMigration.migratedName("hd1k_combo.img.incoming") == nil,
          "a crashed download's staging file has extension \"incoming\", not \"img\"")
    check(CatalogMigration.migratedName("hd1k_combo") == nil,
          "a name with no extension at all is not a disk image")
    check(CatalogMigration.migratedName(".img") == nil,
          "and neither is a name with no stem")

    // MARK: -

    section("Running it twice is a no-op, because it will be run twice")

    check(CatalogMigration.migratedName(v0Name) == nil,
          "a name that already carries -v0- maps to nothing")
    let onceThroughSlots = CatalogMigration.migratedSlots([legacyCombo, "", "my_stuff.img", ""])
    check(CatalogMigration.migratedSlots(onceThroughSlots) == onceThroughSlots,
          "so a second pass over migrated slots changes nothing")
    check(CatalogMigration.migratedName("hd1k_combo-v0-3.6.0.img") == nil,
          "including a name migrated for a different release, which must not be re-stamped")

    // MARK: -

    section("The four slots keep their shape")

    check(CatalogMigration.migratedSlots([legacyCombo, "", "hd1k_bp.img", "my_stuff.img"])
            == [v0Name, "", "hd1k_bp-v0-3.5.1.img", "my_stuff.img"],
          "each slot maps independently, in place, and \"\" stays \"\"")
    check(CatalogMigration.migratedSlots(["", "", "", ""]) == ["", "", "", ""],
          "four empty slots come back as four empty slots, not as three or as nil")
    check(CatalogMigration.migratedSlots([]) == [],
          "and an empty array is not padded")

    // MARK: -

    section("A file that could not be renamed takes its stored names with it")

    // The file and every reference to it have to stay consistent. A slot
    // rewritten to a name whose file is still under the old one resolves to
    // nothing, and restoreDiskSelections() writes that nothing back over the
    // user's configuration.
    let stuck: Set<String> = [legacyCombo]
    check(CatalogMigration.migratedSlots([legacyCombo, "hd1k_bp.img"], notMoved: stuck)
            == [legacyCombo, "hd1k_bp-v0-3.5.1.img"],
          "the stuck one keeps its old name; the one beside it still migrates")
    check(CatalogMigration.migratedSlots([legacyCombo.uppercased()], notMoved: stuck)
            == [legacyCombo.uppercased()],
          "matched case-insensitively, like everything else that compares a filename here")

    // MARK: -

    section("Profiles: the disks move, the ROM does not")

    let profile = EmulatorProfile(name: "Work",
                                  romFilename: "emu_avw.rom",
                                  diskFilenames: [legacyCombo, "hd1k_ws4.img", "", "mine.img"],
                                  bootString: "1")
    let store = ProfileStore(profiles: [profile], lastUsedName: "Work")
    let migratedStore = CatalogMigration.migrated(store)
    let migratedProfile = migratedStore.profile(named: "Work")
    check(migratedProfile?.diskFilenames
            == [v0Name, "hd1k_ws4-v0-3.5.1.img", "", "mine.img"],
          "every slot in a saved profile goes through the same mapping as the live ones")
    check(migratedProfile?.romFilename == "emu_avw.rom",
          "romFilename names a file in the app BUNDLE, which did not move - renaming it would "
            + "make applyProfile report the ROM unresolved for every profile the user has")
    check(migratedProfile?.bootString == "1" && migratedProfile?.name == "Work",
          "and nothing else about the profile is touched")
    check(migratedStore.lastUsedName == "Work",
          "the last-used profile is still the last-used profile")

    let short = ProfileStore(profiles: [EmulatorProfile(name: "Short",
                                                        diskFilenames: [legacyCombo])])
    check(CatalogMigration.migrated(short).profile(named: "Short")?.diskFilenames.count == 4,
          "a profile that arrives with fewer than four slots still comes out with four")

    check(CatalogMigration.migrated(ProfileStore()).profiles.isEmpty,
          "no profiles is not an error")

    // MARK: -

    section("The ledger is rekeyed, never rebuilt")

    // Provenance says which PUBLISHED image these bytes came from, and a rename
    // does not change that. It also cannot be recomputed: adoptProvenanceIfCurrent
    // only adopts for a file that still hashes to the catalog, which is exactly
    // the disks the user has never written to. Dropping the ledger would leave
    // every disk they actually use at .unknownProvenance(matchesCatalog: false)
    // and give it a standing "any files you saved in it are lost" warning.
    let record = DiskRecord(installedCatalogSha256: pinnedCombo,
                            measuredSha256: pinnedCombo,
                            measuredSize: 51_380_224,
                            measuredModified: 1_234.5)
    var before = DiskLedger()
    before.setRecord(record, for: legacyCombo)
    before.setRecord(DiskRecord(installedCatalogSha256: v0Combo), for: "mine.img")
    let after = CatalogMigration.migrated(before)

    check(after.record(for: v0Name) == record,
          "the whole record moves to the new name, unchanged")
    check(after.record(for: legacyCombo) == nil,
          "and is not left behind under the old one as well")
    check(after.record(for: v0Name)?.installedCatalogSha256 == pinnedCombo,
          "provenance is carried, not re-derived - a rename is not a verified download")
    check(after.record(for: v0Name)?.measuredSize == 51_380_224
            && after.record(for: v0Name)?.measuredModified == 1_234.5,
          "and so are the size and mtime the measurement was taken against, which is what "
            + "makes a true rename cheap and a copy-then-delete ~210 MB of re-hashing")
    check(after.record(for: "mine.img")?.installedCatalogSha256 == v0Combo,
          "a record for a file the catalog does not name stays exactly where it was")
    check(after.records.count == before.records.count,
          "no record is dropped and none is invented")

    var stuckLedger = DiskLedger()
    stuckLedger.setRecord(record, for: legacyCombo)
    check(CatalogMigration.migrated(stuckLedger, notMoved: stuck).record(for: legacyCombo) == record,
          "a record whose file could not be renamed stays under the name that file still has")

    // Two names that fold together can only exist on a case-sensitive volume,
    // and both want the same destination. Sorted order decides, and the loser
    // keeps its own key rather than being dropped.
    var collide = DiskLedger()
    collide.setRecord(DiskRecord(installedCatalogSha256: pinnedCombo), for: "hd1k_bp.img")
    var occupied = DiskLedger()
    occupied.setRecord(DiskRecord(installedCatalogSha256: v0Combo), for: "hd1k_bp-v0-3.5.1.img")
    occupied.setRecord(DiskRecord(installedCatalogSha256: pinnedCombo), for: "hd1k_bp.img")
    let resolved = CatalogMigration.migrated(occupied)
    check(resolved.record(for: "hd1k_bp-v0-3.5.1.img")?.installedCatalogSha256 == v0Combo,
          "a record already filed under the v0 name holds it against one migrating onto it")
    check(resolved.record(for: "hd1k_bp.img")?.installedCatalogSha256 == pinnedCombo,
          "and the one that lost keeps its own key rather than being dropped")
    check(CatalogMigration.migrated(collide).record(for: "hd1k_bp-v0-3.5.1.img") != nil,
          "with the destination free, it moves as usual")

    // MARK: -

    section("Which files to rename, from a directory listing")

    let listing = [legacyCombo, "hd1k_bp.img", "mine.img", "disks_catalog.xml",
                   "hd1k_ws4.img.incoming"]
    let plan = CatalogMigration.renames(in: listing)
    check(plan == [CatalogMigration.Rename(from: "hd1k_bp.img", to: "hd1k_bp-v0-3.5.1.img"),
                   CatalogMigration.Rename(from: legacyCombo, to: v0Name)],
          "only the two catalog images, sorted, so two devices with the same directory agree")
    check(!plan.contains(where: { $0.from == "mine.img" }),
          "a user's own image is not moved - it cannot be re-downloaded from anywhere")
    check(!plan.contains(where: { $0.from == "disks_catalog.xml" }),
          "and neither is the cached catalog")
    check(!plan.contains(where: { $0.from == "hd1k_ws4.img.incoming" }),
          "nor a half-finished download's staging file")

    check(CatalogMigration.renames(in: [legacyCombo, v0Name]).isEmpty,
          "a destination that already exists is not renamed onto - moveItem would throw, and "
            + "this pass may not delete either copy")
    check(CatalogMigration.renames(in: [v0Name]).isEmpty,
          "an already-migrated directory has nothing to do")
    check(CatalogMigration.renames(in: []).isEmpty,
          "and neither has an empty one")

    // MARK: -

    section("A file that belongs to another release is not this release's to offer")

    check(CatalogMigration.belongsToAnotherRelease(v0Name, romwbwVersion: "3.6.0"),
          "under 3.6.0, a 3.5.1 image is another release's - offering it in the picker is "
            + "how someone boots a 3.5.1 disk against a 3.6.0 ROM by accident")
    check(!CatalogMigration.belongsToAnotherRelease(v0Name, romwbwVersion: "3.5.1"),
          "under 3.5.1 it is exactly the disk to offer")
    check(!CatalogMigration.belongsToAnotherRelease("my-v0-3.5.1.img", romwbwVersion: "3.6.0"),
          "a user's own file that happens to look versioned is never hidden - the stem has "
            + "to be one the catalog has named")
    check(!CatalogMigration.belongsToAnotherRelease("mine.img", romwbwVersion: "3.6.0"),
          "and neither is an ordinary import")
    check(!CatalogMigration.belongsToAnotherRelease(legacyCombo, romwbwVersion: "3.6.0"),
          "an unmigrated name carries no release, so nothing can be concluded from it")
    check(!CatalogMigration.belongsToAnotherRelease("hd1k_combo-v0-3.5.1.img.incoming",
                                                    romwbwVersion: "3.6.0"),
          "a staging file is not an image")
    check(CatalogMigration.belongsToAnotherRelease("HD1K_COMBO-V0-3.5.1.IMG",
                                                   romwbwVersion: "3.6.0"),
          "matched case-insensitively, like every other filename comparison here")

    // MARK: -

    section("Keys scoped to one RomWBW release")

    check(CatalogMigration.versionedKey("selectedDisks") == "selectedDisks.v0.3.5.1",
          "the interface and the release are both in the key")
    check(CatalogMigration.versionedKey("catalogGeneration", romwbwVersion: "3.6.0")
            == "catalogGeneration.v0.3.6.0",
          "so two releases cannot overwrite each other's - which for the generation key means "
            + "3.5.1 -> 3.6.0 -> 3.5.1 does not delete the library twice")
    check(CatalogMigration.versionedKey("selectedDisks") != "selectedDisks",
          "and none of them collides with the unsuffixed key an older build wrote, which is "
            + "what lets the migration copy a value across without destroying the original")
}

@main
enum CatalogMigrationTestMain {
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
