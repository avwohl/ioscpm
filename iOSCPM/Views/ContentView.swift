/*
 * ContentView.swift - Main view for RomWBW emulator
 */

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var viewModel = EmulatorViewModel()
    @AppStorage("terminalFontSize") private var fontSize: Double = 20

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
                    Menu {
                        // OS Images
                        Button("Load OS to Slot 0...") {
                            viewModel.loadDisk(0)
                        }
                        Button("Load OS to Slot 1...") {
                            viewModel.loadDisk(1)
                        }
                        Button("Load OS to Slot 2...") {
                            viewModel.loadDisk(2)
                        }

                        Divider()

                        // Data Disks
                        Button("Load Drive A (Slot 3)...") {
                            viewModel.loadDisk(3)
                        }
                        Button("Load Drive B (Slot 4)...") {
                            viewModel.loadDisk(4)
                        }
                        Button("Load Drive C (Slot 5)...") {
                            viewModel.loadDisk(5)
                        }
                        Button("Load Drive D (Slot 6)...") {
                            viewModel.loadDisk(6)
                        }

                        Divider()

                        // Save Disks
                        Button("Save Drive A (Slot 3)...") {
                            viewModel.saveDisk(3)
                        }
                        Button("Save Drive B (Slot 4)...") {
                            viewModel.saveDisk(4)
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

#Preview {
    ContentView()
}
