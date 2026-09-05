//
//  DiskLedger.swift
//  iOSCPM
//
//  Whether the disk image sitting in Documents/Disks is still the one the
//  catalog names, and what the app is allowed to do about it when it is not.
//
//  This lives apart from the views for the same reason TerminalDialect,
//  ControlKey, ExportPath, CGAColor, TerminalRendition, TerminalScreen,
//  DiskSize, WindowFrame and EmulatorProfile do: it is a pure value with no
//  UIKit, no URLSession and no FileManager behind it, which is the only reason
//  Tests/DiskLedgerTests.swift can check it on a machine with no Xcode.
//
//  ## The hole this closes
//
//  `disks.xml` carries a `version` attribute, and the invalidation it drove was
//  the only thing that has ever caused an installed image to be replaced.  It
//  fired on a change to that attribute and on nothing else.  The attribute is
//  13 at v1.4.5, v1.4.11 and v1.4.12 alike - left there deliberately, because
//  moving it makes `deleteCatalogDisks(named:)` clear the catalog half of every
//  device's library, including for the builds in service, which still carry the
//  pre-build-56 loop that took every `.img` regardless.
//
//  Build 63 stopped reading that attribute at all: the successor,
//  `checkCatalogGenerationAndInvalidate`, acts only on the v0 catalog's
//  `generation`, which the XML does not carry.  Nothing below changes - a
//  generation bump reaches this file by exactly the path the version attribute
//  did - but the attribute is no longer a way to reach a build 63 device, and
//  is still the old way to reach every build in service.
//
//  So when `hd1k_combo.img` was republished with the fixed `r8.com`, nothing
//  reached a device that already had the old one.  The user could see it -
//  `DiskDownloadRow` painted the installed hash red against the catalog's - and
//  there was no control that re-downloaded it.  That is the gap.
//
//  ## Why the obvious fix destroys user data
//
//  "Hash the file, re-download when it differs from the catalog" is wrong, and
//  wrong in the direction that loses work.  **A downloaded disk is a writable
//  CP/M volume.**  `saveDownloadedDisks()` writes the running machine's image
//  back over `Documents/Disks/<name>.img` on every warm boot and every
//  backgrounding.  The first time a user saves a file inside a catalog disk, its
//  bytes stop matching the catalog for ever - and it is not stale, it is theirs.
//  A refresh keyed on that comparison would silently overwrite 49 MB of somebody's
//  work with a fresh download, on Wi-Fi, unprompted.  That is the standing entry
//  "Data Loss Risk with GitHub Disks" in KNOWN_PROBLEMS.md, automated.
//
//  ## So staleness is decided from provenance, not from bytes
//
//  The ledger records, per filename, **the catalog `<sha256>` that a verified
//  download actually matched**.  That is a fact about which published image these
//  bytes came from, and local writes cannot change it.
//
//      superseded  <=>  recorded provenance != the catalog's current <sha256>
//
//  "Have the bytes moved since we wrote them" is a second, independent question,
//  and it decides only whether replacing them is *lossy*:
//
//      pristine  <=>  the bytes still hash to the provenance we recorded
//
//  A superseded-and-pristine image can be refreshed automatically; nothing is
//  lost.  A superseded image the user has written to is offered as a button with
//  the cost spelled out, and is never replaced on the app's own initiative.
//
//  ## Migration, and the honest limit
//
//  Every install in service has no ledger at all, because nothing has ever
//  written one.  For those, provenance is unknowable: an image that does not hash
//  to the catalog is either the superseded one or one the user has written to,
//  and there is no evidence here that separates them.  Such an image gets the
//  button and never the automatic path.  The automatic half therefore only starts
//  working for images downloaded by a build that carries this file - which is the
//  honest answer, not a shortcoming to be optimised away.
//
//  One case does resolve on its own: an image that already hashes to the catalog
//  is current whoever downloaded it, so its provenance is adopted on sight and it
//  never has to be hashed again.  That covers nineteen of the twenty entries.
//
//  ## Measurement caching
//
//  Hashing the library costs ~211 MB of reads - the twenty catalog entries total
//  210,763,776 bytes - and that cannot happen on every launch.  A measurement is
//  therefore stored beside the provenance with the (size, mtime) it was taken
//  against, and is re-used while both still agree with the file.  The modification
//  time is stored as a `Double` of `timeIntervalSinceReferenceDate` rather than a
//  `Date`: a `Date` round-trips through JSON as a Double anyway, and one that
//  comes back a hair off invalidates every measurement on every launch, which
//  re-hashes the whole library for ever.
//

import Foundation

// MARK: - What is recorded about one installed image

