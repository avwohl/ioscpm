/*
 * EmulatorViewModel.swift - View model for RomWBW emulator
 */

import SwiftUI
import Combine
import AVFoundation
import CryptoKit

// ROM option with name and filename
struct ROMOption: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let filename: String
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
    var id: String { filename }
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

    // ROM selection
    @Published var selectedROM: ROMOption? {
        didSet {
            if let rom = selectedROM {
                UserDefaults.standard.set(rom.filename, forKey: "selectedROM")
            }
        }
    }
    let availableROMs: [ROMOption] = [
        ROMOption(name: "EMU AVW", filename: "emu_avw.rom"),
    ]

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

    private func persistSelectedDisks() {
        let filenames = selectedDisks.map { $0?.filename ?? "" }
        UserDefaults.standard.set(filenames, forKey: "selectedDisks")
    }

    @Published var availableDisks: [DiskOption] = [
        DiskOption(name: "None", filename: ""),
    ]

    // Downloadable disk catalog - pinned to an explicit ioscpm release (matching
    // the Windows/Android ports). The core's HBIOS identifies as RomWBW v3.5.1;
    // disks from a different RomWBW release print an HBIOS/CBIOS mismatch warning
    // at boot. Bump this tag together with core/ROM upgrades. Help (HelpView)
    // deliberately stays on releases/latest — help floats, disks are pinned.
    //
    // v1.4.12 (2026-09-03) replaces v1.4.5, which served an R8 that hands an
    // unfiltered host basename to F_DELETE: importing a host file whose name
    // contains ? or * made an ambiguous FCB and erased every matching CP/M file
    // first, silently. This repository published the fixed image on 2026-09-01
    // and then went on serving its own users the broken one for two days,
    // because publishing an asset is not the same as shipping it. tools/
    // check-disk-pins.sh exists to make that gap fail rather than go unnoticed.
    //
    // Safe on both counts the release order asks about, checked rather than
    // assumed. The invalidation wipe cannot fire: v1.4.5 and v1.4.12 both carry
    // <disks version="13">, and checkCatalogVersionAndInvalidate only acts on a
    // change - and since build 56 it clears only disks the catalog can give
    // back. And the two catalogs are 7042 bytes each differing on one line, the
    // <sha256> of hd1k_combo.img; byte-diffing the images themselves shows 5,121
    // bytes changed out of 51,380,224, all of it R8.COM, W8.COM and their two
    // directory entries, first difference 1.02 MB in - so the RomWBW generation
    // this comment pins against is byte-identical and the mismatch warning
    // cannot appear.
    private static let releaseTag = "v1.4.12"
    private static let catalogURL = "https://github.com/avwohl/ioscpm/releases/download/\(releaseTag)/disks.xml"
    private static let releaseBaseURL = "https://github.com/avwohl/ioscpm/releases/download/\(releaseTag)"
    /// Which releaseTag the cached catalog on disk was fetched under.  The cache
    /// holds one tag's <sha256> values but parseDiskCatalogXML always rebuilds the
    /// URLs from the CURRENT releaseTag, so a cache from a different pin pairs the
    /// wrong hashes with the right URLs.  See loadCachedCatalog.
    private static let catalogCacheTagKey = "catalogCacheTag"

    @Published var diskCatalog: [DownloadableDisk] = []
    @Published var catalogLoading: Bool = false
    @Published var catalogError: String?

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

    // Disk slot labels
    let diskLabels = ["Disk 0 (OS)", "Disk 1 (OS)", "Disk 2 (OS)", "Disk 3 (Data)"]

    // Boot string - reflects the emulator's NVRAM setting
    // Changed by SYSCONF in ROM or by UI, synced to UserDefaults
    @Published var bootString: String = "" {
        didSet {
            // Save to UserDefaults whenever it changes (from UI or SYSCONF sync)
            UserDefaults.standard.set(bootString, forKey: Self.nvramKey)
        }
    }

    // NVRAM persistence key
    private static let nvramKey = "emulatorNvram"

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
        ProfileStore.decoded(from: UserDefaults.standard.data(forKey: EmulatorViewModel.profileStoreKey))

    private func persistProfiles() {
        if let data = profileStore.encoded() {
            UserDefaults.standard.set(data, forKey: Self.profileStoreKey)
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
            if let rom = availableROMs.first(where: { $0.filename == profile.romFilename }) {
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

        // Restore boot string from NVRAM key
        bootString = UserDefaults.standard.string(forKey: Self.nvramKey) ?? ""

        // Restore the configurable keyboard mapping
        loadKeyMapping()
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
        // Restore saved ROM selection (sync - ROMs are bundled)
        if let savedROM = UserDefaults.standard.string(forKey: "selectedROM") {
            selectedROM = availableROMs.first { $0.filename == savedROM }
        }
        if selectedROM == nil {
            selectedROM = availableROMs.first
        }

        // Fetch disk catalog from remote XML (async - will call restoreDiskSelections when done)
        fetchDiskCatalog()
    }

    /// Restore saved disk selections from UserDefaults, or set defaults
    private func restoreDiskSelections() {
        isRestoringSelections = true
        defer {
            isRestoringSelections = false
            // Once, at the end, with the whole selection settled. The first-run
            // path picks defaults out of the catalog and those do have to be
            // written; it is only the three intermediate states that did not.
            persistSelectedDisks()
        }

        // Check if user has saved selections
        let hasSavedSelections = UserDefaults.standard.stringArray(forKey: "selectedDisks") != nil
        debugPrint("[RestoreDisks] hasSavedSelections=\(hasSavedSelections)")
        debugPrint("[RestoreDisks] availableDisks has \(availableDisks.count) entries:")
        for disk in availableDisks {
            debugPrint("[RestoreDisks]   - '\(disk.filename)' isDownloaded=\(disk.isDownloaded)")
        }

        if hasSavedSelections {
            if let savedDisks = UserDefaults.standard.stringArray(forKey: "selectedDisks") {
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

        // Load selected ROM
        let romFile = selectedROM?.filename ?? "emu_avw.rom"
        debugPrint("[EmulatorVM] Loading ROM: \(romFile)")
        guard emulator?.loadROM(fromBundle: romFile) == true else {
            // The bridge records why: missing from the bundle, unreadable, or
            // rejected by the core's HCB validation (a corrupt or wrong-version
            // image). Saying "not found" for all three sends people hunting for
            // a file that is right there.
            let reason = emulator?.lastROMError ?? "\(romFile) could not be loaded"
            debugPrint("[EmulatorVM] ERROR: Failed to load ROM: \(romFile) - \(reason)")
            showError("Failed to load ROM: \(romFile)\n\(reason)")
            statusText = "Error: \(reason)"
            return false
        }
        debugPrint("[EmulatorVM] ROM loaded successfully: \(romFile)")
        statusText = "ROM loaded: \(selectedROM?.name ?? romFile)"

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

        // Download if needed, otherwise start
        if !neededDownloads.isEmpty {
            statusText = "Downloading \(neededDownloads.count) disk(s)..."
            downloadDisksAndStart(neededDownloads)
        } else if alreadyDownloaded.isEmpty {
            // Nothing selected or all slots empty
            showError("No disks available to load. Please download disks in Settings first.")
            statusText = "Error: No disks"
        } else {
            // All disks ready
            debugPrint("[Start] All disks ready, starting emulator")
            startEmulator()
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
        downloadDiskFromSettings(disk, attemptsRemaining: 3)
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

    /// Load NVRAM from UserDefaults (restores boot config from previous session)
    private func loadNvram() {
        if let setting = UserDefaults.standard.string(forKey: Self.nvramKey) {
            emulator?.setNvramSetting(setting)
            debugPrint("[NVRAM] Loaded setting '\(setting)' from UserDefaults")
        }
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

    // MARK: - Disk Catalog Management

    /// Fetch disk catalog from remote XML, falling back to cached version
    func fetchDiskCatalog() {
        catalogLoading = true
        catalogError = nil

        guard let url = URL(string: Self.catalogURL) else {
            debugPrint("[Catalog] Invalid catalog URL")
            loadCachedCatalog()
            return
        }

        debugPrint("[Catalog] Fetching from: \(Self.catalogURL)")

        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.catalogLoading = false

                if let error = error {
                    self.debugPrint("[Catalog] Fetch error: \(error.localizedDescription)")
                }

                if let httpResponse = response as? HTTPURLResponse {
                    self.debugPrint("[Catalog] HTTP status: \(httpResponse.statusCode)")
                }

                if let data = data, error == nil {
                    self.debugPrint("[Catalog] Received \(data.count) bytes")
                    // Parse and cache the new catalog
                    let result = self.parseDiskCatalogXML(data)
                    self.debugPrint("[Catalog] Parsed \(result.disks.count) disks, version: '\(result.version)'")
                    for disk in result.disks {
                        self.debugPrint("[Catalog]   - '\(disk.filename)' (\(disk.name))")
                    }
                    if !result.disks.isEmpty {
                        // Check if catalog version changed - if so, invalidate the
                        // downloaded disks this catalog can hand back. The NEW
                        // catalog's names, not the old one's: a file the new
                        // catalog does not list cannot be re-downloaded from it,
                        // which is exactly the test for whether deleting it is
                        // recoverable.
                        let notice = self.checkCatalogVersionAndInvalidate(
                            newVersion: result.version,
                            catalogFilenames: Set(result.disks.map { $0.filename }))

                        self.diskCatalog = result.disks
                        self.saveCatalogToCache(data)
                        self.refreshAvailableDisks()
                        self.restoreDiskSelections()
                        // AFTER restoreDiskSelections, which ends by setting
                        // statusText to "Ready - Press Play to start" and so
                        // silently swallowed anything set before it. The status
                        // line was the only trace of an invalidation the user
                        // could see while the alert was being eaten too.
                        if let notice = notice { self.statusText = notice }
                        return
                    }
                }

                // Fetch failed, try cached version
                self.debugPrint("[Catalog] Falling back to cached catalog")
                self.loadCachedCatalog()
            }
        }.resume()
    }

    /// Check if catalog version changed and invalidate the downloaded disks the
    /// catalog is able to hand back.
    ///
    /// **`catalogFilenames` is the whole safety property of this function.** The
    /// version attribute moving means the images behind those names may have
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
    private func checkCatalogVersionAndInvalidate(newVersion: String,
                                                 catalogFilenames: Set<String>) -> String? {
        let storedVersion = UserDefaults.standard.string(forKey: "catalogVersion") ?? ""

        print("[Catalog] Checking version: stored='\(storedVersion)' new='\(newVersion)'")

        if storedVersion.isEmpty {
            // First run - just store the version
            print("[Catalog] First run, storing catalog version: '\(newVersion)'")
            UserDefaults.standard.set(newVersion, forKey: "catalogVersion")
            return nil
        } else if storedVersion != newVersion {
            print("[Catalog] ⚠️ VERSION CHANGED from '\(storedVersion)' to '\(newVersion)'")
            let (cleared, kept) = deleteCatalogDisks(named: catalogFilenames)
            UserDefaults.standard.set(newVersion, forKey: "catalogVersion")

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
            print("[Catalog] Version unchanged: '\(newVersion)'")
        }
        return nil
    }

    /// Load catalog from local cache
    private func loadCachedCatalog() {
        catalogLoading = false
        let cacheURL = downloadsDirectory.appendingPathComponent("disks_catalog.xml")

        // A cache fetched under a different release pin cannot be trusted for
        // DOWNLOADS.  The cached XML carries the <sha256> values of the tag it came
        // from, but parseDiskCatalogXML rebuilds every URL from the tag THIS build
        // is pinned to - so after an app update that moved releaseTag, a device
        // whose first launch has no network would pair the old hashes with the new
        // URLs.  That was survivable while the hash was advisory; since downloads
        // are verified it means three full downloads (49 MB each for the combo)
        // that cannot succeed.  An absent stamp means the cache predates this
        // bookkeeping and its tag is unknowable, which is the same problem.
        //
        // But it must NOT be thrown away wholesale, and the first version of this
        // did exactly that.  This branch fires precisely when the network is down,
        // so there is no refetch to fall back on: emptying diskCatalog would leave
        // start() refusing to boot - it rejects an empty catalog before it ever
        // checks whether anything still needs downloading - and would drop the
        // user's own imported images too, since refreshAvailableDisks() is the only
        // thing that scans the directory.  A user who already had every disk
        // downloaded would have been unable to run the emulator at all, offline,
        // which is worse than the bug being fixed.
        //
        // So keep exactly the entries whose file is already on disk.  Those are
        // never re-downloaded, so their stale <sha256> is never consulted, and the
        // guest can boot.  Everything else is dropped, which is what stops a
        // mismatched hash reaching a download.  The cache file and stamp still go,
        // so the next successful fetch replaces them.
        let cachedTag = UserDefaults.standard.string(forKey: Self.catalogCacheTagKey)
        let cacheExists = FileManager.default.fileExists(atPath: cacheURL.path)
        if cacheExists && cachedTag != Self.releaseTag {
            debugPrint("[Catalog] Cached catalog is from pin '\(cachedTag ?? "unstamped")', this build is pinned to '\(Self.releaseTag)'")
            var salvaged: [DownloadableDisk] = []
            if let data = try? Data(contentsOf: cacheURL) {
                salvaged = parseDiskCatalogXML(data).disks.filter { isDiskDownloaded($0.filename) }
            }
            try? FileManager.default.removeItem(at: cacheURL)
            UserDefaults.standard.removeObject(forKey: Self.catalogCacheTagKey)

            let msg = "Disk catalog is out of date for this version. Connect to the internet to refresh it."
            if salvaged.isEmpty {
                debugPrint("[Catalog] Nothing already downloaded to keep - catalog is empty until a refresh")
                catalogError = msg
                showError(msg)
            } else {
                debugPrint("[Catalog] Keeping \(salvaged.count) already-downloaded disk(s) so the emulator can still start")
                diskCatalog = salvaged
                refreshAvailableDisks()
                restoreDiskSelections()
                catalogError = msg
            }
            return
        }

        if let data = try? Data(contentsOf: cacheURL) {
            let result = parseDiskCatalogXML(data)
            if !result.disks.isEmpty {
                diskCatalog = result.disks
                refreshAvailableDisks()
                restoreDiskSelections()
                return
            }
        }
        catalogError = "No disk catalog available. Connect to internet to download."
        showError("No disk catalog available. Connect to internet to download.")
    }

    /// Save catalog XML to local cache
    private func saveCatalogToCache(_ data: Data) {
        let cacheURL = downloadsDirectory.appendingPathComponent("disks_catalog.xml")
        do {
            // .atomic: a kill or a full disk partway through a plain write leaves a
            // truncated catalog that still carries a matching stamp from an earlier
            // successful write, so it would pass the check above and parse to zero
            // disks.  Temp-file-and-rename makes the file wholly old or wholly new.
            try data.write(to: cacheURL, options: .atomic)
            // Stamp the pin only after the bytes are down.  Stamping a write that
            // failed would claim a cache matching this build when the file on disk
            // is still the previous one.
            UserDefaults.standard.set(Self.releaseTag, forKey: Self.catalogCacheTagKey)
        } catch {
            debugPrint("[Catalog] Failed to cache catalog: \(error.localizedDescription)")
        }
    }

    /// Parse disks.xml into DownloadableDisk array and catalog version
    private func parseDiskCatalogXML(_ data: Data) -> (disks: [DownloadableDisk], version: String) {
        let parser = DiskCatalogXMLParser()
        let disks = parser.parse(data: data, baseURL: Self.releaseBaseURL)
        return (disks, parser.catalogVersion)
    }

    // MARK: - Disk Download Management

    /// Directory where downloaded disk images are stored
    var downloadsDirectory: URL {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let disks = docs.appendingPathComponent("Disks", isDirectory: true)
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
        downloadDiskFromSettings(disk, attemptsRemaining: 3)
    }

    /// Internal settings download with retry logic
    private func downloadDiskFromSettings(_ disk: DownloadableDisk, attemptsRemaining: Int) {
        let attempt = 4 - attemptsRemaining
        debugPrint("[Settings Download] '\(disk.filename)' attempt \(attempt)/3")

        guard let url = URL(string: disk.url) else {
            downloadStates[disk.filename] = .error("Invalid URL")
            return
        }

        downloadStates[disk.filename] = .downloading(progress: 0)

        let task = downloadSession.downloadTask(with: url) { [weak self] tempURL, response, error in
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
                                self.downloadDiskFromSettings(disk, attemptsRemaining: attemptsRemaining - 1)
                            }
                        } else {
                            self.downloadStates[disk.filename] = .error("HTTP error \(httpResponse.statusCode)")
                        }
                    }
                    return
                }
            }

            if let error = error {
                self.debugPrint("[Settings Download] ERROR: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    if attemptsRemaining > 1 {
                        self.debugPrint("[Settings Download] Retrying in 1 second...")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            self.downloadDiskFromSettings(disk, attemptsRemaining: attemptsRemaining - 1)
                        }
                    } else {
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
                            self.downloadDiskFromSettings(disk, attemptsRemaining: attemptsRemaining - 1)
                        }
                    } else {
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
                                self.downloadDiskFromSettings(disk, attemptsRemaining: attemptsRemaining - 1)
                            }
                        } else {
                            self.downloadStates[disk.filename] = .error("Checksum mismatch - not saved")
                        }
                    }
                    return
                }
                self.debugPrint("[Settings Download] SHA256 verified: \(expectedSha256.prefix(16))...")
            } else {
                // No hash means no guarantee, so refuse rather than install.  This
                // is not a hypothetical branch to be lenient about: every one of the
                // 20 entries in the pinned v1.4.5 catalog carries a <sha256>, so an
                // entry without one is a degraded or hostile catalog, not a normal
                // one.  Accepting it silently would have made the whole check
                // optional at the attacker's choosing.
                self.debugPrint("[Settings Download] REFUSED: no SHA256 in catalog for '\(disk.filename)'")
                DispatchQueue.main.async {
                    self.downloadStates[disk.filename] = .error("No checksum in catalog - not saved")
                }
                return
            }

            self.debugPrint("[Settings Download] Moving from \(tempURL.path) to \(destURL.path)")

            do {
                // Remove the existing file only now, with the download verified.
                try? fm.removeItem(at: destURL)
                try fm.moveItem(at: tempURL, to: destURL)
                self.debugPrint("[Settings Download] Move successful")

                DispatchQueue.main.async {
                    self.downloadStates[disk.filename] = .downloaded
                    self.refreshAvailableDisks()
                    self.statusText = "Downloaded: \(disk.name)"
                }
            } catch {
                self.debugPrint("[Settings Download] ERROR moving file: \(error.localizedDescription)")
                DispatchQueue.main.async {
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
        downloadStates[filename] = .notDownloaded
    }

    /// Delete a downloaded disk image
    func deleteDownloadedDisk(_ filename: String) {
        let path = downloadsDirectory.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: path)
        downloadStates[filename] = .notDownloaded
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
    /// asserting that everything went. See checkCatalogVersionAndInvalidate for
    /// why the set is the boundary.
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

    func emulatorHostFileRequestRead(_ suggestedFilename: String) {
        DispatchQueue.main.async {
            // R8 always reads from the Documents/Imports folder — a batch/scripted
            // build that does many R8s never triggers a picker. Use "Import File…"
            // (a user-initiated action) to stage an arbitrary host file into
            // Imports beforehand.
            let fm = FileManager.default
            let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
            let importsDir = docs.appendingPathComponent("Imports", isDirectory: true)
            try? fm.createDirectory(at: importsDir, withIntermediateDirectories: true)

            // The core has already reduced the guest's path to a leaf, and this
            // reduces again rather than trusting that: the name is about to be
            // joined to importsDir, and appendingPathComponent does not escape
            // "..".
            let requested = (suggestedFilename.trimmingCharacters(in: .whitespaces) as NSString)
                .lastPathComponent
            var fileURL: URL?

            if !requested.isEmpty && requested != "." && requested != ".." {
                let specificFile = importsDir.appendingPathComponent(requested)
                if fm.fileExists(atPath: specificFile.path) {
                    fileURL = specificFile
                } else if let contents = try? fm.contentsOfDirectory(
                            at: importsDir, includingPropertiesForKeys: nil) {
                    // CP/M's CCP uppercases the whole command line, so the guest
                    // asks for FOO.COM when the file is foo.com. The native
                    // backend resolves that case-insensitively and so does this;
                    // it matters on a case-sensitive volume, and costs one scan
                    // of a flat folder on any other.
                    fileURL = contents.first {
                        $0.lastPathComponent.compare(requested,
                                                     options: .caseInsensitive) == .orderedSame
                    }
                }
            }

            // Deliberately no "use the first file in the folder" fallback. That
            // is what this used to do when the requested name did not resolve,
            // and R8 has no way to notice: it derives the CP/M name from the
            // path the user typed, so unrelated contents landed in CP/M under
            // the requested name with a success message on both sides.
            guard let url = fileURL else {
                emu_host_file_cancel()
                let what = requested.isEmpty ? "No filename given" : "\(requested) not found"
                self.showError("R8: \(what) in the Imports folder.\n\nPut the file in:\n\(importsDir.path)")
                self.statusText = "R8: \(what) in Imports"
                return
            }

            do {
                let data = try Data(contentsOf: url)
                // The NAMED form. `url` is what actually opened, which is not
                // what the guest asked for whenever the case-insensitive
                // fallback above did the finding - the CCP shouts the command
                // line, so R8 FOO.COM is how a file called foo.com is reached.
                // R8 prints this (HBF_HOST_GETRNAME) instead of echoing the
                // request back at the person who typed it.
                //
                // Called even when the file is empty. `baseAddress` is nil for
                // an empty Data, so guarding on it skipped the hand-off
                // entirely and left the backend parked in WAITING_READ - the
                // read side of the zero-byte hole the write side closed in
                // build 53 (romwbw_emu v1.36, cpmdroid c06fa58). An empty file
                // in Imports is a real file and R8 should make an empty CP/M
                // one out of it, through the same states as any other size.
                data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                    let ptr = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self)
                    emu_host_file_load_named(ptr, data.count, url.path)
                }
                self.statusText = "R8: Loaded \(url.lastPathComponent) (\(data.count) bytes)"
            } catch {
                emu_host_file_cancel()
                self.statusText = "R8: Error reading \(url.lastPathComponent)"
            }
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

// MARK: - XML Parser for Disk Catalog

class DiskCatalogXMLParser: NSObject, XMLParserDelegate {
    private var disks: [DownloadableDisk] = []
    private var currentElement = ""
    private var currentDisk: [String: String] = [:]
    private var currentText = ""
    private var baseURL = ""
    private(set) var catalogVersion: String = ""

    func parse(data: Data, baseURL: String) -> [DownloadableDisk] {
        self.baseURL = baseURL
        disks = []
        catalogVersion = ""

        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()

        return disks
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName
        currentText = ""

        if elementName == "disks" {
            // Extract catalog version from <disks version="1">
            catalogVersion = attributeDict["version"] ?? ""
        } else if elementName == "disk" {
            currentDisk = [:]
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch elementName {
        case "filename":
            currentDisk["filename"] = trimmed
        case "name":
            currentDisk["name"] = trimmed
        case "description":
            currentDisk["description"] = trimmed
        case "size":
            currentDisk["size"] = trimmed
        case "license":
            currentDisk["license"] = trimmed
        case "sha256":
            currentDisk["sha256"] = trimmed
        case "defaultSlot":
            currentDisk["defaultSlot"] = trimmed
        case "disk":
            // End of disk element - create DownloadableDisk
            if let filename = currentDisk["filename"],
               let name = currentDisk["name"] {
                let disk = DownloadableDisk(
                    filename: filename,
                    name: name,
                    description: currentDisk["description"] ?? "",
                    url: "\(baseURL)/\(filename)",
                    sizeBytes: Int64(currentDisk["size"] ?? "0") ?? 0,
                    license: currentDisk["license"] ?? "Unknown",
                    sha256: currentDisk["sha256"],
                    defaultSlot: Int(currentDisk["defaultSlot"] ?? "")
                )
                disks.append(disk)
            }
        default:
            break
        }
    }
}
