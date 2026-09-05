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

    /// The RomWBW release this build's bundled ROM and disks are for.
    ///
    /// One constant rather than a lookup because release A changes no URL: the
    /// app still fetches the catalog it always did, and the only thing that
    /// moves is what it calls the files it has already downloaded. When the
    /// version picker arrives this becomes the selected release, and every
    /// function below already takes it as a parameter.
    static let bundledRomWBWVersion = "3.5.1"

    /// The only extension a catalog disk has ever had. Checked rather than
    /// assumed, because `Documents/Disks` holds more than images: the old
    /// `disks_catalog.xml` cache, the v0 caches that replaced it
    /// (`index-v0.json`, `catalog-v0-<ver>.json`), and a crashed download's
    /// `<name>.img.incoming` staging file. None of them may be touched.
    static let diskExtension = "img"

    /// The stems the catalog shipped with this app has ever named.
    ///
    /// These are the twenty disk `id`s in the v0 3.5.1 catalog, which are also
    /// exactly the twenty `<filename>` stems in the `disks.xml` this build is
    /// pinned to. Anything else in `Documents/Disks` belongs to the user.
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

    /// Filenames are compared case-insensitively, the same fold `DiskLedger` and
    /// `deleteCatalogDisks(named:)` use. `Documents` is published to the Files
    /// app on a case-insensitive volume, so a user's `HD1K_COMBO.IMG` and the
    /// catalog's `hd1k_combo.img` are one file on one device and two on another.
    static func fold(_ filename: String) -> String { filename.lowercased() }

    // MARK: - Keys scoped to one RomWBW release

    /// A `UserDefaults` key for a value that is only valid under one RomWBW
    /// release: `"selectedDisks"` becomes `"selectedDisks.v0.3.5.1"`.
    ///
    /// Three values need this and they need it for three different reasons. A
    /// disk slot names a file that only exists under one release. An NVRAM blob
    /// fails RomWBW's own `NVSW_CHECKSUM` under another release - the version
    /// bytes are XORed into the seed - and resets to defaults without saying so.
    /// And the catalog generation decides what gets DELETED, so one shared key
    /// across releases means a user switching 3.5.1 -> 3.6.0 -> 3.5.1 has their
    /// library cleared twice; `generation` is scoped per release upstream for
    /// exactly this reason (romwbw_disks docs/CATALOG_SCHEMA.md §4.3).
    static func versionedKey(_ base: String,
                             romwbwVersion: String = bundledRomWBWVersion) -> String {
        "\(base).\(interface).\(romwbwVersion)"
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
                             romwbwVersion: String = bundledRomWBWVersion) -> String? {
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
                              romwbwVersion: String = bundledRomWBWVersion) -> [String] {
        stored.map { migratedName($0, notMoved: notMoved, romwbwVersion: romwbwVersion) ?? $0 }
    }

    /// Every saved profile's disk slots.
    ///
    /// `romFilename` is deliberately NOT migrated. It names a file in the app
    /// BUNDLE - `availableROMs` is one hardcoded entry, `emu_avw.rom`, and
    /// `loadSelectedResources()` passes it to `loadROM(fromBundle:)` - and the
    /// bundle still ships that exact name. Rewriting it to
    /// `emu_avw-v0-3.5.1.rom` would make `applyProfile` report the ROM
    /// unresolved for every profile the user has, to rename a file that did not
    /// move.
    ///
    /// Round-tripping through `ProfileStore` sorts and de-duplicates, so the
    /// encoded bytes differ even when no name changed. That is correct and it
    /// means "did the migration change anything" cannot be answered by
    /// comparing the stored blob.
    static func migrated(_ store: ProfileStore,
                         notMoved: Set<String> = [],
                         romwbwVersion: String = bundledRomWBWVersion) -> ProfileStore {
        let profiles = store.profiles.map { profile -> EmulatorProfile in
            var updated = profile
            updated.diskFilenames = migratedSlots(profile.diskFilenames,
                                                  notMoved: notMoved,
                                                  romwbwVersion: romwbwVersion)
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
                         romwbwVersion: String = bundledRomWBWVersion) -> DiskLedger {
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
    /// The stem has to be one the catalog has named, so a user's own
    /// `my-v0-3.5.1.img` is never hidden. The cost of that caution is one stray
    /// row: an image published only under a later release - 3.6.0 adds four
    /// stems 3.5.1 does not have - is not in this table, so under 3.5.1 it
    /// shows as a user-added disk under its own name. Harmless, and it says
    /// which release it is for right in the name.
    static func belongsToAnotherRelease(_ filename: String,
                                        romwbwVersion: String = bundledRomWBWVersion) -> Bool {
        let folded = fold(filename)
        guard folded.hasSuffix(".\(diskExtension)") else { return false }
        let stem = String(folded.dropLast(diskExtension.count + 1))

        let marker = "-\(interface)-"
        guard let range = stem.range(of: marker, options: .backwards) else { return false }
        guard catalogDiskStems.contains(String(stem[stem.startIndex..<range.lowerBound])) else {
            return false
        }
        return String(stem[range.upperBound...]) != fold(romwbwVersion)
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
    /// the harmless one.
    ///
    /// Sorted, so a device with two names that fold together renames the same
    /// one on every run. The caller still has to re-check the destination
    /// before each move: the first rename in such a pair CREATES the second's
    /// destination, and this listing was taken before either happened.
    static func renames(in directoryContents: [String],
                        romwbwVersion: String = bundledRomWBWVersion) -> [Rename] {
        let present = Set(directoryContents.map(fold))
        var renames: [Rename] = []
        for name in directoryContents.sorted() {
            guard let new = migratedName(name, romwbwVersion: romwbwVersion),
                  !present.contains(fold(new)) else { continue }
            renames.append(Rename(from: name, to: new))
        }
        return renames
    }
}
