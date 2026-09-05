/*
 * EmulatorViewModel.swift - View model for RomWBW emulator
 */

import SwiftUI
import Combine
import AVFoundation
import CryptoKit
import Network

// One ROM the app can load: the one in its bundle, or one the release publishes.
struct ROMOption: Identifiable, Hashable, Equatable {
    /// The filename is the identity, exactly as it is for DiskOption below.
    ///
    /// It was `let id = UUID()`, which the synthesized == and hash took in, so
    /// two ROMOptions naming the same file compared UNEQUAL. That was
    /// survivable only because availableROMs was a `let` holding one element
    /// built once: the picker at ContentView tags its rows with
    /// `rom as ROMOption?` and SwiftUI matches the tag against selectedROM by
    /// ==, so a value rebuilt from a catalog would match no tag and the picker
    /// would go blank on every refresh. `availableROMs` IS rebuilt from a
    /// catalog now - on every fetch and on every release switch - so that trap
    /// is no longer theoretical, and identity by filename is what defuses it.
    var id: String { filename }
    let name: String
    let filename: String

    /// The catalog's own id - "emu_avw" - which is the same under every RomWBW
    /// release while the filename carries the release. It is what the CHOICE is
    /// remembered as: someone who picked EMU RCZ80 under 3.5.1 means EMU RCZ80
    /// under 3.6.0 too. Keying a remembered ROM on the id rather than on a
    /// parsed filename is what romwbw_disks docs/CATALOG_SCHEMA.md §6.1 asks
    /// for.
    let romID: String

    /// The catalog entry these bytes have to match, or nil for the ROM in the
    /// app bundle - which no catalog publishes and which is verified by being
    /// what this build shipped.
    let catalogEntry: CatalogROM?

    /// The RomWBW release this ROM is for, where it can be known without
    /// reading the image: the catalog's `romwbw_version` for a published ROM,
    /// and what the bundled image's own HCB says for the bundled one.
    let romwbwRelease: String?

    /// Does this option answer to a ROM name something wrote down earlier - a
    /// saved profile's `romFilename`, or the remembered choice?
    func answersTo(_ storedName: String) -> Bool {
        CatalogROM.refers(storedName, toID: romID, filename: filename)
    }

    // Equatable and Hashable on the filename, for the reason above.
    static func == (lhs: ROMOption, rhs: ROMOption) -> Bool {
        lhs.filename == rhs.filename
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(filename)
    }
}

extension ROMOption {

    /// A ROM the release publishes, as the picker's row.
    init(catalog entry: CatalogROM, release: String?) {
        self.init(name: entry.displayName,
                  filename: entry.filename,
                  romID: entry.id,
                  catalogEntry: entry,
                  romwbwRelease: release)
    }
}

// Disk option with name and filename
struct DiskOption: Identifiable, Hashable, Equatable {
    var id: String { filename.isEmpty ? "_none_" : filename }  // Use filename as stable ID
    let name: String
    let filename: String
    var isDownloaded: Bool = false  // true if available locally

    // Equatable based on filename (the unique identifier)
    static func == (lhs: DiskOption, rhs: DiskOption) -> Bool {
        lhs.filename == rhs.filename
    }

    // Hashable based on filename
    func hash(into hasher: inout Hasher) {
        hasher.combine(filename)
    }
}

// Downloadable disk image catalog entry
struct DownloadableDisk: Identifiable, Codable {
    /// Still the filename, deliberately, even though the catalog now carries a
    /// stable `id` of its own (`catalogID` below).
    ///
    /// This id is what ContentView's DiskDownloadRow is built on, and that row
    /// then reads `downloadStates[disk.filename]`, `refreshPlan(for:)`,
    /// `cancelDownload(_:)` and `deleteDownloadedDisk(_:)` - four keyed lookups
    /// into stores that know nothing about catalog ids. A row whose identity
    /// and whose lookups disagree shows another disk's progress.
    var id: String { filename }
    /// The catalog's own id: "hd1k_combo", the same under every RomWBW release
    /// while the filename carries the release. Not a lookup key anywhere in
    /// this app - it is what makes a disk recognisable ACROSS releases, and
    /// what the schema says to key on rather than array position or a parsed
    /// filename.
    let catalogID: String
    let filename: String
    let name: String
    let description: String
    let url: String
    let sizeBytes: Int64
    let license: String  // "GPLv3", "Free", "User-provided", etc.
    let sha256: String?  // Optional SHA256 hash for integrity verification
    let defaultSlot: Int?  // If set, use this disk as default in this slot (0-3) on first launch

    var sizeDescription: String {
        if sizeBytes >= 1_000_000 {
            return String(format: "%.1f MB", Double(sizeBytes) / 1_000_000)
        } else {
            return String(format: "%.0f KB", Double(sizeBytes) / 1_000)
        }
    }

    /// Short SHA256 prefix for display (first 8 chars)
    var sha256Short: String? {
        guard let hash = sha256, hash.count >= 8 else { return nil }
        return String(hash.prefix(8))
    }
}

// Download state for a disk
enum DownloadState: Equatable {
    case notDownloaded
    case downloading(progress: Double)
    case downloaded
    case error(String)
}

/// Why there is no catalog on screen, and how far the two-hop fetch got.
///
/// This replaces a bare `catalogError: String?`. One string had nowhere to say
/// "the index came back and this release's catalog did not", and those want
/// different answers: the first means this device cannot reach GitHub, the
/// second means the release list is fine and one asset behind it is not - which
/// is a publishing problem upstream that no amount of reconnecting fixes.
///
/// `servedFromCache` is the other half of the same point. A stale release list
/// with a good catalog is not a failure the user has to act on today; it is a
/// note. Reporting it with the same weight as "nothing loaded" is how a warning
/// stops being read.
struct CatalogFailure: Equatable {
    enum Stage: Equatable {
        /// index-v0.json, the one URL compiled into this app.
        case index
        /// That release's catalog-v0-<ver>.json.
        case catalog(romwbwVersion: String)
        /// The index was read and this build's emulator core can run none of
        /// the releases in it. Not a network problem and not recoverable by
        /// retrying: it means the core is older (or newer) than everything
        /// romwbw_disks publishes.
        case noSupportedRelease
    }

    let stage: Stage
    /// The underlying reason, in the words of whatever produced it.
    let detail: String
    /// True when a cached document is on screen anyway.
    let servedFromCache: Bool

    /// One line, naming which hop failed.
    var summary: String {
        switch stage {
        case .index:
            return servedFromCache
                ? "Using the saved list of RomWBW releases - the current one could not be fetched."
                : "Could not fetch the list of RomWBW releases."
        case .catalog(let version):
            return servedFromCache
                ? "Using the saved RomWBW \(version) disk catalog - the current one could not be fetched."
                : "The RomWBW release list loaded, but the \(version) disk catalog did not."
        case .noSupportedRelease:
            return "This app's emulator cannot run any of the published RomWBW releases."
        }
    }

    /// What the settings screen shows: the hop, then the reason.
    var displayText: String { detail.isEmpty ? summary : "\(summary) \(detail)" }
}

class EmulatorViewModel: NSObject, ObservableObject {
    @Published var statusText: String = "Ready"
    @Published var isRunning: Bool = false
    @Published var terminalShouldFocus: Bool = false

    @Published var showingDiskPicker: Bool = false
    @Published var showingDiskExporter: Bool = false
    @Published var showingError: Bool = false
    @Published var errorMessage: String = ""
    /// The alert's heading. "Error" for the overwhelming majority of callers,
    /// which really are errors; the catalog-invalidation notice is not one, and
    /// heading "your disks were cleared" with the word Error tells the user
    /// something went wrong when the app did exactly what it meant to.
    @Published var errorTitle: String = "Error"
    @Published var showingManifestWriteWarning: Bool = false
    @Published var isDownloading: Bool = false
    @Published var downloadingDiskName: String = ""
    @Published var downloadingProgress: Double = 0

    /// The ROM for the release in play cannot be used, and the machine is not
    /// starting. Its own alert rather than showError's, because this one offers
    /// a way out - switching back to the release this app carries a ROM for -
    /// and an OK button on its own would leave the user with a Play button that
    /// refuses and no idea what to do about it.
    @Published var showingROMProblem: Bool = false
    @Published private(set) var romProblemMessage: String = ""

    /// ROM files already fetched a second time because the copy on this device
    /// did not match the catalog. A bad copy is re-downloaded ONCE; a second
    /// failure is reported rather than retried for ever, since the fault is
    /// then in the catalog or the server and no amount of data will fix it.
    /// Cleared again by `fetchROM` the moment a copy verifies, so the budget is
    /// one re-fetch per FAULT rather than one per launch. In memory only: a
    /// relaunch is a fair second chance too, and the download path never
    /// installs unverified bytes, so the worst a wrong entry can cost is one
    /// more 512 KB transfer.
    private var romRefetched: Set<String> = []

    // Host file transfer (R8/W8 utilities)
    @Published var showingHostFileImporter: Bool = false
    @Published var showingHostFileExporter: Bool = false
    @Published var hostFileExportFilename: String = "download.bin"
    @Published var hostFileExportDocument: DiskImageDocument?
    @Published var hostFileTempURL: URL?
    @Published var showingHostFileMoveExporter: Bool = false
    @Published var showingHostFileSavePrompt: Bool = false  // Alert asking user to save
    private var pendingHostFileData: Data?  // Data waiting to be saved
    // Toggles the "Import File…" picker that stages an arbitrary host file into
    // the Imports folder (so a later R8 can read it). Not tied to any guest wait.
    @Published var showingImportToInbox: Bool = false

    // MARK: The ROM
    //
    // The last thing in this app that was pinned to one RomWBW release. Disks,
    // the catalog URL and the release choice all come from the published index
    // already; the ROM did not, so RomWBW 3.6.0 could be published stable and
    // default and still not reach a user without a store release of this app -
    // which is the cost romwbw_disks exists to remove.
    //
    // The rules, in full, and all three clients follow the same ones:
    //
    //   1. The ROM for a release is the entry in that release's catalog
    //      `roms[]` flagged `default: true`, or the first entry when none is -
    //      never roms[0] by position, and never "the one called emu_avw".
    //   2. It lives beside the disks, under its catalog filename, which already
    //      carries the release: emu_avw-v0-3.6.0.rom. Two releases' ROMs
    //      coexist exactly as their disks do.
    //   3. Its size AND its sha256 are checked before it is used, EVERY time,
    //      not only when it is downloaded.
    //   4. The bundled ROM stays, and is what a first offline launch boots. It
    //      is not a substitute for another release's ROM.
    //   5. It lands BEFORE the emulator starts, or the machine does not start.
    //      Falling back to the bundled ROM would pair one release's disks with
    //      another release's HBIOS - the mismatch this whole thing removes -
    //      and would do it invisibly.

    /// Which ROM the user picked. The picker binds straight to this.
    @Published var selectedROM: ROMOption? {
        didSet {
            // The catalog id, not the filename: see selectedROMIDKey.
            if let rom = selectedROM {
                UserDefaults.standard.set(rom.romID, forKey: Self.selectedROMIDKey)
            }
        }
    }

    /// Where the ROM choice is remembered.
    ///
    /// The catalog `id`, under one key for the interface rather than one per
    /// release. "emu_rcz80" means the same ROM under every release, while
    /// `emu_rcz80-v0-3.5.1.rom` names one release's file - and choosing between
    /// the two published ROMs is a preference about which machine the user
    /// wants, which should survive a release switch the way the terminal
    /// settings do. It is also what the schema asks for: key on `id`.
    ///
    /// The old "selectedROM" key held a bundle filename and is deliberately
    /// left in place, unread, exactly as "catalogCacheTag" is. It costs
    /// nothing, a user who downgrades this app finds their settings as they
    /// left them, and nothing is lost by not reading it: it can only say
    /// "emu_avw.rom", which resolves to the ROM the catalog flags default
    /// anyway.
    private static let selectedROMIDKey = "selectedROMID.\(CatalogMigration.interface)"

    /// The ROMs this app can load for the release in play.
    ///
    /// Computed from the catalog now, not a one-element `let`. Each row is a
    /// ROM the selected release publishes; where the bundled image IS one of
    /// them - byte for byte, checked by hash in `resolveROM()` - that row costs
    /// no download at all.
    ///
    /// With no catalog in hand - or with one that publishes no `roms[]` at
    /// all, which §6.1 says to survive rather than assume away - the whole list
    /// is the bundled ROM, and only when the release in play is the one it
    /// declares. That is the first offline launch: no network, no index, and a
    /// machine that still boots. Offering it under any OTHER release would be
    /// the silent substitution this change exists to remove, so the list is
    /// empty instead and `start()` says why.
    var availableROMs: [ROMOption] {
        if let document = catalogDocument, !document.romEntries.isEmpty {
            let release = document.romwbwVersion ?? romwbwVersion
            return document.romEntries.map { ROMOption(catalog: $0, release: release) }
        }
        guard let bundled = Self.bundledROMRelease, bundled == romwbwVersion,
              Self.bundledROMURL != nil else { return [] }
        return [Self.bundledROMOption]
    }

    // Disk selection for slots 0-3 (OS slots) and data drives
    private var isRestoringSelections = false  // Flag to prevent didSet during restore
    @Published var selectedDisks: [DiskOption?] = Array(repeating: nil, count: 4) {
        didSet {
            // isRestoringSelections is what the flag above was declared for and
            // was never actually consulted by: restore and profile-apply set
            // the four slots one at a time, so each of them rewrote this key
            // three times over with a half-applied selection. Both bracket
            // themselves and persist once at the end instead.
            guard !isRestoringSelections else { return }
            persistSelectedDisks()
        }
    }

    /// Which disks are in which slots, for THIS RomWBW release.
    ///
    /// A 3.5.1 disk is not a 3.6.0 disk - the filenames differ and the guest
    /// prints `*** WARNING: HBIOS/CBIOS Version Mismatch ***` if they are
    /// crossed - so the selection is stored per release. The unsuffixed key is
    /// what every build before the v0 catalog wrote; the migration copies its
    /// value once and then leaves it alone, so a user who downgrades the app
    /// still finds their slots.
    ///
    /// Computed from the release in play rather than fixed at load time: the
    /// release picker moves it, and a key captured once would go on reading
    /// 3.5.1's slots after the user switched to 3.6.0 - which is not a stale
    /// display but a wrong write, since the very next persist would put 3.6.0
    /// names under the 3.5.1 key.
    var selectedDisksKey: String {
        CatalogMigration.versionedKey("selectedDisks", romwbwVersion: romwbwVersion)
    }

    /// Write the four slots back.
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
    /// A slot bound to a local file is excluded. `restoreLocalDiskBindings()`
    /// runs inside the same bracket and deliberately writes `filename: ""` over
    /// whatever catalog name that slot had; putting the name back would fight
    /// with it every launch.
    private func persistSelectedDisks(remembering remembered: [String]? = nil) {
        var filenames = selectedDisks.map { $0?.filename ?? "" }
        if let remembered = remembered {
            for i in filenames.indices {
                guard filenames[i].isEmpty,
                      i < remembered.count,
                      i < localDiskURLs.count, localDiskURLs[i] == nil else { continue }
                filenames[i] = remembered[i]
            }
        }
        UserDefaults.standard.set(filenames, forKey: selectedDisksKey)
    }

    @Published var availableDisks: [DiskOption] = [
        DiskOption(name: "None", filename: ""),
    ]

    // MARK: The catalog, and the one URL this app compiles in
    //
    // There is no release tag any more. `releaseTag = "v1.4.12"` and the two
    // URLs built out of it are gone: a disk fix reached users only through an
    // edit, a rebuild and a shipped release, and v1.4.5's broken R8 - which
    // handed an unfiltered host basename to F_DELETE, so importing a file whose
    // name held ? or * silently erased every matching CP/M file first - went on
    // being served for two days after the fixed image was published, because
    // publishing an asset is not the same as shipping it.
    //
    // What replaces it is two hops, and only the first is compiled in:
    //
    //   1. index-v0.json, below. Lists every RomWBW release romwbw_disks
    //      publishes, each with an absolute catalog_url and that catalog's
    //      catalog_sha256/catalog_size.
    //   2. the selected release's catalog, verified against those two before it
    //      is parsed. It carries its own base_url, and an asset URL is
    //      base_url + filename - no tag interpolation anywhere, and no "/"
    //      inserted by this app (the document's base_url ends in one).
    //
    // The index tag holds that one small file and nothing else, so re-cutting
    // it costs one upload of a few kilobytes. That is what makes a floating
    // entry point safe here when HelpView's releases/latest is safe for the
    // same reason: the thing that moves is tiny, and the things clients cache
    // never move.
    //
    // The OLD tags stay live regardless. Every build already in service is
    // hardwired to https://github.com/avwohl/ioscpm/releases/download/v1.4.12/
    // and GitHub release asset URLs cannot be redirected. Migrating this app
    // does not free v1.4.5 or v1.4.12; only the last user uninstalling does.
    private static let indexURL =
        "https://github.com/avwohl/romwbw_disks/releases/download/catalog-v0/index-v0.json"

    /// Which RomWBW release the cached catalog was fetched under used to be a
    /// UserDefaults stamp, because the parser rebuilt every URL from the
    /// CURRENT releaseTag and a cache from another pin paired the wrong hashes
    /// with the right URLs. It cannot happen now: the cache holds the whole
    /// document, base_url included, so a cached catalog is self-consistent by
    /// construction, and the release is in the cache FILENAME rather than in a
    /// key that can drift from it.
    ///
    /// The old "catalogCacheTag" key is deliberately left in place, unread. It
    /// costs nothing, and a user who downgrades this app should find their
    /// settings as they left them.
    ///
    /// Always called with an explicit release, never with an implicit "the
    /// current one": the release switch reads and writes caches on both sides
    /// of the move, and a cache written under the wrong name is a 3.6.0 catalog
    /// that a 3.5.1 launch would read as its own.
    private func catalogCacheURL(for version: String) -> URL {
        downloadsDirectory
            .appendingPathComponent("catalog-\(CatalogMigration.interface)-\(version).json")
    }

    /// The release list, cached so a first launch with no network still knows
    /// which releases exist rather than offering only the one in play.
    private var indexCacheURL: URL {
        downloadsDirectory.appendingPathComponent("index-\(CatalogMigration.interface).json")
    }

    /// The catalog generation last seen for THIS RomWBW release, and the only
    /// thing that may delete a downloaded image.  Per release because deletion
    /// is per release; see checkCatalogGenerationAndInvalidate.
    ///
    /// Not the old unsuffixed "catalogVersion" key, which held the XML's
    /// `version` attribute - "13" against a v0 generation of 1. That key is
    /// orphaned rather than carried forward, so the first v0 fetch on any
    /// device finds this one empty and takes the first-run branch.
    ///
    /// Takes the release explicitly, like `catalogCacheURL(for:)` and for the
    /// same reason: this key gates a DELETION, and reading `romwbwVersion` from
    /// inside would file one release's generation under another's the moment a
    /// fetch outlives the picker.
    private func catalogGenerationKey(for version: String) -> String {
        CatalogMigration.versionedKey("catalogGeneration", romwbwVersion: version)
    }

    @Published var diskCatalog: [DownloadableDisk] = []
    @Published var catalogLoading: Bool = false

    /// Why there is no catalog, and which hop failed. Nil when all is well.
    @Published var catalogFailure: CatalogFailure?

    /// The whole decoded catalog for the release in play, kept because the disk
    /// list is not all of it: `roms[]` is what says which ROM this release
    /// publishes, which is now what the app loads rather than only what it
    /// warns about.
    ///
    /// `@Published` although it is private: `availableROMs` is computed from
    /// it, so a catalog arriving has to redraw the ROM picker. Everything else
    /// this fetch assigns is published too, so the redraw would happen anyway -
    /// which is exactly why it is stated here instead of being relied upon.
    @Published private var catalogDocument: RomWBWCatalogDocument?

    // MARK: The RomWBW release in play
    //
    // Every RomWBW release is its own machine. Its disks have their own
    // filenames (hd1k_combo-v0-3.5.1.img is not hd1k_combo-v0-3.6.0.img), its
    // NVRAM blob will not validate under another release's ROM - NVSW_CHECKSUM
    // XORs the version bytes into its seed, so it resets to defaults with no
    // error - and a 3.5.1 disk booted under a 3.6.0 ROM prints
    // *** WARNING: HBIOS/CBIOS Version Mismatch ***.
    //
    // So the release is a first-class selection, and everything whose validity
    // depends on it is stored per release. Switching releases DELETES NOTHING:
    // 3.5.1 -> 3.6.0 -> 3.5.1 comes back to exactly the slots, boot string and
    // downloaded images it left.

    /// The releases the picker offers: what the index publishes, filtered to
    /// what this build's emulator core says it can run.
    ///
    /// Seeded with the release in play so the picker always has a row matching
    /// its selection - an unmatched selection renders blank, and on a first
    /// offline launch the index never arrives at all.
    @Published private(set) var romwbwVersions: [RomWBWIndexEntry] = []

    /// Which release is in play. The picker binds straight to this.
    @Published var romwbwVersion: String = EmulatorViewModel.initialRomWBWVersion() {
        didSet {
            // Swift does not re-enter an observer for an assignment made inside
            // it, so the revert below is safe; the flag is for the OTHER way in
            // - adoptRomWBWVersion(_:refetch:), which assigns from outside and
            // would otherwise have this run the switch a second time.
            guard !isSwitchingRomWBWVersion, oldValue != romwbwVersion else { return }

            // Not while a machine is running off the old release's disks. The
            // switch empties the slots, and saveDownloadedDisks() writes the
            // guest's live image back to the file the SLOT names: with the
            // slots emptied under a running emulator, the periodic flush and
            // the one in stop() would both find nothing to write to and discard
            // the user's work without a word.
            if isRunning {
                romwbwVersion = oldValue
                showError("Stop the emulator before changing the RomWBW release. "
                          + "The disks in the drives belong to \(oldValue).")
                return
            }

            applyRomWBWVersionSwitch(from: oldValue, refetch: true)
        }
    }

    /// Guards the didSet above against running twice for one move.
    private var isSwitchingRomWBWVersion = false

    /// Where the release choice is remembered. Scoped by interface but NOT by
    /// release - it names the release, so it cannot be per release.
    private static let romwbwVersionKey =
        "selectedRomWBWVersion.\(CatalogMigration.interface)"

