//
//  DiskLedgerTests.swift
//
//  That an installed disk image is judged stale by where it CAME FROM and not
//  by what its bytes hash to now, and that nothing the app does on its own
//  initiative can overwrite a disk the user has written to.
//
//  `todo.txt` carried, under "The repin has not shipped": "a device that already
//  downloaded it keeps the old R8 after the update, indefinitely ... What the
//  user sees is checksumStatus painting the installed hash red against the
//  catalog's; there is no control that re-downloads it."
//
//  The obvious reading of that - compare the file's hash with the catalog's and
//  re-download when they differ - is the one assertion in this file that exists
//  to forbid something. A downloaded disk is a writable CP/M volume;
//  `saveDownloadedDisks()` writes the running machine's image back over the same
//  file on every warm boot and every backgrounding. So a much-used, perfectly
//  current disk stops matching the catalog the first time somebody saves a file
//  in it, and a refresh keyed on that comparison would overwrite their work with
//  a download. See "the data-loss case" below, which is the section that matters.
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

// The two hashes this repository actually shipped, so the suite is driving the
// real case rather than a made-up one. `be19984e…` is what disks.xml claimed for
// hd1k_combo.img at v1.4.5 and v1.4.11; `89b8ae1a…` is what v1.4.12 claims, and
// what releases/latest now serves.
let oldCombo = "be19984edbcbb901973c268b870587235ea128e3c5e13b80a35d8c9488ec6d6e"
let newCombo = "89b8ae1aaa6867dc515c3511b34c4f0c311a77e99ff71066f5a774bef99cde1d"
// A hash that is neither - what a disk the user has saved a file into looks like.
let userWritten = "1111111111111111111111111111111111111111111111111111111111111111"

let combo = "hd1k_combo.img"
let facts = DiskFileFacts(size: 51_380_224, modified: 1_000_000)

func ledger(_ record: DiskRecord?, name: String = combo) -> DiskLedger {
    guard let record = record else { return DiskLedger() }
    var l = DiskLedger()
    l.setRecord(record, for: name)
    return l
}

