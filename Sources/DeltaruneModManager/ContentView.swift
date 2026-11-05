import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct DeltaruneModManagerApp: App {
    var body: some Scene {
        Window("DELTARUNE Mod Manager", id: "main") {
            ContentView()
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 960, height: 700)
    }
}

struct ContentView: View {
    @StateObject private var model = AppModel()
    @StateObject private var catalog = GameBananaCatalog()
    @State private var section: MainSection = .discover
    @State private var selectedMod: GameBananaMod?
    @State private var editingInstance: ModInstance?
    @State private var instanceSearchText = ""
    @State private var isModSidebarCollapsed = false
    @State private var isDownloadQueuePresented = false
    @AppStorage("showModLibrary") private var showModLibrary = false
    @AppStorage("collapsedModCategories") private var collapsedModCategoriesData = ""
    @State private var targetedCategoryID: String?
    @State private var pendingCategoryInstanceID: String?
    @State private var newCategoryName = ""
    @State private var isCreatingCategory = false
    @State private var windowsFolder: URL?
    @State private var gameApp: URL?

    var body: some View {
        Group {
            if model.settings == nil {
                SetupView(model: model, windowsFolder: $windowsFolder, gameApp: $gameApp)
            } else {
                dashboard
            }
        }
        .frame(minWidth: 820, minHeight: 600)
        .background {
            GeometryReader { geometry in
                ZStack {
                    Color(red: 0.045, green: 0.065, blue: 0.13)
                    if let image = titleBackground {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                            .overlay(Color(red: 0.015, green: 0.025, blue: 0.075).opacity(0.70))
                    }
                }
            }
            .ignoresSafeArea()
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if gameApp == nil {
                gameApp = model.setupGameApp
            }
        }
        .onOpenURL { url in
            if url.scheme?.lowercased() == "dmt" {
                model.handleLaunchShortcut(url)
            } else {
                model.handleOneClickInstall(url, catalog: catalog)
            }
        }
        .onChange(of: section) { newSection in
            if newSection == .instances {
                model.refreshMissingGameBananaIcons(catalog: catalog)
                model.checkForModUpdates(catalog: catalog)
            }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .sheet(item: $selectedMod) { mod in
            GameBananaModDetailSheet(mod: mod, catalog: catalog) { file in
                model.downloadAndInstall(
                    file,
                    modName: mod.name,
                    gameBananaIconURLs: mod.imageURLs,
                    game: .deltarune,
                    gameBananaModID: mod.id
                )
            }
        }
        .sheet(item: $model.manualPatchSelection) { selection in
            ManualPatchAssignmentSheet(selection: selection, actionTitle: "Create Instance") { assignments, name in
                model.installManualArchive(selection, assignments: assignments, modName: name)
            } cancel: {
                model.cancelManualPatchSelection()
            }
        }
        .sheet(item: $editingInstance) { instance in
            InstanceEditorSheet(instance: instance, model: model)
        }
    }

    private var titleBackground: NSImage? {
        guard let url = Bundle.main.url(forResource: "title-background", withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }

    private var filteredInstances: [ModInstance] {
        let query = instanceSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentGameInstances = model.recentlyPlayedInstances.filter { $0.targetGame == .deltarune }
        guard !query.isEmpty else { return currentGameInstances }
        return currentGameInstances.filter { instance in
            ([instance.name, instance.version, instance.description] + instance.authors)
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var collapsedCategoryIDs: Set<String> {
        guard let data = Data(base64Encoded: collapsedModCategoriesData),
              let identifiers = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(identifiers)
    }

    private func toggleCategory(_ id: String) {
        var collapsed = collapsedCategoryIDs
        if !collapsed.insert(id).inserted {
            collapsed.remove(id)
        }
        if let data = try? JSONEncoder().encode(collapsed.sorted()) {
            collapsedModCategoriesData = data.base64EncodedString()
        }
    }

    private func moveInstance(_ instanceID: String?, to category: String) -> Bool {
        guard let instanceID,
              let instance = model.instances.first(where: { $0.id == instanceID }) else {
            return false
        }
        model.categorizeInstance(instance, as: category == "Uncategorized" ? "" : category)
        return true
    }

    private func instanceCard(for instance: ModInstance) -> some View {
        InstanceCard(
            instance: instance,
            iconURL: model.iconURL(for: instance),
            launch: { model.launch(instance) },
            isGameSessionActive: model.isGameSessionActive,
            isActiveInstance: model.activeInstanceID == instance.id,
            createDesktopShortcut: { model.createDesktopShortcut(for: instance) },
            update: model.availableModUpdates[instance.id].map { file in
                { model.updateMod(instance, using: file, catalog: catalog) }
            },
            showCustomFiles: { model.showCustomFilesInFinder(for: instance) },
            showCustomMusic: { model.showCustomMusicInFinder(for: instance) },
            replaceSkippedFile: { skippedFile in
                chooseDylibReplacement(skippedFile, for: instance)
            },
            edit: { editingInstance = instance },
            remove: { model.removeInstance(instance) },
            disabled: model.isBusy
        )
    }

    private func libraryTile(for instance: ModInstance) -> some View {
        LibraryModTile(
            instance: instance,
            iconURL: model.iconURL(for: instance),
            launch: { model.launch(instance) },
            isPlaying: model.activeInstanceID == instance.id,
            isGameSessionActive: model.isGameSessionActive,
            createDesktopShortcut: { model.createDesktopShortcut(for: instance) },
            update: model.availableModUpdates[instance.id].map { file in
                { model.updateMod(instance, using: file, catalog: catalog) }
            },
            showCustomFiles: { model.showCustomFilesInFinder(for: instance) },
            showCustomMusic: { model.showCustomMusicInFinder(for: instance) },
            edit: { editingInstance = instance },
            remove: { model.removeInstance(instance) },
            disabled: model.isBusy
        )
        .draggable(instance.id)
    }

    private var dashboard: some View {
        HStack(spacing: 0) {
            modSidebar
                .frame(width: isModSidebarCollapsed ? 34 : 78)
                .frame(maxHeight: .infinity)
                .background(.black.opacity(0.24))
                .overlay(alignment: .trailing) {
                    Rectangle().fill(.white.opacity(0.10)).frame(width: 1)
                }
                .animation(.easeInOut(duration: 0.22), value: isModSidebarCollapsed)

            VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 0) {
                            Text("DELT")
                                .tracking(2)
                            Text("A")
                                .tracking(2)
                                .overlay {
                                    Image(systemName: "heart.fill")
                                        .font(.system(size: 8, weight: .black))
                                        .foregroundStyle(.red)
                                        .offset(y: 1)
                                }
                            Text("RUNE")
                                .tracking(2)
                        }
                        .font(.system(size: 27, weight: .black, design: .rounded))
                        .fixedSize()
                        HStack(spacing: 8) {
                            Text("MOD MANAGER")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .tracking(3)
                                .foregroundStyle(.cyan)
                            Text("made by toast")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                    }

                    Spacer(minLength: 8)

                    HStack(spacing: 2) {
                        sectionButton(.discover, title: "Discover", icon: "sparkle.magnifyingglass")
                        sectionButton(.instances, title: "My Mods", icon: "square.stack.3d.up")
                        sectionButton(.settings, title: "Settings", icon: "gearshape")
                    }

                    Button {
                        isDownloadQueuePresented.toggle()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.down.circle")
                            if !model.downloadQueue.isEmpty {
                                Text("\(model.downloadQueue.count)")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .help("View the download queue")
                    .accessibilityLabel("Downloads")
                    .popover(isPresented: $isDownloadQueuePresented, arrowEdge: .bottom) {
                        DownloadQueuePopover(
                            entries: model.downloadQueue,
                            removeQueued: model.removeQueuedDownload,
                            clearFinished: model.clearFinishedDownloads
                        )
                        .frame(width: 360, height: 390)
                    }

                    Spacer(minLength: 8)

                    HStack(spacing: 8) {
                        Button {
                            model.checkForUpdates()
                        } label: {
                            if model.isCheckingForUpdates {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(width: 20)
                            } else {
                                Label("Update", systemImage: "arrow.down.circle")
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.isBusy || model.isCheckingForUpdates)
                        .help("Check for a newer version and open its installer download page.")
                        .fixedSize()

                        Button {
                            model.launchVanilla(for: .deltarune)
                        } label: {
                            Label("Launch Vanilla", systemImage: "gamecontroller")
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.isBusy)
                        .help("Launch DELTARUNE without applying a mod instance.")
                        .fixedSize()

                        Button {
                            chooseModArchive()
                        } label: {
                            Label("Install Mod", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.indigo)
                        .disabled(model.isBusy)
                        .fixedSize()
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 12)

            Rectangle().fill(.white.opacity(0.12)).frame(height: 1)

            if !model.statusMessage.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 10) {
                        if model.isBusy {
                            ProgressView().controlSize(.small)
                        } else if model.isGameSessionActive {
                            Image(systemName: "waveform")
                                .foregroundStyle(.cyan)
                        } else {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                        Text(model.statusMessage)
                            .font(.system(size: 13, weight: model.isGameSessionActive ? .semibold : .medium))
                        Spacer()
                    }

                    if model.isDownloading {
                        HStack(spacing: 10) {
                            if let progress = model.downloadProgress {
                                ProgressView(value: progress)
                                    .tint(.cyan)
                                Text("\(Int(progress * 100))%")
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.68))
                                    .frame(width: 38, alignment: .trailing)
                            } else {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Receiving download…")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.58))
                            }
                        }
                        .frame(maxWidth: 360, alignment: .leading)
                        .padding(.leading, 24)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 12)
                .background(model.isGameSessionActive ? .cyan.opacity(0.07) : .white.opacity(0.035))
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.easeInOut(duration: 0.22), value: model.isGameSessionActive)
            }

            if section == .discover {
                ModCatalogView(
                    catalog: catalog,
                    installedModIDs: Set(model.instances.compactMap(\.gameBananaModID)),
                    select: { selectedMod = $0 }
                )
            } else if section == .settings {
                settingsPage
            } else if filteredInstances.isEmpty && instanceSearchText.isEmpty {
                installedEmptyState
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.white.opacity(0.55))
                        TextField("Search your mods", text: $instanceSearchText)
                            .textFieldStyle(.plain)
                        if !instanceSearchText.isEmpty {
                            Button {
                                instanceSearchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.white.opacity(0.55))
                            }
                            .buttonStyle(.plain)
                            .fixedSize()
                        }
                    }
                    .padding(11)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 24)
                    .padding(.top, 18)

                    if filteredInstances.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 30))
                                .foregroundStyle(.white.opacity(0.45))
                            Text("No matching mods")
                                .font(.system(size: 16, weight: .semibold))
                            Text("Try a different name, version, description, or author.")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 18) {
                                HStack(spacing: 10) {
                                    if !model.availableModUpdates.isEmpty {
                                        Button {
                                            model.updateAllMods(catalog: catalog)
                                        } label: {
                                            Label(
                                                "Update All (\(model.availableModUpdates.count))",
                                                systemImage: "arrow.triangle.2.circlepath"
                                            )
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .tint(.indigo)
                                        .disabled(model.isBusy || model.isCheckingModUpdates)
                                    }
                                    if model.isCheckingModUpdates {
                                        ProgressView("Checking for mod updates…")
                                            .font(.system(size: 11))
                                    }
                                    Spacer()
                                    Button {
                                        showModLibrary.toggle()
                                    } label: {
                                        Label(
                                            showModLibrary ? "List View" : "Library",
                                            systemImage: showModLibrary ? "list.bullet" : "square.grid.2x2"
                                        )
                                    }
                                    .buttonStyle(.bordered)
                                    .help(showModLibrary ? "Show mods as detailed rows" : "Show mods as square icons")
                                }
                                LazyVStack(alignment: .leading, spacing: 20) {
                                    ForEach(ModInstance.categorySections(filteredInstances)) { category in
                                        let isCollapsed = collapsedCategoryIDs.contains(category.id)
                                        VStack(alignment: .leading, spacing: 11) {
                                            Button {
                                                toggleCategory(category.id)
                                            } label: {
                                                HStack(spacing: 10) {
                                                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                                                        .font(.system(size: 10, weight: .bold))
                                                        .foregroundStyle(.white.opacity(0.55))
                                                    Text(category.title)
                                                        .font(.system(size: 15, weight: .bold, design: .rounded))
                                                        .foregroundStyle(.white.opacity(0.9))
                                                    Text("\(category.instances.count)")
                                                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                                        .foregroundStyle(.white.opacity(0.45))
                                                    Rectangle()
                                                        .fill(.white.opacity(targetedCategoryID == category.id ? 0.55 : 0.12))
                                                        .frame(height: 1)
                                                }
                                                .contentShape(Rectangle())
                                                .padding(.vertical, 4)
                                            }
                                            .buttonStyle(.plain)
                                            .dropDestination(for: String.self) { items, _ in
                                                moveInstance(items.first, to: category.title)
                                            } isTargeted: { targeted in
                                                targetedCategoryID = targeted ? category.id : nil
                                            }
                                            if !isCollapsed {
                                                if showModLibrary {
                                                    LazyVGrid(
                                                        columns: [GridItem(.adaptive(minimum: 120, maximum: 150), spacing: 14)],
                                                        alignment: .leading,
                                                        spacing: 16
                                                    ) {
                                                        ForEach(category.instances) { instance in
                                                            libraryTile(for: instance)
                                                        }
                                                    }
                                                } else {
                                                    ForEach(category.instances) { instance in
                                                        instanceCard(for: instance)
                                                            .draggable(instance.id)
                                                    }
                                                }
                                            }
                                        }
                                    }
                                    Text("＋  Drop a mod here to create a category")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.62))
                                        .frame(maxWidth: .infinity, minHeight: 34)
                                        .background(
                                            targetedCategoryID == "new-category" ? .cyan.opacity(0.15) : .white.opacity(0.045),
                                            in: RoundedRectangle(cornerRadius: 9)
                                        )
                                        .dropDestination(for: String.self) { items, _ in
                                            guard let instanceID = items.first,
                                                  model.instances.contains(where: { $0.id == instanceID }) else {
                                                return false
                                            }
                                            pendingCategoryInstanceID = instanceID
                                            newCategoryName = ""
                                            isCreatingCategory = true
                                            return true
                                        } isTargeted: { targeted in
                                            targetedCategoryID = targeted ? "new-category" : nil
                                        }
                                }
                            }
                            .padding(24)
                        }
                        .alert("Create Category", isPresented: $isCreatingCategory) {
                            TextField("Category name", text: $newCategoryName)
                            Button("Create") {
                                guard let instanceID = pendingCategoryInstanceID,
                                      let instance = model.instances.first(where: { $0.id == instanceID }) else {
                                    return
                                }
                                model.categorizeInstance(instance, as: newCategoryName)
                                pendingCategoryInstanceID = nil
                            }
                            .disabled(newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            Button("Cancel", role: .cancel) {
                                pendingCategoryInstanceID = nil
                            }
                        } message: {
                            Text("Choose a name for the category. The dropped mod will be moved into it.")
                        }
                    }
                }
            }

            Rectangle().fill(.white.opacity(0.12)).frame(height: 1)
            HStack {
                Label("Original game files are restored after each session", systemImage: "arrow.uturn.backward")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
                Spacer()
                Text("Windows backup + Mac install configured")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 13)
            }
        }
    }

    private var modSidebar: some View {
        VStack(spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.22)) {
                    isModSidebarCollapsed.toggle()
                }
            } label: {
                Image(systemName: isModSidebarCollapsed ? "chevron.right" : "chevron.left")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.72))
                    .frame(width: 30, height: 30)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)
            .help(isModSidebarCollapsed ? "Expand mod shortcuts" : "Collapse mod shortcuts")
            .accessibilityLabel(isModSidebarCollapsed ? "Expand mod shortcuts" : "Collapse mod shortcuts")
            .padding(.top, 12)

            if !isModSidebarCollapsed {
                Text("MODS")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(1)
                    .foregroundStyle(.white.opacity(0.40))
                    .transition(.opacity)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 9) {
                        ForEach(model.recentlyPlayedInstances.filter { $0.targetGame == .deltarune }) { instance in
                            modSidebarIcon(for: instance)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .transition(.opacity)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func modSidebarIcon(for instance: ModInstance) -> some View {
        let isActive = model.activeInstanceID == instance.id
        HStack(spacing: 8) {
            Group {
                if let iconURL = model.iconURL(for: instance),
                   let image = NSImage(contentsOf: iconURL) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 11)
                            .fill(.indigo.opacity(0.28))
                        Image(systemName: "sparkles")
                            .font(.system(size: 19, weight: .medium))
                            .foregroundStyle(.cyan)
                    }
                }
            }
            .frame(width: 46, height: 46)
            .clipShape(RoundedRectangle(cornerRadius: 11))
            .overlay {
                RoundedRectangle(cornerRadius: 11)
                    .strokeBorder(isActive ? Color.green.opacity(0.9) : .white.opacity(0.13), lineWidth: isActive ? 2 : 1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
        .padding(.leading, isModSidebarCollapsed ? 0 : 16)
        .padding(.trailing, 6)
        .opacity(model.isGameSessionActive && !isActive ? 0.42 : 1)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            model.launch(instance)
        }
        .accessibilityElement()
        .accessibilityLabel(instance.name)
        .accessibilityHint("Double-click to launch this mod.")
        .disabled(model.isBusy || model.isGameSessionActive)
    }

    private var settingsPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Settings")
                .font(.system(size: 25, weight: .bold, design: .rounded))
            Text("Manage the game locations used for mod installation and launch.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.62))

            SetupPathRow(
                number: "01",
                title: "Mac DELTARUNE.app",
                detail: "Select the installed Mac game app.",
                path: model.settings?.gameAppPath,
                buttonTitle: "Change App",
                action: chooseGameAppForSettings
            )
            SetupPathRow(
                number: "02",
                title: "Windows game source",
                detail: "Choose the folder containing chapterN_windows/data.win.",
                path: model.settings?.windowsSourcePath ?? "Original source path not saved",
                buttonTitle: "Choose & Back Up",
                action: chooseWindowsBackupSource
            )
            HStack(spacing: 10) {
                Image(systemName: "externaldrive")
                    .foregroundStyle(.cyan)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Current Windows backup")
                        .font(.system(size: 13, weight: .semibold))
                    Text(model.settings?.windowsBackupPath ?? "")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.52))
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Show in Finder", systemImage: "folder") {
                    model.showWindowsBackupInFinder()
                }
                .buttonStyle(.bordered)
                .disabled(model.isBusy)
            }
            .padding(15)
            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))

            HStack(spacing: 12) {
                Image(systemName: "terminal")
                    .foregroundStyle(.cyan)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Command-line launcher")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Install `drmt` to list and launch installed mod instances from Terminal.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                    Text("Installs to ~/.local/bin/drmt")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.42))
                }
                Spacer()
                Button(model.isCLIInstalled ? "Reinstall CLI" : "Install CLI") {
                    model.installCLI()
                }
                .buttonStyle(.bordered)
                .disabled(model.isBusy)
            }
            .padding(15)
            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))

            Text("Changing the Windows source creates a fresh backup for future installs. Existing mod instances keep their current patched files.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.48))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(28)
        .frame(maxWidth: 760, maxHeight: .infinity, alignment: .topLeading)
    }

    private var installedEmptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 42))
                .foregroundStyle(.cyan.opacity(0.8))
            Text("No mod instances yet")
                .font(.system(size: 22, weight: .bold, design: .rounded))
            Text("Browse the GameBanana catalog and choose a Deltamod release, or import an archive.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.58))
                .font(.system(size: 14))
                .lineSpacing(5)
            HStack(spacing: 12) {
                Button("Discover Mods") { section = .discover }
                    .buttonStyle(.borderedProminent)
                    .tint(.indigo)
                Button("Choose Mod Archive") { chooseModArchive() }
                    .buttonStyle(.bordered)
            }
            .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sectionButton(_ item: MainSection, title: String, icon: String) -> some View {
        Button {
            section = item
        } label: {
            HStack(spacing: 7) {
                Image(systemName: icon)
                Text(title)
                    .lineLimit(1)
            }
            .font(.system(size: 12, weight: .semibold))
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .foregroundStyle(section == item ? .white : .white.opacity(0.75))
            .background {
                if section == item {
                    RoundedRectangle(cornerRadius: 9).fill(.white.opacity(0.11))
                }
            }
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func chooseModArchive() {
        let panel = NSOpenPanel()
        panel.title = "Choose a GameBanana mod archive"
        panel.message = "Deltamod and G3M packages install automatically. Manual patches are analyzed before chapter assignment."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let ext = url.pathExtension.lowercased()
        guard ext == "deltamod" || ext == "zip" || ext == "rar" || ext == "xdelta" else {
            model.errorMessage = "Choose a .deltamod, ZIP, RAR, or xdelta patch."
            return
        }
        do {
            if try DeltaModBuilder.archiveKind(url) != .other {
                model.installArchive(url)
            } else {
                model.analyzeManualArchive(
                    url,
                    modName: url.deletingPathExtension().lastPathComponent,
                    game: .deltarune
                )
            }
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    private func chooseDylibReplacement(_ skippedFile: ModSkippedFile, for instance: ModInstance) {
        let panel = NSOpenPanel()
        panel.title = "Choose a Mac replacement for \(skippedFile.targetPath)"
        panel.message = "Choose a compatible macOS .dylib. It will be installed as \(skippedFile.macReplacementPath) when this mod instance launches."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "dylib") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.replaceSkippedFile(skippedFile, with: url, in: instance)
    }

    private func chooseGameAppForSettings() {
        let panel = NSOpenPanel()
        panel.title = "Select Mac DELTARUNE.app"
        panel.message = "Choose the installed Mac game app used for modded and vanilla launches."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.updateGameApp(to: url)
    }

    private func chooseWindowsBackupSource() {
        let panel = NSOpenPanel()
        panel.title = "Select Windows DELTARUNE folder"
        panel.message = "Choose the folder containing chapterN_windows/data.win files."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.updateWindowsBackup(from: url)
    }
}

private struct DownloadQueuePopover: View {
    let entries: [DownloadQueueEntry]
    let removeQueued: (UUID) -> Void
    let clearFinished: () -> Void

    private var hasFinishedEntries: Bool {
        entries.contains { [.completed, .failed, .cancelled].contains($0.status) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Download Queue")
                    .font(.system(size: 16, weight: .bold))
                Spacer()
                if hasFinishedEntries {
                    Button("Clear Finished", action: clearFinished)
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)

            if entries.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 28))
                        .foregroundStyle(.white.opacity(0.35))
                    Text("Queue is empty")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Downloads and updates you start will appear here.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(entries) { entry in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .top, spacing: 8) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(entry.title)
                                            .font(.system(size: 12, weight: .semibold))
                                            .lineLimit(2)
                                        Text(entry.filename)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.white.opacity(0.52))
                                            .lineLimit(1)
                                        Text(entry.status.rawValue)
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(entry.status == .failed ? .orange : .cyan)
                                    }
                                    Spacer(minLength: 0)
                                    if entry.status == .queued {
                                        Button {
                                            removeQueued(entry.id)
                                        } label: {
                                            Image(systemName: "xmark")
                                        }
                                        .buttonStyle(.plain)
                                        .help("Remove from queue")
                                    } else if entry.status == .downloading || entry.status == .installing {
                                        ProgressView()
                                            .controlSize(.small)
                                    }
                                }
                                if let progress = entry.progress {
                                    ProgressView(value: progress)
                                        .tint(.cyan)
                                }
                                if let failureMessage = entry.failureMessage {
                                    Text(failureMessage)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.orange)
                                        .lineLimit(3)
                                }
                            }
                            .padding(10)
                            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
            }
        }
        .background(.black.opacity(0.55))
    }
}

