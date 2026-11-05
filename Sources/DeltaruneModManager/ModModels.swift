import AppKit
import CryptoKit
import Foundation

struct AppSettings: Codable {
    var windowsBackupPath: String
    var gameAppPath: String
    var windowsSourcePath: String? = nil
    var undertaleAppPath: String? = nil
    var undertaleGameFolderPath: String? = nil
    var undertaleBackupPath: String? = nil
}

enum ModGame: String, Codable, CaseIterable, Identifiable {
    case deltarune
    case undertale

    var id: String { rawValue }

    var title: String {
        switch self {
        case .deltarune: "DELTARUNE"
        case .undertale: "UNDERTALE"
        }
    }

    var gameBananaRow: String {
        switch self {
        case .deltarune: "6755"
        case .undertale: "5506"
        }
    }
}

struct ModPayload: Codable, Hashable {
    var resourcePath: String
    var instanceFile: String
    var sourceLabel: String? = nil
}

struct ModInstance: Codable, Identifiable {
    var id: String
    var name: String
    var version: String
    var targetGameVersion: String?
    var description: String
    var authors: [String]
    var iconFile: String?
    var payloads: [ModPayload]
    var warnings: [String]
    var skippedFiles: [ModSkippedFile]? = nil
    var game: ModGame? = nil
    var gameBananaModID: Int? = nil
    var gameBananaFileID: Int? = nil
    var gameBananaFileDateAdded: Int64? = nil
    var lastPlayedAt: Date? = nil
    var category: String? = nil

    var targetGame: ModGame { game ?? .deltarune }

    static func categorySections(_ instances: [ModInstance]) -> [ModInstanceCategorySection] {
        var grouped: [String: (title: String, instances: [ModInstance])] = [:]
        for instance in instances {
            let cleanCategory = instance.category?.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = cleanCategory.flatMap { $0.isEmpty ? nil : $0 } ?? "Uncategorized"
            let key = title.localizedLowercase
            if grouped[key] == nil {
                grouped[key] = (title, [])
            }
            grouped[key]?.instances.append(instance)
        }

        return grouped.values
            .map { group in
                let orderedInstances = orderedByLastPlayed(group.instances)
                let title = orderedInstances.first?.category?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return ModInstanceCategorySection(
                    title: title.flatMap { $0.isEmpty ? nil : $0 } ?? group.title,
                    instances: orderedInstances
                )
            }
            .sorted { lhs, rhs in
                let lhsDate = lhs.instances.first?.lastPlayedAt
                let rhsDate = rhs.instances.first?.lastPlayedAt
                if let lhsDate, let rhsDate, lhsDate != rhsDate {
                    return lhsDate > rhsDate
                }
                if lhsDate != nil, rhsDate == nil { return true }
                if lhsDate == nil, rhsDate != nil { return false }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
    }

    static func orderedByLastPlayed(_ instances: [ModInstance]) -> [ModInstance] {
        instances.enumerated()
            .sorted { lhs, rhs in
                switch (lhs.element.lastPlayedAt, rhs.element.lastPlayedAt) {
                case let (left?, right?) where left != right:
                    return left > right
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    return lhs.offset < rhs.offset
                }
            }
            .map(\.element)
    }
}

struct ModInstanceCategorySection: Identifiable {
    let title: String
    let instances: [ModInstance]

    var id: String { title.localizedLowercase }
}

struct ModSkippedFile: Codable, Hashable, Identifiable {
    let sourcePath: String
    let targetPath: String
    let macReplacementPath: String

    var id: String { targetPath }
}

struct ModBuildResult {
    var instance: ModInstance
    var directory: URL
}

enum ModInstancePayloadMerger {
    static func merge(_ build: ModBuildResult, into directory: URL) throws -> ModInstance {
        let fileManager = FileManager.default
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let current = try JSONDecoder().decode(ModInstance.self, from: Data(contentsOf: manifestURL))
        let payloadRoot = directory.appendingPathComponent("Payloads", isDirectory: true)
        try fileManager.createDirectory(at: payloadRoot, withIntermediateDirectories: true)
        var updated = current
        var copiedFiles: [URL] = []
        var replacedFiles: [String] = []
        do {
            for payload in build.instance.payloads {
                let source = try SafePaths.url(
                    for: "Payloads/\(payload.instanceFile)",
                    under: build.directory
                )
                let filename = UUID().uuidString
                let destination = try SafePaths.url(for: filename, under: payloadRoot)
                try fileManager.copyItem(at: source, to: destination)
                copiedFiles.append(destination)
                let installed = ModPayload(
                    resourcePath: try SafePaths.relative(payload.resourcePath),
                    instanceFile: filename,
                    sourceLabel: payload.sourceLabel
                )
                replacedFiles.append(contentsOf: updated.payloads
                    .filter { $0.resourcePath == installed.resourcePath }
                    .map(\.instanceFile))
                updated.payloads.removeAll { $0.resourcePath == installed.resourcePath }
                updated.payloads.append(installed)
            }
            try JSONEncoder.pretty.encode(updated).write(to: manifestURL, options: .atomic)
        } catch {
            for file in copiedFiles {
                try? fileManager.removeItem(at: file)
            }
            throw error
        }
        for filename in Set(replacedFiles) {
            guard !updated.payloads.contains(where: { $0.instanceFile == filename }) else { continue }
            do {
                let oldFile = try SafePaths.url(for: filename, under: payloadRoot)
                if fileManager.fileExists(atPath: oldFile.path) {
                    try fileManager.removeItem(at: oldFile)
                }
            } catch {
                NSLog("Could not remove replaced instance payload %@: %@", filename, error.localizedDescription)
            }
        }
        return updated
    }

    static func replaceSkippedFile(
        _ skippedFile: ModSkippedFile,
        with replacementURL: URL,
        in directory: URL
    ) throws -> ModInstance {
        guard replacementURL.pathExtension.lowercased() == "dylib" else {
            throw ModManagerError.invalidArchive("Choose a macOS .dylib replacement.")
        }
        let fileManager = FileManager.default
        let manifestURL = directory.appendingPathComponent("manifest.json")
        var updated = try JSONDecoder().decode(ModInstance.self, from: Data(contentsOf: manifestURL))
        guard let skippedFiles = updated.skippedFiles,
              skippedFiles.contains(skippedFile) else {
            throw ModManagerError.invalidArchive("This skipped file is no longer available for replacement.")
        }

        let cleanTarget = try SafePaths.relative(skippedFile.macReplacementPath)
        let payloadRoot = directory.appendingPathComponent("Payloads", isDirectory: true)
        try fileManager.createDirectory(at: payloadRoot, withIntermediateDirectories: true)
        let filename = UUID().uuidString
        let destination = try SafePaths.url(for: filename, under: payloadRoot)
        try fileManager.copyItem(at: replacementURL, to: destination)

        let oldPayloads = updated.payloads.filter { $0.resourcePath == cleanTarget }
        updated.payloads.removeAll { $0.resourcePath == cleanTarget }
        updated.payloads.append(ModPayload(
            resourcePath: cleanTarget,
            instanceFile: filename,
            sourceLabel: "Mac replacement for \(skippedFile.targetPath)"
        ))
        updated.skippedFiles?.removeAll { $0 == skippedFile }
        updated.warnings.removeAll {
            $0 == "Skipped Windows-only or unsupported override: \(skippedFile.targetPath)"
        }

        do {
            try JSONEncoder.pretty.encode(updated).write(to: manifestURL, options: .atomic)
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }

        for payload in oldPayloads where !updated.payloads.contains(where: { $0.instanceFile == payload.instanceFile }) {
            do {
                let oldFile = try SafePaths.url(for: payload.instanceFile, under: payloadRoot)
                if fileManager.fileExists(atPath: oldFile.path) {
                    try fileManager.removeItem(at: oldFile)
                }
            } catch {
                NSLog("Could not remove replaced instance payload %@: %@", payload.instanceFile, error.localizedDescription)
            }
        }
        return updated
    }
}

enum ManualPatchTarget: Hashable {
    case launcher
    case chapter(Int)
    case undertale

    var displayName: String {
        switch self {
        case .launcher:
            "Launcher"
        case .chapter(let number):
            "Chapter \(number)"
        case .undertale:
            "Undertale data.win"
        }
    }
}

struct ManualPatchOption: Identifiable, Hashable {
    enum Kind: String, Hashable {
        case xdelta
        case dataWin
        case dylib
    }

    let path: String
    var kind: Kind = .xdelta
    var id: String { path }

    var suggestsLauncher: Bool {
        guard kind != .dylib else { return false }
        if URL(fileURLWithPath: path).lastPathComponent.caseInsensitiveCompare("data.win") == .orderedSame,
           suggestedChapter == nil {
            return true
        }
        let expression = try! NSRegularExpression(
            pattern: #"(?:^|[^a-z0-9])launcher(?:[^a-z0-9]|$)"#,
            options: [.caseInsensitive]
        )
        return expression.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
    }

