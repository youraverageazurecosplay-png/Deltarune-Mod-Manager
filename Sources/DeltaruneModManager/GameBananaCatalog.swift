import AppKit
import Combine
import Foundation
import SwiftUI

struct GameBananaMod: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    let profileURL: URL
    let hasFiles: Bool
    let imageURL: URL?
    let imageURLs: [URL]
    let author: String?
    let category: String?
    let downloadCount: Int?
    let viewCount: Int?
    let dateAdded: Int64?

    enum CodingKeys: String, CodingKey {
        case id = "_idRow"
        case name = "_sName"
        case profileURL = "_sProfileUrl"
        case hasFiles = "_bHasFiles"
        case previewMedia = "_aPreviewMedia"
        case submitter = "_aSubmitter"
        case category = "_aRootCategory"
        case downloadCount = "_nDownloadCount"
        case viewCount = "_nViewCount"
        case dateAdded = "_tsDateAdded"
    }

    enum SubmitterKeys: String, CodingKey {
        case name = "_sName"
    }

    enum CategoryKeys: String, CodingKey {
        case name = "_sName"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        profileURL = try container.decode(URL.self, forKey: .profileURL)
        hasFiles = try container.decodeIfPresent(Bool.self, forKey: .hasFiles) ?? false
        downloadCount = try container.decodeIfPresent(Int.self, forKey: .downloadCount)
        viewCount = try container.decodeIfPresent(Int.self, forKey: .viewCount)
        dateAdded = try container.decodeIfPresent(Int64.self, forKey: .dateAdded)

        if container.contains(.submitter), (try? container.decodeNil(forKey: .submitter)) != true {
            let submitter = try container.nestedContainer(keyedBy: SubmitterKeys.self, forKey: .submitter)
            author = try submitter.decodeIfPresent(String.self, forKey: .name)
        } else {
            author = nil
        }
        if container.contains(.category), (try? container.decodeNil(forKey: .category)) != true {
            let category = try container.nestedContainer(keyedBy: CategoryKeys.self, forKey: .category)
            self.category = try category.decodeIfPresent(String.self, forKey: .name)
        } else {
            self.category = nil
        }

        let media = try container.decodeIfPresent(GameBananaMedia.self, forKey: .previewMedia)
        imageURLs = media?.imageURLs ?? []
        imageURL = imageURLs.first
    }
}

enum GameBananaSort: String, CaseIterable, Identifiable {
    case relevance
    case popularity
    case newest
    case recentlyUpdated

    var id: String { rawValue }

    var title: String {
        switch self {
        case .relevance: "Most relevant"
        case .popularity: "Popularity"
        case .newest: "Newest"
        case .recentlyUpdated: "Recently updated"
        }
    }

    var apiValue: String {
        switch self {
        case .relevance: "best_match"
        case .popularity: "popularity"
        case .newest: "date"
        case .recentlyUpdated: "udate"
        }
    }
}

private struct GameBananaMedia: Decodable {
    let images: [GameBananaImage]
    var imageURLs: [URL] { images.flatMap(\.urls) }

    enum CodingKeys: String, CodingKey {
        case images = "_aImages"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        images = try container.decodeIfPresent([GameBananaImage].self, forKey: .images) ?? []
    }
}

private struct GameBananaImage: Decodable {
    let urls: [URL]

    enum CodingKeys: String, CodingKey {
        case directURL = "_sUrl"
        case baseURL = "_sBaseUrl"
        case file530 = "_sFile530"
        case file220 = "_sFile220"
        case file = "_sFile"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let directURL = try container.decodeIfPresent(URL.self, forKey: .directURL)
        let base = try container.decodeIfPresent(String.self, forKey: .baseURL)
        if let directURL {
            urls = [directURL]
        } else if let base {
            let filenames = [
                try container.decodeIfPresent(String.self, forKey: .file530),
                try container.decodeIfPresent(String.self, forKey: .file),
                try container.decodeIfPresent(String.self, forKey: .file220)
            ].compactMap { $0 }
            urls = filenames.compactMap { URL(string: "\(base)/\($0)") }
        } else {
            urls = []
        }
    }
}

