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
        viewModel.showingManifestWriteWarning || viewModel.showingError
            || viewModel.showingROMProblem || showingResetConfirm
    }

    /// A flag the terminal screen may only present an alert on while Settings
    /// is closed.
    ///
    /// Reading it through this is what keeps the two views from presenting the
    /// same alert at once. Writing goes straight through: the OK button on
    /// SettingsView's copy clears the flag for both, which is right - there is
    /// one condition, not two, and it has been acknowledged.
    private func whileSettingsClosed(_ flag: Binding<Bool>) -> Binding<Bool> {
        Binding(get: { flag.wrappedValue && !showingSettings },
                set: { flag.wrappedValue = $0 })
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
            //
            // All three are ALSO declared on SettingsView, and that is what
            // `whileSettingsClosed` is for. They bind the same three @Published
            // flags, so with Settings up as a full-screen cover both views tried
            // to present the same alert - and an alert presented from the root
            // takes the cover down with it. Measured on 2026-09-11: pressing
            // "Use This Catalog" on a URL that does not resolve put up "Could
            // not fetch the list of RomWBW releases" AND threw the user out of
            // Settings onto the terminal screen. SettingsView's own copy already
            // said "whichever view is on top has to be the one that can present
            // it"; nothing had ever stopped the one underneath from trying too.
            //
            // Reachable before this, but rare - the fetch it reports ran at
            // launch. Enabling "Use This Catalog" made a failing fetch something
            // the user asks for on purpose, which is what turned a corner into
            // the ordinary way to use the control.
            .alert(viewModel.errorTitle,
                   isPresented: whileSettingsClosed($viewModel.showingError)) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage)
            }
            .alert("ROM Not Available",
                   isPresented: whileSettingsClosed($viewModel.showingROMProblem)) {
                // One button, and it says nothing more than OK, because there is
                // nothing more this app can offer. It used to carry a "Use
                // RomWBW 3.5.1" escape backed by a bundled ROM; that ROM is gone
                // and inventing a substitute would boot a release the user did
                // not pick. `romProblemMessage` carries the two real ways out -
                // a connection, or the other ROM this release publishes.
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.romProblemMessage)
            }
            .alert("Disk May Be Overwritten",
                   isPresented: whileSettingsClosed($viewModel.showingManifestWriteWarning)) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("This disk may be replaced when the app updates. Any changes you save could be lost.\n\nTo keep changes permanently, use 'Save Disk As' to copy to your own file.")
            }
            .sheet(isPresented: $showingAbout) {
                AboutView(viewModel: viewModel)
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
            // The toolbar gear carries `.disabled(viewModel.isRunning)`; this
            // route did not, and the menu item it serves has a Cmd-, shortcut,
            // so on Mac Catalyst and on an iPad with a keyboard Settings opened
            // over a running machine. That matters because the disk-slot pickers
            // inside it mutate `selectedDisks` WITHOUT reloading the core, and
            // `saveDownloadedDisks()` writes the guest's live image back to the
            // file the SLOT names - so re-pointing slot 0 under a running
            // machine wrote 51 MB of the disk in the drive over whichever file
            // was picked instead. Same guard, same reason as the gear.
            guard !viewModel.isRunning else {
                viewModel.refuseWhileRunning("opening Settings")
                return
            }
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
    @ObservedObject var viewModel: EmulatorViewModel
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

                // The RomWBW release this machine is on - the loaded ROM's,
                // or the selected one before anything is loaded. A disk slice
                // built by a release other than the loaded ROM's prints an
                // HBIOS/CBIOS version mismatch, so this is the first thing to
                // ask for in a bug report.
                //
                // It named the releases this BUILD could run until romwbw_emu
                // v1.44 deleted the compile-time list behind it. There is no
                // list to name now: the core loads any ROM with a readable
                // HBIOS configuration block.
                Text(viewModel.romWBWReleaseSummary)
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
    /// The catalog index URL being typed, before it is applied. A draft rather
    /// than a direct binding because applying one tears the catalog down and
    /// refetches, which must happen when the user says so and not on each
    /// keystroke.
    @State private var catalogIndexDraft = ""
    /// Why the last attempt to apply one was refused, if it was.
    @State private var catalogIndexError: String?

    /// One line of guidance under a control, in the shape every "why can I not
    /// use this" sentence in Settings should take: caption, secondary, full
    /// width so it reads as a row rather than a stray word, and phrased as
    /// something to DO. A reason that only names the condition leaves the user
    /// exactly as stuck as silence does, so the sentence has to end in an
    /// action.
    /// True when "Use Built-In" genuinely has nothing to do: the built-in
    /// catalog is already in use AND nothing is typed in the field.
    ///
    /// One property, read by both the button's `.disabled` and the caption that
    /// explains it, so the two cannot drift apart. That drift is the whole
    /// defect this section was reported for - a control that was off for a
    /// condition no sentence on screen covered.
    private var useBuiltInHasNothingToDo: Bool {
        !viewModel.usingCustomCatalogIndex
            && catalogIndexDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func catalogHint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

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

                // The ROM.
                //
                // Its own view, for the reason ProfileSection is: this Form is
                // already large enough to be worth keeping out of one
                // type-check, and this section grew a status line, a progress
                // bar and a button.
                ROMSection(viewModel: viewModel)

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
                            // Re-pointing a slot does not reload the core, and
                            // saveDownloadedDisks() writes the drive's live
                            // image to the file the slot names. Under a running
                            // machine that overwrites the newly picked file with
                            // the old one's contents. Settings should not be
                            // reachable while running at all now; this is here so
                            // that a third way in cannot reopen the hole.
                            .disabled(viewModel.isRunning)

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

                // RomWBW release.
                //
                // Which release's disks the catalog offers, which files they are
                // (hd1k_combo-v0-3.5.1.img is not hd1k_combo-v0-3.6.0.img), and
                // which slots, boot string and downloaded images are in play.
                // Switching deletes nothing: everything is stored per release
                // and comes back on switching back.
                Section(header: Text("RomWBW Release")) {
                    Picker("Release", selection: $viewModel.romwbwVersion) {
                        // Newest published first, by index position alone - see
                        // `RomWBWIndex.displayOrder`. The view model keeps the
                        // index's own order for everything that decides which
                        // release to be on, so a preview appended to the index
                        // shows up at the top of this menu without becoming
                        // what a fresh install selects. Order here is a display
                        // choice and nothing more: the Picker matches its
                        // selection by tag, not by row position.
                        ForEach(viewModel.romwbwVersionsNewestFirst) { entry in
                            // pickerLabel carries the status, so a preview
                            // release says so where the choice is made rather
                            // than in a note further down the screen.
                            Text(entry.pickerLabel).tag(entry.romwbwVersion)
                        }
                    }
                    .pickerStyle(.menu)
                    // The switch empties the four slots, and saveDownloadedDisks()
                    // writes the guest's live image back to the file the SLOT
                    // names - so doing it under a running machine would discard
                    // the user's work on the next flush. The view model refuses
                    // it too; this is so the control does not look available.
                    .disabled(viewModel.isRunning)

                    if viewModel.isRunning {
                        Text("Stop the emulator to change release.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if let mismatch = viewModel.romReleaseMismatchNotice {
                        HStack(alignment: .top) {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundColor(.orange)
                            Text(mismatch)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    // WHY THE LIST IS SHORT, SAID WHERE THE LIST IS.
                    //
                    // A failed index hop leaves `romwbwVersions` holding one
                    // placeholder row, and until 2026-09-18 the only sign of it
                    // anywhere in Settings was a notice and a Retry under the
                    // "Download Disk Images" heading, a Section and 165 lines
                    // further down. So the symptom a user reports is "the
                    // release is stuck and there is nothing to change it to" -
                    // which is a true description of a one-row menu, and says
                    // nothing about a network failure, because nothing here
                    // did.
                    //
                    // This file already stated the rule it was breaking, a few
                    // lines up: say it where the choice is made rather than in
                    // a note further down the screen.
                    if let failure = viewModel.catalogFailure,
                       case .index = failure.stage {
                        HStack(alignment: .top) {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundColor(.orange)
                            Text(failure.summary)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        // The same call the Retry further down makes. Two
                        // buttons for one action is the right trade against a
                        // user who cannot find the one.
                        Button("Retry Fetching Releases") {
                            viewModel.fetchDiskCatalog()
                        }
                        .disabled(viewModel.catalogLoading)
                    }

                    // The opt-in, HERE rather than under Preferences, because
                    // what it changes is the list directly above it.
                    Toggle("Show Development Snapshots", isOn: Binding(
                        get: { viewModel.showPrereleaseVersions },
                        set: { viewModel.showPrereleaseVersions = $0 }
                    ))
                    Text("Off by default. RomWBW publishes development snapshots "
                         + "between releases; they are unfinished and are never "
                         + "what this app picks on its own. A snapshot reports "
                         + "itself as the release it precedes, so once one is "
                         + "running there is no way to tell from inside the "
                         + "machine which you are on. Turning this off leaves a "
                         + "snapshot you are already using in the list until you "
                         + "pick something else.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Where the catalog itself comes from.
                //
                // The point of this app compiling in exactly one URL is that
                // everything else is read from a document at run time. This is
                // that one URL, made changeable - for testing a romwbw_disks
                // release before it is published, and for running your own.
                Section(header: Text("Catalog")) {
                    if viewModel.usingCustomCatalogIndex {
                        HStack(alignment: .top) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("Using a custom catalog. Every ROM and disk comes from "
                                 + "whoever publishes it. Downloads are still checked "
                                 + "against that catalog's own SHA-256, but the catalog "
                                 + "is the thing being trusted.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    // A bare TextField in a Form draws no border, and `.caption`
                    // grey is exactly what the four prose rows around it look
                    // like - so the one editable control in this section read as
                    // another line of explanation, with a greyed-out button on
                    // either side of it as apparent proof the whole section was
                    // off. Measured, not guessed: on 2026-09-11 a tap on this
                    // row in the simulator was reported as landing on a disabled
                    // control, and only a second tap further right found the
                    // caret. `.roundedBorder` is what the key-binding fields at
                    // "Customize Keys" already use, and in a Form it is the only
                    // thing that says a row is typable.
                    TextField("Built-in catalog", text: $catalogIndexDraft)
                        .font(.system(.caption, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                        .submitLabel(.go)
                        // Return applies it too. `applyCatalogIndexURL` carries
                        // the same two refusals this field's `.disabled` does,
                        // so a hardware Return cannot get past a guard the
                        // button honours.
                        .onSubmit {
                            // The button's guard, repeated: a keyboard does not
                            // consult a button's disabled state, and the field
                            // stays typable during a fetch so that a URL can be
                            // got ready while one is in flight.
                            guard !viewModel.catalogLoading else { return }
                            catalogIndexError = viewModel.applyCatalogIndexURL(catalogIndexDraft)
                        }
                        .disabled(viewModel.isRunning
                                  || viewModel.catalogIndexURLIsFromEnvironment)

                    // Every state this section can be greyed in, said on screen
                    // and said as an INSTRUCTION.
                    //
                    // The rule is that a stopped emulator can always set the
                    // catalog, and anything that is off anyway owes the user the
                    // sentence that turns it on. The third branch is the one
                    // that was missing, and it is the ordinary resting state of
                    // a fresh install - stopped, built-in catalog, no env var -
                    // so the only screen that explained nothing was the screen
                    // everybody starts on. The other two branches render only
                    // when their condition holds, which is why the section could
                    // look most disabled while saying least.
                    if viewModel.catalogIndexURLIsFromEnvironment {
                        catalogHint("ROMWBW_INDEX_URL is set for this launch and wins over "
                                    + "anything set here. To type a catalog in, relaunch "
                                    + "without it - clear it from the scheme's environment "
                                    + "variables in Xcode, or drop SIMCTL_CHILD_ROMWBW_INDEX_URL "
                                    + "from the simctl launch.")
                    } else if viewModel.isRunning {
                        catalogHint("Stop the emulator - Stop on the main screen - and this "
                                    + "field and both buttons come back.")
                    } else if viewModel.catalogLoading {
                        catalogHint("Reading the catalog now. Wait for it to finish - a "
                                    + "second fetch started on top of this one would race "
                                    + "it, and whichever answered first would decide.")
                    } else if useBuiltInHasNothingToDo {
                        catalogHint("The built-in catalog is already in use and the field is "
                                    + "empty, so \"Use Built-In\" has nothing to undo and is "
                                    + "off. Type an index URL and it turns on - either to "
                                    + "clear what you typed, or to come back here after "
                                    + "\"Use This Catalog\".")
                    }

                    if let error = catalogIndexError {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }

                    HStack {
                        // Deliberately NOT disabled when the field matches the
                        // URL already in use. It used to be, and that single
                        // clause is why both buttons in this section were grey
                        // the instant Settings opened, before a key was pressed:
                        // an empty field equals an empty setting on every fresh
                        // install. Pressing it on an unchanged URL now means
                        // "read that index again", which is the right thing to
                        // offer somebody who has just re-published a
                        // romwbw_disks release under the same URL with different
                        // bytes - the case this field exists for. See the guard
                        // in `applyCatalogIndexURL`, which had to learn to
                        // re-fetch rather than return early, or enabling this
                        // would have traded a visibly dead button for an
                        // invisibly dead one.
                        // Bordered for the reason ProfileSection's Save button
                        // is: this row sits directly under a text field, and a
                        // borderless button that dims to grey text is
                        // indistinguishable from the field's grey placeholder
                        // above it. A capsule that dims still reads as a button.
                        Button("Use This Catalog") {
                            catalogIndexError = viewModel.applyCatalogIndexURL(catalogIndexDraft)
                        }
                        .buttonStyle(.bordered)
                        // `catalogLoading` too, and the hint above says so.
                        // `fetchDiskCatalog()` has no in-flight guard, so
                        // pressing this during the launch fetch would put a
                        // second index hop in the air beside the first and let
                        // whichever answered last overwrite the other - and
                        // before this button was enabled on a fresh install
                        // there was no way to reach that from the UI at all.
                        .disabled(viewModel.isRunning
                                  || viewModel.catalogIndexURLIsFromEnvironment
                                  || viewModel.catalogLoading)
                        Spacer()
                        // This one stays conditional, and the hint above now
                        // says why: with the built-in catalog in use there is
                        // nothing for it to switch back to, and two buttons
                        // doing the same thing is a worse screen than one button
                        // and one sentence.
                        Button("Use Built-In") {
                            catalogIndexDraft = ""
                            catalogIndexError = viewModel.applyCatalogIndexURL("")
                        }
                        .buttonStyle(.bordered)
                        // Off ONLY when there is genuinely nothing to undo:
                        // already on the built-in catalog AND nothing typed in
                        // the field.
                        //
                        // `!usingCustomCatalogIndex` alone was wrong, and wrong
                        // in the state where this button is most wanted. Type a
                        // URL and do not press Use This Catalog: the catalog in
                        // use is still the built-in one, so that clause held and
                        // greyed the button - yet its action is exactly "clear
                        // the field and go back", which is the one way out of a
                        // half-typed URL short of selecting the text and
                        // deleting it by hand.
                        .disabled(viewModel.isRunning
                                  || viewModel.catalogIndexURLIsFromEnvironment
                                  || viewModel.catalogLoading
                                  || useBuiltInHasNothingToDo)
                    }

                    // The URL actually in use, whatever its source. Worth
                    // showing even when it is the built-in one: a bug report
                    // that names the catalog is worth more than one that does
                    // not, and this is the only place it appears.
                    Text("In use: \(viewModel.effectiveCatalogIndexURL)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)

                    Text("Each catalog keeps its own downloads and its own slot, ROM and "
                         + "boot-string settings, so switching costs a fetch and never "
                         + "your library. Switching back finds it as you left it.")
                        .font(.caption2)
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
                    } else if let failure = viewModel.catalogFailure, !failure.servedFromCache {
                        // Nothing to show: say which of the two fetches failed.
                        // "Could not fetch the release list" and "the list
                        // loaded, 3.5.1's catalog did not" are different
                        // problems with different fixes, and the old single
                        // string could say neither.
                        HStack(alignment: .top) {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundColor(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(failure.summary)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                if !failure.detail.isEmpty {
                                    Text(failure.detail)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        Button("Retry") {
                            viewModel.fetchDiskCatalog()
                        }
                    } else {
                        // A cached document IS on screen, so this is a note and
                        // not a failure: the disks below all work, and what the
                        // user cannot see is whether the list behind them has
                        // moved.
                        if let failure = viewModel.catalogFailure, failure.servedFromCache {
                            Text(failure.summary)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }

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
            // Seeded on appear rather than initialised once: Settings is a
            // sheet, so this struct is rebuilt each time it opens, and the
            // stored value may have been changed by a profile or by another
            // sheet in between. Empty means "the built-in one", which is what
            // the placeholder says.
            .onAppear {
                // The stored setting, which is EMPTY for the built-in catalog -
                // see `catalogIndexURLText`, which is empty on purpose so that a
                // default moving in a later build reaches this install.
                //
                // The exception is a launch under ROMWBW_INDEX_URL. Then the
                // stored setting is not what is in force, and showing it left
                // the field reading "Built-in catalog" while "In use:" named the
                // env URL - two answers to one question, with the misleading one
                // in the more prominent place. Seen on screen on 2026-09-11.
                // Safe to show the resolved URL only here: in this state the
                // field and both buttons are disabled, so there is nothing that
                // could store it back and freeze this install onto it.
                catalogIndexDraft = viewModel.catalogIndexURLIsFromEnvironment
                    ? viewModel.effectiveCatalogIndexURL
                    : viewModel.catalogIndexURLText
                catalogIndexError = nil
            }
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
            .alert("ROM Not Available", isPresented: $viewModel.showingROMProblem) {
                // The same alert the terminal screen carries, for the same
                // reason showingError is on both: whichever view is on top has
                // to be the one that can present it.
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.romProblemMessage)
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


// MARK: - The ROM

/// Which ROM boots, where its bytes come from, and how to get them.
///
/// The rows are the selected release's `roms[]` rather than one bundled file:
/// the ROM has to match the release the disks come from, and which of the two
/// published ROMs to use is a choice. The line under the picker says where the
/// bytes actually are - not fetched yet, or downloaded and re-checked on every
/// use - because pressing Play on a ROM that is not here yet starts a download
/// before it starts a machine, and that is worth knowing in advance rather than
/// discovering as a pause.
struct ROMSection: View {
    @ObservedObject var viewModel: EmulatorViewModel

    var body: some View {
        Section(header: Text("ROM Image")) {
            // A row, or a sentence - never an empty menu. `availableROMs` is
            // built from the selected release's `roms[]`, so it is `[]` until a
            // catalog has been fetched, and a `Picker` with no rows and a nil
            // selection draws its title with a blank value and opens on nothing.
            // The two other pickers in this Form were both given a floor for
            // exactly this reason: `availableDisks` starts at one "None" row and
            // `romwbwVersions` is seeded with a placeholder. This app used to
            // have a third floor here without meaning to - the bundled ROM was
            // the fallback row - and removing the ROM removed it.
            //
            // A sentence rather than a disabled placeholder row, because the two
            // states are not the same: an empty list means the catalog has not
            // arrived, which is a thing to wait for or to fix, not a ROM to pick.
            if viewModel.availableROMs.isEmpty {
                Text("No ROM yet - the RomWBW \(viewModel.romwbwVersion) catalog "
                     + "has not been read. Every ROM is downloaded, so this needs "
                     + "a connection.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Picker("ROM", selection: $viewModel.selectedROM) {
                    ForEach(viewModel.availableROMs) { rom in
                        Text(rom.name).tag(rom as ROMOption?)
                    }
                }
                .pickerStyle(.menu)
            }

            Text(viewModel.romStatusDescription)
                .font(.caption)
                .foregroundColor(.secondary)

            if let progress = viewModel.romDownloadProgress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
            } else if viewModel.romNeedsDownload {
                // Offered rather than required: pressing Play fetches it too.
                // This is for the person who would rather not discover they
                // have no signal at the moment they want to boot.
                Button {
                    viewModel.downloadSelectedROM()
                } label: {
                    Label("Download ROM", systemImage: "arrow.down.circle")
                }
                .font(.caption)
            }
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

    /// The name the last save actually used, which is not always the name that
    /// was typed.
    @State private var lastSavedName: String?

    /// What the line under the field says: why Save is off, or what pressing it
    /// will actually produce.
    ///
    /// The second half earns its place as much as the first. `saveCurrentProfile`
    /// does not refuse a name already taken - it saves "Games 2" and returns the
    /// name it used - and the caller here threw that return value away, so
    /// typing a name that existed produced a profile under a different name with
    /// nothing on screen saying so. Saying it before the tap is cheaper than
    /// explaining it afterwards, and it points at the gesture that does
    /// overwrite.
    ///
    /// Safe to compute on every keystroke: `uniqueName(basedOn:)` only reads
    /// `profiles`. Tests/EmulatorProfileTests.swift asserts that it saves
    /// nothing, because a future "reserve this name" variant called from a view
    /// body would append a profile per character typed.
    private var saveHint: String {
        guard !trimmedName.isEmpty else {
            return "Type a name to save the current ROM, disks, boot string, "
                + "terminal settings and key map as a profile."
        }
        let clean = EmulatorProfile.sanitized(name: trimmedName)
        let actual = viewModel.profileStore.uniqueName(basedOn: trimmedName)
        if actual != clean {
            // NOT "load it and use Update". Update overwrites a profile with
            // the machine as it stands, but loading one first REPLACES the
            // machine as it stands - `applyProfile` reassigns the ROM, all four
            // slots, the boot string, the key map and the terminal settings -
            // so following that advice destroys the very setup the user is
            // trying to save. Deleting the old one leaves the current machine
            // untouched, and the next save then takes the name back.
            return "\"\(clean)\" is already a profile. This saves as \"\(actual)\" - "
                + "to reuse the name instead, swipe the old one away in the list above "
                + "first."
        }
        if clean != trimmedName {
            return "Saves as \"\(clean)\" - a name is cut to "
                + "\(EmulatorProfile.maxNameLength) characters so it fits the list."
        }
        return "Saves as \"\(clean)\"."
    }

    private func saveNamedProfile() {
        lastSavedName = viewModel.saveCurrentProfile(named: trimmedName)
        newProfileName = ""
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

            // The field and the button that makes a profile.
            //
            // Three things here exist because the field and the button were
            // reported together as "disabled with no reason given", and only one
            // of them was ever disabled. The field never was. A bare TextField
            // in a Form row draws no border, so all it puts on screen is grey
            // placeholder text beside a button that is grey every time Settings
            // opens - `newProfileName` is a fresh `@State ""` and this sheet is
            // rebuilt on each presentation - and grey beside grey reads as "not
            // for you" rather than "type here".
            //
            // `.buttonStyle(.borderless)` is the disk row's fix for the disk
            // row's reason: inside a Form row the automatic style takes the
            // whole row as its tap target, so a tap aimed at the field could be
            // routed to the disabled button and do nothing, silently - which is
            // indistinguishable from the field being dead.
            //
            // And the button now says why it is off. It is off for the most
            // trivial reason a control can be off, which is exactly the kind a
            // user cannot guess, because they are looking for a hard one.
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    TextField("New profile name", text: $newProfileName)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled(true)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        // Return saves too, but only through the same emptiness
                        // test the button uses: the keyboard does not consult a
                        // button's disabled state, and without this Return on an
                        // empty field saves "Untitled", then "Untitled 2",
                        // because sanitized(name:) refuses to produce a blank
                        // name and uniqueName refuses to reuse one.
                        .onSubmit { if !trimmedName.isEmpty { saveNamedProfile() } }

                    // `.bordered`, not `.borderless`, and the reason is the
                    // whole point of this row: placeholder text and a disabled
                    // button label were BOTH grey text with no container, so
                    // "New profile name" and "Save Current" looked like the
                    // same kind of thing. They are not - one is a prompt inside
                    // a field you can type in, the other is a control that is
                    // unavailable - and an element's KIND and an element's
                    // STATE must not be carried by the same visual property.
                    // Grey was carrying both.
                    //
                    // Containers settle it on each side. The field's border
                    // says "text in a box is a field", and a bordered button
                    // keeps its capsule when it dims, which is what makes a
                    // disabled control read as a faded button rather than as
                    // more prose. It also keeps the hit-target fix `.borderless`
                    // was added for: in a Form row the automatic style takes the
                    // whole row, and both of these styles scope the tap to the
                    // button, so a tap aimed at the field reaches the field.
                    Button("Save Current") { saveNamedProfile() }
                        .buttonStyle(.bordered)
                        .disabled(trimmedName.isEmpty)
                }

                Text(saveHint)
                    .font(.caption)
                    .foregroundColor(.secondary)

                // Said here rather than only in `statusText`: the status line
                // lives on the terminal screen, behind this full-screen cover,
                // so a user who saves and keeps working in Settings would
                // otherwise see no confirmation at all.
                //
                // Gated on the profile still EXISTING, not merely on having
                // saved one. The list it confirms is directly above this line
                // and is swipe-deletable, so "Saved "Games"." would otherwise go
                // on asserting a profile that the user had just removed while
                // looking at it.
                if let saved = lastSavedName, viewModel.profileStore.names.contains(saved) {
                    Text("Saved \"\(saved)\".")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
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
