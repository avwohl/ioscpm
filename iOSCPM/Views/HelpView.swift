import CryptoKit
import SwiftUI

// MARK: - Help Index Model
//
// The shape this view works in, and the shape the offline tiers are stored in.
// It is NOT the shape published any more: the topics are a `help` block inside
// the catalog index now (`CatalogHelp` in CatalogDocument.swift), and
// `HelpIndex.from(_:)` below converts one into the other.
//
// Kept, rather than replaced by CatalogHelp, because it is also the document on
// disk. Every install that ran build 69 or earlier has a legacy help_index.json
// in its cache, the app bundles one, and both decode straight into this. A view
// model rewritten around CatalogHelp would have had to carry a second decoder
// for those anyway.

struct HelpIndex: Codable {
    let version: Int
    let base_url: String
    let topics: [HelpTopic]

    /// The index's `help` block as a list this view can show, or nil when the
    /// index carries none - which is an index published before the block
    /// existed, and the case the bundled copy is for.
    static func from(_ help: CatalogHelp?) -> HelpIndex? {
        guard let help = help, help.ok, let base = help.baseURL else { return nil }
        let topics = help.topics.filter { $0.usable }.map { topic in
            HelpTopic(id: topic.id,
                      // `name` in the catalog, `title` here. The id is the last
                      // resort so a row is never blank.
                      title: topic.name.flatMap { $0.isEmpty ? nil : $0 } ?? topic.id,
                      description: topic.topicDescription ?? "",
                      filename: topic.filename ?? "",
                      size: topic.size,
                      sha256: topic.sha256)
        }
        return topics.isEmpty ? nil : HelpIndex(version: 1, base_url: base, topics: topics)
    }
}

struct HelpTopic: Codable, Identifiable {
    let id: String
    let title: String
    let description: String
    let filename: String
    /// What the catalog says this topic's bytes are. Optional because the
    /// legacy document carries neither, and absent means the check is skipped
    /// rather than failed - the same degradation a catalog document gets when
    /// the index publishes no hash for it.
    let size: Int64?
    let sha256: String?

    enum CodingKeys: String, CodingKey {
        case id, title, description, filename, size, sha256
    }

    init(id: String, title: String, description: String, filename: String,
         size: Int64? = nil, sha256: String? = nil) {
        self.id = id
        self.title = title
        self.description = description
        self.filename = filename
        self.size = size
        self.sha256 = sha256
    }

    /// Nil when `data` is what the index said this topic is, and the reason
    /// when it is not.
    ///
    /// **Absent means unchecked here, which is deliberately NOT the rule
    /// `RomWBWIndexEntry.payloadProblem` applies to a catalog document.** That
    /// one refuses an entry carrying no `catalog_sha256`, because it is the gate
    /// in front of a 512 KB ROM and 49 MB of disk images and a gate that cannot
    /// verify must not say yes. A help topic is a few kilobytes of text that is
    /// rendered and never executed, the legacy document carries no hashes at
    /// all, and refusing on that basis would leave a reader pointed at an older
    /// index with no topics rather than unverified ones. So this checks what is
    /// published and skips what is not.
    func problem(with data: Data) -> String? {
        if let size = size, size > 0, Int64(data.count) != size {
            return "got \(data.count) bytes, the catalog says \(size)"
        }
        if let sha256 = sha256, !sha256.isEmpty {
            let measured = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            if measured.caseInsensitiveCompare(sha256) != .orderedSame {
                return "sha256 \(measured), the catalog says \(sha256)"
            }
        }
        return nil
    }
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

    /// The catalog index, which is where the help topics are published.
    ///
    /// **No help URL is compiled into this app any more.** This was
    /// `avwohl/ioscpm/releases/latest/download/help_index.json` - a second
    /// index, in this app's own release area, in a shape of its own, for the
    /// one subsystem that had no reason to be special. It meant a typo fix in a
    /// help topic needed an App Store release, and it kept whichever ioscpm
    /// release carried the Latest flag load-bearing for as long as any install
    /// existed. That was the last thing here still working that way; the ROM,
    /// the disks and their catalogs stopped in build 63.
    ///
    /// It is `CatalogMigration.indexURL`, so `ROMWBW_INDEX_URL` and the catalog
    /// index setting move help with them: a device pointed at a test catalog
    /// reads that catalog's help, and a fork gets its own for free.
    private static var indexURL: String { CatalogMigration.indexURL }