struct GameBananaItemDetails: Decodable {
    let name: String
    let profileURL: URL
    let description: String
    let files: [GameBananaFile]
    let imageURL: URL?
    let imageURLs: [URL]

    enum CodingKeys: String, CodingKey {
        case name = "_sName"
        case profileURL = "_sProfileUrl"
        case description = "_sDescription"
        case files = "_aFiles"
        case previewMedia = "_aPreviewMedia"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        profileURL = try container.decode(URL.self, forKey: .profileURL)
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        files = try container.decodeIfPresent([GameBananaFile].self, forKey: .files) ?? []
        let media = try container.decodeIfPresent(GameBananaMedia.self, forKey: .previewMedia)
        imageURLs = media?.imageURLs ?? []
        imageURL = imageURLs.first
    }
}

struct GameBananaFile: Decodable, Identifiable {
    let id: Int
    let name: String
    let size: Int64
    let downloadURL: URL
    let isArchived: Bool
    let version: String?
    let description: String?
    let dateAdded: Int64?

    enum CodingKeys: String, CodingKey {
        case id = "_idRow"
        case name = "_sFile"
        case size = "_nFilesize"
        case downloadURL = "_sDownloadUrl"
        case isArchived = "_bIsArchived"
        case version = "_sVersion"
        case description = "_sDescription"
        case dateAdded = "_tsDateAdded"
    }

    var isDeltamod: Bool {
        name.localizedCaseInsensitiveContains("deltamod")
    }

    var isManualPatchDownload: Bool {
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        return ext == "zip" || ext == "rar" || ext == "xdelta"
    }

    var isSupportedRelease: Bool {
        !isArchived && isSelectableRelease
    }

    var isSelectableRelease: Bool {
        isDeltamod || isManualPatchDownload
    }

    var isActiveDeltamod: Bool {
        isDeltamod && !isArchived
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var releaseTitle: String {
        if let version = version?.trimmingCharacters(in: .whitespacesAndNewlines),
           !version.isEmpty {
            return "Version \(version)"
        }
        if let description = description?.trimmingCharacters(in: .whitespacesAndNewlines),
           !description.isEmpty {
            return description
        }
        return URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
    }
}

enum GameBananaReleasePicker {
    private enum Variant: Equatable {
        case standard
        case nxruneCompatibility
        case advanced
    }

    static func updateCandidate(
        from files: [GameBananaFile],
        for game: ModGame,
        installedFileID: Int,
        installedFileDateAdded: Int64?
    ) -> GameBananaFile? {
        let supported = files.filter(\.isSupportedRelease)
        let deltamods = supported.filter(\.isDeltamod)
        let prefersDeltamod = game == .deltarune && !deltamods.isEmpty
        let candidates: [GameBananaFile]
        if prefersDeltamod {
            candidates = deltamods
        } else {
            let installedVariant = files.first { $0.id == installedFileID }.map(variant(for:)) ?? .standard
            let matchingVariant = supported.filter { variant(for: $0) == installedVariant }
            candidates = matchingVariant.isEmpty
                ? supported.filter { variant(for: $0) != .advanced }
                : matchingVariant
        }
        guard let latest = candidates.max(by: { ($0.dateAdded ?? 0) < ($1.dateAdded ?? 0) }),
              latest.id != installedFileID else {
            return nil
        }

        let installedFile = files.first { $0.id == installedFileID }
        let isFormatMigration = prefersDeltamod
            && latest.isDeltamod
            && installedFile?.isDeltamod != true
        guard isFormatMigration
                || installedFileDateAdded == nil
                || (latest.dateAdded ?? 0) > (installedFileDateAdded ?? 0) else {
            return nil
        }
        return latest
    }

    private static func variant(for file: GameBananaFile) -> Variant {
        let name = file.name.localizedLowercase
        if name.contains("advanced") {
            return .advanced
        }
        if name.contains("nxrune") || name.contains("compat") {
            return .nxruneCompatibility
        }
        return .standard
    }
}

struct GameBananaOneClickLink: Equatable {
    let fileID: Int
    let modID: Int

    static func usesSupportedScheme(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "g3m" || scheme == "deltahub"
    }

