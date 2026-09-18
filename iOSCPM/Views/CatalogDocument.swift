//
//  CatalogDocument.swift
//  iOSCPM
//
//  The two interface-v0 catalog documents, and the rules for reading them.
//
//  Pure values, like CatalogMigration, DiskLedger and EmulatorProfile: no
//  UIKit, no URLSession, no UserDefaults. The view model does the fetching and
//  owns the keys; every decision about what a fetched document means is here,
//  so Tests/CatalogDocumentTests.swift can drive it on a machine with no Xcode.
//
//  ## Two documents, two hops
//
//  Only ONE URL is compiled into this app now - the index. It lists the RomWBW
//  releases romwbw_disks publishes, each with an absolute `catalog_url` and
//  that catalog's `catalog_sha256`/`catalog_size`, so the second hop can be
//  verified before it is parsed. The per-release catalog then carries its own
//  `base_url`, and an asset URL is `base_url + filename`.
//
//  Nothing interpolates a release tag into a URL any more. That is the whole
//  point: the old `releaseTag = "v1.4.12"` had to be edited, rebuilt and
//  shipped for a disk fix to reach anyone, and a build that was never shipped
//  went on serving the old image with nothing to say so.
//
//  ## What this file must tolerate (romwbw_disks docs/CATALOG_SCHEMA.md §6.1)
//
//  - **Unknown fields, at every level.** Adding a field is explicitly not an
//    interface break, so a parser that rejected one would be broken by the next
//    release. `Decodable` ignores them by default; the thing to avoid is
//    round-tripping a document through an encoder, which would drop them.
//  - **Entries appearing and disappearing.** `hd1k_ws4` exists under 3.5.1 and
//    not under 3.6.0; RomWBW 3.7.0 will appear in the index with no app change.
//    So: key on `id`, never on array position, never on array length, and never
//    assume `emu_avw` is in `roms[]` - or that `roms[]` is there at all.
//  - **Optional fields being absent.** `slices` and `defaultSlot` appear only on
//    hd1k_combo (verified: 1 of 20 entries under 3.5.1, 1 of 24 under 3.6.0);
//    `cbios` is null on the data-only images.
//  - **New `status` and `license` values.** Both are free text. "stable" and
//    "preview" are what is published today, not a closed set: display an
//    unfamiliar one, do not fail on it and do not branch on it beyond marking a
//    preview as such.
//  - **`generation` jumping by more than 1.** Compare, never compute.
//
//  What is NOT tolerated is a document missing a field nothing can work
//  without - `romwbw_version` on an index entry, `base_url` on a catalog,
//  `id`/`filename`/`name` on a disk. Those throw, the fetch falls back to the
//  cached catalog, and the user is told. That is the loud, recoverable failure;
//  quietly dropping such an entry would give a short catalog, and a short
//  catalog makes `start()` refuse to boot a slot it can no longer resolve.
//

import Foundation

// MARK: - index-v0.json

/// The packed RomWBW version bytes, as the index publishes them.
///
/// Hex STRINGS - `"0x35"`, not `53` - in both the index entry and the catalog
/// (romwbw_disks writes them out of `versions/<ver>/version.json` verbatim).
/// Making them integers would be a v0 break, so parsing them as strings is not
/// defensive coding, it is the contract.
///
/// Nothing in this app reads them today. They are decoded anyway because they
/// are still published in every entry and still describe the one axis that is
/// real - the ROM-to-disk-image pairing the guest enforces with
/// `*** WARNING: HBIOS/CBIOS Version Mismatch ***`. What they stopped being in
/// romwbw_emu v1.44 is an emulator gate; `RomWBWIndex.offered` is where that
/// went. The comparisons this app actually makes are in release STRINGS -
/// `romwbwVersion` against `RomWBWEmulator.romWBWRelease(ofImageData:)`,
/// through `RomWBWRelease.romServes` - so the packed bytes had no caller left
/// once the filter went, and the accessors that unpacked them (`versionBytes`,
/// `hexByte`) went with it rather than staying alive on their own unit tests.
///
/// These two bytes are also exactly why that comparison cannot be `==`: they
/// are all a ROM has to describe itself with, and they cannot hold the
/// `-dev.14` a snapshot's catalog entry carries. See `RomWBWRelease`.
struct RomWBWHBIOS: Decodable, Equatable {
    let verByte: String?
    let updByte: String?

