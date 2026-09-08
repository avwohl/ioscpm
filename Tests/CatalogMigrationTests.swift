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

    check(migratedProfile?.romwbwVersion == "3.5.1",
          "and the profile is stamped with the release its slots are now named for - a "
            + "profile written before the picker existed carries no release, and without "
            + "one applyProfile can only report an unresolved slot as a bare filename")
    let alreadyStamped = ProfileStore(profiles: [
        EmulatorProfile(name: "kept", diskFilenames: ["hd1k_combo.img", "", "", ""],
                        romwbwVersion: "3.6.0")])
    check(CatalogMigration.migrated(alreadyStamped).profiles.first?.romwbwVersion == "3.6.0",
          "a profile that already names a release keeps it - it was saved by a build that "
            + "knew which one, and overwriting that would file it under the wrong release")

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

    section("A stem published after this app was built")

    // hd1k_msx exists under 3.6.0 and not under 3.5.1, and it is bootable. It is
    // one of five - hd1k_cobol, hd1k_dos65, hd1k_infocom, hd1k_msx, hd1k_wp -
    // and no build of this app can have them in a frozen table, because they
    // were published after it. The whole point of the catalog is that more will
    // follow.
    let laterRelease = "hd1k_msx-v0-3.6.0.img"

    check(!CatalogMigration.belongsToAnotherRelease(laterRelease, romwbwVersion: "3.5.1"),
          "against the frozen pre-v0 table a 3.6.0-only disk reads as a user import, which "
            + "is how a 3.6.0 system disk gets offered to a 3.5.1 machine")
    check(CatalogMigration.belongsToAnotherRelease(
              laterRelease, romwbwVersion: "3.5.1",
              knownStems: CatalogMigration.catalogDiskStems.union(["hd1k_msx"])),
          "once the app has SEEN the 3.6.0 catalog publish it, the same file is correctly "
            + "another release's - which is why the runtime caller passes what it observed")
    check(!CatalogMigration.belongsToAnotherRelease(
              laterRelease, romwbwVersion: "3.6.0",
              knownStems: CatalogMigration.catalogDiskStems.union(["hd1k_msx"])),
          "and under 3.6.0 it is this release's disk, so it stays in the picker")
    check(!CatalogMigration.belongsToAnotherRelease(
              "mine-v0-3.6.0.img", romwbwVersion: "3.5.1",
              knownStems: CatalogMigration.catalogDiskStems.union(["hd1k_msx"])),
          "observing more stems never widens it to a name no catalog published")

    check(CatalogMigration.versionedParts(of: laterRelease)?.stem == "hd1k_msx",
          "versionedParts reads the stem back out, which is how the app records what it saw")
    check(CatalogMigration.versionedParts(of: laterRelease)?.release == "3.6.0",
          "and the release")
    check(CatalogMigration.versionedParts(of: "HD1K_MSX-V0-3.6.0.IMG")?.stem == "hd1k_msx",
          "folded, so a case-insensitive volume records one stem and not two")
    check(CatalogMigration.versionedParts(of: legacyCombo) == nil,
          "a pre-v0 name has no release in it to read")
    check(CatalogMigration.versionedParts(of: "hd1k_combo-v0-3.5.1.img.incoming") == nil,
          "and a staging file is not an image")
    check(CatalogMigration.versionedParts(of: "odd-v0-x-v0-3.6.0.img")?.stem == "odd-v0-x",
          "split at the LAST marker, so a name that contains one reads the way it was written")

    // MARK: -

    section("The catalog id a stored disk name means, across releases")

    check(CatalogMigration.catalogID(ofDiskNamed: "hd1k_combo-v0-3.5.1.img") == "hd1k_combo",
          "a saved profile names one release's file and means the disk under any of them")
    check(CatalogMigration.catalogID(ofDiskNamed: "hd1k_combo-v0-3.6.0.img") == "hd1k_combo",
          "so the two releases' files answer to the same id - which is what lets a profile "
            + "saved on 3.5.1 resolve its slots on 3.6.0 instead of reporting four failures")
    check(CatalogMigration.catalogID(ofDiskNamed: legacyCombo) == "hd1k_combo",
          "a pre-v0 name resolves too, for a profile written before the migration ran")
    check(CatalogMigration.catalogID(ofDiskNamed: "mine.img") == nil,
          "a user's own disk answers to no catalog id, so it can only ever match itself")
    check(CatalogMigration.catalogID(ofDiskNamed: "my-v0-3.5.1.img") == nil,
          "and neither does one that merely looks versioned")
    check(CatalogMigration.catalogID(ofDiskNamed: "hd1k_msx-v0-3.6.0.img") == nil,
          "a stem published after this build knows nothing about is not guessed at")
    check(CatalogMigration.catalogID(ofDiskNamed: "hd1k_msx-v0-3.6.0.img",
                                     knownStems: CatalogMigration.catalogDiskStems
                                         .union(["hd1k_msx"])) == "hd1k_msx",
          "until the app has seen it published, which is the same observed set "
            + "belongsToAnotherRelease uses")
    check(CatalogMigration.catalogID(ofDiskNamed: "hd1k_combo.img.incoming") == nil,
          "a staging file is not an image")

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