    init?(url: URL) {
        guard Self.usesSupportedScheme(url) else { return nil }
        let link = url.absoluteString
        guard let separator = link.range(of: "://") else { return nil }
        var target = String(link[separator.upperBound...])
        target = target
            .replacingOccurrences(of: "https//", with: "https://")
            .replacingOccurrences(of: "http//", with: "http://")
        guard let components = URLComponents(string: target),
              let host = components.host?.lowercased(),
              host == "gamebanana.com" || host == "www.gamebanana.com" else {
            return nil
        }
        let segments = components.path.split(separator: "/")
        guard segments.count == 2,
              segments[0].lowercased() == "mmdl" else {
            return nil
        }
        let parameters = segments[1].split(separator: ",")
        guard parameters.count >= 3,
              parameters[1].lowercased() == "mod",
              let fileID = Int(parameters[0]),
              let modID = Int(parameters[2]),
              fileID > 0, modID > 0 else {
            return nil
        }
        self.fileID = fileID
        self.modID = modID
    }
}

enum GameBananaPagination {
    static let resultsPerPage = 15
    static let initialPageCount = 2
    static let prefetchCount = 15

    static func shouldPrefetch(visibleIndex: Int, loadedCount: Int) -> Bool {
        visibleIndex >= max(0, loadedCount - prefetchCount)
    }

    static func shouldLoadCategoryMore(matchingCount: Int, canLoadMore: Bool) -> Bool {
        canLoadMore && matchingCount < resultsPerPage
    }
}

@MainActor
final class GameBananaCatalog: ObservableObject {
    @Published private(set) var game: ModGame = .deltarune
    @Published private(set) var mods: [GameBananaMod] = []
    @Published private(set) var isLoading = false
    @Published private(set) var canLoadMore = true
    @Published private(set) var errorMessage: String?
    @Published private(set) var onlyCompatibleMods = false
    @Published private(set) var isCheckingCompatibility = false
    @Published private(set) var compatibilityProgress = 0
    @Published private(set) var compatibilityTotal = 0
    @Published private(set) var compatibilityError: String?
    @Published private(set) var compatibleModIDs: Set<Int> = []
    @Published var sortOption: GameBananaSort = .relevance

    private var page = 1
    private var query = ""
    private var requestGeneration = UUID()
    private var compatibilityByModID: [Int: Bool] = [:]

    init() {
        URLCache.shared = URLCache(
            memoryCapacity: 32 * 1024 * 1024,
            diskCapacity: 128 * 1024 * 1024,
            diskPath: "DeltaruneModManager-GameBanana"
        )
    }

    func search(_ newQuery: String) async {
        query = newQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        page = 1
        canLoadMore = true
        mods = []
        compatibilityByModID.removeAll(keepingCapacity: false)
        compatibleModIDs = []
        let generation = UUID()
        requestGeneration = generation
        await fetchPage(page: page, generation: generation)
        for _ in 1..<GameBananaPagination.initialPageCount {
            guard requestGeneration == generation, canLoadMore, errorMessage == nil else { return }
            await loadMore()
        }
    }

    func setGame(_ newGame: ModGame) {
        guard game != newGame else { return }
        game = newGame
        onlyCompatibleMods = false
        compatibilityError = nil
        Task { await search("") }
    }

    func loadMore() async {
        guard !isLoading, canLoadMore else { return }
        page += 1
        await fetchPage(page: page, generation: requestGeneration)
    }

    func setOnlyCompatibleMods(_ enabled: Bool) async {
        onlyCompatibleMods = enabled
        compatibilityError = nil
        guard enabled else {
            isCheckingCompatibility = false
            compatibleModIDs = []
            return
        }
        await checkCompatibility(for: mods, generation: requestGeneration)
    }

    func details(for mod: GameBananaMod) async throws -> GameBananaItemDetails {
        try await details(forModID: mod.id)
    }

    func details(forModID id: Int) async throws -> GameBananaItemDetails {
        var components = URLComponents(string: "https://gamebanana.com/apiv11/Mod/\(id)")!
        components.queryItems = [URLQueryItem(
            name: "_csvProperties",
            value: "_aFiles,_aPreviewMedia,_sName,_sProfileUrl,_sDescription"
        )]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        try Self.validate(response)
        return try JSONDecoder().decode(GameBananaItemDetails.self, from: data)
    }