    enum CodingKeys: String, CodingKey {
        case verByte = "ver_byte"
        case updByte = "upd_byte"
    }
}

/// One published RomWBW release.
struct RomWBWIndexEntry: Decodable, Equatable, Identifiable {
    /// The release string is the identity - `"3.5.1"`, `"3.6.0"` - so a picker
    /// row keeps its identity when the index is re-fetched. Deliberately not a
    /// `UUID()`: `ROMOption` used to do that, and a fresh UUID per construction
    /// changes `==` and `hash`, which makes a SwiftUI picker's tag stop matching
    /// its selection the moment the array is rebuilt.
    var id: String { romwbwVersion }

    let romwbwVersion: String
    let label: String?
    let status: String?
    let isDefault: Bool?
    /// **Upstream does not call this a release.** `true` on a RomWBW
    /// development snapshot the publisher is carrying deliberately; ABSENT on a
    /// real release, which is why this is optional and why `isPrerelease`
    /// treats nil as false. romwbw_disks emits it only when true, so that a
    /// released version's catalog stays byte-identical to the one already on
    /// its immutable tag.
    let prerelease: Bool?
    let hbios: RomWBWHBIOS?
    let catalogURL: String?
    let catalogSHA256: String?
    let catalogSize: Int?
    let generation: Int?
    let diskCount: Int?
    let notes: [String]?

    enum CodingKeys: String, CodingKey {
        case romwbwVersion = "romwbw_version"
        case label
        case status
        case isDefault = "default"
        case prerelease
        case hbios
        case catalogURL = "catalog_url"
        case catalogSHA256 = "catalog_sha256"
        case catalogSize = "catalog_size"
        case generation
        case diskCount = "disk_count"
        case notes
    }
}

extension RomWBWIndexEntry {

    /// What to call this release. `label` is a display string the index
    /// provides ("RomWBW 3.5.1") and explicitly must not be parsed; this is the
    /// fallback for an index that omits it.
    ///
    /// For a snapshot the publisher puts the warning in here - "RomWBW
    /// 3.7.0-dev.14 (development snapshot)" - because `label` is the one field
    /// every client renders everywhere it names a release, and `status` and
    /// `prerelease` are not shown on every screen.
    var displayLabel: String { label ?? "RomWBW \(romwbwVersion)" }

    /// Absent means "a real release". An index written before the field existed
    /// has no key at all, and must not read as a snapshot.
    var isPrerelease: Bool { prerelease ?? false }

    /// Published as not-yet-recommended. **No released entry carries this
    /// today**: 3.6.0 did until romwbw_disks promoted it on 2026-09-05, and the
    /// live index has published both 3.5.1 and 3.6.0 as `"status": "stable"`
    /// since. Do not write a release name in here again - the status is a fact
    /// about what the index says this minute, and naming one in a docstring is
    /// the second source of truth CLAUDE.md warns about.
    var isPreview: Bool { normalizedStatus == "preview" }