    /// The ROM the app bundle ships, and the release it declares.
    ///
    /// Read out of the image rather than asserted: there is no compile-time pin
    /// left to read anywhere in this tree - the core takes the RomWBW version
    /// from whichever ROM it loads - so the only honest answer comes from the
    /// four HCB bytes at 0x103-0x106 of the file itself. nil when the bundled
    /// ROM is missing or carries no HCB, which is a broken build rather than a
    /// user-visible condition; the fallback is the release the storage
    /// migration was written for.
    static let bundledROMFilename = "emu_avw.rom"
    static let bundledROMRelease: String? =
        RomWBWEmulator.romWBWRelease(ofBundledROM: bundledROMFilename)

    /// The bundled ROM's file, or nil when this build was assembled without it.
    /// Named with the type rather than bare, as `bundledROMFacts` below is: a
    /// closure is a different lexical context from the property initializers
    /// above it, and spelling the two the same way is one less thing for the
    /// first Mac build of this file to argue about.
    static let bundledROMURL: URL? = {
        let name = (EmulatorViewModel.bundledROMFilename as NSString).deletingPathExtension
        let ext = (EmulatorViewModel.bundledROMFilename as NSString).pathExtension
        return Bundle.main.url(forResource: name, withExtension: ext)
    }()

    /// Its size and SHA-256, measured once.
    ///
    /// Measured rather than declared, for the same reason `bundledROMRelease`
    /// is read out of the image: it is what lets the bundled file STAND IN for
    /// a catalog ROM instead of merely resembling one. The v0 3.5.1 catalog's
    /// emu_avw entry names 524,288 bytes hashing to c7abc580…, and the file in
    /// this bundle is those exact bytes - so a first launch on 3.5.1 downloads
    /// no ROM at all, and the claim that it need not is CHECKED rather than
    /// asserted. Bundle a differently-built image one day and the hash simply
    /// stops matching: the release's ROM is then fetched, which is right,
    /// rather than quietly substituted, which is the bug.
    ///
    /// Mapped, and lazy like every `static let`, so the 512 KB is read the
    /// first time a ROM is resolved and not at launch.
    static let bundledROMFacts: (size: Int64, sha256: String)? = {
        guard let url = EmulatorViewModel.bundledROMURL,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return (size: Int64(data.count), sha256: EmulatorViewModel.sha256Hex(data))
    }()

    /// The bundled ROM as a picker row.
    ///
    /// Only ever offered when no catalog has been read, so it is the offline
    /// first launch and nothing else; where a catalog IS in hand the bundle
    /// gets no row of its own but stands in for the entry whose bytes it
    /// already is. Its `romID` is its own stem, which is also the catalog id of
    /// the ROM it is a copy of - that is what makes a remembered "emu_avw"
    /// resolve to the same ROM either way.
    static let bundledROMOption = ROMOption(
        name: "EMU AVW",
        filename: bundledROMFilename,
        romID: (bundledROMFilename as NSString).deletingPathExtension,
        catalogEntry: nil,
        romwbwRelease: bundledROMRelease)

    /// The release to start on when the user has never chosen one.
    ///
    /// Runs as `romwbwVersion`'s stored-property initializer, which Swift
    /// evaluates before `profileStore`'s and therefore before the storage
    /// migration. That is only safe because the key it reads is a new one that
    /// no migration touches: anything this needed from a migrated key would
    /// have to move, not be read from here.
    private static func initialRomWBWVersion() -> String {
        if let stored = UserDefaults.standard.string(forKey: romwbwVersionKey),
           !stored.isEmpty {
            return stored
        }
        return bundledROMRelease ?? CatalogMigration.bundledRomWBWVersion
    }

    // MARK: Disk freshness
    //
    // Which published image each installed file came from, and what may be done
    // about one the catalog has moved on from. The reasoning is all in
    // DiskLedger.swift, including why this is decided from provenance and not by
    // hashing the file against the catalog - that comparison would classify every
    // disk a user has saved work into as stale and overwrite it.

    /// Per-filename provenance and cached measurements. Keyed by lowercased name.
    private var diskLedger = DiskLedger()
    private static let diskLedgerKey = "diskLedger"

    /// What the UI should offer for each catalog filename, lowercased.
    ///
    /// A separate dictionary rather than a new `DownloadState` case, deliberately:
    /// `refreshAvailableDisks()` rewrites every entry of `downloadStates` on every
    /// catalog fetch, and `waitForDownloadCompletion` treats any state it does not
    /// recognise as "still going" and re-polls for ever - so a freshness value
    /// parked there would both be erased and hang the Play path.
    @Published private(set) var diskRefreshPlans: [String: DiskRefreshPlan] = [:]

    /// What the path monitor last reported. Starts at `.unknown`, which fails
    /// closed - a cold launch must not race the first callback into starting a
    /// 49 MB download on somebody's cellular data.
    @Published private(set) var networkCondition: NetworkCondition = .unknown

    private let pathMonitor = NWPathMonitor()
    private var pathMonitorStarted = false

    /// Files whose hash could not be computed. Without this a nil from
    /// `sha256OfFile` leaves the verdict at `.needsMeasurement` for ever and
    /// `reassessDiskFreshness()` schedules the same 49 MB file on every pass.
    private var measurementFailed: Set<String> = []

    /// How many times each file has been hashed this session.
    ///
    /// The backstop on the measure/reassess cycle. A measurement is stored
    /// against the size and modification time it was taken for, so if the file
    /// moves underneath the pass the stored one no longer applies and the verdict
    /// returns to `.needsMeasurement` - which schedules it again. That is the
    /// right behaviour once and a 49 MB read in a loop if the file keeps moving,
    /// which is exactly what `saveDownloadedDisks()` does to a mounted disk every
    /// twenty seconds. `isMounted` already keeps those out; this catches whatever
    /// else can churn a file, including the user writing to it through Files.
    private var measurementAttempts: [String: Int] = [:]
    private static let maxMeasurementAttempts = 3
    /// True while a measurement pass is in flight, so overlapping catalog
    /// fetches do not start a second one over the same files.
    private var measuringDisks = false

    // Download state tracking
    @Published var downloadStates: [String: DownloadState] = [:]
    private var downloadTasks: [String: URLSessionDownloadTask] = [:]

    // Dedicated URLSession with no caching for disk downloads (avoids redirect caching issues)
    private lazy var downloadSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    /// The session an UNATTENDED refresh uses, and the only one that may run
    /// without a tap.  The two flags are the guarantee rather than the path
    /// monitor: they are applied by the OS when the connection is established,
    /// so a path that flips to cellular between the decision and the transfer
    /// still cannot spend the user's data.
    ///
    /// `waitsForConnectivity` is deliberately left at its default of false.
    /// Setting it looks like the polite thing and is the exact opposite: it
    /// converts the prompt failure below into a wait bounded only by
    /// `timeoutIntervalForResource`, which defaults to seven days, with no
    /// callback on the completion-handler API.  A background session would be
    /// worse again - those ignore the flag and always wait.
    ///
    /// With it false, a cellular-only path fails immediately and specifically:
    /// NSURLErrorNotConnectedToInternet carrying
    /// `NSURLErrorNetworkUnavailableReasonKey`.  `refreshDeferral` turns that
    /// into "waiting for Wi-Fi" rather than the lie the generic handler tells
    /// ("The Internet connection appears to be offline") on perfectly good LTE.
    private lazy var autoRefreshSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        config.allowsExpensiveNetworkAccess = false
        config.allowsConstrainedNetworkAccess = false
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    // Disk slot labels
    let diskLabels = ["Disk 0 (OS)", "Disk 1 (OS)", "Disk 2 (OS)", "Disk 3 (Data)"]

    // Boot string - reflects the emulator's NVRAM setting
    // Changed by SYSCONF in ROM or by UI, synced to UserDefaults
    @Published var bootString: String = "" {
        didSet {
            // Save to UserDefaults whenever it changes (from UI or SYSCONF
            // sync), under the key for the release in play. Clearing autoboot
            // clears THIS release's, and leaves the other release's alone.
            UserDefaults.standard.set(bootString, forKey: nvramKey)
        }
    }

    // NVRAM persistence key, per RomWBW release.
    //
    // RomWBW's NVSW_CHECKSUM XORs the running release's version bytes into its
    // seed, so a blob saved under 3.5.1 fails validation under a 3.6.0 ROM and
    // silently resets to defaults - the user's autoboot setting disappears with
    // no error anywhere. One key per release is the only shape that survives a
    // machine that can load either. The unsuffixed key is what every earlier
    // build wrote; the v0 migration copies its value across once and leaves it
    // in place.
    //
    // Computed from the release in play for the same reason
    // `selectedDisksKey` is: the picker moves it, and every reader and writer
    // has to move with it. The readers and writers are `restoreBootString()`
    // (from init and from the release switch) and bootString's didSet, reached
    // from applyProfile, clearAutoboot and syncNvramFromEmulator.
    private var nvramKey: String {
        CatalogMigration.versionedKey("emulatorNvram", romwbwVersion: romwbwVersion)
    }

    // Manifest disk write warning setting (defaults to true = warnings enabled)
    private static let warnManifestWritesKey = "warnManifestWrites"

    var warnManifestWrites: Bool {
        get {
            // Default to true if not set
            if UserDefaults.standard.object(forKey: Self.warnManifestWritesKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: Self.warnManifestWritesKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.warnManifestWritesKey)
            // Apply to all disk units immediately
            applyWarningSuppression()
        }
    }

    /// Apply warning suppression setting to all disk units
    private func applyWarningSuppression() {
        let suppressed = !warnManifestWrites
        for unit in 0..<4 {
            emulator?.setDiskWarningSuppressed(Int32(unit), suppressed: suppressed)
        }
    }

    // Host file transfer (R8/W8) always uses the sandbox Documents/Imports and
    // Documents/Exports folders, so batch/scripted transfers never trigger a
    // picker. Reaching arbitrary host locations is a separate user action:
    // "Import File…" stages a picked file into Imports; "Open Exports Folder"
    // surfaces W8 output for sharing.

    // MARK: - Configurable Keyboard Mapping

    private static let keyProfileKey = "keyProfile"
    private static let keyBindingsKey = "keyBindings"

    // Effective per-key termcap-style bindings (SpecialKey.rawValue -> string).
    private var currentKeyBindings: [SpecialKey: String] = KeyProfile.wordStar.bindings ?? [:]

    /// Selected profile. Choosing a preset resets the bindings to that preset;
    /// editing an individual key switches the profile to `.custom`.
    @Published var keyProfile: KeyProfile = .wordStar {
        didSet {
            UserDefaults.standard.set(keyProfile.rawValue, forKey: Self.keyProfileKey)
            if let preset = keyProfile.bindings {
                currentKeyBindings = preset
                persistKeyBindings()
            }
        }
    }

    var keyMap: KeyMap { KeyMap(bindings: currentKeyBindings) }

    func keyBinding(for key: SpecialKey) -> String { currentKeyBindings[key] ?? "" }

    func setKeyBinding(_ key: SpecialKey, to value: String) {
        currentKeyBindings[key] = value
        if keyProfile != .custom {
            keyProfile = .custom  // didSet won't clobber currentKeyBindings (custom has nil bindings)
        }
        persistKeyBindings()
        objectWillChange.send()
    }

    private func persistKeyBindings() {
        var dict: [String: String] = [:]
        for (k, v) in currentKeyBindings { dict[k.rawValue] = v }
        UserDefaults.standard.set(dict, forKey: Self.keyBindingsKey)
    }

    /// Restore the saved keyboard mapping (call once during init).
    private func loadKeyMapping() {
        let profRaw = UserDefaults.standard.string(forKey: Self.keyProfileKey) ?? KeyProfile.wordStar.rawValue
        let prof = KeyProfile(rawValue: profRaw) ?? .wordStar
        if let preset = prof.bindings {
            currentKeyBindings = preset
        } else if let stored = UserDefaults.standard.dictionary(forKey: Self.keyBindingsKey) as? [String: String] {
            var m: [SpecialKey: String] = [:]
            for (k, v) in stored { if let sk = SpecialKey(rawValue: k) { m[sk] = v } }
            currentKeyBindings = m
        }
        // Assign without persisting a redundant write via the observed setter is
        // fine here; the values already match what was stored.
        keyProfile = prof
    }