    nonisolated static func download(
        _ file: GameBananaFile,
        progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }
    ) async throws -> URL {
        guard file.isSelectableRelease else {
            throw GameBananaError.unsupportedDownload
        }
        try FileManager.default.createDirectory(at: AppPaths.downloads, withIntermediateDirectories: true)
        let filename = URL(fileURLWithPath: file.name).lastPathComponent
        let destination = AppPaths.downloads
            .appendingPathComponent("\(UUID().uuidString)-\(filename)")
        let delegate = GameBananaDownloadDelegate(destination: destination, progress: progress)
        return try await delegate.download(from: file.downloadURL)
    }

    nonisolated static func downloadImageData(from url: URL) async throws -> Data {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              host == "gamebanana.com" || host.hasSuffix(".gamebanana.com") else {
            throw GameBananaError.badResponse
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        try Self.validate(response)
        guard !data.isEmpty, data.count <= 10 * 1024 * 1024 else {
            throw GameBananaError.badResponse
        }
        return data
    }

    nonisolated static func loadPreviewImage(from urls: [URL]) async -> NSImage? {
        for url in urls {
            guard url.scheme?.lowercased() == "https",
                  let host = url.host?.lowercased(),
                  host == "gamebanana.com" || host.hasSuffix(".gamebanana.com") else {
                continue
            }
            for attempt in 0..<2 {
                do {
                    var request = URLRequest(url: url)
                    request.cachePolicy = .returnCacheDataElseLoad
                    request.timeoutInterval = 20
                    let (data, response) = try await URLSession.shared.data(for: request)
                    guard let response = response as? HTTPURLResponse,
                          (200..<300).contains(response.statusCode),
                          data.count <= 15 * 1024 * 1024,
                          let image = NSImage(data: data) else {
                        break
                    }
                    return image
                } catch {
                    if attempt == 0 {
                        try? await Task.sleep(nanoseconds: 300_000_000)
                    }
                }
            }
        }
        return nil
    }

    private func fetchPage(page: Int, generation: UUID) async {
        isLoading = true
        errorMessage = nil
        defer {
            if generation == requestGeneration {
                isLoading = false
            }
        }

        var components = URLComponents(string: "https://gamebanana.com/apiv11/Util/Search/Results")!
        components.queryItems = [
            URLQueryItem(name: "_sSearchString", value: query.isEmpty ? game.title : query),
            URLQueryItem(name: "_sModelName", value: "Mod"),
            URLQueryItem(name: "_idGameRow", value: game.gameBananaRow),
            URLQueryItem(name: "_nPage", value: String(page)),
            URLQueryItem(name: "_nPerpage", value: String(GameBananaPagination.resultsPerPage)),
            URLQueryItem(name: "_sOrder", value: sortOption.apiValue)
        ]

        do {
            let (data, response) = try await URLSession.shared.data(from: components.url!)
            try Self.validate(response)
            let result = try JSONDecoder().decode(GameBananaSearchResponse.self, from: data)
            guard generation == requestGeneration else { return }
            mods.append(contentsOf: result.records)
            canLoadMore = mods.count < result.metadata.recordCount
            if onlyCompatibleMods {
                await checkCompatibility(for: result.records, generation: generation)
            }
        } catch {
            guard generation == requestGeneration else { return }
            if page > 1 { self.page = max(1, page - 1) }
            errorMessage = GameBananaError.message(for: error)
        }
    }

    private func checkCompatibility(for candidates: [GameBananaMod], generation: UUID) async {
        guard onlyCompatibleMods, generation == requestGeneration else { return }
        let unresolved = candidates.filter { compatibilityByModID[$0.id] == nil }
        guard !unresolved.isEmpty else {
            compatibleModIDs = Set(compatibilityByModID.compactMap { $0.value ? $0.key : nil })
            return
        }
        isCheckingCompatibility = true
        compatibilityProgress = 0
        compatibilityTotal = unresolved.count
        compatibilityError = nil
        defer {
            if generation == requestGeneration {
                isCheckingCompatibility = false
            }
        }

        for mod in unresolved {
            guard onlyCompatibleMods, generation == requestGeneration else { return }
            do {
                let item = try await details(for: mod)
                compatibilityByModID[mod.id] = item.files.contains(where: \.isSupportedRelease)
                compatibilityProgress += 1
                compatibleModIDs = Set(compatibilityByModID.compactMap { $0.value ? $0.key : nil })
            } catch {
                compatibilityError = "Couldn't check compatibility for \(mod.name): \(GameBananaError.message(for: error))"
                return
            }
        }
    }

    nonisolated private static func validate(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            throw GameBananaError.badResponse
        }
    }
}

