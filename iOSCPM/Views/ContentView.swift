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
    @State private var showingResetConfirm = false

    /// True while something modal is drawn over the terminal. The terminal view
    /// is still the first responder underneath, and its key commands are the
    /// first UIKit consults, so without this Escape and Return reach CP/M
    /// instead of dismissing the dialog. Sheets are not listed: they cover the
    /// terminal entirely and present their own responder.
    private var modalHasKeyboard: Bool {
        viewModel.showingManifestWriteWarning || viewModel.showingError || showingResetConfirm
    }

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
                    captureKeyboard: !modalHasKeyboard,
                    showCursor: !viewModel.isScrolledBack && viewModel.cursorVisible,
                    showKeyRow: viewModel.showKeyRow,
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

                    // Scrollback state, in the open. "sb 0/0" after a boot and a
                    // couple of DIRs means nothing ever scrolled off the top, so
                    // there is nothing to scroll back to - which is otherwise
                    // indistinguishable from the scroll input being broken.
                    Text("sb \(viewModel.scrollbackOffset)/\(viewModel.scrollbackAvailable)")
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
                        showingResetConfirm = true
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    // Anchored on the button so the iPad/Catalyst popover points
                    // at the control the user tapped.
                    .confirmationDialog("Reset the machine?",
                                        isPresented: $showingResetConfirm,
                                        titleVisibility: .visible) {
                        Button("Reset", role: .destructive) { viewModel.reset() }
                        Button("Cancel", role: .cancel) { }
                    } message: {
                        Text("Stops the machine, clears the scrollback and returns it to the power-on state. Disk changes are saved first; press Play to boot again.")
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
            // EmptyDiskDocument(sizeBytes:), not EmptyDiskDocument(). This
            // document is what actually writes the file the picker creates, and
            // it ran BEFORE createNewDisk: with the size hardcoded inside it,
            // the exporter laid down 8 MB and only the rewrite below honoured
            // the user's choice. Both read viewModel.newDiskSize now.
            //
            // The modifier is re-evaluated when newDiskSize changes - it is
            // @Published and this body reads it - so the document handed to the
            // picker carries the current choice.
            .fileExporter(
                isPresented: $viewModel.showingCreateDisk,
                document: EmptyDiskDocument(sizeBytes: viewModel.newDiskSize.bytes),
                contentType: .data,
                defaultFilename: "newdisk.img"
            ) { result in
                if case .success(let url) = result {
                    viewModel.createNewDisk(at: url)
                }
            }
            // The iOS 15 alert API, not alert(isPresented:content:). Two of the
            // OLD form were chained on this same view - this one and the
            // manifest warning below - and only one alert(isPresented:) per view
            // is ever honoured, so the later modifier replaced this one and
            // showError() put up nothing at all. Measured, not deduced: build 56's
            // catalog-invalidation alert fired and no alert appeared, while the
            // manifest warning on the same screen worked. The newer API stacks.
            .alert(viewModel.errorTitle, isPresented: $viewModel.showingError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage)
            }
            .alert("Disk May Be Overwritten", isPresented: $viewModel.showingManifestWriteWarning) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("This disk may be replaced when the app updates. Any changes you save could be lost.\n\nTo keep changes permanently, use 'Save Disk As' to copy to your own file.")
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
            // ...and for the Emulator menu, which travels the same way.
            .onReceive(NotificationCenter.default.publisher(for: .emulatorCommand)) { note in
                if let raw = note.object as? String,
                   let command = EmulatorMenuCommand(rawValue: raw) {
                    perform(command)
                }
            }
        }
        .navigationViewStyle(.stack)  // Force single column on Mac
        .onAppear {
            viewModel.loadBundledResources()
            // One turn later: the scene exists by the time a view appears, but
            // its window may not have been laid out yet, and a geometry request
            // against an unlaid-out scene is refused.
            DispatchQueue.main.async { restoreWindowState() }
        }
        .onChange(of: scenePhase) { newPhase in
            print("[ScenePhase] Changed to: \(newPhase)")
            if newPhase == .background || newPhase == .inactive {
                viewModel.saveDisksOnBackground()
                // Deactivating is the last moment the frame still means
                // something. On anything but Catalyst this is a no-op.
                saveWindowState()
            }
        }
    }

    /// Carry out a menu command.
    ///
    /// Every one of these is the same call the corresponding on-screen control
    /// makes, including Reset going through the confirmation rather than round
    /// it: a menu item that destroys more than its toolbar twin would is a trap.
    private func perform(_ command: EmulatorMenuCommand) {
        switch command {
        case .startStop:
            if viewModel.isRunning { viewModel.stop() } else { viewModel.start() }
        case .reset:
            showingResetConfirm = true
        case .clearScreen:
            viewModel.clearTerminal()
        case .scrollToLive:
            viewModel.scrollToLiveBottom()
        case .saveAllDisks:
            viewModel.saveAllDisks()
        case .openImports:
            viewModel.openImportsFolder()
        case .openExports:
            viewModel.openExportsFolder()
        case .settings:
            showingSettings = true
        }
    }

    private func restoreWindowState() {
        #if targetEnvironment(macCatalyst)
        CatalystWindow.restore()
        #endif
    }

    private func saveWindowState() {
        #if targetEnvironment(macCatalyst)
        CatalystWindow.save()
        #endif
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

                // The RomWBW release the core emulates. A disk slice built by a
                // different release prints an HBIOS/CBIOS version mismatch, so
                // this is the first thing to ask for in a bug report.
                Text("RomWBW \(RomWBWEmulator.romWBWPin()) core")
                    .font(.caption)
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
    /// Name being typed into the "Save Current As" field.
    @State private var newProfileName = ""

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

                // Configuration profiles.
                //
                // A named set of ROM, disks, boot string, terminal settings and
                // key map - the whole machine, not just the key map, which is
                // what KeyProfile already was. Extracted into its own small
                // view: this Form is already large enough to be worth keeping
                // out of one type-check.
                ProfileSection(viewModel: viewModel, newProfileName: $newProfileName)

                // Preferences Section
                Section(header: Text("Preferences")) {
                    Toggle("Warn on Downloaded Disk Writes", isOn: Binding(
                        get: { viewModel.warnManifestWrites },
                        set: { viewModel.warnManifestWrites = $0 }
                    ))
                    Text("Show warning when writing to downloaded disks (changes may be lost on app update)")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Toggle("On-screen Key Row", isOn: Binding(
                        get: { viewModel.showKeyRow },
                        set: { viewModel.showKeyRow = $0 }
                    ))
                    Text("Show a row of arrow, editing and function keys under the terminal. Without a hardware keyboard it is the only way to press them. On a Mac it is also the only way to send Ctrl+arrow, which the system takes for itself.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Picker("New Disk Size", selection: Binding(
                        get: { viewModel.newDiskSize },
                        set: { viewModel.newDiskSize = $0 }
                    )) {
                        ForEach(DiskSize.offered) { size in
                            Text(size.label).tag(size)
                        }
                    }
                    .pickerStyle(.menu)
                    Text("Size of a disk made with \"Create New...\". Anything larger than the 8 MB single slice is laid out as hd512 slices, each of which comes up as its own CP/M drive letter. A created disk is blank - no system, no boot track.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Toggle("Terminal Bell", isOn: Binding(
                        get: { viewModel.bellEnabled },
                        set: { viewModel.bellEnabled = $0 }
                    ))
                    Text("Make a sound when a program sends BEL (Ctrl-G). Turn off to silence a program that rings it in a loop. The setting is yours: resetting the machine does not turn it back on.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Picker("Scrollback", selection: Binding(
                        get: { viewModel.scrollbackCapacity },
                        set: { viewModel.scrollbackCapacity = $0 }
                    )) {
                        Text("Off").tag(0)
                        Text("500 lines").tag(500)
                        Text("1000 lines").tag(1000)
                        Text("2000 lines").tag(2000)
                        Text("5000 lines").tag(5000)
                        Text("10000 lines").tag(10000)
                    }
                    .pickerStyle(.menu)
                    Text("Lines of terminal history kept for scrollback (0 disables). Scroll with two-finger drag / mouse wheel; on a hardware keyboard, Shift+PageUp/PageDown page and Ctrl+Home/End jump to oldest/live.")
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
            .alert(viewModel.errorTitle, isPresented: $viewModel.showingError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage)
            }
            .alert("Disk May Be Overwritten", isPresented: $viewModel.showingManifestWriteWarning) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("This disk may be replaced when the app updates. Any changes you save could be lost.\n\nTo keep changes permanently, use 'Save Disk As' to copy to your own file.")
            }
        }
        .navigationViewStyle(.stack)
    }
}

