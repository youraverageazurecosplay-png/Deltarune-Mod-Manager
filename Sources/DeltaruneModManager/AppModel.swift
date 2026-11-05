import AppKit
import Combine
import Foundation

private struct ActiveRunJournal: Codable {
    var gameAppPath: String
    var resourcePath: String
    var backupDirectory: String
    var files: [ActiveRunFile]
    var game: ModGame? = nil
}

private struct ActiveRunFile: Codable {
    var resourcePath: String
    var backupPath: String
    var hadOriginal: Bool
}

enum DownloadQueueStatus: String {
    case queued = "Queued"
    case downloading = "Downloading"
    case installing = "Installing"
    case waitingForInput = "Needs patch selection"
    case completed = "Completed"
    case failed = "Failed"
    case cancelled = "Cancelled"
}

struct DownloadQueueEntry: Identifiable {
    let id: UUID
    let title: String
    let filename: String
    var status: DownloadQueueStatus
    var progress: Double?
    var failureMessage: String?
}

private enum GameBananaQueueOperation {
    case install(
        file: GameBananaFile,
        modName: String,
        iconURLs: [URL],
        game: ModGame,
        modID: Int?
    )
    case update(
        instanceID: String,
        modID: Int,
        file: GameBananaFile,
        catalog: GameBananaCatalog
    )
}

private struct QueuedGameBananaDownload {
    let entryID: UUID
    let operation: GameBananaQueueOperation
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var settings: AppSettings?
    @Published private(set) var instances: [ModInstance] = []
    @Published var isBusy = false
    @Published private(set) var isDownloading = false
    @Published private(set) var downloadProgress: Double?
    @Published private(set) var isGameSessionActive = false
    @Published private(set) var activeInstanceID: String?
    @Published var statusMessage = ""
    @Published var errorMessage: String?
    @Published var setupWindowsFolder: URL?
    @Published var setupGameApp: URL?
    @Published var manualPatchSelection: ManualPatchSelection?
    @Published var isCheckingForUpdates = false
    @Published private(set) var availableModUpdates: [String: GameBananaFile] = [:]
    @Published private(set) var isCheckingModUpdates = false
    @Published private(set) var downloadQueue: [DownloadQueueEntry] = []

    var recentlyPlayedInstances: [ModInstance] {
        ModInstance.orderedByLastPlayed(instances)
    }

    var isCLIInstalled: Bool {
        FileManager.default.fileExists(atPath: Self.cliInstallURL.path)
    }

    private var runTimer: Timer?
    private var launchedProcessID: pid_t?
    private var appTerminationObserver: NSObjectProtocol?
    private var appLaunchObserver: NSObjectProtocol?
    private var isRestoringRun = false
    private var launchedGame: ModGame = .deltarune
    private var iconRefreshInProgress = Set<String>()
    private var queuedGameBananaDownloads: [QueuedGameBananaDownload] = []
    private var downloadQueueTask: Task<Void, Never>?
    private var activeDownloadQueueEntryID: UUID?

