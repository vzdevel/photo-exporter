//
//  RemoteFolderSelectionSheet.swift
//  Photo Exporter
//
//  Created by Antigravity on 2026-11-15.
//

import SwiftUI

enum RemoteFolderPickerMode {
    case googleDrive(
        accountID: String,
        initialFolderId: String,
        initialFolderName: String,
        initialFolderPath: String,
        initialBreadcrumbs: [GoogleDriveFolderBreadcrumb]
    )
    case samba(
        host: String,
        port: Int,
        isGuest: Bool,
        username: String,
        password: String,
        initialShare: String,
        initialPath: String
    )
}

enum RemoteFolderPickerSelection {
    case googleDrive(
        folderId: String,
        folderName: String,
        folderPath: String,
        breadcrumbs: [GoogleDriveFolderBreadcrumb]
    )
    case samba(
        share: String,
        path: String
    )
}

/// Shared folder browser sheet for choosing an export folder on Google Drive or Samba.
/// For Samba, top-level shares are displayed as folders in the root path.
struct RemoteFolderSelectionSheet: View {
    @Environment(\.dismiss) private var dismiss

    let mode: RemoteFolderPickerMode
    let onSelect: (RemoteFolderPickerSelection) -> Void

    private struct FolderNode: Identifiable, Equatable {
        let id: String
        let name: String
    }

    private static let sambaRootNodeID = "__samba_root__"

    // Browsing & selection state
    @State private var folderStack: [FolderNode] = []
    @State private var selectedStack: [FolderNode] = []
    @State private var childFolders: [FolderNode] = []
    @State private var currentFolderMediaCounts: (images: Int, videos: Int)? = nil
    @State private var loadedCountsStack: [FolderNode] = []
    @State private var selectedFolderMediaCounts: (images: Int, videos: Int)? = nil
    @State private var isLoadingFolders: Bool = false
    @State private var folderErrorMessage: String? = nil
    @State private var loadTask: Task<Void, Never>? = nil

    // New folder creation state
    @State private var isShowingNewFolderAlert: Bool = false
    @State private var newFolderName: String = ""
    @State private var isCreatingFolder: Bool = false

    // Manual Samba share fallback alert (for servers that disable SRVSVC share enumeration)
    @State private var isShowingManualShareAlert: Bool = false
    @State private var manualShareName: String = ""

    private var isSambaMode: Bool {
        if case .samba = mode { return true }
        return false
    }

    private var isAtSambaServerRoot: Bool {
        isSambaMode && folderStack.count <= 1
    }

    private var currentNode: FolderNode {
        folderStack.last ?? FolderNode(id: "root", name: rootDisplayName)
    }

    private var rootDisplayName: String {
        switch mode {
        case .googleDrive:
            return "My Drive"
        case .samba(let host, _, _, _, _, _, _):
            let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Server" : trimmed
        }
    }

    private var hasValidSelection: Bool {
        switch mode {
        case .googleDrive:
            return !selectedStack.isEmpty
        case .samba:
            // Must select a share or a subfolder inside a share (depth >= 2)
            return selectedStack.count >= 2
        }
    }

    private var isCurrentFolderSelected: Bool {
        guard canSelectCurrentDirectory, let currentLast = folderStack.last, let selectedLast = selectedStack.last else {
            return false
        }
        return folderStack == selectedStack && currentLast.id == selectedLast.id
    }

    private var canSelectCurrentDirectory: Bool {
        !isAtSambaServerRoot && !folderStack.isEmpty
    }

    private var canCreateFolderHere: Bool {
        !isAtSambaServerRoot && !isCreatingFolder
    }