private enum MainSection {
    case discover
    case instances
    case settings
}

struct ManualPatchAssignmentSheet: View {
    let selection: ManualPatchSelection
    let actionTitle: String
    let install: ([ManualPatchAssignment], String) -> Void
    let cancel: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTargets: [String: ManualPatchTarget]
    @State private var modName: String

    init(
        selection: ManualPatchSelection,
        actionTitle: String,
        install: @escaping ([ManualPatchAssignment], String) -> Void,
        cancel: @escaping () -> Void
    ) {
        self.selection = selection
        self.actionTitle = actionTitle
        self.install = install
        self.cancel = cancel
        _modName = State(initialValue: selection.modName)

        var defaults: [String: ManualPatchTarget] = [:]
        var usedTargets = Set<ManualPatchTarget>()
        for option in selection.options {
            let target: ManualPatchTarget?
            if option.suggestsLauncher {
                target = .launcher
            } else {
                target = option.suggestedChapter.map(ManualPatchTarget.chapter)
            }
            guard let target else { continue }
            if option.kind != .dylib, !usedTargets.insert(target).inserted { continue }
            defaults[option.id] = target
        }
        _selectedTargets = State(initialValue: defaults)
    }

    private var assignments: [ManualPatchAssignment] {
        selection.options.compactMap { option in
            guard let target = selectedTargets[option.id] else { return nil }
            return ManualPatchAssignment(
                patchPath: option.path,
                target: target,
                kind: option.kind
            )
        }
    }

