import SwiftUI

// MARK: - Help Index Model

struct HelpIndex: Codable {
    let version: Int
    let base_url: String
    let topics: [HelpTopic]
}

struct HelpTopic: Codable, Identifiable {
    let id: String
    let title: String
    let description: String
    let filename: String
}

// MARK: - Help View

struct HelpView: View {
    @StateObject private var viewModel = HelpViewModel()
    @State private var selectedTopic: HelpTopic?
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        NavigationView {
            Group {
                switch viewModel.indexState {
                case .loading:
                    ProgressView("Loading help topics...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                case .loaded(let index):
                    List(index.topics) { topic in
                        Button(action: {
                            selectedTopic = topic
                        }) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(topic.title)
                                    .font(.headline)
                                    .foregroundColor(.primary)
                                Text(topic.description)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .listStyle(.insetGrouped)

                case .error(let message):
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundColor(.orange)
                        Text("Failed to load help")
                            .font(.headline)
                        Text(message)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Retry") {
                            viewModel.fetchIndex()
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Help")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
            .sheet(item: $selectedTopic) { topic in
                HelpTopicView(viewModel: viewModel, topic: topic)
            }
        }
        .onAppear {
            if case .loading = viewModel.indexState {
                viewModel.fetchIndex()
            }
        }
    }
}

// MARK: - Help Topic View

struct HelpTopicView: View {
    @ObservedObject var viewModel: HelpViewModel
    let topic: HelpTopic
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        NavigationView {
            Group {
                switch viewModel.contentState(for: topic.id) {
                case .loading:
                    ProgressView("Loading...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                case .loaded(let content):
                    ScrollView {
                        MarkdownView(content: content)
                            .padding()
                    }

                case .error(let message):
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundColor(.orange)
                        Text("Failed to load content")
                            .font(.headline)
                        Text(message)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Button("Retry") {
                            viewModel.fetchContent(for: topic)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(topic.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
        .onAppear {
            viewModel.fetchContent(for: topic)
        }
    }
}

// MARK: - Simple Markdown View

struct MarkdownView: View {
    let content: String

    var body: some View {
        if #available(iOS 15.0, macOS 12.0, *) {
            Text(attributedContent)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(content)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @available(iOS 15.0, macOS 12.0, *)
    private var attributedContent: AttributedString {
        do {
            return try AttributedString(markdown: content, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        } catch {
            return AttributedString(content)
        }
    }
}

// MARK: - Help View Model

class HelpViewModel: ObservableObject {
    enum LoadState<T> {
        case loading
        case loaded(T)
        case error(String)
    }

    @Published var indexState: LoadState<HelpIndex> = .loading
    @Published private var contentCache: [String: LoadState<String>] = [:]

    private static let indexURL = "https://github.com/avwohl/ioscpm/releases/latest/download/help_index.json"
    private var baseURL: String = "https://github.com/avwohl/ioscpm/releases/latest/download/"

    // Local cache directory
    private var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("help", isDirectory: true)
    }

    init() {
        // Create cache directory if needed
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    func contentState(for topicId: String) -> LoadState<String> {
        return contentCache[topicId] ?? .loading
    }

    func fetchIndex() {
        indexState = .loading

        guard let url = URL(string: Self.indexURL) else {
            indexState = .error("Invalid URL")
            return
        }

        // Try cached index first
        let cachedIndexURL = cacheDirectory.appendingPathComponent("help_index.json")

        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    // Try cache on network error
                    if let cachedData = try? Data(contentsOf: cachedIndexURL),
                       let index = try? JSONDecoder().decode(HelpIndex.self, from: cachedData) {
                        self?.baseURL = index.base_url
                        self?.indexState = .loaded(index)
                    } else {
                        self?.indexState = .error(error.localizedDescription)
                    }
                    return
                }

                guard let data = data else {
                    self?.indexState = .error("No data received")
                    return
                }

                do {
                    let index = try JSONDecoder().decode(HelpIndex.self, from: data)
                    self?.baseURL = index.base_url
                    self?.indexState = .loaded(index)

                    // Cache the index
                    try? data.write(to: cachedIndexURL)
                } catch {
                    self?.indexState = .error("Failed to parse index: \(error.localizedDescription)")
                }
            }
        }.resume()
    }

    func fetchContent(for topic: HelpTopic) {
        // Check if already loaded
        if case .loaded = contentCache[topic.id] {
            return
        }

        contentCache[topic.id] = .loading

        let urlString = baseURL + topic.filename
        guard let url = URL(string: urlString) else {
            contentCache[topic.id] = .error("Invalid URL")
            return
        }

        let cachedFileURL = cacheDirectory.appendingPathComponent(topic.filename)

        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    // Try cache on network error
                    if let cachedContent = try? String(contentsOf: cachedFileURL, encoding: .utf8) {
                        self?.contentCache[topic.id] = .loaded(cachedContent)
                    } else {
                        self?.contentCache[topic.id] = .error(error.localizedDescription)
                    }
                    return
                }

                guard let data = data, let content = String(data: data, encoding: .utf8) else {
                    self?.contentCache[topic.id] = .error("Failed to decode content")
                    return
                }

                self?.contentCache[topic.id] = .loaded(content)

                // Cache the content
                try? content.write(to: cachedFileURL, atomically: true, encoding: .utf8)
            }
        }.resume()
    }
}

// MARK: - Preview

struct HelpView_Previews: PreviewProvider {
    static var previews: some View {
        HelpView()
    }
}