    /// Whether the on-screen navigation/function key row is drawn under the
    /// terminal.
    ///
    /// Default on, and on for every device: it is not only a phone feature. On
    /// Mac Catalyst the row is the ONLY way to send Ctrl+arrow at all, because
    /// WindowServer takes those four for Mission Control before the app is
    /// offered the press - so the four bindings exist there and can never fire
    /// from the keyboard.
    static let showKeyRowKey = "showKeyRow"
    @Published var showKeyRow: Bool =
        UserDefaults.standard.object(forKey: EmulatorViewModel.showKeyRowKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(showKeyRow, forKey: Self.showKeyRowKey) }
    }

    /// Send a remapped navigation key's byte sequence to the guest.
    func sendSpecialKey(_ key: SpecialKey) {
        scrollToLiveBottom()
        for b in keyMap.bytes(for: key) {
            emulator?.sendCharacter(unichar(b))
        }
    }

    // MARK: - Configuration Profiles

    /// Every saved profile, and which one was last applied.
    ///
    /// The whole store is one JSON value under one key. Profiles are small and
    /// there are a handful of them, everything else this app remembers is in
    /// UserDefaults, and a file in Documents would appear in Files alongside
    /// the user's disk images, which is the last place a settings blob belongs.
    static let profileStoreKey = "emulatorProfiles"

    @Published private(set) var profileStore: ProfileStore =
        ProfileStore.decoded(from: EmulatorViewModel.profileDataAfterV0Migration())

    private func persistProfiles() {
        if let data = profileStore.encoded() {
            UserDefaults.standard.set(data, forKey: Self.profileStoreKey)
        }
    }

    // MARK: - Interface v0 storage migration

    /// Set once the rename pass below has finished with nothing left to do.
    ///
    /// It exists to keep a directory listing off every launch, not to make the
    /// pass safe: the pass is idempotent by construction, because a name that
    /// already carries `-v0-` maps to nothing. See CatalogMigration.
    private static let v0MigrationDoneKey = "migratedToInterfaceV0"

    /// Run the storage migration, then hand back the profile bytes it left.
    ///
    /// This is spelled as the initializer expression for `profileStore` rather
    /// than as a call at the top of `init()` because Swift runs stored-property
    /// initializers BEFORE the body of any initializer. A `migrate()` first in
    /// `init()` would migrate the ledger (read at the bottom of `init()`) and
    /// the disk slots (read later still, from `restoreDiskSelections()`)
    /// correctly, and would already have lost the race for every profile - and
    /// it would look like it had worked, because the two halves that are easy
    /// to check are the two that were migrated. Making the migration produce
    /// the bytes is the only spelling that cannot be reordered by accident.
    private static func profileDataAfterV0Migration() -> Data? {
        migrateStorageToInterfaceV0()
        return UserDefaults.standard.data(forKey: profileStoreKey)
    }

    /// Rename what this app remembers about a catalog disk, from `<id>.img` to
    /// `<id>-v0-3.5.1.img`, across all four stores and the files themselves.
    ///
    /// Runs before anything reads any of them, which is not a convention but a
    /// requirement: `restoreDiskSelections()` resolves each stored name against
    /// the catalog and writes nil back for a name it cannot find, so one fetch
    /// after an unmigrated upgrade erases the user's slot configuration. The
    /// ordering is enforced by where this is called from, above.
    ///
    /// What it will not do, in order of how much they cost:
    ///
    ///   - It never deletes. Not a file, not a key, not a ledger record. A name
    ///     the catalog has never used belongs to the user and is left exactly
    ///     as it is, under the name they gave it.
    ///   - It renames rather than copies. `DiskLedger.measurementApplies`
    ///     compares a stored measurement against the file's CURRENT size and
    ///     modification time, and `moveItem` preserves both; a copy-then-delete
    ///     changes mtime, invalidates every record, and makes the app re-hash
    ///     ~210 MB whose answer it already had.
    ///   - It carries provenance across rather than re-deriving it.
    ///     `installedCatalogSha256` records which published image these bytes
    ///     came from, and that survives a rename. It cannot be recomputed: see
    ///     DiskLedger.swift for why hashing the file answers a different
    ///     question, and `recordInstall`'s comment for why a verified download
    ///     is the only place provenance may be written.
    private static func migrateStorageToInterfaceV0() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: v0MigrationDoneKey) else { return }

        let fm = FileManager.default
        let directory = disksDirectoryURL

        // The files first. A stored name may only be rewritten once the file it
        // names has actually moved - a slot pointing at a name with no file
        // behind it resolves to nothing, and the restore writes that nothing
        // back over the user's configuration.
        var notMoved: Set<String> = []
        var renamed = 0

        // A directory that is not there yet is not a failure - a device that
        // has downloaded nothing has nothing to rename, and the keys below name
        // nothing that is on disk either. A directory that IS there and cannot
        // be listed is a different answer: "unknown", not "empty". Swallowing
        // that into an empty listing would rename no file, rewrite every stored
        // name anyway, and then set the done flag over it - the half-applied
        // state where start() refuses to boot and saveDownloadedDisks() throws
        // the guest's work away in silence. So it defers the whole pass with
        // the flag left clear, and the next launch tries again.
        var contents: [String] = []
        if fm.fileExists(atPath: directory.path) {
            do {
                contents = try fm.contentsOfDirectory(atPath: directory.path)
            } catch {
                print("[Migration] Could not list \(directory.path):"
                      + " \(error.localizedDescription) - deferred to the next launch")
                return
            }
        }

        for rename in CatalogMigration.renames(in: contents) {
            let source = directory.appendingPathComponent(rename.from)
            let destination = directory.appendingPathComponent(rename.to)
            // `moveItem` THROWS when the destination exists, and this pass may
            // not delete either copy, so the destination is checked first and
            // the old file is left where it is. Re-checked here rather than
            // trusted from `renames(in:)`, because two names differing only in
            // case map onto one v0 name and the first rename creates the
            // second's destination.
            guard !fm.fileExists(atPath: destination.path) else { continue }
            do {
                try fm.moveItem(at: source, to: destination)
                renamed += 1
            } catch {
                // Leave every reference to this one alone as well, so the file
                // and the names that point at it stay consistent. The usual
                // cause is transient: Documents is protected until the device
                // has been unlocked once, and the app can be launched in the
                // background before that.
                notMoved.insert(CatalogMigration.fold(rename.from))
                print("[Migration] Could not rename '\(rename.from)': \(error.localizedDescription)")
            }
        }

        // The four slots. Prefer the versioned key once it exists: a pass that
        // could not move a file leaves the done flag clear and runs again next
        // launch, by which time the user may have changed a slot, and copying
        // the legacy value over it again would put the older choice back.
        //
        // The target key is the BUNDLED release's, not the one the release
        // picker has selected. Everything this pass touches was written by a
        // build that had no picker and one pinned catalog, so it can only be
        // 3.5.1 data; filing it under 3.6.0 because that is where the user
        // happens to be would claim disks for a release they were never built
        // for. This runs before any instance exists, which is what makes that
        // hard to get wrong: there is no romwbwVersion here to reach for.
        let migratedSlotsKey = CatalogMigration.versionedKey("selectedDisks")
        if let stored = defaults.stringArray(forKey: migratedSlotsKey)
            ?? defaults.stringArray(forKey: "selectedDisks") {
            defaults.set(CatalogMigration.migratedSlots(stored, notMoved: notMoved),
                         forKey: migratedSlotsKey)
        }

        // The saved profiles, in place under their own key: a profile is not
        // release-specific, it names disks by filename and the filenames now
        // carry the release. Note that decoding sorts and de-duplicates, so the
        // stored bytes change even when no name did.
        if let data = defaults.data(forKey: profileStoreKey) {
            let store = CatalogMigration.migrated(ProfileStore.decoded(from: data),
                                                  notMoved: notMoved)
            if let encoded = store.encoded() {
                defaults.set(encoded, forKey: profileStoreKey)
            }
        }

        // The ledger, likewise in place and for the same reason. Only when
        // there is one: `deserialized(nil)` is an empty ledger, and writing
        // that would put an empty record set where there had been no key.
        if let stored = defaults.string(forKey: diskLedgerKey),
           let serialized = CatalogMigration.migrated(DiskLedger.deserialized(stored),
                                                      notMoved: notMoved).serialized() {
            defaults.set(serialized, forKey: diskLedgerKey)
        }

        // The NVRAM blob, which holds no filename at all - this is a key move,
        // not a rename. Same reasoning as the slots: into the bundled release's
        // key, because a boot string saved before there was a picker was saved
        // against the bundled ROM. The legacy key is left in place
        // deliberately.
        let migratedNvramKey = CatalogMigration.versionedKey("emulatorNvram")
        if defaults.object(forKey: migratedNvramKey) == nil,
           let legacy = defaults.string(forKey: "emulatorNvram") {
            defaults.set(legacy, forKey: migratedNvramKey)
        }

        // A file that could not be moved is worth another attempt on the next
        // launch rather than a name frozen half-migrated for ever. The pass is
        // idempotent and costs one directory listing, so re-running it is
        // cheaper than the state it avoids.
        if notMoved.isEmpty {
            defaults.set(true, forKey: v0MigrationDoneKey)
        }
        if renamed > 0 || !notMoved.isEmpty {
            print("[Migration] interface v0: renamed \(renamed) disk image(s), "
                  + "\(notMoved.count) deferred to the next launch")
        }
    }

    /// The machine as it stands right now, under `name`.
    ///
    /// A slot bound to a local file is recorded as empty. A security-scoped
    /// bookmark is a token issued to this installation, not a name, so a
    /// profile cannot honestly carry one; see EmulatorProfile for the argument.
    func currentProfile(named name: String) -> EmulatorProfile {
        var bindings: [String: String] = [:]
        for (key, value) in currentKeyBindings { bindings[key.rawValue] = value }
        return EmulatorProfile(
            name: name,
            romFilename: selectedROM?.filename ?? "",
            diskFilenames: selectedDisks.map { $0?.filename ?? "" },
            bootString: bootString,
            keyProfileName: keyProfile.rawValue,
            keyBindings: bindings,
            scrollbackCapacity: scrollbackCapacity,
            bellEnabled: bellEnabled,
            warnManifestWrites: warnManifestWrites,
            showKeyRow: showKeyRow,
            newDiskSizeBytes: newDiskSize.bytes)
    }

    /// Save the machine as it stands, under a name not already taken.
    @discardableResult
    func saveCurrentProfile(named name: String) -> String {
        let unique = profileStore.uniqueName(basedOn: name)
        profileStore.save(currentProfile(named: unique))
        profileStore.markUsed(unique)
        persistProfiles()
        return unique
    }

    /// Overwrite an existing profile with the machine as it stands.
    func updateProfile(named name: String) {
        guard profileStore.profile(named: name) != nil else { return }
        profileStore.save(currentProfile(named: name))
        profileStore.markUsed(name)
        persistProfiles()
    }

    func deleteProfile(named name: String) {
        profileStore.delete(named: name)
        persistProfiles()
    }

    @discardableResult
    func renameProfile(_ old: String, to proposed: String) -> String? {
        let result = profileStore.rename(old, to: proposed)
        persistProfiles()
        return result
    }

    /// Put the machine into the state a profile describes.
    ///
    /// Best-effort per item, and it says so: a disk the catalog no longer
    /// carries, or a ROM that is not in the bundle, leaves that one slot alone
    /// rather than failing the whole apply. What is reported back is what
    /// actually could not be honoured.
    ///
    /// The four disk slots are set inside the isRestoringSelections bracket for
    /// the reason the restore path uses it: each assignment persists, so
    /// without it the defaults key is rewritten three times with a half-applied
    /// selection - and if the app were killed in between, a machine that is
    /// neither the old profile nor the new one is what comes back.
    @discardableResult
    func applyProfile(_ profile: EmulatorProfile) -> [String] {
        var unresolved: [String] = []

        if !profile.romFilename.isEmpty {
            // By filename first, then by catalog id. A profile saved before the
            // ROM came from the catalog carries "emu_avw.rom", and one saved
            // under another release carries that release's filename; both mean
            // "the emu_avw ROM", which every release publishes. Matching on the
            // exact filename alone would report the ROM unresolved for every
            // profile a user already has.
            if let rom = availableROMs.first(where: { $0.answersTo(profile.romFilename) }) {
                selectedROM = rom
            } else {
                unresolved.append("ROM \(profile.romFilename)")
            }
        }

        isRestoringSelections = true
        for (index, filename) in profile.diskFilenames.enumerated() where index < 4 {
            if filename.isEmpty {
                selectedDisks[index] = nil
            } else if let disk = availableDisks.first(where: { $0.filename == filename }) {
                selectedDisks[index] = disk
                // A catalog disk replaces whatever local file was bound here;
                // leaving the bookmark would have the slot claim two sources.
                localDiskURLs[index] = nil
            } else {
                unresolved.append("disk \(index): \(filename)")
            }
        }
        isRestoringSelections = false
        persistSelectedDisks()
        saveLocalDiskBindings()

        bootString = profile.bootString

        // The key map: the profile first, then the custom bindings, because
        // setting the profile to a preset replaces the bindings with that
        // preset's and would otherwise undo them.
        if let prof = KeyProfile(rawValue: profile.keyProfileName) {
            keyProfile = prof
        }
        if profile.keyProfileName == KeyProfile.custom.rawValue {
            var restored: [SpecialKey: String] = [:]
            for (key, value) in profile.keyBindings {
                if let sk = SpecialKey(rawValue: key) { restored[sk] = value }
            }
            currentKeyBindings = restored
            persistKeyBindings()
            objectWillChange.send()
        }

        scrollbackCapacity = profile.scrollbackCapacity
        bellEnabled = profile.bellEnabled
        warnManifestWrites = profile.warnManifestWrites
        showKeyRow = profile.showKeyRow
        newDiskSize = DiskSize.offered(bytes: profile.newDiskSizeBytes)

        profileStore.markUsed(profile.name)
        persistProfiles()

        statusText = unresolved.isEmpty
            ? "Applied profile: \(profile.name)"
            : "Applied \(profile.name) - could not resolve \(unresolved.count) item(s)"
        return unresolved
    }

    /// Clear autoboot setting (NVRAM and persisted value)
    func clearAutoboot() {
        bootString = ""
        emulator?.setNvramSetting("")
        debugPrint("[NVRAM] Cleared autoboot setting")
    }

    // Debug mode (reduces console spam when off)
    @Published var debugMode: Bool = false {
        didSet {
            emulator?.setDebug(debugMode)
        }
    }

    /// Debug print - only outputs when debugMode is enabled
    private func debugPrint(_ message: String) {
        if debugMode {
            print(message)
        }
    }

    // Current disk unit being imported/exported
    var currentDiskUnit: Int = 0
    var exportDocument: DiskImageDocument?

    // Local disk file URLs (for file-backed disks)
    @Published var localDiskURLs: [URL?] = Array(repeating: nil, count: 4)

    // For creating new disk files
    @Published var showingCreateDisk: Bool = false
    @Published var showingOpenDisk: Bool = false
    var diskUnitForFileOp: Int = 0

    // Maximum disk size (64MB for hd1k format with multiple slices)
    static let maxDiskSize = 64 * 1024 * 1024  // 64MB max
    static let defaultDiskSize = 8 * 1024 * 1024  // 8MB default for new disks

    /// The size the next created disk will be.
    ///
    /// A created disk used to be 8 MB always, and the number was written out
    /// twice: createNewDisk(at:size:) took a size its one call site never
    /// passed, and the .fileExporter that runs FIRST handed the picker an
    /// EmptyDiskDocument that wrote its own 8 MB with no reference to either.
    /// Both read this now, so the exporter and the rewrite cannot disagree.
    ///
    /// What may be offered is not a free choice: the core rejects an image that
    /// is not one of four shapes, so a round 16 or 32 MB would produce a file it
    /// refuses to load. DiskSize.offered is the list that satisfies it, and
    /// Tests/DiskSizeTests.swift is what keeps it satisfying it.
    static let newDiskSizeKey = "newDiskSizeBytes"
    @Published var newDiskSize: DiskSize = DiskSize.offered(
        bytes: UserDefaults.standard.object(forKey: EmulatorViewModel.newDiskSizeKey) as? Int
            ?? DiskSize.default.bytes) {
        didSet {
            UserDefaults.standard.set(newDiskSize.bytes, forKey: Self.newDiskSizeKey)
        }
    }

    // MARK: - Terminal screen
    //
    // The cell grid, the cursor, the scrolling region, the scrollback and the
    // whole VT100/ANSI/VT52 escape parser live in TerminalScreen.swift, which
    // imports nothing but Foundation. That is the only reason
    // Tests/TerminalScreenTests.swift can drive them on a machine with no
    // simulator and no display - the same move, and the same reason, as
    // TerminalDialect, ControlKey, ExportPath, CGAColor and TerminalRendition
    // before it.
    //
    // What is left on this side is the half that genuinely needs a host: the
    // UserDefaults the capacity is persisted in, the audio engine the bell
    // reaches, and the wire back to the emulator that a device report is
    // answered on. The parser cannot make either of those calls itself, which
    // is exactly what makes it testable; it queues them and
    // `drainTerminalEffects()` carries them out.
    //
    // `screen` is @Published, so a mutation through any of the forwarding
    // members below republishes exactly as the individual @Published
    // properties used to.
    @Published var screen = TerminalScreen(
        scrollbackCapacity: EmulatorViewModel.loadScrollbackCapacity(),
        bellEnabled: EmulatorViewModel.loadBellEnabled())

    // Terminal dimensions
    var terminalRows: Int { screen.rows }
    var terminalCols: Int { screen.cols }

    /// The live grid. The view draws `displayCells`, which is this or a window
    /// into history; this is what the banner paints into and what a test reads.
    var terminalCells: [[TerminalCell]] { screen.cells }

    var cursorRow: Int {
        get { screen.cursorRow }
        set { screen.cursorRow = newValue }
    }
    var cursorCol: Int {
        get { screen.cursorCol }
        set { screen.cursorCol = newValue }
    }

    /// DECTCEM. Read by the view to decide whether to draw the caret at all.
    var cursorVisible: Bool { screen.cursorVisible }

    /// The `terminalRows` rows currently visible: the live grid when at the
    /// bottom, or a window into (scrollback + live) when scrolled up.
    var displayCells: [[TerminalCell]] { screen.displayCells }

    var scrollbackOffset: Int { screen.scrollbackOffset }
    var isScrolledBack: Bool { screen.isScrolledBack }
    var scrollbackAvailable: Int { screen.scrollbackAvailable }

    /// Scroll the viewport by `lines` (positive = back into history, negative =
    /// toward the live bottom). Clamped to the available scrollback.
    func adjustScrollback(byLines lines: Int) { screen.adjustScrollback(byLines: lines) }

    /// Snap back to the live bottom of the terminal.
    func scrollToLiveBottom() { screen.scrollToLiveBottom() }

    /// Drop the transcript of the session that just ended.
    private func resetScrollback() { screen.resetScrollback() }

    // Scrollback capacity in lines. User-configurable (Settings); 0 disables
    // capture. Persisted under `scrollbackLines` and clamped 0...100000, matching
    // the z80cpmw `display.scrollbackLines` schema (default 1000).
    static let scrollbackCapacityKey = "scrollbackLines"
    static let scrollbackCapacityDefault = 1000
    static func loadScrollbackCapacity() -> Int {
        let v = UserDefaults.standard.object(forKey: scrollbackCapacityKey) as? Int ?? scrollbackCapacityDefault
        return min(max(0, v), TerminalScreen.maxScrollbackCapacity)
    }
    @Published var scrollbackCapacity: Int = EmulatorViewModel.loadScrollbackCapacity() {
        didSet {
            let clamped = min(max(0, scrollbackCapacity), TerminalScreen.maxScrollbackCapacity)
            if clamped != scrollbackCapacity { scrollbackCapacity = clamped; return }
            UserDefaults.standard.set(clamped, forKey: Self.scrollbackCapacityKey)
            // The screen applies it to the buffer it already holds: 0 clears the
            // history, a smaller cap trims the oldest lines.
            screen.scrollbackCapacity = clamped
        }
    }

    // MARK: - Bell

    /// Whether BEL (0x07) makes a noise.
    ///
    /// A guest that BELs in a loop could not be shut up: the parser's 0x07 arm
    /// called playBeep() with nothing to consult. cpmdroid made this a setting
    /// first and z80cpmw followed in 480edcb (setBellEnabled / isBellEnabled);
    /// this port was the last one without it.
    ///
    /// It lives on TerminalScreen, next to the counter it gates, so the
    /// suppression is testable without an audio engine - z80cpmw put it in the
    /// same place for the same reason. This property is the persistence and the
    /// Settings binding for it, nothing more.
    ///
    /// The setting is the USER'S, not the guest's: no machine reset and no
    /// escape sequence may switch it back on for someone who turned it off.
    /// TerminalScreen.resetToPowerOn() deliberately leaves it alone, and
    /// z80cpmw's clear() does the same.
    static let bellEnabledKey = "bellEnabled"
    static func loadBellEnabled() -> Bool {
        UserDefaults.standard.object(forKey: bellEnabledKey) as? Bool ?? true
    }
    @Published var bellEnabled: Bool = EmulatorViewModel.loadBellEnabled() {
        didSet {
            UserDefaults.standard.set(bellEnabled, forKey: Self.bellEnabledKey)
            screen.bellEnabled = bellEnabled
        }
    }

    private var emulator: RomWBWEmulator?

    // Audio engine for beep
    private var audioEngine: AVAudioEngine?
    private var tonePlayer: AVAudioPlayerNode?

    // Periodic disk auto-save timer
    private var diskSaveTimer: Timer?


    override init() {
        super.init()

        // No grid to build: TerminalScreen sizes its own at construction.
        // Show startup message in terminal
        showStartupMessage()

        emulator = RomWBWEmulator()
        emulator?.delegate = self

        setupAudio()

        // Restore the boot string for the release in play. romwbwVersion is a
        // stored property, so it is already set by the time this body runs.
        restoreBootString()

        // Seed the release picker with the release in play, so it has a row
        // matching its selection before any index arrives - and on a launch
        // with no network, for ever.
        romwbwVersions = [RomWBWIndexEntry.placeholder(romwbwVersion: romwbwVersion)]

        // Restore the configurable keyboard mapping
        loadKeyMapping()

        // Provenance for the installed disk images, and the path monitor that
        // decides when an unattended refresh is allowed to run.
        diskLedger = DiskLedger.deserialized(
            UserDefaults.standard.string(forKey: Self.diskLedgerKey))
        startWatchingNetwork()
    }

    deinit {
        // Started once in init, so cancelling here is unconditional. NWPathMonitor
        // holds a dispatch source; leaving it running past the object keeps the
        // update handler's captured self alive.
        pathMonitor.cancel()
    }

    private func showStartupMessage() {
        // Show version info at top of terminal
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        var buildDate = ""
        if let executableURL = Bundle.main.executableURL,
           let attrs = try? FileManager.default.attributesOfItem(atPath: executableURL.path),
           let modDate = attrs[.modificationDate] as? Date {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            buildDate = formatter.string(from: modDate)
        }
        // place(), not write(): this paints a screen nobody is typing at yet,
        // so it must not move the cursor or disturb the parser.
        let versionStr = "Z80CPM v\(version).\(build) \(buildDate)"
        screen.place(versionStr, row: 0, col: 0)

        // Show "Press Play" message centered
        let message = "Press Play to start, then"
        let startRow = terminalRows / 2
        screen.place(message, row: startRow, col: (terminalCols - message.count) / 2)

        let hint = "C<ret> start CP/M   2<ret> boot slice 0"
        screen.place(hint, row: startRow + 1, col: (terminalCols - hint.count) / 2)
    }

    // MARK: - Audio Setup

    private func setupAudio() {
        audioEngine = AVAudioEngine()
        tonePlayer = AVAudioPlayerNode()

        guard let engine = audioEngine, let player = tonePlayer else { return }

        engine.attach(player)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        engine.connect(player, to: engine.mainMixerNode, format: format)

        do {
            try engine.start()
        } catch {
            debugPrint("Audio engine failed to start: \(error)")
        }
    }

    // MARK: - Resource Loading

    func loadBundledResources() {
        // The ROM choice, against what this release offers. With no catalog yet
        // that is the app's own ROM and only when the release in play is the
        // one it declares - which is the offline first launch. The catalog
        // fetch below re-resolves it against `roms[]` the moment it lands.
        restoreROMSelection()

        // Fetch the disk catalog (async - calls restoreDiskSelections when done)
        fetchDiskCatalog()
    }

    /// Restore saved disk selections from UserDefaults, or set defaults
    private func restoreDiskSelections() {
        // Read once, before anything can rewrite it, and hand it to the persist
        // at the end so a name this catalog cannot resolve is remembered rather
        // than blanked. See persistSelectedDisks(remembering:).
        let savedSelections = UserDefaults.standard.stringArray(forKey: selectedDisksKey)

        isRestoringSelections = true
        defer {
            isRestoringSelections = false
            // Once, at the end, with the whole selection settled. The first-run
            // path picks defaults out of the catalog and those do have to be
            // written; it is only the three intermediate states that did not.
            persistSelectedDisks(remembering: savedSelections)
        }

        // Check if user has saved selections
        let hasSavedSelections = savedSelections != nil
        debugPrint("[RestoreDisks] hasSavedSelections=\(hasSavedSelections)")
        debugPrint("[RestoreDisks] availableDisks has \(availableDisks.count) entries:")
        for disk in availableDisks {
            debugPrint("[RestoreDisks]   - '\(disk.filename)' isDownloaded=\(disk.isDownloaded)")
        }

        if hasSavedSelections {
            if let savedDisks = savedSelections {
                debugPrint("[RestoreDisks] Saved filenames: \(savedDisks)")
                for (index, filename) in savedDisks.enumerated() where index < 4 {
                    if !filename.isEmpty {
                        let found = availableDisks.first { $0.filename == filename }
                        debugPrint("[RestoreDisks] Disk \(index): '\(filename)' -> \(found != nil ? "found, isDownloaded=\(found!.isDownloaded)" : "NOT FOUND")")
                        selectedDisks[index] = found
                    }
                }
            }
        } else {
            // First launch defaults: use defaultSlot from catalog
            debugPrint("[RestoreDisks] First launch - setting defaults from catalog")
            for catalogDisk in diskCatalog {
                if let slot = catalogDisk.defaultSlot, slot >= 0, slot < 4 {
                    debugPrint("[RestoreDisks] Catalog default: '\(catalogDisk.filename)' -> slot \(slot)")
                    selectedDisks[slot] = availableDisks.first { $0.filename == catalogDisk.filename }
                }
            }
        }

        // Ensure disk 0 has something selected (fallback if no catalog defaults)
        if selectedDisks[0] == nil || selectedDisks[0]?.filename.isEmpty == true {
            // Try to find a disk with defaultSlot=0, then fall back to first available
            let defaultDisk = diskCatalog.first { $0.defaultSlot == 0 }
            selectedDisks[0] = availableDisks.first { $0.filename == defaultDisk?.filename }
                ?? availableDisks.first { !$0.filename.isEmpty }
                ?? availableDisks.first
        }

        debugPrint("[RestoreDisks] Final selections:")
        for (i, disk) in selectedDisks.enumerated() {
            if let d = disk {
                debugPrint("[RestoreDisks]   Disk \(i): '\(d.filename)' isDownloaded=\(d.isDownloaded)")
            } else {
                debugPrint("[RestoreDisks]   Disk \(i): nil")
            }
        }

        // Restore local disk bindings from bookmarks
        restoreLocalDiskBindings()

        statusText = "Ready - Press Play to start"
    }


    /// Load the selected ROM and disks. Returns false only when the ROM failed:
    /// without a ROM there is nothing to execute, so the caller must not start
    /// the CPU. A disk that fails to load is reported but is not fatal - booting
    /// with no disk is legitimate.
    @discardableResult
    func loadSelectedResources() -> Bool {
        // Close all existing disks before loading new configuration
        // This prevents old disks from persisting when user reduces disk count
        emulator?.closeAllDisks()

        // The ROM, from wherever this release's copy actually is: the app
        // bundle when the bundled image is what the catalog publishes, and
        // Documents/Disks when it is not.
        //
        // Checked here rather than trusted from start(). This is the moment the
        // bytes reach the core, and it is reached again from every later Play,
        // by which time the file can have been replaced by a restore or a sync.
        // loadROMFromData: takes the exact bytes that were hashed, so there is
        // no window between the check and the load in which the file could
        // change - which loadROMFromPath: would have left open.
        let resolution = resolveROM()
        guard case .ready(let romImage, let romOption) = resolution else {
            // No fallback to the bundled ROM. See resolveROM: substituting it
            // is the mismatch this whole path exists to prevent, and it would
            // happen where nobody is looking.
            switch resolution {
            case .ready:
                break
            case .needsDownload(_, let asset, _):
                reportROMProblem(romProblemText(file: asset.filename,
                                                reason: "it is not on this device yet"))
            case .unavailable(let reason):
                reportROMProblem(reason)
            }
            return false
        }

        // What the IMAGE says it is, now that its bytes are in hand. The hash
        // says these are the bytes the catalog named; it cannot say what the
        // four HCB bytes at 0x103 hold, and those are what the guest reports
        // and what the disks have to agree with. A ROM that verifies against
        // the wrong release's catalog entry is a publishing mistake upstream,
        // and starting on it is exactly the pairing this refuses to make.
        if let declared = RomWBWEmulator.romWBWRelease(ofImageData: romImage),
           declared != romwbwVersion {
            reportROMProblem(romProblemText(
                file: romOption.filename,
                reason: "the image says it is RomWBW \(declared), not \(romwbwVersion)"))
            return false
        }

        debugPrint("[EmulatorVM] Loading ROM: \(romOption.filename)")
        guard emulator?.loadROM(fromData: romImage) == true else {
            // The bridge records why: unreadable, or rejected by the core's HCB
            // validation. That check stays the last line of defence - verifying
            // a hash says the bytes are the published ones, not that this build
            // can run them.
            let reason = emulator?.lastROMError ?? "\(romOption.filename) could not be loaded"
            debugPrint("[EmulatorVM] ERROR: Failed to load ROM: \(romOption.filename) - \(reason)")
            showError("Failed to load ROM: \(romOption.filename)\n\(reason)")
            statusText = "Error: \(reason)"
            return false
        }
        debugPrint("[EmulatorVM] ROM loaded successfully: \(romOption.filename)")
        statusText = "ROM loaded: \(romOption.name)"

        // Should be nil from here on: the ROM that just loaded is this
        // release's own. Kept because it is the safety net for a user whose
        // picker is still showing the bundled ROM under another release, and
        // because a log that says so is cheaper than a bug report about a
        // warning in the middle of a boot.
        if let mismatch = romReleaseMismatchNotice {
            debugPrint("[EmulatorVM] \(mismatch)")
        }

        var diskLoadErrors: [String] = []

        // Load selected disks
        for unit in 0..<selectedDisks.count {
            debugPrint("[EmulatorVM] Loading disk unit \(unit): \(selectedDisks[unit]?.filename ?? "none")")

            // First check if there's a local file URL for this unit
            if let url = localDiskURLs[unit] {
                if loadLocalDisk(unit: unit, from: url) {
                    debugPrint("[EmulatorVM] Loaded local disk to unit \(unit)")
                    statusText = "Loaded local file to \(diskLabels[unit])"
                    continue
                }
            }

            // Check for selected disk
            if let disk = selectedDisks[unit], !disk.filename.isEmpty {
                // Always check actual file existence, not just isDownloaded flag
                let diskPath = downloadsDirectory.appendingPathComponent(disk.filename)
                let fileExists = FileManager.default.fileExists(atPath: diskPath.path)
                debugPrint("[EmulatorVM] Disk \(unit) '\(disk.filename)': isDownloaded=\(disk.isDownloaded), fileExists=\(fileExists)")

                if fileExists {
                    // Load from downloads directory
                    if loadDownloadedDisk(unit: unit, filename: disk.filename) {
                        debugPrint("🔵 [DISK] Loaded downloaded disk \(disk.filename) to unit \(unit)")
                        statusText = "Loaded: \(disk.name) to \(diskLabels[unit])"
                        continue
                    } else {
                        debugPrint("[EmulatorVM] ERROR: File exists but failed to load \(disk.filename)")
                        diskLoadErrors.append("\(disk.filename) (corrupted?)")
                        continue
                    }
                }

                // Try loading from bundle as fallback
                let success = emulator?.loadDisk(Int32(unit), fromBundle: disk.filename) == true
                debugPrint("🔵 [DISK] loadDisk(\(unit), \(disk.filename)) from bundle = \(success)")
                if success {
                    statusText = "Loaded: \(disk.name) to \(diskLabels[unit])"
                } else {
                    debugPrint("[EmulatorVM] ERROR: Failed to load \(disk.filename) to unit \(unit) - not in downloads or bundle")
                    diskLoadErrors.append(disk.filename)
                }
            }
        }

        // Show error if any disks failed to load
        if !diskLoadErrors.isEmpty {
            showError("Failed to load disks: \(diskLoadErrors.joined(separator: ", ")). Try re-downloading from Settings.")
        }

        // Apply boot setting to emulator - empty means no autoboot
        emulator?.setNvramSetting(bootString)
        debugPrint("[NVRAM] Applied boot setting '\(bootString.isEmpty ? "(none)" : bootString)' to emulator")

        // Apply warning suppression setting to all disk units
        applyWarningSuppression()

        return true
    }

    // MARK: - Local Disk File Management

    func openLocalDisk(unit: Int) {
        diskUnitForFileOp = unit
        showingOpenDisk = true
    }

    func createLocalDisk(unit: Int) {
        diskUnitForFileOp = unit
        showingCreateDisk = true
    }

    func loadLocalDisk(unit: Int, from url: URL) -> Bool {
        guard url.startAccessingSecurityScopedResource() else {
            showError("Cannot access file: \(url.lastPathComponent)")
            return false
        }
        defer { url.stopAccessingSecurityScopedResource() }

        do {
            let data = try Data(contentsOf: url)
            if data.count > Self.maxDiskSize {
                showError("Disk file too large (max 8MB)")
                return false
            }
            if emulator?.loadDisk(Int32(unit), from: data) == true {
                localDiskURLs[unit] = url
                selectedDisks[unit] = DiskOption(name: "Local: \(url.lastPathComponent)", filename: "")
                saveLocalDiskBindings()
                return true
            }
        } catch {
            showError("Failed to load disk: \(error.localizedDescription)")
        }
        return false
    }

    func handleOpenDiskResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            if loadLocalDisk(unit: diskUnitForFileOp, from: url) {
                statusText = "Loaded: \(url.lastPathComponent) to \(diskLabels[diskUnitForFileOp])"
            }
        case .failure(let error):
            showError("Open failed: \(error.localizedDescription)")
        }
    }

    /// Write a blank image at `url` and bind it to the unit the create flow was
    /// started for.
    ///
    /// `size` defaults to nil rather than to a constant so that the ordinary
    /// call takes the user's choice; passing one explicitly is for a caller
    /// that has its own reason, and the tests.
    func createNewDisk(at url: URL, size: Int? = nil) {
        guard url.startAccessingSecurityScopedResource() else {
            showError("Cannot access location")
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        // Create empty disk image (filled with 0xE5 like formatted CP/M disk).
        // 0xE5 is CP/M's empty-directory-entry marker, so this comes up as a
        // blank drive - but there is no boot track and no system on it. See
        // KNOWN_PROBLEMS.md for building a bootable image with cpmtools.
        let chosen = size ?? newDiskSize.bytes
        let data = Data(repeating: 0xE5, count: min(chosen, Self.maxDiskSize))

        do {
            try data.write(to: url)
            if emulator?.loadDisk(Int32(diskUnitForFileOp), from: data) == true {
                localDiskURLs[diskUnitForFileOp] = url
                selectedDisks[diskUnitForFileOp] = DiskOption(name: "Local: \(url.lastPathComponent)", filename: "")
                saveLocalDiskBindings()
                statusText = "Created: \(url.lastPathComponent)"
            }
        } catch {
            showError("Failed to create disk: \(error.localizedDescription)")
        }
    }

    func saveDiskToFile(unit: Int) {
        guard let url = localDiskURLs[unit] else {
            // If no local URL, use the regular export dialog
            saveDisk(unit)
            return
        }

        guard let data = emulator?.getDiskData(Int32(unit)) else {
            showError("No data in disk unit \(unit)")
            return
        }

        guard url.startAccessingSecurityScopedResource() else {
            showError("Cannot access file")
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        do {
            try data.write(to: url)
            statusText = "Saved: \(url.lastPathComponent)"
        } catch {
            showError("Failed to save: \(error.localizedDescription)")
        }
    }

    // MARK: - Local Disk Bookmark Persistence

    /// Save security-scoped bookmarks for local disk files to UserDefaults
    private func saveLocalDiskBindings() {
        var bookmarks: [Data?] = Array(repeating: nil, count: 4)

        for i in 0..<4 {
            guard let url = localDiskURLs[i] else { continue }
            do {
                let bookmarkData = try url.bookmarkData(
                    options: .minimalBookmark,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                bookmarks[i] = bookmarkData
                debugPrint("[LocalDisk] Saved bookmark for slot \(i): \(url.lastPathComponent)")
            } catch {
                debugPrint("[LocalDisk] Failed to create bookmark for slot \(i): \(error)")
            }
        }

        // Save as array of optional Data (encode as array of Data or empty Data)
        let encoded = bookmarks.map { $0 ?? Data() }
        UserDefaults.standard.set(encoded, forKey: "localDiskBookmarks")
        debugPrint("[LocalDisk] Saved \(bookmarks.compactMap { $0 }.count) local disk bookmarks")
    }

    /// Restore local disk bindings from saved bookmarks
    private func restoreLocalDiskBindings() {
        guard let savedBookmarks = UserDefaults.standard.array(forKey: "localDiskBookmarks") as? [Data] else {
            debugPrint("[LocalDisk] No saved bookmarks found")
            return
        }

        for (i, bookmarkData) in savedBookmarks.enumerated() where i < 4 {
            guard !bookmarkData.isEmpty else { continue }

            do {
                var isStale = false
                let url = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: [],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )

                if isStale {
                    debugPrint("[LocalDisk] Bookmark for slot \(i) is stale, will re-save")
                }

                // Verify we can still access the file
                guard url.startAccessingSecurityScopedResource() else {
                    debugPrint("[LocalDisk] Cannot access security-scoped resource for slot \(i)")
                    continue
                }

                if FileManager.default.fileExists(atPath: url.path) {
                    localDiskURLs[i] = url
                    selectedDisks[i] = DiskOption(name: "Local: \(url.lastPathComponent)", filename: "")
                    debugPrint("[LocalDisk] Restored local disk for slot \(i): \(url.lastPathComponent)")

                    // Re-save bookmark if stale
                    if isStale {
                        saveLocalDiskBindings()
                    }
                } else {
                    url.stopAccessingSecurityScopedResource()
                    debugPrint("[LocalDisk] File no longer exists for slot \(i): \(url.path)")
                }
            } catch {
                debugPrint("[LocalDisk] Failed to resolve bookmark for slot \(i): \(error)")
            }
        }
    }

    /// Clear local disk binding for a specific slot
    func clearLocalDisk(unit: Int) {
        if let url = localDiskURLs[unit] {
            url.stopAccessingSecurityScopedResource()
        }
        localDiskURLs[unit] = nil
        saveLocalDiskBindings()
        debugPrint("[LocalDisk] Cleared local disk for slot \(unit)")
    }

    // MARK: - Emulation Control

    func start() {
        statusText = "Checking disks..."

        // Check if catalog is loaded
        if diskCatalog.isEmpty {
            if catalogLoading {
                showError("Disk catalog is loading. Please wait a moment and try again.")
                statusText = "Catalog loading..."
            } else {
                showError("Failed to load disk catalog. Please check your internet connection and try again.")
                statusText = "Error: No disk catalog"
            }
            return
        }

        // Check if any disk is selected
        let hasSelectedDisk = selectedDisks.contains { $0 != nil && !($0?.filename.isEmpty ?? true) }
        if !hasSelectedDisk {
            showError("No disk selected. Please select at least one disk in Settings.")
            statusText = "Error: No disk selected"
            return
        }

        // Debug logging
        debugPrint("[Start] diskCatalog has \(diskCatalog.count) entries")
        debugPrint("[Start] Downloads directory: \(downloadsDirectory.path)")

        // Collect disks that need downloading
        var neededDownloads: [DownloadableDisk] = []
        var missingFromCatalog: [String] = []
        var alreadyDownloaded: [String] = []

        for (i, diskOpt) in selectedDisks.enumerated() {
            guard let disk = diskOpt, !disk.filename.isEmpty else {
                debugPrint("[Start] Disk \(i): (none)")
                continue
            }

            // Check actual file existence
            let fileExists = isDiskDownloaded(disk.filename)
            debugPrint("[Start] Disk \(i): '\(disk.filename)' fileExists=\(fileExists)")

            if fileExists {
                alreadyDownloaded.append(disk.filename)
                continue
            }

            // Need to download - look up in catalog
            if let catalogEntry = diskCatalog.first(where: { $0.filename == disk.filename }) {
                debugPrint("[Start] Need download: '\(disk.filename)'")
                neededDownloads.append(catalogEntry)
            } else {
                debugPrint("[Start] ERROR: '\(disk.filename)' NOT in catalog!")
                missingFromCatalog.append(disk.filename)
            }
        }

        debugPrint("[Start] Already downloaded: \(alreadyDownloaded.count), need download: \(neededDownloads.count), missing: \(missingFromCatalog.count)")

        // Error if any selected disks aren't in catalog
        if !missingFromCatalog.isEmpty {
            showError("Cannot find disk(s) in catalog: \(missingFromCatalog.joined(separator: ", ")). The catalog may be outdated.")
            statusText = "Error: Disk not in catalog"
            return
        }

        // The ROM first, and everything below waits on it.
        //
        // This is the one resource with no degraded mode. A disk that will not
        // download leaves an empty drive; a ROM that will not download leaves
        // either nothing to execute or - if the bundled one were substituted -
        // a guest whose CBIOS and HBIOS disagree, which RomWBW announces in the
        // middle of a boot and most people scroll past. So it is fetched before
        // the disks (512 KB against tens of megabytes, and it is the blocking
        // one), verified, and a failure stops the start rather than softening
        // it. prepareROM has already told the user what is wrong and offered
        // the way out by the time it answers false.
        prepareROM { [weak self] romReady in
            guard let self = self, romReady else { return }

            // Download if needed, otherwise start
            if !neededDownloads.isEmpty {
                self.statusText = "Downloading \(neededDownloads.count) disk(s)..."
                self.downloadDisksAndStart(neededDownloads)
            } else if alreadyDownloaded.isEmpty {
                // Nothing selected or all slots empty
                self.showError("No disks available to load. Please download disks in Settings first.")
                self.statusText = "Error: No disks"
            } else {
                // All disks ready
                self.debugPrint("[Start] All disks ready, starting emulator")
                self.startEmulator()
            }
        }
    }

    /// Download multiple disks sequentially, then start emulator
    private func downloadDisksAndStart(_ disks: [DownloadableDisk]) {
        guard !disks.isEmpty else {
            isDownloading = false
            downloadingDiskName = ""
            startEmulator()
            return
        }

        var remaining = disks
        let current = remaining.removeFirst()
        isDownloading = true
        downloadingDiskName = current.name
        downloadingProgress = 0
        statusText = "Downloading \(current.name)..."

        downloadDiskWithCompletion(current) { [weak self] success in
            guard let self = self else { return }
            if success {
                // Continue with remaining downloads
                self.downloadDisksAndStart(remaining)
            } else {
                self.isDownloading = false
                self.downloadingDiskName = ""
                // Get actual error from download state
                if case .error(let errorMsg) = self.downloadStates[current.filename] {
                    self.showError("Download failed: \(errorMsg)")
                } else {
                    self.showError("Failed to download \(current.name)")
                }
            }
        }
    }

    /// Download a disk image with completion callback (uses same path as settings download)
    private func downloadDiskWithCompletion(_ disk: DownloadableDisk, completion: @escaping (Bool) -> Void) {
        // Use the settings download path and poll for completion
        downloadDiskFromSettings(disk, attemptsRemaining: 3, session: downloadSession,
                                 expectedFacts: nil)
        waitForDownloadCompletion(disk.filename, completion: completion)
    }

    /// Poll for download completion (checks downloadStates)
    private func waitForDownloadCompletion(_ filename: String, completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self = self else {
                completion(false)
                return
            }
            switch self.downloadStates[filename] {
            case .downloaded:
                self.downloadingProgress = 1.0
                completion(true)
            case .error:
                self.downloadingProgress = 0
                completion(false)
            case .downloading(let progress):
                self.downloadingProgress = progress
                self.waitForDownloadCompletion(filename, completion: completion)
            case .notDownloaded, .none:
                // Still in progress, keep polling
                self.waitForDownloadCompletion(filename, completion: completion)
            }
        }
    }

    /// Actually start the emulator after all disks are ready
    private func startEmulator() {
        debugPrint("🟢 [START] startEmulator called")
        // Before the disks are read. An unattended refresh decided its verdict
        // when nothing was running; this is the moment that stops being true.
        cancelRefreshesForMountedDisks()
        // Clear terminal before starting (removes "Press Play" message).
        // clearTerminal(), not eraseScreen(): starting is a machine-level clear,
        // so it must put the rendition back to the default before painting -
        // an erase fills with the current background now.
        clearTerminal()
        // Starting is a fresh session too. The screen was already cleared above;
        // leaving the history behind it meant the banner printed on top of the
        // previous machine's transcript, and a drag walked back into output that
        // no longer had anything to do with what was running.
        resetScrollback()
        // Print version info to terminal
        printVersionInfo()
        // Load selected ROM and disks before starting
        debugPrint("🟢 [START] calling loadSelectedResources")
        guard loadSelectedResources() else {
            // loadSelectedResources has already set statusText and raised the
            // error alert. Running the CPU with no ROM just executes whatever
            // bank 0 happens to hold.
            debugPrint("🔴 [START] resource load failed, not starting")
            isRunning = false
            return
        }
        debugPrint("🟢 [START] calling emulator.start()")
        emulator?.start()
        isRunning = emulator?.isRunning ?? false
        statusText = "Running"
        terminalShouldFocus = true  // Auto-focus terminal
        debugPrint("🟢 [START] emulator started, isRunning=\(isRunning)")

        // Start periodic disk auto-save timer (every 20 seconds)
        diskSaveTimer = Timer.scheduledTimer(withTimeInterval: 20.0, repeats: true) { [weak self] _ in
            self?.saveDownloadedDisks()
        }
    }

    func stop() {
        // Stop auto-save timer
        diskSaveTimer?.invalidate()
        diskSaveTimer = nil

        // Auto-save any modified downloaded disks
        saveDownloadedDisks()

        emulator?.stop()
        isRunning = false
        statusText = "Stopped - disk changes saved"
    }

    // MARK: - NVRAM Persistence

    /// Read the boot string for the release in play back out of UserDefaults.
    ///
    /// Called from init and from the release switch. It replaces a `loadNvram()`
    /// that had no caller anywhere in the tree - dead since before the ledger
    /// existed - and that pushed the stored setting straight into the emulator,
    /// which `loadSelectedResources()` already does at load time. Leaving a dead
    /// reader of a key that is now per release would have been worse than the
    /// dead code was: the version-scoping would have looked done and been
    /// applied in one of the two places that matter.
    ///
    /// The assignment writes the value straight back through bootString's
    /// didSet, under the SAME key it was just read from. That is idempotent,
    /// and after a switch it is what puts an empty string under a release the
    /// user has never set a boot option for.
    private func restoreBootString() {
        bootString = UserDefaults.standard.string(forKey: nvramKey) ?? ""
    }

    /// Sync NVRAM from emulator to UI (called when SYSCONF changes NVRAM)
    /// Setting bootString triggers didSet which saves to UserDefaults
    private func syncNvramFromEmulator() {
        let setting = emulator?.getNvramSetting() ?? ""
        bootString = setting
        debugPrint("[NVRAM] Synced from emulator: '\(setting)'")
    }

    /// Public method to save all disk images (called from UI menu)
    func saveAllDisks() {
        saveDownloadedDisks()
        statusText = "All disks saved"
    }

    /// Open the Imports folder (for R8)
    func openImportsFolder() {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let importsDir = docs.appendingPathComponent("Imports", isDirectory: true)
        try? fm.createDirectory(at: importsDir, withIntermediateDirectories: true)
        openFolderInFilesApp(importsDir)
    }

    /// Open the Exports folder (for W8)
    func openExportsFolder() {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let exportsDir = docs.appendingPathComponent("Exports", isDirectory: true)
        try? fm.createDirectory(at: exportsDir, withIntermediateDirectories: true)
        openFolderInFilesApp(exportsDir)
    }

    /// Open a folder - on Mac opens Finder, on iOS shows path
    private func openFolderInFilesApp(_ url: URL) {
        #if targetEnvironment(macCatalyst)
        // On Mac, open in Finder
        UIApplication.shared.open(url)
        #else
        // On iOS, try shareddocuments scheme for Files app
        if let filesURL = URL(string: "shareddocuments://\(url.path)"),
           UIApplication.shared.canOpenURL(filesURL) {
            UIApplication.shared.open(filesURL)
        } else {
            // Fallback: show the path
            showError("Open Files app and navigate to:\nOn My iPhone > Z80CPM > \(url.lastPathComponent)")
        }
        #endif
    }

    /// Save downloaded disk images back to Documents/Disks
    private func saveDownloadedDisks() {
        print("[SaveDisks] Starting save, emulator running: \(isRunning)")
        for unit in 0..<4 {
            guard let disk = selectedDisks[unit],
                  !disk.filename.isEmpty else {
                print("[SaveDisks] Unit \(unit): no disk selected")
                continue
            }

            // Check if this is a downloaded disk (file exists in downloads directory)
            let path = downloadsDirectory.appendingPathComponent(disk.filename)
            let isDownloadedDisk = FileManager.default.fileExists(atPath: path.path)
            print("[SaveDisks] Unit \(unit): '\(disk.filename)' exists=\(isDownloadedDisk) path=\(path.path)")
            guard isDownloadedDisk else { continue }

            guard let data = emulator?.getDiskData(Int32(unit)),
                  data.count > 0 else {
                print("[SaveDisks] Unit \(unit): no data from emulator")
                continue
            }

            print("[SaveDisks] Unit \(unit): got \(data.count) bytes from emulator")
            do {
                try data.write(to: path)
                print("[SaveDisks] Unit \(unit): saved \(data.count) bytes to \(disk.filename)")
            } catch {
                print("[SaveDisks] Unit \(unit): FAILED to save: \(error)")
            }
        }
    }

    /// Public method to save disks (called from app lifecycle)
    func saveDisksOnBackground() {
        print("[SaveDisks] saveDisksOnBackground called, isRunning=\(isRunning)")
        if isRunning {
            saveDownloadedDisks()
        }
    }

    func reset() {
        // Save disks before reset
        saveDownloadedDisks()

        emulator?.reset()

        // Apply boot setting - empty means no autoboot
        emulator?.setNvramSetting(bootString)

        // Cold boot returns the terminal to its ANSI/VT100 default: the
        // dialect, the parser state, both sticky DEC modes, the rendition, the
        // screen and the scrollback. The order inside matters and belongs with
        // the state, so it lives in TerminalScreen.resetToPowerOn() rather than
        // being written out here.
        //
        // What it deliberately does NOT touch is `bellEnabled`. That is the
        // user's setting, not the machine's, and no reset may switch it back on
        // for someone who turned it off.
        screen.resetToPowerOn()
        isRunning = false
        // The auto-save timer has to go with the machine. It used to survive a
        // Reset - `stop()` invalidated it and this did not - so a repeating
        // twenty-second write of the emulator's in-memory image carried on
        // against a machine reported as not running. Harmless-looking until
        // something else trusted `isRunning` to mean "the emulator can still
        // write to this file", which is exactly what the disk refresh does.
        diskSaveTimer?.invalidate()
        diskSaveTimer = nil
        statusText = "Reset - disk changes saved"
    }

    func sendKey(_ char: Character) {
        // Typing returns the view to the live bottom.
        scrollToLiveBottom()
        // Only send ASCII characters (0-127) to CP/M
        guard let code = char.asciiValue else { return }
        emulator?.sendCharacter(unichar(code))
    }

    func sendString(_ str: String) {
        scrollToLiveBottom()
        emulator?.send(str)
    }

    // Set controlify mode (for Ctrl key modifier)
    func setControlify(_ mode: RWBControlifyMode) {
        emulator?.setControlify(mode)
    }

    // Check if controlify is active
    var isControlifyActive: Bool {
        guard let mode = emulator?.getControlify() else { return false }
        return mode != .off
    }

    // MARK: - Terminal Operations
    //
    // Both of these are TerminalScreen's, and the argument for why they are two
    // different jobs - ED is not DECSTBM - is written out there. They are kept
    // as members here because the views and the machine paths call them by
    // these names.

    /// Erase the whole screen and home the cursor. Nothing else: not the
    /// rendition, not the parser state, not the scrolling region.
    func eraseScreen() { screen.eraseScreen() }

    /// Erase the screen AND put the terminal back to power-on state. This is
    /// the machine-level clear - Start and Reset - and no guest sequence
    /// reaches it.
    func clearTerminal() { screen.clearTerminal() }

    /// Write a host string to the terminal at the current cursor position. Not
    /// the guest's data path: this does not run the escape parser.
    private func writeToTerminal(_ text: String) { screen.write(text) }

    /// Output version and build info to terminal
    func printVersionInfo() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        var buildDate = ""
        if let executableURL = Bundle.main.executableURL,
           let attrs = try? FileManager.default.attributesOfItem(atPath: executableURL.path),
           let modDate = attrs[.modificationDate] as? Date {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            buildDate = formatter.string(from: modDate)
        }
        writeToTerminal("Z80CPM v\(version).\(build) \(buildDate)\n")
    }

    // MARK: - Disk Management

    func loadDisk(_ unit: Int) {
        currentDiskUnit = unit
        showingDiskPicker = true
    }

    func saveDisk(_ unit: Int) {
        guard let data = emulator?.getDiskData(Int32(unit)) else {
            showError("No data in disk unit \(unit)")
            return
        }
        currentDiskUnit = unit
        exportDocument = DiskImageDocument(data: data)
        showingDiskExporter = true
    }

    func handleDiskImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }

            guard url.startAccessingSecurityScopedResource() else {
                showError("Cannot access file")
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }

            do {
                let data = try Data(contentsOf: url)
                _ = emulator?.loadDisk(Int32(currentDiskUnit), from: data)
                statusText = "Loaded disk unit \(currentDiskUnit)"
            } catch {
                showError("Failed to load disk: \(error.localizedDescription)")
            }

        case .failure(let error):
            showError("Import failed: \(error.localizedDescription)")
        }
    }

    func handleExportResult(_ result: Result<URL, Error>) {
        if case .failure(let error) = result {
            showError("Export failed: \(error.localizedDescription)")
        }
        exportDocument = nil
    }

    // MARK: - Helpers

    private func showError(_ message: String, title: String = "Error") {
        errorMessage = message
        errorTitle = title
        showingError = true
    }

    /// Show warning when writing to a manifest-managed disk
    private func showManifestWriteWarning() {
        showingManifestWriteWarning = true
    }

    /// Suppress manifest write warnings for all loaded disks (user chose "Don't warn again")
    /// Also persists the preference so it survives app restart
    func suppressManifestWriteWarnings() {
        warnManifestWrites = false  // This calls applyWarningSuppression() and persists to UserDefaults
    }

    /// Calculate SHA256 hash of a file
    func sha256OfFile(at url: URL) -> String? {
        // .mappedIfSafe, not a plain read: the combo image is 49 MB and this runs
        // on a phone.  Reading it whole puts 49 MB of dirty pages in the process
        // right after a download has already used memory; mapping lets SHA256 walk
        // the file and lets the OS evict pages behind it.  Falls back to a normal
        // read on its own when mapping is unsafe (a non-regular file, or a volume
        // that cannot be mapped), which is what "ifSafe" means.
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Disk Freshness
    //
    // Whether each installed image is still the one the catalog names, and what
    // the app may do about one that is not. DiskLedger.swift carries the whole
    // argument; what is here is the plumbing - where the facts come from, when
    // the question is asked, and which session answers it.

    private func persistDiskLedger() {
        UserDefaults.standard.set(diskLedger.serialized(), forKey: Self.diskLedgerKey)
    }

    /// Size and modification time for an installed image, or nil if there is no
    /// file. These two are what decide whether a stored hash still describes the
    /// bytes, so the whole library does not have to be re-read on every launch.
    private func fileFacts(for filename: String) -> DiskFileFacts? {
        let url = downloadsDirectory.appendingPathComponent(filename)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value,
              let modified = attrs[.modificationDate] as? Date else { return nil }
        return DiskFileFacts(size: size, modified: modified.timeIntervalSinceReferenceDate)
    }

    /// True when the file is selected in a slot AND the machine is running.
    ///
    /// Replacing it then undoes itself: `saveDownloadedDisks()` writes the
    /// in-memory image back over the file on the next flush, so the badge would
    /// go green and then red again. Worse, the download lands under a machine
    /// that has the old geometry mapped.
    private func isMounted(_ filename: String) -> Bool {
        let wanted = filename.lowercased()
        for unit in 0..<selectedDisks.count {
            guard let disk = selectedDisks[unit],
                  disk.filename.lowercased() == wanted else { continue }
            // Ask the emulator rather than trusting `isRunning`. `reset()` sets
            // isRunning false and `HBIOSEmulator::reset()` does not close the
            // disks, so the in-memory image is still there and still gets
            // written back - which made a stopped-looking machine able to undo a
            // refresh and leave the ledger recording the new hash for the old
            // bytes, permanently and invisibly.
            if emulator?.isDiskLoaded(Int32(unit)) == true { return true }
            if isRunning { return true }
        }
        return false
    }

    /// The freshness verdict for one catalog entry, from the ledger and the file.
    private func freshness(of disk: DownloadableDisk) -> DiskFreshness {
        diskLedger.freshness(filename: disk.filename,
                             catalogSha256: disk.sha256,
                             facts: fileFacts(for: disk.filename))
    }

    /// What the settings row should offer for this entry.
    func refreshPlan(for filename: String) -> DiskRefreshPlan {
        diskRefreshPlans[filename.lowercased()] ?? .doNothing
    }

    /// Recompute every verdict, hash whatever cannot be decided without it, and
    /// start the refreshes the network allows.
    ///
    /// Called after a catalog has been adopted and whenever the path changes. It
    /// is cheap in the ordinary case: nothing is read from disk but sizes and
    /// modification times.
    func reassessDiskFreshness() {
        guard !diskCatalog.isEmpty else { return }

        var plans: [String: DiskRefreshPlan] = [:]
        var toMeasure: [DownloadableDisk] = []

        for disk in diskCatalog {
            let key = disk.filename.lowercased()
            let verdict = freshness(of: disk)
            if verdict == .needsMeasurement {
                // Not a mounted disk: the running machine rewrites it every
                // twenty seconds, so the measurement would never settle and the
                // pass would re-read it for as long as the emulator ran. Nothing
                // is offered for one anyway.
                let churning = isMounted(disk.filename)
                let exhausted =
                    (measurementAttempts[key] ?? 0) >= Self.maxMeasurementAttempts
                if !measurementFailed.contains(key) && !churning && !exhausted {
                    toMeasure.append(disk)
                }
                // Say nothing about a disk that has not been measured. An
                // unmeasured file is not evidence of anything.
                plans[key] = .doNothing
                continue
            }
            plans[key] = DiskRefreshPolicy.plan(for: verdict,
                                                network: networkCondition,
                                                isMounted: isMounted(disk.filename))
        }

        diskRefreshPlans = plans

        if !toMeasure.isEmpty {
            measureDisks(toMeasure)
            return
        }
        startAllowedRefreshes()
    }

    /// Hash the images whose provenance cannot be settled without it, off the
    /// main thread, then ask again.
    ///
    /// This is the migration path and it runs at most once per file: every
    /// outcome writes something into the ledger - a measurement, an adopted
    /// provenance, or a place in `measurementFailed` - so no file can come back
    /// round to `.needsMeasurement` unchanged. That is what stops an unbounded
    /// re-hash of a 49 MB image.
    private func measureDisks(_ disks: [DownloadableDisk]) {
        guard !measuringDisks else { return }
        measuringDisks = true

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }

            var measured: [(String, String, DiskFileFacts, String?)] = []
            var failed: [String] = []

            for disk in disks {
                // Re-read the facts beside the hash rather than reusing the ones
                // the verdict was taken against: the file can be rewritten by
                // saveDownloadedDisks() while this loop is running, and a hash
                // stored against the older size would then claim to describe
                // bytes it never saw.
                guard let facts = self.fileFacts(for: disk.filename) else {
                    failed.append(disk.filename.lowercased())
                    continue
                }
                let url = self.downloadsDirectory.appendingPathComponent(disk.filename)
                guard let hash = self.sha256OfFile(at: url) else {
                    // Distinguish this from "absent": a transient read failure
                    // must not be allowed to read as a reason to re-download.
                    failed.append(disk.filename.lowercased())
                    continue
                }
                measured.append((disk.filename, hash, facts, disk.sha256))
            }

            DispatchQueue.main.async {
                for disk in disks {
                    let key = disk.filename.lowercased()
                    self.measurementAttempts[key] = (self.measurementAttempts[key] ?? 0) + 1
                }
                for (filename, hash, facts, catalogHash) in measured {
                    self.diskLedger.recordMeasurement(filename: filename,
                                                      sha256: hash, facts: facts)
                    if let catalogHash = catalogHash {
                        // An image that already hashes to the catalog is current
                        // whoever downloaded it, so adopt its provenance instead
                        // of leaving it unknown and re-hashing it next launch.
                        self.diskLedger.adoptProvenanceIfCurrent(filename: filename,
                                                                 catalogSha256: catalogHash)
                    }
                }
                for key in failed {
                    self.measurementFailed.insert(key)
                    self.debugPrint("[Freshness] Could not measure '\(key)' - leaving it alone")
                }
                self.persistDiskLedger()
                self.measuringDisks = false
                self.reassessDiskFreshness()
            }
        }
    }

    /// Start every refresh the plan and the network permit.
    private func startAllowedRefreshes() {
        for disk in diskCatalog {
            guard refreshPlan(for: disk.filename) == .refreshNow else { continue }
            // One transfer per filename. downloadTasks has a single slot per
            // name, so a second start orphans the first task - which keeps
            // running, keeps its progress observation alive, and races the same
            // 49 MB destination in moveItem.
            guard downloadTasks[disk.filename] == nil else { continue }
            if case .downloading = downloadStates[disk.filename] ?? .notDownloaded { continue }
            debugPrint("[Freshness] Refreshing superseded image '\(disk.filename)' automatically")
            statusText = "Updating \(disk.name)…"
            downloadDiskFromSettings(disk, attemptsRemaining: 3, session: autoRefreshSession,
                                     expectedFacts: fileFacts(for: disk.filename))
        }
    }

    /// The Update control. Allowed on any network - that is what makes
    /// restricting the automatic half safe - and refused only where the download
    /// path would refuse it anyway.
    func updateDisk(_ disk: DownloadableDisk) {
        // Not while the emulator is running off it, however explicit the tap.
        // The download would land under a machine holding the old image, and the
        // next flush of saveDownloadedDisks() would write that old image straight
        // back over it - leaving the file superseded again while the ledger
        // records the new hash as its provenance, which is a lie that never
        // corrects itself.
        guard !isMounted(disk.filename) else {
            showError("Stop the emulator before updating \(disk.name).\n\nIt is in a drive right now, and the machine would write its own copy back over the new one.")
            return
        }
        let verdict = freshness(of: disk)
        guard DiskRefreshPolicy.allowsUserRequestedUpdate(for: verdict) else { return }
        guard downloadTasks[disk.filename] == nil else { return }
        downloadDiskFromSettings(disk, attemptsRemaining: 3, session: downloadSession,
                                 expectedFacts: nil)
    }

    /// Stop any unattended refresh of a disk that is about to be mounted.
    ///
    /// Called from the start path. The verdict that began a refresh was taken
    /// when nothing was running; pressing Play afterwards is the race, and this
    /// closes all but the milliseconds during which a transfer is already inside
    /// `moveItem`.
    ///
    /// This only works because the completion handler treats `URLError.cancelled`
    /// as terminal. Without that it takes the generic retry arm and re-enters one
    /// second later with two attempts left - so this would *restart* the refresh
    /// under the now-running machine rather than stopping it.
    private func cancelRefreshesForMountedDisks() {
        for slot in selectedDisks {
            guard let filename = slot?.filename, !filename.isEmpty else { continue }
            guard let task = downloadTasks[filename] else { continue }
            debugPrint("[Freshness] Cancelling refresh of '\(filename)' - it is about to be mounted")
            task.cancel()
            downloadTasks.removeValue(forKey: filename)
            downloadStates[filename] = isDiskDownloaded(filename) ? .downloaded : .notDownloaded
        }
    }

    /// The installed file's first eight hash digits and whether they match the
    /// catalog's, from the ledger's CACHED measurement.
    ///
    /// This used to be computed in `DiskDownloadRow.checksumStatus` by hashing
    /// the whole image inside a SwiftUI computed property that `body` reads, and
    /// SwiftUI re-evaluates `body` freely - 49 MB of reads per render for the
    /// combo, on a phone. The measurement is taken once, off the main thread, and
    /// stored against the size and modification time it was taken for, so a
    /// render is now a dictionary lookup.
    ///
    /// nil while nothing has been measured yet, which is the honest answer: the
    /// row shows the catalog's expected hash in grey rather than a colour it
    /// has not earned.
    func installedChecksumStatus(for disk: DownloadableDisk) -> (shown: String, matches: Bool)? {
        guard let facts = fileFacts(for: disk.filename),
              let record = diskLedger.record(for: disk.filename),
              DiskLedger.measurementApplies(record, to: facts),
              let measured = record.measuredSha256, measured.count >= 8 else { return nil }
        let shown = String(measured.prefix(8))
        guard let catalog = DiskLedger.normalizedHash(disk.sha256) else {
            // Nothing to compare against is not a green tick. The download path
            // refuses such an entry, so a file sitting here against one was
            // installed before that check existed.
            return (shown, false)
        }
        return (shown, measured == catalog)
    }

    /// Whether replacing this image would discard bytes the app did not download.
    /// The confirmation text depends on it, so the UI asks rather than guessing.
    func updateWouldDiscardLocalChanges(_ disk: DownloadableDisk) -> Bool {
        if case .offerUpdate(let lossy) = refreshPlan(for: disk.filename) { return lossy }
        return false
    }

    /// Whether this error is the automatic session's own restriction declining to
    /// spend the user's data, rather than a real failure.
    ///
    /// Deliberately not written as an exhaustive `switch` over
    /// `URLError.NetworkUnavailableReason`: the enum gained `.ultraConstrained`
    /// in iOS 26.1, `@unknown default` does not silence the exhaustiveness
    /// warning for it, and naming the case makes the file fail to compile against
    /// every older SDK. Comparing the cases this app can act on leaves both ends
    /// working.
    private static func refreshDeferral(from error: Error) -> DiskRefreshDeferral? {
        guard let urlError = error as? URLError,
              urlError.code == .notConnectedToInternet else { return nil }
        let reason = urlError.networkUnavailableReason
        if reason == .expensive { return .expensive }
        if reason == .constrained { return .constrained }
        if reason == .cellular { return .expensive }
        // No reason attached means an ordinary outage, which is a real failure and
        // belongs on the retry path.
        return nil
    }

    private func startWatchingNetwork() {
        guard !pathMonitorStarted else { return }
        pathMonitorStarted = true
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let condition = NetworkCondition(isReachable: path.status == .satisfied,
                                             isExpensive: path.isExpensive,
                                             isConstrained: path.isConstrained)
            DispatchQueue.main.async {
                guard let self = self, self.networkCondition != condition else { return }
                self.networkCondition = condition
                self.debugPrint("[Freshness] Path: reachable=\(condition.isReachable) expensive=\(condition.isExpensive) constrained=\(condition.isConstrained)")
                self.reassessDiskFreshness()
            }
        }
        // The documented first reading is this handler firing once at start.
        // NWPathMonitor.currentPath before start() is not documented to mean
        // anything, which is why networkCondition begins at .unknown.
        pathMonitor.start(queue: DispatchQueue.global(qos: .utility))
    }

    // MARK: - Choosing a RomWBW release

    /// Move to another release without being asked to by the picker.
    ///
    /// Used when the index no longer offers the release in play. Assigning to
    /// `romwbwVersion` from out here WOULD run its didSet, which is why the
    /// flag exists: the switch is performed once, by this function, with
    /// `refetch` under the caller's control - the index path is already in the
    /// middle of a fetch and must not start a second one.
    private func adoptRomWBWVersion(_ version: String, refetch: Bool) {
        guard version != romwbwVersion else { return }
        let previous = romwbwVersion
        isSwitchingRomWBWVersion = true
        romwbwVersion = version
        isSwitchingRomWBWVersion = false
        applyRomWBWVersionSwitch(from: previous, refetch: refetch)
    }

    /// Everything that has to change when the release does.
    ///
    /// **Nothing is deleted here, and nothing may be.** Every store this moves
    /// off is keyed per release and stays exactly where it was: the slots under
    /// `selectedDisks.v0.<previous>`, the boot string under
    /// `emulatorNvram.v0.<previous>`, the generation under
    /// `catalogGeneration.v0.<previous>`, the images in Documents/Disks under
    /// names carrying `<previous>`, and the saved catalog under
    /// `catalog-v0-<previous>.json`. 3.5.1 -> 3.6.0 -> 3.5.1 therefore comes
    /// back to precisely what it left. The old single `catalogVersion` key made
    /// exactly this sequence wipe the library twice, which is what
    /// per-(interface, release) scoping is for.
    ///
    /// The in-memory reset runs inside `isRestoringSelections` so that emptying
    /// the four slots does not persist four blanks - by the time this runs,
    /// `selectedDisks`'s didSet is already writing to the NEW release's key,
    /// and blanking that would destroy the slots the user set the last time
    /// they were on it.
    private func applyRomWBWVersionSwitch(from previous: String, refetch: Bool) {
        UserDefaults.standard.set(romwbwVersion, forKey: Self.romwbwVersionKey)
        debugPrint("[Release] RomWBW \(previous) -> \(romwbwVersion)")

        isRestoringSelections = true
        selectedDisks = Array(repeating: nil, count: 4)
        isRestoringSelections = false

        // The catalog and the picker's disk list belong to the release that is
        // leaving. Anything still in flight does not: a download in progress
        // writes the file it was started for, under the name it was started
        // with, and its ledger record is keyed on that name - so the download
        // dictionaries are deliberately left alone rather than cleared under a
        // task that is still polling them.
        catalogDocument = nil
        diskCatalog = []
        availableDisks = [DiskOption(name: "None", filename: "")]

        // The ROM belongs to the release that is leaving too: its filename
        // carries the release, and the file it names boots that release and no
        // other. Re-resolved here against an empty catalog, so the picker shows
        // this app's own ROM if this is its release and nothing at all if it is
        // not - and then again when the new catalog lands.
        restoreROMSelection()

        // Under a per-release key the boot string cannot simply be kept: it is
        // the other release's, and RomWBW would fail its checksum and silently
        // reset. Read this release's own.
        restoreBootString()

        statusText = "RomWBW \(romwbwVersion) selected"
        if refetch { fetchDiskCatalog() }
    }

    // MARK: - The release's ROM

    /// The release's own choice of ROM, as a row.
    ///
    /// The entry flagged `default: true`, and the first entry when a catalog
    /// flags none - `RomWBWCatalogDocument.defaultROM` decides that, so it is
    /// decided once and in the place that can be tested. Never `roms[0]` by
    /// position, and never "the one called emu_avw": the schema promises
    /// neither.
    private var defaultROMOption: ROMOption? {
        let options = availableROMs
        if let flagged = catalogDocument?.defaultROM,
           let match = options.first(where: { $0.romID == flagged.id }) {
            return match
        }
        return options.first
    }

    /// The ROM row the app would actually use: the selection while it is still
    /// one of this release's, and the release's default otherwise.
    ///
    /// The fallback is not politeness. `availableROMs` is rebuilt by every
    /// catalog fetch and every release switch and `selectedROM` is re-resolved
    /// on both, but a fetch answering late - or a view read in between - can
    /// see a selection belonging to the release that just left. Falling back to
    /// this release's default is how that shows as the right ROM instead of
    /// resolving to another release's file.
    private var romInPlay: ROMOption? {
        availableROMs.first(where: { $0 == selectedROM }) ?? defaultROMOption
    }

    /// Where the ROM for the release in play is, or what has to happen first.
    enum ROMResolution {
        /// Present and checked. These exact bytes, from this option - the
        /// caller loads what was hashed rather than re-reading the file, so
        /// nothing can change between the check and the load.
        case ready(Data, ROMOption)
        /// Not usable yet, but the catalog says where it is and what it must
        /// hash to. `replacing` is why the copy already on this device was
        /// rejected, and nil when there simply is no copy.
        case needsDownload(ROMOption, DownloadableDisk, replacing: String?)
        /// Nothing to load and nothing to fetch. The text is a finished
        /// sentence naming the release, the file where there is one, and why.
        case unavailable(String)
    }

    /// Find the release's ROM and check it, every time, before it is used.
    ///
    /// Not cached, deliberately: 512 KB of SHA-256 is nothing next to a boot,
    /// and a ROM that verified when it landed can be truncated afterwards by a
    /// full volume, a restore from a backup or a container edited by hand. A
    /// corrupt ROM is the one file whose damage gives a guest that boots to
    /// nothing at all, with no message to work from.
    ///
    /// There is no arm that returns the bundled ROM for another release. That
    /// is the whole point of the exercise: it would pair 3.6.0 disks with a
    /// 3.5.1 HBIOS, print *** WARNING: HBIOS/CBIOS Version Mismatch *** in the
    /// middle of a boot, and do it invisibly.
    private func resolveROM() -> ROMResolution {
        guard let option = romInPlay else {
            return .unavailable(romProblemText(
                file: nil,
                reason: "its catalog has not been read yet,"
                    + " or it publishes no ROM this app can load"))
        }

        // The bundled ROM, when it is the whole list - no catalog has been read
        // yet, or the one that has been read publishes no roms[]. It boots the
        // release it declares and no other.
        guard let entry = option.catalogEntry else {
            guard let release = Self.bundledROMRelease, release == romwbwVersion,
                  let url = Self.bundledROMURL,
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                return .unavailable(romProblemText(
                    file: option.filename,
                    reason: "the ROM this app carries is RomWBW"
                        + " \(Self.bundledROMRelease ?? "an unreadable release"), not"
                        + " \(romwbwVersion), and no catalog has been fetched to get one from"))
            }
            return .ready(data, option)
        }

        guard let document = catalogDocument else {
            // The catalog went away between building the row and resolving it.
            // Nothing to fetch from: base_url lives in the document.
            return .unavailable(romProblemText(
                file: entry.filename,
                reason: "the catalog it comes from is no longer loaded"))
        }

        // The bundled image standing in for a published ROM, by hash. Same
        // check a downloaded copy gets, against the same catalog fields: the
        // bundled 3.5.1 emu_avw IS emu_avw-v0-3.5.1.rom, byte for byte
        // (524,288 bytes, c7abc580…), so the release this app ships with needs
        // no network on a first launch.
        //
        // By hash and not by "same release, same id", deliberately. If
        // romwbw_disks ever republishes 3.5.1's emu_avw with different bytes,
        // this stops matching and the published image is FETCHED - which is the
        // entire point of reading the ROM from the catalog, and it would be
        // undone by an arm that shrugged and booted the older copy. What that
        // costs is the offline first launch of a device that has never fetched
        // it, on a release whose ROM has been rebuilt. Nothing published today
        // is in that state, and a rebuild is a decision someone makes upstream
        // rather than something that drifts.
        if let facts = Self.bundledROMFacts,
           entry.problem(byteCount: facts.size, sha256: facts.sha256) == nil,
           let url = Self.bundledROMURL,
           let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
            return .ready(data, option)
        }

        let asset = Self.romAsset(entry, from: document)
        let url = downloadsDirectory.appendingPathComponent(entry.filename)
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return .needsDownload(option, asset, replacing: nil)
        }

        if let problem = entry.problem(byteCount: Int64(data.count),
                                       sha256: Self.sha256Hex(data)) {
            // Fetched again ONCE, and then reported. The file is not deleted
            // and cannot be: the download path stages into `<name>.incoming`
            // and only replaces the destination with bytes that already
            // verified, so a failed re-fetch leaves the user's copy exactly
            // where it was. Retrying for ever instead would spend a metered
            // connection on a catalog entry that is simply wrong.
            if romRefetched.contains(CatalogMigration.fold(entry.filename)) {
                return .unavailable(romProblemText(
                    file: entry.filename,
                    reason: "it is still wrong after being fetched again - \(problem)."
                        + " The copy on this device has been left exactly where it is"))
            }
            return .needsDownload(option, asset, replacing: problem)
        }

        return .ready(data, option)
    }

    /// The ROM as the download path's own type.
    ///
    /// `downloadDiskFromSettings` is the one verified transfer in this app. It
    /// refuses a catalog filename that is not a plain leaf, hashes the temp
    /// file against the catalog's sha256 BEFORE anything replaces what is on
    /// disk, stages into `<name>.incoming` and swaps, retries three times, and
    /// reports progress the way every other download does. Writing a second
    /// copy of all that for a 512 KB file would be a second thing to get wrong.
    ///
    /// What it does that a ROM has no use for is inert rather than incorrect:
    /// `refreshAvailableDisks()` lists `.img` files only, so a `.rom` never
    /// appears as a disk, and the ledger record it writes is provenance for a
    /// file nothing ever asks the ledger about.
    private static func romAsset(_ entry: CatalogROM,
                                 from document: RomWBWCatalogDocument) -> DownloadableDisk {
        DownloadableDisk(
            catalogID: entry.id,
            filename: entry.filename,
            name: entry.displayName,
            description: "RomWBW \(document.romwbwVersion ?? "") ROM",
            url: document.assetURL(for: entry.filename),
            sizeBytes: entry.size ?? 0,
            // The catalog carries no license field for a ROM, and this one is
            // never displayed - the ROM rows are not disk rows. "Unknown" is
            // what the disk path already puts when a document does not say;
            // what the ROM actually is licensed under is in
            // docs/ROM_ATTESTATION.md.
            license: "Unknown",
            sha256: entry.sha256,
            defaultSlot: nil)
    }

    /// Re-resolve the ROM choice against the release in play.
    ///
    /// Called wherever `availableROMs` can have changed underneath it: at
    /// launch, on every adopted catalog, and after a release switch. A picker
    /// whose selection matches no row renders blank, and the rows are catalog
    /// data now - they arrive over the network and they change with the
    /// release.
    private func restoreROMSelection() {
        let options = availableROMs
        guard !options.isEmpty else {
            // Nothing to offer. Deliberately not left pointing at the previous
            // release's ROM: `start()` decides from this selection, and a stale
            // one is a ROM for a machine that is no longer selected.
            selectedROM = nil
            return
        }
        if let remembered = UserDefaults.standard.string(forKey: Self.selectedROMIDKey),
           let match = options.first(where: { $0.answersTo(remembered) }) {
            selectedROM = match
            return
        }
        selectedROM = defaultROMOption
    }

    /// Put the release's ROM in place, then say whether the machine may start.
    ///
    /// `true` means the ROM for the release in play is on this device and its
    /// bytes have been checked against the catalog. `false` means the machine
    /// does not start: the user has been told which release, which file and
    /// why, and offered the release this app carries a ROM for. There is
    /// deliberately no third answer.
    ///
    /// This is the part that differs from a disk. A missing disk is an empty
    /// drive; a missing ROM is either nothing to execute or - if the bundled
    /// one were quietly substituted - a guest that misbehaves and says so in a
    /// warning most people will scroll past.
    private func prepareROM(then completion: @escaping (Bool) -> Void) {
        switch resolveROM() {
        case .ready(_, let option):
            debugPrint("[ROM] \(option.filename) is here and verified")
            completion(true)

        case .needsDownload(let option, let asset, let replacing):
            // The same overlay a disk download puts up. 512 KB is quick, but on
            // a bad connection it is the one thing standing between the user
            // and a booting machine, so it must not look like a hang.
            isDownloading = true
            downloadingDiskName = "\(option.name) ROM for RomWBW \(romwbwVersion)"
            downloadingProgress = 0
            fetchROM(option: option, asset: asset, replacing: replacing) { [weak self] ok in
                self?.isDownloading = false
                self?.downloadingDiskName = ""
                completion(ok)
            }

        case .unavailable(let reason):
            reportROMProblem(reason)
            completion(false)
        }
    }

    /// Fetch one ROM and check what landed.
    private func fetchROM(option: ROMOption, asset: DownloadableDisk, replacing: String?,
                          then completion: @escaping (Bool) -> Void) {
        if let rejected = replacing {
            // Once. See resolveROM.
            romRefetched.insert(CatalogMigration.fold(asset.filename))
            debugPrint("[ROM] \(asset.filename) rejected (\(rejected)); fetching it again")
        }
        debugPrint("[ROM] Fetching \(asset.url)")
        statusText = "Downloading \(asset.name) ROM..."

        downloadDiskFromSettings(asset, attemptsRemaining: 3, session: downloadSession,
                                 expectedFacts: nil)
        waitForDownloadCompletion(asset.filename) { [weak self] transferred in
            guard let self = self else { completion(false); return }
            guard transferred else {
                var detail = "the download did not finish"
                if case .error(let message)? = self.downloadStates[asset.filename] {
                    detail = message
                }
                self.reportROMProblem(self.romProblemText(file: asset.filename, reason: detail))
                completion(false)
                return
            }
            // What landed is checked before it runs, by the same path that
            // checks a copy that was already here. A transfer that reports
            // success and a file that verifies are two different facts.
            switch self.resolveROM() {
            case .ready:
                // The one re-fetch is spent per fault, not per launch. These
                // bytes verify, so the fault that provoked the re-fetch is
                // over; leaving the mark standing would make the NEXT damage to
                // this file - a restore, a full volume, hours later in the same
                // session - report itself as "still wrong after being fetched
                // again", which it would not be, and refuse the fetch that
                // would have fixed it.
                self.romRefetched.remove(CatalogMigration.fold(asset.filename))
                self.statusText = "ROM ready: \(asset.name)"
                completion(true)
            case .unavailable(let reason):
                self.reportROMProblem(reason)
                completion(false)
            case .needsDownload(_, _, let stillWrong):
                self.reportROMProblem(self.romProblemText(
                    file: asset.filename,
                    reason: stillWrong ?? "it did not arrive"))
                completion(false)
            }
        }
    }

    /// Fetch the release's ROM now, from Settings, rather than when Play is
    /// pressed. Same transfer, same verification, same messages.
    func downloadSelectedROM() {
        switch resolveROM() {
        case .ready(_, let option):
            statusText = "ROM ready: \(option.name)"
        case .needsDownload(let option, let asset, let replacing):
            fetchROM(option: option, asset: asset, replacing: replacing) { _ in }
        case .unavailable(let reason):
            reportROMProblem(reason)
        }
    }

    /// The sentence a ROM failure gets: the release, the file, the reason, and
    /// the honest way out.
    ///
    /// Never "starting anyway" and never "using the bundled one instead": if
    /// the ROM cannot be had, the machine does not start on that release.
    private func romProblemText(file: String?, reason: String) -> String {
        let named = file.map { "\($0) " } ?? ""
        var text = "The RomWBW \(romwbwVersion) ROM \(named)cannot be used: "
            + CatalogTransfer.sentence(reason)
        if let fallback = bundledROMFallbackRelease {
            text += " Try again when you have a connection, or switch back to RomWBW"
                + " \(fallback), which this app carries its own ROM for."
        } else {
            text += " Try again when you have a connection, or choose another ROM in Settings."
        }
        return text
    }

    private func reportROMProblem(_ reason: String) {
        romProblemMessage = reason
        showingROMProblem = true
        statusText = "Error: no ROM for RomWBW \(romwbwVersion)"
        debugPrint("[ROM] \(reason)")
    }

    /// The release this app carries its own ROM for, offered as the way out of
    /// a ROM that cannot be fetched. Nil when that IS the release in play.
    var bundledROMFallbackRelease: String? {
        guard let bundled = Self.bundledROMRelease, bundled != romwbwVersion else { return nil }
        return bundled
    }

    /// Take that offer.
    func switchToBundledROMRelease() {
        guard let bundled = bundledROMFallbackRelease else { return }
        guard !isRunning else {
            showError("Stop the emulator before changing the RomWBW release.")
            return
        }
        adoptRomWBWVersion(bundled, refetch: true)
    }

    /// One line for Settings about where the selected ROM's bytes come from.
    ///
    /// Cheap on purpose - file existence, not a hash. It is read on every
    /// redraw of that Form, and a wrong-looking line here costs a glance while
    /// a corrupt file costs a boot: the hash is what `start()` does.
    var romStatusDescription: String {
        guard let option = romInPlay else {
            return "No ROM for RomWBW \(romwbwVersion) yet - the catalog has not been read."
        }
        guard let entry = option.catalogEntry else {
            return "\(option.filename) - the ROM in this app,"
                + " for RomWBW \(option.romwbwRelease ?? "an unreadable release")."
        }
        if let facts = Self.bundledROMFacts,
           entry.problem(byteCount: facts.size, sha256: facts.sha256) == nil {
            return "\(entry.filename) - this app already carries these exact bytes,"
                + " so there is nothing to download."
        }
        if isDiskDownloaded(entry.filename) {
            return "\(entry.filename) - downloaded, and checked again every time it is used."
        }
        let size = entry.size.map { "\($0 / 1024) KB" } ?? "a ROM"
        return "\(entry.filename) - \(size) to download."
            + " Press Play and it is fetched before the machine starts."
    }

    /// Whether Settings should offer to fetch it now. Same cheap test.
    var romNeedsDownload: Bool {
        guard let entry = romInPlay?.catalogEntry else { return false }
        if let facts = Self.bundledROMFacts,
           entry.problem(byteCount: facts.size, sha256: facts.sha256) == nil { return false }
        return !isDiskDownloaded(entry.filename)
    }

    /// How far the ROM download has got, or nil when none is running.
    var romDownloadProgress: Double? {
        guard let entry = romInPlay?.catalogEntry,
              case .downloading(let progress)? = downloadStates[entry.filename] else { return nil }
        return progress
    }

    /// What to say when the ROM that would boot is not the release's own, or
    /// nil when they agree.
    ///
    /// It should be unreachable in normal operation now, and it is kept for the
    /// case where it is not: someone whose picker is showing the bundled ROM
    /// while another release is selected, because no catalog has been read yet.
    /// Deleting it would take away the only warning such a user gets before
    /// RomWBW prints *** WARNING: HBIOS/CBIOS Version Mismatch *** in the
    /// middle of a boot.
    ///
    /// It no longer means "the bundled ROM's release is not the release in
    /// play". That stopped being a mismatch the moment this app could fetch the
    /// release's own ROM, and leaving it saying so would have turned the one
    /// warning that matters into a line every 3.6.0 user learns to ignore.
    var romReleaseMismatchNotice: String? {
        guard let option = romInPlay,
              let release = option.romwbwRelease,
              release != romwbwVersion else { return nil }
        return "The ROM on offer (\(option.filename)) is RomWBW \(release), and the disks "
            + "in play are RomWBW \(romwbwVersion)'s. That pair boots with "
            + "*** WARNING: HBIOS/CBIOS Version Mismatch ***, so the machine will not be "
            + "started on it."
    }

    // MARK: - Disk catalog: the two-hop fetch

    /// Fetch the release index, then the selected release's catalog.
    ///
    /// Two hops, one compiled-in URL, and nothing built from a tag. The index
    /// says which releases exist and where each catalog is; the catalog says
    /// where its assets are. Either hop can fail on its own, and which one did
    /// is the difference between "this device cannot reach GitHub" and "the
    /// release list is fine and one asset behind it is missing" - so the two
    /// are reported separately rather than as one string.
    ///
    /// Any failure falls back to the cache for the release in play, because
    /// this arm is reached exactly when the network is down: emptying the
    /// catalog would leave `start()` refusing to boot (it rejects an empty
    /// catalog before it ever checks whether anything needs downloading) and
    /// would drop the user's own imported images with it, since
    /// `refreshAvailableDisks()` is the only thing that scans the directory.
    func fetchDiskCatalog() {
        catalogLoading = true
        catalogFailure = nil

        guard let url = URL(string: Self.indexURL) else {
            // A compiled-in constant that is not a URL is a build mistake, not
            // a condition - but it must not take the app down with it.
            debugPrint("[Catalog] Invalid index URL")
            continueFromCachedIndex(indexProblem: "the compiled-in index URL is not a URL")
            return
        }

        debugPrint("[Catalog] Fetching index: \(Self.indexURL)")

        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }

                if let problem = CatalogTransfer.problem(
                        errorDescription: error?.localizedDescription,
                        statusCode: (response as? HTTPURLResponse)?.statusCode,
                        byteCount: data?.count) {
                    self.debugPrint("[Catalog] Index fetch failed: \(problem)")
                    self.continueFromCachedIndex(indexProblem: problem)
                    return
                }

                guard let data = data,
                      let index = try? JSONDecoder().decode(RomWBWIndex.self, from: data) else {
                    self.debugPrint("[Catalog] Index did not decode")
                    self.continueFromCachedIndex(
                        indexProblem: "the release list could not be read")
                    return
                }

                self.debugPrint("[Catalog] Index lists \(index.romwbwVersions.count) release(s)")
                self.saveIndexToCache(data)
                self.adoptIndex(index, indexProblem: nil)
            }
        }.resume()
    }

    /// The index hop failed. Use the saved one if there is a usable one.
    ///
    /// A saved release list is worth reading even when it is stale: the
    /// catalog hop below it may well succeed from ITS cache, and the picker
    /// then still shows every release rather than collapsing to the one in
    /// play. `indexProblem` is carried all the way through so that a run which
    /// ends up showing a perfectly good catalog can still say the list behind
    /// it is the saved one.
    private func continueFromCachedIndex(indexProblem: String) {
        if let data = try? Data(contentsOf: indexCacheURL),
           let index = try? JSONDecoder().decode(RomWBWIndex.self, from: data) {
            debugPrint("[Catalog] Using the cached release list")
            adoptIndex(index, indexProblem: indexProblem)
            return
        }
        catalogFailure = CatalogFailure(stage: .index,
                                        detail: indexProblem,
                                        servedFromCache: false)
        loadCachedCatalog()
    }

    /// Decide which release to be on, then fetch its catalog.
    private func adoptIndex(_ index: RomWBWIndex, indexProblem: String?) {
        // Ask the core, per entry, rather than comparing against a constant:
        // there is no compile-time pin left, and a build can carry a core that
        // is newer or older than the releases this index lists.
        let offered = RomWBWIndex.offered(index.romwbwVersions) { ver, upd in
            RomWBWEmulator.supportsRomWBW(ver: ver, upd: upd)
        }

        guard !offered.isEmpty else {
            // A real condition, and one worth saying out loud: this build's
            // core can run none of the releases this repository publishes. Not
            // a network failure, not fixed by retrying, and emphatically not a
            // reason to fall back to a hardcoded tag.
            debugPrint("[Catalog] No published release is supported by this core")
            romwbwVersions = [RomWBWIndexEntry.placeholder(romwbwVersion: romwbwVersion)]
            catalogFailure = CatalogFailure(
                stage: .noSupportedRelease,
                detail: "It runs RomWBW \(RomWBWEmulator.romWBWReleases()); "
                    + "the catalog publishes none of those.",
                servedFromCache: false)
            loadCachedCatalog()
            return
        }

        romwbwVersions = offered

        guard let entry = RomWBWIndex.preferred(among: offered,
                                                keeping: romwbwVersion,
                                                bundledROMRelease: Self.bundledROMRelease) else {
            loadCachedCatalog()
            return
        }

        if entry.romwbwVersion != romwbwVersion {
            // The release in play is no longer published, or was never
            // supported by this core. Move, but do not re-fetch from inside the
            // move - this call is already the fetch, and the catalog hop below
            // is the one that finishes it.
            debugPrint("[Catalog] RomWBW \(romwbwVersion) is not offered; moving to \(entry.romwbwVersion)")
            adoptRomWBWVersion(entry.romwbwVersion, refetch: false)
        }

        fetchCatalog(for: entry, indexProblem: indexProblem)
    }

    /// Fetch one release's catalog, verify it against the index, and adopt it.
    private func fetchCatalog(for entry: RomWBWIndexEntry, indexProblem: String?) {
        let version = entry.romwbwVersion

        guard let urlString = entry.catalogURL, let url = URL(string: urlString) else {
            failCatalogHop(version: version,
                           detail: "the release list gives it no catalog URL",
                           indexProblem: indexProblem)
            return
        }

        debugPrint("[Catalog] Fetching catalog: \(urlString)")

        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }

                // A response for a release that is no longer in play is
                // DROPPED, not applied. The picker moves `romwbwVersion` the
                // instant it is tapped and starts its own fetch, but this
                // request is already out and answers minutes later on a slow
                // connection. Everything below writes state that belongs to
                // one release - the disk list, the cache, the slots, and the
                // generation that decides what gets DELETED - so adopting
                // 3.5.1's catalog while 3.6.0 is selected would compare
                // 3.5.1's generation against 3.6.0's stored one and clear the
                // images 3.5.1 can hand back, for a change neither release
                // made. Saying nothing is right too: the fetch the switch
                // started owns the status line now.
                guard self.romwbwVersion == version else {
                    self.debugPrint("[Catalog] Dropping the RomWBW \(version) response;"
                                    + " \(self.romwbwVersion) is in play now")
                    return
                }

                if let problem = CatalogTransfer.problem(
                        errorDescription: error?.localizedDescription,
                        statusCode: (response as? HTTPURLResponse)?.statusCode,
                        byteCount: data?.count) {
                    self.debugPrint("[Catalog] Catalog fetch failed: \(problem)")
                    self.failCatalogHop(version: version, detail: problem,
                                        indexProblem: indexProblem)
                    return
                }

                guard let data = data else {
                    self.failCatalogHop(version: version, detail: "the response was empty",
                                        indexProblem: indexProblem)
                    return
                }

                // Verified BEFORE it is parsed, against the size and checksum
                // the index carries. The index is the only document this app
                // takes on trust, and it exists so that the big one need not
                // be. A truncated or substituted catalog parses to a SHORT disk
                // list rather than to an error, and a short list is what makes
                // start() refuse to boot a slot it can no longer resolve.
                if let problem = entry.payloadProblem(byteCount: data.count,
                                                      sha256: Self.sha256Hex(data)) {
                    self.debugPrint("[Catalog] Catalog rejected: \(problem)")
                    self.failCatalogHop(version: version, detail: problem,
                                        indexProblem: indexProblem)
                    return
                }

                guard let document = try? JSONDecoder()
                        .decode(RomWBWCatalogDocument.self, from: data) else {
                    self.failCatalogHop(version: version,
                                        detail: "the catalog could not be read",
                                        indexProblem: indexProblem)
                    return
                }

                // Right bytes, wrong document: an asset uploaded under the
                // wrong tag, or a v1 catalog published at a v0 URL. The
                // checksum cannot catch either - it says only that these are
                // the bytes the index pointed at.
                if let problem = entry.documentProblem(
                        document, expectedInterface: CatalogMigration.interface) {
                    self.debugPrint("[Catalog] Catalog rejected: \(problem)")
                    self.failCatalogHop(version: version, detail: problem,
                                        indexProblem: indexProblem)
                    return
                }

                self.adoptCatalog(document, data: data, version: version,
                                  indexProblem: indexProblem)
            }
        }.resume()
    }

    /// Put a verified catalog into force.
    private func adoptCatalog(_ document: RomWBWCatalogDocument,
                              data: Data,
                              version: String,
                              indexProblem: String?) {
        catalogLoading = false

        let disks = Self.downloadableDisks(from: document)
        let generationText = document.generation.map { String($0) } ?? "unstated"
        debugPrint("[Catalog] Parsed \(disks.count) disks, generation \(generationText)")
        for disk in disks {
            debugPrint("[Catalog]   - '\(disk.filename)' (\(disk.name))")
        }

        guard !disks.isEmpty else {
            // A verified catalog that lists nothing is a publishing mistake,
            // not a network problem, and adopting it would empty the picker.
            failCatalogHop(version: version, detail: "it lists no disks",
                           indexProblem: indexProblem)
            return
        }

        // Whether the generation moved, and only then, delete the downloaded
        // images this catalog can hand BACK. The new catalog's names, not the
        // old one's: a file the new catalog does not list cannot be
        // re-downloaded from it, which is exactly the test for whether deleting
        // it is recoverable.
        let notice = checkCatalogGenerationAndInvalidate(
            generation: document.generation,
            catalogFilenames: Set(disks.map { $0.filename }),
            for: version)

        catalogDocument = document
        diskCatalog = disks
        saveCatalogToCache(data, for: version)
        // The ROM list is this document's `roms[]`, so the remembered choice
        // has to be resolved against it - before restoreDiskSelections(), which
        // ends by claiming the machine is ready to play.
        restoreROMSelection()
        refreshAvailableDisks()
        restoreDiskSelections()
        // AFTER restoreDiskSelections, which ends by setting statusText to
        // "Ready - Press Play to start" and so silently swallowed anything set
        // before it. The status line was the only trace of an invalidation the
        // user could see while the alert was being eaten too.
        if let notice = notice { statusText = notice }

        // A good catalog behind a stale release list is a note, not a failure:
        // everything on screen works, and what the user cannot see is whether a
        // release has been added since. Saying so at the same volume as "no
        // catalog at all" is how a warning stops being read.
        if let indexProblem = indexProblem {
            catalogFailure = CatalogFailure(stage: .index,
                                            detail: indexProblem,
                                            servedFromCache: true)
        }

        // With the new catalog in force, ask which installed images it has
        // moved on from. This is the arm that reaches a device already holding
        // a superseded image.
        reassessDiskFreshness()
    }

    /// The catalog hop failed. Record which release it was for, then fall back.
    ///
    /// When the index hop had already failed, that one is reported as the
    /// stage - it is the first thing that went wrong and the one a user can
    /// usually act on - with what happened underneath it spelled out in the
    /// detail. Reporting only the second would say "the release list loaded"
    /// about a list that came off the disk, which is the sort of small lie that
    /// sends someone looking in the wrong place.
    private func failCatalogHop(version: String, detail: String, indexProblem: String?) {
        catalogLoading = false
        if let indexProblem = indexProblem {
            catalogFailure = CatalogFailure(
                stage: .index,
                detail: CatalogTransfer.sentence(indexProblem)
                    + " The saved list's RomWBW \(version) catalog did not load either: "
                    + CatalogTransfer.sentence(detail),
                servedFromCache: false)
        } else {
            catalogFailure = CatalogFailure(stage: .catalog(romwbwVersion: version),
                                            detail: detail,
                                            servedFromCache: false)
        }
        loadCachedCatalog()
    }

    /// The catalog's disks, as the rest of the app wants them.
    ///
    /// The URL is absolute and computed once, here, from the document's own
    /// `base_url` - which ends in "/", so nothing appends a separator. That is
    /// the one line where the three clients used to disagree.
    private static func downloadableDisks(
            from document: RomWBWCatalogDocument) -> [DownloadableDisk] {
        document.diskEntries.map { entry in
            DownloadableDisk(catalogID: entry.id,
                             filename: entry.filename,
                             name: entry.name,
                             description: entry.description ?? "",
                             url: document.assetURL(for: entry.filename),
                             sizeBytes: entry.size ?? 0,
                             license: entry.license ?? "Unknown",
                             sha256: entry.sha256,
                             defaultSlot: entry.defaultSlot)
        }
    }

    /// SHA-256 of a document, as lower-case hex.
    ///
    /// Data, not a file: these documents are kilobytes and are hashed before
    /// they are written anywhere, which is the whole point - the check has to
    /// happen before anything acts on them. `sha256OfFile` is the mapped
    /// equivalent for the 49 MB images.
    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Check whether this RomWBW release's catalog generation changed and, if
    /// it did, invalidate the downloaded disks the catalog is able to hand back.
    ///
    /// **`generation` is not the old `<disks version="13">` attribute, and the
    /// two must never share a key.** `generation` advances only when a
    /// release's artifacts actually change, and it is scoped per RomWBW release
    /// upstream (romwbw_disks docs/CATALOG_SCHEMA.md §4). The XML this app used
    /// to fetch carried 13 in an attribute that meant something else; the v0
    /// catalogs are at generation 1. Had the two shared a key, the first v0
    /// fetch would have seen 13 ≠ 1, called `deleteCatalogDisks(named:)` with
    /// the v0 filenames, and deleted the entire library the storage migration
    /// had just finished renaming into those exact names - with an alert saying
    /// it was intentional. The old "catalogVersion" key is therefore orphaned
    /// rather than carried across, so this one starts empty on every device and
    /// the first v0 fetch takes the first-run branch below.
    ///
    /// nil generation means "this document does not say", and the only honest
    /// response to that is to delete nothing.
    ///
    /// The key is per (interface, RomWBW release) for the same reason the
    /// generation is: a user switching 3.5.1 → 3.6.0 → 3.5.1 is not making
    /// three catalog changes and must not have their library cleared twice. One
    /// shared key across releases re-creates that loop exactly, and it would
    /// not show up in testing today, because both published releases happen to
    /// be at generation 1.
    ///
    /// **`catalogFilenames` is the whole safety property of this function.** The
    /// generation moving means the images behind those names may have
    /// changed, so a stale copy has to go and be fetched again. It says nothing
    /// about a file the catalog does not name — a disk the user imported through
    /// Files, or one `createNewDisk` made in the app — and those cannot be
    /// re-downloaded from anywhere. This used to delete every `.img` in
    /// `Documents/Disks` regardless, so a catalog bump destroyed a user's own
    /// disks, unprompted, on their next launch, with an alert afterwards.
    ///
    /// The names come from the **new** catalog rather than the stored one,
    /// because "can this be given back" is a question about the catalog that is
    /// about to be in force. An image dropped from the catalog in the same bump
    /// is therefore spared, which is right: nothing can re-fetch it either.
    ///
    /// This is the least destructive of the options considered and forecloses
    /// none of the others — a confirmation step or copy-on-write can still be
    /// added in front of it; both are open under "User Data Persistence" in
    /// KNOWN_PROBLEMS.md. What it cannot do is help the builds already in
    /// service: the App Store serves 1.4.9 (builds 36/37), those fetch the
    /// catalog from `releases/latest/download/` rather than from a pinned tag,
    /// and they carry the old loop. That is why the release order still matters
    /// and why `--prerelease` is load-bearing; see docs/DISK_W8FIX_RUNBOOK.md,
    /// and re-measure what the Store serves with tools/check-store-version.sh
    /// rather than trusting the number in this comment.
    /// Returns the status-line text for what it did, for the caller to apply
    /// after restoreDiskSelections - which ends by overwriting statusText.
    @discardableResult
    private func checkCatalogGenerationAndInvalidate(generation: Int?,
                                                    catalogFilenames: Set<String>,
                                                    for version: String) -> String? {
        // A catalog document that carries no generation cannot say whether
        // anything changed, and the only honest response to "I do not know" is
        // to delete nothing. The unsuffixed "catalogVersion" key the XML path
        // used to write is deliberately left where it is, unread: a user who
        // downgrades this app should find it as they left it.
        guard let generation = generation else { return nil }

        let key = catalogGenerationKey(for: version)
        let newVersion = String(generation)
        let storedVersion = UserDefaults.standard.string(forKey: key) ?? ""

        print("[Catalog] Checking generation: stored='\(storedVersion)' new='\(newVersion)'")

        if storedVersion.isEmpty {
            // First run - just store the generation
            print("[Catalog] First run, storing catalog generation: '\(newVersion)'")
            UserDefaults.standard.set(newVersion, forKey: key)
            return nil
        } else if storedVersion != newVersion {
            print("[Catalog] ⚠️ GENERATION CHANGED from '\(storedVersion)' to '\(newVersion)'")
            let (cleared, kept) = deleteCatalogDisks(named: catalogFilenames)
            UserDefaults.standard.set(newVersion, forKey: key)

            // Say nothing at all when nothing was cleared. A user who has only
            // ever imported their own disks has had nothing done to them, and an
            // alert claiming otherwise is its own small harm.
            guard cleared > 0 else {
                print("[Catalog] Nothing to clear (\(kept) disk(s) not in the catalog, kept)")
                return nil
            }

            var message = "The disk catalog has been updated. "
            message += cleared == 1
                ? "1 downloaded disk was cleared and needs to be downloaded again."
                : "\(cleared) downloaded disks were cleared and need to be downloaded again."
            if kept > 0 {
                message += kept == 1
                    ? "\n\n1 disk that is not in the catalog — one you imported or created — was left alone."
                    : "\n\n\(kept) disks that are not in the catalog — ones you imported or created — were left alone."
            }
            showError(message, title: "Disk Catalog Updated")
            return "Disk catalog updated - \(cleared) disk(s) need redownload"
        } else {
            print("[Catalog] Generation unchanged: '\(newVersion)'")
        }
        return nil
    }

    /// Show the saved catalog for the release in play.
    ///
    /// Reached whenever either hop fails, which in practice means the network
    /// is down - so this is the arm that decides whether the app is usable
    /// offline. It is: the cache holds the WHOLE document, `base_url` included,
    /// so every URL in it is the one it was fetched with and a cached catalog
    /// is self-consistent by construction.
    ///
    /// That is what retired the old salvage branch. The XML cache held one
    /// tag's `<sha256>` values while the parser rebuilt every URL from the tag
    /// the BUILD was pinned to, so a cache from a different pin paired the
    /// wrong hashes with the right URLs, and the only safe response was to
    /// throw away every entry whose file was not already downloaded. Nothing
    /// can pair them wrongly now, and the cache filename carries the release,
    /// so 3.5.1's and 3.6.0's cannot overwrite each other either.
    ///
    /// The generation is deliberately NOT consulted here. Deleting a
    /// downloaded image is a decision to take from a freshly fetched, verified
    /// document - never from a copy of one this app already acted on.
    private func loadCachedCatalog() {
        catalogLoading = false

        let cacheURL = catalogCacheURL(for: romwbwVersion)
        guard let data = try? Data(contentsOf: cacheURL),
              let document = try? JSONDecoder().decode(RomWBWCatalogDocument.self, from: data)
        else {
            // Nothing saved for this release. Leave whatever failure the caller
            // recorded in place - it says which hop failed, which this does not
            // know - and only speak up when nothing else has.
            debugPrint("[Catalog] No usable cache for RomWBW \(romwbwVersion)")
            if catalogFailure == nil {
                catalogFailure = CatalogFailure(
                    stage: .catalog(romwbwVersion: romwbwVersion),
                    detail: "No saved copy on this device. Connect to the internet to download it.",
                    servedFromCache: false)
            }
            showError(catalogFailure?.displayText
                      ?? "No disk catalog available. Connect to internet to download.")
            return
        }

        let disks = Self.downloadableDisks(from: document)
        guard !disks.isEmpty else {
            // Saved, decodable, and empty. Say so rather than showing an empty
            // list with no explanation: start() refuses to boot on an empty
            // catalog, and "no disks and no reason" is the state that gets
            // reported as "the app does nothing".
            debugPrint("[Catalog] Cached catalog for RomWBW \(romwbwVersion) lists no disks")
            if catalogFailure == nil {
                catalogFailure = CatalogFailure(
                    stage: .catalog(romwbwVersion: romwbwVersion),
                    detail: "The saved copy on this device lists no disks.",
                    servedFromCache: false)
            }
            return
        }

        debugPrint("[Catalog] Using the cached RomWBW \(romwbwVersion) catalog, \(disks.count) disks")
        catalogDocument = document
        diskCatalog = disks
        // The saved catalog names the release's ROMs as well as its disks, so
        // the ROM picker is right offline too - and, on the release this app
        // bundles a ROM for, the bundled bytes still satisfy that entry and
        // nothing has to be fetched.
        restoreROMSelection()
        refreshAvailableDisks()
        restoreDiskSelections()
        // Safe here, unlike in the old salvage branch: these are the sha256
        // values this release actually publishes, so judging installed images
        // against them is the same question a live fetch would ask.
        reassessDiskFreshness()

        if let failure = catalogFailure, failure.stage != .noSupportedRelease {
            // Something IS on screen, so downgrade the failure to a note that
            // says which half of it is stale. Not for .noSupportedRelease: a
            // cached catalog does not make "this build's core can run none of
            // the published releases" any less true, and it is the one
            // condition here that a retry cannot fix.
            catalogFailure = CatalogFailure(stage: failure.stage,
                                            detail: failure.detail,
                                            servedFromCache: true)
        }
    }

    /// Save the verified catalog bytes for one release.
    ///
    /// The release is in the FILENAME - catalog-v0-3.5.1.json - not in a
    /// UserDefaults stamp beside it. A stamp can drift from the file it
    /// describes; a filename cannot, and two releases' caches then coexist for
    /// the same reason their disk images do.
    ///
    /// The bytes are written exactly as they arrived, after verification and
    /// never before. Re-encoding the decoded document would drop every field
    /// this app does not know about, and the next release will add some.
    private func saveCatalogToCache(_ data: Data, for version: String) {
        do {
            // .atomic: a kill or a full disk partway through a plain write
            // leaves a truncated document that decodes to nothing, or worse to
            // a short disk list. Temp-file-and-rename makes the file wholly old
            // or wholly new.
            try data.write(to: catalogCacheURL(for: version), options: .atomic)
        } catch {
            debugPrint("[Catalog] Failed to cache catalog: \(error.localizedDescription)")
        }
    }

    /// Save the release list, for the same reason.
    private func saveIndexToCache(_ data: Data) {
        do {
            try data.write(to: indexCacheURL, options: .atomic)
        } catch {
            debugPrint("[Catalog] Failed to cache the release list: \(error.localizedDescription)")
        }
    }

    // MARK: - Disk Download Management

    /// Where downloaded disk images live, without creating anything.
    ///
    /// Static because the v0 storage migration runs before any instance exists
    /// - it is what produces the bytes `profileStore` is decoded from - and
    /// because a migration that renamed files in a different directory from the
    /// one everything else reads would be silent and total.
    static var disksDirectoryURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Disks", isDirectory: true)
    }

    /// Directory where downloaded disk images are stored
    var downloadsDirectory: URL {
        let fm = FileManager.default
        let disks = Self.disksDirectoryURL
        if !fm.fileExists(atPath: disks.path) {
            try? fm.createDirectory(at: disks, withIntermediateDirectories: true)
        }
        return disks
    }

    /// Check if a disk image is already downloaded
    func isDiskDownloaded(_ filename: String) -> Bool {
        let path = downloadsDirectory.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: path.path)
    }

    /// Get the local path for a downloaded disk
    func downloadedDiskPath(_ filename: String) -> URL {
        return downloadsDirectory.appendingPathComponent(filename)
    }

    /// Refresh the list of available disks (all catalog disks + any local .img files)
    func refreshAvailableDisks() {
        var disks: [DiskOption] = [DiskOption(name: "None", filename: "")]

        // Add ALL catalog disks (downloaded or not - user can select and we'll download on run)
        for catalog in diskCatalog {
            let downloaded = isDiskDownloaded(catalog.filename)
            disks.append(DiskOption(
                name: downloaded ? catalog.name : "\(catalog.name) (download)",
                filename: catalog.filename,
                isDownloaded: downloaded
            ))
            downloadStates[catalog.filename] = downloaded ? .downloaded : .notDownloaded
        }

        // Check for any other .img files in downloads directory (user-added disks)
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: downloadsDirectory,
            includingPropertiesForKeys: nil
        ) {
            for url in contents where url.pathExtension == "img" {
                let filename = url.lastPathComponent
                // Another release's catalog image is not a user-added disk.
                // Under 3.6.0 the twenty 3.5.1 files are all sitting in this
                // directory, and listing them here would offer a 3.5.1 system
                // disk for a 3.6.0 machine - the mismatch the versioned
                // filenames exist to keep apart. Nothing is deleted and nothing
                // moves: they come back when their release does.
                if CatalogMigration.belongsToAnotherRelease(filename,
                                                            romwbwVersion: romwbwVersion) {
                    continue
                }
                if !disks.contains(where: { $0.filename == filename }) {
                    disks.append(DiskOption(
                        name: filename,
                        filename: filename,
                        isDownloaded: true
                    ))
                }
            }
        }

        availableDisks = disks
    }

    /// Download a disk image from the catalog (with automatic retry)
    func downloadDisk(_ disk: DownloadableDisk) {
        downloadDiskFromSettings(disk, attemptsRemaining: 3, session: downloadSession,
                                 expectedFacts: nil)
    }

    /// Internal settings download with retry logic.
    ///
    /// `session` has NO default on purpose. The automatic refresh must run on
    /// autoRefreshSession, which refuses an expensive or constrained path; the
    /// four retry sites below re-enter this function, and one of them left on the
    /// unrestricted session would silently spend a user's cellular data. With the
    /// parameter required, a missed site fails to compile instead.
    private func downloadDiskFromSettings(_ disk: DownloadableDisk, attemptsRemaining: Int,
                                          session: URLSession,
                                          expectedFacts: DiskFileFacts?) {
        let attempt = 4 - attemptsRemaining
        debugPrint("[Settings Download] '\(disk.filename)' attempt \(attempt)/3")

        guard let url = URL(string: disk.url) else {
            downloadStates[disk.filename] = .error("Invalid URL")
            return
        }

        downloadStates[disk.filename] = .downloading(progress: 0)

        let task = session.downloadTask(with: url) { [weak self] tempURL, response, error in
            guard let self = self else { return }

            // Check HTTP status code first (can check on background thread)
            if let httpResponse = response as? HTTPURLResponse {
                self.debugPrint("[Settings Download] HTTP status: \(httpResponse.statusCode)")
                if httpResponse.statusCode < 200 || httpResponse.statusCode >= 300 {
                    self.debugPrint("[Settings Download] ERROR: Bad HTTP status \(httpResponse.statusCode)")
                    DispatchQueue.main.async {
                        if attemptsRemaining > 1 {
                            self.debugPrint("[Settings Download] Retrying in 1 second...")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                self.downloadDiskFromSettings(disk, attemptsRemaining: attemptsRemaining - 1,
                                                              session: session,
                                                              expectedFacts: expectedFacts)
                            }
                        } else {
                            self.downloadTasks.removeValue(forKey: disk.filename)
                            self.downloadStates[disk.filename] = .error("HTTP error \(httpResponse.statusCode)")
                        }
                    }
                    return
                }
            }

            if let error = error {
                self.debugPrint("[Settings Download] ERROR: \(error.localizedDescription)")

                // A refusal by the automatic session's own flags is not a failure
                // and must not be treated as one. The OS reports it as
                // NSURLErrorNotConnectedToInternet, whose localizedDescription is
                // "The Internet connection appears to be offline" - a lie on
                // perfectly good LTE, and one the retry loop would tell three
                // times over before parking it as a red error the user cannot
                // clear. Stand down instead and let the path monitor bring it
                // back when the network changes.
                // A cancelled transfer is a decision, not a failure, and must
                // never be retried. The generic arm below sees only
                // `attemptsRemaining > 1` and would re-enter one second later -
                // so cancelRefreshesForMountedDisks(), which exists to stop a
                // refresh landing under the running machine, would instead
                // restart it while the disk was mounted. Same for the user's own
                // cancel button.
                if (error as? URLError)?.code == .cancelled {
                    self.debugPrint("[Settings Download] Cancelled - not retrying")
                    DispatchQueue.main.async {
                        self.downloadTasks.removeValue(forKey: disk.filename)
                        self.downloadStates[disk.filename] =
                            self.isDiskDownloaded(disk.filename) ? .downloaded : .notDownloaded
                    }
                    return
                }

                if let deferral = Self.refreshDeferral(from: error) {
                    self.debugPrint("[Settings Download] Standing down: \(deferral.explanation)")
                    DispatchQueue.main.async {
                        self.downloadTasks.removeValue(forKey: disk.filename)
                        // Recompute from the file rather than assuming: the old
                        // copy is still in place, and leaving `.downloading`
                        // parked here shows a progress bar that never advances.
                        self.downloadStates[disk.filename] =
                            self.isDiskDownloaded(disk.filename) ? .downloaded : .notDownloaded
                        self.diskRefreshPlans[disk.filename.lowercased()] = .deferred(deferral)
                    }
                    return
                }

                DispatchQueue.main.async {
                    if attemptsRemaining > 1 {
                        self.debugPrint("[Settings Download] Retrying in 1 second...")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            self.downloadDiskFromSettings(disk, attemptsRemaining: attemptsRemaining - 1,
                                                              session: session,
                                                              expectedFacts: expectedFacts)
                        }
                    } else {
                        self.downloadTasks.removeValue(forKey: disk.filename)
                        self.downloadStates[disk.filename] = .error(error.localizedDescription)
                    }
                }
                return
            }

            guard let tempURL = tempURL else {
                self.debugPrint("[Settings Download] ERROR: No temp file")
                DispatchQueue.main.async {
                    if attemptsRemaining > 1 {
                        self.debugPrint("[Settings Download] Retrying in 1 second...")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            self.downloadDiskFromSettings(disk, attemptsRemaining: attemptsRemaining - 1,
                                                              session: session,
                                                              expectedFacts: expectedFacts)
                        }
                    } else {
                        self.downloadTasks.removeValue(forKey: disk.filename)
                        self.downloadStates[disk.filename] = .error("Download failed")
                    }
                }
                return
            }

            // IMPORTANT: Move file BEFORE returning from completion handler!
            // URLSession deletes the temp file when the completion handler returns.
            let fm = FileManager.default
            let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
            let disksDir = docs.appendingPathComponent("Disks", isDirectory: true)
            try? fm.createDirectory(at: disksDir, withIntermediateDirectories: true)

            // The catalog is downloaded content, so its <filename> is untrusted
            // input - and two lines below it reaches removeItem.  appendingPathComponent
            // does not escape "..", so a catalog naming "../Imports/x" would delete
            // outside Disks/.  That is the same shape as the W8 export bug this app
            // shipped (see docs and romwbw_emu's RELEASE_ORDER), so it is refused
            // here rather than reduced: a legitimate catalog names a plain file, and
            // silently rewriting the name would desync it from refreshAvailableDisks.
            let leaf = (disk.filename as NSString).lastPathComponent
            guard !disk.filename.isEmpty, disk.filename == leaf,
                  leaf != ".", leaf != ".." else {
                self.debugPrint("[Settings Download] REFUSED: catalog filename is not a plain name: '\(disk.filename)'")
                DispatchQueue.main.async {
                    self.downloadTasks.removeValue(forKey: disk.filename)
                    self.downloadStates[disk.filename] = .error("Bad filename in catalog")
                }
                return
            }
            let destURL = disksDir.appendingPathComponent(disk.filename)

            // Verify the checksum on the TEMP file, before anything replaces what
            // the user already has.  Order matters: the old code below removed the
            // destination first, so a corrupt or truncated download destroyed a good
            // disk and left nothing in its place.  Verifying first makes a bad
            // download cost a retry instead of the disk they were using.
            //
            // Nothing enforced this until 2026-09-01.  There WAS an implementation
            // that hashed, downloadDiskWithRetry, but nothing ever called it - the
            // only caller of a download path is this function - so every disk the
            // app has ever downloaded was written unverified.  That dead copy is
            // deleted in the same change that added this, so there is one download
            // path and it verifies.
            if let expectedSha256 = disk.sha256 {
                let actualSha256 = self.sha256OfFile(at: tempURL)
                if actualSha256?.lowercased() != expectedSha256.lowercased() {
                    self.debugPrint("[Settings Download] ERROR: SHA256 mismatch for '\(disk.filename)'")
                    self.debugPrint("[Settings Download]   Expected: \(expectedSha256)")
                    self.debugPrint("[Settings Download]   Got:      \(actualSha256 ?? "unreadable")")
                    DispatchQueue.main.async {
                        if attemptsRemaining > 1 {
                            self.debugPrint("[Settings Download] Retrying in 1 second...")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                self.downloadDiskFromSettings(disk, attemptsRemaining: attemptsRemaining - 1,
                                                              session: session,
                                                              expectedFacts: expectedFacts)
                            }
                        } else {
                            self.downloadTasks.removeValue(forKey: disk.filename)
                            self.downloadStates[disk.filename] = .error("Checksum mismatch - not saved")
                        }
                    }
                    return
                }
                self.debugPrint("[Settings Download] SHA256 verified: \(expectedSha256.prefix(16))...")
            } else {
                // No hash means no guarantee, so refuse rather than install.  This
                // is not a hypothetical branch to be lenient about: every one of the
                // 20 entries in the pinned v1.4.12 catalog carries a <sha256>, so an
                // entry without one is a degraded or hostile catalog, not a normal
                // one.  Accepting it silently would have made the whole check
                // optional at the attacker's choosing.
                self.debugPrint("[Settings Download] REFUSED: no SHA256 in catalog for '\(disk.filename)'")
                DispatchQueue.main.async {
                    self.downloadTasks.removeValue(forKey: disk.filename)
                    self.downloadStates[disk.filename] = .error("No checksum in catalog - not saved")
                }
                return
            }

            // THE LAST CHECK, and the one that matters most.
            //
            // Everything the decision to start this transfer rested on was
            // sampled before it began - whether the image was pristine, and
            // whether the machine had it mounted. 49 MB later none of that is
            // known any more, and this is the line that destroys the old file.
            // An unattended refresh that started while nothing was running can
            // land after the user has booted that disk and saved work into it,
            // and `saveDownloadedDisks()` writes the image back every twenty
            // seconds - so the file under `destURL` may now be theirs.
            //
            // `expectedFacts` is what the destination looked like when the plan
            // was made. If it no longer matches, somebody wrote to the file and
            // this install is abandoned: the download is discarded, the disk they
            // have is left alone, and the next sweep re-decides with the truth.
            // Only the automatic path passes facts; an explicit tap has already
            // been confirmed against the same hazard by `updateDisk`.
            if let expected = expectedFacts {
                let now = self.fileFacts(for: disk.filename)
                if now != expected {
                    self.debugPrint("[Settings Download] ABANDONED: '\(disk.filename)' changed under the transfer - not replacing it")
                    DispatchQueue.main.async {
                        self.downloadTasks.removeValue(forKey: disk.filename)
                        self.downloadStates[disk.filename] =
                            self.isDiskDownloaded(disk.filename) ? .downloaded : .notDownloaded
                        self.reassessDiskFreshness()
                    }
                    return
                }
            }

            self.debugPrint("[Settings Download] Installing \(tempURL.path) as \(destURL.path)")

            do {
                // Stage inside Disks/ first, then swap. The old shape was
                // removeItem-then-moveItem, which has a window where the user has
                // NO disk at all: a moveItem that throws - a full volume, a
                // sandbox refusal - left the slot empty having already deleted
                // the working copy. Staging makes the failure mode "nothing
                // happened" instead.
                let stagingURL = disksDir.appendingPathComponent(disk.filename + ".incoming")
                try? fm.removeItem(at: stagingURL)
                try fm.moveItem(at: tempURL, to: stagingURL)
                do {
                    if fm.fileExists(atPath: destURL.path) {
                        _ = try fm.replaceItemAt(destURL, withItemAt: stagingURL)
                    } else {
                        try fm.moveItem(at: stagingURL, to: destURL)
                    }
                } catch {
                    try? fm.removeItem(at: stagingURL)
                    throw error
                }
                self.debugPrint("[Settings Download] Install successful")

                DispatchQueue.main.async {
                    self.downloadTasks.removeValue(forKey: disk.filename)
                    self.downloadStates[disk.filename] = .downloaded
                    self.refreshAvailableDisks()

                    // The one point in the app where provenance is knowable: the
                    // bytes on disk are the ones just verified against the
                    // catalog's <sha256>, so record which published image they
                    // are. Everything DiskLedger decides later rests on this
                    // line, and no other code may write it - a hash computed
                    // over the file at any later moment cannot tell a superseded
                    // image from one the user has saved work into.
                    if let expected = disk.sha256 {
                        self.diskLedger.recordInstall(filename: disk.filename,
                                                      catalogSha256: expected,
                                                      facts: self.fileFacts(for: disk.filename))
                        // A verified download settles both of the reasons a file
                        // stops being measured, so clear them: the bytes and
                        // their hash are known exactly, and any earlier failure
                        // or churn is no longer the state of this file.
                        self.measurementFailed.remove(disk.filename.lowercased())
                        self.measurementAttempts.removeValue(forKey: disk.filename.lowercased())
                        self.persistDiskLedger()
                    }
                    // Clear the offer here rather than waiting for the next
                    // sweep. A sweep only runs on a catalog fetch or a path
                    // change, neither of which happens because a download
                    // finished - so the Update button would sit there afterwards
                    // inviting a second 49 MB fetch of an image already current.
                    self.diskRefreshPlans[disk.filename.lowercased()] = .doNothing
                    self.statusText = "Downloaded: \(disk.name)"
                }
            } catch {
                self.debugPrint("[Settings Download] ERROR moving file: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.downloadTasks.removeValue(forKey: disk.filename)
                    self.downloadStates[disk.filename] = .error("Save failed: \(error.localizedDescription)")
                }
            }
        }

        // Track progress via observation
        let observation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            DispatchQueue.main.async {
                self?.downloadStates[disk.filename] = .downloading(progress: progress.fractionCompleted)
            }
        }
        // Store observation to keep it alive (simplified - in production use proper storage)
        objc_setAssociatedObject(task, "progressObservation", observation, .OBJC_ASSOCIATION_RETAIN)

        downloadTasks[disk.filename] = task
        task.resume()
    }

    /// Cancel a download in progress
    func cancelDownload(_ filename: String) {
        downloadTasks[filename]?.cancel()
        downloadTasks.removeValue(forKey: filename)
        // Recompute rather than assert. Since disks can be REFRESHED in place,
        // a cancelled transfer often leaves a perfectly good installed image
        // behind - and saying .notDownloaded for one hides its hash badge, drops
        // it back to a download arrow, and invites the user to re-fetch 49 MB of
        // a file they already have.
        downloadStates[filename] = isDiskDownloaded(filename) ? .downloaded : .notDownloaded
    }

    /// Delete a downloaded disk image
    func deleteDownloadedDisk(_ filename: String) {
        let path = downloadsDirectory.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: path)
        downloadStates[filename] = .notDownloaded
        // Everything recorded about the file goes with the file. Leaving the plan
        // behind kept an orange "any files you saved in it are lost" note on a
        // disk that no longer exists; leaving the ledger record behind would hand
        // the next download a provenance it did not earn.
        diskRefreshPlans.removeValue(forKey: filename.lowercased())
        diskLedger.removeRecord(for: filename)
        measurementFailed.remove(filename.lowercased())
        measurementAttempts.removeValue(forKey: filename.lowercased())
        persistDiskLedger()
        refreshAvailableDisks()

        // Clear selection if this disk was selected
        for i in 0..<selectedDisks.count {
            if selectedDisks[i]?.filename == filename {
                selectedDisks[i] = availableDisks.first
            }
        }
    }

    /// Delete the downloaded images the catalog names, and only those.
    ///
    /// Returns (cleared, kept) so the caller can say what happened rather than
    /// asserting that everything went. See checkCatalogGenerationAndInvalidate
    /// for why the set is the boundary.
    ///
    /// The comparison is case-insensitive. The catalog's filenames and the
    /// on-disk names are written by the same code, so they agree today — but
    /// `Documents` is published to the Files app on a case-insensitive volume,
    /// and a user's own `HD1K_COMBO.IMG` must not be deleted as a catalog disk
    /// on one device and kept on another.
    @discardableResult
    private func deleteCatalogDisks(named catalogFilenames: Set<String>) -> (cleared: Int, kept: Int) {
        let fm = FileManager.default
        let lowercased = Set(catalogFilenames.map { $0.lowercased() })
        var cleared = 0
        var kept = 0
        if let contents = try? fm.contentsOfDirectory(at: downloadsDirectory, includingPropertiesForKeys: nil) {
            for url in contents where url.pathExtension.lowercased() == "img" {
                let filename = url.lastPathComponent
                guard lowercased.contains(filename.lowercased()) else {
                    // Another RomWBW release's catalog image is kept too, but
                    // it is not COUNTED: the caller's alert calls what it
                    // counts "ones you imported or created", and twenty
                    // hd1k_*-v0-3.5.1.img files sitting under a 3.6.0 catalog
                    // are neither. They are this catalog's opposite numbers,
                    // and they come back the moment that release is selected.
                    if CatalogMigration.belongsToAnotherRelease(filename,
                                                                romwbwVersion: romwbwVersion) {
                        continue
                    }
                    kept += 1
                    debugPrint("[Catalog] Keeping '\(filename)' - not in the catalog, cannot be re-downloaded")
                    continue
                }
                try? fm.removeItem(at: url)
                downloadStates[filename] = .notDownloaded
                cleared += 1
            }
        }
        debugPrint("[Catalog] Catalog version change: cleared \(cleared), kept \(kept)")
        return (cleared, kept)
    }

    /// Load a downloaded disk into the emulator
    func loadDownloadedDisk(unit: Int, filename: String) -> Bool {
        let path = downloadsDirectory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: path.path) else { return false }

        do {
            let data = try Data(contentsOf: path)
            if emulator?.loadDisk(Int32(unit), from: data) == true {
                // Mark as manifest disk - warns user if they write to it
                emulator?.setDiskIsManifest(Int32(unit), isManifest: true)
                return true
            }
        } catch {
            showError("Failed to load disk: \(error.localizedDescription)")
        }
        return false
    }

    // MARK: - Sound Generation

    private func playBeep(durationMs: Int) {
        guard let player = tonePlayer else { return }

        let sampleRate: Double = 44100
        let frequency: Double = 800  // 800 Hz beep
        let duration = Double(durationMs) / 1000.0
        let frameCount = AVAudioFrameCount(sampleRate * duration)

        // Use mono format matching setupAudio()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
    
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount

        guard let channelData = buffer.floatChannelData?[0] else { return }
        for frame in 0..<Int(frameCount) {
            let phase = Double(frame) / sampleRate * frequency * 2.0 * .pi
            // Square wave
            channelData[frame] = sin(phase) > 0 ? 0.3 : -0.3
        }

        player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        player.play()
    }
}