    private var normalizedStatus: String {
        (status ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The picker row: `"RomWBW 3.6.0 (preview)"`.
    ///
    /// Any status other than "stable" is shown verbatim, not just "preview".
    /// The set is open, and a release marked something this build has never
    /// heard of is exactly the one a user should be told about rather than
    /// offered silently.
    var pickerLabel: String {
        let raw = (status ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, normalizedStatus != "stable" else { return displayLabel }
        return "\(displayLabel) (\(raw))"
    }

    /// What is wrong with the bytes fetched from `catalog_url`, or nil when
    /// they are exactly what this entry promised.
    ///
    /// Called BEFORE the JSON is parsed. The index is the only document this
    /// app trusts on its own say-so, and it exists precisely so the big one can
    /// be checked. An entry that carries no `catalog_sha256` fails here rather
    /// than being waved through: a gate that cannot verify must not say yes,
    /// and a v0 index that omits it is broken in a way this app cannot repair.
    func payloadProblem(byteCount: Int, sha256: String) -> String? {
        if let expected = catalogSize, expected != byteCount {
            return "the catalog is \(byteCount) bytes, but the index says \(expected)"
        }
        guard let expected = catalogSHA256?.trimmingCharacters(in: .whitespacesAndNewlines),
              !expected.isEmpty else {
            return "the index carries no checksum for this catalog, so it cannot be verified"
        }
        guard expected.lowercased() == sha256.lowercased() else {
            return "the catalog's checksum is \(String(sha256.prefix(16)))…,"
                + " but the index says \(String(expected.prefix(16)))…"
        }
        return nil
    }

    /// What is wrong with the document those bytes decoded into.
    ///
    /// Both checks are about a document that verified cleanly and is still the
    /// wrong one - an asset uploaded under the wrong tag, or a v1 catalog
    /// published at a v0 URL. Neither can be diagnosed from the hash, which
    /// only says the bytes are the ones the index pointed at.
    func documentProblem(_ document: RomWBWCatalogDocument,
                         expectedInterface: String) -> String? {
        if let interface = document.interface, interface != expectedInterface {
            return "that catalog is interface \(interface), and this app reads \(expectedInterface)"
        }
        if let version = document.romwbwVersion, version != romwbwVersion {
            return "that catalog is for RomWBW \(version), not \(romwbwVersion)"
        }
        return nil
    }

    /// The release in play, before any index has been read.
    ///
    /// A picker whose selection matches no row renders blank, and the release
    /// list arrives over the network - which on a first offline launch never
    /// arrives at all. This is the one row that is always there: it claims
    /// nothing about the release except its name.
    static func placeholder(romwbwVersion: String) -> RomWBWIndexEntry {
        RomWBWIndexEntry(romwbwVersion: romwbwVersion,
                         label: nil,
                         status: nil,
                         isDefault: nil,
                         // Not a snapshot: the placeholder claims nothing about
                         // the release except its name, and "nothing" must not
                         // read as "development snapshot".
                         prerelease: nil,
                         hbios: nil,
                         catalogURL: nil,
                         catalogSHA256: nil,
                         catalogSize: nil,
                         generation: nil,
                         diskCount: nil,
                         notes: nil)
    }
}

/// index-v0.json itself.
/// One in-app help topic, out of the index's optional `help` block.
///
/// Release strings, and the one comparison this app makes with them.
///
/// **A ROM cannot say which pre-release it is.** The release a ROM declares is
/// read out of two bytes of its HBIOS configuration block - the version and
/// update bytes at 0x103 - so `RomWBWEmulator.romWBWRelease(ofImageData:)` can
/// only ever answer three numbers: `"3.7.0"`. The catalog, which is a document
/// and not two bytes, names the full upstream tag: `"3.7.0-dev.14"`.
///
/// The publisher measured that pair and carries it deliberately. A RomWBW
/// development snapshot's HCB is byte-for-byte what the release it precedes
/// will carry - `v3.7.0-dev.14` reads `57 a8 37 00`, exactly what a released
/// 3.7.0 will read - so nothing computed from those bytes can separate them.
/// What separates them is the CBIOS banner inside the disk image, which is a
/// string: `CBIOS v3.7.0-dev.14 [WBW]`. See romwbw_disks
/// `docs/CATALOG_SCHEMA.md` section 2.3.1.
///
/// So a straight `!=` between the two rejected every snapshot: the ROM
/// downloaded, verified against its published sha256, and then would not start
/// because "the image says it is RomWBW 3.7.0, not 3.7.0-dev.14". Both
/// statements were true and the conclusion was wrong.
enum RomWBWRelease {

    /// May a ROM declaring `declaredByROM` serve a catalog entry for
    /// `catalogVersion`?
    ///
    /// True when they are the same release, or when the catalog entry is a
    /// **pre-release of** what the ROM declares - semver's rule, where
    /// `3.7.0-dev.14` has the core version `3.7.0`.
    ///
    /// This cannot let a genuinely wrong pairing through, which is why it needs
    /// no help from the entry's `prerelease` flag: a 3.6.0 ROM against a
    /// `3.7.0-dev.14` entry matches neither arm, and a released `3.7.0` ROM
    /// against a `3.7.0` entry matches the first. Only the suffix is forgiven,
    /// and only in the direction the HCB is incapable of expressing.
    static func romServes(catalogVersion: String, declaredByROM: String) -> Bool {
        if catalogVersion == declaredByROM { return true }
        // The separator matters: without it "3.7.01" would match a "3.7.0" ROM.
        return catalogVersion.hasPrefix(declaredByROM + "-")
    }
}

/// **Shaped like a disk or a ROM on purpose.** It carries an `id`, a
/// `filename`, a `size` and a `sha256` under a shared `base_url`, because that
/// is what every other asset this catalog publishes carries - and help had been
/// the one kind of content nothing verified. `size` and `sha256` are optional
/// for the same reason they are optional on a catalog document: an index that
/// stops publishing them must degrade to an unchecked download rather than to
/// no help at all.
///
/// `id` and `filename` are optional too, and `usable` is what requires them.
/// Decoding is where a strict field would be most expensive: help lives inside
/// the SAME document as `romwbw_versions`, so one malformed topic throwing here
/// would take the release list with it and leave the app with no catalog.
struct CatalogHelpTopic: Decodable, Equatable, Identifiable {
    let topicID: String?
    let filename: String?
    let name: String?
    let topicDescription: String?
    let size: Int64?
    let sha256: String?

    enum CodingKeys: String, CodingKey {
        case topicID = "id"
        case filename
        case name
        case topicDescription = "description"
        case size
        case sha256
    }

    /// Identifiable wants a non-optional id; an entry with none is dropped by
    /// `usable` before anything can list it, so the fallback is never shown.
    var id: String { topicID ?? "" }

    /// An entry with an id and something to fetch. Everything else is display
    /// text that a missing value only makes plainer.
    var usable: Bool {
        guard let topicID = topicID, !topicID.isEmpty else { return false }
        guard let filename = filename, !filename.isEmpty else { return false }
        return true
    }
}

/// The index's `help` block: where the topics live and what they are.
///
/// **It is in the index and not in a per-version catalog**, which is the other
/// place it could have gone. The topics are about CP/M and about the
/// application, not about RomWBW 3.5.1 versus 3.6.0; putting them in a
/// per-version catalog would copy them into every release and make fixing a
/// typo mean re-cutting a 200 MB tag.
///
/// **Absent is not an error.** An index published before this block existed has
/// no `help` key at all, and this app then shows the topics it shipped with,
/// exactly as it does with no network.
struct CatalogHelp: Decodable, Equatable {
    let baseURL: String?
    let topics: [CatalogHelpTopic]

    enum CodingKeys: String, CodingKey {
        case baseURL = "base_url"
        case topics
    }

    /// Usable when there is somewhere to fetch from and something to fetch.
    var ok: Bool { !(baseURL ?? "").isEmpty && !topics.filter({ $0.usable }).isEmpty }

    /// `base_url` + `filename`, with NOTHING between them.
    ///
    /// The document's `base_url` ends in "/" - that is the field's whole job,
    /// since the three clients used to disagree about the separator, this one
    /// by appending a "/" of its own in `didEndElement`. So nothing is inserted
    /// here and nothing "fixes" a base that lacks one: a base_url without its
    /// slash is a broken document, and it had better produce a URL that visibly
    /// fails rather than one that quietly works in this client alone.
    func assetURL(for filename: String) -> String { (baseURL ?? "") + filename }

    /// Decoded one topic at a time, so a shape this build does not understand
    /// costs that row and not the list. `topics` failing entirely - `"topics":
    /// 3`, say - throws, and `RomWBWIndex` catches that so the release list
    /// survives it.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try? container.decodeIfPresent(String.self, forKey: .baseURL)
        let wrapped = try container.decode([FailableTopic].self, forKey: .topics)
        topics = wrapped.compactMap { $0.topic }
    }

    /// Never throws, which is what makes the array decode survive a bad element
    /// AND keep its place - a `try?` around a plain `decode` inside an unkeyed
    /// container does not reliably advance past the entry that failed.
    private struct FailableTopic: Decodable {
        let topic: CatalogHelpTopic?
        init(from decoder: Decoder) throws {
            topic = try? CatalogHelpTopic(from: decoder)
        }
    }
}

struct RomWBWIndex: Decodable {
    let schema: String?
    let schemaVersion: Int?
    let interface: String?
    let romwbwVersions: [RomWBWIndexEntry]
    let help: CatalogHelp?

    enum CodingKeys: String, CodingKey {
        case schema
        case schemaVersion = "schema_version"
        case interface
        case romwbwVersions = "romwbw_versions"
        case help
    }

    /// Written out rather than synthesised for one reason: `try?` on `help`.
    ///
    /// The help block shares this document with the release list, so a `help`
    /// key this build cannot read - a future shape, a truncation, anything -
    /// must cost the help list and nothing else. With the synthesised
    /// initialiser it would throw, `fetchIndex` would report the index as
    /// unreadable, and the app would offer no releases, no ROM and no disks
    /// because a help topic was malformed.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decodeIfPresent(String.self, forKey: .schema)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
        interface = try container.decodeIfPresent(String.self, forKey: .interface)
        romwbwVersions = try container.decode([RomWBWIndexEntry].self, forKey: .romwbwVersions)
        help = try? container.decodeIfPresent(CatalogHelp.self, forKey: .help)
    }
}

extension RomWBWIndex {