private struct GameBananaSearchResponse: Decodable {
    let metadata: Metadata
    let records: [GameBananaMod]

    enum CodingKeys: String, CodingKey {
        case metadata = "_aMetadata"
        case records = "_aRecords"
    }

    struct Metadata: Decodable {
        let recordCount: Int

        enum CodingKeys: String, CodingKey {
            case recordCount = "_nRecordCount"
        }
    }
}

private final class GameBananaDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private let destination: URL
    private let progress: @Sendable (Int64, Int64) -> Void
    private var completion: ((Result<URL, Error>) -> Void)?
    private var completedURL: URL?
    private var session: URLSession?

    init(destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    func download(from url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            completion = { continuation.resume(with: $0) }
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            self.session = session
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        progress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            guard let response = downloadTask.response else {
                throw GameBananaError.badResponse
            }
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                throw GameBananaError.badResponse
            }
            try FileManager.default.moveItem(at: location, to: destination)
            completedURL = destination
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            finish(.failure(error))
        } else if let completedURL {
            finish(.success(completedURL))
        } else {
            finish(.failure(GameBananaError.badResponse))
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        guard let completion else { return }
        self.completion = nil
        completion(result)
        session?.finishTasksAndInvalidate()
        session = nil
    }
}

enum GameBananaError: LocalizedError {
    static let offlineMessage = "Game Offline! Try Again Later."

    case badResponse
    case unsupportedDownload
    case oneClickReleaseNotFound

    static func isOffline(_ error: Error) -> Bool {
        let error = error as NSError
        guard error.domain == NSURLErrorDomain else { return false }
        return [
            URLError.notConnectedToInternet.rawValue,
            URLError.networkConnectionLost.rawValue,
            URLError.cannotFindHost.rawValue,
            URLError.cannotConnectToHost.rawValue,
            URLError.dnsLookupFailed.rawValue,
            URLError.dataNotAllowed.rawValue
        ].contains(error.code)
    }

    static func message(for error: Error) -> String {
        isOffline(error) ? offlineMessage : error.localizedDescription
    }

    var errorDescription: String? {
        switch self {
        case .badResponse:
            return "GameBanana returned an unexpected response. Please try again."
        case .unsupportedDownload:
            return "This file isn't a Deltamod, G3M ZIP, or supported manual ZIP/RAR/xdelta patch."
        case .oneClickReleaseNotFound:
            return "The release selected by this GameBanana one-click link is no longer available."
        }
    }
}

struct ModCatalogView: View {
    @ObservedObject var catalog: GameBananaCatalog
    let installedModIDs: Set<Int>
    let select: (GameBananaMod) -> Void
    @State private var searchText = ""
    @State private var selectedCategory = "All Mods"

    private let categories = ["All Mods", "Gameplay Adjustments", "Difficulty Changes", "Game Files", "Skins"]

