import CryptoKit
import Foundation

@main
struct ModModelsValidation {
    static func main() throws {
        try validateSafePaths()
        try validateCustomFiles()
        try validateModArchive()
        try validateUndertaleModArchive()
        try validateGameBananaModels()
        try validateRecentlyPlayedOrdering()
        try validateCategorySections()
        try validateAppUpdateVersions()
        try validateOptionalGameBananaArchive()
        print("Mod manager validation passed.")
    }

    private static func validateSafePaths() throws {
        guard try SafePaths.relative("./chapter3_windows/data.win") == "chapter3_windows/data.win" else {
            throw validationError("Valid relative path was not normalized.")
        }
        do {
            _ = try SafePaths.relative("./chapter3_windows/../data.win")
            throw validationError("Path traversal was accepted.")
        } catch ModManagerError.unsafePath {
        }
        do {
            _ = try SafePaths.relative("/tmp/data.win")
            throw validationError("Absolute path was accepted.")
        } catch ModManagerError.unsafePath {
        }
    }

    private static func validateCustomFiles() throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("DMT-CustomFiles-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }
        let customRoot = temporaryRoot.appendingPathComponent("CustomFiles", isDirectory: true)
        let musicDirectory = customRoot.appendingPathComponent("mus", isDirectory: true)
        try fileManager.createDirectory(at: musicDirectory, withIntermediateDirectories: true)
        let musicFile = musicDirectory.appendingPathComponent("custom.ogg")
        try Data("custom music".utf8).write(to: musicFile)

        let resources = temporaryRoot.appendingPathComponent("Resources", isDirectory: true)
        let chapterResources = resources.appendingPathComponent("chapter3_mac", isDirectory: true)
        let nestedResources = chapterResources.appendingPathComponent("lang", isDirectory: true)
        try fileManager.createDirectory(at: nestedResources, withIntermediateDirectories: true)
        try Data("game content should not be copied".utf8)
            .write(to: chapterResources.appendingPathComponent("game.ios"))
        try ModCustomFiles.prepareMirroredDirectories(from: resources, at: customRoot)
        try require(
            fileManager.fileExists(
                atPath: customRoot.appendingPathComponent("chapter3_mac/lang", isDirectory: true).path
            ),
            "The custom folder tree didn't mirror nested game resource directories."
        )
        try require(
            !fileManager.fileExists(atPath: customRoot.appendingPathComponent("chapter3_mac/game.ios").path),
            "Mirroring the folder structure copied game data into custom files."
        )

        let files = try ModCustomFiles.files(in: customRoot)
        try require(files["mus/custom.ogg"] == musicFile, "Custom resource paths weren't mapped from the Finder folder.")
        let chapterLibrary = customRoot.appendingPathComponent("chapter3_mac/helper.dylib")
        try Data("custom chapter library".utf8).write(to: chapterLibrary)
        let updatedFiles = try ModCustomFiles.files(in: customRoot)
        try require(
            updatedFiles["chapter3_mac/helper.dylib"] == chapterLibrary,
            "A custom chapter dylib wasn't mapped to its matching game resource path."
        )

        let outsideFile = temporaryRoot.appendingPathComponent("outside.ogg")
        try Data("outside".utf8).write(to: outsideFile)
        try fileManager.createSymbolicLink(
            at: customRoot.appendingPathComponent("linked.ogg"),
            withDestinationURL: outsideFile
        )
        do {
            _ = try ModCustomFiles.files(in: customRoot)
            throw validationError("A symbolic link in the custom-files folder was accepted.")
        } catch ModManagerError.unsafePath {
        }
    }