    var suggestedChapter: Int? {
        let searchRange = NSRange(path.startIndex..., in: path)
        let patterns: [(String, NSRegularExpression.Options)] = [
            (#"(?:^|[^a-z0-9])(?:chapter|ch)[ _.-]*([1-5])(?:[^0-9]|$)"#, [.caseInsensitive]),
            (#"(?:Chapter|Ch)[ _.-]*([1-5])(?:[^0-9]|$)"#, [])
        ]
        for (pattern, options) in patterns {
            let expression = try! NSRegularExpression(pattern: pattern, options: options)
            if let match = expression.firstMatch(in: path, range: searchRange),
               let chapterRange = Range(match.range(at: 1), in: path) {
                return Int(path[chapterRange])
            }
        }
        return nil
    }
}

struct ManualPatchAssignment: Hashable {
    let patchPath: String
    let target: ManualPatchTarget
    var kind: ManualPatchOption.Kind = .xdelta

    init(patchPath: String, chapter: Int, kind: ManualPatchOption.Kind = .xdelta) {
        self.patchPath = patchPath
        self.target = .chapter(chapter)
        self.kind = kind
    }

    init(patchPath: String, target: ManualPatchTarget, kind: ManualPatchOption.Kind = .xdelta) {
        self.patchPath = patchPath
        self.target = target
        self.kind = kind
    }
}

struct ManualPatchSelection: Identifiable {
    let id = UUID()
    let archive: URL
    let modName: String
    let options: [ManualPatchOption]
    let deleteAfterSuccess: Bool
    var gameBananaIconURL: URL? = nil
    var game: ModGame = .deltarune
    var gameBananaModID: Int? = nil
    var gameBananaFileID: Int? = nil
    var gameBananaFileDateAdded: Int64? = nil
    var updatingInstanceID: String? = nil
    var queueEntryID: UUID? = nil
}

struct ModInstanceFileEntry: Identifiable, Hashable {
    let path: String
    let sourceLabel: String
    var id: String { path }
}

struct PatchSpec {
    let type: String
    let patch: String
    let target: String
}

enum ModArchiveKind: Equatable {
    case deltamod
    case g3m
    case legacyG3M
    case other
}

enum ModManagerError: LocalizedError {
    case invalidWindowsFolder
    case invalidUndertaleFolder
    case invalidGameApp
    case missingXdelta
    case invalidArchive(String)
    case unsupportedPatch(String)
    case missingSource(String)
    case patchFailed(String)
    case missingManualPatch
    case launchRollbackFailed(String)
    case unsafePath(String)
    case gameAlreadyRunning
    case activeRun

    var errorDescription: String? {
        switch self {
        case .invalidWindowsFolder:
            return "The selected folder does not contain any chapterN_windows/data.win files. Select the Windows DELTARUNE game folder, not the Mac Base DR folder."
        case .invalidUndertaleFolder:
            return "The selected folder does not contain Undertale's data.win file. Choose the Undertale game folder."
        case .invalidGameApp:
            return "The selected app does not contain Contents/Resources/chapterN_mac folders."
        case .missingXdelta:
            return "xdelta3 is required to install this mod. Install it with Homebrew using `brew install xdelta`, then try again."
        case .invalidArchive(let detail):
            return "This mod archive is invalid: \(detail)"
        case .unsupportedPatch(let detail):
            return "This mod contains a patch the app cannot safely apply: \(detail)"
        case .missingSource(let path):
            return "The mod needs a Windows source file that was not backed up: \(path). Re-run setup and select a complete Windows game folder."
        case .patchFailed(let detail):
            return "xdelta3 could not apply the patch: \(detail)"
        case .missingManualPatch:
            return "This manual download doesn't contain any .xdelta patches."
        case .launchRollbackFailed(let detail):
            return "A mod launch failed and automatic rollback also failed: \(detail). Do not launch DELTARUNE; the app will retry recovery next time it starts."
        case .unsafePath(let path):
            return "The mod contains an unsafe file path: \(path)"
        case .gameAlreadyRunning:
            return "DELTARUNE is already running. Quit it before launching a mod instance."
        case .activeRun:
            return "A modded game session is still active. Close DELTARUNE and let the app restore the original files first."
        }
    }
}

enum AppPaths {
    static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Deltarune Mod Manager", isDirectory: true)
    }

    static var settings: URL { support.appendingPathComponent("settings.json") }
    static var instances: URL { support.appendingPathComponent("Instances", isDirectory: true) }
    static var downloads: URL { support.appendingPathComponent("Downloads", isDirectory: true) }
    static var activeRun: URL { support.appendingPathComponent("ActiveRun", isDirectory: true) }

    static func instanceDirectory(_ id: String) -> URL {
        instances.appendingPathComponent(id, isDirectory: true)
    }
}

enum SafePaths {
    static func relative(_ input: String) throws -> String {
        let normalized = input.replacingOccurrences(of: "\\", with: "/")
        let trimmed = normalized.hasPrefix("./") ? String(normalized.dropFirst(2)) : normalized
        let originalComponents = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard !trimmed.hasPrefix("/"),
              !originalComponents.contains(".."),
              !originalComponents.contains(".") else {
            throw ModManagerError.unsafePath(input)
        }
        let path = NSString(string: trimmed).standardizingPath
        let components = path.split(separator: "/")
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.hasPrefix("../"),
              !path.contains("/../"),
              !components.contains(".."),
              !components.contains(".") else {
            throw ModManagerError.unsafePath(input)
        }
        return String(components.joined(separator: "/"))
    }

    static func url(for relativePath: String, under root: URL) throws -> URL {
        let clean = try relative(relativePath)
        let rootPath = root.standardizedFileURL.path
        let url = root.appendingPathComponent(clean).standardizedFileURL
        guard url.path.hasPrefix(rootPath + "/") else {
            throw ModManagerError.unsafePath(relativePath)
        }
        return url
    }
}

enum ModCustomFiles {
    static func prepareMirroredDirectories(from resources: URL, at customRoot: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: customRoot, withIntermediateDirectories: true)
        let standardizedRoot = customRoot.standardizedFileURL
        let rootValues = try standardizedRoot.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard rootValues.isSymbolicLink != true, rootValues.isDirectory == true else {
            throw ModManagerError.unsafePath(standardizedRoot.path)
        }
        guard let enumerator = fileManager.enumerator(
            at: resources,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: resources.path])
        }

        let resourcesPath = resources.standardizedFileURL.path
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(resourcesPath + "/") else {
                throw ModManagerError.unsafePath(path)
            }
            let relative = try SafePaths.relative(String(path.dropFirst(resourcesPath.count + 1)))
            let destination = try SafePaths.url(for: relative, under: standardizedRoot)
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        }
    }

    static func files(in root: URL) throws -> [String: URL] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: root.path) else { return [:] }
        let root = root.standardizedFileURL
        let rootValues = try root.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard rootValues.isSymbolicLink != true, rootValues.isDirectory == true else {
            throw ModManagerError.unsafePath(root.path)
        }
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: root.path])
        }

        var files: [String: URL] = [:]
        let rootPath = root.path
        for case let url as URL in enumerator {
            let standardizedURL = url.standardizedFileURL
            let urlPath = standardizedURL.path
            guard urlPath.hasPrefix(rootPath + "/") else {
                throw ModManagerError.unsafePath(urlPath)
            }
            let relative = try SafePaths.relative(String(urlPath.dropFirst(rootPath.count + 1)))
            var cursor = root
            let components = relative.split(separator: "/")
            var finalValues: URLResourceValues?
            for (index, component) in components.enumerated() {
                cursor.appendPathComponent(String(component))
                let values = try cursor.resourceValues(
                    forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
                )
                guard values.isSymbolicLink != true else {
                    throw ModManagerError.unsafePath(cursor.path)
                }
                let isLastComponent = index == components.count - 1
                guard isLastComponent
                    ? (values.isDirectory == true || values.isRegularFile == true)
                    : values.isDirectory == true else {
                    throw ModManagerError.unsafePath(cursor.path)
                }
                finalValues = values
            }
            if finalValues?.isDirectory == true { continue }
            guard finalValues?.isRegularFile == true else {
                throw ModManagerError.unsafePath(urlPath)
            }
            files[relative] = standardizedURL
        }
        return files
    }
}

