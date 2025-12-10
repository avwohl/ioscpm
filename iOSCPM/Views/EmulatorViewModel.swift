/*
 * EmulatorViewModel.swift - View model for CP/M emulator
 */

import SwiftUI
import Combine

class EmulatorViewModel: NSObject, ObservableObject {
    @Published var terminalText: String = ""
    @Published var statusText: String = "Ready"
    @Published var isRunning: Bool = false

    @Published var showingDiskAPicker: Bool = false
    @Published var showingDiskBPicker: Bool = false
    @Published var showingDiskAExporter: Bool = false
    @Published var showingDiskBExporter: Bool = false
    @Published var showingError: Bool = false
    @Published var errorMessage: String = ""

    var exportDocument: DiskImageDocument?

    private var emulator: CPMEmulator?
    private var outputBuffer: String = ""
    private var cursorX: Int = 0

    override init() {
        super.init()
        emulator = CPMEmulator()
        emulator?.delegate = self
    }

    // MARK: - Resource Loading

    func loadBundledResources() {
        // Load CP/M system from bundle
        guard let systemURL = Bundle.main.url(forResource: "cpm22", withExtension: "sys"),
              let systemData = try? Data(contentsOf: systemURL) else {
            statusText = "Error: cpm22.sys not found"
            return
        }

        guard emulator?.loadSystem(from: systemData) == true else {
            statusText = "Error: Failed to load system"
            return
        }

        // Load default disk image if available
        if let diskURL = Bundle.main.url(forResource: "drivea", withExtension: "img"),
           let diskData = try? Data(contentsOf: diskURL) {
            _ = emulator?.loadDiskA(diskData)
        } else {
            // Create empty disk if no default
            emulator?.createEmptyDiskA()
        }

        statusText = "System loaded - Press Play to start"
    }

    // MARK: - Emulation Control

    func start() {
        emulator?.start()
        isRunning = emulator?.isRunning ?? false
    }

    func stop() {
        emulator?.stop()
        isRunning = false
    }

    func reset() {
        emulator?.reset()
        terminalText = ""
        outputBuffer = ""
        cursorX = 0
        isRunning = false
        statusText = "Reset - Press Play to start"
    }

    func sendKey(_ char: Character) {
        emulator?.sendKey(char.utf16.first ?? 0)
    }

    // MARK: - Disk Management

    func handleDiskAImport(_ result: Result<[URL], Error>) {
        handleDiskImport(result, isDiskA: true)
    }

    func handleDiskBImport(_ result: Result<[URL], Error>) {
        handleDiskImport(result, isDiskA: false)
    }

    private func handleDiskImport(_ result: Result<[URL], Error>, isDiskA: Bool) {
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
                if isDiskA {
                    _ = emulator?.loadDiskA(data)
                } else {
                    _ = emulator?.loadDiskB(data)
                }
            } catch {
                showError("Failed to load disk: \(error.localizedDescription)")
            }

        case .failure(let error):
            showError("Import failed: \(error.localizedDescription)")
        }
    }

    func saveDiskA() {
        guard let data = emulator?.getDiskAData() else {
            showError("No disk A data to save")
            return
        }
        exportDocument = DiskImageDocument(data: data)
        showingDiskAExporter = true
    }

    func saveDiskB() {
        guard let data = emulator?.getDiskBData() else {
            showError("No disk B data to save")
            return
        }
        exportDocument = DiskImageDocument(data: data)
        showingDiskBExporter = true
    }

    func handleExportResult(_ result: Result<URL, Error>) {
        if case .failure(let error) = result {
            showError("Export failed: \(error.localizedDescription)")
        }
        exportDocument = nil
    }

    func createEmptyDiskA() {
        emulator?.createEmptyDiskA()
    }

    func createEmptyDiskB() {
        emulator?.createEmptyDiskB()
    }

    // MARK: - Helpers

    private func showError(_ message: String) {
        errorMessage = message
        showingError = true
    }
}

// MARK: - CPMEmulatorDelegate

extension EmulatorViewModel: CPMEmulatorDelegate {
    func emulatorDidOutputCharacter(_ character: unichar) {
        let ch = Int(character)

        switch ch {
        case 0x07: // Bell
            // Could play a sound
            break

        case 0x08: // Backspace
            if !outputBuffer.isEmpty {
                outputBuffer.removeLast()
                cursorX = max(0, cursorX - 1)
            }

        case 0x09: // Tab
            let spaces = 8 - (cursorX % 8)
            outputBuffer += String(repeating: " ", count: spaces)
            cursorX += spaces

        case 0x0A: // Line feed
            outputBuffer += "\n"
            cursorX = 0

        case 0x0D: // Carriage return
            // CP/M sends CR+LF, we only need to handle LF for newline
            // So ignore CR to avoid double spacing
            break

        case 0x20...0x7E: // Printable ASCII
            outputBuffer += String(UnicodeScalar(ch)!)
            cursorX += 1

        default:
            // Ignore other control characters
            break
        }

        // Update terminal (limit size to prevent memory issues)
        let maxLength = 50000
        if outputBuffer.count > maxLength {
            let startIndex = outputBuffer.index(outputBuffer.endIndex, offsetBy: -maxLength)
            outputBuffer = String(outputBuffer[startIndex...])
        }

        terminalText = outputBuffer
    }

    func emulatorDidChangeStatus(_ status: String) {
        statusText = status
    }

    func emulatorDidRequestInput() {
        // Could show a visual indicator that input is expected
    }
}
