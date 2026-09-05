//
//  EmulatorProfile.swift
//  iOSCPM
//
//  A named machine: which ROM, which disks in which slots, what it boots, how
//  the terminal behaves and what the navigation keys send.
//
//  `todo.txt` had "no configuration profiles - named sets of ROM, disks, boot
//  string, terminal and key map. KeyProfile (KeyMap.swift) is only the key-map
//  half." This is the other half, and it deliberately CONTAINS the key-map
//  half rather than replacing it: a KeyProfile is still what a set of bindings
//  is called, and an EmulatorProfile records which one is in force.
//
//  Everything here is a value with no UIKit, no emulator and no UserDefaults
//  behind it - the store is handed its bytes and hands bytes back - which is
//  the only reason Tests/EmulatorProfileTests.swift can drive it. The
//  view model owns the one UserDefaults key it lives in, and owns applying it.
//
//  ## What a profile does NOT carry
//
//  The security-scoped bookmarks for file-backed disks (`localDiskBookmarks`).
//  A bookmark is a token issued to THIS installation for a file the user
//  granted access to; it is not a name and it does not mean anything anywhere
//  else. A profile that carried one would either fail to resolve or, worse,
//  look like it had restored a disk it had not. So a slot bound to a local file
//  is recorded as empty, and applying a profile leaves the existing local
//  binding for a slot the profile has nothing to say about.
//
//  The disk CATALOG is not carried either: a profile names disks by filename,
//  and a filename that is no longer in the catalog resolves to nothing rather
//  than to a guess. Applying a profile is therefore best-effort per slot, and
//  says so.
//

import Foundation

/// One saved machine configuration.
struct EmulatorProfile: Codable, Equatable, Identifiable {

    /// Longer than this is not a name, it is a paragraph, and it will not fit
    /// in the picker it has to appear in.
    static let maxNameLength = 40

    var name: String
    /// The ROM's filename: a catalog one, e.g. "emu_avw-v0-3.6.0.rom", or the
    /// bundle's "emu_avw.rom" in a profile saved before ROMs came from the
    /// catalog. Resolved by catalog id rather than by exact name, so a profile
    /// saved under one release still finds the same ROM under another.
    var romFilename: String
    /// Four entries, one per disk unit. A catalog filename, or "" for none.
    var diskFilenames: [String]
    /// What the machine autoboots, as SYSCONF stores it. "" means no autoboot.
    var bootString: String
    /// KeyProfile.rawValue - "WordStar", "VT100/ANSI", "VT52" or "Custom".
    var keyProfileName: String
    /// SpecialKey.rawValue -> termcap-style binding. Only meaningful when
    /// `keyProfileName` is "Custom"; carried regardless so a profile saved from
    /// a preset and later edited still round-trips.
    var keyBindings: [String: String]
    var scrollbackCapacity: Int
    var bellEnabled: Bool
    var warnManifestWrites: Bool
    var showKeyRow: Bool
    var newDiskSizeBytes: Int

    var id: String { name }

    init(name: String,
         romFilename: String = "",
         diskFilenames: [String] = ["", "", "", ""],
         bootString: String = "",
         keyProfileName: String = "WordStar",
         keyBindings: [String: String] = [:],
         scrollbackCapacity: Int = 1000,
         bellEnabled: Bool = true,
         warnManifestWrites: Bool = true,
         showKeyRow: Bool = true,
         newDiskSizeBytes: Int = DiskSize.default.bytes) {
        self.name = EmulatorProfile.sanitized(name: name)
        self.romFilename = romFilename
        self.diskFilenames = EmulatorProfile.sanitized(diskFilenames: diskFilenames)
        self.bootString = bootString
        self.keyProfileName = keyProfileName
        self.keyBindings = keyBindings
        self.scrollbackCapacity = min(max(0, scrollbackCapacity), TerminalScreen.maxScrollbackCapacity)
        self.bellEnabled = bellEnabled
        self.warnManifestWrites = warnManifestWrites
        self.showKeyRow = showKeyRow
        self.newDiskSizeBytes = DiskSize.offered(bytes: newDiskSizeBytes).bytes
    }

