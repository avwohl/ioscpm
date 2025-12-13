/*
 * ContentView.swift - Main view for RomWBW emulator
 */

import SwiftUI
import UniformTypeIdentifiers

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
                    fontSize: CGFloat(fontSize)
                ) { char in
                    viewModel.sendKey(char)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Status bar
                HStack {
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
            .navigationTitle("RomWBW")
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
                        Label("Font Size", systemImage: "textformat.size")
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
                    Picker("Disk 0", selection: $viewModel.selectedDisk0) {
                        ForEach(viewModel.availableDisks) { disk in
                            Text(disk.name).tag(disk as DiskOption?)
                        }
                    }
                    .pickerStyle(.menu)

                    Picker("Disk 1", selection: $viewModel.selectedDisk1) {
                        ForEach(viewModel.availableDisks) { disk in
                            Text(disk.name).tag(disk as DiskOption?)
                        }
                    }
                    .pickerStyle(.menu)
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
        }
    }
}

#Preview {
    ContentView()
}
