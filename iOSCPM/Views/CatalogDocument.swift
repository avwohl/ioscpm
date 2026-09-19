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
    /// True only for the row `placeholder(romwbwVersion:)` builds. Not decoded -
    /// it is absent from `CodingKeys`, so it keeps this default for every entry
    /// that came out of the index.
    ///
    /// Deliberately NOT "has no catalog_url": a PUBLISHED entry can lack one
    /// too (an index bug, which `offered` drops it for), and that is a different
    /// thing from a row this app invented because it had no list at all. They
    /// want different labels, so they need different tests.
    var isPlaceholder: Bool = false
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

    /// `displayLabel` lowercased and cut into words at every non-alphanumeric,
    /// which is what lets `pickerLabel` ask whether the label already says what
    /// `status` says. Splitting on punctuation is the point: the live snapshot
    /// carries its marker inside parentheses.
    private var displayLabelWords: [String] {
        displayLabel.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// The picker row: `"RomWBW 3.6.0 (preview)"`.
    ///
    /// Any status other than "stable" is shown verbatim, not just "preview".
    /// The set is open, and a release marked something this build has never
    /// heard of is exactly the one a user should be told about rather than
    /// offered silently.
    ///
    /// **Unless the label already carries it.** The publisher puts the warning
    /// in `label` for a snapshot - "RomWBW 3.7.0-dev.14 (development snapshot)"
    /// against `"status": "snapshot"` - because `label` is the field every
    /// client renders everywhere, and appending the status to that produced
    /// "RomWBW 3.7.0-dev.14 (development snapshot) (snapshot)".
    ///
    /// The test is for the status as a WORD of the label and not as a
    /// substring, and that is the difference between a cosmetic fix and a
    /// silent one: "rc" is a substring of "Source" and of "March", so a plain
    /// `contains` would drop the marker from "RomWBW 3.8.0 Source Build" - an
    /// unfamiliar status on a label that never mentioned it, which is the exact
    /// case the paragraph above exists for. A status of several words matches
    /// no single word and keeps its marker, which is the safe direction: a
    /// marker shown twice is ugly, one that is never shown is the bug.
    var pickerLabel: String {
        // A PLACEHOLDER MUST NOT READ AS A PUBLISHED RELEASE. When the index
        // hop does not land, `romwbwVersions` becomes exactly one of these -
        // seeded from the release last in play, which on a fresh or migrated
        // install is CatalogMigration.legacyRomWBWVersion, "3.5.1". The row
        // then said "RomWBW 3.5.1", indistinguishable from the real 3.5.1, and
        // a one-row menu offering it looks like an app that has decided rather
        // than one that failed to ask. That is the shape of "it is stuck on
        // 3.5.1 and there is no way to change it".
        if isPlaceholder { return "\(displayLabel) - release list not loaded" }
        let raw = (status ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, normalizedStatus != "stable" else { return displayLabel }
        if displayLabelWords.contains(normalizedStatus) { return displayLabel }
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
                         isPlaceholder: true,
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

    /// What to say about the ROM in bank 0 and the release the machine is set
    /// to, in one string.
    ///
    /// **Pure, and that is what it is for.** Its one caller is
    /// `romWBWReleaseSummary` in EmulatorViewModel, which said "RomWBW 3.7.0
    /// ROM loaded" on a machine set to 3.7.0-dev.14 while it built the string
    /// itself. The rule lives here so it can be tested with no bridge and no
    /// UIKit - nothing in this repository constructs EmulatorViewModel, so a
    /// rule written there is type-checked and never run.
    ///
    /// `loadedByROM` is what the ROM says about itself, read out of the two HCB
    /// bytes by `RomWBWEmulator.loadedRomWBWRelease()` - three numbers, or four
    /// when the patch nibble is non-zero ("3.7.0.1"). `selected` is the catalog
    /// string for the release in play, which is the only one of the two that
    /// can carry a `-dev.14`.
    ///
    /// The measured numbers lead, because asking bank 0 is the whole point of
    /// reading it at all - see `romReleaseMismatchNotice` - and the catalog's
    /// tag is added only where `romServes` says the selection is a pre-release
    /// of exactly what the ROM declares. So a stale 3.6.0 ROM does not acquire
    /// a "-dev.14" because the picker moved, and that is a state a running app
    /// reaches: the emulator is built once in `init()` and the release picker
    /// is not.
    ///
    /// The one pair nothing on this machine can tell apart is a released 3.7.0
    /// ROM while 3.7.0-dev.14 is selected, since a snapshot's HCB is
    /// byte-for-byte what the release it precedes will carry. The wording is
    /// therefore a claim about the SELECTION and never about the bytes.
    /// z80cpmw's About box (`MainWindow.cpp`) says the same thing against the
    /// same `romServes`.
    static func summary(loadedByROM: String?, selected: String) -> String {
        guard let loaded = loadedByROM else {
            return "RomWBW \(selected) selected - no ROM loaded yet"
        }
        if loaded != selected,
           romServes(catalogVersion: selected, declaredByROM: loaded) {
            return "RomWBW \(loaded) ROM loaded - set to RomWBW \(selected),"
                + " a development snapshot the ROM's version bytes cannot spell"
        }
        return "RomWBW \(loaded) ROM loaded"
    }

    /// What this machine is about to run, said before it runs: the release, the
    /// ROM file published under it, and what is in the drives.
    ///
    /// **Pure, and that is what it is for**, exactly as `summary` above is. Its
    /// one caller is `startEmulator()` in EmulatorViewModel, which nothing in
    /// this repository constructs, so a rule written there is type-checked and
    /// never run. It returns lines and prints nothing: the terminal belongs to
    /// the caller, and so does the `"\n"` that `TerminalScreen.write` turns into
    /// CR+LF.
    ///
    /// **The release the machine is SET to, never what the ROM declares.** That
    /// is the choice z80cpmw's `MainWindow::startEmulator` and cpmdroid's
    /// `createMachineBanner` both made, for the reason `summary` spells out
    /// above: two HCB bytes spell three numbers, so asking the loaded image
    /// would print "3.7.0" on a machine running 3.7.0-dev.14. The suffix exists
    /// only in the catalog string and in the v0 filename.
    ///
    /// `diskFilenames` carries one entry per DRIVE and the number printed is
    /// that drive, not the position among the surviving entries: a machine with
    /// one image in drive 2 has to say `Disk 2`. Empty drives are skipped rather
    /// than listed as "(none)", matching both siblings - three of the four are
    /// empty on a default machine, and naming them spends three lines of a
    /// 24-line screen to say nothing.
    ///
    /// Each name is reduced to its last path component. z80cpmw reduces for the
    /// reason this port shares and cpmdroid does not: a slot here may hold a
    /// file the user browsed to, and the container's own path is wider than the
    /// screen on its own. That matters more here than on either sibling, because
    /// `TerminalScreen.write` is the host's printf and stops at the right margin
    /// rather than folding - an over-long line loses its tail in silence. The
    /// longest real case, `Starting RomWBW 3.7.0-dev.14 -
    /// emu_avw-v0-3.7.0-dev.14.rom`, is 58 columns; a disk line is 40.
    ///
    /// **Nothing is invented.** With no release there is no banner at all, which
    /// is the rule the whole ROM gate follows, and with no ROM filename the
    /// release line stands by itself rather than naming a file this app cannot
    /// name - again what both siblings do. Naming ANOTHER release's ROM is the
    /// one thing this must never do, and it cannot: both strings come from the
    /// caller's single selection.
    static func startBanner(release: String,
                            romFilename: String?,
                            diskFilenames: [String?]) -> [String] {
        guard !release.isEmpty else { return [] }

        var first = "Starting RomWBW \(release)"
        let rom = basename(romFilename ?? "")
        if !rom.isEmpty { first += " - \(rom)" }

        var lines = [first]
        for (drive, name) in diskFilenames.enumerated() {
            let leaf = basename(name ?? "")
            if leaf.isEmpty { continue }
            lines.append("  Disk \(drive): \(leaf)")
        }
        return lines
    }

    /// The last path component of `path`, or "" when there is nothing left.
    ///
    /// `split` rather than `NSString.lastPathComponent` for the reason
    /// `ExportPath.leafName` gives: `lastPathComponent` of `"///"` is `"/"`, so a
    /// separator-only string does not reduce to nothing the way an empty one
    /// does, and the caller's test for empty then misses it. This one is not the
    /// guest's data path, so unlike that one it knows only about `/` and has no
    /// fallback name to offer - a banner says less rather than saying something
    /// made up.
    private static func basename(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? ""
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
    /// **This took a `keeping:` argument for one day, and losing it is the
    /// point.** The rule was that the release a user was ON stayed offered
    /// whatever the setting said, so that unticking the box could not move a
    /// machine. The reasoning was that moving it would leave the four slots on
    /// images built for the release being left - an HBIOS/CBIOS mismatch, which
    /// is the whole thing the release mechanism prevents.
    ///
    /// That premise is false here, and z80cpmw reversed the identical decision
    /// on the identical report: a box that is unticked, stays unticked across a
    /// restart, and leaves a -dev release selected describes a machine sitting
    /// on a release its own Settings page will not list.
    /// `applyRomWBWVersionSwitch` deletes nothing and every store it moves off
    /// is keyed per release - the slots, the boot string, the generation, the
    /// images, the saved catalog - so leaving a snapshot is reversible by
    /// switching back, and the mismatch cannot happen. z80cpmw had to BUILD
    /// that reconcile first; ioscpm has had it since the v0 migration.
    ///
    /// So unticking now moves the machine to the index default, and a stored
    /// preference for a snapshot is not honoured while the box is off:
    /// `preferred` only keeps a `current` that is still in this list, so a
    /// config already pairing 3.7.0-dev.14 with the box off returns to the
    /// default on the next launch with nobody touching a control.
    static func offered(_ entries: [RomWBWIndexEntry],
                        includingPrereleases: Bool) -> [RomWBWIndexEntry] {
        entries.filter { entry in
            guard let url = entry.catalogURL, !url.isEmpty else { return false }
            return includingPrereleases || !entry.isPrerelease
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
    ///
    ///      **An empty `current` is not a choice**, and falls through to
    ///      `default: true`. Nothing stops the index publishing a row whose
    ///      `romwbw_version` is "": it is a non-optional String with no
    ///      emptiness gate, and `offered` drops an entry only for want of a
    ///      `catalog_url`, so such a row is decoded, offered, and - without
    ///      this guard - matched by an empty stored value and selected.
    ///      `storedRomWBWVersion()` in EmulatorViewModel refuses an empty
    ///      string as well, which is a different question: that one is about
    ///      what this app has written down, and this one is about what ""
    ///      MEANS here, for every caller.
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
        if let current = current, !current.isEmpty,
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
    /// The slice to boot from INSIDE this image. **Not a drive number.**
    ///
    /// CATALOG_SCHEMA.md 3.3: "the slice a client should boot from when it
    /// mounts this image with no other instruction". It is published only on
    /// `hd1k_combo`, whose only value is 0, and that is the whole reason
    /// reading it as one of the four drives worked for as long as it did - a
    /// release that published 3 on it would have put the combo in drive 3 and
    /// left a first launch with nothing in drive 0.
    ///
    /// Which disks a first launch mounts is `defaultDiskIDs`; the catalog does
    /// not say, and `disks[]` carries no `default` flag the way `roms[]` does.
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

    /// The disks a device with no saved selection gets, drive 0 first.
    ///
    /// **The catalog does not name a default disk**, and this list is the
    /// honest consequence. A `roms[]` entry carries `default: true` and
    /// `defaultROM` above reads it; a `disks[]` entry carries no such flag -
    /// not in CATALOG_SCHEMA.md's field table and not in any published
    /// catalog. `CatalogDisk.defaultSlot` looks like a candidate and is not
    /// one: it is an index INSIDE hd1k_combo and has nothing to say about
    /// which of the four drives an image belongs in.
    ///
    /// So the choice is this app's to make and is written down here rather
    /// than inferred from a field that means something else. Same two ids in
    /// the same order as z80cpmw's `DEFAULT_DISK_IDS` (DiskCatalog.h), and for
    /// the same reasons; both are published by every release in the v0 catalog.
    static let defaultDiskIDs = ["hd1k_combo", "hd1k_games"]

    /// The filename to mount in each of `driveCount` drives on a first launch.
    ///
    /// Nil for a drive `defaultDiskIDs` does not name, and nil for an id this
    /// release does not publish - a drive left empty is the right answer there,
    /// since substituting whatever else the catalog happens to list would put
    /// an arbitrary disk in front of someone who has chosen nothing.
    ///
    /// It takes `(id, filename)` pairs rather than reading this document's own
    /// `diskEntries` because the view model has already turned the document
    /// into `[DownloadableDisk]` by the time `restoreDiskSelections()` needs
    /// the answer, and one rule with two callers is the point.
    static func defaultDiskFilenames(
            driveCount: Int = 4,
            published: [(id: String, filename: String)]) -> [String?] {
        (0..<max(0, driveCount)).map { drive -> String? in
            guard drive < defaultDiskIDs.count else { return nil }
            let wanted = defaultDiskIDs[drive]
            return published.first(where: { $0.id == wanted })?.filename
        }
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

// MARK: - Reading back what this app saved

/// Whether a document that came out of this app's own cache is the one this
/// app put there.
///
/// **Nothing used to ask.** The fetch path gates a catalog twice -
/// `RomWBWIndexEntry.payloadProblem` against the size and checksum the index
/// promised, then `documentProblem` against the release and interface that
/// were asked for - and then writes the bytes to the disk library under
/// `Documents`. That directory is published over `UIFileSharingEnabled` and
/// `LSSupportsOpeningDocumentsInPlace`, so the copy that comes back is not
/// necessarily the copy that went in, and the offline path decoded it and
/// adopted it with no check at all.
///
/// A catalog is exactly the document worth editing. It names the `base_url`
/// every disk image is fetched from AND the `sha256` each one is checked
/// against, so whoever supplies both supplies neither: `downloadDiskFromSettings`
/// would verify an attacker's image against the attacker's hash and report it
/// as good. The same is true of the saved release list, which is where the
/// catalog's own URL and checksum come from - verifying one against the other
/// is circular, and both are in the same user-writable directory.
///
/// So a fetch that passes those gates also records the size and SHA-256 of the
/// bytes it wrote, in `UserDefaults`, and this compares the two.
///
/// **What this does not defend against**, said plainly rather than implied:
/// on Mac Catalyst the preferences store is as reachable as the Documents
/// directory, so the stamp separates them on iOS and is a consistency check on
/// the Mac. See "The cache stamp is a boundary on iOS only" in
/// `KNOWN_PROBLEMS.md`.
enum CachedCatalog {

    /// Adopt the saved copy, decline it, or decline it and throw it away.
    ///
    /// The line between the last two is the one that matters, and it is this:
    /// **delete only what can be proven wrong, never what merely cannot be
    /// checked.**
    ///
    /// Every install that predates the stamp has a cache and no stamp, and
    /// `start()` returns early on an empty `diskCatalog`. Deleting an unstamped
    /// cache on the upgrade launch would leave a device with no connection
    /// nothing to boot and no way back - that file is the only copy, and the
    /// fetch that would replace it is precisely what is unavailable. That is
    /// why an absent stamp keeps the file.
    ///
    /// **And why it is now ADOPTED as well, not merely kept.** This paragraph
    /// used to say that declining to adopt "costs the same launch and is undone
    /// by the next one with a connection". That was wrong in the way that
    /// matters: the launch it costs is the launch with no connection, which is
    /// the only launch on which the cache is load-bearing at all. A device that
    /// had booted offline for weeks would have updated the app and then found
    /// Play refusing, with every byte it needed already on it. Declining and
    /// deleting differ in how long the damage lasts, not in what it is.
    ///
    /// So an unverifiable cache is adopted and marked UNTRUSTED, and the app
    /// refuses the one thing a doctored catalog is worth doctoring for: it will
    /// not start a new transfer while the document it would take the URL and
    /// the expected checksum from cannot be verified. Booting from images that
    /// are already on the device - and were hash-checked when they arrived -
    /// costs the attacker nothing they did not already have, since anyone who
    /// can rewrite the cache can rewrite those images too.
    ///
    /// A stamp that is present and disagrees is a different claim: these bytes
    /// are provably not the ones this app last verified. Keeping them buys
    /// nothing, since they would be declined on every launch from here on.
    enum Verdict: Equatable {
        case verified
        case unverifiable(String)
        case rejected(String)
    }

    /// The stamp check, for either of the two documents this app caches.
    ///
    /// Both halves of the stamp have to be there. They are written together by
    /// one caller, so half a stamp means something lost one of them, and a
    /// gate that cannot verify must not say yes - the same position
    /// `payloadProblem` takes on an index entry with no checksum.
    static func stampVerdict(byteCount: Int,
                             sha256: String,
                             stampedSize: Int?,
                             stampedSHA256: String?) -> Verdict {
        guard let expectedHash = stampedSHA256?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !expectedHash.isEmpty,
              let expectedSize = stampedSize else {
            return .unverifiable("this app has no record of the copy it saved,"
                                 + " so what is on the device cannot be checked")
        }
        if expectedSize != byteCount {
            return .rejected("the saved copy is \(byteCount) bytes,"
                             + " and this app saved \(expectedSize)")
        }
        guard expectedHash.lowercased() == sha256.lowercased() else {
            return .rejected("the saved copy's checksum is \(String(sha256.prefix(16)))…,"
                             + " and this app saved \(String(expectedHash.prefix(16)))…")
        }
        return .verified
    }

    /// The stamp check, plus the two `RomWBWIndexEntry.documentProblem` makes.
    ///
    /// Those two are belt and braces and are documented as such: `interface`
    /// and `romwbw_version` are both optional in the document, so each is a
    /// no-op on a catalog that omits its field, and a document whose bytes
    /// match the stamp is by construction one this app already ran
    /// `documentProblem` over. The stamp is the gate that does the work. They
    /// are still asked, because the file is named for the release and the
    /// stamp is keyed by it, and a cache that somehow ends up under the wrong
    /// name is a 3.6.0 catalog that a 3.5.1 launch would resolve its slots
    /// against.
    static func catalogVerdict(byteCount: Int,
                               sha256: String,
                               stampedSize: Int?,
                               stampedSHA256: String?,
                               document: RomWBWCatalogDocument,
                               expectedRelease: String,
                               expectedInterface: String) -> Verdict {
        let stamp = stampVerdict(byteCount: byteCount,
                                 sha256: sha256,
                                 stampedSize: stampedSize,
                                 stampedSHA256: stampedSHA256)
        guard case .verified = stamp else { return stamp }

        if let interface = document.interface, interface != expectedInterface {
            return .rejected("the saved catalog is interface \(interface),"
                             + " and this app reads \(expectedInterface)")
        }
        if let version = document.romwbwVersion, version != expectedRelease {
            return .rejected("the saved catalog is for RomWBW \(version), not \(expectedRelease)")
        }
        return .verified
    }
}

extension CachedCatalog.Verdict {

    /// Why the saved copy is not being adopted, or nil when it is.
    var problem: String? {
        switch self {
        case .verified: return nil
        case .unverifiable(let why), .rejected(let why): return why
        }
    }

    /// Whether the file should be deleted as well as declined. See `Verdict`.
    var discardsFile: Bool {
        if case .rejected = self { return true }
        return false
    }

    /// Whether the saved copy may be used at all. Only `.rejected` refuses:
    /// bytes this app can prove are not the ones it saved. See `Verdict`.
    var adoptsFile: Bool {
        if case .rejected = self { return false }
        return true
    }

    /// Whether what was adopted may be treated as this app's own. False for an
    /// unstamped copy, which is adopted so the device still boots but must not
    /// be allowed to name a URL to fetch from or a checksum to fetch against.
    var trustworthy: Bool {
        if case .verified = self { return true }
        return false
    }
}
