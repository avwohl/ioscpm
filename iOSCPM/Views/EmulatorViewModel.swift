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
            // Save selected disk filenames to UserDefaults
            let filenames = selectedDisks.map { $0?.filename ?? "" }
            UserDefaults.standard.set(filenames, forKey: "selectedDisks")
        }
    }

    @Published var availableDisks: [DiskOption] = [
        DiskOption(name: "None", filename: ""),
    ]

    // Downloadable disk catalog - pinned to an explicit ioscpm release (matching
    // the Windows/Android ports). The core's HBIOS identifies as RomWBW v3.5.1;
    // disks from a different RomWBW release print an HBIOS/CBIOS mismatch warning
    // at boot. Bump this tag together with core/ROM upgrades. Help (HelpView)
    // deliberately stays on releases/latest — help floats, disks are pinned.
    private static let releaseTag = "v1.4.5"
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

    /// Send a remapped navigation key's byte sequence to the guest.
    func sendSpecialKey(_ key: SpecialKey) {
        scrollToLiveBottom()
        for b in keyMap.bytes(for: key) {
            emulator?.sendCharacter(unichar(b))
        }
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

    // VDA terminal state (25x80 character cells)
    @Published var terminalCells: [[TerminalCell]] = []
    @Published var cursorRow: Int = 0
    @Published var cursorCol: Int = 0

    // Scrollback: full lines that have scrolled off the top of the live viewport.
    private var scrollbackLines: [[TerminalCell]] = []
    // Scrollback capacity in lines. User-configurable (Settings); 0 disables
    // capture. Persisted under `scrollbackLines` and clamped 0...100000, matching
    // the z80cpmw `display.scrollbackLines` schema (default 1000).
    static let scrollbackCapacityKey = "scrollbackLines"
    static let scrollbackCapacityDefault = 1000
    static func loadScrollbackCapacity() -> Int {
        let v = UserDefaults.standard.object(forKey: scrollbackCapacityKey) as? Int ?? scrollbackCapacityDefault
        return min(max(0, v), 100000)
    }
    @Published var scrollbackCapacity: Int = EmulatorViewModel.loadScrollbackCapacity() {
        didSet {
            let clamped = min(max(0, scrollbackCapacity), 100000)
            if clamped != scrollbackCapacity { scrollbackCapacity = clamped; return }
            UserDefaults.standard.set(clamped, forKey: Self.scrollbackCapacityKey)
            applyScrollbackCapacity()
        }
    }
    // How many lines the user has scrolled up from the live bottom (0 = live).
    @Published var scrollbackOffset: Int = 0

    var isScrolledBack: Bool { scrollbackOffset > 0 }
    var scrollbackAvailable: Int { scrollbackLines.count }

    /// The `terminalRows` rows currently visible: the live grid when at the
    /// bottom, or a window into (scrollback + live) when scrolled up.
    var displayCells: [[TerminalCell]] {
        guard scrollbackOffset > 0 else { return terminalCells }
        let total = scrollbackLines + terminalCells
        let bottomExclusive = max(0, total.count - scrollbackOffset)
        let start = max(0, bottomExclusive - terminalRows)
        var slice = Array(total[start..<bottomExclusive])
        if slice.count > terminalRows { slice = Array(slice.suffix(terminalRows)) }
        while slice.count < terminalRows {
            slice.append(Array(repeating: TerminalCell(), count: terminalCols))
        }
        return slice
    }

    /// Scroll the viewport by `lines` (positive = back into history, negative =
    /// toward the live bottom). Clamped to the available scrollback.
    func adjustScrollback(byLines lines: Int) {
        let clamped = min(max(0, scrollbackOffset + lines), scrollbackLines.count)
        if clamped != scrollbackOffset { scrollbackOffset = clamped }
    }

    /// Snap back to the live bottom of the terminal.
    func scrollToLiveBottom() {
        if scrollbackOffset != 0 { scrollbackOffset = 0 }
    }

    /// Drop the transcript of the session that just ended.
    ///
    /// Called from both places a fresh session begins, rather than written out
    /// at each, because only one of them used to do it: reset() cleared the
    /// history and startEmulator() did not, so Stop then Play left the dead
    /// machine's output above the new banner and could open already parked in
    /// history. z80cpmw calls resetScrollback() from both of its own, and this
    /// carries the name for that reason.
    private func resetScrollback() {
        if !scrollbackLines.isEmpty { scrollbackLines.removeAll() }
        if scrollbackOffset != 0 { scrollbackOffset = 0 }
    }

    /// Apply a changed capacity to the existing buffer: 0 clears history, a
    /// smaller cap trims the oldest lines. New captures honour the cap in scrollUp.
    private func applyScrollbackCapacity() {
        let cap = scrollbackCapacity
        if cap == 0 {
            if !scrollbackLines.isEmpty { scrollbackLines.removeAll() }
            if scrollbackOffset != 0 { scrollbackOffset = 0 }
        } else if scrollbackLines.count > cap {
            scrollbackLines.removeFirst(scrollbackLines.count - cap)
            if scrollbackOffset > cap { scrollbackOffset = cap }
        }
    }

    private var emulator: RomWBWEmulator?

    // Audio engine for beep
    private var audioEngine: AVAudioEngine?
    private var tonePlayer: AVAudioPlayerNode?

    // Periodic disk auto-save timer
    private var diskSaveTimer: Timer?

    // Terminal dimensions
    let terminalRows = 25
    let terminalCols = 80

    // VT100/ANSI escape sequence parser state
    private enum EscapeState {
        case normal
        case escape          // Received ESC
        case csi             // Received ESC [
        case csiParam        // Collecting CSI parameters
        case vt52Row         // Received ESC Y, expecting the row byte (value + 0x20)
        case vt52Col         // Received ESC Y <row>, expecting the col byte (value + 0x20)
        case escConsumeOne   // Swallow one byte (charset/line-size designation)
    }
    private var escapeState: EscapeState = .normal
    private var escapeParams: [Int] = []
    private var escapeCurrentParam: String = ""
    /// True once a private-parameter marker - '?', '<', '=' or '>' - has been
    /// seen in the current CSI sequence.
    private var escapePrivateMode: Bool = false
    private var savedCursorRow: Int = 0
    private var savedCursorCol: Int = 0
    /// The current graphic rendition: the CGA attribute byte, the three
    /// per-cell face flags, and the reverse-video toggle. The whole of SGR
    /// lives in TerminalRendition.swift, which has no screen behind it and is
    /// therefore the one part of this parser the test suite can reach.
    private var rendition = TerminalRendition()

    /// DECAWM (ESC[?7h / l). On - the default, and what a VT100 powers up as -
    /// writing the last column arms `pendingWrap`. Off, the cursor stays put and
    /// each further character overwrites the last cell.
    private var autoWrap = true

    /// DECTCEM (ESC[?25h / l). Full-screen programs hide the cursor while they
    /// redraw so it does not strobe around the screen. Kept separate from the
    /// blink phase and from `isScrolledBack`, which suppress drawing for their
    /// own reasons.
    @Published var cursorVisible = true

    /// The current attribute as it should actually be drawn.
    private var displayAttr: UInt8 {
        rendition.displayAttr
    }

    /// The cell every erase leaves behind: a space in the CURRENT rendition,
    /// not a default one. This is background-colour-erase, what a real VT and
    /// xterm do, and it is why a program can set a colour, clear, and get a
    /// screen of that colour.
    ///
    /// The nibbles are unpacked exactly as the glyph-write path unpacks them
    /// (see emulatorVDAWriteChar), so an erased cell and a character written
    /// into it afterwards always agree - which is the whole point. Filling with
    /// a hardcoded fg 7 / bg 0 was only survivable while the erase also reset
    /// the rendition to that same default, and this file's erases never did.
    ///
    /// z80cpmw's TerminalView::blankCell() is the same function; cpmdroid's
    /// ED/EL already fill from the current rendition, and the web frontend gets
    /// it from xterm.js. This port was the last one filling with a default.
    ///
    /// The machine-level paths (reset(), startEmulator()) must put the
    /// rendition back to 0x07 BEFORE they clear, or a fresh boot inherits the
    /// colour the dead session ended on.
    /// The flags are deliberately NOT carried. Underline and blink are visible
    /// on a space, so an erase that kept them would draw a rule under all 2000
    /// cells after ESC[4m ESC[2J - z80cpmw zeroes them at the same site and for
    /// the same reason. The colours are carried, which is the whole point of
    /// this being background-colour-erase.
    private var blankCell: TerminalCell {
        let attr = displayAttr
        return TerminalCell(character: " ",
                            foreground: attr & 0x0F,
                            background: (attr >> 4) & 0x07,
                            flags: 0)
    }
    private var scrollTop: Int = 0         // Top of scrolling region (0-based)
    private var scrollBottom: Int = 24     // Bottom of scrolling region (0-based, inclusive)

    // Deferred autowrap (VT100 "last column" behavior): after a glyph is written
    // to the rightmost column the cursor stays put and we only wrap when the next
    // printable character arrives. Without this, writing to the bottom-right corner
    // scrolls the screen and corrupts any full-screen layout (WordStar, Zork, the
    // TERMDEF border test, etc.).
    private var pendingWrap: Bool = false
    // Which terminal we are pretending to be. Default is ANSI/VT100; see
    // TerminalDialect for how a stream switches it and why that is delicate.
    // Only ESC D / E / H and the ESC Z reply differ by dialect, so ANSI
    // behavior is unchanged while this stays .ansi.
    private var dialect = TerminalDialect()
    private var vt52CursorRow: Int = 0     // Row latched while parsing ESC Y <row> <col>

    override init() {
        super.init()

        // Initialize terminal cells
        terminalCells = Array(repeating: Array(repeating: TerminalCell(), count: terminalCols), count: terminalRows)

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
        let versionStr = "Z80CPM v\(version).\(build) \(buildDate)"
        for (i, char) in versionStr.enumerated() where i < terminalCols {
            terminalCells[0][i].character = char
        }

        // Show "Press Play" message centered
        let message = "Press Play to start, then"
        let startCol = (terminalCols - message.count) / 2
        let startRow = terminalRows / 2

        for (i, char) in message.enumerated() {
            terminalCells[startRow][startCol + i].character = char
        }

        let hint = "C<ret> start CP/M   2<ret> boot slice 0"
        let hintCol = (terminalCols - hint.count) / 2
        for (i, char) in hint.enumerated() {
            terminalCells[startRow + 1][hintCol + i].character = char
        }
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
        defer { isRestoringSelections = false }

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

    func createNewDisk(at url: URL, size: Int = defaultDiskSize) {
        guard url.startAccessingSecurityScopedResource() else {
            showError("Cannot access location")
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        // Create empty disk image (filled with 0xE5 like formatted CP/M disk)
        let data = Data(repeating: 0xE5, count: min(size, Self.maxDiskSize))

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

        // Cold boot returns the terminal to its ANSI/VT100 default. This block
        // runs BEFORE the screen is cleared, not after: an erase now paints the
        // current SGR background, so clearing first and resetting the rendition
        // second would leave the screen in the dying session's colour.
        // clearTerminal() resets the rendition itself for the same reason -
        // startEmulator() has no such block in front of it - and this covers
        // the rest of the power-on state.
        dialect.reset()
        escapeState = .normal
        // Both DEC modes back to power-on: a guest that hid the cursor and then
        // died must not leave it hidden for the next session, and DECAWM off is
        // just as sticky.
        autoWrap = true
        cursorVisible = true

        clearTerminal()
        // A cold boot starts a fresh session — drop the old scrollback history.
        resetScrollback()
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

    /// Erase the whole screen and home the cursor. Nothing else: not the
    /// rendition, not the parser state, not the scrolling region.
    ///
    /// This is what ESC[2J, VT52 ESC E and the HBIOS VDA clear mean.
    /// Erase-in-display says what to do with the cells and says nothing about
    /// the terminal's modes, so a program that sets a colour, sets a scrolling
    /// region and then clears its screen must come back to both still in force.
    /// The scrolling-region reset that used to live here was a bug of exactly
    /// that kind - ED is not DECSTBM - and it now belongs to clearTerminal()
    /// alone. z80cpmw split the same two jobs apart for the same reason; see
    /// its TerminalView::eraseScreen().
    ///
    /// Homing the cursor IS the one thing here a strict VT100 would not do, and
    /// it stays: both sibling ports home it, and CP/M software written against
    /// ANSI.SYS expects ESC[2J to home.
    func eraseScreen() {
        for row in 0..<terminalRows {
            for col in 0..<terminalCols {
                terminalCells[row][col] = blankCell
            }
        }
        cursorRow = 0
        cursorCol = 0
        pendingWrap = false
    }

    /// Erase the screen AND put the terminal back to power-on state. This is
    /// the machine-level clear - Start and Reset - and no guest sequence
    /// reaches it.
    ///
    /// The rendition goes back to the default FIRST, because eraseScreen()
    /// paints the current one: reset it afterwards and a fresh boot would be
    /// filled with whatever colour the last session happened to end on.
    func clearTerminal() {
        rendition.reset()
        eraseScreen()
        scrollTop = 0
        scrollBottom = terminalRows - 1
    }

    /// Write a string to the terminal at the current cursor position
    private func writeToTerminal(_ text: String) {
        for char in text {
            if char == "\n" {
                cursorRow += 1
                cursorCol = 0
                if cursorRow >= terminalRows {
                    cursorRow = terminalRows - 1
                }
            } else {
                if cursorCol < terminalCols {
                    terminalCells[cursorRow][cursorCol].character = char
                    terminalCells[cursorRow][cursorCol].foreground = 7  // White
                    cursorCol += 1
                }
            }
        }
    }

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
    /// This is the least destructive of the four options `todo.txt` listed and
    /// forecloses none of the others — a confirmation step or copy-on-write can
    /// still be added in front of it. What it cannot do is help the builds
    /// already in service: the App Store serves 1.4.9 (builds 36/37), those
    /// fetch the catalog from `releases/latest/download/` rather than from a
    /// pinned tag, and they carry the old loop. That is why the release order
    /// still matters and why `--prerelease` is load-bearing; see `todo.txt`.
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

// MARK: - Terminal Cell

struct TerminalCell: Equatable {
    var character: Character = " "
    var foreground: UInt8 = 7  // White
    var background: UInt8 = 0  // Black

    /// CellFlags.bold / .underline / .blink - the per-cell face, which the
    /// packed CGA byte above has no room for. See TerminalRendition.swift for
    /// the bit values, which are z80cpmw's and cpmdroid's byte for byte.
    ///
    /// Reverse video is deliberately absent: it is resolved into the two
    /// colours at the write, which is what makes SGR 7 and 27 exact inverses.
    var flags: UInt8 = 0
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
        // eraseScreen(), not clearTerminal(): this is the guest asking HBIOS to
        // clear the display, which fills with the attribute the guest last set
        // through emulatorVDASetAttr. It is not a machine reset, so it must not
        // take the rendition or the scrolling region with it.
        DispatchQueue.main.async {
            self.eraseScreen()
        }
    }

    func emulatorVDASetCursorRow(_ row: Int32, col: Int32) {
        DispatchQueue.main.async {
            self.cursorRow = min(max(Int(row), 0), self.terminalRows - 1)
            self.cursorCol = min(max(Int(col), 0), self.terminalCols - 1)
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

    /// Process a character through the VT100/ANSI escape sequence parser
    private func processCharacter(_ ch: unichar) {
        switch escapeState {
        case .normal:
            processNormalChar(ch)

        case .escape:
            processEscapeChar(ch)

        case .csi, .csiParam:
            processCSIChar(ch)

        case .vt52Row:
            // VT52 direct cursor address: row is the byte value biased by 0x20
            vt52CursorRow = min(max(Int(ch) - 0x20, 0), terminalRows - 1)
            escapeState = .vt52Col

        case .vt52Col:
            // VT52 direct cursor address: col is the byte value biased by 0x20
            cursorRow = vt52CursorRow
            cursorCol = min(max(Int(ch) - 0x20, 0), terminalCols - 1)
            pendingWrap = false
            escapeState = .normal

        case .escConsumeOne:
            // Swallow the single parameter byte of a charset/line-size designation.
            escapeState = .normal
        }
    }

    /// Process character in normal (non-escape) state
    private func processNormalChar(_ ch: unichar) {
        switch ch {
        case 0x07: // Bell
            playBeep(durationMs: 100)

        case 0x08: // Backspace
            pendingWrap = false
            if cursorCol > 0 {
                cursorCol -= 1
            }

        case 0x09: // Tab
            pendingWrap = false
            cursorCol = min((cursorCol + 8) & ~7, terminalCols - 1)

        case 0x0A: // Line feed (with implicit CR for compatibility)
            pendingWrap = false
            cursorCol = 0  // Reset column for Unix-style LF-only files
            if cursorRow < scrollTop {
                // Above scrolling region - just move down
                cursorRow += 1
            } else if cursorRow < scrollBottom {
                // Within scrolling region but not at bottom - move down
                cursorRow += 1
            } else if cursorRow == scrollBottom {
                // At bottom of scrolling region - scroll the region
                scrollRegion(scrollTop, scrollBottom, 1)
                // cursorRow stays at scrollBottom
            }
            // If cursorRow > scrollBottom (below region), do nothing

        case 0x0D: // Carriage return
            pendingWrap = false
            cursorCol = 0

        case 0x1B: // ESC - start escape sequence
            escapeState = .escape
            escapeParams = []
            escapeCurrentParam = ""
            escapePrivateMode = false

        default:
            // Printable character
            if ch >= 0x20 && ch <= 0x7E {
                // Resolve a deferred wrap left armed by the previous last-column write.
                if pendingWrap {
                    cursorCol = 0
                    cursorRow += 1
                    if cursorRow >= terminalRows {
                        scrollUp(1)
                        cursorRow = terminalRows - 1
                    }
                    pendingWrap = false
                }
                let char = Character(UnicodeScalar(ch) ?? UnicodeScalar(32))
                terminalCells[cursorRow][cursorCol].character = char
                let attr = displayAttr
                terminalCells[cursorRow][cursorCol].foreground = attr & 0x0F
                terminalCells[cursorRow][cursorCol].background = (attr >> 4) & 0x07
                terminalCells[cursorRow][cursorCol].flags = rendition.flags
                if cursorCol >= terminalCols - 1 {
                    // At the rightmost column: arm a deferred wrap instead of
                    // moving now, so writing the corner cell does not scroll the
                    // screen. With DECAWM off there is no wrap to arm and the
                    // cursor simply stays on the last column, overwriting it.
                    if autoWrap { pendingWrap = true }
                } else {
                    cursorCol += 1
                }
            }
        }
    }

    /// Process character after ESC received
    private func processEscapeChar(_ ch: unichar) {
        // Settle the dialect first, so the cases below read a current answer.
        // This subsumes the per-case assignments the VT52 branches used to
        // make; TerminalDialect owns which bytes are taken as proof.
        dialect.noteEscapeByte(ch)

        // Any escape sequence that follows resolves/cancels a pending autowrap.
        switch ch {
        case 0x5B: // '[' - CSI (Control Sequence Introducer)
            escapeState = .csi
            return  // CSI handler runs; keep collecting, do not fall through

        case 0x37: // '7' - DECSC (Save Cursor)
            savedCursorRow = cursorRow
            savedCursorCol = cursorCol

        case 0x38: // '8' - DECRC (Restore Cursor)
            pendingWrap = false
            cursorRow = savedCursorRow
            cursorCol = savedCursorCol

        case 0x44: // 'D'
            pendingWrap = false
            if dialect.isVT52 {
                // VT52 cursor left
                if cursorCol > 0 { cursorCol -= 1 }
            } else {
                // VT100 Index (move cursor down, scroll if needed)
                cursorRow += 1
                if cursorRow >= terminalRows {
                    scrollUp(1)
                    cursorRow = terminalRows - 1
                }
            }

        case 0x4D: // 'M' - Reverse Index (move cursor up, scroll if needed)
            pendingWrap = false
            if cursorRow > 0 {
                cursorRow -= 1
            }

        case 0x45: // 'E'
            pendingWrap = false
            if dialect.isVT52 {
                // Heath/Zenith VT52: clear screen and home
                eraseScreen()
            } else {
                // VT100 Next Line
                cursorCol = 0
                cursorRow += 1
                if cursorRow >= terminalRows {
                    scrollUp(1)
                    cursorRow = terminalRows - 1
                }
            }

        // ---- VT52 escape sequences ----
        case 0x41: // 'A' - VT52 cursor up
            pendingWrap = false
            if cursorRow > 0 { cursorRow -= 1 }

        case 0x42: // 'B' - VT52 cursor down
            pendingWrap = false
            cursorRow = min(cursorRow + 1, terminalRows - 1)

        case 0x43: // 'C' - VT52 cursor right
            pendingWrap = false
            cursorCol = min(cursorCol + 1, terminalCols - 1)

        case 0x48: // 'H' - VT52 cursor home (no VT100 effect; HTS unsupported)
            if dialect.isVT52 {
                pendingWrap = false
                cursorRow = 0
                cursorCol = 0
            }

        case 0x49: // 'I' - VT52 reverse line feed
            pendingWrap = false
            if cursorRow > 0 {
                cursorRow -= 1
            }
            // At the top row we have no downward-scroll helper; clamp rather than
            // scrolling the wrong way.

        case 0x4A: // 'J' - VT52 erase to end of screen
            clearFromCursor()

        case 0x4B: // 'K' - VT52 erase to end of line
            for col in cursorCol..<terminalCols {
                terminalCells[cursorRow][col] = blankCell
            }

        case 0x59: // 'Y' - VT52 direct cursor address (two bytes follow)
            escapeState = .vt52Row
            return  // stay in escape parsing for the row/col bytes

        case 0x46, 0x47: // 'F'/'G' - VT52 enter/exit graphics mode (no glyph remap here)
            break

        case 0x5A: // 'Z' - identify
            emulator?.send(dialect.identifyReply)

        case 0x3C: // '<' - exit VT52, enter ANSI mode (handled above)
            break

        case 0x3D, 0x3E: // '='/'>' - keypad application/numeric mode (ignored)
            break

        case 0x28, 0x29, 0x2A, 0x2B, 0x23, 0x20:
            // '(' ')' '*' '+' designate a character set; '#' a line size; ' ' the
            // 7/8-bit control set. Each takes one trailing byte we don't act on but
            // must consume so it is not printed as a stray glyph.
            escapeState = .escConsumeOne
            return

        default:
            // Only process control characters, discard unknown printable chars
            if ch < 0x20 {
                escapeState = .normal
                processNormalChar(ch)
                return
            }
        }
        escapeState = .normal
    }

    /// A guest can emit an unbounded CSI parameter run. Bound both the digit
    /// count and the parameter count, and clamp the parsed value, so a runaway
    /// or hostile stream cannot grow the parser's state without limit or hand a
    /// wild row/column count to a handler. Same limits as z80cpmw.
    private static let maxCSIParamDigits = 6
    private static let maxCSIParams = 16

    /// Parse the accumulated parameter digits, clamped.
    private func takeCSIParam() -> Int {
        let value = Int(escapeCurrentParam) ?? 0
        return min(value, 9999)
    }

    /// Process character in CSI sequence
    private func processCSIChar(_ ch: unichar) {
        // Control characters abort the sequence and are processed normally
        if ch < 0x20 {
            escapeState = .normal
            processNormalChar(ch)
            return
        }

        // Private-parameter markers. '?' introduces the DEC private modes;
        // '<', '=' and '>' introduce the secondary and tertiary device-attribute
        // forms and xterm's modifyOtherKeys. None of them is a FINAL byte, and
        // treating the last three as one is what made ESC[>c end at the '>' and
        // print its own tail as glyphs - the same shape of bug '?' had in
        // z80cpmw before it learned the whole set.
        if ch >= 0x3C && ch <= 0x3F { // '<' '=' '>' '?'
            escapePrivateMode = true
            escapeState = .csiParam
            return
        }

        // Intermediate bytes, space through '/'. They belong to the sequence
        // and are not acted on here, but they must not end it either: ESC[!p
        // (DECSTR) and ESC[<n> q (DECSCUSR, which is what a program sends to
        // pick a cursor shape) both carry one, and both used to terminate at it
        // and leave the final byte to print as a glyph.
        if ch >= 0x20 && ch <= 0x2F {
            escapeState = .csiParam
            return
        }

        // Check if it's a parameter digit or separator
        if ch >= 0x30 && ch <= 0x39 { // '0'-'9'
            // Leading zeros are padding, not magnitude - dropping them keeps a
            // zero-padded parameter from spending the digit budget and being
            // truncated to a small number. Past the cap the value saturates at
            // the clamp takeCSIParam applies, rather than losing its high digits.
            if escapeCurrentParam.isEmpty && ch == 0x30 {
                escapeState = .csiParam
                return
            }
            if escapeCurrentParam.count < Self.maxCSIParamDigits {
                escapeCurrentParam.append(Character(UnicodeScalar(ch)!))
            }
            escapeState = .csiParam
            return
        }

        if ch == 0x3B { // ';' - parameter separator
            if escapeParams.count < Self.maxCSIParams {
                escapeParams.append(takeCSIParam())
            }
            escapeCurrentParam = ""
            escapeState = .csiParam
            return
        }

        // Final character - execute the sequence
        if !escapeCurrentParam.isEmpty, escapeParams.count < Self.maxCSIParams {
            escapeParams.append(takeCSIParam())
        }

        executeCSI(ch)
        escapeState = .normal
    }

    /// Execute a CSI sequence
    private func executeCSI(_ finalChar: unichar) {
        let p1 = escapeParams.count > 0 ? escapeParams[0] : 0
        let p2 = escapeParams.count > 1 ? escapeParams[1] : 0

        switch finalChar {
        case 0x41: // 'A' - Cursor Up
            pendingWrap = false
            let n = max(p1, 1)
            cursorRow = max(cursorRow - n, 0)

        case 0x42: // 'B' - Cursor Down
            pendingWrap = false
            let n = max(p1, 1)
            cursorRow = min(cursorRow + n, terminalRows - 1)

        case 0x43: // 'C' - Cursor Forward
            pendingWrap = false
            let n = max(p1, 1)
            cursorCol = min(cursorCol + n, terminalCols - 1)

        case 0x44: // 'D' - Cursor Back
            pendingWrap = false
            let n = max(p1, 1)
            cursorCol = max(cursorCol - n, 0)

        case 0x47, 0x60: // 'G' or '`' - Cursor Horizontal Absolute (column)
            pendingWrap = false
            let col = max(p1, 1) - 1
            cursorCol = min(max(col, 0), terminalCols - 1)

        case 0x64: // 'd' - Vertical Position Absolute (row)
            pendingWrap = false
            let row = max(p1, 1) - 1
            cursorRow = min(max(row, 0), terminalRows - 1)

        case 0x48, 0x66: // 'H' or 'f' - Cursor Position
            pendingWrap = false
            let row = max(p1, 1) - 1  // 1-based to 0-based
            let col = max(p2, 1) - 1
            cursorRow = min(max(row, 0), terminalRows - 1)
            cursorCol = min(max(col, 0), terminalCols - 1)

        case 0x4A: // 'J' - Erase in Display
            switch p1 {
            case 0: // Clear from cursor to end of screen
                clearFromCursor()
            case 1: // Clear from beginning to cursor
                clearToCursor()
            case 2: // Clear entire screen
                // eraseScreen(), not clearTerminal(): ED 2 erases cells and
                // says nothing about the rendition or the scrolling region.
                eraseScreen()
            default:
                break
            }

        case 0x4B: // 'K' - Erase in Line
            switch p1 {
            case 0: // Clear from cursor to end of line
                for col in cursorCol..<terminalCols {
                    terminalCells[cursorRow][col] = blankCell
                }
            case 1: // Clear from beginning to cursor
                for col in 0...cursorCol {
                    terminalCells[cursorRow][col] = blankCell
                }
            case 2: // Clear entire line
                for col in 0..<terminalCols {
                    terminalCells[cursorRow][col] = blankCell
                }
            default:
                break
            }

        case 0x4D: // 'M' - DL (Delete Line) - delete lines at cursor, scroll up
            // Delete n lines starting at cursor row, scroll remaining lines up
            let startRow = cursorRow
            let endRow = scrollBottom  // Use scrolling region bottom, or terminalRows-1 if no region
            if startRow <= endRow {
                // Clamp to the region: deleting more lines than there are just
                // clears it. Unclamped, endRow - n + 1 falls below startRow and
                // the Range below traps - a live crash for an editor that asks
                // to delete to the bottom from near it.
                let n = min(max(p1, 1), endRow - startRow + 1)
                for row in startRow..<(endRow - n + 1) {
                    if row + n <= endRow {
                        terminalCells[row] = terminalCells[row + n]
                    }
                }
                // Clear the bottom n lines
                for row in max(endRow - n + 1, startRow)...endRow {
                    terminalCells[row] = Array(repeating: blankCell, count: terminalCols)
                }
            }

        case 0x4C: // 'L' - IL (Insert Line) - insert lines at cursor, scroll down
            // Insert n blank lines at cursor row, scroll remaining lines down
            let startRow = cursorRow
            let endRow = scrollBottom
            if startRow <= endRow {
                // Clamped for the same reason as DL above; the loops here happen
                // to survive an over-large n, but not by design.
                let n = min(max(p1, 1), endRow - startRow + 1)
                for row in stride(from: endRow, through: startRow + n, by: -1) {
                    if row - n >= startRow {
                        terminalCells[row] = terminalCells[row - n]
                    }
                }
                // Clear the top n lines (at cursor position)
                for row in startRow..<min(startRow + n, endRow + 1) {
                    terminalCells[row] = Array(repeating: blankCell, count: terminalCols)
                }
            }

        // The five editing finals below blank cells with `blankCell`, i.e. the
        // current SGR background, matching clearFromCursor/clearToCursor and the
        // rest of the erase family in this file. That decision was taken for the
        // whole family at once rather than introduced in half of it; see
        // blankCell for what it means and why.
        case 0x40: // '@' - ICH (Insert Character)
            // Shift the rest of the line right by n, blanking what opens up.
            // Characters pushed past the last column are lost, not wrapped:
            // ICH is defined within the line.
            if cursorRow < terminalRows, cursorCol < terminalCols {
                let n = min(max(p1, 1), terminalCols - cursorCol)
                var row = terminalCells[cursorRow]
                if terminalCols - cursorCol - n > 0 {
                    for col in stride(from: terminalCols - 1, through: cursorCol + n, by: -1) {
                        row[col] = row[col - n]
                    }
                }
                for col in cursorCol..<(cursorCol + n) {
                    row[col] = blankCell
                }
                terminalCells[cursorRow] = row
            }

        case 0x50: // 'P' - DCH (Delete Character)
            // Shift the rest of the line left by n; the tail becomes blanks.
            if cursorRow < terminalRows, cursorCol < terminalCols {
                let n = min(max(p1, 1), terminalCols - cursorCol)
                var row = terminalCells[cursorRow]
                for col in cursorCol..<(terminalCols - n) {
                    row[col] = row[col + n]
                }
                for col in max(terminalCols - n, cursorCol)..<terminalCols {
                    row[col] = blankCell
                }
                terminalCells[cursorRow] = row
            }

        case 0x58: // 'X' - ECH (Erase Character)
            // Blank n cells from the cursor without moving anything: unlike DCH
            // the rest of the line stays where it is, and unlike EL the erase
            // stops after n.
            if cursorRow < terminalRows, cursorCol < terminalCols {
                let n = min(max(p1, 1), terminalCols - cursorCol)
                for col in cursorCol..<(cursorCol + n) {
                    terminalCells[cursorRow][col] = blankCell
                }
            }

        case 0x53: // 'S' - SU (Scroll Up)
            // Scroll the region up n lines. Content leaving the top of a full
            // screen goes to scrollback; content leaving a partial region does
            // not, matching what LF does - lines pushed out of a status-line
            // window were never history.
            // Whole screen goes through scrollUp() so the top line reaches
            // scrollback; a partial region goes through scrollRegion(), which
            // deliberately does not - lines pushed out of a status-line window
            // were never history.
            let lines = max(p1, 1)
            if scrollTop == 0 && scrollBottom == terminalRows - 1 {
                scrollUp(lines)
            } else {
                scrollRegion(scrollTop, scrollBottom, min(lines, scrollBottom - scrollTop + 1))
            }

        case 0x54: // 'T' - SD (Scroll Down)
            // The reverse: blank lines enter at the top of the region and the
            // bottom line falls off. Never touches scrollback in either
            // direction - nothing is leaving the top.
            for _ in 0..<max(p1, 1) {
                let top = scrollTop, bottom = scrollBottom
                if top <= bottom {
                    for row in stride(from: bottom, through: top + 1, by: -1) {
                        terminalCells[row] = terminalCells[row - 1]
                    }
                    terminalCells[top] = Array(repeating: blankCell, count: terminalCols)
                }
            }

        case 0x6D: // 'm' - SGR (Select Graphic Rendition)
            // A private marker makes this something else entirely. ESC[>4;2m
            // and ESC[>4m are xterm's modifyOtherKeys and say nothing about
            // colour; without this guard the bare one reached SGR as ESC[m and
            // reset the whole rendition. z80cpmw guards the same final for the
            // same reason.
            if !escapePrivateMode {
                // An empty list is ESC[m, which is ESC[0m; applySGR handles it.
                rendition.applySGR(escapeParams)
            }

        case 0x73: // 's' - Save cursor position (SCO)
            savedCursorRow = cursorRow
            savedCursorCol = cursorCol

        case 0x75: // 'u' - Restore cursor position (SCO)
            pendingWrap = false
            cursorRow = savedCursorRow
            cursorCol = savedCursorCol

        case 0x72: // 'r' - Set scrolling region (DECSTBM)
            // ESC[top;bottomr - set scrolling region (1-based)
            // ESC[r - reset to full screen
            pendingWrap = false
            let top = (escapeParams.count > 0 && escapeParams[0] > 0) ? escapeParams[0] - 1 : 0
            let bottom = (escapeParams.count > 1 && escapeParams[1] > 0) ? escapeParams[1] - 1 : terminalRows - 1
            if top < bottom && bottom < terminalRows {
                scrollTop = top
                scrollBottom = bottom
                // Cursor moves to home position after setting region
                cursorRow = 0
                cursorCol = 0
            }

        case 0x6E: // 'n' - Device Status Report (answerback)
            if !escapePrivateMode {
                if p1 == 6 {
                    // CPR: report cursor position, 1-based
                    emulator?.send("\u{1B}[\(cursorRow + 1);\(cursorCol + 1)R")
                } else if p1 == 5 {
                    // DSR: terminal OK
                    emulator?.send("\u{1B}[0n")
                }
            }

        case 0x63: // 'c' - Device Attributes (answerback)
            if !escapePrivateMode && p1 == 0 {
                // Identify as a VT100 with no options
                emulator?.send("\u{1B}[?1;0c")
            }

        case 0x68: // 'h' - Set Mode
            if escapePrivateMode {
                if escapeParams.contains(2) {
                    // DECANM set: select ANSI (VT100) mode
                    dialect.noteDECANM(selectsANSI: true)
                }
                if escapeParams.contains(7) {
                    autoWrap = true     // DECAWM
                }
                if escapeParams.contains(25) {
                    cursorVisible = true  // DECTCEM
                }
            }
            // Other DEC private modes are acknowledged but not acted upon.

        case 0x6C: // 'l' - Reset Mode
            if escapePrivateMode {
                if escapeParams.contains(2) {
                    // DECANM reset: select VT52 mode
                    dialect.noteDECANM(selectsANSI: false)
                }
                if escapeParams.contains(7) {
                    // DECAWM off: writing the last column overwrites it instead
                    // of wrapping. Clear any wrap already armed, or a pending
                    // one from before the mode change would still fire.
                    autoWrap = false
                    pendingWrap = false
                }
                if escapeParams.contains(25) {
                    cursorVisible = false  // DECTCEM
                }
            }
            // Other DEC private modes are acknowledged but not acted upon.

        default:
            // Unknown CSI sequence, ignore
            break
        }
    }

    /// Clear from cursor to end of screen
    private func clearFromCursor() {
        // Clear rest of current line
        for col in cursorCol..<terminalCols {
            terminalCells[cursorRow][col] = blankCell
        }
        // Clear remaining lines
        for row in (cursorRow + 1)..<terminalRows {
            for col in 0..<terminalCols {
                terminalCells[row][col] = blankCell
            }
        }
    }

    /// Clear from beginning to cursor
    private func clearToCursor() {
        // Clear lines before current
        for row in 0..<cursorRow {
            for col in 0..<terminalCols {
                terminalCells[row][col] = blankCell
            }
        }
        // Clear current line up to cursor
        for col in 0...cursorCol {
            terminalCells[cursorRow][col] = blankCell
        }
    }

    func emulatorVDAScrollUp(_ lines: Int32) {
        DispatchQueue.main.async {
            self.scrollUp(Int(lines))
        }
    }

    func emulatorVDASetAttr(_ attr: UInt8) {
        // Attr is CGA-style: bits 0-3 = foreground, bits 4-6 = background, bit 7 = blink
        DispatchQueue.main.async {
            // This replaces the whole byte, so any SGR 7 swap is gone with
            // it - and so are the face flags, which the byte cannot express.
            self.rendition.attr = attr
            self.rendition.flags = 0
            self.rendition.reverse = false
        }
    }

    private func scrollUp(_ lines: Int) {
        guard lines > 0 else { return }

        // Preserve the rows scrolling off the top into the scrollback buffer.
        // Capacity 0 disables capture entirely (z80cpmw parity).
        let cap = scrollbackCapacity
        if cap > 0 {
            let captured = min(lines, terminalRows)
            for row in 0..<captured {
                scrollbackLines.append(terminalCells[row])
            }
            if scrollbackLines.count > cap {
                scrollbackLines.removeFirst(scrollbackLines.count - cap)
            }
            // Keep the visible window anchored to the same content while the user
            // is reading history (up to the buffer cap).
            if scrollbackOffset > 0 {
                scrollbackOffset = min(scrollbackOffset + captured, scrollbackLines.count)
            }
        }

        let keep = max(0, terminalRows - lines)
        for row in 0..<keep {
            terminalCells[row] = terminalCells[row + lines]
        }
        for row in keep..<terminalRows {
            terminalCells[row] = Array(repeating: blankCell, count: terminalCols)
        }
    }

    private func scrollRegion(_ top: Int, _ bottom: Int, _ lines: Int) {
        guard lines > 0 && top >= 0 && bottom < terminalRows && top < bottom else { return }

        // A region that is the whole screen IS the screen scrolling, and the
        // lines leaving the top are history. scrollUp() is the one path that
        // captures them. Routing that case here rather than at each call site
        // is the point: the LF handler called scrollRegion() directly, so every
        // ordinary newline-driven scroll - which is nearly all of them - threw
        // its top line away, and the scrollback buffer stayed empty for the
        // whole life of the feature. The SU handler had this test inline and so
        // was the only path that ever captured anything.
        if top == 0 && bottom == terminalRows - 1 {
            scrollUp(lines)
            return
        }

        // Scroll lines within the region [top, bottom]
        for row in top..<(bottom - lines + 1) {
            terminalCells[row] = terminalCells[row + lines]
        }
        // Clear the bottom lines of the region
        for row in (bottom - lines + 1)...bottom {
            terminalCells[row] = Array(repeating: blankCell, count: terminalCols)
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