    private static func validateModArchive() throws {
        guard let xdelta = DeltaModBuilder.xdeltaExecutable() else {
            throw validationError("xdelta3 is not installed.")
        }
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("DMT-Test-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let windowsFolder = temporaryRoot.appendingPathComponent("Windows", isDirectory: true)
        let windowsChapter = windowsFolder.appendingPathComponent("chapter3_windows", isDirectory: true)
        let backupRoot = temporaryRoot.appendingPathComponent("Backups", isDirectory: true)
        let modFolder = temporaryRoot.appendingPathComponent("Mod", isDirectory: true)
        let appSupport = temporaryRoot.appendingPathComponent("AppData", isDirectory: true)
        try fileManager.createDirectory(at: windowsChapter, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: modFolder, withIntermediateDirectories: true)

        let windowsLauncherSource = windowsFolder.appendingPathComponent("data.win")
        try Data("original launcher source".utf8).write(to: windowsLauncherSource)
        let source = windowsChapter.appendingPathComponent("data.win")
        let target = temporaryRoot.appendingPathComponent("patched-data.win")
        try Data("original chapter source".utf8).write(to: source)
        try Data("patched chapter contents".utf8).write(to: target)
        try WindowsBackup.backup(from: windowsFolder, to: backupRoot)

        let deltaPatch = modFolder.appendingPathComponent("chapter3.xdelta")
        try run(
            executable: xdelta,
            arguments: ["-e", "-s", source.path, target.path, deltaPatch.path]
        )
        try Data("extra mod music".utf8).write(to: modFolder.appendingPathComponent("extra.ogg"))
        try Data("windows dll".utf8).write(to: modFolder.appendingPathComponent("helper.dll"))
        try Data([137, 80, 78, 71]).write(to: modFolder.appendingPathComponent("_icon.png"))
        try Data("""
        {
          "metadata": {
            "name": "Test Chapter Mod",
            "version": "2.0",
            "description": "A test mod",
            "author": ["Test Author"]
          },
          "deltaruneTargetVersion": "1.06"
        }
        """.utf8).write(to: modFolder.appendingPathComponent("_deltamodinfo.json"))
        try Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <patch type="xdelta" patch="./chapter3.xdelta" to="./chapter3_windows/data.win" />
        <patch type="override" patch="./extra.ogg" to="./mus/extra.ogg" note="Rock & Roll" />
        <patch type="override" patch="./helper.dll" to="./chapter3_windows/helper.dll" />
        """.utf8).write(to: modFolder.appendingPathComponent("modding.xml"))

        let archive = temporaryRoot.appendingPathComponent("test.deltamod")
        try makeArchive(from: modFolder, at: archive)
        let result = try DeltaModBuilder.build(
            archive: archive,
            windowsBackup: backupRoot,
            supportRoot: appSupport
        )

        try require(result.instance.name == "Test Chapter Mod", "Mod metadata was not read.")
        try require(result.instance.targetGameVersion == "1.06", "Target game version was not read.")
        try require(result.instance.iconFile != nil, "Mod icon was not imported.")
        try require(
            Set(result.instance.payloads.map(\.resourcePath)) == Set(["chapter3_mac/game.ios", "mus/extra.ogg"]),
            "Patch or override destinations were incorrect."
        )
        try require(try DeltaModBuilder.isDeltamodArchive(archive), "Deltamod archive wasn't recognized.")
        try require(result.instance.warnings.contains { $0.contains("helper.dll") }, "Windows DLL was not reported.")
        guard let skippedDLL = result.instance.skippedFiles?.first(where: {
            $0.targetPath == "chapter3_windows/helper.dll"
        }) else {
            throw validationError("A skipped Windows DLL wasn't made replaceable.")
        }
        try require(
            skippedDLL.sourcePath == "helper.dll"
                && skippedDLL.macReplacementPath == "chapter3_mac/helper.dylib",
            "The Windows DLL replacement target wasn't mapped to its Mac chapter path."
        )

        let chapterPayload = try requirePayload("chapter3_mac/game.ios", in: result.instance)
        let patchedPayload = result.directory.appendingPathComponent("Payloads")
            .appendingPathComponent(chapterPayload.instanceFile)
        try require(
            try Data(contentsOf: patchedPayload) == Data("patched chapter contents".utf8),
            "xdelta output differs from expected patched data."
        )

        let musicPayload = try requirePayload("mus/extra.ogg", in: result.instance)
        let copiedMusic = result.directory.appendingPathComponent("Payloads")
            .appendingPathComponent(musicPayload.instanceFile)
        try require(
            try Data(contentsOf: copiedMusic) == Data("extra mod music".utf8),
            "Override file was not copied into the instance."
        )
        let repatchedDirectory = temporaryRoot.appendingPathComponent("RepatchedInstance", isDirectory: true)
        try fileManager.copyItem(at: result.directory, to: repatchedDirectory)
        let dylibReplacement = temporaryRoot.appendingPathComponent("helper.dylib")
        try Data("macOS helper library".utf8).write(to: dylibReplacement)
        let repatchedInstance = try ModInstancePayloadMerger.replaceSkippedFile(
            skippedDLL,
            with: dylibReplacement,
            in: repatchedDirectory
        )
        let dllReplacementPayload = try requirePayload("chapter3_mac/helper.dylib", in: repatchedInstance)
        let dylibPayloadURL = repatchedDirectory.appendingPathComponent("Payloads")
            .appendingPathComponent(dllReplacementPayload.instanceFile)
        try require(
            try Data(contentsOf: dylibPayloadURL) == Data("macOS helper library".utf8)
                && repatchedInstance.skippedFiles?.isEmpty == true
                && !repatchedInstance.warnings.contains { $0.contains("helper.dll") },
            "Repatching with a Mac dylib didn't replace the unsupported DLL warning and add its payload."
        )
        let dllOnlyFolder = temporaryRoot.appendingPathComponent("DLLOnlyMod", isDirectory: true)
        try fileManager.createDirectory(at: dllOnlyFolder, withIntermediateDirectories: true)
        try Data("Windows-only helper".utf8).write(to: dllOnlyFolder.appendingPathComponent("helper.dll"))
        try Data("{\"metadata\":{\"name\":\"DLL Only Mod\"}}".utf8)
            .write(to: dllOnlyFolder.appendingPathComponent("_deltamodinfo.json"))
        try Data("""
        <patch type="override" patch="./helper.dll" to="./chapter3_windows/helper.dll" />
        """.utf8).write(to: dllOnlyFolder.appendingPathComponent("modding.xml"))
        let dllOnlyArchive = temporaryRoot.appendingPathComponent("dll-only.deltamod")
        try makeArchive(from: dllOnlyFolder, at: dllOnlyArchive)
        let dllOnlyInstance = try DeltaModBuilder.build(
            archive: dllOnlyArchive,
            windowsBackup: backupRoot,
            supportRoot: appSupport
        )
        try require(
            dllOnlyInstance.instance.payloads.isEmpty
                && dllOnlyInstance.instance.skippedFiles?.count == 1,
            "A DLL-only mod couldn't create an instance to offer a Mac replacement."
        )

        let g3mFolder = temporaryRoot.appendingPathComponent("G3MMod", isDirectory: true)
        try fileManager.createDirectory(at: g3mFolder, withIntermediateDirectories: true)
        try fileManager.copyItem(at: deltaPatch, to: g3mFolder.appendingPathComponent("chapter3.xdelta"))
        try fileManager.copyItem(
            at: modFolder.appendingPathComponent("extra.ogg"),
            to: g3mFolder.appendingPathComponent("extra.ogg")
        )
        try fileManager.copyItem(
            at: modFolder.appendingPathComponent("_icon.png"),
            to: g3mFolder.appendingPathComponent("icon.png")
        )
        let g3mConfig: [String: Any] = [
            "config_version": "2.0.0",
            "id": "test_g3m_mod",
            "name": "Test G3M Mod",
            "version": "1.2.0",
            "authors": ["G3M Tester"],
            "game": "deltarune",
            "game_version": "1.06",
            "icon": "${mod_path}/icon.png",
            "files": [
                [
                    "Chapter 3": [
                        [
                            "source": "${mod_path}/chapter3.xdelta",
                            "target": "${game_path}/chapter3_windows/data.win",
                            "type": "patch",
                            "source_hash": try sha256(g3mFolder.appendingPathComponent("chapter3.xdelta")),
                            "target_hash": try sha256(source)
                        ],
                        [
                            "source": "${mod_path}/extra.ogg",
                            "target": "${game_path}/mus/extra.ogg",
                            "type": "overwrite"
                        ]
                    ]
                ],
                ["source": "${mod_path}/README.md", "type": "info"]
            ]
        ]
        let g3mConfigURL = g3mFolder.appendingPathComponent("mod_config.json")
        try JSONSerialization.data(withJSONObject: g3mConfig, options: [.prettyPrinted, .sortedKeys])
            .write(to: g3mConfigURL)
        let g3mArchive = temporaryRoot.appendingPathComponent("test-g3m.zip")
        try makeArchive(from: g3mFolder, at: g3mArchive)
        try require(try DeltaModBuilder.archiveKind(g3mArchive) == .g3m, "G3M package wasn't recognized.")
        let g3mInstance = try DeltaModBuilder.build(
            archive: g3mArchive,
            windowsBackup: backupRoot,
            supportRoot: appSupport
        )
        try require(g3mInstance.instance.name == "Test G3M Mod", "G3M metadata wasn't imported.")
        try require(g3mInstance.instance.iconFile != nil, "G3M icon wasn't imported.")
        try require(
            Set(g3mInstance.instance.payloads.map(\.resourcePath)) == Set([
                "chapter3_mac/game.ios",
                "mus/extra.ogg"
            ]),
            "G3M chapter patch or overwrite destinations were incorrect."
        )
        let g3mChapter = try requirePayload("chapter3_mac/game.ios", in: g3mInstance.instance)
        let g3mPatchedData = g3mInstance.directory.appendingPathComponent("Payloads")
            .appendingPathComponent(g3mChapter.instanceFile)
        try require(
            try Data(contentsOf: g3mPatchedData) == Data("patched chapter contents".utf8),
            "G3M xdelta output differs from expected patched data."
        )

        let legacyG3MFolder = temporaryRoot.appendingPathComponent("LegacyG3M", isDirectory: true)
        try fileManager.createDirectory(at: legacyG3MFolder, withIntermediateDirectories: true)
        let legacyTarget = Data("legacy G3M patched chapter".utf8)
        let legacyPatch = legacyG3MFolder.appendingPathComponent("chapter3.bps")
        try makeBPSPatch(source: Data(contentsOf: source), target: legacyTarget, at: legacyPatch)
        let sourceChecksum = String(try sha256(source).dropFirst("sha256:".count))
        try Data("""
        name = "Legacy G3M Patch"
        version = "1.0"
        description = "Legacy package test"
        author = ["G3M Tester"]

        [[neededFiles]]
        file = "./chapter3_windows/data.win"
        checksum = "\(sourceChecksum)"
        """.utf8).write(to: legacyG3MFolder.appendingPathComponent("meta.toml"))
        try Data("""
        <patch type="bps" patch="./chapter3.bps" to="./chapter3_windows/data.win" />
        """.utf8).write(to: legacyG3MFolder.appendingPathComponent("modding.xml"))
        let legacyG3MArchive = temporaryRoot.appendingPathComponent("legacy-g3m.zip")
        try makeArchive(from: legacyG3MFolder, at: legacyG3MArchive)
        try require(
            try DeltaModBuilder.archiveKind(legacyG3MArchive) == .legacyG3M,
            "Legacy G3M package wasn't recognized."
        )
        let legacyInstance = try DeltaModBuilder.build(
            archive: legacyG3MArchive,
            windowsBackup: backupRoot,
            supportRoot: appSupport
        )
        try require(legacyInstance.instance.name == "Legacy G3M Patch", "Legacy G3M TOML metadata wasn't read.")
        let legacyPayload = try requirePayload("chapter3_mac/game.ios", in: legacyInstance.instance)
        let legacyPatchedData = legacyInstance.directory.appendingPathComponent("Payloads")
            .appendingPathComponent(legacyPayload.instanceFile)
        try require(
            try Data(contentsOf: legacyPatchedData) == legacyTarget,
            "Legacy G3M BPS output differs from expected patched data."
        )

        var invalidG3MConfig = g3mConfig
        guard var invalidGroups = invalidG3MConfig["files"] as? [[String: Any]],
              var invalidChapter = invalidGroups[0]["Chapter 3"] as? [[String: Any]] else {
            throw validationError("Test G3M configuration could not be modified.")
        }
        invalidChapter[0]["source_hash"] = "sha256:" + String(repeating: "0", count: 64)
        invalidGroups[0]["Chapter 3"] = invalidChapter
        invalidG3MConfig["files"] = invalidGroups
        try JSONSerialization.data(withJSONObject: invalidG3MConfig, options: [.prettyPrinted, .sortedKeys])
            .write(to: g3mConfigURL)
        let invalidG3MArchive = temporaryRoot.appendingPathComponent("invalid-g3m.zip")
        try makeArchive(from: g3mFolder, at: invalidG3MArchive)
        do {
            _ = try DeltaModBuilder.build(
                archive: invalidG3MArchive,
                windowsBackup: backupRoot,
                supportRoot: appSupport
            )
            throw validationError("A mismatched G3M source hash was accepted.")
        } catch ModManagerError.invalidArchive {
        }

        let manualTarget = temporaryRoot.appendingPathComponent("manual-patched-data.win")
        try Data("manual chapter three".utf8).write(to: manualTarget)
        let manualPatch = temporaryRoot.appendingPathComponent("chapter3_manual.xdelta")
        try run(
            executable: xdelta,
            arguments: ["-e", "-s", source.path, manualTarget.path, manualPatch.path]
        )
        let manualLauncherTarget = temporaryRoot.appendingPathComponent("manual-patched-launcher.win")
        try Data("manual launcher contents".utf8).write(to: manualLauncherTarget)
        let manualLauncherPatch = temporaryRoot.appendingPathComponent("launcher_60fps.xdelta")
        try run(
            executable: xdelta,
            arguments: ["-e", "-s", windowsLauncherSource.path, manualLauncherTarget.path, manualLauncherPatch.path]
        )
        try require(
            ManualPatchOption(path: manualLauncherPatch.lastPathComponent).suggestsLauncher,
            "A launcher patch filename wasn't recognized."
        )
        try require(
            try DeltaModBuilder.manualPatchOptions(archive: manualPatch, supportRoot: appSupport)
                .map(\.path) == [manualPatch.lastPathComponent],
            "A standalone xdelta wasn't offered as a selectable patch."
        )
        let manualArchiveFolder = temporaryRoot.appendingPathComponent("ManualMod", isDirectory: true)
        try FileManager.default.createDirectory(at: manualArchiveFolder, withIntermediateDirectories: true)
        let windowsChapter2 = windowsFolder.appendingPathComponent("chapter2_windows", isDirectory: true)
        try fileManager.createDirectory(at: windowsChapter2, withIntermediateDirectories: true)
        let source2 = windowsChapter2.appendingPathComponent("data.win")
        try Data("chapter two source".utf8).write(to: source2)
        try WindowsBackup.backup(from: windowsFolder, to: backupRoot)
        try Data("{\"test\":\"green ralsei language override\"}".utf8)
            .write(to: manualArchiveFolder.appendingPathComponent("lang_en.json"))

        let manualTarget2 = temporaryRoot.appendingPathComponent("manual-patched-data-ch2.win")
        try Data("manual chapter two".utf8).write(to: manualTarget2)
        let manualPatch2 = temporaryRoot.appendingPathComponent("chapter2_manual.xdelta")
        try run(
            executable: xdelta,
            arguments: ["-e", "-s", source2.path, manualTarget2.path, manualPatch2.path]
        )
        try FileManager.default.copyItem(
            at: manualPatch2,
            to: manualArchiveFolder.appendingPathComponent(manualPatch2.lastPathComponent)
        )
        try FileManager.default.copyItem(
            at: manualPatch,
            to: manualArchiveFolder.appendingPathComponent(manualPatch.lastPathComponent)
        )
        try FileManager.default.copyItem(
            at: manualLauncherPatch,
            to: manualArchiveFolder.appendingPathComponent(manualLauncherPatch.lastPathComponent)
        )
        try Data("chapter three helper library".utf8)
            .write(to: manualArchiveFolder.appendingPathComponent("chapter3_audio.dylib"))
        let manualArchive = temporaryRoot.appendingPathComponent("manual.zip")
        try makeArchive(from: manualArchiveFolder, at: manualArchive)
        try require(!DeltaModBuilder.isDeltamodArchive(manualArchive), "Manual archive was treated as a Deltamod.")
        let manualOptions = try DeltaModBuilder.manualPatchOptions(
            archive: manualArchive,
            supportRoot: appSupport
        )
        try require(
            manualOptions.map(\.path) == [
                "chapter2_manual.xdelta",
                "chapter3_audio.dylib",
                "chapter3_manual.xdelta",
                "launcher_60fps.xdelta"
            ],
            "Manual archive analysis returned \(manualOptions.map(\.path)) instead of all xdelta patch names."
        )
        try require(
            manualOptions.first(where: { $0.path == "chapter3_audio.dylib" })?.kind == .dylib,
            "A dylib in a manual archive wasn't identified as a chapter file."
        )
        try require(
            manualOptions.filter { $0.kind != .dylib }.compactMap(\.suggestedChapter) == [2, 3],
            "Chapter numbers in manual patch filenames weren't detected."
        )
        try require(
            manualOptions.first(where: { $0.path == "launcher_60fps.xdelta" })?.suggestsLauncher == true,
            "The launcher patch in a ZIP wasn't auto-assigned to the launcher."
        )
        try require(
            ManualPatchOption(path: "Chapter1LocalMultiplayerVer11_5.xdelta").suggestedChapter == 1,
            "A chapter number directly followed by a filename suffix wasn't detected."
        )
        try require(
            ManualPatchOption(path: "nobulletcooldownsCh1_v1.5.0.xdelta").suggestedChapter == 1,
            "An embedded capitalized Ch chapter marker wasn't detected."
        )
        try require(
            ManualPatchOption(path: "nobulletcooldownsCh5_v1.5.0.xdelta").suggestedChapter == 5,
            "An embedded capitalized Ch5 chapter marker wasn't detected."
        )
        try require(
            ManualPatchOption(path: "patch1.xdelta").suggestedChapter == nil,
            "The chapter detector mistook the end of 'patch1' for chapter 1."
        )
        let manualInstance = try DeltaModBuilder.buildManual(
            archive: manualArchive,
            assignments: [
                ManualPatchAssignment(patchPath: "chapter3_manual.xdelta", chapter: 3),
                ManualPatchAssignment(patchPath: "chapter2_manual.xdelta", chapter: 2),
                ManualPatchAssignment(
                    patchPath: "launcher_60fps.xdelta",
                    target: .launcher
                ),
                ManualPatchAssignment(patchPath: "chapter3_audio.dylib", chapter: 3, kind: .dylib)
            ],
            modName: "Manual Test Mod",
            windowsBackup: backupRoot,
            supportRoot: appSupport
        )
        for (resourcePath, expected) in [
            ("chapter3_mac/game.ios", "manual chapter three"),
            ("chapter2_mac/game.ios", "manual chapter two"),
            ("game.ios", "manual launcher contents")
        ] {
            let payload = try requirePayload(resourcePath, in: manualInstance.instance)
            let output = manualInstance.directory.appendingPathComponent("Payloads")
                .appendingPathComponent(payload.instanceFile)
            try require(
                try Data(contentsOf: output) == Data(expected.utf8),
                "\(resourcePath) wasn't patched from its selected xdelta."
            )
        }
        let dylibPayload = try requirePayload("chapter3_mac/chapter3_audio.dylib", in: manualInstance.instance)
        let dylibFile = manualInstance.directory.appendingPathComponent("Payloads")
            .appendingPathComponent(dylibPayload.instanceFile)
        try require(
            try Data(contentsOf: dylibFile) == Data("chapter three helper library".utf8),
            "The assigned dylib wasn't stored under the selected chapter folder."
        )

        let windowsChapter4 = windowsFolder.appendingPathComponent("chapter4_windows", isDirectory: true)
        try fileManager.createDirectory(at: windowsChapter4, withIntermediateDirectories: true)
        try Data("chapter four source".utf8).write(to: windowsChapter4.appendingPathComponent("data.win"))
        try WindowsBackup.backup(from: windowsFolder, to: backupRoot)
        let dataWinArchiveFolder = temporaryRoot.appendingPathComponent("DataWinMod", isDirectory: true)
        let dataWinSourceDirectory = dataWinArchiveFolder
            .appendingPathComponent("Chapter4_windows", isDirectory: true)
        try fileManager.createDirectory(at: dataWinSourceDirectory, withIntermediateDirectories: true)
        let replacementData = Data("complete chapter four data.win replacement".utf8)
        try replacementData.write(to: dataWinSourceDirectory.appendingPathComponent("data.win"))
        let replacementLauncherData = Data("complete launcher data.win replacement".utf8)
        try replacementLauncherData.write(to: dataWinArchiveFolder.appendingPathComponent("data.win"))
        let dataWinArchive = temporaryRoot.appendingPathComponent("data-win-mod.zip")
        try makeArchive(from: dataWinArchiveFolder, at: dataWinArchive)
        let dataWinOptions = try DeltaModBuilder.manualPatchOptions(
            archive: dataWinArchive,
            supportRoot: appSupport
        )
        let chapterDataWinOption = dataWinOptions.first(where: { $0.suggestedChapter == 4 })
        let launcherDataWinOption = dataWinOptions.first(where: { $0.path == "data.win" })
        try require(
            dataWinOptions.count == 2
                && chapterDataWinOption?.kind == .dataWin
                && launcherDataWinOption?.kind == .dataWin
                && launcherDataWinOption?.suggestsLauncher == true,
            "Chapter and launcher data.win files weren't detected as assignable full replacements."
        )
        let replacementInstance = try DeltaModBuilder.buildManual(
            archive: dataWinArchive,
            assignments: [
                ManualPatchAssignment(
                    patchPath: "Chapter4_windows/data.win",
                    chapter: 4,
                    kind: .dataWin
                ),
                ManualPatchAssignment(
                    patchPath: "data.win",
                    target: .launcher,
                    kind: .dataWin
                )
            ],
            modName: "Raw data.win Replacement",
            windowsBackup: backupRoot,
            supportRoot: appSupport
        )
        let replacementPayload = try requirePayload("chapter4_mac/game.ios", in: replacementInstance.instance)
        let replacementFile = replacementInstance.directory.appendingPathComponent("Payloads")
            .appendingPathComponent(replacementPayload.instanceFile)
        try require(
            try Data(contentsOf: replacementFile) == replacementData,
            "A selected data.win wasn't copied as a full chapter replacement."
        )
        let launcherReplacement = try requirePayload("game.ios", in: replacementInstance.instance)
        let launcherReplacementFile = replacementInstance.directory.appendingPathComponent("Payloads")
            .appendingPathComponent(launcherReplacement.instanceFile)
        try require(
            try Data(contentsOf: launcherReplacementFile) == replacementLauncherData,
            "A root data.win wasn't copied as a full launcher replacement."
        )
        let mergeDirectory = temporaryRoot.appendingPathComponent("MergedInstance", isDirectory: true)
        try fileManager.createDirectory(at: mergeDirectory, withIntermediateDirectories: true)
        try JSONEncoder.pretty.encode(replacementInstance.instance)
            .write(to: mergeDirectory.appendingPathComponent("manifest.json"), options: .atomic)
        let mergedInstance = try ModInstancePayloadMerger.merge(manualInstance, into: mergeDirectory)
        try require(
            mergedInstance.payloads.contains { $0.resourcePath == "chapter4_mac/game.ios" }
                && mergedInstance.payloads.contains { $0.resourcePath == "chapter3_mac/chapter3_audio.dylib" },
            "Adding files to an existing instance didn't preserve its previous payloads."
        )
        let mergedDylib = try requirePayload("chapter3_mac/chapter3_audio.dylib", in: mergedInstance)
        let mergedDylibFile = mergeDirectory.appendingPathComponent("Payloads")
            .appendingPathComponent(mergedDylib.instanceFile)
        try require(
            try Data(contentsOf: mergedDylibFile) == Data("chapter three helper library".utf8),
            "A merged payload wasn't copied into the existing instance."
        )
        let overwriteDirectory = temporaryRoot.appendingPathComponent("OverwriteInstance", isDirectory: true)
        try fileManager.copyItem(at: manualInstance.directory, to: overwriteDirectory)
        let oldChapterPayload = try requirePayload("chapter3_mac/game.ios", in: manualInstance.instance)
        let oldChapterPayloadURL = overwriteDirectory.appendingPathComponent("Payloads")
            .appendingPathComponent(oldChapterPayload.instanceFile)
        let overwriteSource = ModInstance(
            id: replacementInstance.instance.id,
            name: replacementInstance.instance.name,
            version: replacementInstance.instance.version,
            targetGameVersion: replacementInstance.instance.targetGameVersion,
            description: replacementInstance.instance.description,
            authors: replacementInstance.instance.authors,
            iconFile: nil,
            payloads: [
                ModPayload(
                    resourcePath: "chapter3_mac/game.ios",
                    instanceFile: launcherReplacement.instanceFile,
                    sourceLabel: "Replacement"
                )
            ],
            warnings: []
        )
        let overwritten = try ModInstancePayloadMerger.merge(
            ModBuildResult(instance: overwriteSource, directory: replacementInstance.directory),
            into: overwriteDirectory
        )
        let overwrittenChapter = try requirePayload("chapter3_mac/game.ios", in: overwritten)
        let overwrittenFile = overwriteDirectory.appendingPathComponent("Payloads")
            .appendingPathComponent(overwrittenChapter.instanceFile)
        try require(
            try Data(contentsOf: overwrittenFile) == replacementLauncherData
                && !fileManager.fileExists(atPath: oldChapterPayloadURL.path),
            "Replacing a managed path didn't install the new file and clean up its previous payload."
        )
        for chapter in [2, 3] {
            let languagePayload = try requirePayload(
                "chapter\(chapter)_mac/lang/lang_en.json",
                in: manualInstance.instance
            )
            let languageOutput = manualInstance.directory.appendingPathComponent("Payloads")
                .appendingPathComponent(languagePayload.instanceFile)
            try require(
                try Data(contentsOf: languageOutput) == Data("{\"test\":\"green ralsei language override\"}".utf8),
                "Manual language override wasn't included in Chapter \(chapter)."
            )
        }
    }

    private static func validateUndertaleModArchive() throws {
        guard let xdelta = DeltaModBuilder.xdeltaExecutable() else {
            throw validationError("xdelta3 is not installed.")
        }
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("DMT-Undertale-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let gameFolder = root.appendingPathComponent("Undertale", isDirectory: true)
        let backup = root.appendingPathComponent("UndertaleBackup", isDirectory: true)
        try fileManager.createDirectory(at: gameFolder, withIntermediateDirectories: true)
        try Data("Undertale original data".utf8).write(to: gameFolder.appendingPathComponent("data.win"))
        try UndertaleBackup.backup(from: gameFolder, to: backup)

        let fullReplacement = Data("Undertale UTMT replacement data".utf8)
        let replacementFolder = root.appendingPathComponent("FullReplacement", isDirectory: true)
        try fileManager.createDirectory(at: replacementFolder, withIntermediateDirectories: true)
        try fullReplacement.write(to: replacementFolder.appendingPathComponent("data.win"))
        let replacementArchive = root.appendingPathComponent("undertale-full-replacement.zip")
        try makeArchive(from: replacementFolder, at: replacementArchive)
        let options = try DeltaModBuilder.manualPatchOptions(
            archive: replacementArchive,
            supportRoot: root.appendingPathComponent("Support")
        )
        try require(options.count == 1 && options[0].kind == .dataWin, "Undertale data.win wasn't recognized as a manual replacement.")
        let replacement = try DeltaModBuilder.buildManual(
            archive: replacementArchive,
            assignments: [ManualPatchAssignment(patchPath: "data.win", target: .undertale, kind: .dataWin)],
            modName: "UTMT Replacement",
            windowsBackup: backup,
            supportRoot: root.appendingPathComponent("Support"),
            game: .undertale
        )
        try require(replacement.instance.targetGame == .undertale, "Undertale manual instance wasn't tagged with its game.")
        let replacementPayload = try requirePayload("game.ios", in: replacement.instance)
        let replacementFile = replacement.directory.appendingPathComponent("Payloads")
            .appendingPathComponent(replacementPayload.instanceFile)
        try require(try Data(contentsOf: replacementFile) == fullReplacement, "Undertale data.win replacement payload was incorrect.")

        let patched = Data("Undertale xdelta patch output".utf8)
        let original = backup.appendingPathComponent("data.win")
        let patchFolder = root.appendingPathComponent("XdeltaPatch", isDirectory: true)
        try fileManager.createDirectory(at: patchFolder, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("patched-undertale.win")
        try patched.write(to: target)
        let delta = patchFolder.appendingPathComponent("undertale_patch.xdelta")
        try run(executable: xdelta, arguments: ["-e", "-s", original.path, target.path, delta.path])
        let deltaArchive = root.appendingPathComponent("undertale-xdelta.zip")
        try makeArchive(from: patchFolder, at: deltaArchive)
        let deltaBuild = try DeltaModBuilder.buildManual(
            archive: deltaArchive,
            assignments: [ManualPatchAssignment(patchPath: "undertale_patch.xdelta", target: .undertale)],
            modName: "Undertale Xdelta",
            windowsBackup: backup,
            supportRoot: root.appendingPathComponent("Support"),
            game: .undertale
        )
        let deltaPayload = try requirePayload("game.ios", in: deltaBuild.instance)
        let deltaOutput = deltaBuild.directory.appendingPathComponent("Payloads")
            .appendingPathComponent(deltaPayload.instanceFile)
        try require(try Data(contentsOf: deltaOutput) == patched, "Undertale xdelta patch didn't use the Undertale backup.")

        let app = root.appendingPathComponent("UNDERTALE.app", isDirectory: true)
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        try fileManager.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data("original Mac Undertale game".utf8).write(to: resources.appendingPathComponent("game.ios"))
        try require(
            try GameAppLocator.undertaleResources(for: app) == resources.standardizedFileURL,
            "Undertale Mac resources weren't resolved from the Steam app."
        )
    }

    private static func validateGameBananaModels() throws {
        let listing = Data("""
        {
          "_idRow": 662826,
          "_sName": "Kaizo Roaring Knight (3.0)",
          "_sProfileUrl": "https://gamebanana.com/mods/662826",
          "_bHasFiles": true,
          "_aPreviewMedia": {
            "_aImages": [{
              "_sBaseUrl": "https://images.gamebanana.com/img/ss/mods",
              "_sFile530": "530-sample.jpg",
              "_sFile": "sample.jpg",
              "_sFile220": "220-sample.jpg"
            }, {
              "_sUrl": "https://images.gamebanana.com/img/ss/mods/second.jpg"
            }]
          },
          "_aSubmitter": {"_sName": "EnderCat8"},
          "_aRootCategory": {"_sName": "Difficulty Changes"},
          "_nDownloadCount": 26797,
          "_nViewCount": 1234
        }
        """.utf8)
        let mod = try JSONDecoder().decode(GameBananaMod.self, from: listing)
        try require(mod.id == 662826, "GameBanana mod id wasn't decoded.")
        try require(mod.downloadCount == 26797, "GameBanana download count wasn't decoded.")
        try require(mod.category == "Difficulty Changes", "GameBanana category wasn't decoded.")
        try require(mod.author == "EnderCat8", "GameBanana creator wasn't decoded.")
        try require(
            mod.imageURL?.absoluteString == "https://images.gamebanana.com/img/ss/mods/530-sample.jpg",
            "GameBanana preview image wasn't decoded."
        )
        try require(
            mod.imageURLs.map(\.absoluteString) == [
                "https://images.gamebanana.com/img/ss/mods/530-sample.jpg",
                "https://images.gamebanana.com/img/ss/mods/sample.jpg",
                "https://images.gamebanana.com/img/ss/mods/220-sample.jpg",
                "https://images.gamebanana.com/img/ss/mods/second.jpg"
            ],
            "GameBanana thumbnail and screenshot fallbacks weren't decoded in priority order."
        )
        let detail = try JSONDecoder().decode(GameBananaItemDetails.self, from: Data("""
        {
          "_sName": "Icon Test",
          "_sProfileUrl": "https://gamebanana.com/mods/123",
          "_aPreviewMedia": {
            "_aImages": [{
              "_sUrl": "https://images.gamebanana.com/img/ss/mods/detail-icon.png"
            }]
          },
          "_aFiles": []
        }
        """.utf8))
        try require(
            detail.imageURL?.absoluteString == "https://images.gamebanana.com/img/ss/mods/detail-icon.png",
            "The GameBanana API's direct preview image URL wasn't decoded."
        )
        try require(detail.imageURLs.count == 1, "GameBanana direct preview URL wasn't included in the fallback list.")
        let fireshockFiles = try JSONDecoder().decode([GameBananaFile].self, from: Data("""
        [
          {
            "_idRow": 1788969,
            "_sFile": "fireshock_deltamod_2983e.zip",
            "_nFilesize": 5216973,
            "_sDownloadUrl": "https://gamebanana.com/dl/1788969",
            "_bIsArchived": false,
            "_tsDateAdded": 1787085290
          },
          {
            "_idRow": 1788971,
            "_sFile": "fireshock_xdelta_bc1bc_7fa0d.rar",
            "_nFilesize": 6004506,
            "_sDownloadUrl": "https://gamebanana.com/dl/1788971",
            "_bIsArchived": false,
            "_tsDateAdded": 1787085293
          }
        ]
        """.utf8))
        try require(
            GameBananaReleasePicker.updateCandidate(
                from: fireshockFiles,
                for: .deltarune,
                installedFileID: 1788971,
                installedFileDateAdded: 1787085293
            )?.id == 1788969,
            "The Deltarune updater didn't prefer a Deltamod over a newer manual archive."
        )
        try require(
            GameBananaReleasePicker.updateCandidate(
                from: fireshockFiles,
                for: .deltarune,
                installedFileID: 1788969,
                installedFileDateAdded: 1787085290
            ) == nil,
            "An already-installed Deltamod was incorrectly marked as needing an update."
        )
        let sixtyFPSFiles = try JSONDecoder().decode([GameBananaFile].self, from: Data("""
        [
          {
            "_idRow": 1861573,
            "_sFile": "deltarune_60fps_v202.zip",
            "_nFilesize": 12430514,
            "_sDownloadUrl": "https://gamebanana.com/dl/1861573",
            "_bIsArchived": false,
            "_tsDateAdded": 1792814168
          },
          {
            "_idRow": 1861574,
            "_sFile": "deltarune_60fps_nxrune_compat_v202.zip",
            "_nFilesize": 8607387,
            "_sDownloadUrl": "https://gamebanana.com/dl/1861574",
            "_bIsArchived": false,
            "_tsDateAdded": 1792814203
          },
          {
            "_idRow": 1861577,
            "_sFile": "deltarune_60fps_advanced_v202.zip",
            "_nFilesize": 53051800,
            "_sDownloadUrl": "https://gamebanana.com/dl/1861577",
            "_bIsArchived": false,
            "_tsDateAdded": 1792814258
          }
        ]
        """.utf8))
        try require(
            GameBananaReleasePicker.updateCandidate(
                from: sixtyFPSFiles,
                for: .deltarune,
                installedFileID: 1861573,
                installedFileDateAdded: 1792814168
            ) == nil,
            "The 60 FPS updater offered a compatibility or advanced variant over the installed standard release."
        )
        try require(
            GameBananaReleasePicker.updateCandidate(
                from: sixtyFPSFiles,
                for: .deltarune,
                installedFileID: 1841436,
                installedFileDateAdded: 1791444813
            )?.id == 1861573,
            "The 60 FPS updater didn't select the standard release for an older standard install."
        )
        try require(GameBananaSort.relevance.apiValue == "best_match", "Relevance wasn't mapped to GameBanana's global order.")
        try require(GameBananaSort.popularity.apiValue == "popularity", "Popularity wasn't mapped to GameBanana's global order.")
        try require(GameBananaSort.newest.apiValue == "date", "Newest wasn't mapped to GameBanana's global order.")
        try require(GameBananaSort.recentlyUpdated.apiValue == "udate", "Recently updated wasn't mapped to GameBanana's global order.")
        try require(
            GameBananaPagination.shouldLoadCategoryMore(matchingCount: 2, canLoadMore: true),
            "A sparse category didn't request more catalog pages."
        )
        try require(
            !GameBananaPagination.shouldLoadCategoryMore(
                matchingCount: GameBananaPagination.resultsPerPage,
                canLoadMore: true
            ),
            "A populated category kept requesting pages unnecessarily."
        )
        try require(
            !GameBananaPagination.shouldLoadCategoryMore(matchingCount: 2, canLoadMore: false),
            "A category requested pages after the catalog was exhausted."
        )
        guard let oneClick = GameBananaOneClickLink(
            url: URL(string: "g3m://https//gamebanana.com/mmdl/1863022,Mod,730367?toolid=20615")!
        ) else {
            throw validationError("G3M GameBanana one-click link wasn't parsed.")
        }
        try require(
            oneClick.fileID == 1_863_022 && oneClick.modID == 730_367,
            "G3M one-click IDs were parsed incorrectly."
        )
        guard let legacyOneClick = GameBananaOneClickLink(
            url: URL(string: "deltahub://https//www.gamebanana.com/mmdl/123,Mod,456?toolid=1")!
        ) else {
            throw validationError("Legacy DELTAHUB one-click link wasn't parsed.")
        }
        try require(
            legacyOneClick.fileID == 123 && legacyOneClick.modID == 456,
            "Legacy one-click IDs were parsed incorrectly."
        )
        try require(
            GameBananaOneClickLink(url: URL(string: "g3m://https//example.com/mmdl/1,Mod,2")!) == nil,
            "An external host was accepted as a GameBanana one-click link."
        )
        try require(
            GameBananaPagination.resultsPerPage * GameBananaPagination.initialPageCount == 30
                && GameBananaPagination.prefetchCount == 15,
            "GameBanana pagination didn't match the initial 30 and 15-result prefetch."
        )
        try require(
            GameBananaPagination.shouldPrefetch(visibleIndex: 15, loadedCount: 30)
                && !GameBananaPagination.shouldPrefetch(visibleIndex: 14, loadedCount: 30),
            "The catalog prefetch threshold wasn't at 15 remaining results."
        )

        let item = Data("""
        {
          "_sName": "Kaizo Roaring Knight (3.0)",
          "_sProfileUrl": "https://gamebanana.com/mods/662826",
          "_sDescription": "A test description",
          "_aFiles": [{
            "_idRow": 1847726,
            "_sFile": "kaizo_knight_v3_0-deltamod.zip",
            "_nFilesize": 34542670,
            "_sDownloadUrl": "https://gamebanana.com/dl/1847726",
            "_bIsArchived": false,
            "_sVersion": "3.0",
            "_sDescription": "Latest version"
          }, {
            "_idRow": 1847000,
            "_sFile": "kaizo_knight_v2_0-deltamod.zip",
            "_nFilesize": 2000,
            "_sDownloadUrl": "https://gamebanana.com/dl/1847000",
            "_bIsArchived": true,
            "_sDescription": "Old version"
          }]
        }
        """.utf8)
        let details = try JSONDecoder().decode(GameBananaItemDetails.self, from: item)
        try require(details.files.count == 2, "GameBanana release list wasn't decoded.")
        try require(details.files[0].isDeltamod, "Deltamod release wasn't recognized.")
        try require(!details.files[0].isArchived, "Current release was marked archived.")
        try require(details.files[0].isActiveDeltamod, "Current Deltamod wasn't marked compatible.")
        try require(details.files[0].releaseTitle == "Version 3.0", "GameBanana release version wasn't shown.")
        try require(
            details.files[1].isSelectableRelease && !details.files[1].isSupportedRelease,
            "An archived but supported version wasn't selectable separately from compatibility checks."
        )
        let manualFile = GameBananaFile(
            id: 1,
            name: "manual-patch.zip",
            size: 20,
            downloadURL: URL(string: "https://gamebanana.com/dl/1")!,
            isArchived: false,
            version: nil,
            description: nil,
            dateAdded: nil
        )
        try require(manualFile.isManualPatchDownload, "Manual ZIP download wasn't recognized.")
        let rarFile = GameBananaFile(
            id: 2,
            name: "kaizov5_1e9db.rar",
            size: 40,
            downloadURL: URL(string: "https://gamebanana.com/dl/2")!,
            isArchived: false,
            version: nil,
            description: nil,
            dateAdded: nil
        )
        try require(
            rarFile.isManualPatchDownload && rarFile.isSelectableRelease,
            "GameBanana RAR download wasn't recognized as a supported manual release."
        )
        try require(
            try DeltaModBuilder.archiveKind(URL(fileURLWithPath: "manual.rar")) == .other,
            "RAR packages weren't routed to manual archive analysis."
        )
        let offlineError = NSError(
            domain: NSURLErrorDomain,
            code: URLError.notConnectedToInternet.rawValue
        )
        try require(
            GameBananaError.message(for: offlineError) == "Game Offline! Try Again Later.",
            "Offline GameBanana errors weren't mapped to the requested message."
        )
        let serverError = NSError(domain: "GameBanana", code: 503)
        try require(
            GameBananaError.message(for: serverError) != GameBananaError.offlineMessage,
            "A server error was incorrectly reported as offline."
        )
    }

    private static func validateAppUpdateVersions() throws {
        try require(
            AppUpdateService.isNewer("v1.0.4", than: "1.0.3"),
            "A newer tagged update wasn't recognized."
        )
        try require(
            !AppUpdateService.isNewer("v1.0.3", than: "1.0.3")
                && !AppUpdateService.isNewer("v1.0.2", than: "1.0.3"),
            "A current or older release was reported as an update."
        )
    }

    private static func validateRecentlyPlayedOrdering() throws {
        let older = validationInstance(id: "older", name: "Older", lastPlayedAt: Date(timeIntervalSince1970: 100))
        let neverPlayed = validationInstance(id: "never", name: "Never")
        let newer = validationInstance(id: "newer", name: "Newer", lastPlayedAt: Date(timeIntervalSince1970: 200))
        let ordered = ModInstance.orderedByLastPlayed([older, neverPlayed, newer])
        try require(
            ordered.map(\.id) == ["newer", "older", "never"],
            "Mod instances weren't ordered by most recently played."
        )

        let encoded = try JSONEncoder().encode(newer)
        let decoded = try JSONDecoder().decode(ModInstance.self, from: encoded)
        try require(
            decoded.lastPlayedAt == newer.lastPlayedAt,
            "A mod's last-played date wasn't persisted in its manifest."
        )

        let oldManifest = Data("""
        {
          "id": "legacy",
          "name": "Legacy Mod",
          "version": "",
          "description": "",
          "authors": [],
          "payloads": [],
          "warnings": []
        }
        """.utf8)
        let legacy = try JSONDecoder().decode(ModInstance.self, from: oldManifest)
        try require(legacy.lastPlayedAt == nil, "A legacy manifest without a last-played date wasn't supported.")
    }

    private static func validateCategorySections() throws {
        var violet = validationInstance(
            id: "violet",
            name: "Violet Knight",
            lastPlayedAt: Date(timeIntervalSince1970: 100)
        )
        violet.category = "Knight Mods"
        var kaizo = validationInstance(
            id: "kaizo",
            name: "Kaizo Knight",
            lastPlayedAt: Date(timeIntervalSince1970: 300)
        )
        kaizo.category = " Knight Mods "
        var orange = validationInstance(id: "orange", name: "Orange Knight")
        orange.category = "knight mods"
        let uncategorized = validationInstance(id: "uncategorized", name: "Other Mod")

        let sections = ModInstance.categorySections([violet, uncategorized, orange, kaizo])
        try require(
            sections.map(\.title) == ["Knight Mods", "Uncategorized"],
            "Categories weren't grouped case-insensitively or sorted by recent play."
        )
        try require(
            sections[0].instances.map(\.id) == ["kaizo", "violet", "orange"],
            "Mods in a category weren't ordered by most recently played: \(sections[0].instances.map(\.id))."
        )
        try require(
            sections[1].instances.map(\.id) == ["uncategorized"],
            "A mod without a category wasn't placed in Uncategorized."
        )

        let encoded = try JSONEncoder().encode(kaizo)
        let decoded = try JSONDecoder().decode(ModInstance.self, from: encoded)
        try require(decoded.category == kaizo.category, "A mod category wasn't persisted in its manifest.")
    }

    private static func validationInstance(
        id: String,
        name: String,
        lastPlayedAt: Date? = nil
    ) -> ModInstance {
        ModInstance(
            id: id,
            name: name,
            version: "",
            targetGameVersion: nil,
            description: "",
            authors: [],
            iconFile: nil,
            payloads: [],
            warnings: [],
            lastPlayedAt: lastPlayedAt
        )
    }

    private static func validateOptionalGameBananaArchive() throws {
        guard let archivePath = ProcessInfo.processInfo.environment["DMT_TEST_DELTAMOD_ARCHIVE"],
              let backupPath = ProcessInfo.processInfo.environment["DMT_TEST_WINDOWS_BACKUP"] else {
            return
        }
        let supportRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DMT-Live-Archive-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportRoot) }
        let result = try DeltaModBuilder.build(
            archive: URL(fileURLWithPath: archivePath),
            windowsBackup: URL(fileURLWithPath: backupPath),
            supportRoot: supportRoot
        )
        try require(!result.instance.name.isEmpty, "Live GameBanana metadata wasn't read.")
        try require(
            result.instance.payloads.contains { $0.resourcePath == "chapter3_mac/game.ios" },
            "Live GameBanana xdelta wasn't assigned to Chapter 3."
        )
    }

    private static func makeArchive(from directory: URL, at archive: URL) throws {
        let script = """
        import os, sys, zipfile
        root, output = sys.argv[1], sys.argv[2]
        with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as package:
            for current, _, names in os.walk(root):
                for name in names:
                    path = os.path.join(current, name)
                    package.write(path, os.path.relpath(path, root))
        """
        try run(
            executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c", script, directory.path, archive.path]
        )
    }

    private static func run(executable: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let details = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw validationError(details)
        }
    }

    private static func requirePayload(_ path: String, in instance: ModInstance) throws -> ModPayload {
        guard let payload = instance.payloads.first(where: { $0.resourcePath == path }) else {
            throw validationError("Missing payload \(path).")
        }
        return payload
    }

    private static func sha256(_ file: URL) throws -> String {
        let digest = SHA256.hash(data: try Data(contentsOf: file))
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func makeBPSPatch(source: Data, target: Data, at destination: URL) throws {
        var patch = Data("BPS1".utf8)
        patch.append(contentsOf: encodeBPSNumber(UInt64(source.count)))
        patch.append(contentsOf: encodeBPSNumber(UInt64(target.count)))
        patch.append(contentsOf: encodeBPSNumber(0))
        patch.append(contentsOf: encodeBPSNumber((UInt64(target.count - 1) << 2) | 1))
        patch.append(target)
        patch.appendLittleEndian(crc32(source))
        patch.appendLittleEndian(crc32(target))
        patch.appendLittleEndian(crc32(patch))
        try patch.write(to: destination)
    }

    private static func encodeBPSNumber(_ value: UInt64) -> [UInt8] {
        var value = value
        var result: [UInt8] = []
        while true {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value == 0 {
                byte |= 0x80
                result.append(byte)
                return result
            }
            result.append(byte)
            value -= 1
        }
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1
            }
        }
        return ~crc
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else {
            throw validationError(message)
        }
    }

    private static func validationError(_ message: String) -> NSError {
        NSError(
            domain: "DeltaruneModManagerValidation",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

private extension Data {
    mutating func appendLittleEndian(_ value: UInt32) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}