func runAllTests() {
    section("A catalog hash is only a hash if it is one")

    check(DiskLedger.normalizedHash(nil) == nil, "nil is not a hash")
    check(DiskLedger.normalizedHash("") == nil,
          "the empty string is not a hash - <sha256></sha256> parses to Optional(\"\"), not to nil")
    check(DiskLedger.normalizedHash("   ") == nil, "whitespace alone is not a hash")
    check(DiskLedger.normalizedHash("abc123") == nil, "a short string is not a hash")
    check(DiskLedger.normalizedHash(String(repeating: "z", count: 64)) == nil,
          "64 non-hex characters are not a hash")
    check(DiskLedger.normalizedHash(oldCombo) == oldCombo, "a real hash survives")
    check(DiskLedger.normalizedHash(oldCombo.uppercased()) == oldCombo,
          "an uppercase catalog hash folds to lowercase rather than reading as permanently stale")
    check(DiskLedger.normalizedHash("  \(newCombo)\n") == newCombo,
          "surrounding whitespace is trimmed - the value comes from XML text")

    // MARK: -

    section("Filenames are matched case-insensitively")

    var folded = DiskLedger()
    folded.setRecord(DiskRecord(installedCatalogSha256: newCombo), for: "HD1K_COMBO.IMG")
    check(folded.record(for: "hd1k_combo.img")?.installedCatalogSha256 == newCombo,
          "a record written under one case is found under the other")
    check(DiskLedger(records: ["HD1K_COMBO.IMG": DiskRecord(installedCatalogSha256: newCombo)])
            .record(for: "hd1k_combo.img") != nil,
          "and folding happens on the way in, so a decoded ledger behaves the same")

    // MARK: -

    section("Nothing can be decided without a usable catalog hash")

    let anyLedger = ledger(DiskRecord(installedCatalogSha256: oldCombo))
    check(anyLedger.freshness(filename: combo, catalogSha256: nil, facts: facts) == .unverifiable,
          "no <sha256> in the catalog entry is .unverifiable")
    check(anyLedger.freshness(filename: combo, catalogSha256: "", facts: facts) == .unverifiable,
          "an empty <sha256> is .unverifiable too")
    check(DiskLedger.action(for: .unverifiable) == DiskRefreshAction.none,
          "and .unverifiable lights no control - the download path refuses such an entry, so an Update button could only fail")
    check(DiskRefreshPolicy.allowsUserRequestedUpdate(for: .unverifiable) == false,
          "not even on an explicit tap")

    // MARK: -

    section("An absent file belongs to the ordinary download path")

    check(DiskLedger().freshness(filename: combo, catalogSha256: newCombo, facts: nil) == .notInstalled,
          "no file is .notInstalled")
    check(DiskLedger.action(for: .notInstalled) == DiskRefreshAction.none,
          "and nothing here acts on it")

    // MARK: -

    section("Provenance, not bytes, decides staleness")

    let currentPristine = DiskRecord(installedCatalogSha256: newCombo,
                                     measuredSha256: newCombo,
                                     measuredSize: facts.size,
                                     measuredModified: facts.modified)
    check(ledger(currentPristine).freshness(filename: combo, catalogSha256: newCombo, facts: facts) == .current,
          "provenance equal to the catalog is .current")

    let supersededPristine = DiskRecord(installedCatalogSha256: oldCombo,
                                        measuredSha256: oldCombo,
                                        measuredSize: facts.size,
                                        measuredModified: facts.modified)
    check(ledger(supersededPristine).freshness(filename: combo, catalogSha256: newCombo, facts: facts)
            == .superseded(locallyModified: false),
          "provenance be19984e against a catalog on 89b8ae1a is superseded, and the bytes are untouched")
    check(DiskLedger.action(for: .superseded(locallyModified: false)) == .refreshAutomatically,
          "a superseded image nobody has written to may be refreshed unasked")

    // MARK: -

    section("THE DATA-LOSS CASE: a disk the user has written to is never replaced unasked")

    // The exact shape that makes this necessary: the user downloaded the CURRENT
    // image and then saved a file inside it. Its bytes no longer hash to anything the
    // catalog knows. It is not stale - it is theirs.
    let currentButWritten = DiskRecord(installedCatalogSha256: newCombo,
                                       measuredSha256: userWritten,
                                       measuredSize: facts.size,
                                       measuredModified: facts.modified)
    check(ledger(currentButWritten).freshness(filename: combo, catalogSha256: newCombo, facts: facts) == .current,
          "a CURRENT disk the user has saved into is still .current - local writes cannot make it stale")
    check(DiskLedger.action(for: .current) == DiskRefreshAction.none,
          "so nothing offers to re-download it, and nothing does")

    // And the harder one: genuinely superseded AND written to.
    let supersededAndWritten = DiskRecord(installedCatalogSha256: oldCombo,
                                          measuredSha256: userWritten,
                                          measuredSize: facts.size,
                                          measuredModified: facts.modified)
    let verdict = ledger(supersededAndWritten).freshness(filename: combo,
                                                         catalogSha256: newCombo, facts: facts)
    check(verdict == .superseded(locallyModified: true),
          "superseded, and the bytes have moved since we wrote them")
    check(DiskLedger.action(for: verdict) == .offerUpdate(lossy: true),
          "that is a BUTTON, marked lossy - never the automatic path")
    check(DiskRefreshPolicy.plan(for: verdict,
                                 network: NetworkCondition(isReachable: true,
                                                           isExpensive: false,
                                                           isConstrained: false),
                                 isMounted: false) == .offerUpdate(lossy: true),
          "and a perfect network does not upgrade it to an automatic refresh")

    // MARK: -

    section("A missing or stale measurement is treated as 'the user may have written to it'")

    let supersededUnmeasured = DiskRecord(installedCatalogSha256: oldCombo)
    check(ledger(supersededUnmeasured).freshness(filename: combo, catalogSha256: newCombo, facts: facts)
            == .needsMeasurement,
          "superseded with no measurement asks to be measured rather than guessing")
    check(DiskLedger.action(for: .needsMeasurement) == .measure,
          "and .needsMeasurement is not an action on the file")

    let sizeMoved = DiskRecord(installedCatalogSha256: oldCombo,
                               measuredSha256: oldCombo,
                               measuredSize: facts.size + 1,
                               measuredModified: facts.modified)
    check(DiskLedger.measurementApplies(sizeMoved, to: facts) == false,
          "a measurement taken against a different size no longer applies")
    let timeMoved = DiskRecord(installedCatalogSha256: oldCombo,
                               measuredSha256: oldCombo,
                               measuredSize: facts.size,
                               measuredModified: facts.modified + 1)
    check(DiskLedger.measurementApplies(timeMoved, to: facts) == false,
          "nor one taken against a different modification time")
    check(DiskLedger.measurementApplies(supersededPristine, to: facts) == true,
          "one taken against both, unchanged, still applies")
    check(DiskLedger.measurementApplies(DiskRecord(installedCatalogSha256: oldCombo,
                                                   measuredSha256: nil,
                                                   measuredSize: facts.size,
                                                   measuredModified: facts.modified),
                                        to: facts) == false,
          "and a record with size and time but no hash is not a measurement")

    // MARK: -

    section("Migration: an install that predates the ledger")

    let noRecord = DiskLedger()
    check(noRecord.freshness(filename: combo, catalogSha256: newCombo, facts: facts) == .needsMeasurement,
          "with no record at all the file has to be hashed before anything is said about it")

    var measured = DiskLedger()
    measured.recordMeasurement(filename: combo, sha256: newCombo, facts: facts)
    check(measured.freshness(filename: combo, catalogSha256: newCombo, facts: facts)
            == .unknownProvenance(matchesCatalog: true),
          "an unrecorded file that hashes to the catalog is unknown-provenance-but-matching")
    check(DiskLedger.action(for: .unknownProvenance(matchesCatalog: true)) == DiskRefreshAction.none,
          "which is as good as current, and nothing is offered")

    var measuredOld = DiskLedger()
    measuredOld.recordMeasurement(filename: combo, sha256: oldCombo, facts: facts)
    let ambiguous = measuredOld.freshness(filename: combo, catalogSha256: newCombo, facts: facts)
    check(ambiguous == .unknownProvenance(matchesCatalog: false),
          "an unrecorded file that does NOT hash to the catalog is genuinely ambiguous")
    check(DiskLedger.action(for: ambiguous) == .offerUpdate(lossy: true),
          "superseded or written-to, there is no evidence here that separates them - so it is a lossy button, never automatic")
    check(DiskRefreshPolicy.allowsUserRequestedUpdate(for: ambiguous) == true,
          "the user may still ask for it explicitly")

    // MARK: -

    section("Adopting provenance for an image that is already current")

    var adopting = DiskLedger()
    adopting.recordMeasurement(filename: combo, sha256: newCombo, facts: facts)
    adopting.adoptProvenanceIfCurrent(filename: combo, catalogSha256: newCombo)
    check(adopting.record(for: combo)?.installedCatalogSha256 == newCombo,
          "a file that hashes to the catalog has its provenance adopted - nineteen of the twenty entries stop being re-hashed")
    check(adopting.freshness(filename: combo, catalogSha256: newCombo, facts: facts) == .current,
          "and it reads .current from then on")

    var notAdopting = DiskLedger()
    notAdopting.recordMeasurement(filename: combo, sha256: oldCombo, facts: facts)
    notAdopting.adoptProvenanceIfCurrent(filename: combo, catalogSha256: newCombo)
    check(notAdopting.record(for: combo)?.installedCatalogSha256 == "",
          "a file that does not hash to the catalog gets NO invented provenance")

    var alreadyKnown = ledger(supersededPristine)
    alreadyKnown.adoptProvenanceIfCurrent(filename: combo, catalogSha256: newCombo)
    check(alreadyKnown.record(for: combo)?.installedCatalogSha256 == oldCombo,
          "and a record that already has provenance is never overwritten by adoption")

    // MARK: -

    section("Recording a verified download")

    var installed = DiskLedger()
    installed.recordInstall(filename: combo, catalogSha256: newCombo, facts: facts)
    check(installed.freshness(filename: combo, catalogSha256: newCombo, facts: facts) == .current,
          "a freshly downloaded image is current")
    check(installed.record(for: combo)?.measuredSha256 == newCombo,
          "and its measurement is free - the download path just hashed the file to verify it")
    check(installed.freshness(filename: combo, catalogSha256: oldCombo, facts: facts)
            == .superseded(locallyModified: false),
          "against an older catalog the same record reads superseded, which is the direction that matters")

    var refused = DiskLedger()
    refused.recordInstall(filename: combo, catalogSha256: "not-a-hash", facts: facts)
    check(refused.record(for: combo) == nil,
          "an install cannot be recorded against a hash that is not one")

    // MARK: -

    section("The network gate, and what it says when it stands down")

    let superseded = DiskFreshness.superseded(locallyModified: false)
    let wifi = NetworkCondition(isReachable: true, isExpensive: false, isConstrained: false)
    let cellular = NetworkCondition(isReachable: true, isExpensive: true, isConstrained: false)
    let lowData = NetworkCondition(isReachable: true, isExpensive: false, isConstrained: true)
    let offline = NetworkCondition(isReachable: false, isExpensive: false, isConstrained: false)

    check(DiskRefreshPolicy.plan(for: superseded, network: wifi, isMounted: false) == .refreshNow,
          "unconstrained and inexpensive: refresh now")
    check(DiskRefreshPolicy.plan(for: superseded, network: cellular, isMounted: false)
            == .deferred(.expensive),
          "cellular: deferred, and the reason is 'waiting for Wi-Fi' rather than an error")
    check(DiskRefreshPolicy.plan(for: superseded, network: lowData, isMounted: false)
            == .deferred(.constrained),
          "Low Data Mode: deferred as constrained")
    check(DiskRefreshPolicy.plan(for: superseded, network: offline, isMounted: false)
            == .deferred(.offline),
          "no network: deferred as offline")
    check(NetworkCondition.unknown.allowsUnattendedTransfer == false,
          "and the value before the monitor has reported fails CLOSED - a cold launch cannot race it into spending cellular data")
    check(DiskRefreshPolicy.plan(for: superseded, network: .unknown, isMounted: false)
            == .deferred(.offline),
          "an unmeasured path defers rather than downloads")
    check(wifi.allowsUnattendedTransfer == true, "and a real Wi-Fi path allows it")

    // MARK: -

    section("A mounted disk is never refreshed under the running machine")

    check(DiskRefreshPolicy.plan(for: superseded, network: wifi, isMounted: true)
            == .deferred(.mounted),
          "replacing a disk the running emulator is booted from undoes itself - the next flush writes the old image back over it")
    check(DiskRefreshDeferral.mounted.isNetwork == false,
          "and being mounted is NOT a network reason, so a tap must not override it")
    check([DiskRefreshDeferral.offline, .expensive, .constrained].allSatisfy { $0.isNetwork },
          "while every network reason is one a tap DOES override - the Update control is offered for those")
    check(DiskRefreshPolicy.plan(for: superseded, network: cellular, isMounted: true)
            == .deferred(.mounted),
          "the machine outranks the network: mounted defers as mounted whatever the path is doing")
    check(DiskRefreshPolicy.plan(for: .current, network: wifi, isMounted: false) == .doNothing,
          "and a current disk is left alone on any network")

    // MARK: -

    section("An explicit tap is allowed where the automatic path is not")

    check(DiskRefreshPolicy.allowsUserRequestedUpdate(for: .superseded(locallyModified: true)) == true,
          "the user may replace their own modified disk if they choose to")
    check(DiskRefreshPolicy.allowsUserRequestedUpdate(for: .current) == false,
          "but there is nothing to ask for on a current one")
    check(DiskRefreshPolicy.allowsUserRequestedUpdate(for: .notInstalled) == false,
          "an absent file is a download, not an update")
    check(DiskRefreshPolicy.allowsUserRequestedUpdate(for: .needsMeasurement) == false,
          "and nothing is offered before the file has been measured")

    // MARK: -

    section("Persistence")

    var round = DiskLedger()
    round.recordInstall(filename: combo, catalogSha256: newCombo, facts: facts)
    round.recordMeasurement(filename: "hd1k_games.img", sha256: oldCombo,
                            facts: DiskFileFacts(size: 8_388_608, modified: 42))
    let text = round.serialized()
    check(text != nil, "a ledger serialises")
    let back = DiskLedger.deserialized(text)
    check(back == round, "and comes back the same")
    check(back.record(for: "HD1K_GAMES.IMG")?.measuredSize == 8_388_608,
          "including through a case change on the way back")
    check(DiskLedger.deserialized(nil).records.isEmpty,
          "no stored value is an empty ledger, not a crash")
    check(DiskLedger.deserialized("{ not json").records.isEmpty,
          "and so is a corrupt one - a half-decoded ledger must never read as 'everything is current'")

    // The modification time is a Double on purpose. A Date round-tripping through
    // JSON that comes back a hair off invalidates every measurement on every launch,
    // which re-hashes the whole 211 MB library for ever.
    let precise = DiskFileFacts(size: 51_380_224, modified: 1_725_000_000.123456)
    var precision = DiskLedger()
    precision.recordMeasurement(filename: combo, sha256: newCombo, facts: precise)
    let reloaded = DiskLedger.deserialized(precision.serialized())
    check(DiskLedger.measurementApplies(reloaded.record(for: combo)!, to: precise),
          "a fractional modification time survives the round trip exactly, so the measurement still applies after a relaunch")
}

@main
enum DiskLedgerTestMain {
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
