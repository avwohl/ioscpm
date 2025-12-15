/*
 * EmulatorViewModel.swift - View model for RomWBW emulator
 */

import SwiftUI
import Combine
import AVFoundation

// ROM option with name and filename
struct ROMOption: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let filename: String
}

// Disk option with name and filename
struct DiskOption: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let filename: String
    var isDownloaded: Bool = false  // true if available locally
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

    var sizeDescription: String {
        if sizeBytes >= 1_000_000 {
            return String(format: "%.1f MB", Double(sizeBytes) / 1_000_000)
        } else {
            return String(format: "%.0f KB", Double(sizeBytes) / 1_000)
        }
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

    // ROM selection
    @Published var selectedROM: ROMOption?
    let availableROMs: [ROMOption] = [
        ROMOption(name: "EMU AVW (Recommended)", filename: "emu_avw.rom"),
        ROMOption(name: "EMU RomWBW", filename: "emu_romwbw.rom"),
        ROMOption(name: "SBC SIMH", filename: "SBC_simh_std.rom"),
    ]

    // Disk selection for slots 0-3 (OS slots) and data drives
    @Published var selectedDisks: [DiskOption?] = Array(repeating: nil, count: 4)
    @Published var availableDisks: [DiskOption] = [
        DiskOption(name: "None", filename: ""),
    ]

    // Downloadable disk catalog - URLs for disk images users can download
    let diskCatalog: [DownloadableDisk] = [
        DownloadableDisk(
            filename: "hd1k_cpm22.img",
            name: "CP/M 2.2",
            description: "Digital Research CP/M 2.2 operating system. The classic 8-bit OS.",
            url: "https://github.com/wwarthen/RomWBW/raw/dev/Binary/hd1k_cpm22.img",
            sizeBytes: 8_388_608,
            license: "Free (Lineo license)"
        ),
        DownloadableDisk(
            filename: "hd1k_zsdos.img",
            name: "ZSDOS",
            description: "Z-System DOS - Enhanced CP/M compatible OS with date/time stamping.",
            url: "https://github.com/wwarthen/RomWBW/raw/dev/Binary/hd1k_zsdos.img",
            sizeBytes: 8_388_608,
            license: "Free"
        ),
        DownloadableDisk(
            filename: "hd1k_nzcom.img",
            name: "NZCOM",
            description: "ZCPR3 environment with enhanced command processor.",
            url: "https://github.com/wwarthen/RomWBW/raw/dev/Binary/hd1k_nzcom.img",
            sizeBytes: 8_388_608,
            license: "Free"
        ),
        DownloadableDisk(
            filename: "hd1k_cpm3.img",
            name: "CP/M 3 (Plus)",
            description: "Digital Research CP/M Plus with banked memory support.",
            url: "https://github.com/wwarthen/RomWBW/raw/dev/Binary/hd1k_cpm3.img",
            sizeBytes: 8_388_608,
            license: "Free"
        ),
        DownloadableDisk(
            filename: "hd1k_zpm3.img",
            name: "ZPM3",
            description: "Z-System CP/M 3 - Enhanced CP/M Plus with ZCPR support.",
            url: "https://github.com/wwarthen/RomWBW/raw/dev/Binary/hd1k_zpm3.img",
            sizeBytes: 8_388_608,
            license: "Free"
        ),
        DownloadableDisk(
            filename: "hd1k_ws4.img",
            name: "WordStar 4",
            description: "WordStar 4 word processor - the legendary CP/M application.",
            url: "https://github.com/wwarthen/RomWBW/raw/dev/Binary/hd1k_ws4.img",
            sizeBytes: 8_388_608,
            license: "Abandonware"
        ),
    ]

    // Download state tracking
    @Published var downloadStates: [String: DownloadState] = [:]
    private var downloadTasks: [String: URLSessionDownloadTask] = [:]

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
    private var savedCursorRow: Int = 0
    private var savedCursorCol: Int = 0
    private var currentAttr: UInt8 = 0x07  // Default: white on black

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
        let message = "Press Play to start"
        let startCol = (terminalCols - message.count) / 2
        let startRow = terminalRows / 2

        for (i, char) in message.enumerated() {
            terminalCells[startRow][startCol + i].character = char
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
            print("Audio engine failed to start: \(error)")
        }
    }

    // MARK: - Resource Loading

    func loadBundledResources() {
        // Refresh list of downloaded disks
        refreshAvailableDisks()

        // Set default selections only if not already set
        if selectedROM == nil {
            selectedROM = availableROMs.first
        }
        if selectedDisks[0] == nil {
            // Try to select CP/M 2.2 if downloaded, otherwise None
            selectedDisks[0] = availableDisks.first { $0.filename == "hd1k_cpm22.img" }
                ?? availableDisks.first
        }

        if availableDisks.count <= 1 {
            statusText = "Download disk images in Settings to get started"
        } else {
            statusText = "Ready - Select ROM and disks, then Start"
        }
    }

    func loadSelectedResources() {
        // Load selected ROM
        let romFile = selectedROM?.filename ?? "emu_avw.rom"
        print("[EmulatorVM] Loading ROM: \(romFile)")
        guard emulator?.loadROM(fromBundle: romFile) == true else {
            print("[EmulatorVM] ERROR: Failed to load ROM: \(romFile)")
            statusText = "Error: \(romFile) not found"
            return
        }
        print("[EmulatorVM] ROM loaded successfully: \(romFile)")
        statusText = "ROM loaded: \(selectedROM?.name ?? romFile)"

        // Load selected disks
        for unit in 0..<selectedDisks.count {
            print("[EmulatorVM] Loading disk unit \(unit): \(selectedDisks[unit]?.filename ?? "none")")

            // First check if there's a local file URL for this unit
            if let url = localDiskURLs[unit] {
                if loadLocalDisk(unit: unit, from: url) {
                    print("[EmulatorVM] Loaded local disk to unit \(unit)")
                    statusText = "Loaded local file to \(diskLabels[unit])"
                    continue
                }
            }

            // Check for downloaded disk
            if let disk = selectedDisks[unit], !disk.filename.isEmpty {
                if disk.isDownloaded {
                    // Load from downloads directory
                    if loadDownloadedDisk(unit: unit, filename: disk.filename) {
                        print("[EmulatorVM] Loaded downloaded disk \(disk.filename) to unit \(unit)")
                        statusText = "Loaded: \(disk.name) to \(diskLabels[unit])"
                        continue
                    }
                }

                // Try loading from bundle as fallback
                let success = emulator?.loadDisk(Int32(unit), fromBundle: disk.filename) == true
                print("[EmulatorVM] loadDisk(\(unit), \(disk.filename)) = \(success)")
                if success {
                    statusText = "Loaded: \(disk.name) to \(diskLabels[unit])"
                } else {
                    print("[EmulatorVM] ERROR: Failed to load \(disk.filename) to unit \(unit)")
                }
            }
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
        // Clear terminal before starting (removes "Press Play" message)
        clearTerminal()
        // Load selected ROM and disks before starting
        loadSelectedResources()
        emulator?.start()
        isRunning = emulator?.isRunning ?? false
        statusText = "Running"
        terminalShouldFocus = true  // Auto-focus terminal
    }

    func stop() {
        emulator?.stop()
        isRunning = false
    }

    func reset() {
        emulator?.reset()
        clearTerminal()
        isRunning = false
        statusText = "Reset - Press Play to start"
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

    /// Refresh the list of available disks (bundled + downloaded)
    func refreshAvailableDisks() {
        var disks: [DiskOption] = [DiskOption(name: "None", filename: "")]

        // Add downloaded disks
        for catalog in diskCatalog {
            if isDiskDownloaded(catalog.filename) {
                disks.append(DiskOption(
                    name: catalog.name,
                    filename: catalog.filename,
                    isDownloaded: true
                ))
                downloadStates[catalog.filename] = .downloaded
            } else if downloadStates[catalog.filename] == nil {
                downloadStates[catalog.filename] = .notDownloaded
            }
        }

        // Check for any other .img files in downloads directory
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

    /// Download a disk image from the catalog
    func downloadDisk(_ disk: DownloadableDisk) {
        guard let url = URL(string: disk.url) else {
            downloadStates[disk.filename] = .error("Invalid URL")
            return
        }

        downloadStates[disk.filename] = .downloading(progress: 0)

        let task = URLSession.shared.downloadTask(with: url) { [weak self] tempURL, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }

                if let error = error {
                    self.downloadStates[disk.filename] = .error(error.localizedDescription)
                    return
                }

                guard let tempURL = tempURL else {
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

        case 0x0A: // Line feed
            cursorRow += 1
            if cursorRow >= terminalRows {
                scrollUp(1)
                cursorRow = terminalRows - 1
            }

        case 0x0D: // Carriage return
            cursorCol = 0

        case 0x1B: // ESC - start escape sequence
            escapeState = .escape
            escapeParams = []
            escapeCurrentParam = ""

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
            // Unknown escape sequence, return to normal
            escapeState = .normal
        }
    }

    /// Process character in CSI sequence
    private func processCSIChar(_ ch: unichar) {
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

        case 0x72: // 'r' - Set scrolling region (ignore for now)
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

    // MARK: - Sound

    func emulatorBeep(_ durationMs: Int32) {
        DispatchQueue.main.async {
            self.playBeep(durationMs: Int(durationMs))
        }
    }
}
