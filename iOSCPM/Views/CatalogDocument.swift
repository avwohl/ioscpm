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
    var displayLabel: String { label ?? "RomWBW \(romwbwVersion)" }

    /// Published as not-yet-recommended. 3.6.0 carries this today.
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

    /// The two bytes `emu_romwbw_release_supported()` wants, or nil when the
    /// index does not say. Nil is treated as "cannot ask, so do not offer":
    /// see `RomWBWIndex.offered(_:supported:)`.
    var versionBytes: (ver: UInt8, upd: UInt8)? {
        guard let ver = RomWBWIndexEntry.hexByte(hbios?.verByte),
              let upd = RomWBWIndexEntry.hexByte(hbios?.updByte) else { return nil }
        return (ver, upd)
    }

    /// `"0x35"` -> `0x35`. Nil for anything that is not one byte of hex, which
    /// includes `"0x350"` - a value that does not fit is not a byte.
    static func hexByte(_ text: String?) -> UInt8? {
        guard var digits = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !digits.isEmpty else { return nil }
        if digits.hasPrefix("0x") || digits.hasPrefix("0X") {
            digits = String(digits.dropFirst(2))
        }
        return UInt8(digits, radix: 16)
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
struct RomWBWIndex: Decodable {
    let schema: String?
    let schemaVersion: Int?
    let interface: String?
    let romwbwVersions: [RomWBWIndexEntry]

    enum CodingKeys: String, CodingKey {
        case schema
        case schemaVersion = "schema_version"
        case interface
        case romwbwVersions = "romwbw_versions"
    }
}

extension RomWBWIndex {

    /// The entries this build can actually run.
    ///
    /// `supported` is the core's own answer - `emu_romwbw_release_supported()`
    /// through the bridge - and not a comparison against a constant in this
    /// app. A client can be built against a newer or an older core than it
    /// expects, so the only honest source for "can this binary boot that
    /// release" is the binary. Hardcoding "offer everything" would break the
    /// first time romwbw_disks publishes a release the core has not been
    /// checked against, which is the case the refusal in `emu_validate_rom_hcb`
    /// exists for.
    ///
    /// An entry with no readable `hbios` bytes, or with no `catalog_url`, is
    /// dropped: there is no way to ask about the first and nothing to fetch for
    /// the second. Both would be publishing bugs upstream, and both are visible
    /// to the caller as a shorter list rather than as a crash.
    static func offered(_ entries: [RomWBWIndexEntry],
                        supported: (UInt8, UInt8) -> Bool) -> [RomWBWIndexEntry] {
        entries.filter { entry in
            guard let url = entry.catalogURL, !url.isEmpty else { return false }
            guard let bytes = entry.versionBytes else { return false }
            return supported(bytes.ver, bytes.upd)
        }
    }

    /// Which of the offered releases to select.
    ///
    /// In order:
    ///
    ///   1. the one already in play, if it is still offered. A user who chose
    ///      3.6.0 does not get moved off it because the index changed.
    ///   2. the release the BUNDLED ROM declares. This app ships one ROM and
    ///      cannot download another yet, so the release it can actually boot
    ///      outranks the index's own `default` - which is a hint for a client
    ///      that can fetch any ROM, and this one is not that client.
    ///   3. `default: true`. The index promises exactly one, and
    ///      romwbw_disks' release check enforces it, but this still picks the
    ///      first if it ever saw two.
    ///   4. the first survivor, so a list that is somehow all unflagged still
    ///      selects something.
    static func preferred(among offered: [RomWBWIndexEntry],
                          keeping current: String?,
                          bundledROMRelease: String?) -> RomWBWIndexEntry? {
        if let current = current,
           let kept = offered.first(where: { $0.romwbwVersion == current }) {
            return kept
        }
        if let bundled = bundledROMRelease,
           let bootable = offered.first(where: { $0.romwbwVersion == bundled }) {
            return bootable
        }
        if let flagged = offered.first(where: { $0.isDefault == true }) {
            return flagged
        }
        return offered.first
    }
}

// MARK: - catalog-v0-<ver>.json

/// One ROM the release publishes.
///
/// Read for what to SAY about a release, not yet for what to load: this build
/// still boots the ROM in its own bundle (docs/ROM_ATTESTATION.md is an App
/// Store filing naming `emu_avw.rom`, and an app whose only ROM is a download
/// has nothing to boot on a first offline launch). Offering these for download
/// is the next release's job.
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