    /// The entries there is something to fetch for - which, since romwbw_emu
    /// v1.44, is every entry the index publishes bar a broken one.
    ///
    /// **This used to be two filters and is now one.** The second took each
    /// entry's `hbios` bytes and asked the core `emu_romwbw_release_supported()`
    /// through the bridge, so a release published after this binary was built
    /// was never offered. That question no longer has an answer: the core loads
    /// any ROM with a readable HBIOS configuration block, and what it actually
    /// depends on - two I/O ports and the set of HBIOS functions
    /// `hbios_dispatch.cc` services - is versioned by the catalog's own name.
    /// Every release a **v0** index publishes speaks v0; an interface change
    /// this core could not service would be published as `index-v1.json`, which
    /// this app ignores by name. So a per-entry filter could only ever hide a
    /// release the user could have booted.
    ///
    /// What survives is the `catalog_url` guard, which is not a release filter:
    /// an entry with nowhere to fetch its catalog from cannot be selected
    /// usefully, and offering it would turn a publishing bug upstream into a
    /// catalog-hop failure here. That is a shorter list rather than a crash.
    /// **The prerelease opt-in.** Since 2026-09-18 the index may carry a RomWBW
    /// development snapshot, flagged `prerelease: true` and never `default`.
    /// romwbw_disks' contract (`docs/CATALOG_SCHEMA.md` 2.3.1) is that a client
    /// MUST NOT offer one unless the user asked, so `includingPrereleases` is
    /// off by default in the setting that feeds it.
    ///
    /// **The release the user is ON is always offered**, whatever the setting
    /// says, and that is the whole reason `keeping` is here. Dropping it from
    /// the list the moment the toggle went off would have three bad ends, all
    /// of them worse than showing one extra row:
    ///
    ///   - a SwiftUI Picker whose selection matches no tag renders BLANK. That
    ///     hazard is documented on `romwbwVersions` and on `preferred` already.
    ///   - moving the selection is refused outright while the machine is
    ///     running, because the disks in the drives belong to the old release
    ///     (see the `romwbwVersion` observer), so the toggle could not act.
    ///   - it would silently discard a choice the user made on purpose.
    ///
    /// So turning it off stops a snapshot being OFFERED and stops it being
    /// recommended; it does not yank the one in use. Pick a stable release and
    /// the snapshot leaves the list on its own.
    static func offered(_ entries: [RomWBWIndexEntry],
                        includingPrereleases: Bool,
                        keeping current: String?) -> [RomWBWIndexEntry] {
        entries.filter { entry in
            guard let url = entry.catalogURL, !url.isEmpty else { return false }
            if entry.isPrerelease && !includingPrereleases {
                return entry.romwbwVersion == current
            }
            return true
        }
    }