enum WindowsBackup {
    static func backup(from folder: URL, to backupRoot: URL) throws {
        let fileManager = FileManager.default
        let entries = try fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var sourceFiles: [(URL, String)] = []
        let rootData = folder.appendingPathComponent("data.win")
        if fileManager.fileExists(atPath: rootData.path) {
            sourceFiles.append((rootData, "data.win"))
        }

        for entry in entries {
            guard entry.lastPathComponent.range(of: #"^chapter[1-5]_windows$"#, options: .regularExpression) != nil else {
                continue
            }
            let dataFile = entry.appendingPathComponent("data.win")
            if fileManager.fileExists(atPath: dataFile.path) {
                sourceFiles.append((dataFile, "\(entry.lastPathComponent)/data.win"))
            }
        }
        guard sourceFiles.contains(where: { $0.1.range(of: #"^chapter[1-5]_windows/data\.win$"#, options: .regularExpression) != nil }) else {
            throw ModManagerError.invalidWindowsFolder
        }

        try fileManager.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        for (source, relativePath) in sourceFiles {
            let destination = try SafePaths.url(for: relativePath, under: backupRoot)
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: source, to: destination)
        }
    }
}

enum UndertaleBackup {
    static func backup(from folder: URL, to backupRoot: URL) throws {
        let source = try GameAppLocator.undertaleDataFile(in: folder)
        try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: source,
            to: backupRoot.appendingPathComponent("data.win")
        )
    }
}

enum GameAppLocator {
    static func resources(for appURL: URL) throws -> URL {
        let candidate: URL
        if appURL.lastPathComponent == "Resources" {
            candidate = appURL
        } else {
            candidate = appURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        }
        let chapterFolders = (1...5).map {
            candidate.appendingPathComponent("chapter\($0)_mac", isDirectory: true)
        }
        guard chapterFolders.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw ModManagerError.invalidGameApp
        }
        return candidate.standardizedFileURL
    }

    static func defaultApp() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let common = home.appendingPathComponent(
            "Library/Application Support/Steam/steamapps/common",
            isDirectory: true
        )
        let candidates = [
            common.appendingPathComponent("DELTARUNE/DELTARUNE.app", isDirectory: true),
            common.appendingPathComponent("DELTARUNE.app", isDirectory: true)
        ]
        return candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })
    }

    static func defaultUndertaleApp() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let common = home.appendingPathComponent(
            "Library/Application Support/Steam/steamapps/common",
            isDirectory: true
        )
        let candidates = [
            common.appendingPathComponent("Undertale/UNDERTALE.app", isDirectory: true),
            common.appendingPathComponent("Undertale/Undertale.app", isDirectory: true),
            home.appendingPathComponent("Applications/Undertale.app", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Undertale.app", isDirectory: true)
        ]
        return candidates.first(where: {
            (try? undertaleResources(for: $0)) != nil
        })
    }

    static func undertaleResources(for appURL: URL) throws -> URL {
        let resources = appURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        let gameFile = resources.appendingPathComponent("game.ios")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: gameFile.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw ModManagerError.invalidGameApp
        }
        return resources.standardizedFileURL
    }

    static func defaultUndertaleFolder() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let folder = home.appendingPathComponent(
            "Library/Application Support/Steam/steamapps/common/Undertale",
            isDirectory: true
        )
        return (try? undertaleDataFile(in: folder)) == nil ? nil : folder
    }

    static func undertaleDataFile(in folder: URL) throws -> URL {
        let dataFile = folder.appendingPathComponent("data.win")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dataFile.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw ModManagerError.invalidUndertaleFolder
        }
        return dataFile
    }
}

enum DeltaModBuilder {
    private static let archiveInspectionScript = """
    import json, pathlib, sys, zipfile
    with zipfile.ZipFile(sys.argv[1]) as archive:
        names = [pathlib.PurePosixPath(name.replace("\\\\", "/")).name.lower() for name in archive.namelist()]
    print(json.dumps({
        "hasInfo": "_deltamodinfo.json" in names,
        "hasModding": "modding.xml" in names,
        "hasG3MConfig": "mod_config.json" in names,
        "hasLegacyG3MMetadata": "meta.toml" in names
    }))
    """

    private static let extractorScript = """
    import os, pathlib, shutil, stat, sys, zipfile
    archive_path, output_path = sys.argv[1], pathlib.Path(sys.argv[2]).resolve()
    output_path.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(archive_path) as archive:
        if len(archive.infolist()) > 10000 or sum(item.file_size for item in archive.infolist()) > 2_000_000_000:
            raise ValueError("archive exceeds the safe extraction limit")
        for entry in archive.infolist():
            name = entry.filename.replace("\\\\", "/")
            path = pathlib.PurePosixPath(name)
            mode = (entry.external_attr >> 16) & 0o170000
            if path.is_absolute() or any(part in ("..", "") for part in path.parts) or mode == stat.S_IFLNK:
                raise ValueError("unsafe archive entry: " + name)
            destination = (output_path / str(path)).resolve()
            if os.path.commonpath([str(output_path), str(destination)]) != str(output_path):
                raise ValueError("unsafe archive entry: " + name)
            if entry.is_dir():
                destination.mkdir(parents=True, exist_ok=True)
            else:
                destination.parent.mkdir(parents=True, exist_ok=True)
                with archive.open(entry) as source, open(destination, "wb") as target:
                    shutil.copyfileobj(source, target)
    """