/// The app's record of one file in `Documents/Disks`.
///
/// `installedCatalogSha256` is the load-bearing field and the only one that
/// cannot be recomputed: it says which published image these bytes came from.
/// The rest is a cache of an expensive measurement.
struct DiskRecord: Codable, Equatable {
    /// The catalog `<sha256>` a verified download matched when this file was
    /// installed. Lowercase hex. Never inferred from the bytes on disk - that is
    /// exactly the inference that cannot be made.
    var installedCatalogSha256: String

    /// The last hash actually computed over the file, if one has been.
    var measuredSha256: String?
    /// The size the measurement was taken against.
    var measuredSize: Int64?
    /// The modification time the measurement was taken against, as
    /// `timeIntervalSinceReferenceDate`. A Double on purpose - see the file
    /// comment.
    var measuredModified: Double?

    init(installedCatalogSha256: String,
         measuredSha256: String? = nil,
         measuredSize: Int64? = nil,
         measuredModified: Double? = nil) {
        self.installedCatalogSha256 = installedCatalogSha256
        self.measuredSha256 = measuredSha256
        self.measuredSize = measuredSize
        self.measuredModified = measuredModified
    }
}

/// What the file system says about a file, reduced to the two facts that decide
/// whether a stored measurement still applies. Kept as a value so the decision
/// logic never touches FileManager and stays testable here.
struct DiskFileFacts: Equatable {
    var size: Int64
    var modified: Double

    init(size: Int64, modified: Double) {
        self.size = size
        self.modified = modified
    }
}

// MARK: - Verdicts

/// What is known about one catalog entry's installed copy.
enum DiskFreshness: Equatable {
    /// The catalog carries no usable `<sha256>`, so nothing can be decided - and
    /// nothing should be attempted: the download path refuses such an entry.
    case unverifiable
    /// No file on disk. The ordinary download path owns this case.
    case notInstalled
    /// Provenance recorded and equal to the catalog's current hash.
    case current
    /// Provenance recorded and different from the catalog's current hash. The
    /// publisher moved the bytes. `locallyModified` says whether replacing them
    /// would take anything with it.
    case superseded(locallyModified: Bool)
    /// No provenance recorded - an image installed before this bookkeeping
    /// existed, or one dropped into `Documents/Disks` through the Files app.
    /// `matchesCatalog` is the one thing measurement can still settle.
    case unknownProvenance(matchesCatalog: Bool)
    /// A file is present and has not been hashed yet. Nothing may be decided
    /// until it has been.
    case needsMeasurement
}

/// What the app may do about a verdict, before the network is consulted.
enum DiskRefreshAction: Equatable {
    /// Leave it alone.
    case none
    /// Show an Update control. `lossy` is true when replacing the file would
    /// discard bytes the app did not download - then the control must say so.
    case offerUpdate(lossy: Bool)
    /// Show an Update control *and* refresh without being asked, if the network
    /// allows. Only ever reached for a file proven pristine.
    case refreshAutomatically
    /// Hash the file, then ask again.
    case measure
}

// MARK: - The ledger

/// The per-filename records, and every decision that can be made from them.
///
/// Filenames are matched case-insensitively throughout. `Documents` is published
/// to the Files app on a case-insensitive volume, so a user's `HD1K_COMBO.IMG`
/// and the catalog's `hd1k_combo.img` are one file on one device and two on
/// another; the ledger must not answer differently for them.
struct DiskLedger: Equatable {

    /// Keyed by the LOWERCASED filename. Use `record(for:)` rather than reaching
    /// into this directly.
    private(set) var records: [String: DiskRecord]

    init(records: [String: DiskRecord] = [:]) {
        var folded: [String: DiskRecord] = [:]
        for (name, record) in records {
            folded[DiskLedger.fold(name)] = record
        }
        self.records = folded
    }

    static func fold(_ filename: String) -> String { filename.lowercased() }

    func record(for filename: String) -> DiskRecord? {
        records[DiskLedger.fold(filename)]
    }

    mutating func setRecord(_ record: DiskRecord, for filename: String) {
        records[DiskLedger.fold(filename)] = record
    }

    mutating func removeRecord(for filename: String) {
        records.removeValue(forKey: DiskLedger.fold(filename))
    }

    /// Record a verified download: these bytes came from the image the catalog
    /// currently names, and we know their hash exactly because we just checked it.
    mutating func recordInstall(filename: String,
                                catalogSha256: String,
                                facts: DiskFileFacts?) {
        guard let hash = DiskLedger.normalizedHash(catalogSha256) else { return }
        var record = DiskRecord(installedCatalogSha256: hash)
        if let facts = facts {
            record.measuredSha256 = hash
            record.measuredSize = facts.size
            record.measuredModified = facts.modified
        }
        setRecord(record, for: filename)
    }