// Empty disk document for creating new disk files.
//
// The size is a stored property rather than a literal because this document is
// half of the write: the exporter runs it to create the file, and
// createNewDisk() then rewrites the same path. Those two used to disagree - one
// hardcoded 8 MB, the other took a size nothing passed - so a picker that fed
// only one of them would have looked like it worked and produced an 8 MB image.
struct EmptyDiskDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }

    let sizeBytes: Int

    init(sizeBytes: Int = DiskSize.default.bytes) {
        self.sizeBytes = min(max(sizeBytes, 0), EmulatorViewModel.maxDiskSize)
    }

    init(configuration: ReadConfiguration) throws {
        self.sizeBytes = DiskSize.default.bytes
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        // 0xE5 is CP/M's empty-directory marker, so this comes up as a blank drive.
        let data = Data(repeating: 0xE5, count: sizeBytes)
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

    /// Only ever set for an update that would discard the user's own bytes.
    /// A pristine image is replaced on the tap, with nothing to warn about.
    @State private var confirmingUpdate = false

    var downloadState: DownloadState {
        viewModel.downloadStates[disk.filename] ?? .notDownloaded
    }

    /// The installed file's SHA256 (first 8 chars) and whether it matches the
    /// catalog.
    ///
    /// This used to be two computed properties, and `body` read both: the text
    /// from one and its colour from the other. Each hashed the whole image, so
    /// every render of every downloaded row read the file twice - 98 MB of reads
    /// per render for the combo. Merging them halved it; the number that was
    /// still wrong was one, not two. SwiftUI re-evaluates `body` freely, and a
    /// 49 MB read has no business happening there at all.
    ///
    /// The hash now comes from the ledger's cached measurement, taken once off
    /// the main thread and stored against the size and modification time it was
    /// taken for. This is a dictionary lookup.
    var checksumStatus: (shown: String, matches: Bool)? {
        guard case .downloaded = downloadState else { return nil }
        return viewModel.installedChecksumStatus(for: disk)
    }

    /// What the app is offering to do about this image, if anything.
    var refreshPlan: DiskRefreshPlan { viewModel.refreshPlan(for: disk.filename) }

    /// The one-line note under the row when an image has been superseded.
    ///
    /// A superseded image is NOT an error and must not read like one: the disk
    /// the user has still works, and in the deferred case the app is going to
    /// fetch the new one by itself as soon as the network is right.
    var refreshNote: (text: String, systemImage: String)? {
        switch refreshPlan {
        case .doNothing:
            return nil
        case .refreshNow:
            return ("A newer version of this disk is being downloaded", "arrow.triangle.2.circlepath")
        case .deferred(let reason):
            return ("A newer version of this disk is available — \(reason.explanation)",
                    "arrow.triangle.2.circlepath")
        case .offerUpdate(let lossy):
            return (lossy
                    ? "A newer version is available. Updating replaces this disk, and any files you saved in it are lost."
                    : "A newer version of this disk is available",
                    lossy ? "exclamationmark.triangle" : "arrow.triangle.2.circlepath")
        }
    }

    /// Whether to show the Update control, and whether tapping it needs the
    /// confirmation.
    ///
    /// A NETWORK deferral must still offer it. Restricting the automatic half to
    /// Wi-Fi is only defensible because an explicit tap works on any network, and
    /// gating this on `.offerUpdate` alone left a user on cellular - or with Low
    /// Data Mode on - looking at "a newer version is available" with no way to
    /// get it. `.deferred(.mounted)` is the one that genuinely cannot be
    /// overridden by a tap: the running machine would write its own copy back.
    var updateControl: (lossy: Bool, Void)? {
        switch refreshPlan {
        case .offerUpdate(let lossy):
            return (lossy, ())
        case .deferred(let reason):
            // Only reached from a pristine verdict, so never lossy.
            return reason.isNetwork ? (false, ()) : nil
        case .doNothing, .refreshNow:
            return nil
        }
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
                        if let status = checksumStatus {
                            Text("•")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(status.shown)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(status.matches ? .green : .red)
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

            // "A newer version is available". Orange, not red: nothing has gone
            // wrong and the disk in hand still works.
            if let note = refreshNote {
                HStack(spacing: 4) {
                    Image(systemName: note.systemImage)
                    Text(note.text)
                }
                .font(.caption)
                .foregroundColor(.orange)
            }
        }
        .padding(.vertical, 4)
        .alert("Update \(disk.name)?", isPresented: $confirmingUpdate) {
            Button("Cancel", role: .cancel) {}
            Button("Update", role: .destructive) { viewModel.updateDisk(disk) }
        } message: {
            Text("""
                 This downloads the current version and replaces the copy on this \
                 device. Any files you saved inside this disk will be lost.

                 To keep them, copy them out with W8 first, or export the disk \
                 from the Files app.
                 """)
        }
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
                // The control todo.txt said did not exist: "there is no control
                // that re-downloads it". Offered whenever the catalog has moved
                // on from the installed copy, on ANY network - restricting the
                // automatic half is only defensible because this is always here.
                if let control = updateControl {
                    Button {
                        if control.lossy { confirmingUpdate = true } else { viewModel.updateDisk(disk) }
                    } label: {
                        Label("Update to Latest Version",
                              systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                Button {
                    viewModel.deleteDownloadedDisk(disk.filename)
                } label: {
                    Label("Delete", systemImage: "trash")
                        .foregroundColor(.red)
                }
            } label: {
                // Orange while an update is outstanding, so the state is visible
                // without opening the menu.
                Image(systemName: refreshNote == nil
                      ? "checkmark.circle.fill" : "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundColor(refreshNote == nil ? .green : .orange)
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


// MARK: - Configuration Profiles

/// The profile list, and the field that makes a new one.
///
/// `todo.txt` had "no configuration profiles - named sets of ROM, disks, boot
/// string, terminal and key map. KeyProfile is only the key-map half." This is
/// the UI for the other half; the values and the store are in
/// EmulatorProfile.swift, where they can be tested.
struct ProfileSection: View {
    @ObservedObject var viewModel: EmulatorViewModel
    @Binding var newProfileName: String

    private var trimmedName: String {
        newProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Section(header: Text("Configuration Profiles")) {
            if viewModel.profileStore.profiles.isEmpty {
                Text("No saved profiles. Set the machine up the way you want it, then name it below and save.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(viewModel.profileStore.profiles) { profile in
                    ProfileRow(profile: profile,
                               isCurrent: viewModel.profileStore.lastUsedName == profile.name) {
                        viewModel.applyProfile(profile)
                    }
                }
                .onDelete { offsets in
                    for index in offsets {
                        let profiles = viewModel.profileStore.profiles
                        if index < profiles.count {
                            viewModel.deleteProfile(named: profiles[index].name)
                        }
                    }
                }
                Text("Tap a profile to load it. A disk it names that is no longer in the catalog is left alone rather than cleared, and the status line says how many could not be resolved.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack {
                TextField("New profile name", text: $newProfileName)
                    .autocorrectionDisabled(true)
                    .textInputAutocapitalization(.words)
                Button("Save Current") {
                    viewModel.saveCurrentProfile(named: trimmedName)
                    newProfileName = ""
                }
                .disabled(trimmedName.isEmpty)
            }

            if let current = viewModel.profileStore.lastUsedName {
                Button("Update \"\(current)\" from Current Settings") {
                    viewModel.updateProfile(named: current)
                }
                .font(.caption)
            }
        }
    }
}

/// One row in the profile list. Its own type so the list body stays small.
struct ProfileRow: View {
    let profile: EmulatorProfile
    let isCurrent: Bool
    let apply: () -> Void

    var body: some View {
        Button(action: apply) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name)
                        .foregroundColor(.primary)
                    Text(profile.summary)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if isCurrent {
                    Image(systemName: "checkmark")
                        .foregroundColor(.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
