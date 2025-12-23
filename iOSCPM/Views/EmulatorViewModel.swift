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
    let license: String  // "MIT", "Free", "User-provided", etc.
    let sha256: String?  // Optional SHA256 hash for integrity verification

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
    @Published var isDownloading: Bool = false
    @Published var downloadingDiskName: String = ""

    // Host file transfer (R8/W8 utilities)
    @Published var showingHostFileImporter: Bool = false
    @Published var showingHostFileExporter: Bool = false
    @Published var hostFileExportData: Data?
    @Published var hostFileExportFilename: String = "download.bin"

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
    @Published var selectedDisks: [DiskOption?] = Array(repeating: nil, count: 4) {
        didSet {
            // Save selected disk filenames to UserDefaults
            let filenames = selectedDisks.map { $0?.filename ?? "" }
            UserDefaults.standard.set(filenames, forKey: "selectedDisks")
        }
    }

    // Number of slices to expose per disk (1-8, default 4)
    @Published var diskSliceCounts: [Int] = [4, 4, 4, 4] {
        didSet {
            UserDefaults.standard.set(diskSliceCounts, forKey: "diskSliceCounts")
        }
    }
    @Published var availableDisks: [DiskOption] = [
        DiskOption(name: "None", filename: ""),
    ]

    // Downloadable disk catalog - fetched from disks.xml in GitHub releases
    private static let catalogURL = "https://github.com/avwohl/ioscpm/releases/latest/download/disks.xml"
    private static let releaseBaseURL = "https://github.com/avwohl/ioscpm/releases/latest/download"

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

    // Boot string for auto-boot
    @Published var bootString: String = ""

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

    private var emulator: RomWBWEmulator?

    // Audio engine for beep
    private var audioEngine: AVAudioEngine?
    private var tonePlayer: AVAudioPlayerNode?

    // Terminal dimensions
    let terminalRows = 25
    let terminalCols = 80

    // VT100/ANSI escape sequence parser state
    private enum EscapeState {
        case normal
        case escape          // Received ESC
        case csi             // Received ESC [
        case csiParam        // Collecting CSI parameters
    }
    private var escapeState: EscapeState = .normal
    private var escapeParams: [Int] = []
    private var escapeCurrentParam: String = ""
    private var escapePrivateMode: Bool = false  // True if '?' prefix (DEC private mode)
    private var savedCursorRow: Int = 0
    private var savedCursorCol: Int = 0
    private var currentAttr: UInt8 = 0x07  // Default: white on black
    private var scrollTop: Int = 0         // Top of scrolling region (0-based)
    private var scrollBottom: Int = 24     // Bottom of scrolling region (0-based, inclusive)

    override init() {
        super.init()

        // Initialize terminal cells
        terminalCells = Array(repeating: Array(repeating: TerminalCell(), count: terminalCols), count: terminalRows)

        // Show startup message in terminal
        showStartupMessage()

        emulator = RomWBWEmulator()
        emulator?.delegate = self

        setupAudio()
    }

    private func showStartupMessage() {
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
            // First launch defaults: Combo for disk 0, Infocom for disk 1
            debugPrint("[RestoreDisks] First launch - setting defaults")
            selectedDisks[0] = availableDisks.first { $0.filename == "hd1k_combo.img" }
            selectedDisks[1] = availableDisks.first { $0.filename == "hd1k_infocom.img" }
        }

        // Ensure disk 0 has something selected
        if selectedDisks[0] == nil || selectedDisks[0]?.filename.isEmpty == true {
            selectedDisks[0] = availableDisks.first { $0.filename == "hd1k_combo.img" }
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

        // Restore saved slice counts or use defaults
        if let savedSliceCounts = UserDefaults.standard.array(forKey: "diskSliceCounts") as? [Int] {
            diskSliceCounts = savedSliceCounts.count >= 4 ? Array(savedSliceCounts.prefix(4)) : savedSliceCounts + Array(repeating: 4, count: 4 - savedSliceCounts.count)
        }
        debugPrint("[RestoreDisks] Slice counts: \(diskSliceCounts)")

        statusText = "Ready - Press Play to start"
    }

    func loadSelectedResources() {
        // Close all existing disks before loading new configuration
        // This prevents old disks from persisting when user reduces disk count
        emulator?.closeAllDisks()

        // Load selected ROM
        let romFile = selectedROM?.filename ?? "emu_avw.rom"
        debugPrint("[EmulatorVM] Loading ROM: \(romFile)")
        guard emulator?.loadROM(fromBundle: romFile) == true else {
            debugPrint("[EmulatorVM] ERROR: Failed to load ROM: \(romFile)")
            showError("Failed to load ROM: \(romFile)")
            statusText = "Error: \(romFile) not found"
            return
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
                    emulator?.setDiskSliceCount(Int32(unit), slices: Int32(diskSliceCounts[unit]))
                    debugPrint("[EmulatorVM] Loaded local disk to unit \(unit) with \(diskSliceCounts[unit]) slices")
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
                        debugPrint("🔵 [DISK] Calling setDiskSliceCount(\(unit), \(diskSliceCounts[unit])) for downloaded disk")
                        emulator?.setDiskSliceCount(Int32(unit), slices: Int32(diskSliceCounts[unit]))
                        debugPrint("🔵 [DISK] Loaded downloaded disk \(disk.filename) to unit \(unit) with \(diskSliceCounts[unit]) slices")
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
                    debugPrint("🔵 [DISK] Calling setDiskSliceCount(\(unit), \(diskSliceCounts[unit]))")
                    emulator?.setDiskSliceCount(Int32(unit), slices: Int32(diskSliceCounts[unit]))
                    debugPrint("🔵 [DISK] Set slice count for unit \(unit) to \(diskSliceCounts[unit])")
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

        // Set boot string
        emulator?.setBootString(bootString)
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

    // MARK: - Emulation Control

    func start() {
        statusText = "Checking disks..."

        // Check if catalog is loaded
        if diskCatalog.isEmpty {
            showError("Disk catalog not loaded. Please wait for catalog to load or check internet connection.")
            statusText = "Error: No disk catalog"
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
        statusText = "Downloading \(current.name)..."

        downloadDiskWithCompletion(current) { [weak self] success in
            guard let self = self else { return }
            if success {
                // Continue with remaining downloads
                self.downloadDisksAndStart(remaining)
            } else {
                self.isDownloading = false
                self.downloadingDiskName = ""
                self.showError("Failed to download \(current.name)")
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
                completion(true)
            case .error:
                completion(false)
            case .downloading, .notDownloaded, .none:
                // Still in progress, keep polling
                self.waitForDownloadCompletion(filename, completion: completion)
            }
        }
    }

    /// Internal download with retry logic
    private func downloadDiskWithRetry(_ disk: DownloadableDisk, attemptsRemaining: Int, completion: @escaping (Bool) -> Void) {
        let attempt = 4 - attemptsRemaining
        debugPrint("[Download] Starting download of '\(disk.filename)' (attempt \(attempt)/3) from \(disk.url)")

        guard let url = URL(string: disk.url) else {
            debugPrint("[Download] ERROR: Invalid URL: \(disk.url)")
            completion(false)
            return
        }

        downloadStates[disk.filename] = .downloading(progress: 0)

        let task = downloadSession.downloadTask(with: url) { [weak self] tempURL, response, error in
            DispatchQueue.main.async {
                guard let self = self else {
                    completion(false)
                    return
                }

                // Check HTTP status code first
                if let httpResponse = response as? HTTPURLResponse {
                    self.debugPrint("[Download] HTTP status: \(httpResponse.statusCode)")
                    if httpResponse.statusCode < 200 || httpResponse.statusCode >= 300 {
                        self.debugPrint("[Download] ERROR: Bad HTTP status \(httpResponse.statusCode)")
                        if attemptsRemaining > 1 {
                            self.debugPrint("[Download] Retrying in 1 second... (\(attemptsRemaining - 1) attempts left)")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                self.downloadDiskWithRetry(disk, attemptsRemaining: attemptsRemaining - 1, completion: completion)
                            }
                            return
                        }
                        self.downloadStates[disk.filename] = .error("HTTP error \(httpResponse.statusCode)")
                        completion(false)
                        return
                    }
                }

                // Check for errors - retry if attempts remaining
                if let error = error {
                    self.debugPrint("[Download] ERROR: \(error.localizedDescription)")
                    if attemptsRemaining > 1 {
                        self.debugPrint("[Download] Retrying in 1 second... (\(attemptsRemaining - 1) attempts left)")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            self.downloadDiskWithRetry(disk, attemptsRemaining: attemptsRemaining - 1, completion: completion)
                        }
                        return
                    }
                    self.downloadStates[disk.filename] = .error(error.localizedDescription)
                    completion(false)
                    return
                }

                if tempURL == nil {
                    self.debugPrint("[Download] ERROR: No temp file received")
                    if attemptsRemaining > 1 {
                        self.debugPrint("[Download] Retrying in 1 second... (\(attemptsRemaining - 1) attempts left)")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            self.downloadDiskWithRetry(disk, attemptsRemaining: attemptsRemaining - 1, completion: completion)
                        }
                        return
                    }
                    self.downloadStates[disk.filename] = .error("Download failed - no data")
                    completion(false)
                    return
                }

                let destURL = self.downloadsDirectory.appendingPathComponent(disk.filename)
                self.debugPrint("[Download] Moving temp file to \(destURL.path)")
                do {
                    try? FileManager.default.removeItem(at: destURL)
                    try FileManager.default.moveItem(at: tempURL!, to: destURL)

                    // Verify the file exists
                    let fileExists = FileManager.default.fileExists(atPath: destURL.path)
                    self.debugPrint("[Download] SUCCESS: '\(disk.filename)' saved, fileExists=\(fileExists)")

                    // Verify SHA256 checksum if available
                    if let expectedSha256 = disk.sha256 {
                        let actualSha256 = self.sha256OfFile(at: destURL)
                        if actualSha256?.lowercased() != expectedSha256.lowercased() {
                            self.debugPrint("[Download] ERROR: SHA256 mismatch for '\(disk.filename)'")
                            self.debugPrint("[Download]   Expected: \(expectedSha256)")
                            self.debugPrint("[Download]   Got:      \(actualSha256 ?? "nil")")
                            try? FileManager.default.removeItem(at: destURL)
                            if attemptsRemaining > 1 {
                                self.debugPrint("[Download] Retrying in 1 second... (\(attemptsRemaining - 1) attempts left)")
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                    self.downloadDiskWithRetry(disk, attemptsRemaining: attemptsRemaining - 1, completion: completion)
                                }
                                return
                            }
                            self.downloadStates[disk.filename] = .error("Checksum mismatch")
                            completion(false)
                            return
                        }
                        self.debugPrint("[Download] SHA256 verified: \(expectedSha256.prefix(16))...")
                    }

                    self.downloadStates[disk.filename] = .downloaded
                    self.refreshAvailableDisks()
                    // Update the selected disk to mark it as downloaded
                    for i in 0..<self.selectedDisks.count {
                        if self.selectedDisks[i]?.filename == disk.filename {
                            self.selectedDisks[i] = self.availableDisks.first { $0.filename == disk.filename }
                            self.debugPrint("[Download] Updated selectedDisks[\(i)] isDownloaded=\(self.selectedDisks[i]?.isDownloaded ?? false)")
                        }
                    }
                    completion(true)
                } catch {
                    self.debugPrint("[Download] ERROR moving file: \(error.localizedDescription)")
                    self.downloadStates[disk.filename] = .error(error.localizedDescription)
                    completion(false)
                }
            }
        }

        let observation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            DispatchQueue.main.async {
                self?.downloadStates[disk.filename] = .downloading(progress: progress.fractionCompleted)
            }
        }
        objc_setAssociatedObject(task, "progressObservation", observation, .OBJC_ASSOCIATION_RETAIN)
        task.resume()
    }

    /// Actually start the emulator after all disks are ready
    private func startEmulator() {
        debugPrint("🟢 [START] startEmulator called")
        // Clear terminal before starting (removes "Press Play" message)
        clearTerminal()
        // Load selected ROM and disks before starting
        debugPrint("🟢 [START] calling loadSelectedResources, diskSliceCounts=\(diskSliceCounts)")
        loadSelectedResources()
        debugPrint("🟢 [START] calling emulator.start()")
        emulator?.start()
        isRunning = emulator?.isRunning ?? false
        statusText = "Running"
        terminalShouldFocus = true  // Auto-focus terminal
        debugPrint("🟢 [START] emulator started, isRunning=\(isRunning)")
    }

    func stop() {
        // Auto-save any modified downloaded disks
        saveDownloadedDisks()

        emulator?.stop()
        isRunning = false
        statusText = "Stopped - disk changes saved"
    }

    /// Public method to save all disk images (called from UI menu)
    func saveAllDisks() {
        saveDownloadedDisks()
        statusText = "All disks saved"
    }

    /// Save downloaded disk images back to Documents/Disks
    private func saveDownloadedDisks() {
        for unit in 0..<4 {
            guard let disk = selectedDisks[unit],
                  disk.isDownloaded,
                  !disk.filename.isEmpty else { continue }

            guard let data = emulator?.getDiskData(Int32(unit)),
                  data.count > 0 else { continue }

            let path = downloadsDirectory.appendingPathComponent(disk.filename)
            do {
                try data.write(to: path)
                debugPrint("[EmulatorVM] Saved disk \(unit) to \(disk.filename)")
            } catch {
                debugPrint("[EmulatorVM] Failed to save disk \(unit): \(error)")
            }
        }
    }

    func reset() {
        // Save disks before reset
        saveDownloadedDisks()

        emulator?.reset()
        clearTerminal()
        isRunning = false
        statusText = "Reset - disk changes saved"
    }

    func sendKey(_ char: Character) {
        // Only send ASCII characters (0-127) to CP/M
        guard let code = char.asciiValue else { return }
        emulator?.sendCharacter(unichar(code))
    }

    func sendString(_ str: String) {
        emulator?.send(str)
    }

    // MARK: - Terminal Operations

    func clearTerminal() {
        for row in 0..<terminalRows {
            for col in 0..<terminalCols {
                terminalCells[row][col] = TerminalCell()
            }
        }
        cursorRow = 0
        cursorCol = 0
        scrollTop = 0
        scrollBottom = terminalRows - 1
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

    private func showError(_ message: String) {
        errorMessage = message
        showingError = true
    }

    /// Calculate SHA256 hash of a file
    func sha256OfFile(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
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
                        // Check if catalog version changed - if so, invalidate all downloaded disks
                        self.checkCatalogVersionAndInvalidate(newVersion: result.version)

                        self.diskCatalog = result.disks
                        self.saveCatalogToCache(data)
                        self.refreshAvailableDisks()
                        self.restoreDiskSelections()
                        return
                    }
                }

                // Fetch failed, try cached version
                self.debugPrint("[Catalog] Falling back to cached catalog")
                self.loadCachedCatalog()
            }
        }.resume()
    }

    /// Check if catalog version changed and invalidate downloaded disks if needed
    private func checkCatalogVersionAndInvalidate(newVersion: String) {
        let storedVersion = UserDefaults.standard.string(forKey: "catalogVersion") ?? ""

        if storedVersion.isEmpty {
            // First run - just store the version
            debugPrint("[Catalog] First run, storing catalog version: '\(newVersion)'")
            UserDefaults.standard.set(newVersion, forKey: "catalogVersion")
        } else if storedVersion != newVersion {
            // Version changed - delete all downloaded disks
            debugPrint("[Catalog] Version changed from '\(storedVersion)' to '\(newVersion)' - invalidating downloads")
            deleteAllDownloadedDisks()
            UserDefaults.standard.set(newVersion, forKey: "catalogVersion")
            statusText = "Disk catalog updated - disks need redownload"
            showError("Disk catalog has been updated. Your downloaded disks have been cleared and need to be redownloaded.")
        } else {
            debugPrint("[Catalog] Version unchanged: '\(newVersion)'")
        }
    }

    /// Load catalog from local cache
    private func loadCachedCatalog() {
        catalogLoading = false
        let cacheURL = downloadsDirectory.appendingPathComponent("disks_catalog.xml")
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
        try? data.write(to: cacheURL)
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
            DispatchQueue.main.async {
                guard let self = self else { return }

                // Check HTTP status code first
                if let httpResponse = response as? HTTPURLResponse {
                    self.debugPrint("[Settings Download] HTTP status: \(httpResponse.statusCode)")
                    if httpResponse.statusCode < 200 || httpResponse.statusCode >= 300 {
                        self.debugPrint("[Settings Download] ERROR: Bad HTTP status \(httpResponse.statusCode)")
                        if attemptsRemaining > 1 {
                            self.debugPrint("[Settings Download] Retrying in 1 second...")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                self.downloadDiskFromSettings(disk, attemptsRemaining: attemptsRemaining - 1)
                            }
                            return
                        }
                        self.downloadStates[disk.filename] = .error("HTTP error \(httpResponse.statusCode)")
                        return
                    }
                }

                if let error = error {
                    self.debugPrint("[Settings Download] ERROR: \(error.localizedDescription)")
                    if attemptsRemaining > 1 {
                        self.debugPrint("[Settings Download] Retrying in 1 second...")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            self.downloadDiskFromSettings(disk, attemptsRemaining: attemptsRemaining - 1)
                        }
                        return
                    }
                    self.downloadStates[disk.filename] = .error(error.localizedDescription)
                    return
                }

                guard let tempURL = tempURL else {
                    self.debugPrint("[Settings Download] ERROR: No temp file")
                    if attemptsRemaining > 1 {
                        self.debugPrint("[Settings Download] Retrying in 1 second...")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            self.downloadDiskFromSettings(disk, attemptsRemaining: attemptsRemaining - 1)
                        }
                        return
                    }
                    self.downloadStates[disk.filename] = .error("Download failed")
                    return
                }

                // Move to downloads directory
                let destURL = self.downloadsDirectory.appendingPathComponent(disk.filename)
                do {
                    // Remove existing file if any
                    try? FileManager.default.removeItem(at: destURL)
                    try FileManager.default.moveItem(at: tempURL, to: destURL)
                    self.downloadStates[disk.filename] = .downloaded
                    self.refreshAvailableDisks()
                    self.statusText = "Downloaded: \(disk.name)"
                } catch {
                    self.downloadStates[disk.filename] = .error(error.localizedDescription)
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

    /// Delete all downloaded disk images (used when catalog version changes)
    private func deleteAllDownloadedDisks() {
        let fm = FileManager.default
        if let contents = try? fm.contentsOfDirectory(at: downloadsDirectory, includingPropertiesForKeys: nil) {
            for url in contents where url.pathExtension == "img" {
                try? fm.removeItem(at: url)
                let filename = url.lastPathComponent
                downloadStates[filename] = .notDownloaded
            }
        }
        debugPrint("[Catalog] Deleted all downloaded disks due to catalog version change")
    }

    /// Load a downloaded disk into the emulator
    func loadDownloadedDisk(unit: Int, filename: String) -> Bool {
        let path = downloadsDirectory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: path.path) else { return false }

        do {
            let data = try Data(contentsOf: path)
            if emulator?.loadDisk(Int32(unit), from: data) == true {
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
        DispatchQueue.main.async {
            self.clearTerminal()
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
            self.processCharacter(ch)
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
        }
    }

    /// Process character in normal (non-escape) state
    private func processNormalChar(_ ch: unichar) {
        switch ch {
        case 0x07: // Bell
            playBeep(durationMs: 100)

        case 0x08: // Backspace
            if cursorCol > 0 {
                cursorCol -= 1
            }

        case 0x09: // Tab
            cursorCol = min((cursorCol + 8) & ~7, terminalCols - 1)

        case 0x0A: // Line feed (with implicit CR for compatibility)
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
            cursorCol = 0

        case 0x1B: // ESC - start escape sequence
            escapeState = .escape
            escapeParams = []
            escapeCurrentParam = ""
            escapePrivateMode = false

        default:
            // Printable character
            if ch >= 0x20 && ch <= 0x7E {
                let char = Character(UnicodeScalar(ch) ?? UnicodeScalar(32))
                terminalCells[cursorRow][cursorCol].character = char
                terminalCells[cursorRow][cursorCol].foreground = currentAttr & 0x0F
                terminalCells[cursorRow][cursorCol].background = (currentAttr >> 4) & 0x07
                cursorCol += 1
                if cursorCol >= terminalCols {
                    cursorCol = 0
                    cursorRow += 1
                    if cursorRow >= terminalRows {
                        scrollUp(1)
                        cursorRow = terminalRows - 1
                    }
                }
            }
        }
    }

    /// Process character after ESC received
    private func processEscapeChar(_ ch: unichar) {
        switch ch {
        case 0x5B: // '[' - CSI (Control Sequence Introducer)
            escapeState = .csi

        case 0x37: // '7' - DECSC (Save Cursor)
            savedCursorRow = cursorRow
            savedCursorCol = cursorCol
            escapeState = .normal

        case 0x38: // '8' - DECRC (Restore Cursor)
            cursorRow = savedCursorRow
            cursorCol = savedCursorCol
            escapeState = .normal

        case 0x44: // 'D' - Index (move cursor down, scroll if needed)
            cursorRow += 1
            if cursorRow >= terminalRows {
                scrollUp(1)
                cursorRow = terminalRows - 1
            }
            escapeState = .normal

        case 0x4D: // 'M' - Reverse Index (move cursor up, scroll if needed)
            if cursorRow > 0 {
                cursorRow -= 1
            }
            escapeState = .normal

        case 0x45: // 'E' - Next Line
            cursorCol = 0
            cursorRow += 1
            if cursorRow >= terminalRows {
                scrollUp(1)
                cursorRow = terminalRows - 1
            }
            escapeState = .normal

        default:
            // Unknown escape sequence - return to normal
            escapeState = .normal
            // Only process control characters, discard unknown printable chars
            if ch < 0x20 {
                processNormalChar(ch)
            }
        }
    }

    /// Process character in CSI sequence
    private func processCSIChar(_ ch: unichar) {
        // Control characters abort the sequence and are processed normally
        if ch < 0x20 {
            escapeState = .normal
            processNormalChar(ch)
            return
        }

        // Check for '?' prefix (DEC private mode)
        if ch == 0x3F { // '?'
            escapePrivateMode = true
            escapeState = .csiParam
            return
        }

        // Check if it's a parameter digit or separator
        if ch >= 0x30 && ch <= 0x39 { // '0'-'9'
            escapeCurrentParam.append(Character(UnicodeScalar(ch)!))
            escapeState = .csiParam
            return
        }

        if ch == 0x3B { // ';' - parameter separator
            escapeParams.append(Int(escapeCurrentParam) ?? 0)
            escapeCurrentParam = ""
            escapeState = .csiParam
            return
        }

        // Final character - execute the sequence
        if !escapeCurrentParam.isEmpty {
            escapeParams.append(Int(escapeCurrentParam) ?? 0)
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
            let n = max(p1, 1)
            cursorRow = max(cursorRow - n, 0)

        case 0x42: // 'B' - Cursor Down
            let n = max(p1, 1)
            cursorRow = min(cursorRow + n, terminalRows - 1)

        case 0x43: // 'C' - Cursor Forward
            let n = max(p1, 1)
            cursorCol = min(cursorCol + n, terminalCols - 1)

        case 0x44: // 'D' - Cursor Back
            let n = max(p1, 1)
            cursorCol = max(cursorCol - n, 0)

        case 0x48, 0x66: // 'H' or 'f' - Cursor Position
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
                clearTerminal()
            default:
                break
            }

        case 0x4B: // 'K' - Erase in Line
            switch p1 {
            case 0: // Clear from cursor to end of line
                for col in cursorCol..<terminalCols {
                    terminalCells[cursorRow][col] = TerminalCell()
                }
            case 1: // Clear from beginning to cursor
                for col in 0...cursorCol {
                    terminalCells[cursorRow][col] = TerminalCell()
                }
            case 2: // Clear entire line
                for col in 0..<terminalCols {
                    terminalCells[cursorRow][col] = TerminalCell()
                }
            default:
                break
            }

        case 0x4D: // 'M' - DL (Delete Line) - delete lines at cursor, scroll up
            let n = max(p1, 1)
            // Delete n lines starting at cursor row, scroll remaining lines up
            let startRow = cursorRow
            let endRow = scrollBottom  // Use scrolling region bottom, or terminalRows-1 if no region
            if startRow <= endRow {
                for row in startRow..<(endRow - n + 1) {
                    if row + n <= endRow {
                        terminalCells[row] = terminalCells[row + n]
                    }
                }
                // Clear the bottom n lines
                for row in max(endRow - n + 1, startRow)...endRow {
                    terminalCells[row] = Array(repeating: TerminalCell(), count: terminalCols)
                }
            }

        case 0x4C: // 'L' - IL (Insert Line) - insert lines at cursor, scroll down
            let n = max(p1, 1)
            // Insert n blank lines at cursor row, scroll remaining lines down
            let startRow = cursorRow
            let endRow = scrollBottom
            if startRow <= endRow {
                for row in stride(from: endRow, through: startRow + n, by: -1) {
                    if row - n >= startRow {
                        terminalCells[row] = terminalCells[row - n]
                    }
                }
                // Clear the top n lines (at cursor position)
                for row in startRow..<min(startRow + n, endRow + 1) {
                    terminalCells[row] = Array(repeating: TerminalCell(), count: terminalCols)
                }
            }

        case 0x6D: // 'm' - SGR (Select Graphic Rendition)
            if escapeParams.isEmpty {
                // ESC[m = reset
                currentAttr = 0x07
            } else {
                for param in escapeParams {
                    applySGR(param)
                }
            }

        case 0x73: // 's' - Save cursor position (SCO)
            savedCursorRow = cursorRow
            savedCursorCol = cursorCol

        case 0x75: // 'u' - Restore cursor position (SCO)
            cursorRow = savedCursorRow
            cursorCol = savedCursorCol

        case 0x72: // 'r' - Set scrolling region (DECSTBM)
            // ESC[top;bottomr - set scrolling region (1-based)
            // ESC[r - reset to full screen
            let top = (escapeParams.count > 0 && escapeParams[0] > 0) ? escapeParams[0] - 1 : 0
            let bottom = (escapeParams.count > 1 && escapeParams[1] > 0) ? escapeParams[1] - 1 : terminalRows - 1
            if top < bottom && bottom < terminalRows {
                scrollTop = top
                scrollBottom = bottom
                // Cursor moves to home position after setting region
                cursorRow = 0
                cursorCol = 0
            }

        case 0x68: // 'h' - Set Mode
            if escapePrivateMode {
                // DEC Private Mode Set (e.g., ESC[?7h = enable line wrap)
                // We acknowledge these but don't change behavior
            }
            break

        case 0x6C: // 'l' - Reset Mode
            if escapePrivateMode {
                // DEC Private Mode Reset (e.g., ESC[?7l = disable line wrap)
                // We acknowledge these but don't change behavior
            }
            break

        default:
            // Unknown CSI sequence, ignore
            break
        }
    }

    /// Apply SGR (Select Graphic Rendition) parameter
    private func applySGR(_ param: Int) {
        switch param {
        case 0: // Reset
            currentAttr = 0x07
        case 1: // Bold (use bright colors)
            currentAttr |= 0x08
        case 7: // Reverse video
            let fg = currentAttr & 0x0F
            let bg = (currentAttr >> 4) & 0x07
            currentAttr = (fg << 4) | bg
        case 27: // Reverse off
            currentAttr = 0x07
        case 30...37: // Foreground colors
            let color = UInt8(param - 30)
            currentAttr = (currentAttr & 0xF0) | color
        case 40...47: // Background colors
            let color = UInt8(param - 40)
            currentAttr = (currentAttr & 0x0F) | (color << 4)
        default:
            break
        }
    }

    /// Clear from cursor to end of screen
    private func clearFromCursor() {
        // Clear rest of current line
        for col in cursorCol..<terminalCols {
            terminalCells[cursorRow][col] = TerminalCell()
        }
        // Clear remaining lines
        for row in (cursorRow + 1)..<terminalRows {
            for col in 0..<terminalCols {
                terminalCells[row][col] = TerminalCell()
            }
        }
    }

    /// Clear from beginning to cursor
    private func clearToCursor() {
        // Clear lines before current
        for row in 0..<cursorRow {
            for col in 0..<terminalCols {
                terminalCells[row][col] = TerminalCell()
            }
        }
        // Clear current line up to cursor
        for col in 0...cursorCol {
            terminalCells[cursorRow][col] = TerminalCell()
        }
    }

    func emulatorVDAScrollUp(_ lines: Int32) {
        DispatchQueue.main.async {
            self.scrollUp(Int(lines))
        }
    }

    func emulatorVDASetAttr(_ attr: UInt8) {
        // Attr is CGA-style: bits 0-3 = foreground, bits 4-6 = background, bit 7 = blink
        // For now, store and use when writing chars
        // This could be enhanced to update current attribute state
    }

    private func scrollUp(_ lines: Int) {
        guard lines > 0 else { return }

        for row in 0..<(terminalRows - lines) {
            terminalCells[row] = terminalCells[row + lines]
        }
        for row in (terminalRows - lines)..<terminalRows {
            terminalCells[row] = Array(repeating: TerminalCell(), count: terminalCols)
        }
    }

    private func scrollRegion(_ top: Int, _ bottom: Int, _ lines: Int) {
        guard lines > 0 && top >= 0 && bottom < terminalRows && top < bottom else { return }

        // Scroll lines within the region [top, bottom]
        for row in top..<(bottom - lines + 1) {
            terminalCells[row] = terminalCells[row + lines]
        }
        // Clear the bottom lines of the region
        for row in (bottom - lines + 1)...bottom {
            terminalCells[row] = Array(repeating: TerminalCell(), count: terminalCols)
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
            self.statusText = "R8: Select file to import..."
            self.showingHostFileImporter = true
        }
    }

    func emulatorHostFileDownload(_ filename: String, data: Data) {
        DispatchQueue.main.async {
            // Save to Documents/Disks directory
            let saveURL = self.downloadsDirectory.appendingPathComponent(filename)
            do {
                try data.write(to: saveURL)
                self.statusText = "W8: Saved \(filename) (\(data.count) bytes)"
                self.debugPrint("[HostFile] Saved \(filename) to \(saveURL.path)")

                // Also show share sheet for convenience
                self.hostFileExportData = data
                self.hostFileExportFilename = filename
                self.showingHostFileExporter = true
            } catch {
                self.showError("Failed to save \(filename): \(error.localizedDescription)")
            }
        }
    }

    /// Handle result from host file importer (R8)
    func handleHostFileImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else {
                emu_host_file_cancel()
                statusText = "R8: Cancelled"
                return
            }

            guard url.startAccessingSecurityScopedResource() else {
                emu_host_file_cancel()
                showError("Cannot access file: \(url.lastPathComponent)")
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }

            do {
                let data = try Data(contentsOf: url)
                // Provide data to emulator
                data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                    if let ptr = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                        emu_host_file_load(ptr, data.count)
                    }
                }
                statusText = "R8: Loaded \(url.lastPathComponent) (\(data.count) bytes)"
            } catch {
                emu_host_file_cancel()
                showError("Failed to read file: \(error.localizedDescription)")
            }

        case .failure(let error):
            emu_host_file_cancel()
            if (error as NSError).code != NSUserCancelledError {
                showError("Import failed: \(error.localizedDescription)")
            } else {
                statusText = "R8: Cancelled"
            }
        }
    }

    /// Handle cancellation of host file importer
    func handleHostFileImportCancel() {
        emu_host_file_cancel()
        statusText = "R8: Cancelled"
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
                    sha256: currentDisk["sha256"]
                )
                disks.append(disk)
            }
        default:
            break
        }
    }
}
