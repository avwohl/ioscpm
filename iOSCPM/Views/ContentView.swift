/*
 * ContentView.swift - Main view for CP/M emulator
 */

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var viewModel = EmulatorViewModel()

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Terminal display
                TerminalView(text: $viewModel.terminalText) { char in
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
            .navigationTitle("CP/M")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Menu {
                        Button("Load Disk A...") {
                            viewModel.showingDiskAPicker = true
                        }
                        Button("Load Disk B...") {
                            viewModel.showingDiskBPicker = true
                        }
                        Divider()
                        Button("Save Disk A...") {
                            viewModel.saveDiskA()
                        }
                        Button("Save Disk B...") {
                            viewModel.saveDiskB()
                        }
                        Divider()
                        Button("Create Empty Disk A") {
                            viewModel.createEmptyDiskA()
                        }
                        Button("Create Empty Disk B") {
                            viewModel.createEmptyDiskB()
                        }
                    } label: {
                        Label("Disks", systemImage: "opticaldiscdrive")
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
                isPresented: $viewModel.showingDiskAPicker,
                allowedContentTypes: [.data, .item],
                allowsMultipleSelection: false
            ) { result in
                viewModel.handleDiskAImport(result)
            }
            .fileImporter(
                isPresented: $viewModel.showingDiskBPicker,
                allowedContentTypes: [.data, .item],
                allowsMultipleSelection: false
            ) { result in
                viewModel.handleDiskBImport(result)
            }
            .fileExporter(
                isPresented: $viewModel.showingDiskAExporter,
                document: viewModel.exportDocument,
                contentType: .data,
                defaultFilename: "diskA.img"
            ) { result in
                viewModel.handleExportResult(result)
            }
            .fileExporter(
                isPresented: $viewModel.showingDiskBExporter,
                document: viewModel.exportDocument,
                contentType: .data,
                defaultFilename: "diskB.img"
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
