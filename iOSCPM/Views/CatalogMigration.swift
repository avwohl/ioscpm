//
//  CatalogMigration.swift
//  iOSCPM
//
//  What this app remembers about a catalog disk, renamed from `<id>.img` to
//  `<id>-v0-<romwbw version>.img`, once and without deleting anything.
//
//  Pure values, like TerminalDialect, ExportPath, DiskSize, EmulatorProfile and
//  DiskLedger: no UIKit, no FileManager, no UserDefaults. That is the only
//  reason Tests/CatalogMigrationTests.swift can drive it on a machine with no
//  Xcode. The view model owns the keys and the FileManager calls
//  (`migrateStorageToInterfaceV0`); every decision they make is here.
//
//  ## Why the names moved
//
//  romwbw_disks now publishes one catalog per RomWBW release, and the same disk
//  exists under both: `hd1k_combo.img` is `hd1k_combo-v0-3.5.1.img` under 3.5.1
//  and `hd1k_combo-v0-3.6.0.img` under 3.6.0. The release is in the FILENAME so
//  the two can sit in `Documents/Disks` at once, which they have to be able to
//  do - a 3.5.1 disk booted under a 3.6.0 ROM prints
//  `*** WARNING: HBIOS/CBIOS Version Mismatch ***` and is not a substitute for
//  the 3.6.0 one.
//
//  ## Why all four stores move together
//
//  Everything this app remembers about a disk is keyed on its bare filename:
//  the four slots under `selectedDisks`, every saved profile's `diskFilenames`,
//  the `DiskLedger`'s provenance records, and the files in `Documents/Disks`.
//  A migration that gets three of the four right is worse than one that does
//  nothing:
//
//    - `start()` looks a selected disk up in the catalog by an exact,
//      case-sensitive filename match when the file is not present, and REFUSES
//      to boot on a miss. Not a degraded boot - an alert and no emulator.
//    - `saveDownloadedDisks()` writes the running machine's image back over
//      `Documents/Disks/<the slot's filename>` and skips silently when that
//      file does not exist, so a slot naming one thing and a file named another
//      discards the user's CP/M work on every backgrounding, with nothing shown.
//
//  ## The rules, in the order they are applied
//
//  1. `""` is never a filename. It means BOTH "no disk in this slot" and "this
//     slot is bound to a local file the user picked" (`loadLocalDisk`,
//     `createNewDisk`, `restoreLocalDiskBindings` all write it), so mapping it
//     would silently destroy the second.
//  2. A name that already carries `-v0-` is left alone. That is what makes the
//     pass idempotent, and the pass IS re-run: a rename that could not be
//     performed leaves the done flag clear on purpose.
//  3. A stem the shipped catalog has never named is left alone. Users import
//     their own images through Files and `createNewDisk` makes more, and none
//     of those can be re-downloaded from anywhere. `hd1k_infocom.img` is in
//     this class too: it was served until it was dropped as a duplicate of
//     Games, and it is not in the v0 3.5.1 catalog, so renaming it would claim
//     a provenance it does not have.
//  4. Everything else maps to `<stem>-v0-3.5.1.img`, lowercased, which is the
//     name the published catalog uses.
//
//  Nothing here deletes anything, and nothing here can: these functions take
//  values and return values. The only destructive verb in the whole migration
//  is `FileManager.moveItem`, in the view model, and a move is not a deletion.
//

import Foundation

enum CatalogMigration {

    /// The catalog interface these names belong to. Part of every migrated
    /// filename and of every key scoped to a RomWBW release.
    static let interface = "v0"

    // MARK: - Which catalog is in play

