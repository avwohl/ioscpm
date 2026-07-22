/*
 * ContentView.swift - Main view for RomWBW emulator
 */

import SwiftUI
import UniformTypeIdentifiers
import UIKit

// Read version from bundle Info.plist
let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
let appBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"

// Get build date from executable modification time
var appBuildDate: String {
    guard let executableURL = Bundle.main.executableURL,
          let attrs = try? FileManager.default.attributesOfItem(atPath: executableURL.path),
          let modDate = attrs[.modificationDate] as? Date else {
        return ""
    }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.string(from: modDate)
}

struct ContentView: View {
    @StateObject private var viewModel = EmulatorViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("terminalFontSize") private var fontSize: Double = 20
    @State private var showingSettings = false
    @State private var showingAbout = false
    @State private var showingHelp = false

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Terminal display with control key toolbar
                TerminalWithToolbar(
                    cells: Binding(get: { viewModel.displayCells }, set: { _ in }),
                    cursorRow: $viewModel.cursorRow,
                    cursorCol: $viewModel.cursorCol,
                    shouldFocus: $viewModel.terminalShouldFocus,
                    onKeyInput: { char in viewModel.sendKey(char) },
                    onSetControlify: { mode in viewModel.setControlify(mode) },
                    onScroll: { delta in viewModel.adjustScrollback(byLines: delta) },
                    onSpecialKey: { key in viewModel.sendSpecialKey(key) },
                    isControlifyActive: viewModel.isControlifyActive,
                    captureKeyboard: !viewModel.showingManifestWriteWarning,
                    showCursor: !viewModel.isScrolledBack,
                    rows: viewModel.terminalRows,
                    cols: viewModel.terminalCols,
                    fontSize: CGFloat(fontSize)
                )
                .id(fontSize)  // Force view recreation when font size changes
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottomTrailing) {
                    if viewModel.isScrolledBack {
                        Button {
                            viewModel.scrollToLiveBottom()
                        } label: {
                            Label("Live", systemImage: "arrow.down.to.line")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(.ultraThinMaterial, in: Capsule())
                                .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.3)))
                        }
                        .buttonStyle(.plain)
                        .padding(12)
                        .transition(.opacity)
                    }
                }

                // Status bar
                HStack {
                    Text("v\(appVersion).\(appBuild) \(appBuildDate)")
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
            .overlay(
                // Download overlay
                Group {
                    if viewModel.isDownloading {
                        VStack(spacing: 12) {
                            ProgressView(value: viewModel.downloadingProgress)
                                .progressViewStyle(.linear)
                                .frame(width: 200)
                            Text("Downloading \(Int(viewModel.downloadingProgress * 100))%")
                                .font(.system(.headline, design: .monospaced))
                            Text(viewModel.downloadingDiskName)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                        }
                        .padding(24)
                        .frame(minWidth: 250)
                        .background(Color(.systemBackground).opacity(0.95))
                        .cornerRadius(12)
                        .shadow(radius: 10)
                    }
                }
            )
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

                        Menu {
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
                        } label: {
                            Label("Font Size (\(Int(fontSize)) pt)", systemImage: "textformat.size")
                        }

                        Divider()

                        Menu {
                            ForEach(0..<4, id: \.self) { unit in
                                Button("Disk \(unit)...") {
                                    viewModel.loadDisk(unit)
                                }
                            }
                        } label: {
                            Label("Load Disk", systemImage: "square.and.arrow.down.on.square")
                        }
                        Menu {
                            ForEach(0..<4, id: \.self) { unit in
                                Button("Disk \(unit)...") {
                                    viewModel.saveDisk(unit)
                                }
                            }
                        } label: {
                            Label("Export Disk", systemImage: "square.and.arrow.up.on.square")
                        }

                        Divider()

                        Button {
                            viewModel.showingImportToInbox = true
                        } label: {
                            Label("Import File… (for R8)", systemImage: "square.and.arrow.down")
                        }
                        Button {
                            viewModel.openImportsFolder()
                        } label: {
                            Label("Open Imports Folder", systemImage: "folder")
                        }
                        Button {
                            viewModel.openExportsFolder()
                        } label: {
                            Label("Open Exports Folder", systemImage: "folder.fill")
                        }

                        Divider()

                        Button {
                            showingHelp = true
                        } label: {
                            Label("Help", systemImage: "questionmark.circle")
                        }

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
            .alert(isPresented: $viewModel.showingError) {
                Alert(
                    title: Text("Error"),
                    message: Text(viewModel.errorMessage),
                    dismissButton: .default(Text("OK"))
                )
            }
            .alert(isPresented: $viewModel.showingManifestWriteWarning) {
                Alert(
                    title: Text("Disk May Be Overwritten"),
                    message: Text("This disk may be replaced when the app updates. Any changes you save could be lost.\n\nTo keep changes permanently, use 'Save Disk As' to copy to your own file."),
                    dismissButton: .default(Text("OK"))
                )
            }
            .sheet(isPresented: $showingAbout) {
                AboutView()
            }
            .sheet(isPresented: $showingHelp) {
                HelpView()
            }
            // Host file modifiers extracted to reduce type-check complexity
            .hostFileModifiers(viewModel: viewModel)
            // Listen for Help menu command from menu bar
            .onReceive(NotificationCenter.default.publisher(for: .showHelp)) { _ in
                showingHelp = true
            }
        }
        .navigationViewStyle(.stack)  // Force single column on Mac
        .onAppear {
            viewModel.loadBundledResources()
        }
        .onChange(of: scenePhase) { newPhase in
            print("[ScenePhase] Changed to: \(newPhase)")
            if newPhase == .background || newPhase == .inactive {
                viewModel.saveDisksOnBackground()
            }
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

                Text("Version \(appVersion) (\(appBuild))")
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
                    Text("License: GPL v3")
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
                // Warning about downloaded disks
                Section {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("Downloaded disks may be replaced on updates. Save work to local files. ↓ Scroll")
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
                                    presentationMode.wrappedValue.dismiss()
                                }
                                .font(.caption)

                                Button("Create New...") {
                                    viewModel.createLocalDisk(unit: unit)
                                    presentationMode.wrappedValue.dismiss()
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

                }

                // Boot Section
                Section(header: Text("Boot Options")) {
                    HStack {
                        Text("Auto-Boot")
                        Spacer()
                        if viewModel.bootString.isEmpty {
                            Text("Off (shows menu)")
                                .foregroundColor(.secondary)
                        } else {
                            Text(viewModel.bootString)
                                .foregroundColor(.primary)
                        }
                    }
                    Text("Configure via ROM 'W' menu (SYSCONF)")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if !viewModel.bootString.isEmpty {
                        Button("Clear Auto-Boot") {
                            viewModel.clearAutoboot()
                        }
                    }
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

                // Preferences Section
                Section(header: Text("Preferences")) {
                    Toggle("Warn on Downloaded Disk Writes", isOn: Binding(
                        get: { viewModel.warnManifestWrites },
                        set: { viewModel.warnManifestWrites = $0 }
                    ))
                    Text("Show warning when writing to downloaded disks (changes may be lost on app update)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Keyboard mapping Section (external/hardware keyboards)
                Section(header: Text("Keyboard Mapping")) {
                    Picker("Navigation Keys", selection: Binding(
                        get: { viewModel.keyProfile },
                        set: { viewModel.keyProfile = $0 }
                    )) {
                        ForEach(KeyProfile.allCases) { profile in
                            Text(profile.rawValue).tag(profile)
                        }
                    }
                    Text("Byte sequence each navigation key sends to CP/M (hardware keyboards). Escapes: \\E=Esc, ^X=Ctrl-X, ^?=Del, \\NNN=octal, \\n \\r \\t \\b \\s.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    DisclosureGroup("Customize Keys") {
                        ForEach(SpecialKey.allCases) { key in
                            HStack {
                                Text(key.label)
                                    .frame(width: 130, alignment: .leading)
                                TextField("(unbound)", text: Binding(
                                    get: { viewModel.keyBinding(for: key) },
                                    set: { viewModel.setKeyBinding(key, to: $0) }
                                ))
                                .font(.system(.body, design: .monospaced))
                                .textFieldStyle(.roundedBorder)
                                .autocorrectionDisabled(true)
                                .textInputAutocapitalization(.never)
                            }
                        }
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
                        Text("License: GPL v3")
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
            .alert(isPresented: $viewModel.showingError) {
                Alert(
                    title: Text("Error"),
                    message: Text(viewModel.errorMessage),
                    dismissButton: .default(Text("OK"))
                )
            }
            .alert(isPresented: $viewModel.showingManifestWriteWarning) {
                Alert(
                    title: Text("Disk May Be Overwritten"),
                    message: Text("This disk may be replaced when the app updates. Any changes you save could be lost.\n\nTo keep changes permanently, use 'Save Disk As' to copy to your own file."),
                    dismissButton: .default(Text("OK"))
                )
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

// MARK: - Document Export Picker (for W8 file export)

struct DocumentExportPicker: UIViewControllerRepresentable {
    let sourceURL: URL
    let onCompletion: (Result<URL, Error>) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [sourceURL], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCompletion: onCompletion)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onCompletion: (Result<URL, Error>) -> Void

        init(onCompletion: @escaping (Result<URL, Error>) -> Void) {
            self.onCompletion = onCompletion
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first {
                onCompletion(.success(url))
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCompletion(.failure(NSError(domain: "", code: NSUserCancelledError, userInfo: nil)))
        }
    }
}

// MARK: - Disk Download Row

struct DiskDownloadRow: View {
    let disk: DownloadableDisk
    @ObservedObject var viewModel: EmulatorViewModel

    var downloadState: DownloadState {
        viewModel.downloadStates[disk.filename] ?? .notDownloaded
    }

    /// Actual SHA256 of the downloaded file (first 8 chars)
    var actualSha256Short: String? {
        guard case .downloaded = downloadState else { return nil }
        let url = viewModel.downloadsDirectory.appendingPathComponent(disk.filename)
        guard let hash = viewModel.sha256OfFile(at: url), hash.count >= 8 else { return nil }
        return String(hash.prefix(8))
    }

    /// Check if actual hash matches expected
    var checksumMatches: Bool {
        guard let actual = actualSha256Short,
              let expected = disk.sha256Short else { return true }  // No expected = assume ok
        return actual.lowercased() == expected.lowercased()
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
                        if let sha256Short = actualSha256Short {
                            Text("•")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(sha256Short)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(checksumMatches ? .green : .red)
                        } else if let expectedShort = disk.sha256Short {
                            Text("•")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(expectedShort)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
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

    /// "Import File…" — stage arbitrary host file(s) into the Imports folder so a
    /// later R8 can read them. This is user-initiated and independent of the guest:
    /// R8/W8 transfers themselves always use the Imports/Exports folders (no picker),
    /// so a batch/scripted build never triggers a file dialog.
    func hostFileModifiers(viewModel: EmulatorViewModel) -> some View {
        self
            .fileImporter(
                isPresented: Binding(
                    get: { viewModel.showingImportToInbox },
                    set: { viewModel.showingImportToInbox = $0 }
                ),
                allowedContentTypes: [.data, .item],
                allowsMultipleSelection: true
            ) { result in
                viewModel.handleImportToInbox(result)
            }
    }
}
