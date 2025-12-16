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
    @State private var showingAbout = false

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
            .navigationTitle("Z80CPM v\(appVersion)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    // Settings button - always visible on left
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                    }
                    .disabled(viewModel.isRunning)
                }

                ToolbarItemGroup(placement: .navigationBarTrailing) {
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

                    Menu {
                        Button {
                            viewModel.saveAllDisks()
                        } label: {
                            Label("Save All Disks", systemImage: "square.and.arrow.down")
                        }

                        Divider()

                        ForEach([14, 16, 18, 20, 24, 28], id: \.self) { size in
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

                        Divider()

                        Button("Load Disk 0...") {
                            viewModel.loadDisk(0)
                        }
                        Button("Load Disk 1...") {
                            viewModel.loadDisk(1)
                        }
                        Button("Export Disk 0...") {
                            viewModel.saveDisk(0)
                        }
                        Button("Export Disk 1...") {
                            viewModel.saveDisk(1)
                        }

                        Divider()

                        Button {
                            showingAbout = true
                        } label: {
                            Label("About", systemImage: "info.circle")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .fullScreenCover(isPresented: $showingSettings) {
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
            .sheet(isPresented: $showingAbout) {
                AboutView()
            }
        }
        .navigationViewStyle(.stack)  // Force single column on Mac
        .onAppear {
            viewModel.loadBundledResources()
        }
    }
}

// MARK: - About View

struct AboutView: View {
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 60))
                    .foregroundColor(.blue)

                Text("Z80CPM")
                    .font(.title)
                    .fontWeight(.bold)

                Text("Version \(appVersion)")
                    .foregroundColor(.secondary)

                Text("Z80/CP/M emulator for iOS and macOS")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                Divider()
                    .padding(.horizontal, 40)

                VStack(spacing: 12) {
                    Link(destination: URL(string: "https://github.com/wwarthen/RomWBW")!) {
                        HStack {
                            Image(systemName: "link")
                            Text("RomWBW Project")
                        }
                    }

                    Link(destination: URL(string: "https://github.com/avwohl/ioscpm")!) {
                        HStack {
                            Image(systemName: "link")
                            Text("iOS/Mac Source Code")
                        }
                    }
                }

                Spacer()

                VStack(spacing: 4) {
                    Text("License: MIT")
                        .font(.caption)
                    Text("CP/M OS licensed by Lineo for non-commercial use")
                        .font(.caption)
                }
                .foregroundColor(.secondary)
                .padding(.bottom, 20)
            }
            .padding()
            .navigationTitle("About")
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
                // Scroll hint
                Section {
                    HStack {
                        Spacer()
                        Text("↓ Scroll for more options")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                }
                .listRowBackground(Color.clear)

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

                    Text("Max disk size: 64MB (hd1k format)")
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

                // Download Disk Images Section
                Section(header: Text("Download Disk Images")) {
                    Text("Download CP/M disk images to use offline. Images are stored in the app's Documents folder.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if viewModel.catalogLoading {
                        HStack {
                            ProgressView()
                            Text("Loading disk catalog...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } else if let error = viewModel.catalogError {
                        HStack {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundColor(.orange)
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Button("Retry") {
                            viewModel.fetchDiskCatalog()
                        }
                    } else {
                        ForEach(viewModel.diskCatalog) { disk in
                            DiskDownloadRow(disk: disk, viewModel: viewModel)
                        }

                        Button {
                            viewModel.fetchDiskCatalog()
                        } label: {
                            Label("Refresh Catalog", systemImage: "arrow.clockwise")
                        }
                        .font(.caption)
                    }
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

                    Link(destination: URL(string: "https://github.com/wwarthen/RomWBW")!) {
                        HStack {
                            Text("RomWBW Project")
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .foregroundColor(.secondary)
                        }
                    }

                    Link(destination: URL(string: "https://github.com/avwohl/ioscpm")!) {
                        HStack {
                            Text("iOS/Mac Source Code")
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .foregroundColor(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Z80CPM - a CP/M emulator for iOS and macOS")
                            .font(.caption)
                        Text("Built on the RomWBW HBIOS platform")
                            .font(.caption)
                        Text("License: MIT")
                            .font(.caption)
                        Text("CP/M OS licensed by Lineo for non-commercial use")
                            .font(.caption)
                    }
                    .foregroundColor(.secondary)
                }
            }
            .ifAvailable { view in
                if #available(iOS 16.0, *) {
                    view.scrollIndicators(.visible)
                } else {
                    view
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
        .navigationViewStyle(.stack)
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

// MARK: - Disk Download Row

struct DiskDownloadRow: View {
    let disk: DownloadableDisk
    @ObservedObject var viewModel: EmulatorViewModel

    var downloadState: DownloadState {
        viewModel.downloadStates[disk.filename] ?? .notDownloaded
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(disk.name)
                        .font(.headline)
                    Text(disk.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        Text(disk.sizeDescription)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("•")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(disk.license)
                            .font(.caption2)
                            .foregroundColor(.blue)
                    }
                }

                Spacer()

                downloadButton
            }

            // Progress bar for downloading
            if case .downloading(let progress) = downloadState {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
            }

            // Error message
            if case .error(let message) = downloadState {
                Text(message)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    var downloadButton: some View {
        switch downloadState {
        case .notDownloaded:
            Button {
                viewModel.downloadDisk(disk)
            } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.title2)
            }
            .buttonStyle(.borderless)

        case .downloading:
            Button {
                viewModel.cancelDownload(disk.filename)
            } label: {
                Image(systemName: "xmark.circle")
                    .font(.title2)
                    .foregroundColor(.orange)
            }
            .buttonStyle(.borderless)

        case .downloaded:
            Menu {
                Button {
                    viewModel.deleteDownloadedDisk(disk.filename)
                } label: {
                    Label("Delete", systemImage: "trash")
                        .foregroundColor(.red)
                }
            } label: {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(.green)
            }

        case .error:
            Button {
                viewModel.downloadDisk(disk)
            } label: {
                Image(systemName: "arrow.clockwise.circle")
                    .font(.title2)
                    .foregroundColor(.red)
            }
            .buttonStyle(.borderless)
        }
    }
}

#Preview {
    ContentView()
}

// MARK: - View Extension for iOS version compatibility

extension View {
    @ViewBuilder
    func ifAvailable<Content: View>(@ViewBuilder transform: (Self) -> Content) -> some View {
        transform(self)
    }
}