    init() {
        try? FileManager.default.createDirectory(at: AppPaths.support, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: AppPaths.instances, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: AppPaths.downloads, withIntermediateDirectories: true)
        Self.removeExpiredDownloads()
        settings = Self.loadSettings()
        setupGameApp = settings.map { URL(fileURLWithPath: $0.gameAppPath) } ?? GameAppLocator.defaultApp()
        loadInstances()
        if let settings {
            isGameSessionActive = Self.gameIsRunning(
                at: URL(fileURLWithPath: settings.gameAppPath),
                game: .deltarune
            )
        }
        appLaunchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor [weak self] in
                guard let app, let self,
                      app.bundleURL?.standardizedFileURL.path ==
                        self.gameAppURL(for: .deltarune).standardizedFileURL.path else {
                    return
                }
                self.launchedGame = .deltarune
                self.isGameSessionActive = true
                self.activeInstanceID = nil
                self.statusMessage = "DELTARUNE is running. Close it before launching another instance."
            }
        }
        appTerminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor [weak self] in
                guard let app, let self else {
                    return
                }
                let game = self.launchedGame
                let expectedPath = self.gameAppURL(for: game).standardizedFileURL.path
                let isTrackedGame = self.launchedProcessID == app.processIdentifier ||
                    app.bundleURL?.standardizedFileURL.path == expectedPath
                if isTrackedGame && !Self.gameIsRunning(at: self.gameAppURL(for: game), game: game) {
                    self.restoreAfterGameExit()
                }
            }
        }
        recoverPreviousRunIfNeeded()
    }

    deinit {
        runTimer?.invalidate()
        if let appTerminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appTerminationObserver)
        }
        if let appLaunchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appLaunchObserver)
        }
    }

    func completeSetup() {
        guard let windowsFolder = setupWindowsFolder, let gameApp = setupGameApp else {
            errorMessage = "Choose both the Windows game folder and the installed DELTARUNE app."
            return
        }
        let supportRoot = AppPaths.support
        isBusy = true
        statusMessage = "Backing up Windows chapter data..."
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let resources = try GameAppLocator.resources(for: gameApp)
                let backup = supportRoot.appendingPathComponent("WindowsBackup", isDirectory: true)
                try WindowsBackup.backup(from: windowsFolder, to: backup)
                let settings = AppSettings(
                    windowsBackupPath: backup.path,
                    gameAppPath: gameApp.path,
                    windowsSourcePath: windowsFolder.path
                )
                let data = try JSONEncoder.pretty.encode(settings)
                try data.write(to: AppPaths.settings, options: .atomic)
                DispatchQueue.main.async {
                    self.settings = settings
                    self.setupWindowsFolder = nil
                    self.statusMessage = "Setup complete. Windows chapter files are backed up."
                    self.isBusy = false
                    _ = resources
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                    self.statusMessage = ""
                    self.isBusy = false
                }
            }
        }
    }

    func updateGameApp(to gameApp: URL) {
        guard !isBusy else { return }
        guard let current = settings else {
            errorMessage = "Complete setup before changing the game app."
            return
        }
        guard !Self.gameIsRunning(at: URL(fileURLWithPath: current.gameAppPath)) else {
            errorMessage = ModManagerError.gameAlreadyRunning.localizedDescription
            return
        }
        guard !FileManager.default.fileExists(atPath: Self.journalURL.path) else {
            errorMessage = ModManagerError.activeRun.localizedDescription
            return
        }
        do {
            _ = try GameAppLocator.resources(for: gameApp)
            var updated = current
            updated.gameAppPath = gameApp.path
            try JSONEncoder.pretty.encode(updated).write(to: AppPaths.settings, options: .atomic)
            settings = updated
            setupGameApp = gameApp
            statusMessage = "Updated Mac game app location."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateWindowsBackup(from windowsFolder: URL) {
        guard !isBusy else { return }
        guard let current = settings else {
            errorMessage = "Complete setup before changing the Windows backup."
            return
        }
        guard !Self.gameIsRunning(at: URL(fileURLWithPath: current.gameAppPath)) else {
            errorMessage = ModManagerError.gameAlreadyRunning.localizedDescription
            return
        }
        guard !FileManager.default.fileExists(atPath: Self.journalURL.path) else {
            errorMessage = ModManagerError.activeRun.localizedDescription
            return
        }

        let supportRoot = AppPaths.support
        let newBackup = supportRoot.appendingPathComponent(
            "WindowsBackup-\(UUID().uuidString)",
            isDirectory: true
        )
        isBusy = true
        statusMessage = "Backing up Windows chapter data..."
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try WindowsBackup.backup(from: windowsFolder, to: newBackup)
                var updated = current
                updated.windowsBackupPath = newBackup.path
                updated.windowsSourcePath = windowsFolder.path
                try JSONEncoder.pretty.encode(updated).write(to: AppPaths.settings, options: .atomic)
                DispatchQueue.main.async {
                    self.settings = updated
                    self.statusMessage = "Windows game files backed up."
                    self.isBusy = false
                    Self.removePreviousWindowsBackup(at: URL(fileURLWithPath: current.windowsBackupPath))
                }
            } catch {
                do {
                    if FileManager.default.fileExists(atPath: newBackup.path) {
                        try FileManager.default.removeItem(at: newBackup)
                    }
                } catch {
                    NSLog("Could not remove incomplete Windows backup %@: %@", newBackup.path, error.localizedDescription)
                }
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                    self.statusMessage = ""
                    self.isBusy = false
                }
            }
        }
    }

    func showWindowsBackupInFinder() {
        guard let settings else { return }
        NSWorkspace.shared.activateFileViewerSelecting([
            URL(fileURLWithPath: settings.windowsBackupPath, isDirectory: true)
        ])
    }

    func configureUndertale(app: URL, folder: URL) {
        guard !isBusy else { return }
        guard let current = settings else {
            errorMessage = "Complete DELTARUNE setup before configuring Undertale."
            return
        }
        guard app.pathExtension.lowercased() == "app",
              (try? GameAppLocator.undertaleResources(for: app)) != nil else {
            errorMessage = "Choose the Steam-installed Undertale.app containing Contents/Resources/game.ios."
            return
        }
        guard !Self.gameIsRunning(at: app, game: .undertale) else {
            errorMessage = ModManagerError.gameAlreadyRunning.localizedDescription
            return
        }
        guard !FileManager.default.fileExists(atPath: Self.journalURL.path) else {
            errorMessage = ModManagerError.activeRun.localizedDescription
            return
        }

        let backup = AppPaths.support.appendingPathComponent(
            "UndertaleBackup-\(UUID().uuidString)",
            isDirectory: true
        )
        isBusy = true
        statusMessage = "Backing up the Windows Undertale data.win source..."
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try UndertaleBackup.backup(from: folder, to: backup)
                var updated = current
                updated.undertaleAppPath = app.path
                updated.undertaleGameFolderPath = folder.path
                updated.undertaleBackupPath = backup.path
                try JSONEncoder.pretty.encode(updated).write(to: AppPaths.settings, options: .atomic)
                DispatchQueue.main.async {
                    self.settings = updated
                    self.statusMessage = "Windows Undertale data.win source backed up."
                    self.isBusy = false
                    if let previous = current.undertaleBackupPath {
                        Self.removeManagedBackup(at: URL(fileURLWithPath: previous), prefix: "UndertaleBackup")
                    }
                }
            } catch {
                do {
                    if FileManager.default.fileExists(atPath: backup.path) {
                        try FileManager.default.removeItem(at: backup)
                    }
                } catch {
                    NSLog("Could not remove incomplete Undertale backup %@: %@", backup.path, error.localizedDescription)
                }
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                    self.statusMessage = ""
                    self.isBusy = false
                }
            }
        }
    }

    func updateUndertaleApp(to app: URL) {
        guard !isBusy else { return }
        guard app.pathExtension.lowercased() == "app",
              (try? GameAppLocator.undertaleResources(for: app)) != nil else {
            errorMessage = "Choose the Steam-installed Undertale.app containing Contents/Resources/game.ios."
            return
        }
        guard var updated = settings else {
            errorMessage = "Complete DELTARUNE setup before configuring Undertale."
            return
        }
        guard !Self.gameIsRunning(
            at: URL(fileURLWithPath: updated.undertaleAppPath ?? app.path),
            game: .undertale
        ) else {
            errorMessage = ModManagerError.gameAlreadyRunning.localizedDescription
            return
        }
        guard !FileManager.default.fileExists(atPath: Self.journalURL.path) else {
            errorMessage = ModManagerError.activeRun.localizedDescription
            return
        }
        updated.undertaleAppPath = app.path
        do {
            try JSONEncoder.pretty.encode(updated).write(to: AppPaths.settings, options: .atomic)
            settings = updated
            statusMessage = "Updated Undertale Mac game app."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func isConfigured(for game: ModGame) -> Bool {
        guard let settings else { return false }
        switch game {
        case .deltarune:
            return true
        case .undertale:
            guard let app = settings.undertaleAppPath,
                  let folder = settings.undertaleGameFolderPath,
                  let backup = settings.undertaleBackupPath else {
                return false
            }
            return (try? GameAppLocator.undertaleResources(for: URL(fileURLWithPath: app))) != nil &&
                FileManager.default.fileExists(atPath: URL(fileURLWithPath: folder).appendingPathComponent("data.win").path) &&
                FileManager.default.fileExists(atPath: URL(fileURLWithPath: backup).appendingPathComponent("data.win").path)
        }
    }

    private func backupPath(for game: ModGame, settings: AppSettings) -> String? {
        switch game {
        case .deltarune:
            settings.windowsBackupPath
        case .undertale:
            settings.undertaleBackupPath
        }
    }

    private func gameAppURL(for game: ModGame) -> URL {
        let path: String
        switch game {
        case .deltarune:
            path = settings?.gameAppPath ?? ""
        case .undertale:
            path = settings?.undertaleAppPath ?? ""
        }
        return URL(fileURLWithPath: path)
    }

    func checkForUpdates() {
        guard !isBusy, !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        statusMessage = "Checking for updates..."
        Task {
            defer { isCheckingForUpdates = false }
            do {
                let release = try await AppUpdateService.latestRelease()
                let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.4"
                if AppUpdateService.isNewer(release.tagName, than: currentVersion) {
                    statusMessage = "Version \(release.tagName) is available. Opening the release download page..."
                    guard NSWorkspace.shared.open(release.htmlURL) else {
                        throw AppUpdateError.badResponse
                    }
                } else {
                    statusMessage = "You're up to date (version \(currentVersion))."
                }
            } catch {
                statusMessage = ""
                errorMessage = error.localizedDescription
            }
        }
    }

    func checkForModUpdates(catalog: GameBananaCatalog) {
        guard !isCheckingModUpdates, !isBusy else { return }
        isCheckingModUpdates = true
        availableModUpdates = [:]
        Task {
            defer { isCheckingModUpdates = false }
            var failure: String?
            for instance in instances {
                guard let modID = instance.gameBananaModID,
                      let installedFileID = instance.gameBananaFileID else {
                    continue
                }
                do {
                    let details = try await catalog.details(forModID: modID)
                    guard let latest = GameBananaReleasePicker.updateCandidate(
                        from: details.files,
                        for: instance.targetGame,
                        installedFileID: installedFileID,
                        installedFileDateAdded: instance.gameBananaFileDateAdded
                    ) else {
                        continue
                    }
                    availableModUpdates[instance.id] = latest
                } catch {
                    failure = "Couldn't check for updates to \(instance.name): \(GameBananaError.message(for: error))"
                }
            }
            if let failure {
                errorMessage = failure
            }
        }
    }

    func updateMod(_ instance: ModInstance, using file: GameBananaFile, catalog: GameBananaCatalog) {
        guard let current = instances.first(where: { $0.id == instance.id }),
              let modID = current.gameBananaModID,
              let settings,
              backupPath(for: current.targetGame, settings: settings) != nil else {
            errorMessage = "This mod update is no longer available or its game backup is missing."
            return
        }
        enqueueDownload(
            title: current.name,
            file: file,
            operation: .update(
                instanceID: current.id,
                modID: modID,
                file: file,
                catalog: catalog
            )
        )
    }

    func updateAllMods(catalog: GameBananaCatalog) {
        let pending = instances.compactMap { instance -> (ModInstance, GameBananaFile)? in
            guard let file = availableModUpdates[instance.id] else { return nil }
            return (instance, file)
        }
        guard !pending.isEmpty else { return }
        guard let settings else {
            errorMessage = "Complete setup before updating mods."
            return
        }
        var failures: [String] = []
        for (instance, file) in pending {
            guard let modID = instance.gameBananaModID,
                  backupPath(for: instance.targetGame, settings: settings) != nil else {
                failures.append("\(instance.name): missing GameBanana source or game backup.")
                continue
            }
            enqueueDownload(
                title: instance.name,
                file: file,
                operation: .update(
                    instanceID: instance.id,
                    modID: modID,
                    file: file,
                    catalog: catalog
                )
            )
        }
        if !failures.isEmpty {
            errorMessage = "Couldn't queue some updates:\n" + failures.joined(separator: "\n")
        }
    }

    func removeQueuedDownload(_ id: UUID) {
        guard downloadQueue.first(where: { $0.id == id })?.status == .queued else { return }
        downloadQueue.removeAll { $0.id == id }
        queuedGameBananaDownloads.removeAll { $0.entryID == id }
    }

    func clearFinishedDownloads() {
        let finishedIDs = Set(downloadQueue.filter {
            [.completed, .failed, .cancelled].contains($0.status)
        }.map(\.id))
        downloadQueue.removeAll { finishedIDs.contains($0.id) }
    }

    private func enqueueDownload(
        title: String,
        file: GameBananaFile,
        operation: GameBananaQueueOperation
    ) {
        let id = UUID()
        downloadQueue.append(DownloadQueueEntry(
            id: id,
            title: title,
            filename: file.name,
            status: .queued
        ))
        queuedGameBananaDownloads.append(QueuedGameBananaDownload(entryID: id, operation: operation))
        startDownloadQueueIfNeeded()
    }

    private func startDownloadQueueIfNeeded() {
        guard downloadQueueTask == nil, manualPatchSelection == nil else { return }
        downloadQueueTask = Task { @MainActor in
            while !Task.isCancelled, let next = queuedGameBananaDownloads.first {
                while (isBusy || isGameSessionActive) && !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                guard !Task.isCancelled else { break }
                guard queuedGameBananaDownloads.first?.entryID == next.entryID else { continue }
                guard let entryIndex = downloadQueue.firstIndex(where: { $0.id == next.entryID }) else {
                    queuedGameBananaDownloads.removeFirst()
                    continue
                }
                queuedGameBananaDownloads.removeFirst()
                activeDownloadQueueEntryID = next.entryID
                downloadQueue[entryIndex].status = .downloading
                downloadQueue[entryIndex].progress = nil
                isBusy = true
                statusMessage = "Downloading \(downloadQueue[entryIndex].title)..."

                do {
                    let needsInput = try await performQueuedDownload(next.operation)
                    if needsInput {
                        downloadQueue[entryIndex].status = .waitingForInput
                        isBusy = false
                        activeDownloadQueueEntryID = nil
                        downloadQueueTask = nil
                        return
                    }
                    downloadQueue[entryIndex].status = .completed
                } catch {
                    let message = GameBananaError.message(for: error)
                    downloadQueue[entryIndex].status = .failed
                    downloadQueue[entryIndex].failureMessage = message
                    errorMessage = message
                }
                downloadQueue[entryIndex].progress = nil
                activeDownloadQueueEntryID = nil
                isDownloading = false
                downloadProgress = nil
                isBusy = false
            }
            downloadQueueTask = nil
            if !queuedGameBananaDownloads.isEmpty {
                startDownloadQueueIfNeeded()
            }
        }
    }

    private func performQueuedDownload(_ operation: GameBananaQueueOperation) async throws -> Bool {
        switch operation {
        case let .install(file, modName, iconURLs, game, modID):
            return try await performQueuedInstall(
                file,
                modName: modName,
                iconURLs: iconURLs,
                game: game,
                modID: modID
            )
        case let .update(instanceID, modID, file, catalog):
            guard let instance = instances.first(where: { $0.id == instanceID }),
                  let settings,
                  let backupPath = backupPath(for: instance.targetGame, settings: settings) else {
                throw ModManagerError.invalidArchive("The mod or its game backup is no longer available.")
            }
            statusMessage = "Updating \(instance.name)..."
            updateActiveQueueEntry(status: .downloading)
            let updated = try await buildAndReplaceInstance(
                instance,
                modID: modID,
                file: file,
                backupPath: backupPath,
                catalog: catalog
            )
            if let index = instances.firstIndex(where: { $0.id == updated.id }) {
                instances[index] = updated
            }
            availableModUpdates.removeValue(forKey: updated.id)
            statusMessage = "Updated \(updated.name) to \(file.releaseTitle)."
            return false
        }
    }

    private func updateActiveQueueEntry(
        status: DownloadQueueStatus? = nil,
        progress: Double? = nil
    ) {
        guard let activeDownloadQueueEntryID,
              let index = downloadQueue.firstIndex(where: { $0.id == activeDownloadQueueEntryID }) else {
            return
        }
        if let status {
            downloadQueue[index].status = status
        }
        downloadQueue[index].progress = progress
    }

    private func updateQueueEntry(_ id: UUID, status: DownloadQueueStatus) {
        guard let index = downloadQueue.firstIndex(where: { $0.id == id }) else { return }
        downloadQueue[index].status = status
    }

    private func buildAndReplaceInstance(
        _ instance: ModInstance,
        modID: Int,
        file: GameBananaFile,
        backupPath: String,
        catalog: GameBananaCatalog
    ) async throws -> ModInstance {
        let details = try await catalog.details(forModID: modID)
        let archive = try await downloadGameBananaFile(file)
        defer {
            if let warning = Self.removeDownloadedArchive(archive) {
                NSLog("GameBanana update download cleanup failed: %@", warning)
            }
        }
        updateActiveQueueEntry(status: .installing)
        let kind = try await Task.detached(priority: .userInitiated) {
            try DeltaModBuilder.archiveKind(archive)
        }.value
        let result: ModBuildResult
        if instance.targetGame == .deltarune, kind != .other {
            result = try await Task.detached(priority: .userInitiated) {
                try DeltaModBuilder.build(
                    archive: archive,
                    windowsBackup: URL(fileURLWithPath: backupPath),
                    supportRoot: AppPaths.support
                )
            }.value
        } else {
            let options = try await Task.detached(priority: .userInitiated) {
                try DeltaModBuilder.manualPatchOptions(archive: archive, supportRoot: AppPaths.support)
            }.value
            let assignments = try Self.updateAssignments(for: options, instance: instance)
            result = try await Task.detached(priority: .userInitiated) {
                try DeltaModBuilder.buildManual(
                    archive: archive,
                    assignments: assignments,
                    modName: details.name,
                    windowsBackup: URL(fileURLWithPath: backupPath),
                    supportRoot: AppPaths.support,
                    game: instance.targetGame
                )
            }.value
        }
        var updated = result.instance
        updated.id = instance.id
        updated.name = instance.name
        updated.game = instance.targetGame
        updated.gameBananaModID = modID
        updated.gameBananaFileID = file.id
        updated.gameBananaFileDateAdded = file.dateAdded
        updated.lastPlayedAt = instance.lastPlayedAt
        updated = await addingGameBananaIconIfNeeded(
            to: ModBuildResult(instance: updated, directory: result.directory),
            from: details.imageURLs
        ).instance
        do {
            return try await Task.detached(priority: .userInitiated) {
                try Self.replaceUpdatedInstance(
                    instance,
                    with: ModBuildResult(instance: updated, directory: result.directory)
                )
            }.value
        } catch {
            if FileManager.default.fileExists(atPath: result.directory.path) {
                do {
                    try FileManager.default.removeItem(at: result.directory)
                } catch {
                    NSLog("Could not remove failed update build %@: %@", result.directory.path, error.localizedDescription)
                }
            }
            throw error
        }
    }

    nonisolated private static func updateAssignments(
        for options: [ManualPatchOption],
        instance: ModInstance
    ) throws -> [ManualPatchAssignment] {
        guard !options.isEmpty else { throw ModManagerError.missingManualPatch }
        var assignments: [ManualPatchAssignment] = []
        for option in options {
            let target: ManualPatchTarget?
            if instance.targetGame == .undertale {
                target = options.count == 1 && option.kind != .dylib ? .undertale : nil
            } else if option.suggestsLauncher {
                target = .launcher
            } else if let chapter = option.suggestedChapter {
                target = .chapter(chapter)
            } else {
                let dataTargets = instance.payloads.compactMap { payload -> ManualPatchTarget? in
                    if payload.resourcePath == "game.ios" { return .launcher }
                    guard let match = payload.resourcePath.range(
                        of: #"^chapter([1-5])_mac/game\.ios$"#,
                        options: .regularExpression
                    ) else { return nil }
                    let chapterText = payload.resourcePath[match]
                        .dropFirst("chapter".count)
                        .prefix(1)
                    return Int(chapterText).map(ManualPatchTarget.chapter)
                }
                target = dataTargets.count == 1 ? dataTargets[0] : nil
            }
            guard let target, option.kind != .dylib else {
                throw ModManagerError.unsupportedPatch(
                    "The update release doesn't identify a safe game-data target for \(option.path)."
                )
            }
            assignments.append(ManualPatchAssignment(
                patchPath: option.path,
                target: target,
                kind: option.kind
            ))
        }
        return assignments
    }

    nonisolated private static func replaceUpdatedInstance(
        _ current: ModInstance,
        with build: ModBuildResult
    ) throws -> ModInstance {
        let fileManager = FileManager.default
        let oldDirectory = AppPaths.instanceDirectory(current.id)
        let customRoot = oldDirectory.appendingPathComponent("CustomFiles", isDirectory: true)
        let customFiles = try ModCustomFiles.files(in: customRoot)
        var updatedInstance = build.instance
        updatedInstance.category = current.category
        updatedInstance.lastPlayedAt = current.lastPlayedAt
        for (relativePath, source) in customFiles {
            let destination = try SafePaths.url(
                for: "CustomFiles/\(relativePath)",
                under: build.directory
            )
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.copyItem(at: source, to: destination)
        }
        if build.instance.iconFile == nil, let oldIcon = current.iconFile {
            let source = try SafePaths.url(for: oldIcon, under: oldDirectory)
            let destination = build.directory.appendingPathComponent(oldIcon)
            if fileManager.fileExists(atPath: source.path) {
                try fileManager.copyItem(at: source, to: destination)
            }
        }
        try JSONEncoder.pretty.encode(updatedInstance)
            .write(to: build.directory.appendingPathComponent("manifest.json"), options: .atomic)

        let backupDirectory = AppPaths.instances.appendingPathComponent(
            ".UpdateBackup-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.moveItem(at: oldDirectory, to: backupDirectory)
        do {
            try fileManager.moveItem(at: build.directory, to: oldDirectory)
        } catch {
            do {
                try fileManager.moveItem(at: backupDirectory, to: oldDirectory)
            } catch {
                throw ModManagerError.launchRollbackFailed(
                    "The update failed and the previous instance could not be restored: \(error.localizedDescription)"
                )
            }
            throw error
        }
        do {
            try fileManager.removeItem(at: backupDirectory)
        } catch {
            NSLog("Could not remove prior instance backup %@: %@", backupDirectory.path, error.localizedDescription)
        }
        return updatedInstance
    }

    func installArchive(_ archive: URL, deleteAfterSuccess: Bool = false) {
        guard let settings else {
            errorMessage = "Complete setup before installing a mod."
            return
        }
        guard !isBusy else { return }
        isBusy = true
        statusMessage = "Reading and patching mod archive..."
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try DeltaModBuilder.build(
                    archive: archive,
                    windowsBackup: URL(fileURLWithPath: settings.windowsBackupPath),
                    supportRoot: AppPaths.support
                )
                let cleanupMessage = deleteAfterSuccess ? Self.removeDownloadedArchive(archive) : nil
                DispatchQueue.main.async {
                    self.instances.insert(result.instance, at: 0)
                    self.statusMessage = "Created instance: \(result.instance.name)" +
                        (cleanupMessage.map { " (\($0))" } ?? "")
                    self.isBusy = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                    self.statusMessage = ""
                    self.isBusy = false
                }
            }
        }
    }

    func analyzeManualArchive(
        _ archive: URL,
        modName: String,
        deleteAfterSuccess: Bool = false,
        game: ModGame = .deltarune
    ) {
        guard !isBusy else { return }
        guard isConfigured(for: game) else {
            errorMessage = "Configure \(game.title) in Settings before installing a mod."
            return
        }
        isBusy = true
        statusMessage = "Finding xdelta patches..."
        Task {
            do {
                let options = try await Task.detached(priority: .userInitiated) {
                    try DeltaModBuilder.manualPatchOptions(archive: archive, supportRoot: AppPaths.support)
                }.value
                if installSingleUndertaleXdeltaIfPossible(
                    options,
                    archive: archive,
                    game: game,
                    modName: modName,
                    deleteAfterSuccess: deleteAfterSuccess
                ) {
                    return
                }
                manualPatchSelection = ManualPatchSelection(
                    archive: archive,
                    modName: modName,
                    options: options,
                    deleteAfterSuccess: deleteAfterSuccess,
                    game: game,
                    updatingInstanceID: nil
                )
                statusMessage = game == .undertale
                    ? "Choose which Undertale files to include."
                    : "Choose a chapter for each patch to include."
                isBusy = false
            } catch {
                isBusy = false
                statusMessage = ""
                errorMessage = error.localizedDescription
            }
        }
    }

    func installManualArchive(_ selection: ManualPatchSelection, assignments: [ManualPatchAssignment]) {
        installManualArchive(selection, assignments: assignments, modName: selection.modName)
    }

    func inspectManualArchive(_ archive: URL, game: ModGame = .deltarune) async throws -> ManualPatchSelection {
        let options = try await Task.detached(priority: .userInitiated) {
            try DeltaModBuilder.manualPatchOptions(archive: archive, supportRoot: AppPaths.support)
        }.value
        return ManualPatchSelection(
            archive: archive,
            modName: archive.deletingPathExtension().lastPathComponent,
            options: options,
            deleteAfterSuccess: false,
            game: game
        )
    }

    func installManualArchive(
        _ selection: ManualPatchSelection,
        assignments: [ManualPatchAssignment],
        modName: String
    ) {
        guard let settings else {
            errorMessage = "Complete setup before installing a manual patch."
            return
        }
        guard isConfigured(for: selection.game),
              let backupPath = backupPath(for: selection.game, settings: settings) else {
            errorMessage = "Configure \(selection.game.title) in Settings before installing a mod."
            return
        }
        guard !isBusy else { return }
        isBusy = true
        manualPatchSelection = nil
        if let queueEntryID = selection.queueEntryID {
            updateQueueEntry(queueEntryID, status: .installing)
        }
        statusMessage = "Applying selected patches..."
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try DeltaModBuilder.buildManual(
                        archive: selection.archive,
                        assignments: assignments,
                        modName: modName,
                        windowsBackup: URL(fileURLWithPath: backupPath),
                        supportRoot: AppPaths.support,
                        game: selection.game
                    )
                }.value
                let (installedInstance, iconWarning) = await addingGameBananaIconIfNeeded(
                    to: result,
                    from: selection.gameBananaIconURL.map { [$0] } ?? []
                )
                var installed = installedInstance
                installed.gameBananaModID = selection.gameBananaModID
                installed.gameBananaFileID = selection.gameBananaFileID
                installed.gameBananaFileDateAdded = selection.gameBananaFileDateAdded
                try JSONEncoder.pretty.encode(installed)
                    .write(to: result.directory.appendingPathComponent("manifest.json"), options: .atomic)
                let cleanupMessage = selection.deleteAfterSuccess
                    ? Self.removeDownloadedArchive(selection.archive)
                    : nil
                if let updatingID = selection.updatingInstanceID,
                   let existing = instances.first(where: { $0.id == updatingID }) {
                    installed.lastPlayedAt = existing.lastPlayedAt
                    let updated = try Self.replaceUpdatedInstance(
                        existing,
                        with: ModBuildResult(instance: installed, directory: result.directory)
                    )
                    guard let index = instances.firstIndex(where: { $0.id == updatingID }) else {
                        throw ModManagerError.invalidArchive("The mod instance being updated was removed.")
                    }
                    instances[index] = updated
                } else {
                    instances.insert(installed, at: 0)
                }
                isBusy = false
                statusMessage = (selection.updatingInstanceID == nil ? "Created instance: " : "Updated instance: ") +
                    installed.name +
                    (iconWarning.map { " (\($0))" } ?? "") +
                    (cleanupMessage.map { " (\($0))" } ?? "")
                finishQueuedManualSelection(selection, error: nil)
            } catch {
                isBusy = false
                statusMessage = ""
                errorMessage = error.localizedDescription
                finishQueuedManualSelection(selection, error: error.localizedDescription)
            }
        }
    }

    private func installSingleUndertaleXdeltaIfPossible(
        _ options: [ManualPatchOption],
        archive: URL,
        game: ModGame,
        modName: String,
        deleteAfterSuccess: Bool,
        gameBananaIconURL: URL? = nil,
        gameBananaModID: Int? = nil,
        gameBananaFileID: Int? = nil,
        gameBananaFileDateAdded: Int64? = nil
    ) -> Bool {
        guard game == .undertale,
              options.count == 1,
              options[0].kind == .xdelta else {
            return false
        }
        let selection = ManualPatchSelection(
            archive: archive,
            modName: modName,
            options: options,
            deleteAfterSuccess: deleteAfterSuccess,
            gameBananaIconURL: gameBananaIconURL,
            game: .undertale,
            gameBananaModID: gameBananaModID,
            gameBananaFileID: gameBananaFileID,
            gameBananaFileDateAdded: gameBananaFileDateAdded
        )
        isBusy = false
        installManualArchive(
            selection,
            assignments: [
                ManualPatchAssignment(
                    patchPath: options[0].path,
                    target: .undertale,
                    kind: .xdelta
                )
            ],
            modName: modName
        )
        return true
    }

    func addManualArchive(
        _ selection: ManualPatchSelection,
        assignments: [ManualPatchAssignment],
        named modName: String,
        to instance: ModInstance
    ) {
        guard let settings else {
            errorMessage = "Complete setup before editing a mod instance."
            return
        }
        guard let backupPath = backupPath(for: instance.targetGame, settings: settings) else {
            errorMessage = "The backup for \(instance.targetGame.title) is not configured."
            return
        }
        guard !isBusy else { return }
        let cleanName = modName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else {
            errorMessage = "Enter a name for these files."
            return
        }
        isBusy = true
        statusMessage = "Adding files to \(instance.name)..."
        Task {
            var result: ModBuildResult?
            do {
                let built = try await Task.detached(priority: .userInitiated) {
                    try DeltaModBuilder.buildManual(
                        archive: selection.archive,
                        assignments: assignments,
                        modName: cleanName,
                        windowsBackup: URL(fileURLWithPath: backupPath),
                        supportRoot: AppPaths.support,
                        game: instance.targetGame
                    )
                }.value
                result = built
                let updated = try await Task.detached(priority: .userInitiated) {
                    try ModInstancePayloadMerger.merge(
                        built,
                        into: AppPaths.instanceDirectory(instance.id)
                    )
                }.value
                if let index = instances.firstIndex(where: { $0.id == instance.id }) {
                    instances[index] = updated
                }
                statusMessage = "Added \(cleanName) to \(instance.name)."
                isBusy = false
                do {
                    try FileManager.default.removeItem(at: built.directory)
                } catch {
                    errorMessage = "Files were added, but temporary files could not be removed: \(error.localizedDescription)"
                }
            } catch {
                if let result {
                    try? FileManager.default.removeItem(at: result.directory)
                }
                isBusy = false
                statusMessage = ""
                errorMessage = error.localizedDescription
            }
        }
    }

    func replaceSkippedFile(_ skippedFile: ModSkippedFile, with dylibURL: URL, in instance: ModInstance) {
        guard !isBusy else { return }
        guard let current = instances.first(where: { $0.id == instance.id }) else {
            errorMessage = "This mod instance is no longer available."
            return
        }
        isBusy = true
        statusMessage = "Repatching \(current.name) with \(dylibURL.lastPathComponent)..."
        Task {
            do {
                let updated = try await Task.detached(priority: .userInitiated) {
                    try ModInstancePayloadMerger.replaceSkippedFile(
                        skippedFile,
                        with: dylibURL,
                        in: AppPaths.instanceDirectory(current.id)
                    )
                }.value
                if let index = instances.firstIndex(where: { $0.id == current.id }) {
                    instances[index] = updated
                }
                isBusy = false
                statusMessage = "Repatched \(current.name). The Mac replacement will be applied the next time you launch this instance."
            } catch {
                isBusy = false
                statusMessage = ""
                errorMessage = error.localizedDescription
            }
        }
    }

    func cancelManualPatchSelection() {
        guard let selection = manualPatchSelection else { return }
        manualPatchSelection = nil
        if selection.deleteAfterSuccess {
            if let cleanupMessage = Self.removeDownloadedArchive(selection.archive) {
                statusMessage = cleanupMessage
            } else {
                statusMessage = "Cancelled patch selection."
            }
        }
        finishQueuedManualSelection(selection, error: nil, cancelled: true)
    }

    private func finishQueuedManualSelection(
        _ selection: ManualPatchSelection,
        error: String?,
        cancelled: Bool = false
    ) {
        guard let queueEntryID = selection.queueEntryID,
              let index = downloadQueue.firstIndex(where: { $0.id == queueEntryID }) else {
            return
        }
        downloadQueue[index].status = cancelled ? .cancelled : (error == nil ? .completed : .failed)
        downloadQueue[index].failureMessage = error
        downloadQueue[index].progress = nil
        activeDownloadQueueEntryID = nil
        startDownloadQueueIfNeeded()
    }

    func handleOneClickInstall(_ url: URL, catalog: GameBananaCatalog) {
        guard GameBananaOneClickLink.usesSupportedScheme(url) else { return }
        guard !isBusy else {
            errorMessage = "Wait for the current mod operation to finish before using a one-click install."
            return
        }
        guard settings != nil else {
            errorMessage = "Complete setup and select your own game files before installing a mod."
            return
        }
        guard let link = GameBananaOneClickLink(url: url) else {
            errorMessage = "This GameBanana one-click link is invalid or uses an unsupported install type."
            return
        }

        isBusy = true
        statusMessage = "Finding the selected GameBanana release..."
        Task {
            do {
                let details = try await catalog.details(forModID: link.modID)
                guard let file = details.files.first(where: { $0.id == link.fileID }) else {
                    throw GameBananaError.oneClickReleaseNotFound
                }
                guard file.isSelectableRelease else {
                    throw GameBananaError.unsupportedDownload
                }
                isBusy = false
                downloadAndInstall(
                    file,
                    modName: details.name,
                    gameBananaIconURLs: details.imageURLs,
                    game: catalog.game,
                    gameBananaModID: link.modID
                )
            } catch {
                isBusy = false
                statusMessage = ""
                errorMessage = GameBananaError.message(for: error)
            }
        }
    }

    func downloadAndInstall(
        _ file: GameBananaFile,
        modName: String,
        gameBananaIconURLs: [URL] = [],
        game: ModGame = .deltarune,
        gameBananaModID: Int? = nil
    ) {
        guard file.isSelectableRelease else {
            errorMessage = "This release isn't a supported Deltamod, G3M ZIP, or manual ZIP/RAR/xdelta patch."
            return
        }
        guard let settings else {
            errorMessage = "Complete setup before installing a mod."
            return
        }
        guard isConfigured(for: game),
              backupPath(for: game, settings: settings) != nil else {
            errorMessage = "Configure \(game.title) in Settings before installing a mod."
            return
        }
        enqueueDownload(
            title: modName,
            file: file,
            operation: .install(
                file: file,
                modName: modName,
                iconURLs: gameBananaIconURLs,
                game: game,
                modID: gameBananaModID
            )
        )
    }

    private func performQueuedInstall(
        _ file: GameBananaFile,
        modName: String,
        iconURLs: [URL],
        game: ModGame,
        modID: Int?
    ) async throws -> Bool {
        guard let settings else {
            throw ModManagerError.invalidArchive("Complete setup before installing a mod.")
        }
        guard let backupPath = backupPath(for: game, settings: settings) else {
            throw ModManagerError.invalidArchive("Configure \(game.title) before installing a mod.")
        }
        let archive = try await downloadGameBananaFile(file)
        let kind = try DeltaModBuilder.archiveKind(archive)
        if kind == .other || game == .undertale {
            let options = try await Task.detached(priority: .userInitiated) {
                try DeltaModBuilder.manualPatchOptions(archive: archive, supportRoot: AppPaths.support)
            }.value
            manualPatchSelection = ManualPatchSelection(
                archive: archive,
                modName: modName,
                options: options,
                deleteAfterSuccess: true,
                gameBananaIconURL: iconURLs.first,
                game: game,
                gameBananaModID: modID,
                gameBananaFileID: file.id,
                gameBananaFileDateAdded: file.dateAdded,
                queueEntryID: activeDownloadQueueEntryID
            )
            statusMessage = game == .undertale
                ? "Choose the Undertale data.win file to patch."
                : "Choose a chapter for each patch to include."
            return true
        }

        updateActiveQueueEntry(status: .installing)
        let format = kind == .g3m || kind == .legacyG3M ? "G3M" : "Deltamod"
        statusMessage = "Preparing \(format) instance..."
        let result = try await Task.detached(priority: .userInitiated) {
            try DeltaModBuilder.build(
                archive: archive,
                windowsBackup: URL(fileURLWithPath: backupPath),
                supportRoot: AppPaths.support
            )
        }.value
        var installed = result.instance
        installed.game = game
        installed.gameBananaModID = modID
        installed.gameBananaFileID = file.id
        installed.gameBananaFileDateAdded = file.dateAdded
        installed = await addingGameBananaIconIfNeeded(
            to: ModBuildResult(instance: installed, directory: result.directory),
            from: iconURLs
        ).instance
        try JSONEncoder.pretty.encode(installed)
            .write(to: result.directory.appendingPathComponent("manifest.json"), options: .atomic)
        let cleanupMessage = Self.removeDownloadedArchive(archive)
        instances.insert(installed, at: 0)
        statusMessage = "Created instance: \(installed.name)" +
            (cleanupMessage.map { " (\($0))" } ?? "")
        return false
    }

    nonisolated private static func removeDownloadedArchive(_ archive: URL) -> String? {
        do {
            try FileManager.default.removeItem(at: archive)
            return nil
        } catch {
            return "Downloaded archive kept at \(archive.path): \(error.localizedDescription)"
        }
    }

    private func downloadGameBananaFile(_ file: GameBananaFile) async throws -> URL {
        isDownloading = true
        downloadProgress = nil
        defer {
            isDownloading = false
            downloadProgress = nil
        }
        return try await GameBananaCatalog.download(file) { [weak self] received, expected in
            Task { @MainActor [weak self] in
                guard let self, self.isDownloading else { return }
                self.downloadProgress = expected > 0
                    ? min(1, max(0, Double(received) / Double(expected)))
                    : nil
                self.updateActiveQueueEntry(progress: self.downloadProgress)
            }
        }
    }

    private func addingGameBananaIconIfNeeded(
        to build: ModBuildResult,
        from imageURLs: [URL]
    ) async -> (instance: ModInstance, warning: String?) {
        guard build.instance.iconFile == nil, !imageURLs.isEmpty else {
            return (build.instance, nil)
        }
        var lastError: Error?
        for imageURL in imageURLs {
            do {
                let data = try await GameBananaCatalog.downloadImageData(from: imageURL)
                guard NSImage(data: data) != nil else {
                    throw GameBananaError.badResponse
                }
                let pathExtension = ["png", "jpg", "jpeg"].contains(imageURL.pathExtension.lowercased())
                    ? imageURL.pathExtension.lowercased()
                    : "png"
                let filename = "gamebanana-icon.\(pathExtension)"
                let iconURL = build.directory.appendingPathComponent(filename)
                try data.write(to: iconURL, options: .atomic)

                var updated = build.instance
                updated.iconFile = filename
                do {
                    try JSONEncoder.pretty.encode(updated)
                        .write(to: build.directory.appendingPathComponent("manifest.json"), options: .atomic)
                } catch {
                    try? FileManager.default.removeItem(at: iconURL)
                    throw error
                }
                return (updated, nil)
            } catch {
                lastError = error
            }
        }
        let warning = "GameBanana icon wasn't downloaded: \(lastError?.localizedDescription ?? "no usable image was available")"
        NSLog("%@", warning)
        return (build.instance, warning)
    }

    private static func removeExpiredDownloads() {
        let fileManager = FileManager.default
        do {
            let entries = try fileManager.contentsOfDirectory(
                at: AppPaths.downloads,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            let expirationDate = Date().addingTimeInterval(-7 * 24 * 60 * 60)
            for entry in entries {
                let modified = try entry.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate ?? .distantFuture
                guard modified < expirationDate else { continue }
                do {
                    try fileManager.removeItem(at: entry)
                } catch {
                    NSLog("Could not remove expired mod download %@: %@", entry.path, error.localizedDescription)
                }
            }
        } catch {
            NSLog("Could not inspect mod downloads for cleanup: %@", error.localizedDescription)
        }
    }

    func launch(_ instance: ModInstance) {
        guard let settings else {
            errorMessage = "Complete setup before launching a mod."
            return
        }
        guard !isBusy else { return }
        let game = instance.targetGame
        guard isConfigured(for: game) else {
            errorMessage = "Configure \(game.title) in Settings before launching."
            return
        }
        let gameApp = gameAppURL(for: game)
        guard !Self.gameIsRunning(at: gameApp, game: game) else {
            errorMessage = ModManagerError.gameAlreadyRunning.localizedDescription
            return
        }
        guard !FileManager.default.fileExists(atPath: Self.journalURL.path) else {
            errorMessage = ModManagerError.activeRun.localizedDescription
            return
        }

        isBusy = true
        statusMessage = "Preparing a temporary modded launch..."
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try Self.prepareRun(instance: instance, settings: settings)
                DispatchQueue.main.async {
                    self.openGame(at: gameApp, game: game, instanceID: instance.id)
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                    self.statusMessage = ""
                    self.isBusy = false
                }
            }
        }
    }

    func handleLaunchShortcut(_ url: URL) {
        guard url.scheme?.lowercased() == "dmt",
              url.host?.lowercased() == "launch",
              let instanceID = url.pathComponents.dropFirst().first,
              let instance = instances.first(where: { $0.id == instanceID }) else {
            errorMessage = "This desktop shortcut does not point to an installed mod instance."
            return
        }
        launch(instance)
    }

    func createDesktopShortcut(for instance: ModInstance) {
        guard instances.contains(where: { $0.id == instance.id }) else {
            errorMessage = "This mod instance is no longer available."
            return
        }
        do {
            let desktop = try FileManager.default.url(
                for: .desktopDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            )
            var components = URLComponents()
            components.scheme = "dmt"
            components.host = "launch"
            components.path = "/\(instance.id)"
            guard let launchURL = components.url else {
                throw ModManagerError.invalidArchive("Could not create a launch URL for this mod.")
            }
            let safeName = instance.name
               .replacingOccurrences(of: "/", with: "-")
               .replacingOccurrences(of: ":", with: "-")
               .trimmingCharacters(in: .whitespacesAndNewlines)
            let baseName = safeName.isEmpty ? "Mod" : safeName
            var destination = desktop.appendingPathComponent("\(baseName).app", isDirectory: true)
            var suffix = 2
            while FileManager.default.fileExists(atPath: destination.path) {
                if Self.isDesktopLauncher(destination, for: launchURL.absoluteString) {
                    break
                }
                destination = desktop.appendingPathComponent("\(baseName) (\(suffix)).app", isDirectory: true)
                suffix += 1
            }

            let temporaryLauncher = desktop.appendingPathComponent(
                ".\(baseName)-\(UUID().uuidString).app",
                isDirectory: true
            )
            defer {
                if FileManager.default.fileExists(atPath: temporaryLauncher.path) {
                    do {
                        try FileManager.default.removeItem(at: temporaryLauncher)
                    } catch {
                        NSLog("Could not remove temporary desktop launcher %@: %@", temporaryLauncher.path, error.localizedDescription)
                    }
                }
            }
            guard let launcherTemplate = Bundle.main.resourceURL?
                .appendingPathComponent("DesktopModLauncher.app", isDirectory: true),
                  FileManager.default.fileExists(atPath: launcherTemplate.path) else {
                throw ModManagerError.invalidArchive(
                    "The native desktop launcher is missing from this app build. Rebuild or reinstall the manager."
                )
            }
            try FileManager.default.copyItem(at: launcherTemplate, to: temporaryLauncher)
            let configuration: [String: String] = [
                "managerAppPath": Bundle.main.bundleURL.path,
                "launchURL": launchURL.absoluteString
            ]
            let configurationData = try PropertyListSerialization.data(
                fromPropertyList: configuration,
                format: .xml,
                options: 0
            )
            try configurationData.write(
                to: temporaryLauncher.appendingPathComponent("Contents/Resources/dmt-launch.plist"),
                options: .atomic
            )
            if let iconURL = iconURL(for: instance), let icon = NSImage(contentsOf: iconURL) {
                _ = NSWorkspace.shared.setIcon(icon, forFile: temporaryLauncher.path, options: [])
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: temporaryLauncher, to: destination)
            let desktopItems = try FileManager.default.contentsOfDirectory(
                at: desktop,
                includingPropertiesForKeys: nil
            )
            for oldShortcut in desktopItems where oldShortcut != destination &&
                ((oldShortcut.pathExtension == "app" &&
                    Self.isDesktopLauncher(oldShortcut, for: launchURL.absoluteString)) ||
                    (oldShortcut.pathExtension == "webloc" &&
                        Self.isShortcut(oldShortcut, for: launchURL.absoluteString))) {
                try FileManager.default.removeItem(at: oldShortcut)
            }
            statusMessage = "Created a desktop shortcut for \(instance.name)."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static func isDesktopLauncher(_ app: URL, for launchURL: String) -> Bool {
        let configuration = app.appendingPathComponent("Contents/Resources/dmt-launch.plist")
        if let data = try? Data(contentsOf: configuration),
           let values = try? PropertyListSerialization.propertyList(
               from: data,
               options: [],
               format: nil
           ) as? [String: String],
           values["launchURL"] == launchURL {
            return true
        }
        let legacyMarker = app.appendingPathComponent("Contents/Resources/dmt-launch-url.txt")
        return (try? String(contentsOf: legacyMarker, encoding: .utf8)) == launchURL
    }

    private static func isShortcut(_ file: URL, for destinationURL: String) -> Bool {
        guard let data = try? Data(contentsOf: file),
              let propertyList = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) else {
            return false
        }
        if let values = propertyList as? [String: String] {
            return values["URL"] == destinationURL
        }
        return propertyList as? String == destinationURL
    }

    func installCLI() {
        guard let bundledCLI = Bundle.main.url(forResource: "drmt", withExtension: nil) else {
            errorMessage = "The drmt command is missing from this app build. Rebuild or reinstall the app, then try again."
            return
        }

        do {
            let fileManager = FileManager.default
            let destination = Self.cliInstallURL
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            if fileManager.fileExists(atPath: destination.path) {
                let existing = try String(contentsOf: destination, encoding: .utf8)
                guard existing.hasPrefix("#!/bin/sh\n# Deltarune Mod Manager CLI\n") else {
                    errorMessage = "A different command already exists at \(destination.path). Move it first if you want to install drmt there."
                    return
                }
            }

            let command = try Data(contentsOf: bundledCLI)
            try command.write(to: destination, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
            statusMessage = "Installed drmt at \(destination.path). Use `drmt list` or `drmt launch <mod name>` in Terminal."
        } catch {
            errorMessage = "Could not install the drmt command: \(error.localizedDescription)"
        }
    }

    func launchVanilla(for game: ModGame = .deltarune) {
        guard settings != nil else {
            errorMessage = "Complete setup before launching \(game.title)."
            return
        }
        guard !isBusy else { return }
        guard isConfigured(for: game) else {
            errorMessage = "Configure \(game.title) in Settings before launching."
            return
        }
        let gameApp = gameAppURL(for: game)
        guard !Self.gameIsRunning(at: gameApp, game: game) else {
            errorMessage = ModManagerError.gameAlreadyRunning.localizedDescription
            return
        }
        guard !FileManager.default.fileExists(atPath: Self.journalURL.path) else {
            errorMessage = ModManagerError.activeRun.localizedDescription
            return
        }

        isBusy = true
        statusMessage = "Launching vanilla \(game.title)..."
        openGame(at: gameApp, game: game)
    }

    func removeInstance(_ instance: ModInstance) {
        guard !isBusy else { return }
        do {
            try FileManager.default.removeItem(at: AppPaths.instanceDirectory(instance.id))
            instances.removeAll { $0.id == instance.id }
            statusMessage = "Removed \(instance.name)."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func iconURL(for instance: ModInstance) -> URL? {
        guard let icon = instance.iconFile else { return nil }
        return AppPaths.instanceDirectory(instance.id).appendingPathComponent(icon)
    }

    func files(for instance: ModInstance) -> [ModInstanceFileEntry] {
        var files: [String: ModInstanceFileEntry] = [:]
        for payload in instance.payloads {
            files[payload.resourcePath] = ModInstanceFileEntry(
                path: payload.resourcePath,
                sourceLabel: payload.sourceLabel ?? "Installed mod"
            )
        }
        let customRoot = AppPaths.instanceDirectory(instance.id)
            .appendingPathComponent("CustomFiles", isDirectory: true)
        do {
            for path in try ModCustomFiles.files(in: customRoot).keys {
                files[path] = ModInstanceFileEntry(path: path, sourceLabel: "Custom files")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        return files.values.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    func renameInstance(_ instance: ModInstance, to name: String) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else {
            errorMessage = "A mod instance name cannot be empty."
            return
        }

        guard let current = instances.first(where: { $0.id == instance.id }) else {
            errorMessage = "This mod instance is no longer available."
            return
        }
        var updated = current
        updated.name = cleanName
        do {
            try JSONEncoder.pretty.encode(updated)
                .write(to: AppPaths.instanceDirectory(instance.id).appendingPathComponent("manifest.json"), options: .atomic)
            if let index = instances.firstIndex(where: { $0.id == instance.id }) {
                instances[index] = updated
            }
            statusMessage = "Saved changes to \(cleanName)."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func categorizeInstance(_ instance: ModInstance, as category: String) {
        guard let index = instances.firstIndex(where: { $0.id == instance.id }) else {
            errorMessage = "This mod instance is no longer available."
            return
        }
        let cleanCategory = category.trimmingCharacters(in: .whitespacesAndNewlines)
        var updated = instances[index]
        updated.category = cleanCategory.isEmpty ? nil : cleanCategory
        do {
            try JSONEncoder.pretty.encode(updated)
                .write(
                    to: AppPaths.instanceDirectory(instance.id).appendingPathComponent("manifest.json"),
                    options: .atomic
                )
            instances[index] = updated
            statusMessage = cleanCategory.isEmpty
                ? "Removed \(instance.name) from its category."
                : "Moved \(instance.name) to \(cleanCategory)."
        } catch {
            errorMessage = "Couldn't save the category for \(instance.name): \(error.localizedDescription)"
        }
    }

    func showCustomFilesInFinder(for instance: ModInstance) {
        let directory = AppPaths.instanceDirectory(instance.id)
            .appendingPathComponent("CustomFiles", isDirectory: true)
        do {
            guard let settings else {
                errorMessage = "Complete setup before opening custom files."
                return
            }
            let resources = try Self.resourcesURL(for: instance.targetGame, settings: settings)
            try ModCustomFiles.prepareMirroredDirectories(from: resources, at: directory)
            NSWorkspace.shared.activateFileViewerSelecting([directory])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func showCustomMusicInFinder(for instance: ModInstance) {
        let directory = AppPaths.instanceDirectory(instance.id)
            .appendingPathComponent("CustomFiles/mus", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(directory)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    nonisolated private static var journalURL: URL {
        AppPaths.activeRun.appendingPathComponent("journal.json")
    }

    nonisolated private static var cliInstallURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/drmt")
    }

    nonisolated private static func resourcesURL(for game: ModGame, settings: AppSettings) throws -> URL {
        switch game {
        case .deltarune:
            return try GameAppLocator.resources(for: URL(fileURLWithPath: settings.gameAppPath))
        case .undertale:
            guard let path = settings.undertaleAppPath else {
                throw ModManagerError.invalidGameApp
            }
            return try GameAppLocator.undertaleResources(for: URL(fileURLWithPath: path))
        }
    }

    nonisolated private static func gameAppPath(for game: ModGame, settings: AppSettings) throws -> String {
        switch game {
        case .deltarune:
            return settings.gameAppPath
        case .undertale:
            guard let path = settings.undertaleAppPath else {
                throw ModManagerError.invalidGameApp
            }
            return path
        }
    }

    private static func loadSettings() -> AppSettings? {
        guard let data = try? Data(contentsOf: AppPaths.settings) else { return nil }
        return try? JSONDecoder().decode(AppSettings.self, from: data)
    }

    nonisolated private static func removePreviousWindowsBackup(at backup: URL) {
        removeManagedBackup(at: backup, prefix: "WindowsBackup")
    }

    nonisolated private static func removeManagedBackup(at backup: URL, prefix: String) {
        let support = AppPaths.support.standardizedFileURL
        let standardizedBackup = backup.standardizedFileURL
        let isManagedBackup = standardizedBackup.lastPathComponent == prefix ||
            standardizedBackup.lastPathComponent.hasPrefix("\(prefix)-")
        guard standardizedBackup.deletingLastPathComponent() == support, isManagedBackup else {
            return
        }
        do {
            if FileManager.default.fileExists(atPath: standardizedBackup.path) {
                try FileManager.default.removeItem(at: standardizedBackup)
            }
        } catch {
            NSLog("Could not remove previous Windows backup %@: %@", standardizedBackup.path, error.localizedDescription)
        }
    }

    private func loadInstances() {
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: AppPaths.instances,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        instances = directories.compactMap { directory in
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")) else {
                return nil
            }

            return try? JSONDecoder().decode(ModInstance.self, from: data)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func refreshMissingGameBananaIcons(catalog: GameBananaCatalog) {
        let missing = instances.filter {
            $0.iconFile == nil && $0.gameBananaModID != nil && !iconRefreshInProgress.contains($0.id)
        }
        guard !missing.isEmpty else { return }
        iconRefreshInProgress.formUnion(missing.map(\.id))
        Task {
            for instance in missing {
                defer { iconRefreshInProgress.remove(instance.id) }
                guard let modID = instance.gameBananaModID else { continue }
                do {
                    let details = try await catalog.details(forModID: modID)
                    let result = await addingGameBananaIconIfNeeded(
                        to: ModBuildResult(
                            instance: instance,
                            directory: AppPaths.instanceDirectory(instance.id)
                        ),
                        from: details.imageURLs
                    )
                    guard result.instance.iconFile != nil,
                          let index = instances.firstIndex(where: { $0.id == instance.id }) else {
                        if let warning = result.warning { NSLog("%@", warning) }
                        continue
                    }
                    instances[index] = result.instance
                } catch {
                    NSLog("Could not refresh GameBanana icon for %@: %@", instance.name, error.localizedDescription)
                }
            }
        }
    }

    private func openGame(at gameApp: URL, game: ModGame, instanceID: String? = nil) {
        launchedGame = game
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: gameApp, configuration: configuration) { [weak self] application, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.restoreActiveRun(showStatus: false)
                    self.errorMessage = "Could not launch \(game.title): \(error.localizedDescription)"
                    self.isGameSessionActive = false
                    self.activeInstanceID = nil
                    self.isBusy = false
                    return
                }
                self.launchedProcessID = application?.processIdentifier
                self.isGameSessionActive = true
                self.activeInstanceID = instanceID
                if let instanceID {
                    self.recordSuccessfulLaunch(of: instanceID)
                }
                self.isBusy = false
                self.statusMessage = FileManager.default.fileExists(atPath: Self.journalURL.path)
                    ? "Mod active. Original game files will be restored when \(game.title) closes."
                    : "Vanilla \(game.title) is running."
                self.watchForGameExit(gameApp: gameApp, game: game)
            }
        }
    }

    private func recordSuccessfulLaunch(of instanceID: String) {
        guard let index = instances.firstIndex(where: { $0.id == instanceID }) else { return }
        var updated = instances[index]
        updated.lastPlayedAt = Date()
        do {
            try JSONEncoder.pretty.encode(updated)
                .write(
                    to: AppPaths.instanceDirectory(instanceID).appendingPathComponent("manifest.json"),
                    options: .atomic
                )
            instances[index] = updated
        } catch {
            NSLog("Could not save last-played time for %@: %@", updated.name, error.localizedDescription)
            errorMessage = "The game launched, but its last-played time couldn't be saved: \(error.localizedDescription)"
        }
    }

    private func watchForGameExit(gameApp: URL, game: ModGame) {
        runTimer?.invalidate()
        let startedAt = Date()
        runTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, Date().timeIntervalSince(startedAt) >= 8 else { return }
                if !Self.gameIsRunning(at: gameApp, game: game) {
                    self.restoreAfterGameExit()
                }
            }
        }
    }

    private func restoreAfterGameExit() {
        runTimer?.invalidate()
        runTimer = nil
        launchedProcessID = nil
        isGameSessionActive = false
        activeInstanceID = nil
        restoreActiveRun(showStatus: true)
    }

    private func restoreActiveRun(showStatus: Bool) {
        let journalURL = Self.journalURL
        guard !isRestoringRun else { return }
        guard FileManager.default.fileExists(atPath: journalURL.path) else {
            statusMessage = ""
            isBusy = false
            return
        }
        isRestoringRun = true
        isBusy = true
        statusMessage = "Restoring original game files..."
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try Self.restoreRun(journalURL: journalURL)
                DispatchQueue.main.async {
                    self.isRestoringRun = false
                    self.statusMessage = showStatus ? "Original game files restored." : ""
                    self.isBusy = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.isRestoringRun = false
                    self.errorMessage = "Could not restore the original game files: \(error.localizedDescription)"
                    self.statusMessage = "Recovery is still needed. Do not launch DELTARUNE until the files are restored."
                    self.isBusy = false
                }
            }
        }
    }

    private func recoverPreviousRunIfNeeded() {
        guard FileManager.default.fileExists(atPath: Self.journalURL.path) else { return }
        guard let data = try? Data(contentsOf: Self.journalURL),
              let journal = try? JSONDecoder().decode(ActiveRunJournal.self, from: data) else {
            errorMessage = "A previous recovery record is damaged. The app cannot safely restore the game files; do not launch DELTARUNE."
            return
        }
        let gameApp = URL(fileURLWithPath: journal.gameAppPath)
        let game = journal.game ?? .deltarune
        launchedGame = game
        if Self.gameIsRunning(at: gameApp, game: game) {
            isGameSessionActive = true
            activeInstanceID = nil
            statusMessage = "A previous modded session is active. Original files will be restored after \(game.title) closes."
            watchForGameExit(gameApp: gameApp, game: game)
        } else {
            restoreActiveRun(showStatus: true)
        }
    }

    nonisolated private static func prepareRun(instance: ModInstance, settings: AppSettings) throws {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: Self.journalURL.path) else {
            throw ModManagerError.activeRun
        }
        if fileManager.fileExists(atPath: AppPaths.activeRun.path) {
            try fileManager.removeItem(at: AppPaths.activeRun)
        }
        let resources = try resourcesURL(for: instance.targetGame, settings: settings)
        let instanceDirectory = AppPaths.instanceDirectory(instance.id)
        let backupDirectory = AppPaths.activeRun.appendingPathComponent("Backups", isDirectory: true)
        try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)

        var sourceByResource: [String: URL] = [:]
        for payload in instance.payloads {
            let resource = try SafePaths.relative(payload.resourcePath)
            let source = try SafePaths.url(
                for: "Payloads/\(payload.instanceFile)",
                under: instanceDirectory
            )
            guard fileManager.fileExists(atPath: source.path) else {
                throw ModManagerError.invalidArchive("An instance payload is missing: \(payload.instanceFile)")
            }
            sourceByResource[resource] = source
        }

        let customFilesDirectory = instanceDirectory.appendingPathComponent("CustomFiles", isDirectory: true)
        for (resource, source) in try ModCustomFiles.files(in: customFilesDirectory) {
            sourceByResource[resource] = source
        }

        var files: [ActiveRunFile] = []
        for resource in sourceByResource.keys.sorted() {
            let target = try SafePaths.url(for: resource, under: resources)
            try ensureNoSymlinkComponents(target, under: resources)
            if fileManager.fileExists(atPath: target.path) {
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: target.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                    throw ModManagerError.unsafePath(resource)
                }
            }
            let backupRelative = resource
            let backup = try SafePaths.url(for: backupRelative, under: backupDirectory)
            let existed = fileManager.fileExists(atPath: target.path)
            if existed {
                try fileManager.createDirectory(
                    at: backup.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.copyItem(at: target, to: backup)
            }
            files.append(ActiveRunFile(
                resourcePath: resource,
                backupPath: backupRelative,
                hadOriginal: existed
            ))
        }

        let journal = ActiveRunJournal(
            gameAppPath: try gameAppPath(for: instance.targetGame, settings: settings),
            resourcePath: resources.path,
            backupDirectory: backupDirectory.path,
            files: files,
            game: instance.targetGame
        )
        try fileManager.createDirectory(at: AppPaths.activeRun, withIntermediateDirectories: true)
        try JSONEncoder.pretty.encode(journal).write(to: Self.journalURL, options: .atomic)

        do {
            for file in files {
                guard let source = sourceByResource[file.resourcePath] else {
                    throw ModManagerError.invalidArchive("An instance payload is missing: \(file.resourcePath)")
                }
                let target = try SafePaths.url(for: file.resourcePath, under: resources)
                try fileManager.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let temporary = target.deletingLastPathComponent()
                    .appendingPathComponent(".dmt-\(UUID().uuidString)")
                try fileManager.copyItem(at: source, to: temporary)
                if fileManager.fileExists(atPath: target.path) {
                    try fileManager.removeItem(at: target)
                }
                try fileManager.moveItem(at: temporary, to: target)
            }
        } catch {
            do {
                try restoreRun(journalURL: Self.journalURL)
            } catch {
                throw ModManagerError.launchRollbackFailed(error.localizedDescription)
            }
            throw error
        }
    }

    nonisolated private static func restoreRun(journalURL: URL) throws {
        let data = try Data(contentsOf: journalURL)
        let journal = try JSONDecoder().decode(ActiveRunJournal.self, from: data)
        let resources = URL(fileURLWithPath: journal.resourcePath)
        let backups = URL(fileURLWithPath: journal.backupDirectory)
        let fileManager = FileManager.default

        for file in journal.files {
            let target = try SafePaths.url(for: file.resourcePath, under: resources)
            try ensureNoSymlinkComponents(target, under: resources)
            if file.hadOriginal {
                let backup = try SafePaths.url(for: file.backupPath, under: backups)
                guard fileManager.fileExists(atPath: backup.path) else {
                    throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: backup.path])
                }
                try fileManager.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let temporary = target.deletingLastPathComponent()
                    .appendingPathComponent(".dmt-restore-\(UUID().uuidString)")
                try fileManager.copyItem(at: backup, to: temporary)
                if fileManager.fileExists(atPath: target.path) {
                    try fileManager.removeItem(at: target)
                }
                try fileManager.moveItem(at: temporary, to: target)
            } else if fileManager.fileExists(atPath: target.path) {
                try fileManager.removeItem(at: target)
            }
        }
        try fileManager.removeItem(at: AppPaths.activeRun)
    }

    nonisolated private static func ensureNoSymlinkComponents(_ target: URL, under root: URL) throws {
        let rootPath = root.standardizedFileURL.path
        let targetPath = target.standardizedFileURL.path
        guard targetPath.hasPrefix(rootPath + "/") else {
            throw ModManagerError.unsafePath(targetPath)
        }
        let relative = String(targetPath.dropFirst(rootPath.count + 1))
        var cursor = root.standardizedFileURL
        for component in relative.split(separator: "/") {
            cursor.appendPathComponent(String(component))
            if FileManager.default.fileExists(atPath: cursor.path) {
                let values = try cursor.resourceValues(forKeys: [.isSymbolicLinkKey])
                if values.isSymbolicLink == true {
                    throw ModManagerError.unsafePath(cursor.path)
                }
            }
        }
    }

    private static func gameIsRunning(at gameApp: URL, game: ModGame = .deltarune) -> Bool {
        let expected = gameApp.standardizedFileURL.path
        let appIsRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleURL?.standardizedFileURL.path == expected
        }
        return appIsRunning || (game == .undertale && undertaleProcessIsRunning())
    }

    nonisolated private static func undertaleProcessIsRunning() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-if", "undertale"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            NSLog("Could not check whether Undertale is running: %@", error.localizedDescription)
            return true
        }
    }
}
