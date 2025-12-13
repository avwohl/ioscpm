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
}

class EmulatorViewModel: NSObject, ObservableObject {
    @Published var statusText: String = "Ready"
    @Published var isRunning: Bool = false

    @Published var showingDiskPicker: Bool = false
    @Published var showingDiskExporter: Bool = false
    @Published var showingError: Bool = false
    @Published var errorMessage: String = ""

    // ROM selection
    @Published var selectedROM: ROMOption?
    let availableROMs: [ROMOption] = [
        ROMOption(name: "SBC SIMH (Default)", filename: "SBC_simh_std.rom"),
        ROMOption(name: "EMU RomWBW", filename: "emu_romwbw.rom"),
        ROMOption(name: "RCZ80", filename: "RCZ80_std.rom"),
        ROMOption(name: "EMU RCZ80", filename: "emu_rcz80.rom"),
    ]

    // Disk selection for slots 0-3 (OS slots) and data drives
    @Published var selectedDisks: [DiskOption?] = Array(repeating: nil, count: 4)
    let availableDisks: [DiskOption] = [
        DiskOption(name: "None", filename: ""),
        DiskOption(name: "CP/M 2.2", filename: "cpm_wbw.img"),
        DiskOption(name: "ZSDOS", filename: "zsys_wbw.img"),
        DiskOption(name: "QPM", filename: "qpm_wbw.img"),
        DiskOption(name: "Drive A Data", filename: "drivea.img"),
    ]

    // Disk slot labels
    let diskLabels = ["Disk 0 (OS)", "Disk 1 (OS)", "Disk 2 (OS)", "Disk 3 (Data)"]

    // Boot string for auto-boot
    @Published var bootString: String = ""

    // Current disk unit being imported/exported
    var currentDiskUnit: Int = 0
    var exportDocument: DiskImageDocument?

    // Local disk file URLs (for file-backed disks)
    @Published var localDiskURLs: [URL?] = Array(repeating: nil, count: 4)

    // For creating new disk files
    @Published var showingCreateDisk: Bool = false
    @Published var showingOpenDisk: Bool = false
    var diskUnitForFileOp: Int = 0

    // Maximum disk size (8MB due to 8-bit OS addressing limits)
    static let maxDiskSize = 8 * 1024 * 1024  // 8MB
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

    override init() {
        super.init()

        // Initialize terminal cells
        terminalCells = Array(repeating: Array(repeating: TerminalCell(), count: terminalCols), count: terminalRows)

        emulator = RomWBWEmulator()
        emulator?.delegate = self

        setupAudio()
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
        // Set default selections
        selectedROM = availableROMs.first
        selectedDisks[0] = availableDisks.first { $0.filename == "cpm_wbw.img" }
        selectedDisks[1] = availableDisks.first { $0.filename == "zsys_wbw.img" }
        selectedDisks[2] = availableDisks.first { $0.filename == "qpm_wbw.img" }
        selectedDisks[3] = availableDisks.first { $0.filename == "drivea.img" }

        statusText = "Ready - Select ROM and disks, then Start"
    }

    func loadSelectedResources() {
        // Load selected ROM
        let romFile = selectedROM?.filename ?? "SBC_simh_std.rom"
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
            // First check if there's a local file URL for this unit
            if let url = localDiskURLs[unit] {
                if loadLocalDisk(unit: unit, from: url) {
                    statusText = "Loaded local file to \(diskLabels[unit])"
                    continue
                }
            }

            // Otherwise load from bundled disk
            if let disk = selectedDisks[unit], !disk.filename.isEmpty {
                if emulator?.loadDisk(Int32(unit), fromBundle: disk.filename) == true {
                    statusText = "Loaded: \(disk.name) to \(diskLabels[unit])"
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
        // Load selected ROM and disks before starting
        loadSelectedResources()
        emulator?.start()
        isRunning = emulator?.isRunning ?? false
        statusText = "Running"
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
        let code = char.asciiValue ?? UInt8(char.utf16.first ?? 0)
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

    // MARK: - Sound Generation

    private func playBeep(durationMs: Int) {
        guard let engine = audioEngine, let player = tonePlayer else { return }

        let sampleRate: Double = 44100
        let frequency: Double = 800  // 800 Hz beep
        let duration = Double(durationMs) / 1000.0
        let frameCount = AVAudioFrameCount(sampleRate * duration)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.mainMixerNode.outputFormat(forBus: 0),
                                            frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount

        let channels = Int(buffer.format.channelCount)
        for ch in 0..<channels {
            guard let channelData = buffer.floatChannelData?[ch] else { continue }
            for frame in 0..<Int(frameCount) {
                let phase = Double(frame) / sampleRate * frequency * 2.0 * .pi
                // Square wave
                channelData[frame] = sin(phase) > 0 ? 0.3 : -0.3
            }
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
            let char = Character(UnicodeScalar(ch) ?? UnicodeScalar(32))

            // Handle control characters
            switch ch {
            case 0x07: // Bell
                self.playBeep(durationMs: 100)
                return

            case 0x08: // Backspace
                if self.cursorCol > 0 {
                    self.cursorCol -= 1
                }
                return

            case 0x09: // Tab
                self.cursorCol = min((self.cursorCol + 8) & ~7, self.terminalCols - 1)
                return

            case 0x0A: // Line feed
                self.cursorRow += 1
                if self.cursorRow >= self.terminalRows {
                    self.scrollUp(1)
                    self.cursorRow = self.terminalRows - 1
                }
                return

            case 0x0D: // Carriage return
                self.cursorCol = 0
                return

            default:
                break
            }

            // Printable character
            if ch >= 0x20 && ch <= 0x7E {
                self.terminalCells[self.cursorRow][self.cursorCol].character = char
                self.cursorCol += 1
                if self.cursorCol >= self.terminalCols {
                    self.cursorCol = 0
                    self.cursorRow += 1
                    if self.cursorRow >= self.terminalRows {
                        self.scrollUp(1)
                        self.cursorRow = self.terminalRows - 1
                    }
                }
            }
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