    private var visibleMods: [GameBananaMod] {
        let filteredMods = catalog.mods.filter { mod in
            let matchesCategory = selectedCategory == "All Mods" || mod.category == selectedCategory
            let matchesCompatibility = !catalog.onlyCompatibleMods || catalog.compatibleModIDs.contains(mod.id)
            return matchesCategory && matchesCompatibility
        }
        return filteredMods
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Discover \(catalog.game.title) Mods")
                        .font(.system(size: 23, weight: .bold, design: .rounded))
                    Text("Browse GameBanana's \(catalog.game.title) catalog")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
                Picker("Sort", selection: Binding(
                    get: { catalog.sortOption },
                    set: { option in
                        catalog.sortOption = option
                        Task { await catalog.search(searchText) }
                    }
                )) {
                    ForEach(GameBananaSort.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .labelsHidden()
                .frame(width: 145)
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.42))
                    TextField("Search mods", text: $searchText)
                        .textFieldStyle(.plain)
                        .onSubmit { Task { await catalog.search(searchText) } }
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                            Task { await catalog.search("") }
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.45))
                        }
                        .buttonStyle(.plain)
                    }
                    Button("Search") { Task { await catalog.search(searchText) } }
                        .buttonStyle(.borderedProminent)
                        .tint(.indigo)
                }
                .padding(8)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                .frame(width: 310)
            }
            .padding(.horizontal, 26)
            .padding(.top, 19)
            .padding(.bottom, 15)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(categories, id: \.self) { category in
                        Button {
                            selectedCategory = category
                            if category != "All Mods" {
                                Task { await loadCategoryResults(category) }
                            }
                        } label: {
                            Text(category)
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 13)
                                .padding(.vertical, 8)
                                .foregroundStyle(selectedCategory == category ? .white : .white.opacity(0.58))
                                .background(selectedCategory == category ? Color.indigo : Color.white.opacity(0.06), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 26)
            }
            .padding(.bottom, 15)

            HStack(spacing: 10) {
                Toggle("Only compatible mods", isOn: Binding(
                    get: { catalog.onlyCompatibleMods },
                    set: { value in Task { await catalog.setOnlyCompatibleMods(value) } }
                ))
                .toggleStyle(.checkbox)
                .font(.system(size: 11, weight: .medium))
                if catalog.isCheckingCompatibility {
                    ProgressView().controlSize(.small)
                    Text("Checking \(catalog.compatibilityProgress)/\(catalog.compatibilityTotal)…")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
                Text("Compatible = supported Deltamod, G3M ZIP, or patch release")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(.horizontal, 26)
            .padding(.bottom, 13)

            Rectangle().fill(.white.opacity(0.09)).frame(height: 1)

            if (catalog.isLoading || catalog.isCheckingCompatibility) && visibleMods.isEmpty {
                loadingState
            } else if let error = catalog.errorMessage, catalog.mods.isEmpty {
                messageState(
                    icon: "wifi.exclamationmark",
                    title: error == GameBananaError.offlineMessage
                        ? GameBananaError.offlineMessage
                        : "Couldn't load GameBanana",
                    detail: error,
                    button: "Try Again",
                    action: { Task { await catalog.search(searchText) } }
                )
            } else if let error = catalog.compatibilityError, visibleMods.isEmpty {
                messageState(
                    icon: "exclamationmark.triangle",
                    title: "Couldn't check compatibility",
                    detail: error,
                    button: "Retry",
                    action: { Task { await catalog.setOnlyCompatibleMods(true) } }
                )
            } else if visibleMods.isEmpty {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        VStack(spacing: 12) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 30))
                                .foregroundStyle(.cyan.opacity(0.8))
                            Text("No mods in this tab yet")
                                .font(.system(size: 17, weight: .bold))
                            Text(catalog.canLoadMore
                                ? "Scroll down to load more \(catalog.game.title) mods."
                                : "Try another category or search term.")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.55))
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, minHeight: 230)
                        loadMoreSentinel
                        if catalog.isLoading {
                            ProgressView().controlSize(.small).padding(14)
                        }
                    }
                }
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 205), spacing: 15)],
                            alignment: .leading,
                            spacing: 15
                        ) {
                            ForEach(Array(visibleMods.enumerated()), id: \.element.id) { index, mod in
                                GameBananaModCard(
                                    mod: mod,
                                    isInstalled: installedModIDs.contains(mod.id)
                                ) {
                                    select(mod)
                                }
                                    .onAppear {
                                        guard catalog.canLoadMore,
                                              !catalog.isLoading,
                                              GameBananaPagination.shouldPrefetch(
                                                visibleIndex: index,
                                                loadedCount: visibleMods.count
                                              ) else { return }
                                        Task { await catalog.loadMore() }
                                    }
                            }
                        }
                        .padding(22)
                        if catalog.isLoading {
                            HStack(spacing: 9) {
                                ProgressView().controlSize(.small)
                                Text("Loading more mods…")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.55))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(14)
                        }
                        if let error = catalog.errorMessage {
                            Text(error).font(.system(size: 11)).foregroundStyle(.orange).padding(.bottom, 12)
                        }
                        if let error = catalog.compatibilityError {
                            HStack(spacing: 8) {
                                Text(error).font(.system(size: 11)).foregroundStyle(.orange)
                                Button("Retry") {
                                    Task { await catalog.setOnlyCompatibleMods(true) }
                                }
                                .font(.system(size: 10, weight: .semibold))
                            }
                            .padding(.bottom, 12)
                        }
                    }
                }
            }
        }
        .task {
            if catalog.mods.isEmpty {
                await catalog.search("")
            }
        }
    }

    private func categoryMatchCount(_ category: String) -> Int {
        catalog.mods.filter { mod in
            mod.category == category &&
                (!catalog.onlyCompatibleMods || catalog.compatibleModIDs.contains(mod.id))
        }.count
    }

    @MainActor
    private func loadCategoryResults(_ category: String) async {
        while selectedCategory == category {
            guard catalog.canLoadMore else { return }
            if catalog.isLoading {
                do {
                    try await Task.sleep(nanoseconds: 100_000_000)
                } catch {
                    return
                }
                continue
            }
            guard GameBananaPagination.shouldLoadCategoryMore(
                matchingCount: categoryMatchCount(category),
                canLoadMore: catalog.canLoadMore
            ) else { return }
            let previousCount = catalog.mods.count
            await catalog.loadMore()
            if catalog.mods.count == previousCount || catalog.errorMessage != nil {
                return
            }
        }
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading \(catalog.game.title) mods from GameBanana…")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadMoreSentinel: some View {
        Color.clear
            .frame(height: 1)
            .id("\(catalog.mods.count)-\(visibleMods.count)")
            .onAppear {
                guard catalog.canLoadMore, !catalog.isLoading else { return }
                Task { await catalog.loadMore() }
            }
    }

    private func messageState(
        icon: String,
        title: String,
        detail: String,
        button: String?,
        action: (() -> Void)?
    ) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: icon).font(.system(size: 30)).foregroundStyle(.cyan.opacity(0.8))
            Text(title).font(.system(size: 17, weight: .bold))
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
            if let button, let action {
                Button(button, action: action).buttonStyle(.borderedProminent).tint(.indigo)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

private struct GameBananaModCard: View {
    let mod: GameBananaMod
    let isInstalled: Bool
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    GameBananaPreviewImage(urls: mod.imageURLs)
                    .frame(height: 128)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    if mod.hasFiles || isInstalled {
                        Label(
                            isInstalled ? "Installed" : "Files",
                            systemImage: isInstalled ? "checkmark.circle.fill" : "arrow.down.circle.fill"
                        )
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(isInstalled ? .gray.opacity(0.9) : .black.opacity(0.7), in: Capsule())
                            .padding(8)
                    }
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text(mod.name)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                    Text(mod.category ?? "Game Mod")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.cyan)
                        .lineLimit(1)
                    HStack(spacing: 9) {
                        if let author = mod.author {
                            Text("by \(author)").lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if let downloads = mod.downloadCount {
                            Label("\(downloads)", systemImage: "arrow.down.circle")
                        }
                    }
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.48))
                }
                .padding(11)
            }
            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.07), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(isInstalled)
        .opacity(isInstalled ? 0.48 : 1)
        .help(isInstalled ? "Already installed. Remove it from My Mods to download it again." : "View mod releases.")
    }
}