    /// Which of the offered releases to select.
    ///
    /// In order:
    ///
    ///   1. `current`, if it is still offered. A user who chose 3.6.0 does not
    ///      get moved off it because the index changed.
    ///
    ///      **`current` is a CHOICE, not "whatever the view model happens to
    ///      hold".** The caller decides which, and getting that wrong is what
    ///      made `default: true` unreachable for a year: `romwbwVersion` is
    ///      seeded with the pre-v0 release so that keys resolve before any index
    ///      arrives, and passing that seed here matched this rule on every
    ///      launch. See `romWBWVersionToKeep` in EmulatorViewModel, which is
    ///      where the distinction lives.
    ///   2. `default: true`. The index promises exactly one, and
    ///      romwbw_disks' release check enforces it, but this still picks the
    ///      first if it ever saw two.
    ///   3. the first survivor, so a list that is somehow all unflagged still
    ///      selects something.
    ///
    /// There used to be a rule between 1 and 2: "the release the BUNDLED ROM
    /// declares", ranked above the index's own recommendation because it was the
    /// one release a fresh install could boot with nothing downloaded. That rule
    /// went with the bundled ROM on 2026-09-08, which settles the question
    /// todo.txt had left open in the direction that note already argued for: a
    /// fresh install has to download disks either way, so there is nothing left
    /// to rank above `default: true`.
    static func preferred(among offered: [RomWBWIndexEntry],
                          keeping current: String?) -> RomWBWIndexEntry? {
        if let current = current,
           let kept = offered.first(where: { $0.romwbwVersion == current }) {
            return kept
        }
        if let flagged = offered.first(where: { $0.isDefault == true }) {
            return flagged
        }
        return offered.first
    }