// MARK: - RomWBWEmulatorDelegate

extension EmulatorViewModel: RomWBWEmulatorDelegate {

    // Console output (streaming text, used by some apps)
    func emulatorDidOutputCharacter(_ ch: unichar) {
        // Handle as VDA write at current cursor
        emulatorVDAWriteChar(ch)
    }

    func emulatorDidChangeStatus(_ status: String) {
        DispatchQueue.main.async {
            self.statusText = status
        }
    }

    func emulatorDidRequestInput() {
        // Could show cursor blinking or input indicator
    }

    // MARK: - VDA (Video Display Adapter)

    func emulatorVDAClear() {
        // vdaClear() erases, and is deliberately not the machine-level clear:
        // this is the guest asking HBIOS to clear the display, which fills with
        // the attribute the guest last set through emulatorVDASetAttr. It must
        // not take the rendition or the scrolling region with it.
        DispatchQueue.main.async {
            self.screen.vdaClear()
        }
    }

    func emulatorVDASetCursorRow(_ row: Int32, col: Int32) {
        DispatchQueue.main.async {
            self.screen.vdaSetCursor(row: Int(row), col: Int(col))
        }
    }

    func emulatorVDAWriteChar(_ ch: unichar) {
        DispatchQueue.main.async {
            // Check for manifest disk write warning
            if self.emulator?.pollManifestWriteWarning() == true {
                self.showManifestWriteWarning()
            }
            // Check for NVRAM changes from SYSCONF
            if self.emulator?.hasNvramChange() == true {
                self.syncNvramFromEmulator()
            }
            self.processCharacter(ch)
            self.checkHostFileState()
        }
    }