    /// Store a hash that was computed over the file, against the facts it was
    /// computed for.
    mutating func recordMeasurement(filename: String,
                                    sha256: String,
                                    facts: DiskFileFacts) {
        guard let hash = DiskLedger.normalizedHash(sha256) else { return }
        var record = record(for: filename)
            ?? DiskRecord(installedCatalogSha256: "")
        record.measuredSha256 = hash
        record.measuredSize = facts.size
        record.measuredModified = facts.modified
        setRecord(record, for: filename)
    }

    /// An image whose bytes already hash to the catalog is current whoever
    /// downloaded it, so its provenance can be adopted rather than left unknown.
    /// This is what stops a migrating install from re-hashing nineteen files on
    /// every launch.
    mutating func adoptProvenanceIfCurrent(filename: String, catalogSha256: String) {
        guard let catalog = DiskLedger.normalizedHash(catalogSha256),
              var record = record(for: filename),
              record.installedCatalogSha256.isEmpty,
              let measured = record.measuredSha256,
              measured == catalog else { return }
        record.installedCatalogSha256 = catalog
        setRecord(record, for: filename)
    }

    // MARK: Decisions

    /// Whether a stored measurement still describes the file on disk.
    static func measurementApplies(_ record: DiskRecord, to facts: DiskFileFacts) -> Bool {
        guard record.measuredSha256 != nil,
              let size = record.measuredSize,
              let modified = record.measuredModified else { return false }
        return size == facts.size && modified == facts.modified
    }

    /// The verdict for one catalog entry.
    ///
    /// `facts` is nil when there is no file. `catalogSha256` is the entry's
    /// `<sha256>` exactly as the catalog gave it, including the empty string an
    /// `<sha256></sha256>` element parses to.
    func freshness(filename: String,
                   catalogSha256: String?,
                   facts: DiskFileFacts?) -> DiskFreshness {
        guard let catalog = DiskLedger.normalizedHash(catalogSha256) else {
            return .unverifiable
        }
        guard let facts = facts else { return .notInstalled }

        let stored = record(for: filename)
        let provenance = stored.map { DiskLedger.normalizedHash($0.installedCatalogSha256) } ?? nil

        if let provenance = provenance {
            if provenance == catalog { return .current }
            // The one image the v0 migration leaves under a hash that disagrees
            // with the catalog naming it, because two toolchains built the same
            // disk and left different slack between the same 94 files. Only the
            // migration can produce this provenance - a download records the
            // catalog it was fetched against - so this cannot bless a corrupt or
            // unrelated file, and it stops applying as soon as a device fetches
            // the canonical image. CatalogMigration.equivalentPriorImage carries
            // the measurements.
            if CatalogMigration.isEquivalentPriorImage(provenance: provenance,
                                                      catalogSha256: catalog) {
                return .current
            }
            // Superseded. Whether replacing it is lossy depends on a measurement
            // that still applies; with no usable measurement, assume the user has
            // written to it. Conservative in the only direction that cannot lose
            // work - it downgrades an automatic refresh to a button.
            guard let record = stored,
                  DiskLedger.measurementApplies(record, to: facts),
                  let measured = record.measuredSha256 else {
                return .needsMeasurement
            }
            return .superseded(locallyModified: measured != provenance)
        }

        // No provenance. A measurement can still settle whether the file IS the
        // catalog's image, which is the common migration case.
        guard let record = stored,
              DiskLedger.measurementApplies(record, to: facts),
              let measured = record.measuredSha256 else {
            return .needsMeasurement
        }
        return .unknownProvenance(matchesCatalog: measured == catalog)
    }

    /// What may be done about a verdict, before the network is consulted.
    static func action(for freshness: DiskFreshness) -> DiskRefreshAction {
        switch freshness {
        case .unverifiable:
            // The download path refuses an entry with no catalog hash, so an
            // Update control here could only ever fail. Do not light it.
            return .none
        case .notInstalled, .current:
            return .none
        case .needsMeasurement:
            return .measure
        case .superseded(let locallyModified):
            return locallyModified ? .offerUpdate(lossy: true) : .refreshAutomatically
        case .unknownProvenance(let matchesCatalog):
            // Matching the catalog is as good as current. Not matching is
            // genuinely ambiguous - superseded, or the user's own work - and
            // ambiguity never earns the automatic path.
            return matchesCatalog ? .none : .offerUpdate(lossy: true)
        }
    }

    // MARK: Persistence

