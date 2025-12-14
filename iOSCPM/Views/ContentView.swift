/*
 * ContentView.swift - Main view for RomWBW emulator
 */

import SwiftUI
import UniformTypeIdentifiers

// Read version from bundle Info.plist
let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"

struct ContentView: View {
    @StateObject private var viewModel = EmulatorViewModel()
    @AppStorage("terminalFontSize") private var fontSize: Double = 20
    @State private var showingSettings = false

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Terminal display
                TerminalView(
                    cells: $viewModel.terminalCells,
                    cursorRow: $viewModel.cursorRow,
                    cursorCol: $viewModel.cursorCol,
                    rows: viewModel.terminalRows,
                    cols: viewModel.terminalCols,
                    fontSize: CGFloat(fontSize),
                    shouldFocus: $viewModel.terminalShouldFocus
                ) { char in
                    viewModel.sendKey(char)
                }
                .id(fontSize)  // Force view recreation when font size changes
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Status bar
                HStack {
                    Text("v\(appVersion)")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text(viewModel.statusText)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Spacer()

                    if viewModel.isRunning {
                        Circle()
                            .fill(.green)
                            .frame(width: 8, height: 8)
                        Text("Running")
                            .font(.caption)
                            .foregroundColor(.green)
                    } else {
                        Circle()
                            .fill(.red)
                            .frame(width: 8, height: 8)
                        Text("Stopped")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 4)
                .background(Color(.systemGray6))
            }
            .navigationTitle("RomWBW v\(appVersion)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    // Settings button (ROM, Disk, Boot)
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .disabled(viewModel.isRunning)

                    Menu {
                        // Load from file
                        Button("Load Disk 0 from File...") {
                            viewModel.loadDisk(0)
                        }
                        Button("Load Disk 1 from File...") {
                            viewModel.loadDisk(1)
                        }

                        Divider()

                        // Save Disks
                        Button("Save Disk 0...") {
                            viewModel.saveDisk(0)
                        }
                        Button("Save Disk 1...") {
                            viewModel.saveDisk(1)
                        }
                    } label: {
                        Label("Disks", systemImage: "opticaldiscdrive")
                    }

                    Menu {
                        ForEach([12, 14, 16, 18, 20, 24, 28, 32], id: \.self) { size in
                            Button {
                                fontSize = Double(size)
                            } label: {
                                HStack {
                                    Text("\(size) pt")
                                    if Int(fontSize) == size {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        Label("Font Size (\(Int(fontSize)))", systemImage: "textformat.size")
                    }

                    Button {
                        if viewModel.isRunning {
                            viewModel.stop()
                        } else {
                            viewModel.start()
                        }
                    } label: {
                        Image(systemName: viewModel.isRunning ? "stop.fill" : "play.fill")
                    }

                    Button {
                        viewModel.reset()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView(viewModel: viewModel)
            }
            .fileImporter(
                isPresented: $viewModel.showingDiskPicker,
                allowedContentTypes: [.data, .item],
                allowsMultipleSelection: false
            ) { result in
                viewModel.handleDiskImport(result)
            }
            .fileExporter(
                isPresented: $viewModel.showingDiskExporter,
                document: viewModel.exportDocument,
                contentType: .data,
                defaultFilename: "disk\(viewModel.currentDiskUnit).img"
            ) { result in
                viewModel.handleExportResult(result)
            }
            .alert(isPresented: $viewModel.showingError) {
                Alert(
                    title: Text("Error"),
                    message: Text(viewModel.errorMessage),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
        .navigationViewStyle(.stack)  // Force single column on Mac
        .onAppear {
            viewModel.loadBundledResources()
        }
    }
}

// Document for file export
struct DiskImageDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @ObservedObject var viewModel: EmulatorViewModel
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        NavigationView {
            Form {
                // ROM Section
                Section(header: Text("ROM Image")) {
                    Picker("ROM", selection: $viewModel.selectedROM) {
                        ForEach(viewModel.availableROMs) { rom in
                            Text(rom.name).tag(rom as ROMOption?)
                        }
                    }
                    .pickerStyle(.menu)
                }

                // Disk Section
                Section(header: Text("Disk Images")) {
                    ForEach(0..<4, id: \.self) { unit in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(viewModel.diskLabels[unit])
                                    .font(.subheadline)
                                Spacer()
                                if viewModel.localDiskURLs[unit] != nil {
                                    Image(systemName: "doc.fill")
                                        .foregroundColor(.blue)
                                        .font(.caption)
                                }
                            }

                            Picker("", selection: $viewModel.selectedDisks[unit]) {
                                ForEach(viewModel.availableDisks) { disk in
                                    Text(disk.name).tag(disk as DiskOption?)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()

                            HStack(spacing: 12) {
                                Button("Open File...") {
                                    viewModel.openLocalDisk(unit: unit)
                                }
                                .font(.caption)

                                Button("Create New...") {
                                    viewModel.createLocalDisk(unit: unit)
                                }
                                .font(.caption)

                                if viewModel.localDiskURLs[unit] != nil {
                                    Button("Save") {
                                        viewModel.saveDiskToFile(unit: unit)
                                    }
                                    .font(.caption)
                                }
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 2)
                    }

                    Text("Max disk size: 8MB")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Boot Section
                Section(header: Text("Boot Options")) {
                    HStack {
                        Text("Boot String")
                        Spacer()
                        TextField("e.g., 0, C", text: $viewModel.bootString)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                            .multilineTextAlignment(.trailing)
                    }
                    Text("Enter a command to auto-send at boot (e.g., '0' to boot CP/M)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Debug Section
                Section(header: Text("Debug")) {
                    Toggle("Debug Mode", isOn: $viewModel.debugMode)
                    Text("Enable verbose logging to console")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Quick Start Help
                Section(header: Text("Quick Start")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("1. Select a ROM image")
                        Text("2. Select disk images for Disk 0/1")
                        Text("3. Optionally set a boot string")
                        Text("4. Tap Start to boot")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Boot Menu Keys:").fontWeight(.medium)
                        Text("h - Help")
                        Text("l - List ROM apps")
                        Text("d - List devices")
                        Text("0-9 - Boot from device")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }

                // About Section
                Section(header: Text("About")) {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(appVersion)
                            .foregroundColor(.secondary)
                    }

                    Link(destination: URL(string: "https://github.com/avwohl/ioscpm")!) {
                        HStack {
                            Text("Source Code")
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .foregroundColor(.secondary)
                        }
                    }

                    Text("RomWBW CP/M emulator for iOS and macOS")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
            .fileImporter(
                isPresented: $viewModel.showingOpenDisk,
                allowedContentTypes: [.data, .item],
                allowsMultipleSelection: false
            ) { result in
                viewModel.handleOpenDiskResult(result)
            }
            .fileExporter(
                isPresented: $viewModel.showingCreateDisk,
                document: EmptyDiskDocument(),
                contentType: .data,
                defaultFilename: "newdisk.img"
            ) { result in
                if case .success(let url) = result {
                    viewModel.createNewDisk(at: url)
                }
            }
        }
    }
}

// Empty disk document for creating new disk files
struct EmptyDiskDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }

    init() {}

    init(configuration: ReadConfiguration) throws {}

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        // Create 8MB empty disk filled with 0xE5 (CP/M format)
        let data = Data(repeating: 0xE5, count: 8 * 1024 * 1024)
        return FileWrapper(regularFileWithContents: data)
    }
}

#Preview {
    ContentView()
}