    /// The same releases in the order a PICKER should list them: newest
    /// published first, which is the index's last entry first.
    ///
    /// The reordering is by INDEX POSITION and by nothing else. It does not
    /// parse "3.6.0", does not compare it with "3.5.1", and does not read
    /// `status` or `generation`. romwbw_disks appends, so the last entry is the
    /// newest thing published; comparing version strings would be a second
    /// source of truth about release order - the index's own order is the
    /// first - and it is the one that sorts "3.10.0" under "3.6.0" and lifts
    /// whatever "3.7.0-rc1" happens to sort above.
    ///
    /// **This is display order, and only the view may read it.** Everything
    /// that DECIDES which release to be on reads the index order:
    /// `preferred(among:keeping:)` above falls back to `offered.first`, so
    /// handing it this array would redefine "the first entry" as "the newest
    /// published entry" - and select exactly the preview release that showing
    /// newest-first is meant to make visible without making it the default.
    /// A separate function rather than a reversal in place, so that rule has
    /// somewhere to be written down and somewhere to be tested.
    static func displayOrder(_ offered: [RomWBWIndexEntry]) -> [RomWBWIndexEntry] {
        offered.reversed()
    }
}

// MARK: - catalog-v0-<ver>.json

/// One ROM the release publishes.
///
/// This is what the app loads, and since build 66 it is the ONLY thing the app
/// loads: there is no ROM in the bundle any more. Every ROM arrives under this
/// `filename` and is refused unless its bytes match this `size` and this
/// `sha256`, so which RomWBW release is running is a fact about a downloaded
/// file that has been checked, and not a second claim compiled into the app.
struct CatalogROM: Decodable, Equatable {
    let id: String
    let filename: String
    let name: String?
    let size: Int64?
    let sha256: String?
    let isDefault: Bool?