    /// Check if emulator has file ready to save (W8)
    private func checkHostFileState() {
        let state = emu_host_file_get_state_c()
        if state == Int32(HOST_FILE_WRITE_READY.rawValue) {
            // Get file data from emulator
            // The LEAF, not get_write_name_c(): that one now answers with the
            // full Exports path, because it is what W8 prints to the CP/M user
            // (HBF_HOST_GETNAME) and a bare name tells them nothing about where
            // to look. saveToExportsFolder joins to Exports itself and must not
            // be handed an absolute path to join.
            guard let namePtr = emu_host_file_get_write_leaf_c() else {
                emu_host_file_write_done_c()
                return
            }
            // The data pointer is NOT part of that guard. emu_host_file_get_write_data()
            // returns nullptr for an empty buffer by the shared contract, so the
            // pointer cannot say whether an export is waiting - the WRITE_READY
            // state above already did. Guarding on it here made a zero-byte W8
            // export vanish: an empty CP/M file is a real file, and the CLI and
            // Windows backends both create it (cpmdroid c06fa58, same fix).
            let size = emu_host_file_get_write_size_c()
            let data: Data
            if size > 0, let dataPtr = emu_host_file_get_write_data_c() {
                data = Data(bytes: dataPtr, count: size)
            } else {
                data = Data()
            }
            let filename = String(cString: namePtr)

            // W8 always writes to the Documents/Exports folder — no interaction,
            // so a build that ends in several W8s just drops several files there.
            // Share them out afterward via "Open Exports Folder".
            emu_host_file_write_done_c()
            saveToExportsFolder(data: data, filename: filename)
        }
    }