    static func xdeltaExecutable() -> URL? {
        let fixedPaths = [
            "/opt/homebrew/bin/xdelta3",
            "/usr/local/bin/xdelta3",
            "/usr/bin/xdelta3"
        ]
        let pathEntries = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        let candidates = fixedPaths.map(URL.init(fileURLWithPath:)) +
            pathEntries.map { URL(fileURLWithPath: String($0)).appendingPathComponent("xdelta3") }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func archiveKind(_ archive: URL) throws -> ModArchiveKind {
        if archive.pathExtension.lowercased() == "rar" {
            return .other
        }
        guard archive.pathExtension.lowercased() == "zip" ||
                archive.pathExtension.lowercased() == "deltamod" else {
            return .other
        }
        let inspection = try inspectArchive(archive)
        if inspection.hasInfo && inspection.hasModding {
            return .deltamod
        }
        if inspection.hasG3MConfig {
            return .g3m
        }
        if inspection.hasModding && inspection.hasLegacyG3MMetadata {
            return .legacyG3M
        }
        return .other
    }

    static func isDeltamodArchive(_ archive: URL) throws -> Bool {
        try archiveKind(archive) == .deltamod
    }

    static func isG3MArchive(_ archive: URL) throws -> Bool {
        try archiveKind(archive) == .g3m
    }

    private static func inspectArchive(_ archive: URL) throws -> ArchiveInspection {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", archiveInspectionScript, archive.path]
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(
                data: error.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "Archive cannot be inspected."
            throw ModManagerError.invalidArchive(detail.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return try JSONDecoder().decode(ArchiveInspection.self, from: data)
    }

    static func build(archive: URL, windowsBackup: URL, supportRoot: URL) throws -> ModBuildResult {
        switch try archiveKind(archive) {
        case .deltamod:
            return try buildDeltamod(archive: archive, windowsBackup: windowsBackup, supportRoot: supportRoot)
        case .g3m:
            return try buildG3M(archive: archive, windowsBackup: windowsBackup, supportRoot: supportRoot)
        case .legacyG3M:
            return try buildDeltamod(archive: archive, windowsBackup: windowsBackup, supportRoot: supportRoot)
        case .other:
            throw ModManagerError.invalidArchive("This archive contains neither Deltamod metadata nor a G3M mod_config.json.")
        }
    }

    private static func buildDeltamod(
        archive: URL,
        windowsBackup: URL,
        supportRoot: URL
    ) throws -> ModBuildResult {
        let fileManager = FileManager.default
        let workDirectory = supportRoot.appendingPathComponent("Work-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workDirectory) }

        let extracted = workDirectory.appendingPathComponent("Archive", isDirectory: true)
        try extract(archive, to: extracted)
        let jsonMetadataURL = (try? findFile(named: "_deltamodInfo.json", in: extracted))
            ?? (try? findFile(named: "meta.json", in: extracted))
        let tomlMetadataURL = try? findFile(named: "meta.toml", in: extracted)
        let xmlURL = try findFile(named: "modding.xml", in: extracted)
        guard jsonMetadataURL != nil || tomlMetadataURL != nil else {
            throw ModManagerError.invalidArchive("Missing Deltamod/G3M metadata.")
        }
        let metadata = try readMetadata(jsonURL: jsonMetadataURL, tomlURL: tomlMetadataURL)
        let specs = try parseXML(xmlURL)
        guard !specs.isEmpty else {
            throw ModManagerError.invalidArchive("modding.xml has no patch entries.")
        }

        let payloadRoot = workDirectory.appendingPathComponent("Payloads", isDirectory: true)
        try fileManager.createDirectory(at: payloadRoot, withIntermediateDirectories: true)
        var payloads: [ModPayload] = []
        var warnings: [String] = []
        var skippedFiles: [ModSkippedFile] = []
        var emittedTargets = Set<String>()

        for spec in specs {
            let patchPath = try SafePaths.relative(spec.patch)
            let targetPath = try SafePaths.relative(spec.target)
            let patchURL = try findFile(path: patchPath, in: extracted)
            let destinationPath: String
            let outputURL: URL

            if spec.type.lowercased() == "xdelta" ||
                spec.type.lowercased() == "bps" ||
                patchURL.pathExtension.lowercased() == "bps" {
                let chapter = try chapterNumber(fromWindowsTarget: targetPath)
                let sourceRelative = "chapter\(chapter)_windows/data.win"
                let sourceURL = try SafePaths.url(for: sourceRelative, under: windowsBackup)
                guard fileManager.fileExists(atPath: sourceURL.path) else {
                    throw ModManagerError.missingSource(sourceRelative)
                }
                if let expectedChecksum = metadata.neededFiles[targetPath] {
                    try verifyLegacyChecksum(expectedChecksum, for: sourceURL)
                }
                destinationPath = "chapter\(chapter)_mac/game.ios"
                outputURL = try SafePaths.url(for: "Patched-\(chapter)-\(UUID().uuidString)", under: payloadRoot)
                if spec.type.lowercased() == "bps" || patchURL.pathExtension.lowercased() == "bps" {
                    try BPSPatcher.apply(source: sourceURL, patch: patchURL, output: outputURL)
                } else {
                    guard let xdelta = xdeltaExecutable() else {
                        throw ModManagerError.missingXdelta
                    }
                    try runXdelta(executable: xdelta, source: sourceURL, patch: patchURL, output: outputURL)
                }
            } else if spec.type.lowercased() == "override" {
                guard let mapped = mapOverrideTarget(targetPath) else {
                    warnings.append("Skipped Windows-only or unsupported override: \(targetPath)")
                    if let macPath = macReplacementPath(forWindowsTarget: targetPath) {
                        skippedFiles.append(ModSkippedFile(
                            sourcePath: patchPath,
                            targetPath: targetPath,
                            macReplacementPath: macPath
                        ))
                    }
                    continue
                }
                destinationPath = mapped
                outputURL = try SafePaths.url(for: "Override-\(UUID().uuidString)", under: payloadRoot)
                try fileManager.copyItem(at: patchURL, to: outputURL)
            } else {
                throw ModManagerError.unsupportedPatch(spec.type)
            }

            guard emittedTargets.insert(destinationPath).inserted else {
                throw ModManagerError.unsupportedPatch("multiple entries target \(destinationPath)")
            }
            payloads.append(ModPayload(resourcePath: destinationPath, instanceFile: outputURL.lastPathComponent))
        }

        guard !payloads.isEmpty || !skippedFiles.isEmpty else {
            throw ModManagerError.invalidArchive("No Mac-compatible files were found.")
        }

        let id = UUID().uuidString
        let instancesRoot = supportRoot.appendingPathComponent("Instances", isDirectory: true)
        let finalDirectory = instancesRoot.appendingPathComponent(id, isDirectory: true)
        try fileManager.createDirectory(at: instancesRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: finalDirectory, withIntermediateDirectories: true)
        let finalPayloadRoot = finalDirectory.appendingPathComponent("Payloads", isDirectory: true)
        try fileManager.moveItem(at: payloadRoot, to: finalPayloadRoot)

        var iconFile: String?
        if let icon = try? findFile(named: "_icon.png", in: extracted) {
            let iconDestination = finalDirectory.appendingPathComponent("icon.png")
            try fileManager.copyItem(at: icon, to: iconDestination)
            iconFile = "icon.png"
        }

        let instance = ModInstance(
            id: id,
            name: metadata.name,
            version: metadata.version,
            targetGameVersion: metadata.targetVersion,
            description: metadata.description,
            authors: metadata.authors,
            iconFile: iconFile,
            payloads: payloads,
            warnings: warnings,
            skippedFiles: skippedFiles.isEmpty ? nil : skippedFiles
        )
        let manifestURL = finalDirectory.appendingPathComponent("manifest.json")
        let data = try JSONEncoder.pretty.encode(instance)
        try data.write(to: manifestURL, options: .atomic)
        return ModBuildResult(instance: instance, directory: finalDirectory)
    }

    private static func buildG3M(
        archive: URL,
        windowsBackup: URL,
        supportRoot: URL
    ) throws -> ModBuildResult {
        let fileManager = FileManager.default
        let workDirectory = supportRoot.appendingPathComponent("Work-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workDirectory) }

        let extracted = workDirectory.appendingPathComponent("Archive", isDirectory: true)
        try extract(archive, to: extracted)
        let configURL = try findFile(named: "mod_config.json", in: extracted)
        let configData = try Data(contentsOf: configURL)
        guard let config = try JSONSerialization.jsonObject(with: configData) as? [String: Any],
              config["config_version"] as? String == "2.0.0",
              let game = config["game"] as? String,
              game.caseInsensitiveCompare("deltarune") == .orderedSame,
              let name = config["name"] as? String, !name.isEmpty,
              let version = config["version"] as? String,
              let authors = config["authors"] as? [String],
              let entries = config["files"] as? [Any] else {
            throw ModManagerError.invalidArchive(
                "The G3M package must use config_version 2.0.0 and target DELTARUNE."
            )
        }

        let placeholders = config["placeholders"] as? [String: String] ?? [:]
        let operations = try flattenG3MOperations(entries)
        let payloadRoot = workDirectory.appendingPathComponent("Payloads", isDirectory: true)
        try fileManager.createDirectory(at: payloadRoot, withIntermediateDirectories: true)

        var payloads: [ModPayload] = []
        let warnings: [String] = []
        var emittedTargets = Set<String>()

        for operation in operations {
            guard let type = operation["type"] as? String,
                  let sourceExpression = operation["source"] as? String else {
                throw ModManagerError.invalidArchive("A G3M operation is missing its source or type.")
            }
            if type == "info" {
                continue
            }
            guard let targetExpression = operation["target"] as? String else {
                throw ModManagerError.invalidArchive("The G3M \(type) operation is missing its target.")
            }

            let sourcePath = try expandG3MPath(sourceExpression, placeholders: placeholders)
            guard sourcePath.hasPrefix("${mod_path}/") else {
                throw ModManagerError.unsafePath(sourceExpression)
            }
            let sourceRelative = try SafePaths.relative(String(sourcePath.dropFirst("${mod_path}/".count)))
            let sourceURL = try SafePaths.url(for: sourceRelative, under: extracted)
            guard fileManager.fileExists(atPath: sourceURL.path) else {
                throw ModManagerError.invalidArchive("Missing G3M source file: \(sourceRelative)")
            }

            let targetPath = try expandG3MPath(targetExpression, placeholders: placeholders)
            guard targetPath.hasPrefix("${game_path}/") else {
                throw ModManagerError.unsupportedPatch(targetExpression)
            }
            let targetRelative = try SafePaths.relative(String(targetPath.dropFirst("${game_path}/".count)))
            guard let destinationPath = mapOverrideTarget(targetRelative) else {
                throw ModManagerError.unsupportedPatch(targetExpression)
            }
            let sourceHash = operation["source_hash"] as? String
            let targetHash = operation["target_hash"] as? String
            if let sourceHash {
                try verifySHA256(sourceHash, for: sourceURL)
            }

            let isDataFile = destinationPath.range(
                of: #"^chapter[1-5]_mac/game\.ios$"#,
                options: .regularExpression
            ) != nil || destinationPath == "game.ios"
            let outputURL = try SafePaths.url(
                for: "Payload-\(UUID().uuidString)",
                under: payloadRoot
            )
            switch type {
            case "patch":
                guard isDataFile else {
                    throw ModManagerError.unsupportedPatch("G3M patch target \(targetExpression)")
                }
                let sourceRelative: String
                if targetRelative == "data.win" {
                    sourceRelative = "data.win"
                } else {
                    let chapter = try chapterNumber(fromWindowsTarget: targetRelative)
                    sourceRelative = "chapter\(chapter)_windows/data.win"
                }
                let baseURL = try SafePaths.url(for: sourceRelative, under: windowsBackup)
                guard fileManager.fileExists(atPath: baseURL.path) else {
                    throw ModManagerError.missingSource(sourceRelative)
                }
                if let targetHash {
                    try verifySHA256(targetHash, for: baseURL)
                }
                switch sourceURL.pathExtension.lowercased() {
                case "xdelta":
                    guard let xdelta = xdeltaExecutable() else {
                        throw ModManagerError.missingXdelta
                    }
                    try runXdelta(executable: xdelta, source: baseURL, patch: sourceURL, output: outputURL)
                case "win", "ios", "unx":
                    try fileManager.copyItem(at: sourceURL, to: outputURL)
                case "g3mpatch":
                    throw ModManagerError.unsupportedPatch(
                        "G3M resource patches (.g3mpatch) must be converted to xdelta or a full data file."
                    )
                default:
                    throw ModManagerError.unsupportedPatch("G3M patch source \(sourceURL.lastPathComponent)")
                }
            case "overwrite":
                guard targetHash == nil else {
                    throw ModManagerError.unsupportedPatch("target_hash on G3M file overrides")
                }
                var isDirectory: ObjCBool = false
                guard !fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory)
                        || !isDirectory.boolValue else {
                    throw ModManagerError.unsupportedPatch("G3M folder overwrite \(sourceRelative)")
                }
                try fileManager.copyItem(at: sourceURL, to: outputURL)
            case "soft-overwrite", "hard-overwrite", "extract", "soft-extract", "hard-extract":
                throw ModManagerError.unsupportedPatch("G3M operation \(type)")
            default:
                throw ModManagerError.unsupportedPatch("G3M operation \(type)")
            }

            guard emittedTargets.insert(destinationPath).inserted else {
                throw ModManagerError.unsupportedPatch("multiple entries target \(destinationPath)")
            }
            payloads.append(ModPayload(resourcePath: destinationPath, instanceFile: outputURL.lastPathComponent))
        }

        guard !payloads.isEmpty else {
            throw ModManagerError.invalidArchive("The G3M package has no supported DELTARUNE install actions.")
        }

        let id = UUID().uuidString
        let instancesRoot = supportRoot.appendingPathComponent("Instances", isDirectory: true)
        let finalDirectory = instancesRoot.appendingPathComponent(id, isDirectory: true)
        try fileManager.createDirectory(at: instancesRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: finalDirectory, withIntermediateDirectories: true)
        try fileManager.moveItem(
            at: payloadRoot,
            to: finalDirectory.appendingPathComponent("Payloads", isDirectory: true)
        )

        var iconFile: String?
        if let iconExpression = config["icon"] as? String {
            let expandedIcon = try expandG3MPath(iconExpression, placeholders: placeholders)
            if expandedIcon.hasPrefix("${mod_path}/") {
                let iconPath = try SafePaths.relative(String(expandedIcon.dropFirst("${mod_path}/".count)))
                let iconURL = try SafePaths.url(for: iconPath, under: extracted)
                if fileManager.fileExists(atPath: iconURL.path) {
                    try fileManager.copyItem(at: iconURL, to: finalDirectory.appendingPathComponent("icon.png"))
                    iconFile = "icon.png"
                }
            }
        }

        let instance = ModInstance(
            id: id,
            name: name,
            version: version,
            targetGameVersion: config["game_version"] as? String,
            description: config["description"] as? String ?? "",
            authors: authors,
            iconFile: iconFile,
            payloads: payloads,
            warnings: warnings
        )
        try JSONEncoder.pretty.encode(instance)
            .write(to: finalDirectory.appendingPathComponent("manifest.json"), options: .atomic)
        return ModBuildResult(instance: instance, directory: finalDirectory)
    }

    private static func flattenG3MOperations(_ entries: [Any]) throws -> [[String: Any]] {
        var operations: [[String: Any]] = []
        for entry in entries {
            guard let object = entry as? [String: Any] else {
                throw ModManagerError.invalidArchive("G3M files must be operations or named groups.")
            }
            if object["type"] is String {
                operations.append(object)
            } else if object.count == 1, let group = object.values.first as? [Any] {
                operations.append(contentsOf: try flattenG3MOperations(group))
            } else {
                throw ModManagerError.invalidArchive("Invalid G3M operation group.")
            }
        }
        return operations
    }

    private static func expandG3MPath(
        _ path: String,
        placeholders: [String: String]
    ) throws -> String {
        var expanded = path
        for (name, value) in placeholders {
            guard value.hasPrefix("${game_path}/") || value.hasPrefix("${mod_path}/") else {
                throw ModManagerError.unsafePath(value)
            }
            expanded = expanded.replacingOccurrences(of: "${\(name)}", with: value)
        }
        let withoutBuiltInRoots = expanded
            .replacingOccurrences(of: "${mod_path}", with: "")
            .replacingOccurrences(of: "${game_path}", with: "")
        guard !withoutBuiltInRoots.contains("${"), !withoutBuiltInRoots.contains("}") else {
            throw ModManagerError.unsafePath(path)
        }
        return expanded
    }

    private static func verifySHA256(_ expected: String, for fileURL: URL) throws {
        guard expected.range(
            of: #"^sha256:[0-9a-f]{64}$"#,
            options: .regularExpression
        ) != nil else {
            throw ModManagerError.invalidArchive("G3M hashes must use sha256: followed by 64 lowercase hexadecimal digits.")
        }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let actual = "sha256:" + hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
        guard actual == expected else {
            throw ModManagerError.invalidArchive("G3M SHA-256 check failed for \(fileURL.lastPathComponent).")
        }
    }

    private static func verifyLegacyChecksum(_ expected: String, for fileURL: URL) throws {
        let checksum = expected.lowercased()
        let algorithm: String
        switch checksum.count {
        case 32: algorithm = "md5"
        case 40: algorithm = "sha1"
        case 64: algorithm = "sha256"
        default:
            throw ModManagerError.invalidArchive("G3M checksum has an unsupported length.")
        }
        guard checksum.range(of: #"^[0-9a-f]+$"#, options: .regularExpression) != nil else {
            throw ModManagerError.invalidArchive("G3M checksums must be hexadecimal.")
        }

        let actual: String
        switch algorithm {
        case "md5":
            actual = try fileDigest(fileURL, using: Insecure.MD5.self)
                .map { String(format: "%02x", $0) }
                .joined()
        case "sha1":
            actual = try fileDigest(fileURL, using: Insecure.SHA1.self)
                .map { String(format: "%02x", $0) }
                .joined()
        default:
            actual = try fileDigest(fileURL, using: SHA256.self)
                .map { String(format: "%02x", $0) }
                .joined()
        }
        guard actual == checksum else {
            throw ModManagerError.invalidArchive(
                "The backed-up Windows data.win checksum doesn't match this G3M patch."
            )
        }
    }

    private static func fileDigest<H: HashFunction>(
        _ fileURL: URL,
        using type: H.Type
    ) throws -> H.Digest {
        var hasher = H()
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize()
    }

    static func manualPatchOptions(
        archive: URL,
        supportRoot: URL
    ) throws -> [ManualPatchOption] {
        if ["xdelta", "dylib"].contains(archive.pathExtension.lowercased()) {
            let kind: ManualPatchOption.Kind = archive.pathExtension.lowercased() == "dylib" ? .dylib : .xdelta
            return [ManualPatchOption(path: archive.lastPathComponent, kind: kind)]
        }
        let fileManager = FileManager.default
        let workDirectory = supportRoot.appendingPathComponent("Work-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workDirectory) }

        let extracted = workDirectory.appendingPathComponent("Archive", isDirectory: true)
        try extract(archive, to: extracted)
        let extractedPath = extracted.standardizedFileURL.path
        let extractedPrefix = extractedPath.hasSuffix("/") ? extractedPath : extractedPath + "/"
        let files = try findFiles(in: extracted)
            .filter { url in
                var isDirectory: ObjCBool = false
                return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
            }
            .compactMap { url -> ManualPatchOption? in
                let path = String(url.standardizedFileURL.path.dropFirst(extractedPrefix.count))
                switch url.pathExtension.lowercased() {
                case "xdelta":
                    return ManualPatchOption(path: path)
                case "win" where url.lastPathComponent.caseInsensitiveCompare("data.win") == .orderedSame:
                    return ManualPatchOption(path: path, kind: .dataWin)
                case "dylib":
                    return ManualPatchOption(path: path, kind: .dylib)
                default:
                    return nil
                }
            }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        guard !files.isEmpty else {
            throw ModManagerError.missingManualPatch
        }
        return files
    }

    static func buildManual(
        archive: URL,
        assignments: [ManualPatchAssignment],
        modName: String,
        windowsBackup: URL,
        supportRoot: URL,
        game: ModGame = .deltarune
    ) throws -> ModBuildResult {
        guard !assignments.isEmpty else {
            throw ModManagerError.missingManualPatch
        }
        let gamePatches = assignments.filter { $0.kind != .dylib }
        let hasValidTargets = assignments.allSatisfy { assignment in
            switch assignment.target {
            case .launcher:
                game == .deltarune && assignment.kind != .dylib
            case .chapter(let chapter):
                game == .deltarune && (1...5).contains(chapter)
            case .undertale:
                game == .undertale && assignment.kind != .dylib
            }
        }
        guard hasValidTargets,
              Set(gamePatches.map(\.target)).count == gamePatches.count,
              Set(assignments.map(\.patchPath)).count == assignments.count else {
            throw ModManagerError.unsupportedPatch(
                "Each file must target one supported game data file; only one xdelta or data.win may target each game file."
            )
        }

        let fileManager = FileManager.default
        let workDirectory = supportRoot.appendingPathComponent("Work-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workDirectory) }

        let isStandaloneFile = ["xdelta", "dylib"].contains(archive.pathExtension.lowercased())
        let extracted = workDirectory.appendingPathComponent("Archive", isDirectory: true)
        if !isStandaloneFile {
            try extract(archive, to: extracted)
        }
        let languageFiles = isStandaloneFile
            ? []
            : try findFiles(in: extracted).filter { isLanguageOverride($0.lastPathComponent) }
        let payloadRoot = workDirectory.appendingPathComponent("Payloads", isDirectory: true)
        try fileManager.createDirectory(at: payloadRoot, withIntermediateDirectories: true)
        var manualPayloads: [ModPayload] = []
        var emittedTargets = Set<String>()

        for assignment in assignments {
            let patchURL: URL
            if isStandaloneFile {
                guard assignment.patchPath == archive.lastPathComponent else {
                    throw ModManagerError.invalidArchive("The selected file doesn't match the imported file.")
                }
                patchURL = archive
            } else {
                let patchPath = try SafePaths.relative(assignment.patchPath)
                patchURL = try findFile(path: patchPath, in: extracted)
            }

            let destinationPath: String
            let output = payloadRoot.appendingPathComponent("Patched-\(UUID().uuidString)")
            switch assignment.kind {
            case .xdelta:
                let sourceRelative: String
                switch assignment.target {
                case .launcher:
                    sourceRelative = "data.win"
                    destinationPath = "game.ios"
                case .chapter(let chapter):
                    sourceRelative = "chapter\(chapter)_windows/data.win"
                    destinationPath = "chapter\(chapter)_mac/game.ios"
                case .undertale:
                    sourceRelative = "data.win"
                    destinationPath = "game.ios"
                }
                let source = try SafePaths.url(for: sourceRelative, under: windowsBackup)
                guard fileManager.fileExists(atPath: source.path) else {
                    throw ModManagerError.missingSource(sourceRelative)
                }
                guard let xdelta = xdeltaExecutable() else {
                    throw ModManagerError.missingXdelta
                }
                try runXdelta(executable: xdelta, source: source, patch: patchURL, output: output)
            case .dataWin:
                let sourceRelative: String
                switch assignment.target {
                case .launcher:
                    sourceRelative = "data.win"
                    destinationPath = "game.ios"
                case .chapter(let chapter):
                    sourceRelative = "chapter\(chapter)_windows/data.win"
                    destinationPath = "chapter\(chapter)_mac/game.ios"
                case .undertale:
                    sourceRelative = "data.win"
                    destinationPath = "game.ios"
                }
                let source = try SafePaths.url(for: sourceRelative, under: windowsBackup)
                guard fileManager.fileExists(atPath: source.path) else {
                    throw ModManagerError.missingSource(sourceRelative)
                }
                try fileManager.copyItem(at: patchURL, to: output)
            case .dylib:
                guard case .chapter(let chapter) = assignment.target, game == .deltarune else {
                    throw ModManagerError.unsupportedPatch("A dylib must target a chapter, not the launcher.")
                }
                destinationPath = "chapter\(chapter)_mac/\(URL(fileURLWithPath: assignment.patchPath).lastPathComponent)"
                _ = try SafePaths.relative(destinationPath)
                try fileManager.copyItem(at: patchURL, to: output)
            }
            guard emittedTargets.insert(destinationPath).inserted else {
                throw ModManagerError.unsupportedPatch("multiple files target \(destinationPath)")
            }
            manualPayloads.append(ModPayload(
                resourcePath: destinationPath,
                instanceFile: output.lastPathComponent,
                sourceLabel: modName
            ))

            if case .chapter(let chapter) = assignment.target {
                for languageFile in languageFiles where assignment.kind != .dylib {
                    let languagePath = "chapter\(chapter)_mac/lang/\(languageFile.lastPathComponent)"
                    guard emittedTargets.insert(languagePath).inserted else {
                        throw ModManagerError.unsupportedPatch("multiple files target \(languagePath)")
                    }
                    let payloadURL = payloadRoot.appendingPathComponent("Override-\(UUID().uuidString)")
                    try fileManager.copyItem(at: languageFile, to: payloadURL)
                    manualPayloads.append(ModPayload(
                        resourcePath: languagePath,
                        instanceFile: payloadURL.lastPathComponent,
                        sourceLabel: modName
                    ))
                }
            }
        }

        let id = UUID().uuidString
        let instancesRoot = supportRoot.appendingPathComponent("Instances", isDirectory: true)
        let finalDirectory = instancesRoot.appendingPathComponent(id, isDirectory: true)
        try fileManager.createDirectory(at: instancesRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: finalDirectory, withIntermediateDirectories: true)
        let finalPayloadRoot = finalDirectory.appendingPathComponent("Payloads", isDirectory: true)
        try fileManager.moveItem(at: payloadRoot, to: finalPayloadRoot)

        var iconFile: String?
        if !isStandaloneFile,
           let icon = try? findFile(named: "_icon.png", in: extracted) {
            try fileManager.copyItem(at: icon, to: finalDirectory.appendingPathComponent("icon.png"))
            iconFile = "icon.png"
        }

        let targets = assignments.map(\.target.displayName).sorted().joined(separator: ", ")
        let instance = ModInstance(
            id: id,
            name: modName,
            version: "",
            targetGameVersion: nil,
            description: "Manually imported files for \(targets).",
            authors: [],
            iconFile: iconFile,
            payloads: manualPayloads,
            warnings: assignments.map {
                "Manually assigned \($0.patchPath) to \($0.target.displayName) as a manually selected file; verify it matches that target."
            },
            game: game
        )
        try JSONEncoder.pretty.encode(instance)
            .write(to: finalDirectory.appendingPathComponent("manifest.json"), options: .atomic)
        return ModBuildResult(instance: instance, directory: finalDirectory)
    }

    private static func extract(_ archive: URL, to destination: URL) throws {
        if archive.pathExtension.lowercased() == "rar" {
            try extractRAR(archive, to: destination)
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", extractorScript, archive.path, destination.path]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw ModManagerError.invalidArchive(error.localizedDescription)
        }
        guard process.terminationStatus == 0 else {
            let message = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "Could not extract archive."
            throw ModManagerError.invalidArchive(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func extractRAR(_ archive: URL, to destination: URL) throws {
        try validateRARPaths(archive)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = [
            "-x",
            "-f", archive.path,
            "-C", destination.path,
            "--no-same-owner",
            "--no-same-permissions"
        ]
        let errorPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw ModManagerError.invalidArchive("Could not start the macOS RAR extractor: \(error.localizedDescription)")
        }
        guard process.terminationStatus == 0 else {
            let detail = String(
                data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
            let message: String
            if let detail, !detail.isEmpty {
                message = "Could not extract RAR: \(detail)"
            } else {
                message = "Could not extract this RAR. Make sure it isn't encrypted or damaged."
            }
            throw ModManagerError.invalidArchive(
                message
            )
        }
        try validateExtractedRAR(at: destination)
    }

    private static func validateRARPaths(_ archive: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-t", "-f", archive.path]
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        do {
            try process.run()
        } catch {
            throw ModManagerError.invalidArchive("Could not start the macOS RAR extractor: \(error.localizedDescription)")
        }
        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(
                data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = if let detail, !detail.isEmpty {
                "Could not read RAR contents: \(detail)"
            } else {
                "The RAR archive is invalid or unsupported."
            }
            throw ModManagerError.invalidArchive(message)
        }
        guard let listing = String(data: output, encoding: .utf8) else {
            throw ModManagerError.invalidArchive("The RAR archive contains an invalid file listing.")
        }
        let entries = listing.split(whereSeparator: \.isNewline)
        guard entries.count <= 10_000 else {
            throw ModManagerError.invalidArchive("The RAR archive exceeds the 10,000-entry extraction limit.")
        }
        for entry in entries {
            let path = String(entry).replacingOccurrences(of: "\\", with: "/")
            let firstComponent = path.split(separator: "/").first.map(String.init) ?? ""
            guard !firstComponent.contains(":") else {
                throw ModManagerError.unsafePath(path)
            }
            _ = try SafePaths.relative(path)
        }
    }

    private static func validateExtractedRAR(at root: URL) throws {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else {
            throw ModManagerError.invalidArchive("The RAR archive could not be inspected after extraction.")
        }

        var entryCount = 0
        var totalSize: Int64 = 0
        while let url = enumerator.nextObject() as? URL {
            entryCount += 1
            guard entryCount <= 10_000 else {
                throw ModManagerError.invalidArchive("The RAR archive exceeds the 10,000-entry extraction limit.")
            }
            let values = try url.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true,
                  values.isDirectory == true || values.isRegularFile == true else {
                throw ModManagerError.invalidArchive("The RAR contains an unsupported or unsafe file entry.")
            }
            if values.isRegularFile == true {
                totalSize += Int64(values.fileSize ?? 0)
                guard totalSize <= 2_000_000_000 else {
                    throw ModManagerError.invalidArchive("The RAR archive exceeds the 2 GB extraction limit.")
                }
            }
        }
    }

    private static func findFile(named name: String, in root: URL) throws -> URL {
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent.compare(name, options: .caseInsensitive) == .orderedSame {
                return url
            }
        }
        throw ModManagerError.invalidArchive("Missing \(name).")
    }

    private static func findFiles(withExtension ext: String, in root: URL) throws -> [URL] {
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        var matches: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension.lowercased() == ext.lowercased() {
                matches.append(url)
            }
        }
        return matches
    }

    private static func findFiles(in root: URL) throws -> [URL] {
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        var matches: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            matches.append(url)
        }
        return matches
    }

    private static func isLanguageOverride(_ filename: String) -> Bool {
        filename.range(
            of: #"^lang_[a-z]{2}(?:[-_][a-z0-9]+)?\.json$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func findFile(path: String, in root: URL) throws -> URL {
        let exact = try SafePaths.url(for: path, under: root)
        if FileManager.default.fileExists(atPath: exact.path) {
            return exact
        }
        let suffix = "/" + path
        let matches = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .allObjects as? [URL] ?? []).filter { $0.path.hasSuffix(suffix) }
        guard matches.count == 1, let match = matches.first else {
            throw ModManagerError.invalidArchive("Cannot uniquely find \(path).")
        }
        return match
    }

    private static func readMetadata(jsonURL: URL?, tomlURL: URL?) throws -> (
        name: String,
        version: String,
        targetVersion: String?,
        description: String,
        authors: [String],
        neededFiles: [String: String]
    ) {
        if let jsonURL {
            let data = try Data(contentsOf: jsonURL)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ModManagerError.invalidArchive("\(jsonURL.lastPathComponent) must contain a JSON object.")
            }
            let metadata = root["metadata"] as? [String: Any] ?? root
            let authorValue = metadata["author"]
            let authors = authorValue as? [String]
                ?? (authorValue as? String).map { [$0] }
                ?? []
            var neededFiles: [String: String] = [:]
            for entry in root["neededFiles"] as? [[String: String]] ?? [] {
                guard let path = entry["file"], let checksum = entry["checksum"] else { continue }
                neededFiles[normalizedMetadataPath(path)] = checksum.lowercased()
            }
            return (
                metadata["name"] as? String ?? "Untitled Mod",
                metadata["version"] as? String ?? "",
                root["deltaruneTargetVersion"] as? String,
                metadata["description"] as? String ?? "",
                authors,
                neededFiles
            )
        }

        guard let tomlURL else {
            throw ModManagerError.invalidArchive("Missing Deltamod/G3M metadata.")
        }
        let contents = try String(contentsOf: tomlURL, encoding: .utf8)
        var neededFiles: [String: String] = [:]
        let neededPattern = #"(?m)^\s*file\s*=\s*"([^"]+)"\s*\n\s*checksum\s*=\s*"([0-9a-fA-F]+)""#
        let neededRegex = try NSRegularExpression(pattern: neededPattern)
        let fullRange = NSRange(contents.startIndex..., in: contents)
        for match in neededRegex.matches(in: contents, range: fullRange) {
            guard let pathRange = Range(match.range(at: 1), in: contents),
                  let checksumRange = Range(match.range(at: 2), in: contents) else {
                continue
            }
            neededFiles[normalizedMetadataPath(String(contents[pathRange]))] =
                String(contents[checksumRange]).lowercased()
        }
        let authors = tomlArray("author", in: contents)
        return (
            tomlString("name", in: contents) ?? "Untitled Mod",
            tomlString("version", in: contents) ?? "",
            nil,
            tomlString("description", in: contents) ?? "",
            authors,
            neededFiles
        )
    }

    private static func tomlString(_ key: String, in contents: String) -> String? {
        let pattern = #"(?m)^\s*\#(NSRegularExpression.escapedPattern(for: key))\s*=\s*"((?:\\.|[^"\\])*)""#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: contents, range: NSRange(contents.startIndex..., in: contents)),
              let valueRange = Range(match.range(at: 1), in: contents) else {
            return nil
        }
        return String(contents[valueRange])
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func tomlArray(_ key: String, in contents: String) -> [String] {
        let pattern = #"(?m)^\s*\#(NSRegularExpression.escapedPattern(for: key))\s*=\s*\[([^\]]*)\]"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: contents, range: NSRange(contents.startIndex..., in: contents)),
              let valuesRange = Range(match.range(at: 1), in: contents),
              let valueExpression = try? NSRegularExpression(pattern: #""((?:\\.|[^"\\])*)""#) else {
            return []
        }
        let values = contents[valuesRange]
        return valueExpression.matches(in: String(values), range: NSRange(values.startIndex..., in: values))
            .compactMap { match in
                guard let range = Range(match.range(at: 1), in: values) else { return nil }
                return String(values[range])
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            }
    }

    private static func normalizedMetadataPath(_ path: String) -> String {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        return normalized.replacingOccurrences(
            of: #"^(?:\./)+"#,
            with: "",
            options: .regularExpression
        )
    }

    private static func parseXML(_ url: URL) throws -> [PatchSpec] {
        let data = try Data(contentsOf: url)
        guard let contents = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .utf16) else {
            throw ModManagerError.invalidArchive("modding.xml must be UTF-8 or UTF-16 text.")
        }
        let withoutDeclaration = removingXMLDeclaration(from: contents)
        let contentsToParse = [withoutDeclaration, escapingBareAmpersands(in: withoutDeclaration)]
        var lastFailure: (line: Int, column: Int, detail: String)?
        for candidate in contentsToParse where lastFailure == nil || candidate != withoutDeclaration {
            let delegate = ModXMLDelegate()
            let fragment = Data("<modding>\(candidate)</modding>".utf8)
            let parser = XMLParser(data: fragment)
            parser.shouldResolveExternalEntities = false
            parser.delegate = delegate
            if parser.parse() {
                return delegate.specs
            }
            lastFailure = (
                line: max(1, parser.lineNumber - 1),
                column: parser.columnNumber,
                detail: parser.parserError?.localizedDescription ?? "unknown XML error"
            )
        }
        let failure = lastFailure
        throw ModManagerError.invalidArchive(
            "modding.xml is invalid at line \(failure?.line ?? 1), column \(failure?.column ?? 1): \(failure?.detail ?? "unknown XML error")"
        )
    }

    private static func escapingBareAmpersands(in text: String) -> String {
        text.replacingOccurrences(
            of: #"&(?!#(?:[0-9]+|[xX][0-9a-fA-F]+);|amp;|lt;|gt;|quot;|apos;)"#,
            with: "&amp;",
            options: .regularExpression
        )
    }

    private static func removingXMLDeclaration(from contents: String) -> String {
        let withoutLeadingWhitespace = contents.drop(while: { $0.isWhitespace || $0 == "\u{FEFF}" })
        var result = String(withoutLeadingWhitespace)
        guard result.hasPrefix("<?xml"),
              result.dropFirst(5).first?.isWhitespace == true,
              let declarationEnd = result.range(of: "?>") else {
            return result
        }
        result.removeSubrange(result.startIndex..<declarationEnd.upperBound)
        return result
    }

    private static func chapterNumber(fromWindowsTarget target: String) throws -> Int {
        guard let match = target.range(of: #"^chapter([1-5])_windows/data\.win$"#, options: .regularExpression),
              let chapter = Int(target[match].split(separator: "_")[0].dropFirst("chapter".count)) else {
            throw ModManagerError.unsupportedPatch(target)
        }
        return chapter
    }

    private static func mapOverrideTarget(_ target: String) -> String? {
        if target.hasPrefix("mus/") {
            return target
        }
        if target.range(of: #"^chapter[1-5]_windows/.+"#, options: .regularExpression) != nil {
            let components = target.split(separator: "/", maxSplits: 1)
            guard components.count == 2 else { return nil }
            if components[1].lowercased().hasSuffix(".dll") { return nil }
            let chapter = components[0].replacingOccurrences(of: "_windows", with: "_mac")
            let file = components[1] == "data.win" ? "game.ios" : String(components[1])
            return "\(chapter)/\(file)"
        }
        if target == "data.win" {
            return "game.ios"
        }
        return nil
    }

    private static func macReplacementPath(forWindowsTarget target: String) -> String? {
        guard target.range(
            of: #"^chapter[1-5]_windows/.+\.dll$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil else {
            return nil
        }
        let chapterPath = target.replacingOccurrences(
            of: "_windows/",
            with: "_mac/",
            options: [.caseInsensitive]
        )
        let dylibPath = (chapterPath as NSString).deletingPathExtension + ".dylib"
        return try? SafePaths.relative(dylibPath)
    }

    private static func runXdelta(executable: URL, source: URL, patch: URL, output: URL) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-d", "-s", source.path, patch.path, output.path]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw ModManagerError.patchFailed(error.localizedDescription)
        }
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: output.path) else {
            let message = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "The patch did not apply."
            if message.localizedCaseInsensitiveContains("XD3_INVALID_INPUT") ||
                message.localizedCaseInsensitiveContains("source likely does not match") {
                throw ModManagerError.patchFailed(
                    "The selected chapter's backed-up data.win doesn't match this patch. Check the chapter selection and game version."
                )
            }
            throw ModManagerError.patchFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

private enum BPSPatcher {
    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 {
            crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1
        }
        return crc
    }

    static func apply(source sourceURL: URL, patch patchURL: URL, output outputURL: URL) throws {
        let source = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        let patch = try Data(contentsOf: patchURL, options: .mappedIfSafe)
        guard patch.count >= 19 else {
            throw ModManagerError.patchFailed("The BPS patch is truncated.")
        }
        var output = Data()
        try patch.withUnsafeBytes { patchRaw in
            try source.withUnsafeBytes { sourceRaw in
                let patchBytes = patchRaw.bindMemory(to: UInt8.self)
                let sourceBytes = sourceRaw.bindMemory(to: UInt8.self)
                guard patchBytes[0..<4].elementsEqual([0x42, 0x50, 0x53, 0x31]) else {
                    throw ModManagerError.patchFailed("The patch is not a valid BPS1 file.")
                }

                let sourceCRC = readUInt32(patchBytes, at: patch.count - 12)
                let targetCRC = readUInt32(patchBytes, at: patch.count - 8)
                let patchCRC = readUInt32(patchBytes, at: patch.count - 4)
                guard crc32(patchBytes, range: 0..<(patch.count - 4)) == patchCRC else {
                    throw ModManagerError.patchFailed("The BPS patch checksum failed; re-download the mod.")
                }
                guard crc32(sourceBytes, range: 0..<source.count) == sourceCRC else {
                    throw ModManagerError.patchFailed(
                        "This BPS patch was made for a different version of the backed-up game file."
                    )
                }

                var position = 4
                let commandLimit = patch.count - 12
                let expectedSourceSize = try readNumber(patchBytes, position: &position, limit: commandLimit)
                let targetSizeValue = try readNumber(patchBytes, position: &position, limit: commandLimit)
                let metadataSize = try readNumber(patchBytes, position: &position, limit: commandLimit)
                guard expectedSourceSize == UInt64(source.count),
                      targetSizeValue <= 2_000_000_000,
                      metadataSize <= UInt64(commandLimit - position) else {
                    throw ModManagerError.patchFailed("The BPS patch sizes don't match this game file.")
                }
                position += Int(metadataSize)
                let targetSize = Int(targetSizeValue)
                output = Data(count: targetSize)
                try output.withUnsafeMutableBytes { outputRaw in
                    let outputBytes = outputRaw.bindMemory(to: UInt8.self)
                    var written = 0
                    var sourceRelative: Int64 = 0
                    var targetRelative: Int64 = 0

                    while position < commandLimit {
                        let command = try readNumber(patchBytes, position: &position, limit: commandLimit)
                        let commandType = command & 3
                        let (lengthValue, lengthOverflow) = (command >> 2).addingReportingOverflow(1)
                        guard !lengthOverflow, lengthValue <= UInt64(Int.max),
                              Int(lengthValue) <= targetSize - written else {
                            throw ModManagerError.patchFailed("The BPS patch writes beyond its declared output size.")
                        }
                        let length = Int(lengthValue)
                        switch commandType {
                        case 0:
                            guard length <= source.count, written <= source.count - length else {
                                throw ModManagerError.patchFailed("The BPS patch reads beyond the source file.")
                            }
                            for index in 0..<length {
                                outputBytes[written + index] = sourceBytes[written + index]
                            }
                        case 1:
                            guard length <= commandLimit - position else {
                                throw ModManagerError.patchFailed("The BPS patch has truncated target data.")
                            }
                            for index in 0..<length {
                                outputBytes[written + index] = patchBytes[position + index]
                            }
                            position += length
                        case 2:
                            let encodedDelta = try readNumber(patchBytes, position: &position, limit: commandLimit)
                            sourceRelative = try addRelative(sourceRelative, encodedDelta)
                            guard sourceRelative >= 0,
                                  sourceRelative <= Int64(source.count),
                                  Int64(length) <= Int64(source.count) - sourceRelative else {
                                throw ModManagerError.patchFailed("The BPS source-copy range is invalid.")
                            }
                            for index in 0..<length {
                                outputBytes[written + index] = sourceBytes[Int(sourceRelative) + index]
                            }
                            sourceRelative += Int64(length)
                        default:
                            let encodedDelta = try readNumber(patchBytes, position: &position, limit: commandLimit)
                            targetRelative = try addRelative(targetRelative, encodedDelta)
                            guard targetRelative >= 0, targetRelative < Int64(written) else {
                                throw ModManagerError.patchFailed("The BPS target-copy range is invalid.")
                            }
                            for index in 0..<length {
                                outputBytes[written + index] = outputBytes[Int(targetRelative) + index]
                            }
                            targetRelative += Int64(length)
                        }
                        written += length
                    }
                    guard written == targetSize,
                          crc32(
                            UnsafeBufferPointer(start: outputBytes.baseAddress, count: outputBytes.count),
                            range: 0..<targetSize
                          ) == targetCRC else {
                        throw ModManagerError.patchFailed("The BPS output checksum failed.")
                    }
                }
            }
        }
        do {
            try output.write(to: outputURL, options: .atomic)
        } catch {
            throw ModManagerError.patchFailed(error.localizedDescription)
        }
    }

    private static func readNumber(
        _ bytes: UnsafeBufferPointer<UInt8>,
        position: inout Int,
        limit: Int
    ) throws -> UInt64 {
        var value: UInt64 = 0
        var shift: UInt64 = 1
        while position < limit {
            let byte = bytes[position]
            position += 1
            let (part, multiplyOverflow) = UInt64(byte & 0x7F).multipliedReportingOverflow(by: shift)
            let (sum, addOverflow) = value.addingReportingOverflow(part)
            guard !multiplyOverflow, !addOverflow else {
                throw ModManagerError.patchFailed("The BPS patch contains an invalid number.")
            }
            value = sum
            if byte & 0x80 != 0 {
                return value
            }
            guard shift <= UInt64.max >> 7 else {
                throw ModManagerError.patchFailed("The BPS patch contains an invalid number.")
            }
            shift <<= 7
            let (adjusted, adjustmentOverflow) = value.addingReportingOverflow(shift)
            guard !adjustmentOverflow else {
                throw ModManagerError.patchFailed("The BPS patch contains an invalid number.")
            }
            value = adjusted
        }
        throw ModManagerError.patchFailed("The BPS patch contains a truncated number.")
    }

    private static func addRelative(_ current: Int64, _ encodedDelta: UInt64) throws -> Int64 {
        let magnitude = encodedDelta >> 1
        guard magnitude <= UInt64(Int64.max) else {
            throw ModManagerError.patchFailed("The BPS patch contains an invalid copy offset.")
        }
        let delta = Int64(magnitude) * (encodedDelta & 1 == 1 ? -1 : 1)
        let (result, overflow) = current.addingReportingOverflow(delta)
        guard !overflow else {
            throw ModManagerError.patchFailed("The BPS patch contains an invalid copy offset.")
        }
        return result
    }

    private static func readUInt32(_ bytes: UnsafeBufferPointer<UInt8>, at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) |
            (UInt32(bytes[offset + 1]) << 8) |
            (UInt32(bytes[offset + 2]) << 16) |
            (UInt32(bytes[offset + 3]) << 24)
    }

    private static func crc32(_ bytes: UnsafeBufferPointer<UInt8>, range: Range<Int>) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for index in range {
            crc = crcTable[Int((crc ^ UInt32(bytes[index])) & 0xFF)] ^ (crc >> 8)
        }
        return ~crc
    }
}

private struct ArchiveInspection: Decodable {
    var hasInfo: Bool
    var hasModding: Bool
    var hasG3MConfig: Bool
    var hasLegacyG3MMetadata: Bool
}

private final class ModXMLDelegate: NSObject, XMLParserDelegate {
    var specs: [PatchSpec] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard elementName == "patch",
              let type = attributeDict["type"],
              let patch = attributeDict["patch"],
              let target = attributeDict["to"] else {
            return
        }
        specs.append(PatchSpec(type: type, patch: patch, target: target))
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