    enum CodingKeys: String, CodingKey {
        case id, filename, name, size, sha256
        case isDefault = "default"
    }
}

extension CatalogROM {

    /// What to call it in a picker. `name` is a display string the catalog
    /// provides ("EMU AVW"); the id stands in for a document that omits it,
    /// because a blank row is worse than a terse one.
    var displayName: String {
        if let name = name,
           !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return name
        }
        return id
    }

    /// What is wrong with a copy of this ROM, or nil when its bytes are exactly
    /// what the catalog promised.
    ///
    /// Asked EVERY time the ROM is about to be used, not only after a download.
    /// A ROM is 512 KB and hashing it is nothing; it is also the one file whose
    /// corruption produces a guest that boots to a blank screen with no
    /// diagnosis, so a file that verified when it landed and was truncated
    /// afterwards - a full volume, a restore from a backup, a container edited
    /// by hand - must not go on loading for ever on the strength of that first
    /// check.
    ///
    /// A catalog entry with no `sha256` fails here rather than being waved
    /// through, exactly as a disk without one is refused by the download path:
    /// a gate that cannot verify must not say yes. `size` is checked first
    /// because it is the cheap half and it names the likeliest fault.
    func problem(byteCount: Int64, sha256 measured: String) -> String? {
        if let expected = size, expected != byteCount {
            return "it is \(byteCount) bytes, and the catalog says \(expected)"
        }
        guard let expected = self.sha256?.trimmingCharacters(in: .whitespacesAndNewlines),
              !expected.isEmpty else {
            return "the catalog carries no checksum for it, so it cannot be verified"
        }
        guard expected.lowercased() == measured.lowercased() else {
            return "its checksum is \(String(measured.prefix(16)))…,"
                + " and the catalog says \(String(expected.prefix(16)))…"
        }
        return nil
    }

    /// Does this entry answer to a ROM name something wrote down earlier?
    func answersTo(_ storedName: String) -> Bool {
        CatalogROM.refers(storedName, toID: id, filename: filename)
    }

    /// Does `storedName` mean the ROM with this catalog id?
    ///
    /// The filename first, then the id. A ROM filename carries the release -
    /// `emu_avw-v0-3.6.0.rom` - while what a remembered choice or a saved
    /// profile is really naming is "the emu_avw ROM", which exists under every
    /// release. §6.1 of the schema says to key on `id` for precisely this
    /// reason: not on array position, and not by parsing a filename.
    ///
    /// Static because a stored name has to be matched by this rule - and because it is what makes a build that
    /// stored `"emu_avw.rom"` before ROMs came from the catalog resolve to
    /// `emu_avw-v0-3.5.1.rom` now instead of to nothing.
    static func refers(_ storedName: String, toID romID: String,
                       filename: String) -> Bool {
        let stored = storedName.lowercased()
        guard !stored.isEmpty else { return false }
        if stored == filename.lowercased() { return true }

        let key = romID.lowercased()
        guard !key.isEmpty else { return false }
        // The part before the LAST dot, so a name with no extension is its own
        // stem and `emu_avw.rom` is `emu_avw`.
        let stem = stored.lastIndex(of: ".").map { String(stored[stored.startIndex..<$0]) }
            ?? stored
        // `<id>` and `<id>-<anything>`: the suffix is the interface and the
        // release, and this deliberately does not parse them. It only has to
        // tell one published ROM from another, and their ids differ.
        return stem == key || stem.hasPrefix(key + "-")
    }
}

/// One disk image the release publishes.
///
/// Field names match the JSON exactly, so no CodingKeys: `size` is `size` and
/// not `sizeBytes`, and `defaultSlot` really is camelCase in the document.
/// Getting either wrong is silent - a mistyped `sha256` key does not fail to
/// decode, it decodes to nil, and the download path then refuses every disk
/// with "No checksum in catalog - not saved" and no way for the user to
/// recover.
struct CatalogDisk: Decodable, Equatable {
    let id: String
    let filename: String
    let name: String
    let description: String?
    let size: Int64?
    let sha256: String?
    let license: String?
    let defaultSlot: Int?
}