    /// Where the topics are, out of the document rather than compiled in.
    /// Empty until an index has been read; every fetch goes through a topic
    /// whose base came from the same document that named it.
    private var baseURL: String = ""

    /// Local cache directory, per catalog.
    ///
    /// `indexScope` is EMPTY for the default index, so this is the same path it
    /// has always been unless somebody pointed the app somewhere else - and
    /// then it is a directory of its own, because two catalogs publish
    /// different bytes under the same topic filenames.
    private var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("help" + CatalogMigration.indexScope, isDirectory: true)
    }

    init() {
        // Create cache directory if needed
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Bundled fallback
    //
    // The list and the topics are fetched, which is deliberate - a correction
    // can reach a reader without an app update. What that costs is a dependency
    // on somebody else's release carrying the assets, and on the user having a
    // network. Neither is guaranteed, and the failure is silent: a missing topic
    // looks exactly like being offline.
    //
    // cpmdroid shipped precisely this arrangement with no bundled copy, the
    // assets stopped being attached after v1.11, and every build from then on
    // had no help at all with nothing failing anywhere to say so (z80cpmw's
    // FEATURE_PARITY.md item 6 writes it up). The cache is not a defence: it only
    // helps someone who already loaded help successfully once.
    //
    // What the assets are attached to has moved - romwbw_disks' help-v0 tag,
    // named by the index rather than compiled in here - but the hazard has not,
    // and it got a second demonstration on 2026-09-10: help-v0 was cut with the
    // Latest flag, which took `releases/latest/download/index-v0.json` to 404 for
    // every client until the flag was moved back. Every tier below matters for
    // exactly the length of a mistake like that one.
    //
    // So the bundle sits behind the cache as the last resort. Download first,
    // cache second, shipped copy third - never the shipped copy first, or
    // corrections would stop reaching anyone.

    private func bundledIndex() -> HelpIndex? {
        guard let url = Bundle.main.url(forResource: "help_index", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let index = Self.parse(data) else {
            return nil
        }
        return index
    }

    private func bundledContent(_ filename: String) -> String? {
        // Topic filenames carry their extension ("help_cpm22.md"); Bundle wants
        // the two halves separately.
        let name = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        guard !name.isEmpty,
              let url = Bundle.main.url(forResource: name,
                                        withExtension: ext.isEmpty ? nil : ext),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        return text
    }

    /// Cached index if there is one, else the shipped one.
    ///
    /// Both go through `parse`, the same function the download does, so all
    /// three tiers read a document the same way and neither offline copy can
    /// grow a private shape that nothing exercises. It also means a cache
    /// written by an older build - the standalone help_index.json this app
    /// fetched through build 69 - is still readable by this one.
    private func offlineIndex(_ cachedURL: URL) -> HelpIndex? {
        if let data = try? Data(contentsOf: cachedURL),
           let index = Self.parse(data) {
            return index
        }
        return bundledIndex()
    }

    /// Cached topic if there is one, else the shipped one.
    private func offlineContent(_ cachedURL: URL, _ filename: String) -> String? {
        if let text = try? String(contentsOf: cachedURL, encoding: .utf8) {
            return text
        }
        return bundledContent(filename)
    }

    /// One parser for what arrives: the catalog index's `help` block, else the
    /// standalone document this app used to publish.
    ///
    /// Both shapes, because three tiers read this and they do not all hold the
    /// same document. The live one is index-v0.json. The other is the
    /// help_index.json this app fetched through build 69, which is what every
    /// install of one of those has sitting in its cache and what the bundle
    /// carries - refusing it would take help away from precisely the reader the
    /// offline tiers exist for.
    private static func parse(_ data: Data) -> HelpIndex? {
        let decoder = JSONDecoder()
        if let catalog = try? decoder.decode(RomWBWIndex.self, from: data),
           let index = HelpIndex.from(catalog.help) {
            return index
        }
        return try? decoder.decode(HelpIndex.self, from: data)
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
                    // Cache, then the shipped copy, then give up.
                    if let index = self?.offlineIndex(cachedIndexURL) {
                        self?.baseURL = index.base_url
                        self?.indexState = .loaded(index)
                    } else {
                        self?.indexState = .error("Network error: \(error.localizedDescription)")
                    }
                    return
                }

                // Check HTTP status code
                if let httpResponse = response as? HTTPURLResponse,
                   httpResponse.statusCode != 200 {
                    // A 404 here is the "assets not attached to the newest
                    // release" case, which is why the bundle has to be reachable
                    // from this arm and not only from the network-error one.
                    if let index = self?.offlineIndex(cachedIndexURL) {
                        self?.baseURL = index.base_url
                        self?.indexState = .loaded(index)
                    } else {
                        self?.indexState = .error("Server returned status \(httpResponse.statusCode)")
                    }
                    return
                }

                guard let data = data, !data.isEmpty else {
                    if let index = self?.offlineIndex(cachedIndexURL) {
                        self?.baseURL = index.base_url
                        self?.indexState = .loaded(index)
                    } else {
                        self?.indexState = .error("No data received from server")
                    }
                    return
                }

                if let index = Self.parse(data) {
                    self?.baseURL = index.base_url
                    self?.indexState = .loaded(index)

                    // Cached in THIS app's shape rather than as the bytes that
                    // arrived. What arrives is index-v0.json, which carries the
                    // whole release list and which `offlineIndex` cannot read;
                    // writing it verbatim would leave a cache that only ever
                    // falls through to the bundle. Re-encoding also means the
                    // cached document keeps the size and sha256 of each topic,
                    // so a reader who is offline next time still verifies what
                    // it downloads when the network comes back.
                    if let encoded = try? JSONEncoder().encode(index) {
                        try? encoded.write(to: cachedIndexURL)
                    }
                } else if let index = self?.offlineIndex(cachedIndexURL) {
                    // A body that is not an index reaches here, and it used to
                    // stop here: the parse failure reported itself and the
                    // offline tiers were never consulted, although this same
                    // function reaches them from all three arms above. A
                    // truncated response and a 404 are the same thing to a
                    // reader, and they should get the same answer.
                    self?.baseURL = index.base_url
                    self?.indexState = .loaded(index)
                } else {
                    // Show beginning of response for debugging
                    let preview = String(data: data.prefix(100), encoding: .utf8) ?? "(binary)"
                    self?.indexState = .error("Could not read the catalog index, and no offline copy\nResponse: \(preview)...")
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
                    if let text = self?.offlineContent(cachedFileURL, topic.filename) {
                        self?.contentCache[topic.id] = .loaded(text)
                    } else {
                        self?.contentCache[topic.id] = .error("Network: \(error.localizedDescription)")
                    }
                    return
                }

                // Check HTTP status code
                if let httpResponse = response as? HTTPURLResponse,
                   httpResponse.statusCode != 200 {
                    if let text = self?.offlineContent(cachedFileURL, topic.filename) {
                        self?.contentCache[topic.id] = .loaded(text)
                    } else {
                        self?.contentCache[topic.id] = .error("HTTP \(httpResponse.statusCode)")
                    }
                    return
                }

                guard let data = data, !data.isEmpty,
                      let content = String(data: data, encoding: .utf8) else {
                    if let text = self?.offlineContent(cachedFileURL, topic.filename) {
                        self?.contentCache[topic.id] = .loaded(text)
                    } else {
                        self?.contentCache[topic.id] = .error("Failed to decode content")
                    }
                    return
                }

                // Checked before it is shown or cached. Help was the last
                // content this family published that nothing verified; the
                // index gives a size and a sha256 per topic now, exactly as it
                // does for a ROM or a disk. A response that is whole and is not
                // this topic - a moved tag, a rewritten asset - would otherwise
                // be written over the copy the reader already had, and then
                // shown as though it were the current one.
                if let problem = topic.problem(with: data) {
                    if let text = self?.offlineContent(cachedFileURL, topic.filename) {
                        self?.contentCache[topic.id] = .loaded(text)
                    } else {
                        self?.contentCache[topic.id] = .error("Not the published topic: \(problem)")
                    }
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