private struct GameBananaPreviewImage: View {
    let urls: [URL]
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle().fill(.white.opacity(0.06))
                    .overlay {
                        Image(systemName: "gamecontroller")
                            .font(.system(size: 28))
                            .foregroundStyle(.white.opacity(0.2))
                    }
            }
        }
        .task(id: urls) {
            image = nil
            image = await GameBananaCatalog.loadPreviewImage(from: urls)
        }
    }
}

struct GameBananaModDetailSheet: View {
    let mod: GameBananaMod
    @ObservedObject var catalog: GameBananaCatalog
    let downloadAndInstall: (GameBananaFile) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var details: GameBananaItemDetails?
    @State private var error: String?
    @State private var isLoading = true
    @State private var expandedReleaseIDs = Set<Int>()

    private var compatibleFiles: [GameBananaFile] {
        sortedReleases((details?.files ?? []).filter(\.isDeltamod).filter(\.isSelectableRelease))
    }

    private var manualFiles: [GameBananaFile] {
        sortedReleases((details?.files ?? []).filter { !$0.isDeltamod && $0.isSelectableRelease })
    }

    private func sortedReleases(_ files: [GameBananaFile]) -> [GameBananaFile] {
        files.sorted {
            if $0.isArchived != $1.isArchived {
                return !$0.isArchived
            }
            return ($0.dateAdded ?? 0) > ($1.dateAdded ?? 0)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(details?.name ?? mod.name)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Text("GameBanana mod details")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
                Button {
                    NSWorkspace.shared.open(details?.profileURL ?? mod.profileURL)
                } label: {
                    Label("GameBanana Page", systemImage: "arrow.up.right")
                }
                .buttonStyle(.bordered)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(18)

            Rectangle().fill(.white.opacity(0.1)).frame(height: 1)

            if isLoading {
                ProgressView("Loading releases…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                VStack(spacing: 12) {
                    Text(error)
                        .font(.system(size: 12, weight: error == GameBananaError.offlineMessage ? .bold : .regular))
                        .foregroundStyle(.orange)
                    Button("Retry") { Task { await loadDetails() } }.buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 17) {
                        if !mod.imageURLs.isEmpty {
                            GameBananaPreviewImage(urls: mod.imageURLs)
                            .frame(height: 190)
                            .frame(maxWidth: .infinity)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }

                        if let description = details?.description, !description.isEmpty {
                            Text(description)
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.72))
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if !compatibleFiles.isEmpty {
                            HStack(spacing: 8) {
                                Image(systemName: "shippingbox.fill").foregroundStyle(.cyan)
                                Text("Compatible Deltamod releases")
                                    .font(.system(size: 15, weight: .bold))
                            }
                            ForEach(compatibleFiles) { file in
                                releaseDisclosure(file, tint: .cyan)
                            }
                        }

                        if !manualFiles.isEmpty {
                            HStack(spacing: 8) {
                                Image(systemName: "wrench.and.screwdriver.fill").foregroundStyle(.orange)
                                Text("G3M or manual downloads")
                                    .font(.system(size: 15, weight: .bold))
                            }
                            Text("Downloads are analyzed first. Manual xdelta patches show their filenames so you can assign each one to a chapter.")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.5))
                            ForEach(manualFiles) { file in
                                releaseDisclosure(file, tint: .orange)
                            }
                        }

                        if compatibleFiles.isEmpty && manualFiles.isEmpty {
                            Text("No current Deltamod, G3M ZIP, or supported manual patch is available for this mod.")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.55))
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    .padding(18)
                }
            }

        }
        .frame(minWidth: 620, minHeight: 480)
        .preferredColorScheme(.dark)
        .task(id: mod.id) {
            await loadDetails()
        }
    }

    @MainActor
    private func loadDetails() async {
        isLoading = true
        error = nil
        do {
            details = try await catalog.details(for: mod)
        } catch {
            self.error = GameBananaError.message(for: error)
        }
        isLoading = false
    }

    private func releaseDisclosure(_ file: GameBananaFile, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    if expandedReleaseIDs.contains(file.id) {
                        expandedReleaseIDs.remove(file.id)
                    } else {
                        expandedReleaseIDs.insert(file.id)
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: file.isArchived ? "archivebox" : "shippingbox.fill")
                        .foregroundStyle(tint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(file.releaseTitle)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(2)
                        if file.isArchived {
                            Text("Archived version")
                                .font(.system(size: 10))
                                .foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    Image(systemName: expandedReleaseIDs.contains(file.id) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)

            if expandedReleaseIDs.contains(file.id) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(file.name)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .textSelection(.enabled)
                    HStack(spacing: 10) {
                        Text(file.formattedSize)
                        if file.isArchived {
                            Text("Archived release").foregroundStyle(.orange)
                        }
                    }
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.52))
                    Button {
                        downloadAndInstall(file)
                        dismiss()
                    } label: {
                        Label(
                            file.isDeltamod ? "Download & Install" : "Download & Analyze",
                            systemImage: "arrow.down.to.line"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(tint)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
    }
}