func runEquivalenceTests() {

    section("The one pre-v0 image accepted as equivalent")

    let v0Combo = "0ca4ec60cb8bca71b8f0287c4b634c3126887be483db9b59b41bdff424f89303"
    let priorCombo = "89b8ae1aaa6867dc515c3511b34c4f0c311a77e99ff71066f5a774bef99cde1d"

    check(CatalogMigration.isEquivalentPriorImage(provenance: priorCombo,
                                                  catalogSha256: v0Combo),
          "the v1.4.12 combo is equivalent to the v0 one - same 94 files, byte for byte, "
            + "differing only in the CP/M slack between them")
    check(CatalogMigration.isEquivalentPriorImage(provenance: priorCombo.uppercased(),
                                                  catalogSha256: v0Combo.uppercased()),
          "and the comparison folds case, because nothing guarantees how a hash was stored")

    check(!CatalogMigration.isEquivalentPriorImage(provenance: v0Combo,
                                                  catalogSha256: priorCombo),
          "the relation is one-way: the v0 image is not a stand-in for the older one")
    check(!CatalogMigration.isEquivalentPriorImage(
              provenance: String(repeating: "0", count: 64), catalogSha256: v0Combo),
          "an unrelated hash is not equivalent, which is the whole point - this must not "
            + "become a way to bless a corrupt or truncated image")
    check(!CatalogMigration.isEquivalentPriorImage(provenance: priorCombo,
                                                  catalogSha256: String(repeating: "f", count: 64)),
          "and it is keyed on the catalog hash too, so it cannot leak onto another image")

    check(CatalogMigration.equivalentPriorImage.count == 1,
          "exactly one entry: hd1k_combo is the only one of the twenty whose bytes moved")
}

func runIndexScopeTests() {
    section("Pointing at another catalog, and coming back")

    let defaults = UserDefaults.standard
    let key = CatalogMigration.indexURLOverrideKey
    let saved = defaults.string(forKey: key)
    defer {
        if let saved = saved { defaults.set(saved, forKey: key) }
        else { defaults.removeObject(forKey: key) }
    }

    // The invariant the whole feature rests on. Every key and path this scopes
    // has to come out byte-identical to what a device already holds, or a
    // single visit to a test catalog would strand the user's library behind a
    // name nothing reads afterwards.
    defaults.removeObject(forKey: key)
    check(CatalogMigration.indexScope.isEmpty,
          "the built-in index adds NO suffix - an existing install must find its keys unchanged")
    check(!CatalogMigration.isCustomIndex,
          "and is not reported as custom")
    let stock = CatalogMigration.versionedKey("selectedDisks", romwbwVersion: "3.6.0")
    check(stock == "selectedDisks.v0.3.6.0",
          "which is the key shipped builds already write: \(stock)")

    // An empty or blank setting is "no preference", not "an index called ''".
    defaults.set("   ", forKey: key)
    check(CatalogMigration.indexURL == CatalogMigration.defaultIndexURL,
          "whitespace is not a URL, and falls back to the built-in rather than failing every fetch")
    check(CatalogMigration.versionedKey("selectedDisks", romwbwVersion: "3.6.0") == stock,
          "so it changes no key either")

    defaults.set("https://example.invalid/mine/index-v0.json", forKey: key)
    check(CatalogMigration.isCustomIndex, "a real URL is reported as custom")
    let mine = CatalogMigration.versionedKey("selectedDisks", romwbwVersion: "3.6.0")
    check(mine != stock,
          "and takes a namespace of its own: \(mine)")
    check(mine.hasPrefix(stock + "@"),
          "appended rather than rewritten, so the release scoping underneath is untouched")

    // Two catalogs both publishing "3.6.0" is the case this exists for: same
    // release name, same filenames, different bytes.
    defaults.set("https://example.invalid/other/index-v0.json", forKey: key)
    check(CatalogMigration.versionedKey("selectedDisks", romwbwVersion: "3.6.0") != mine,
          "a DIFFERENT custom index gets a different namespace again - two forks publishing "
            + "3.6.0 must not write over each other")

    defaults.set("https://example.invalid/mine/index-v0.json", forKey: key)
    check(CatalogMigration.versionedKey("selectedDisks", romwbwVersion: "3.6.0") == mine,
          "and the tag is stable, so returning to a catalog finds what was left there")

    defaults.removeObject(forKey: key)
    check(CatalogMigration.versionedKey("selectedDisks", romwbwVersion: "3.6.0") == stock,
          "clearing the setting returns the ORIGINAL key exactly - this is the one that "
            + "decides whether a user gets their library back")

    check(CatalogMigration.fnv1a("a") != CatalogMigration.fnv1a("b"),
          "the tag distinguishes inputs at all")
    check(CatalogMigration.fnv1a(CatalogMigration.defaultIndexURL).count == 8,
          "and is 8 hex characters, short enough to sit in a path")
}

@main
enum CatalogMigrationTestMain {
    static func main() {
        runAllTests()
        runEquivalenceTests()
        runIndexScopeTests()
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