/// catalog-v0-<ver>.json itself.
struct RomWBWCatalogDocument: Decodable {
    let schema: String?
    let interface: String?
    let romwbwVersion: String?
    let generation: Int?
    let status: String?
    let baseURL: String
    let roms: [CatalogROM]?
    let disks: [CatalogDisk]?

    enum CodingKeys: String, CodingKey {
        case schema, interface, generation, status, roms, disks
        case romwbwVersion = "romwbw_version"
        case baseURL = "base_url"
    }
}

extension RomWBWCatalogDocument {

    /// `disks` and `roms` are absent rather than empty in a document that has
    /// none, and "no ROMs" is a shape this app must survive rather than a
    /// reason to fail.
    var diskEntries: [CatalogDisk] { disks ?? [] }
    var romEntries: [CatalogROM] { roms ?? [] }

    /// The ROM this release considers its default, by the `default` FLAG.
    ///
    /// Not `roms[0]`, and not "the one called emu_avw" - the schema says
    /// neither is promised. Nil when the release publishes no ROMs at all,
    /// which is why every caller has to handle nil.
    var defaultROM: CatalogROM? {
        romEntries.first(where: { $0.isDefault == true }) ?? romEntries.first
    }

    /// Where an asset actually lives.
    ///
    /// `base_url` ends with `/` (romwbw_disks guarantees it, and changing that
    /// would be a v0 break), so this concatenates. The old XML parser appended
    /// its own `"/"` because the compiled-in base had none, and that
    /// inconsistency between the three clients is what v0 removes - do not put
    /// it back.
    ///
    /// The `hasSuffix` test is not that fixup returning: it adds a separator
    /// only when there is none, so it can never produce `//`, and it exists so
    /// that a document which somehow lost its trailing slash yields the right
    /// URL rather than turning every single download into a 404.
    func assetURL(for filename: String) -> String {
        baseURL.hasSuffix("/") ? baseURL + filename : baseURL + "/" + filename
    }
}

// MARK: - What went wrong with a transfer

/// Whether an HTTP response can be parsed at all, in one place for both hops.
///
/// Split out from the view model so the messages can be tested: they are what
/// the user reads when the catalog does not load, and "index fetched, catalog
/// failed" has to be distinguishable from "nothing fetched at all".
enum CatalogTransfer {

    /// Nil when the response is worth parsing, else a sentence naming the
    /// problem in terms a person can act on.
    ///
    /// `statusCode` is nil for a non-HTTP response, which URLSession does not
    /// produce for these URLs but which is not worth failing over. A 404 gets
    /// its own wording: for the second hop it means the release tag exists but
    /// the catalog asset does not, which is a publishing mistake upstream and
    /// not something the user can fix by reconnecting.
    static func problem(errorDescription: String?,
                        statusCode: Int?,
                        byteCount: Int?) -> String? {
        if let error = errorDescription, !error.isEmpty {
            return error
        }
        if let code = statusCode, !(200...299).contains(code) {
            if code == 404 {
                return "the server has no such file (HTTP 404)"
            }
            return "the server answered HTTP \(code)"
        }
        guard let count = byteCount, count > 0 else {
            return "the response was empty"
        }
        return nil
    }

    /// One reason, ended once.
    ///
    /// These strings come from two places with different habits: URLSession's
    /// localizedDescription arrives as a finished sentence ("The Internet
    /// connection appears to be offline.") and everything written here arrives
    /// as a clause ("the server answered HTTP 503"). Concatenating the two
    /// produced "…offline.. The saved list's…", which reads as a typo in the
    /// one message a user sees when nothing works.
    static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return trimmed }
        return ".!?".contains(last) ? trimmed : trimmed + "."
    }
}