    /// The index this build ships with, and the only URL it compiles in.
    ///
    /// Everything else - which releases exist, which ROMs and disks each one
    /// has, where they live and what they hash to - is read out of a document
    /// at run time. That is what lets romwbw_disks publish a new ROM or disk
    /// and have it reach an installed client with no app release.
    ///
    /// AND IT NAMES NO RELEASE TAG. It was
    /// `releases/download/catalog-v0/index-v0.json` until 2026-09-10, which
    /// pinned the tag: adding a RomWBW version was always free, because a
    /// version is an entry INSIDE the index, but romwbw_disks could never
    /// rename that release, move the index, or publish a v1 anywhere a shipped
    /// client would look - and INTERFACE_V0.md's own migration plan was "a v1
    /// lives alongside v0: new release tags, a new index URL", which is
    /// unreachable from a constant naming the old one. So that plan silently
    /// meant "and release Windows, Android, iOS and Linux at once", the exact
    /// coupling this catalog exists to remove.
    ///
    /// `releases/latest/download/` is resolved by GitHub to whichever release
    /// carries the Latest flag, so where the index lives belongs to
    /// romwbw_disks. A v1 ships as index-v1.json beside index-v0.json on that
    /// same release: v0 clients keep reading v0, v1 clients read v1, nobody
    /// rebuilds anything.
    static let defaultIndexURL =
        "https://github.com/avwohl/romwbw_disks/releases/latest/download/index-v0.json"

    /// Where a user-supplied index URL is remembered. Empty or absent means
    /// "use the one this build ships with"; it is deliberately not seeded with
    /// `defaultIndexURL`, so that a default which moves in a later build is
    /// picked up rather than frozen into every existing install.
    static let indexURLOverrideKey = "catalogIndexURL"