    private func targetIsUsed(_ target: ManualPatchTarget, by option: ManualPatchOption) -> Bool {
        option.kind != .dylib && selection.options.contains {
            $0.id != option.id && $0.kind != .dylib && selectedTargets[$0.id] == target
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Assign files to game targets")
                        .font(.system(size: 18, weight: .bold))
                    Text(selection.archive.lastPathComponent)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                Spacer()
                Button("Cancel") {
                    cancel()
                    dismiss()
                }
                    .keyboardShortcut(.cancelAction)
            }
            Text("Found \(selection.options.count) installable file\(selection.options.count == 1 ? "" : "s"). Chapter and launcher names are selected automatically; you can change any selection. Launcher patches use the backed-up Windows root data.win and target the Mac app's root game.ios. Chapter files target their matching game file; dylibs are copied into the selected chapter folder. Leave files set to Skip if you don't want them installed.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.67))
                .fixedSize(horizontal: false, vertical: true)

            TextField("Name", text: $modName)
                .textFieldStyle(.roundedBorder)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(selection.options) { option in
                        HStack(spacing: 12) {
                            Image(systemName: iconName(for: option.kind))
                                .foregroundStyle(option.kind == .dataWin ? .orange : option.kind == .dylib ? .purple : .cyan)
                            Text(option.path)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .lineLimit(2)
                                .textSelection(.enabled)
                            Spacer(minLength: 8)
                            Picker("Target", selection: Binding(
                                get: { selectedTargets[option.id] },
                                set: { target in
                                    if let target {
                                        selectedTargets[option.id] = target
                                    } else {
                                        selectedTargets.removeValue(forKey: option.id)
                                    }
                                }
                            )) {
                                Text("Skip").tag(nil as ManualPatchTarget?)
                                if option.kind != .dylib {
                                    Text("Launcher").tag(ManualPatchTarget.launcher as ManualPatchTarget?)
                                        .disabled(targetIsUsed(.launcher, by: option))
                                    ForEach(1...5, id: \.self) { chapter in
                                        Text("Chapter \(chapter)")
                                            .tag(ManualPatchTarget.chapter(chapter) as ManualPatchTarget?)
                                            .disabled(targetIsUsed(.chapter(chapter), by: option))
                                    }
                                }
                            }
                            .frame(width: 155)
                        }
                        .padding(10)
                        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
                    }
                }
            }
            .frame(minHeight: 140, maxHeight: 340)