    /// Write W8 output into the sandbox Documents/Exports folder. Used as the
    /// default (folder) mode and as the fallback when the user cancels the
    /// arbitrary-path save picker, so an export is never silently lost.
    ///
    /// `filename` is a guest-supplied string. It arrives already reduced to a
    /// single leaf component by `emu_host_file_open_write()`, and the two checks
    /// below assume nothing about that having happened.
    ///
    /// What this used to do, and why it does not any more: it took the guest
    /// string whole, called `appendingPathComponent` on it, and then
    /// `removeItem` on the result. `appendingPathComponent` does not escape
    /// `..`, and `removeItem` on a URL ending in `..` succeeds and deletes the
    /// parent *recursively*. `W8 ANYFILE.TXT ..` therefore destroyed the entire
    /// Documents folder — Disks, Imports and Exports, so every disk image the
    /// user had downloaded — while the `try?` swallowed the error and the guest
    /// was told the export succeeded.
    private func saveToExportsFolder(data: Data, filename: String) {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let exportsDir = docs.appendingPathComponent("Exports", isDirectory: true)
        try? fm.createDirectory(at: exportsDir, withIntermediateDirectories: true)

        // ExportPath owns both halves - reducing the guest's string to a leaf
        // and proving the result lands inside Exports - so they can be tested
        // (Tests/ExportPathTests.swift). The core reduces the string before it
        // reaches Swift; this assumes nothing about that, because this method
        // is also reachable from the picker-cancelled path.
        let name = ExportPath.leafName(from: filename)
        guard let destURL = ExportPath.destination(for: filename, in: exportsDir) else {
            statusText = "W8: Refused \(name) — it does not name a file in Exports"
            return
        }

        do {
            // No removeItem: Data.write(to:) replaces an existing file by
            // itself, and the remove was the call that did the damage.
            try data.write(to: destURL)
            statusText = "W8: Saved \(name) to Exports folder"
        } catch {
            statusText = "W8: Failed to save \(name)"
        }
    }