    /// The index actually in use, resolved the way `romwbw-get` resolves it so
    /// the two behave the same: an environment variable first, so a test can
    /// point one launch somewhere without touching what the user has stored;
    /// then the stored setting; then the built-in.
    ///
    /// `ROMWBW_INDEX_URL` reaches a simulator run as
    /// `SIMCTL_CHILD_ROMWBW_INDEX_URL`, and an Xcode scheme sets it directly.
    static var indexURL: String {
        if let env = ProcessInfo.processInfo.environment["ROMWBW_INDEX_URL"],
           !env.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return env.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let stored = (UserDefaults.standard.string(forKey: indexURLOverrideKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stored.isEmpty ? defaultIndexURL : stored
    }

    /// Is this app reading somebody else's catalog?
    static var isCustomIndex: Bool { indexURL != defaultIndexURL }

    /// A short, stable, filesystem- and key-safe tag for the index in use, and
    /// **empty for the built-in one**.
    ///
    /// Empty is the whole point: every key and every path this scopes must come
    /// out byte-identical to what a device already has, or pointing at a test
    /// catalog once and back again would strand a user's library behind a name
    /// nothing reads. So the default index adds nothing at all, and only a
    /// custom one gets a suffix.
    ///
    /// FNV-1a rather than SHA-256 because this needs to be short, stable and
    /// dependency-free - `Tests/run_tests.sh` compiles this file on its own
    /// against the macOS SDK - and it is a namespace tag, not a security
    /// boundary. Two indexes colliding would share a namespace; they would
    /// still be told apart by every sha256 the catalogs themselves carry.
    static var indexScope: String {
        isCustomIndex ? "@" + fnv1a(indexURL) : ""
    }

    static func fnv1a(_ s: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Array(s.utf8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%08x", UInt32(truncatingIfNeeded: hash ^ (hash >> 32)))
    }

    /// The RomWBW release every PRE-v0 name belongs to.
    ///
    /// A `hd1k_combo.img` on a device is a 3.5.1 image: it is what
    /// `avwohl/ioscpm` served, under a catalog that named exactly one release
    /// and never said which. So this is the release the migration renames those
    /// files INTO, and it is a fact about the past that can never change - not a
    /// default, not a preference, and (since 2026-09-08) nothing to do with a
    /// bundled ROM, because this app no longer has one.
    ///
    /// It was called `bundledRomWBWVersion` while a bundled `emu_avw.rom`
    /// happened to declare the same release. That coincidence made it look like
    /// a property of the build, which would have made it something to update
    /// when the build moved - and updating it would silently rename a user's
    /// 3.5.1 disks into another release's names.
    ///
    /// Every function below still takes it as a parameter, defaulted here, so
    /// the release actually in play is what a runtime caller passes.
    static let legacyRomWBWVersion = "3.5.1"

    /// The only extension a catalog disk has ever had. Checked rather than
    /// assumed, because `Documents/Disks` holds more than images: the old
    /// `disks_catalog.xml` cache, the v0 caches that replaced it
    /// (`index-v0.json`, `catalog-v0-<ver>.json`), and a crashed download's
    /// `<name>.img.incoming` staging file. None of them may be touched.
    static let diskExtension = "img"

    /// The stems the catalog shipped with this app has ever named.
    ///
    /// These are the twenty disk `id`s in the v0 3.5.1 catalog, which are also
    /// exactly the twenty `<filename>` stems in the `disks.xml` that every build
    /// before the migration fetched. This build fetches no XML and is pinned to
    /// no tag; the set is a frozen record of what a PRE-v0 device can be holding,
    /// which is what the migration has to recognise. Anything else in
    /// `Documents/Disks` belongs to the user.
    ///
    /// It is deliberately NOT the answer to "is this a catalog disk" at runtime -
    /// it cannot be, since it can only ever list what was published when this
    /// build was made. `knownCatalogStems` in the view model is that answer.
    ///
    /// `hd1k_infocom` is deliberately absent although it was served for a while:
    /// it was removed from the catalog as a duplicate of Games, and there is no
    /// `hd1k_infocom-v0-3.5.1.img` to rename it to. Leaving it alone keeps it
    /// selectable as the user-added disk it has effectively become.
    static let catalogDiskStems: Set<String> = [
        "hd1k_aztecc",
        "hd1k_bascomp",
        "hd1k_bp",
        "hd1k_combo",
        "hd1k_cowgol",
        "hd1k_cpm22",
        "hd1k_cpm3",
        "hd1k_fortran",
        "hd1k_games",
        "hd1k_hitechc",
        "hd1k_msxroms1",
        "hd1k_msxroms2",
        "hd1k_nzcom",
        "hd1k_qpm",
        "hd1k_tpascal",
        "hd1k_ws4",
        "hd1k_z3plus",
        "hd1k_z80asm",
        "hd1k_zpm3",
        "hd1k_zsdos",
    ]

    /// Filenames are compared case-insensitively, the same fold `DiskLedger`
    /// uses. `Documents` is published to the Files app on a case-insensitive
    /// volume, so a user's `HD1K_COMBO.IMG` and the catalog's `hd1k_combo.img`
    /// are one file on one device and two on another.

    /// Pre-v0 images that are equivalent to the v0 image of the same name, keyed
    /// by the v0 catalog's `sha256` and holding the pre-v0 catalog's.
    ///
    /// There is exactly one, and it exists because two toolchains built the same
    /// disk. `hd1k_combo` is the only one of the twenty images whose bytes differ
    /// between ioscpm `v1.4.12` and `catalog-v0-3.5.1.json`, and the difference is
    /// not in anything a guest can reach: both are 51,380,224 bytes, slices 1-5 are
    /// byte-identical, slice 0's directory lists the same 94 files, and all 94
    /// extract byte-identical - `r8.com` and `w8.com` included, at 1,792 bytes
    /// each. The 2,342 bytes that differ are CP/M slack between those files:
    /// unallocated blocks still holding a deleted file's content, plus a little
    /// `0xE5` directory padding. Measured, not assumed - `romwbw_disks`
    /// `docs/FINDINGS.md` section 10 carries the byte ranges.
    ///
    /// So a migrated device holds an image whose every file already matches the
    /// catalog, under a hash that does not. Refreshing it would spend 49 MB of
    /// somebody's data - their cellular data, for the ones who have no choice - to
    /// replace 2,342 bytes of garbage with different garbage.
    ///
    /// This is deliberately keyed on PROVENANCE, which is what makes it safe. A
    /// v0 download records the v0 catalog's hash, so no downloaded file can ever
    /// carry the pre-v0 one: only the migration, which copies the old catalog's
    /// hash across when it renames, can put that value here. It therefore cannot
    /// bless a corrupt, truncated or unrelated file, and it stops applying the
    /// moment a device fetches the canonical image, because the refresh overwrites
    /// the provenance that made it apply.
    static let equivalentPriorImage: [String: String] = [
        // hd1k_combo-v0-3.5.1.img
        "0ca4ec60cb8bca71b8f0287c4b634c3126887be483db9b59b41bdff424f89303":
            "89b8ae1aaa6867dc515c3511b34c4f0c311a77e99ff71066f5a774bef99cde1d"
    ]

    /// True when `provenance` names an image already known to be equivalent to the
    /// image `catalogSha256` names. Both are compared lowercased, as stored.
    static func isEquivalentPriorImage(provenance: String, catalogSha256: String) -> Bool {
        equivalentPriorImage[fold(catalogSha256)] == fold(provenance)
    }

    static func fold(_ filename: String) -> String { filename.lowercased() }

    // MARK: - Keys scoped to one RomWBW release

    /// A `UserDefaults` key for a value that is only valid under one RomWBW
    /// release: `"selectedDisks"` becomes `"selectedDisks.v0.3.5.1"`.
    ///
    /// Three values need this and they need it for three different reasons. A
    /// disk slot names a file that only exists under one release. An NVRAM blob
    /// fails RomWBW's own `NVSW_CHECKSUM` under another release - the version
    /// bytes are XORed into the seed - and resets to defaults without saying so.
    /// And the catalog generation is a fact about one release's artifacts, so a
    /// shared key would have a fetch of 3.6.0's catalog overwrite the value
    /// 3.5.1 is measured against; `generation` is scoped per release upstream
    /// for exactly this reason (romwbw_disks docs/CATALOG_SCHEMA.md §4.3). It
    /// decided what got DELETED until build 66 removed the wipe, which is why
    /// getting it wrong used to clear a library on a 3.5.1 -> 3.6.0 -> 3.5.1
    /// round trip; it deletes nothing now, and the scoping still has to be right.
    static func versionedKey(_ base: String,
                             romwbwVersion: String = legacyRomWBWVersion) -> String {
        // `indexScope` is EMPTY for the built-in index, so this is byte for byte
        // the key every existing install already has. A custom index gets its
        // own suffix, which is what keeps a test catalog's "3.6.0" from writing
        // over the real one's: the two publish different bytes under the same
        // release name and the same filenames, so sharing a key would hand the
        // user's library to whichever was fetched last.
        "\(base).\(interface).\(romwbwVersion)\(indexScope)"
    }

    // MARK: - One name

    /// The v0 filename for a stored name, or nil to leave the name exactly as
    /// it is.
    ///
    /// nil is the answer for `""`, for a name that is already versioned, for
    /// anything that is not `<stem>.img`, and for every stem the catalog has
    /// never named. Returning the input unchanged instead would lose that
    /// distinction, and the callers need it: a name that does not migrate must
    /// not be counted as migrated when the pass reports what it did.
    static func migratedName(_ filename: String,
                             romwbwVersion: String = legacyRomWBWVersion) -> String? {
        // "" is not a filename. See rule 1 in the file comment - this is the
        // check that keeps a slot bound to a local file bound to it.
        guard !filename.isEmpty else { return nil }

        // Split at the LAST dot, so `hd1k_combo.img.incoming` has extension
        // "incoming" and is left alone rather than being treated as an image.
        guard let dot = filename.lastIndex(of: "."), dot != filename.startIndex else { return nil }
        let stem = fold(String(filename[filename.startIndex..<dot]))
        let ext = fold(String(filename[filename.index(after: dot)...]))
        guard ext == diskExtension else { return nil }

        // Idempotence, stated rather than inferred. It also falls out of the
        // membership test below - `hd1k_combo-v0-3.5.1` is not a catalog stem -
        // but that is a coincidence of today's table, and re-running this pass
        // is a designed-for case, not an accident.
        guard !stem.contains("-\(interface)-") else { return nil }

        guard catalogDiskStems.contains(stem) else { return nil }
        return "\(stem)-\(interface)-\(romwbwVersion).\(diskExtension)"
    }

    /// `migratedName`, except that a name whose file could not be renamed is
    /// left alone everywhere.
    ///
    /// `notMoved` holds folded LEGACY names. The file and every reference to it
    /// have to stay consistent: a slot rewritten to a name whose file is still
    /// under the old one resolves to nothing, and `restoreDiskSelections()`
    /// writes that nothing back over the user's configuration.
    private static func migratedName(_ filename: String,
                                     notMoved: Set<String>,
                                     romwbwVersion: String) -> String? {
        guard !notMoved.contains(fold(filename)) else { return nil }
        return migratedName(filename, romwbwVersion: romwbwVersion)
    }

    // MARK: - The four stores

    /// The four disk slots as `selectedDisks` stores them: bare filenames, with
    /// `""` for a slot that is empty or bound to a local file.
    ///
    /// Length and order are preserved exactly. A slot the migration has nothing
    /// to say about comes back byte-identical, which is the whole contract:
    /// this is the value `restoreDiskSelections()` resolves against the catalog,
    /// and anything it cannot resolve it blanks.
    static func migratedSlots(_ stored: [String],
                              notMoved: Set<String> = [],
                              romwbwVersion: String = legacyRomWBWVersion) -> [String] {
        stored.map { migratedName($0, notMoved: notMoved, romwbwVersion: romwbwVersion) ?? $0 }
    }

    /// What `persistSelectedDisks()` should write into a release's
    /// `selectedDisks` key - or nil for "write nothing at all".
    ///
    /// Two decisions, and the first one is the one that loses data.
    ///
    /// `awaitingCatalog` says the four slots in `selected` are the teardown's
    /// blanks and not a machine anybody configured. A release switch empties
    /// them before fetching the new release's catalog, and when that fetch
    /// fails nothing refills them - so the next slot the user touches would
    /// persist three blanks plus their one edit over a key that may already
    /// hold the selection they made the last time they were on this release.
    /// Worse on a release the device has never visited, where the key is
    /// absent: writing `["", "", "", ""]` makes `restoreDiskSelections()`'s
    /// `hasSavedSelections` true for good, and the first-launch disks
    /// (`RomWBWCatalogDocument.defaultDiskIDs`) never reach slots 1-3 on that
    /// release again. Nothing is lost by
    /// declining to write: while the catalog is empty the picker offers only
    /// "None", and a slot bound to a local file is remembered in the bookmarks
    /// key by `saveLocalDiskBindings()`, not here. A caller with a deliberate
    /// selection to record - `applyProfile` - passes false and is written.
    ///
    /// `remembered` is what the key held before `restoreDiskSelections()` ran,
    /// and it is passed only from there. A slot whose stored name the catalog
    /// cannot resolve right now is nil in memory - the restore assigns the
    /// lookup's optional result - and writing that nil straight back is what
    /// permanently erased a configured disk the first time a catalog stopped
    /// naming it. A remembered name costs nothing to keep: the slot is still
    /// empty in the UI and `start()` still skips it, so it cannot brick the
    /// Play button, and it comes back on its own the moment the catalog names
    /// it again.
    ///
    /// A slot bound to a local file is excluded by `localBound`.
    /// `restoreLocalDiskBindings()` runs inside the same bracket and
    /// deliberately writes `filename: ""` over whatever catalog name that slot
    /// had; putting the name back would fight with it every launch.
    static func slotNamesToPersist(selected: [String],
                                   remembered: [String]?,
                                   localBound: [Bool],
                                   awaitingCatalog: Bool) -> [String]? {
        guard !awaitingCatalog else { return nil }
        var filenames = selected
        if let remembered = remembered {
            for i in filenames.indices {
                guard filenames[i].isEmpty,
                      i < remembered.count,
                      i < localBound.count, !localBound[i] else { continue }
                filenames[i] = remembered[i]
            }
        }
        return filenames
    }

    /// Every saved profile's disk slots.
    ///
    /// `romFilename` is deliberately NOT migrated, and it stopped needing to be
    /// migrated for a better reason than the one written here before. A profile
    /// saved by an older build names `emu_avw.rom`, the file in the app bundle;
    /// the ROM now comes from the catalog under `emu_avw-v0-<release>.rom`, and
    /// which release that is depends on which one the user is on when they
    /// apply the profile - so there is no single name to rewrite it to.
    /// `applyProfile` matches it by catalog `id` instead (`ROMOption.answersTo`),
    /// which resolves `emu_avw.rom` to whatever `emu_avw` is under the release
    /// in play. Rewriting the stored string would fix one release and break the
    /// other.
    ///
    /// Round-tripping through `ProfileStore` sorts and de-duplicates, so the
    /// encoded bytes differ even when no name changed. That is correct and it
    /// means "did the migration change anything" cannot be answered by
    /// comparing the stored blob.
    static func migrated(_ store: ProfileStore,
                         notMoved: Set<String> = [],
                         romwbwVersion: String = legacyRomWBWVersion) -> ProfileStore {
        let profiles = store.profiles.map { profile -> EmulatorProfile in
            var updated = profile
            updated.diskFilenames = migratedSlots(profile.diskFilenames,
                                                  notMoved: notMoved,
                                                  romwbwVersion: romwbwVersion)
            // Stamp the release these slots are now named for, where the profile
            // does not already say. A profile written before the picker existed
            // carries no release, and without one `applyProfile` can only report
            // an unresolved slot as a bare filename - so the profiles that most
            // need "saved under RomWBW 3.5.1" are exactly the ones that would
            // never get it. Never overwritten: a profile that names a release
            // was saved by a build that knew which one.
            if updated.romwbwVersion == nil { updated.romwbwVersion = romwbwVersion }
            return updated
        }
        return ProfileStore(profiles: profiles, lastUsedName: store.lastUsedName)
    }

    /// The provenance records, rekeyed.
    ///
    /// Carrying the records across is the point of the exercise, not an
    /// optimisation. `DiskRecord.installedCatalogSha256` says which PUBLISHED
    /// image the bytes on disk came from, and that fact survives a rename; it
    /// cannot be recomputed, because hashing the file answers a different
    /// question. Dropping the ledger and letting `measureDisks` rebuild it
    /// would re-hash ~210 MB and then adopt provenance only for the files that
    /// still match the catalog - which is precisely the disks the user has
    /// never opened. Every disk they actually use would be left at
    /// `.unknownProvenance(matchesCatalog: false)` and acquire a standing
    /// "any files you saved in it are lost" warning.
    ///
    /// Two legacy names can fold onto one v0 name (`hd1k_bp.img` and
    /// `HD1K_BP.IMG` on a case-sensitive volume). Sources are walked in sorted
    /// order and an occupied destination is never overwritten, so the outcome
    /// is the same on every device and no record is dropped: the loser keeps
    /// its old key, which still matches the file that kept its old name.
    static func migrated(_ ledger: DiskLedger,
                         notMoved: Set<String> = [],
                         romwbwVersion: String = legacyRomWBWVersion) -> DiskLedger {
        var result: [String: DiskRecord] = [:]
        var moving: [(from: String, to: String, record: DiskRecord)] = []

        // The records that stay put first, so a record already filed under a v0
        // name holds that name against anything migrating onto it.
        for name in ledger.records.keys.sorted() {
            guard let record = ledger.records[name] else { continue }
            if let new = migratedName(name, notMoved: notMoved, romwbwVersion: romwbwVersion) {
                moving.append((from: name, to: new, record: record))
            } else {
                result[fold(name)] = record
            }
        }
        for move in moving {
            let destination = fold(move.to)
            if result[destination] == nil {
                result[destination] = move.record
            } else {
                result[fold(move.from)] = move.record
            }
        }
        return DiskLedger(records: result)
    }

    /// Is this file a catalog image belonging to a DIFFERENT RomWBW release?
    ///
    /// `hd1k_combo-v0-3.5.1.img` is one of these while 3.6.0 is in play. It is
    /// not a user's import and it is not selectable material: booting a 3.5.1
    /// disk under a 3.6.0 ROM is the mismatch the whole naming scheme exists to
    /// keep apart, and offering it in the picker beside this release's own is
    /// how someone ends up doing it by accident. The file is untouched - it
    /// belongs to the release it names and comes back the moment that release
    /// is selected again.
    ///
    /// The stem has to be one a catalog has named, so a user's own
    /// `my-v0-3.5.1.img` is never hidden.
    ///
    /// `knownStems` is that test, and it defaults to `catalogDiskStems` only so
    /// the pure-value tests have a fixture. **A runtime caller must pass the
    /// stems it has actually seen published**, because `catalogDiskStems` is a
    /// frozen record of the twenty PRE-v0 names and cannot answer for anything
    /// published since. Five ids exist under 3.6.0 and not 3.5.1 -
    /// `hd1k_cobol`, `hd1k_dos65`, `hd1k_infocom`, `hd1k_msx`, `hd1k_wp`, all
    /// of them bootable - so against the frozen table a downloaded
    /// `hd1k_msx-v0-3.6.0.img` reads as a user-added disk under 3.5.1 and is
    /// offered as a system disk for a 3.5.1 machine. That is precisely the
    /// pairing the versioned filenames exist to keep apart, and every disk
    /// romwbw_disks adds from here on would arrive with the same flaw - which
    /// would make "add a disk with no client release" true only in the
    /// paperwork.
    static func belongsToAnotherRelease(_ filename: String,
                                        romwbwVersion: String = legacyRomWBWVersion,
                                        knownStems: Set<String> = catalogDiskStems) -> Bool {
        guard let (stem, release) = versionedParts(of: filename) else { return false }
        guard knownStems.contains(stem) else { return false }
        return release != fold(romwbwVersion)
    }

    /// The release a file's NAME claims, when that is not the release in play -
    /// nil when the name claims none, or claims this one.
    ///
    /// `belongsToAnotherRelease` answers the PICKER's question, "may this app
    /// offer the file", and gates on `knownStems` so that a user's own
    /// `my-v0-3.5.1.img` is never hidden. This answers a different question
    /// about a file the user reached for by hand out of Files, and deliberately
    /// drops that gate. Nothing here hides or refuses anything: the file is
    /// mounted whatever it is called, and someone deliberately booting another
    /// release's image keeps working. So the two sides are not symmetric - a
    /// warning may fire where a hide must not, and the only cost of speaking up
    /// about `my-v0-3.5.1.img` is a sentence about a pairing the user may well
    /// have meant. The cost of staying quiet is
    /// *** WARNING: HBIOS/CBIOS Version Mismatch *** in the middle of a boot
    /// with nothing having said why.
    ///
    /// That asymmetry is why the caller's wording says the file NAMES a release
    /// rather than belongs to one. The filename is the whole evidence: a disk
    /// image carries no release inside it that this app can read, and one the
    /// user made is named by the user.
    static func releaseNamedByLocalFile(_ filename: String,
                                        romwbwVersion: String) -> String? {
        guard let (_, release) = versionedParts(of: filename),
              release != fold(romwbwVersion) else { return nil }
        return release
    }

    /// The catalog id a stored disk name refers to, across releases.
    ///
    /// `hd1k_combo-v0-3.5.1.img` and the pre-v0 `hd1k_combo.img` both answer
    /// "hd1k_combo", so a saved profile written under one release resolves under
    /// another - which it has to, because a profile records a machine and not a
    /// RomWBW release, and the release is in every catalog filename now.
    ///
    /// nil for a name no catalog published, so a user's own `mine.img` matches
    /// only itself. That is the whole safety property: a profile naming a user's
    /// disk must not silently resolve to a catalog disk with a similar name.
    static func catalogID(ofDiskNamed filename: String,
                          knownStems: Set<String> = catalogDiskStems) -> String? {
        if let parts = versionedParts(of: filename) {
            return knownStems.contains(parts.stem) ? parts.stem : nil
        }
        // A pre-v0 name, from a profile written before the migration ran or
        // deferred. Only the twenty names that catalog ever had.
        let folded = fold(filename)
        guard folded.hasSuffix(".\(diskExtension)") else { return nil }
        let stem = String(folded.dropLast(diskExtension.count + 1))
        return catalogDiskStems.contains(stem) ? stem : nil
    }

    /// Split `hd1k_msx-v0-3.6.0.img` into ("hd1k_msx", "3.6.0"), both folded.
    ///
    /// nil for anything that is not a `.img` carrying the interface marker -
    /// a pre-v0 name, a `.incoming` staging file, a user's own `mine.img`.
    /// Split at the LAST marker so a user's `weird-v0-thing-v0-3.5.1.img` is
    /// read the way the writer of that name would read it.
    static func versionedParts(of filename: String) -> (stem: String, release: String)? {
        let folded = fold(filename)
        guard folded.hasSuffix(".\(diskExtension)") else { return nil }
        let stem = String(folded.dropLast(diskExtension.count + 1))
        let marker = "-\(interface)-"
        guard let range = stem.range(of: marker, options: .backwards) else { return nil }
        return (String(stem[stem.startIndex..<range.lowerBound]),
                String(stem[range.upperBound...]))
    }

    // MARK: - The files

    /// One file to rename in `Documents/Disks`.
    struct Rename: Equatable {
        let from: String
        let to: String
    }

    /// What to rename, given the names currently in `Documents/Disks`.
    ///
    /// A file whose destination is already present is not listed at all: the
    /// pass keeps the v0 copy and deletes neither, so the old one stays where
    /// it is and reappears in the picker as a user-added disk. That is the
    /// unavoidable outcome of a reinstall over an old `Documents`, and it is
    /// harmless only if the STORED names stay behind with the file.
    /// `blockedByExistingDestination(in:)` is the other half of that answer,
    /// and a caller that asks this function without asking that one rewrites a
    /// slot, a profile and a ledger record onto a name this pass never created
    /// - a DIFFERENT image in the ordinary case, where the v0 file is the one
    /// the user downloaded, and no file at all where the blocker is a directory
    /// or a case variant.
    ///
    /// Sorted, so a device with two names that fold together renames the same
    /// one on every run. The caller still has to re-check the destination
    /// before each move: the first rename in such a pair CREATES the second's
    /// destination, and this listing was taken before either happened.
    static func renames(in directoryContents: [String],
                        romwbwVersion: String = legacyRomWBWVersion) -> [Rename] {
        let present = Set(directoryContents.map(fold))
        var renames: [Rename] = []
        for name in directoryContents.sorted() {
            guard let new = migratedName(name, romwbwVersion: romwbwVersion),
                  !present.contains(fold(new)) else { continue }
            renames.append(Rename(from: name, to: new))
        }
        return renames
    }

    /// The folded legacy names that `renames(in:)` leaves out because their v0
    /// name is already taken, and which therefore must not be rewritten in any
    /// of the four stores.
    ///
    /// This and `renames(in:)` partition the names `migratedName` recognises:
    /// one says which files move, the other says which ones are staying under
    /// the name they have. Both have to be asked, because the stored names
    /// follow the FILE and not the plan - a slot rewritten to
    /// `hd1k_combo-v0-3.5.1.img` while this device's `hd1k_combo.img` is still
    /// called that names the OTHER image, the one already sitting there, and
    /// `saveDownloadedDisks()` then writes the running machine back over it.
    ///
    /// Unlike a rename that threw, this is permanent: the pass deletes neither
    /// copy, so every later launch finds the same collision. The caller must
    /// keep it apart from the transient deferral for that reason - see
    /// `migrateStorageToInterfaceV0`, where holding the done flag back for this
    /// would re-run the whole pass on every launch for the life of the install.
    ///
    /// Folded, because that is what `migratedName(_:notMoved:romwbwVersion:)`
    /// compares against.
    static func blockedByExistingDestination(
        in directoryContents: [String],
        romwbwVersion: String = legacyRomWBWVersion
    ) -> Set<String> {
        let present = Set(directoryContents.map(fold))
        var blocked: Set<String> = []
        for name in directoryContents {
            guard let new = migratedName(name, romwbwVersion: romwbwVersion),
                  present.contains(fold(new)) else { continue }
            blocked.insert(fold(name))
        }
        return blocked
    }
}