            HStack {
                Text("\(assignments.count) file\(assignments.count == 1 ? "" : "s") selected")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
                Button(actionTitle) {
                    install(assignments, modName)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(assignments.isEmpty || modName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 720, height: 540)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled()
    }

    private func iconName(for kind: ManualPatchOption.Kind) -> String {
        switch kind {
        case .xdelta: "doc.zipper"
        case .dataWin: "externaldrive"
        case .dylib: "shippingbox"
        }
    }
}

private struct SetupView: View {
    @ObservedObject var model: AppModel
    @Binding var windowsFolder: URL?
    @Binding var gameApp: URL?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("DELTARUNE")
                        .font(.system(size: 28, weight: .black, design: .rounded))
                        .tracking(3)
                    Text("MOD MANAGER SETUP")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .tracking(4)
                        .foregroundStyle(.cyan)
                }
                Spacer()
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 30))
                    .foregroundStyle(.cyan.opacity(0.8))
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 24)

            Rectangle().fill(.white.opacity(0.12)).frame(height: 1)

            VStack(alignment: .leading, spacing: 20) {
                Text("One-time setup")
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                Text("Install DELTARUNE, then select your local Windows chapter files and Mac game app. This manager uses the game files you provide and does not download or include them.")
                    .foregroundStyle(.white.opacity(0.68))
                    .font(.system(size: 14))
                    .lineSpacing(4)

                SetupPathRow(
                    number: "01",
                    title: "Windows DELTARUNE folder",
                    detail: "Must contain chapter1_windows/data.win, chapter2_windows/data.win, etc.",
                    path: windowsFolder?.path,
                    buttonTitle: "Choose Windows Folder",
                    action: chooseWindowsFolder
                )
                SetupPathRow(
                    number: "02",
                    title: "Mac DELTARUNE.app",
                    detail: "Steam's installed Mac game. We'll look in its Contents/Resources folder.",
                    path: gameApp?.path,
                    buttonTitle: "Choose Mac App",
                    action: chooseGameApp
                )

                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "info.circle.fill").foregroundStyle(.cyan)
                    Text("Select the Windows folder containing chapterN_windows/data.win files and the installed Mac app below.")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.68))
                    Spacer(minLength: 4)
                    Link(
                        "Open DELTARUNE on Steam",
                        destination: URL(string: "https://store.steampowered.com/app/1671210/DELTARUNE/")!
                    )
                    .font(.system(size: 11, weight: .semibold))
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.cyan.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))

                HStack {
                    if model.isBusy {
                        ProgressView().controlSize(.small)
                        Text(model.statusMessage).font(.system(size: 12))
                    }
                    Spacer()
                    Button("Back Up Files & Continue") {
                        model.setupWindowsFolder = windowsFolder
                        model.setupGameApp = gameApp
                        model.completeSetup()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.indigo)
                    .disabled(model.isBusy || windowsFolder == nil || gameApp == nil)
                }
            }
            .padding(30)
            .frame(maxWidth: 760, alignment: .leading)
            Spacer(minLength: 0)
        }
    }

    private func chooseWindowsFolder() {
        let panel = NSOpenPanel()
        panel.title = "Select Windows DELTARUNE folder"
        panel.message = "Choose the folder containing chapterN_windows/data.win files."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK {
            windowsFolder = panel.url
        }
    }

    private func chooseGameApp() {
        let panel = NSOpenPanel()
        panel.title = "Select Mac DELTARUNE.app"
        panel.message = "Choose the DELTARUNE app installed by Steam."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK {
            gameApp = panel.url
        }
    }
}

