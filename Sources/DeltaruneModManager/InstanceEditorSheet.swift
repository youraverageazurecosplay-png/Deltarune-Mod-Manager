import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct InstanceEditorSheet: View {
    let instance: ModInstance
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var instanceName: String
    @State private var categoryName: String
    @State private var files: [ModInstanceFileEntry] = []
    @State private var searchText = ""
    @State private var isDropTargeted = false
    @State private var patchSelection: ManualPatchSelection?

    init(instance: ModInstance, model: AppModel) {
        self.instance = instance
        self.model = model
        _instanceName = State(initialValue: instance.name)
        _categoryName = State(initialValue: instance.category ?? "")
    }

    private var filteredFiles: [ModInstanceFileEntry] {
        guard !searchText.isEmpty else { return files }
        return files.filter {
            $0.path.localizedCaseInsensitiveContains(searchText)
                || $0.sourceLabel.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Edit Mod")
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                    Text("Changes are applied only while this instance is running.")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
                Button("Done") {
                    saveName()
                    saveCategory()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }

            HStack(spacing: 10) {
                TextField("Mod name", text: $instanceName)
                    .textFieldStyle(.roundedBorder)
                Button("Save Name", action: saveName)
                    .buttonStyle(.bordered)
            }

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Category")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Mods with the same category appear under one heading in My Mods.")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.52))
                }
                Spacer(minLength: 8)
                TextField("e.g. Knight Mods", text: $categoryName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 190)
                Button("Save Category", action: saveCategory)
                    .buttonStyle(.bordered)
            }

            HStack {
                Text("Instance files")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("\(files.count) files")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.48))
            }
            TextField("Filter paths", text: $searchText)
                .textFieldStyle(.roundedBorder)

            ScrollView {
                LazyVStack(spacing: 6) {
                    if filteredFiles.isEmpty {
                        Text(files.isEmpty ? "This instance has no files yet." : "No files match your search.")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.48))
                            .frame(maxWidth: .infinity, minHeight: 70)
                    } else {
                        ForEach(filteredFiles) { file in
                            HStack(spacing: 10) {
                                Image(systemName: "doc")
                                    .foregroundStyle(.cyan.opacity(0.8))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(file.path)
                                        .font(.system(size: 11, design: .monospaced))
                                        .textSelection(.enabled)
                                    Text(file.sourceLabel)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.white.opacity(0.45))
                                }
                                Spacer()
                            }
                            .padding(9)
                            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
            .frame(minHeight: 180)

            Button(action: chooseFiles) {
                VStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 25))
                        .foregroundStyle(.cyan)
                    Text("Add files to this mod")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Click to choose, or drop one ZIP, RAR, .xdelta, or .dylib here. Patches will ask which chapter to use.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.56))
                        .multilineTextAlignment(.center)
                    Text("Choose Files…")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.indigo, in: Capsule())
                }
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(isDropTargeted ? .cyan.opacity(0.15) : .white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isDropTargeted ? .cyan.opacity(0.7) : .white.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted, perform: acceptDrop)

            Text("A .dylib is copied to the selected chapter folder during launch. The game may need a compatible loader to use it.")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(22)
        .frame(width: 720, height: 680)
        .preferredColorScheme(.dark)
        .onAppear(perform: reloadFiles)
        .onChange(of: model.isBusy) { busy in
            if !busy { reloadFiles() }
        }
        .sheet(item: $patchSelection) { selection in
            ManualPatchAssignmentSheet(selection: selection, actionTitle: "Add to Mod") { assignments, name in
                model.addManualArchive(selection, assignments: assignments, named: name, to: instance)
            } cancel: {}
        }
    }

    private func reloadFiles() {
        let current = model.instances.first(where: { $0.id == instance.id }) ?? instance
        instanceName = current.name
        categoryName = current.category ?? ""
        files = model.files(for: current)
    }

    private func saveName() {
        model.renameInstance(instance, to: instanceName)
    }

    private func saveCategory() {
        model.categorizeInstance(instance, as: categoryName)
    }

    private func chooseFiles() {
        guard !model.isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "Add files to \(instance.name)"
        panel.message = "Choose one ZIP or RAR archive, xdelta patch, or dylib."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            .zip,
            UTType(filenameExtension: "rar") ?? .data,
            UTType(filenameExtension: "xdelta") ?? .data,
            UTType(filenameExtension: "dylib") ?? .data
        ]
        if panel.runModal() == .OK, let url = panel.url {
            inspect(url)
        }
    }

    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !model.isBusy, let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL?
            if let value = item as? URL {
                url = value
            } else if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else if let string = item as? String {
                url = URL(string: string)
            } else {
                url = nil
            }
            Task { @MainActor in
                guard let url else {
                    model.errorMessage = "The dropped item could not be read as a file."
                    return
                }
                inspect(url)
            }
        }
        return true
    }

    private func inspect(_ url: URL) {
        guard ["zip", "rar", "xdelta", "dylib"].contains(url.pathExtension.lowercased()) else {
            model.errorMessage = "Add a .zip, .rar, .xdelta, or .dylib file."
            return
        }
        Task {
            do {
                patchSelection = try await model.inspectManualArchive(url)
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }
}