    /// Feed one byte of guest output to the terminal, then carry out whatever
    /// the terminal owes the world for it.
    private func processCharacter(_ ch: unichar) {
        screen.receive(ch)
        drainTerminalEffects()
    }

    /// Carry out the side effects the parser queued instead of performing.
    ///
    /// TerminalScreen has no emulator to answer a device report on and no audio
    /// engine to beep with - that is precisely what lets it be compiled and
    /// driven with no simulator - so it queues both and this drains them.
    ///
    /// The bells are drained whether or not any noise comes out, so a spell
    /// with the bell switched off cannot bank up and then all sound at once.
    /// The gate itself is inside the screen, next to the counter; see
    /// `bellEnabled`.
    private func drainTerminalEffects() {
        for reply in screen.takeResponses() {
            emulator?.send(reply)
        }
        if screen.takeBells() > 0 {
            playBeep(durationMs: 100)
        }
    }

    func emulatorVDAScrollUp(_ lines: Int32) {
        DispatchQueue.main.async {
            self.screen.vdaScrollUp(Int(lines))
        }
    }

    func emulatorVDASetAttr(_ attr: UInt8) {
        DispatchQueue.main.async {
            self.screen.vdaSetAttr(attr)
        }
    }
    // MARK: - Disk Flush

    func emulatorShouldFlushDisks() {
        print("[DiskFlush] Warm boot detected - flushing disks")
        DispatchQueue.main.async {
            self.saveDownloadedDisks()
        }
    }