private struct SetupPathRow: View {
    var number: String
    var title: String
    var detail: String
    var path: String?
    var buttonTitle: String
    var action: () -> Void

    var body: some View {
        HStack(spacing: 15) {
            Text(number)
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(.cyan)
                .frame(width: 32, height: 32)
                .background(.cyan.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(path ?? detail)
                    .font(.system(size: 11, design: path == nil ? .default : .monospaced))
                    .foregroundStyle(path == nil ? .white.opacity(0.48) : .green.opacity(0.9))
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button(buttonTitle, action: action).buttonStyle(.bordered)
        }
        .padding(15)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct LibraryModTile: View {
    let instance: ModInstance
    let iconURL: URL?
    let launch: () -> Void
    let isPlaying: Bool
    let isGameSessionActive: Bool
    let createDesktopShortcut: () -> Void
    let update: (() -> Void)?
    let showCustomFiles: () -> Void
    let showCustomMusic: () -> Void
    let edit: () -> Void
    let remove: () -> Void
    let disabled: Bool
    @State private var confirmRemoval = false

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                Button(action: launch) {
                    icon
                        .frame(width: 108, height: 108)
                        .clipShape(RoundedRectangle(cornerRadius: 13))
                        .overlay {
                            RoundedRectangle(cornerRadius: 13)
                                .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                        }
                        .overlay(alignment: .bottomTrailing) {
                            if isPlaying {
                                Image(systemName: "waveform")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.black.opacity(0.9))
                                    .padding(6)
                                    .background(.green, in: Circle())
                                    .padding(6)
                            }
                        }
                }
                .buttonStyle(.plain)
                .disabled(disabled || (isGameSessionActive && !isPlaying))
                .help(isGameSessionActive ? "Close the running game before launching another instance." : "Launch \(instance.name)")

                Menu {
                    Button("Play", systemImage: isPlaying ? "waveform" : "play.fill", action: launch)
                        .disabled(disabled || isGameSessionActive)
                    Button("Edit", systemImage: "slider.horizontal.3", action: edit)
                        .disabled(disabled)
                    if let update {
                        Button("Update Mod", systemImage: "arrow.triangle.2.circlepath", action: update)
                            .disabled(disabled)
                    }
                    Divider()
                    Button("Add To Desktop", systemImage: "macwindow", action: createDesktopShortcut)
                        .disabled(disabled)
                    Button("Show in Finder", systemImage: "folder", action: showCustomFiles)
                        .disabled(disabled)
                    if instance.targetGame == .deltarune {
                        Button("Music Folder", systemImage: "music.note", action: showCustomMusic)
                            .disabled(disabled)
                    }
                    Divider()
                    Button("Remove", systemImage: "trash", role: .destructive) {
                        confirmRemoval = true
                    }
                    .disabled(disabled)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 27, height: 27)
                        .background(.black.opacity(0.72), in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.2), lineWidth: 1))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .padding(5)
            }

            Text(instance.name)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 34)
            if !instance.version.isEmpty {
                Text(instance.version)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.cyan)
                    .lineLimit(1)
            }
        }
        .padding(9)
        .frame(width: 132)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(isPlaying ? .green.opacity(0.42) : .white.opacity(0.08), lineWidth: 1)
        }
        .confirmationDialog("Remove \(instance.name)?", isPresented: $confirmRemoval, titleVisibility: .visible) {
            Button("Remove Instance", role: .destructive, action: remove)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the saved mod instance. The original game files are unaffected.")
        }
    }

    @ViewBuilder
    private var icon: some View {
        if let iconURL, let image = NSImage(contentsOf: iconURL) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 13).fill(.indigo.opacity(0.2))
                Image(systemName: "sparkles")
                    .font(.system(size: 27))
                    .foregroundStyle(.cyan)
            }
        }
    }
}