    /// Decoding goes through the same normalisation as construction.
    ///
    /// A profile can arrive from a file this app wrote a version ago, or from a
    /// defaults plist somebody edited. A four-slot array with three entries in
    /// it would crash the apply loop, and a scrollback of 2^31 would be applied
    /// verbatim; both are cheaper to fix here than to guard at every reader.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try c.decode(String.self, forKey: .name),
            romFilename: try c.decodeIfPresent(String.self, forKey: .romFilename) ?? "",
            diskFilenames: try c.decodeIfPresent([String].self, forKey: .diskFilenames) ?? [],
            bootString: try c.decodeIfPresent(String.self, forKey: .bootString) ?? "",
            keyProfileName: try c.decodeIfPresent(String.self, forKey: .keyProfileName) ?? "WordStar",
            keyBindings: try c.decodeIfPresent([String: String].self, forKey: .keyBindings) ?? [:],
            scrollbackCapacity: try c.decodeIfPresent(Int.self, forKey: .scrollbackCapacity) ?? 1000,
            bellEnabled: try c.decodeIfPresent(Bool.self, forKey: .bellEnabled) ?? true,
            warnManifestWrites: try c.decodeIfPresent(Bool.self, forKey: .warnManifestWrites) ?? true,
            showKeyRow: try c.decodeIfPresent(Bool.self, forKey: .showKeyRow) ?? true,
            newDiskSizeBytes: try c.decodeIfPresent(Int.self, forKey: .newDiskSizeBytes)
                ?? DiskSize.default.bytes)
    }

    /// One line under the name in the profile list: enough to tell two
    /// profiles apart without opening either.
    var summary: String {
        var parts: [String] = []
        let disks = diskFilenames.filter { !$0.isEmpty }.count
        parts.append(disks == 1 ? "1 disk" : "\(disks) disks")
        if !bootString.isEmpty { parts.append("boot \(bootString)") }
        parts.append(keyProfileName)
        if !bellEnabled { parts.append("bell off") }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// A name that will fit, is not blank, and is not surrounded by space that
    /// makes two profiles look identical in the picker.
    static func sanitized(name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = trimmed.isEmpty ? "Untitled" : trimmed
        return String(collapsed.prefix(maxNameLength))
    }

    /// Exactly four slots, whatever arrived.
    static func sanitized(diskFilenames: [String]) -> [String] {
        var slots = Array(diskFilenames.prefix(4))
        while slots.count < 4 { slots.append("") }
        return slots
    }
}

/// The set of saved profiles, and which one was last applied.
///
/// A value, not a manager: it is decoded from bytes, mutated, and encoded back.
/// Where those bytes live is the view model's business.
struct ProfileStore: Codable, Equatable {

    private(set) var profiles: [EmulatorProfile] = []
    /// The name of the profile last applied, so the picker can show it.
    /// Cleared automatically when that profile is deleted or renamed away.
    private(set) var lastUsedName: String?

    init(profiles: [EmulatorProfile] = [], lastUsedName: String? = nil) {
        self.profiles = profiles
        self.lastUsedName = profiles.contains { $0.name == lastUsedName } ? lastUsedName : nil
    }

    var names: [String] { profiles.map { $0.name } }

    func profile(named name: String) -> EmulatorProfile? {
        profiles.first { $0.name == name }
    }

    var lastUsed: EmulatorProfile? {
        guard let name = lastUsedName else { return nil }
        return profile(named: name)
    }

    /// Add a profile, or replace the one with the same name.
    ///
    /// Replace rather than refuse: "Save Current As" onto an existing name is
    /// how a profile is UPDATED, and there is no other gesture for it. The
    /// caller is the one that knows whether to ask first.
    mutating func save(_ profile: EmulatorProfile) {
        if let index = profiles.firstIndex(where: { $0.name == profile.name }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        sort()
    }

    mutating func delete(named name: String) {
        profiles.removeAll { $0.name == name }
        if lastUsedName == name { lastUsedName = nil }
    }

    /// Rename, refusing a name already taken by a different profile.
    /// Returns the name actually in force, or nil if there was nothing to rename.
    @discardableResult
    mutating func rename(_ old: String, to proposed: String) -> String? {
        guard let index = profiles.firstIndex(where: { $0.name == old }) else { return nil }
        let clean = EmulatorProfile.sanitized(name: proposed)
        if clean == old { return old }
        guard !profiles.contains(where: { $0.name == clean }) else { return nil }
        profiles[index].name = clean
        if lastUsedName == old { lastUsedName = clean }
        sort()
        return clean
    }

    mutating func markUsed(_ name: String) {
        lastUsedName = profiles.contains { $0.name == name } ? name : nil
    }

    /// A name not already taken: "CP/M 2.2", then "CP/M 2.2 2", and so on.
    ///
    /// The suffix goes on before the length cap is applied, so a name at the
    /// limit still gets a distinct one rather than being truncated back onto
    /// the name it was meant to differ from.
    func uniqueName(basedOn base: String) -> String {
        let clean = EmulatorProfile.sanitized(name: base)
        guard profiles.contains(where: { $0.name == clean }) else { return clean }
        var n = 2
        while true {
            let suffix = " \(n)"
            let room = EmulatorProfile.maxNameLength - suffix.count
            let candidate = String(clean.prefix(room)) + suffix
            if !profiles.contains(where: { $0.name == candidate }) { return candidate }
            n += 1
            if n > 999 { return candidate }
        }
    }

    /// Alphabetical, case-insensitively, so the picker does not reorder itself
    /// for reasons the user cannot see.
    private mutating func sort() {
        profiles.sort { $0.name.lowercased() < $1.name.lowercased() }
    }

    // MARK: Bytes in, bytes out

    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    /// Decode, or come back empty.
    ///
    /// An unreadable store is an empty store, never a crash and never a partial
    /// one: profiles are a convenience, and losing them is survivable in a way
    /// that failing to launch is not.
    static func decoded(from data: Data?) -> ProfileStore {
        guard let data, let store = try? JSONDecoder().decode(ProfileStore.self, from: data) else {
            return ProfileStore()
        }
        // Two profiles with the same name cannot both be addressed; keep the
        // first and drop the rest rather than presenting a picker with a
        // duplicate row that selects the wrong one.
        var seen = Set<String>()
        let unique = store.profiles.filter { seen.insert($0.name).inserted }
        return ProfileStore(profiles: unique.sorted { $0.name.lowercased() < $1.name.lowercased() },
                            lastUsedName: store.lastUsedName)
    }
}