    // MARK: - Sound

    func emulatorBeep(_ durationMs: Int32) {
        DispatchQueue.main.async {
            self.playBeep(durationMs: Int(durationMs))
        }
    }

    // MARK: - Host File Transfer (R8/W8)

    /// The backend could not open the file R8 asked for.
    ///
    /// This used to be the whole read path: it resolved the name against
    /// `Imports`, read the bytes and handed them down through
    /// `emu_host_file_load_named`. That is now done synchronously inside
    /// `emu_host_file_open_read` (`emu_io_ios.mm`), on the emulator thread,
    /// because R8 asks for the resolved name (`H_GETRNAME`, 0xEA) about ten Z80
    /// instructions after the open - and a hop to the main queue has essentially
    /// never completed by then, so the backend had nothing to answer with.
    ///
    /// The case-insensitive scan went with it rather than being duplicated in
    /// C++: there is one resolver now, not two that can drift. It also had a bug
    /// of its own that the move fixes - `fileExists(atPath:)` succeeds for
    /// `ESC.TXT` when the file is `esc.txt`, because Documents is a
    /// case-insensitive volume, so the path handed on carried the case the CCP
    /// invented rather than the case the file has.
    ///
    /// What is left is the part that needs UIKit and a user: say where the file
    /// should go, and make the folder so they can put it there. **It must not
    /// touch host-file state.** The open has already failed and returned false;
    /// R8 has been told. Calling `emu_host_file_cancel()` here would be
    /// cancelling a transfer that no longer exists, and a later one if the guest
    /// has moved on.
    func emulatorHostFileRequestRead(_ suggestedFilename: String) {
        DispatchQueue.main.async {
            let fm = FileManager.default
            let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
            let importsDir = docs.appendingPathComponent("Imports", isDirectory: true)
            try? fm.createDirectory(at: importsDir, withIntermediateDirectories: true)

            let requested = suggestedFilename.trimmingCharacters(in: .whitespaces)
            let what = requested.isEmpty ? "No filename given" : "\(requested) not found"
            self.showError("R8: \(what) in the Imports folder.\n\nPut the file in:\n\(importsDir.path)")
            self.statusText = "R8: \(what) in Imports"
        }
    }

    func emulatorHostFileDownload(_ filename: String, data: Data) {
        // Legacy callback - no longer used, polling checkHostFileState() instead
        // Keep for protocol compliance but do nothing
        debugPrint("[HostFile] emulatorHostFileDownload called (legacy, ignored)")
    }

    /// Handle result from host file move picker (W8)
    func handleHostFileMoveResult(_ result: Result<URL, Error>) {
        // Clean up temp file
        if let tempURL = hostFileTempURL {
            try? FileManager.default.removeItem(at: tempURL)
        }
        hostFileTempURL = nil

        // Tell emulator we're done with the write data
        emu_host_file_write_done_c()

        switch result {
        case .success(let url):
            statusText = "W8: Saved to \(url.lastPathComponent)"
        case .failure(let error):
            if (error as NSError).code == NSUserCancelledError {
                statusText = "W8: Save cancelled"
            } else {
                showError("Failed to save: \(error.localizedDescription)")
            }
        }
    }

    /// Handle result from the arbitrary-path W8 exporter.
    func handleHostFileExportResult(_ result: Result<URL, Error>) {
        // Capture the payload before clearing, so a cancel can fall back to the
        // Exports folder instead of silently dropping the export (the guest was
        // already told the close succeeded, per the async close_write contract).
        let pendingData = hostFileExportDocument?.data
        let pendingName = hostFileExportFilename
        hostFileExportDocument = nil
        switch result {
        case .success(let url):
            statusText = "W8: Saved to \(url.lastPathComponent)"
        case .failure(let error):
            if (error as NSError).code == NSUserCancelledError {
                if let data = pendingData {
                    saveToExportsFolder(data: data, filename: pendingName)  // no silent loss
                } else {
                    statusText = "W8: Save cancelled"
                }
            } else {
                showError("Failed to save: \(error.localizedDescription)")
            }
        }
    }

    /// Handle the "Import File…" picker: copy the chosen host file(s) into the
    /// Documents/Imports folder so a later R8 can read them. This is a purely
    /// user-initiated staging action — it never touches emulator host-file state,
    /// so it can neither stall nor be driven by the guest.
    func handleImportToInbox(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            let fm = FileManager.default
            let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
            let importsDir = docs.appendingPathComponent("Imports", isDirectory: true)
            try? fm.createDirectory(at: importsDir, withIntermediateDirectories: true)

            var imported: [String] = []
            for url in urls {
                guard url.startAccessingSecurityScopedResource() else { continue }
                defer { url.stopAccessingSecurityScopedResource() }
                do {
                    let data = try Data(contentsOf: url)
                    let dest = importsDir.appendingPathComponent(url.lastPathComponent)
                    try? fm.removeItem(at: dest)
                    try data.write(to: dest)
                    imported.append(url.lastPathComponent)
                } catch {
                    showError("Could not import \(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            if imported.count == 1 {
                statusText = "Imported \(imported[0]) — run R8 to read it"
            } else if imported.count > 1 {
                statusText = "Imported \(imported.count) files to Imports — run R8 to read them"
            }

        case .failure(let error):
            if (error as NSError).code != NSUserCancelledError {
                showError("Import failed: \(error.localizedDescription)")
            }
        }
    }
}