    private var navigationTitleText: String {
        switch mode {
        case .googleDrive:
            return "Google Drive Folder"
        case .samba:
            return "Samba Folder"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if hasValidSelection {
                    Section("Selected Folder") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Target Path")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "folder.fill.badge.checkmark")
                                    .font(.system(size: 18))
                                    .foregroundColor(.green)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(formattedURI(for: selectedStack))
                                        .font(.system(.subheadline, design: .monospaced, weight: .semibold))
                                        .foregroundColor(.primary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)

                                    if let counts = selectedFolderMediaCounts {
                                        HStack(spacing: 14) {
                                            HStack(spacing: 4) {
                                                Image(systemName: "photo")
                                                Text("\(counts.images) \(counts.images == 1 ? "image" : "images")")
                                            }
                                            HStack(spacing: 4) {
                                                Image(systemName: "video")
                                                Text("\(counts.videos) \(counts.videos == 1 ? "video" : "videos")")
                                            }
                                        }
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .padding(.top, 2)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                Section {
                    // Breadcrumb navigation & New Folder action header
                    HStack {
                        if folderStack.count > 1 {
                            Button {
                                navigateUp()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "chevron.left")
                                        .font(.subheadline.bold())
                                    let parentName = folderStack[folderStack.count - 2].name
                                    Text(parentName)
                                        .font(.subheadline.weight(.semibold))
                                        .lineLimit(1)
                                }
                                .foregroundColor(.blue)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.blue.opacity(0.12))
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.borderless)
                        } else {
                            Text(isSambaMode ? "Shares on \(rootDisplayName)" : rootDisplayName)
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        if canCreateFolderHere {
                            Button {
                                newFolderName = ""
                                isShowingNewFolderAlert = true
                            } label: {
                                HStack(spacing: 4) {
                                    if isCreatingFolder {
                                        ProgressView()
                                            .scaleEffect(0.75)
                                    } else {
                                        Image(systemName: "folder.badge.plus")
                                    }
                                    Text("New Folder")
                                }
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.blue)
                            }
                            .buttonStyle(.borderless)
                            .disabled(isCreatingFolder)
                        }
                    }
                    .padding(.vertical, 2)

                    if canSelectCurrentDirectory {
                        Button {
                            selectCurrentFolder()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: isCurrentFolderSelected ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 20))
                                    .foregroundColor(isCurrentFolderSelected ? .green : .secondary)

                                Text("Select: \"\(currentNode.name)\"")
                                    .font(.subheadline.weight(isCurrentFolderSelected ? .semibold : .regular))
                                    .foregroundColor(.primary)

                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    } else if isAtSambaServerRoot {
                        HStack(spacing: 10) {
                            Image(systemName: "externaldrive.connected.to.line.below")
                                .font(.system(size: 16))
                                .foregroundColor(.secondary)
                            Text("Choose a shared folder below to open and configure as your destination.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 2)
                    }

                    // Child folders / Samba shares list
                    if isLoadingFolders {
                        HStack {
                            Spacer()
                            ProgressView()
                                .scaleEffect(0.85)
                                .padding(.trailing, 6)
                            Text(isAtSambaServerRoot ? "Loading shares..." : "Loading folders...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                        .padding(.vertical, 8)
                    } else if let error = folderErrorMessage {
                        VStack(spacing: 8) {
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.red)
                                .multilineTextAlignment(.center)

                            HStack(spacing: 16) {
                                Button("Try Again") {
                                    loadChildren()
                                }
                                .font(.caption.weight(.bold))

                                if isAtSambaServerRoot {
                                    Button("Enter Share Manually") {
                                        manualShareName = ""
                                        isShowingManualShareAlert = true
                                    }
                                    .font(.caption.weight(.semibold))
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    } else if childFolders.isEmpty {
                        VStack(spacing: 8) {
                            Text(isAtSambaServerRoot
                                 ? "No shared folders found on \"\(rootDisplayName)\""
                                 : "No subfolders in \"\(currentNode.name)\"")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)

                            if isAtSambaServerRoot {
                                Button("Enter Share Manually") {
                                    manualShareName = ""
                                    isShowingManualShareAlert = true
                                }
                                .font(.caption.weight(.semibold))
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    } else {
                        ForEach(childFolders) { folder in
                            HStack(spacing: 12) {
                                Image(systemName: isAtSambaServerRoot ? "externaldrive.fill" : "folder.fill")
                                    .foregroundColor(.blue)
                                    .font(.system(size: 18))

                                Text(folder.name)
                                    .font(.body)
                                    .foregroundColor(.primary)
                                    .lineLimit(1)

                                Spacer()

                                Button {
                                    openFolder(folder)
                                } label: {
                                    HStack(spacing: 3) {
                                        Text("Open")
                                            .font(.caption.weight(.semibold))
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 10, weight: .bold))
                                    }
                                    .foregroundColor(.blue)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.blue.opacity(0.1))
                                    .clipShape(Capsule())
                                }
                                .buttonStyle(.borderless)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                openFolder(folder)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                } header: {
                    Text(isAtSambaServerRoot ? "Select Share" : "Select Folder")
                } footer: {
                    if isAtSambaServerRoot {
                        Text("Tap a share to browse its subfolders or select it.")
                    }
                }
            }
            .navigationTitle(navigationTitleText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        loadTask?.cancel()
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        confirmSelection()
                    }
                    .bold()
                    .disabled(!hasValidSelection || isCreatingFolder)
                }
            }
            .alert("New Folder", isPresented: $isShowingNewFolderAlert) {
                TextField("Folder Name", text: $newFolderName)
                    .autocorrectionDisabled()
                Button("Cancel", role: .cancel) { }
                Button("Create") {
                    createFolder()
                }
            } message: {
                Text("Enter a name for the new folder in \"\(currentNode.name)\"")
            }
            .alert("Enter Share Name", isPresented: $isShowingManualShareAlert) {
                TextField("Share Name", text: $manualShareName)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Cancel", role: .cancel) { }
                Button("Open") {
                    openManualShare()
                }
            } message: {
                Text("Enter the Samba share name on \(rootDisplayName).")
            }
            .onAppear {
                initializeState()
            }
            .onDisappear {
                loadTask?.cancel()
            }
            .task {
                await resolveGoogleDriveHierarchyIfNeeded()
            }
        }
    }

    // MARK: - Initialization & Navigation

    private func initializeState() {
        switch mode {
        case .googleDrive(_, let initialFolderId, let initialFolderName, _, let initialBreadcrumbs):
            let initialStack: [FolderNode]
            if initialFolderId != "root" {
                if !initialBreadcrumbs.isEmpty {
                    initialStack = initialBreadcrumbs.map { FolderNode(id: $0.id, name: $0.name) }
                } else {
                    initialStack = [
                        FolderNode(id: "root", name: "My Drive"),
                        FolderNode(id: initialFolderId, name: initialFolderName)
                    ]
                }
            } else {
                initialStack = [FolderNode(id: "root", name: "My Drive")]
            }
            folderStack = initialStack
            selectedStack = initialStack

        case .samba(_, _, _, _, _, let initialShare, let initialPath):
            var stack: [FolderNode] = [FolderNode(id: Self.sambaRootNodeID, name: rootDisplayName)]
            let cleanShare = initialShare.trimmingCharacters(in: CharacterSet(charactersIn: " /\\"))
            if !cleanShare.isEmpty {
                stack.append(FolderNode(id: cleanShare, name: cleanShare))
                let parts = initialPath
                    .replacingOccurrences(of: "\\", with: "/")
                    .split(separator: "/")
                    .map(String.init)
                    .filter { !$0.isEmpty }
                var runningPath = ""
                for part in parts {
                    runningPath = runningPath.isEmpty ? part : "\(runningPath)/\(part)"
                    stack.append(FolderNode(id: "\(cleanShare)/\(runningPath)", name: part))
                }
                selectedStack = stack
            } else {
                selectedStack = []
            }
            folderStack = stack
        }

        loadChildren()
    }

    private func resolveGoogleDriveHierarchyIfNeeded() async {
        guard case let .googleDrive(accountID, initialFolderId, _, _, initialBreadcrumbs) = mode,
              initialFolderId != "root",
              initialBreadcrumbs.isEmpty else {
            return
        }
        if let resolved = await GoogleDriveService.shared.resolveFolderHierarchy(for: initialFolderId, accountID: accountID) {
            let resolvedNodes = resolved.map { FolderNode(id: $0.id, name: $0.name) }
            await MainActor.run {
                if self.currentNode.id == initialFolderId {
                    self.folderStack = resolvedNodes
                }
                if self.selectedStack.last?.id == initialFolderId {
                    self.selectedStack = resolvedNodes
                }
            }
        }
    }

    private func navigateUp() {
        guard folderStack.count > 1 else { return }
        withAnimation {
            _ = folderStack.popLast()
        }
        if canSelectCurrentDirectory {
            selectCurrentFolder()
        }
        loadChildren()
    }

    private func openFolder(_ folder: FolderNode) {
        withAnimation {
            folderStack.append(folder)
        }
        selectCurrentFolder()
        loadChildren()
    }

    private func openManualShare() {
        let trimmed = manualShareName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/\\"))
        guard !trimmed.isEmpty, isAtSambaServerRoot else { return }
        openFolder(FolderNode(id: trimmed, name: trimmed))
    }

    private func selectCurrentFolder() {
        guard canSelectCurrentDirectory else { return }
        selectedStack = folderStack
        selectedFolderMediaCounts = (loadedCountsStack == folderStack) ? currentFolderMediaCounts : nil
    }

    // MARK: - Formatting & Confirmation

    private func formattedURI(for stack: [FolderNode]) -> String {
        switch mode {
        case .googleDrive:
            let joined = stack.map(\.name).joined(separator: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            return joined.isEmpty ? "My Drive" : joined
        case .samba:
            let components = stack.dropFirst().map(\.name)
            let suffix = components.joined(separator: "/")
            return suffix.isEmpty ? rootDisplayName : "\(rootDisplayName)/\(suffix)"
        }
    }

    private func confirmSelection() {
        switch mode {
        case .googleDrive:
            let effectiveStack = selectedStack.isEmpty ? [FolderNode(id: "root", name: "My Drive")] : selectedStack
            let target = effectiveStack.last ?? FolderNode(id: "root", name: "My Drive")
            let path = effectiveStack.map(\.name).joined(separator: "/")
            let breadcrumbs = effectiveStack.map { GoogleDriveFolderBreadcrumb(id: $0.id, name: $0.name) }
            onSelect(.googleDrive(
                folderId: target.id,
                folderName: target.name,
                folderPath: path.isEmpty ? "My Drive" : path,
                breadcrumbs: breadcrumbs
            ))
        case .samba:
            guard selectedStack.count >= 2 else { return }
            let chosenShare = selectedStack[1].name
            let chosenPath = selectedStack.dropFirst(2).map(\.name).joined(separator: "/")
            onSelect(.samba(share: chosenShare, path: chosenPath))
        }
        dismiss()
    }

    // MARK: - Remote Operations

    private func makeSambaDestination(share: String) -> SambaDestination? {
        guard case let .samba(host, port, isGuest, username, password, _, _) = mode else {
            return nil
        }
        return SambaDestination(
            name: host,
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: port,
            share: share,
            path: "",
            isGuest: isGuest,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            password: password
        )
    }

    private func loadChildren() {
        loadTask?.cancel()
        let expectedStack = folderStack

        loadTask = Task {
            await MainActor.run {
                self.isLoadingFolders = true
                self.folderErrorMessage = nil
                self.childFolders = []
                self.currentFolderMediaCounts = nil
                self.loadedCountsStack = []
            }

            do {
                let loaded: [FolderNode]
                let loadedCounts: (images: Int, videos: Int)?
                switch mode {
                case .googleDrive(let accountID, _, _, _, _):
                    let parentId = expectedStack.last?.id ?? "root"
                    let contents = try await GoogleDriveService.shared.listFolderContents(in: parentId, accountID: accountID)
                    loaded = contents.folders.map { FolderNode(id: $0.id, name: $0.name) }
                    loadedCounts = (contents.imageCount, contents.videoCount)

                case .samba:
                    if expectedStack.count <= 1 {
                        guard let rootDest = makeSambaDestination(share: "") else {
                            throw SMB2Client.makeError("Invalid Samba server configuration.")
                        }
                        let shares = try await SambaService.shared.listShares(for: rootDest)
                        loaded = shares.map { FolderNode(id: $0, name: $0) }
                        loadedCounts = nil
                    } else {
                        let share = expectedStack[1].name
                        let subpath = expectedStack.dropFirst(2).map(\.name).joined(separator: "/")
                        guard let shareDest = makeSambaDestination(share: share) else {
                            throw SMB2Client.makeError("Invalid Samba server configuration.")
                        }
                        let contents = try await SambaService.shared.listFolderContents(for: shareDest, at: subpath)
                        loaded = contents.subfolders.map { name in
                            let nodeID = subpath.isEmpty ? "\(share)/\(name)" : "\(share)/\(subpath)/\(name)"
                            return FolderNode(id: nodeID, name: name)
                        }
                        loadedCounts = (contents.imageCount, contents.videoCount)
                    }
                }

                try Task.checkCancellation()
                await MainActor.run {
                    guard self.folderStack == expectedStack else { return }
                    self.childFolders = loaded
                    self.currentFolderMediaCounts = loadedCounts
                    self.loadedCountsStack = expectedStack
                    if self.selectedStack == expectedStack {
                        self.selectedFolderMediaCounts = loadedCounts
                    }
                    self.isLoadingFolders = false
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    guard self.folderStack == expectedStack else { return }
                    self.folderErrorMessage = error.localizedDescription
                    self.isLoadingFolders = false
                }
            }
        }
    }

    private func createFolder() {
        let trimmed = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, canCreateFolderHere else { return }

        let parentStack = folderStack

        Task {
            await MainActor.run {
                isCreatingFolder = true
                folderErrorMessage = nil
            }

            do {
                let createdNode: FolderNode
                switch mode {
                case .googleDrive(let accountID, _, _, _, _):
                    let parentId = parentStack.last?.id ?? "root"
                    let newFolder = try await GoogleDriveService.shared.createFolder(
                        named: trimmed,
                        in: parentId,
                        accountID: accountID
                    )
                    createdNode = FolderNode(id: newFolder.id, name: newFolder.name)

                case .samba:
                    guard parentStack.count >= 2 else {
                        throw SMB2Client.makeError("Open a share before creating a new folder.")
                    }
                    let share = parentStack[1].name
                    let subpath = parentStack.dropFirst(2).map(\.name).joined(separator: "/")
                    guard let shareDest = makeSambaDestination(share: share) else {
                        throw SMB2Client.makeError("Invalid Samba server configuration.")
                    }
                    try await SambaService.shared.createSubdirectory(
                        named: trimmed,
                        in: subpath,
                        for: shareDest
                    )
                    let nodeID = subpath.isEmpty ? "\(share)/\(trimmed)" : "\(share)/\(subpath)/\(trimmed)"
                    createdNode = FolderNode(id: nodeID, name: trimmed)
                }

                await MainActor.run {
                    self.isCreatingFolder = false
                    if self.folderStack == parentStack {
                        self.folderStack.append(createdNode)
                        self.selectedStack = self.folderStack
                        self.selectedFolderMediaCounts = nil
                        self.loadChildren()
                    }
                }
            } catch {
                await MainActor.run {
                    self.folderErrorMessage = "Failed to create folder: \(error.localizedDescription)"
                    self.isCreatingFolder = false
                }
            }
        }
    }
}