private struct InstanceCard: View {
    let instance: ModInstance
    let iconURL: URL?
    let launch: () -> Void
    let isGameSessionActive: Bool
    let isActiveInstance: Bool
    let createDesktopShortcut: () -> Void
    let update: (() -> Void)?
    let showCustomFiles: () -> Void
    let showCustomMusic: () -> Void
    let replaceSkippedFile: (ModSkippedFile) -> Void
    let edit: () -> Void
    let remove: () -> Void
    let disabled: Bool
    @State private var confirmRemoval = false
    @State private var showingOptions = false
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 17) {
            icon
                .frame(width: 76, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                }
                .shadow(color: .cyan.opacity(isHovered ? 0.20 : 0.08), radius: isHovered ? 12 : 6)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(instance.name)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    if !instance.version.isEmpty {
                        Text(instance.version)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.cyan)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.cyan.opacity(0.10), in: Capsule())
                    }
                    if isActiveInstance {
                        Label("PLAYING", systemImage: "waveform")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.green.opacity(0.12), in: Capsule())
                            .transition(.scale.combined(with: .opacity))
                    }
                }

                Text(instance.description)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(3)
                Text("\(instance.payloads.count) Mac file\(instance.payloads.count == 1 ? "" : "s") in this instance")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.42))
                if !instance.warnings.isEmpty {
                    DisclosureGroup("Compatibility notes (\(instance.warnings.count))") {
                        ForEach(instance.warnings, id: \.self) { warning in
                            Text(warning)
                                .font(.system(size: 11))
                                .foregroundStyle(.orange.opacity(0.85))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(instance.skippedFiles ?? []) { skippedFile in
                            HStack(alignment: .top, spacing: 8) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Windows-only file: \(skippedFile.targetPath)")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.orange.opacity(0.9))
                                    Text("Choose a Mac .dylib to replace it at \(skippedFile.macReplacementPath).")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.white.opacity(0.58))
                                }
                                Spacer(minLength: 4)
                                Button("Repatch with .dylib…") {
                                    replaceSkippedFile(skippedFile)
                                }
                                .buttonStyle(.bordered)
                                .disabled(disabled)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .font(.system(size: 11))
                    .tint(.orange)
                }
            }
            Spacer(minLength: 10)
            VStack(alignment: .trailing, spacing: 9) {
                HStack(spacing: 7) {
                    Button(action: launch) {
                        Label(isActiveInstance ? "Playing" : "Play",
                              systemImage: isActiveInstance ? "waveform" : "play.fill")
                            .frame(minWidth: 86)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.indigo)
                    .disabled(disabled || isGameSessionActive)
                    .opacity(isGameSessionActive && !isActiveInstance ? 0.48 : 1)
                    .help(isGameSessionActive ? "Close the running game before launching another instance." : "Launch this mod.")

                    Button {
                        withAnimation(.easeInOut(duration: 0.22)) {
                            showingOptions.toggle()
                        }
                    } label: {
                        Image(systemName: showingOptions ? "xmark" : "ellipsis")
                            .frame(width: 30, height: 22)
                    }
                    .buttonStyle(.bordered)
                    .help(showingOptions ? "Hide mod options" : "Show mod options")
                    .accessibilityLabel(showingOptions ? "Hide options for \(instance.name)" : "More options for \(instance.name)")
                    .disabled(disabled)
                }

                if showingOptions {
                    VStack(alignment: .trailing, spacing: 7) {
                        Button(action: createDesktopShortcut) {
                            Label("Add To Desktop", systemImage: "macwindow")
                                .frame(minWidth: 132, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                        .help("Create a desktop shortcut that launches this mod through the manager.")
                        .disabled(disabled)

                        Button(action: edit) {
                            Label("Edit", systemImage: "slider.horizontal.3")
                                .frame(minWidth: 132, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                        .disabled(disabled)

                        if let update {
                            Button(action: update) {
                                Label("Update Mod", systemImage: "arrow.triangle.2.circlepath")
                                    .frame(minWidth: 132, alignment: .leading)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)
                            .disabled(disabled)
                        }

                        Button(action: showCustomFiles) {
                            Label("Show in Finder", systemImage: "folder")
                                .frame(minWidth: 132, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                        .help("Open the empty folder tree matching Contents/Resources. Add a file at its matching path (for example chapter3_mac/helper.dylib); it is applied only while this mod runs.")
                        .disabled(disabled)

                        if instance.targetGame == .deltarune {
                            Button(action: showCustomMusic) {
                                Label("Music Folder", systemImage: "music.note")
                                    .frame(minWidth: 132, alignment: .leading)
                            }
                            .buttonStyle(.bordered)
                            .help("Open this mod's CustomFiles/mus folder for custom songs.")
                            .disabled(disabled)
                        }

                        Button("Remove", role: .destructive) {
                            confirmRemoval = true
                        }
                        .frame(minWidth: 132, alignment: .leading)
                        .disabled(disabled)
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }

        .padding(17)
        .background {
            RoundedRectangle(cornerRadius: 15)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(isHovered ? 0.09 : 0.065),
                            Color(red: 0.10, green: 0.12, blue: 0.22).opacity(isHovered ? 0.72 : 0.58)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 15)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.cyan.opacity(isHovered ? 0.32 : 0.13),
                            Color.white.opacity(isHovered ? 0.14 : 0.055)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
        .shadow(color: .black.opacity(isHovered ? 0.24 : 0.12), radius: isHovered ? 16 : 9, y: 5)
        .scaleEffect(isHovered ? 1.006 : 1)
        .animation(.easeOut(duration: 0.18), value: isHovered)
        .animation(.easeInOut(duration: 0.22), value: isGameSessionActive)
        .onHover { isHovered = $0 }
        .confirmationDialog("Remove \(instance.name)?", isPresented: $confirmRemoval, titleVisibility: .visible) {
            Button("Remove Instance", role: .destructive, action: remove)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the saved mod instance. The original game files are unaffected.")
        }
    }

    @ViewBuilder
    private var icon: some View {
        if let iconURL, let image = NSImage(contentsOf: iconURL) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(.indigo.opacity(0.2))
                Image(systemName: "sparkles")
                    .font(.system(size: 25))
                    .foregroundStyle(.cyan)
            }
        }
    }
}