    /// A representation `UserDefaults` can hold. JSON in one string rather than a
    /// nested dictionary, so a partially-written value cannot decode to a
    /// half-ledger that reads as "everything is current".
    func serialized() -> String? {
        guard let data = try? JSONEncoder().encode(records) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deserialized(_ text: String?) -> DiskLedger {
        guard let text = text,
              let data = text.data(using: .utf8),
              let records = try? JSONDecoder().decode([String: DiskRecord].self, from: data)
        else { return DiskLedger() }
        return DiskLedger(records: records)
    }

    // MARK: Hash hygiene

    /// A catalog hash reduced to the one form everything else compares against,
    /// or nil if it is not a SHA256 at all.
    ///
    /// `!= nil` is NOT the test for "the catalog carries a hash":
    /// `<sha256></sha256>` parses to `Optional("")`, because the XML parser
    /// stores whatever it trims from between the tags. Length and alphabet are
    /// checked here so no other caller has to remember.
    static func normalizedHash(_ raw: String?) -> String? {
        guard let raw = raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.count == 64 else { return nil }
        guard trimmed.allSatisfy({ $0.isHexDigit }) else { return nil }
        return trimmed
    }
}

// MARK: - Whether the network allows an unattended download

/// What the path monitor last said. `unknown` is the value before the monitor
/// has reported, and it fails CLOSED - a cold launch must not race the first
/// callback into starting a 49 MB download on somebody's cellular data.
struct NetworkCondition: Equatable {
    var isReachable: Bool
    var isExpensive: Bool
    var isConstrained: Bool

    init(isReachable: Bool, isExpensive: Bool, isConstrained: Bool) {
        self.isReachable = isReachable
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
    }

    /// Nothing has been measured yet: unreachable, expensive and constrained.
    static let unknown = NetworkCondition(isReachable: false,
                                          isExpensive: true,
                                          isConstrained: true)

    /// The only shape an unattended refresh is allowed to run on.
    var allowsUnattendedTransfer: Bool {
        isReachable && !isExpensive && !isConstrained
    }
}

/// Why an automatic refresh is not happening, in terms a status line can use.
enum DiskRefreshDeferral: Equatable {
    case offline
    case expensive
    case constrained
    /// The emulator is running with this disk in a slot. Not a network reason,
    /// and the one deferral an explicit tap must NOT override - see
    /// `allowsUserRequestedUpdate`.
    case mounted

    var explanation: String {
        switch self {
        case .offline:     return "waiting for a network"
        case .expensive:   return "waiting for Wi-Fi"
        case .constrained: return "waiting for a network that is not in Low Data Mode"
        case .mounted:     return "stop the emulator to update this disk"
        }
    }

    /// True when waiting on the network rather than on the machine. The Update
    /// control is offered for these - restricting the automatic half is only
    /// defensible because a tap still works on any network.
    var isNetwork: Bool { self != .mounted }
}

/// The final word on one disk: do it now, offer it, or say why not.
enum DiskRefreshPlan: Equatable {
    case doNothing
    case offerUpdate(lossy: Bool)
    case refreshNow
    case deferred(DiskRefreshDeferral)
}

enum DiskRefreshPolicy {

    /// Combine the ledger's verdict with the network and with what the emulator
    /// is doing.
    ///
    /// `isMounted` is true when the file is selected in a slot **and** the
    /// emulator is running. Replacing it then undoes itself: the next flush
    /// writes the in-memory image straight back over the fresh download. So the
    /// automatic path stands down and the control is offered instead.
    static func plan(for freshness: DiskFreshness,
                     network: NetworkCondition,
                     isMounted: Bool) -> DiskRefreshPlan {
        switch action(for: freshness) {
        case .none, .measure:
            return .doNothing
        case .offerUpdate(let lossy):
            return .offerUpdate(lossy: lossy)
        case .refreshAutomatically:
            // Not while the machine is running off it. Replacing the file then
            // undoes itself - saveDownloadedDisks() writes the in-memory image
            // straight back over the download on the next flush, and the ledger
            // would meanwhile record the new hash as this file's provenance,
            // leaving a superseded image permanently labelled current.
            if isMounted { return .deferred(.mounted) }
            guard network.isReachable else { return .deferred(.offline) }
            if network.isExpensive { return .deferred(.expensive) }
            if network.isConstrained { return .deferred(.constrained) }
            return .refreshNow
        }
    }

    private static func action(for freshness: DiskFreshness) -> DiskRefreshAction {
        DiskLedger.action(for: freshness)
    }

    /// An explicit tap. It is allowed on any network - that is what makes the
    /// automatic half safe to restrict - but it is still refused for an entry the
    /// download path would refuse anyway.
    ///
    /// It does NOT override a mounted disk: see `plan(for:network:isMounted:)`.
    /// The caller has to check that separately, because this function is about
    /// the catalog and the file, and being mounted is about the machine.
    static func allowsUserRequestedUpdate(for freshness: DiskFreshness) -> Bool {
        switch freshness {
        case .unverifiable, .notInstalled, .current:
            return false
        case .needsMeasurement:
            return false
        case .superseded:
            return true
        case .unknownProvenance(let matchesCatalog):
            return !matchesCatalog
        }
    }
}
