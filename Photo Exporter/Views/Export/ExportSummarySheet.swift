//
//  ExportSummarySheet.swift
//  Photo Exporter
//
//  Created by Antigravity on 2026-11-07.
//

import SwiftUI
import Photos
import ImageIO

/// Target export destination for the summary sheet
enum ExportTargetDestination: Equatable {
    case local(URL)
    case googleDrive(account: GoogleAccount, folderId: String, folderName: String)
    case googlePhotos(account: GoogleAccount)
    case samba(SambaDestination)

    var displayName: String {
        switch self {
        case .local(let url):
            return url.lastPathComponent.isEmpty ? "Local Files" : url.lastPathComponent
        case .googleDrive(let account, _, let folderName):
            return "\(account.name) - \(folderName)"
        case .googlePhotos(let account):
            return account.name
        case .samba(let dest):
            return dest.displayName
        }
    }

    var pathSubtitle: String {
        switch self {
        case .local(let url):
            return url.path
        case .googleDrive(let account, _, _):
            return account.gdrivePathDisplayString
        case .googlePhotos(let account):
            return account.email ?? "Google Photos Account"
        case .samba(let dest):
            return dest.sharePathDisplayString
        }
    }

    var iconName: String {
        switch self {
        case .local:
            return "folder.fill"
        case .googleDrive:
            return "GoogleDriveIcon"
        case .googlePhotos:
            return "GooglePhotosIcon"
        case .samba:
            return "server.rack"
        }
    }

    var isAssetIcon: Bool {
        switch self {
        case .googleDrive, .googlePhotos:
            return true
        case .local, .samba:
            return false
        }
    }

    var iconColor: Color {
        switch self {
        case .local:
            return .blue
        case .googleDrive:
            return .green
        case .googlePhotos:
            return .red
        case .samba:
            return .indigo
        }
    }
}

/// Dedicated summary sheet shown for export destinations.
/// Handles duplicate file skipping, filename conflicts/renaming, and final export confirmation.
struct ExportSummarySheet: View {
    let target: ExportTargetDestination
    let rawItems: [PhotoItem]
    var mediaSource: MediaSource = .photoLibrary
    let onConfirmExport: ([PhotoItem]) -> Void
    let onCancel: () -> Void

    @State private var isLoading: Bool = true
    @State private var errorMessage: String? = nil
    @State private var bearerToken: String? = nil
    @State private var skippedItems: [SkippedFileSummaryItem] = []
    @State private var renameGroups: [FileRenameGroup] = []
    @State private var itemsToExport: [PhotoItem] = []
    @State private var displayedSkippedLimit: Int = 3
    @State private var isShowingAllRenames: Bool = false
    @State private var destinationThumbnails: [String: UIImage] = [:]
    @State private var thumbnailGenerationTask: Task<Void, Never>? = nil

    // Duplicate override tracking per photo item id
    @State private var itemsBySubfolder: [String: [PhotoItem]] = [:]
    @State private var destinationFilesBySubfolder: [String: [DestinationFileInfo]] = [:]
    @State private var subfolderOrder: [String] = []
    @State private var userForcedNotDuplicateIDs: Set<String> = []
    @State private var userForcedDuplicateIDs: Set<String> = []

    private var totalRenamedCount: Int {
        renameGroups.reduce(0) { $0 + $1.renamedCount }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if isLoading {
                    loadingView
                } else if let error = errorMessage {
                    errorView(error)
                } else {
                    contentView
                }
            }
            .navigationTitle("Export Summary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        cancelThumbnailGeneration()
                        onCancel()
                    }
                }
            }
        }
        .presentationDetents([.fraction(0.85), .large])
        .presentationDragIndicator(.visible)
        .onAppear {
            Task {
                await analyzeDestination()
            }
        }
        .onDisappear {
            cancelThumbnailGeneration()
        }
        .onChange(of: displayedSkippedLimit) { _, _ in
            startGeneratingThumbnails()
        }
        .onChange(of: isShowingAllRenames) { _, _ in
            startGeneratingThumbnails()
        }
    }

    // MARK: - Loading View

    private var loadingView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .scaleEffect(1.2)
            Text("Checking destination folder...")
                .font(.subheadline.weight(.medium))
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Error View

    private func errorView(_ error: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundColor(.orange)

            Text("Destination Check Failed")
                .font(.headline)

            Text(error)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Button {
                Task {
                    await analyzeDestination()
                }
            } label: {
                Text("Retry")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(Color.blue)
                    .clipShape(Capsule())
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Main Content View

    private var contentView: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    destinationHeaderCard

                    // 1. SKIPPED FILES SUMMARY (Shown first in the sheet)
                    if !skippedItems.isEmpty {
                        skippedFilesSection
                    }

                    // 2. FILE RENAME SUMMARY
                    if !renameGroups.isEmpty {
                        renameSummarySection
                    }

                    // 3. READY TO EXPORT (if no duplicates and no renames)
                    if skippedItems.isEmpty && renameGroups.isEmpty {
                        allClearCard
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }

            // Bottom Action Bar
            bottomActionBar
        }
    }

    // MARK: - Destination Header Card

    private var destinationHeaderCard: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(target.iconColor.opacity(0.12))
                    .frame(width: 44, height: 44)
                AppSourceIconView(
                    iconName: target.iconName,
                    isAssetImage: target.isAssetIcon,
                    size: target.isAssetIcon ? 26 : 20,
                    weight: .semibold,
                    color: target.iconColor
                )
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(target.displayName)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Text(target.pathSubtitle)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Summary Stats Header

    private var summaryStatsHeader: some View {
        HStack(spacing: 8) {
            statPill(title: "Selected", count: rawItems.count, color: .secondary)
            statPill(title: "To Export", count: itemsToExport.count, color: .blue)
            if !skippedItems.isEmpty {
                statPill(title: "Skipped", count: skippedItems.count, color: .secondary)
            }
            if totalRenamedCount > 0 {
                statPill(title: "Renamed", count: totalRenamedCount, color: .orange)
            }
        }
    }

    private func statPill(title: String, count: Int, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundColor(.secondary)
            Text("\(count)")
                .font(.caption2.weight(.bold))
                .foregroundColor(color == .secondary ? .primary : color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(.tertiarySystemFill))
        .clipShape(Capsule())
    }

    // MARK: - 1. Skipped Files Section

    private var skippedFilesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)

                    Text("SKIPPED FILES")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Text("\(skippedItems.count) skipped")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color(.tertiarySystemFill))
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 4)

            Text("Identical files with the same name, modification date, and size already exist in destination and will be skipped.")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 4)

            LazyVStack(spacing: 12) {
                let displayed = Array(skippedItems.prefix(displayedSkippedLimit))
                ForEach(displayed) { item in
                    SkippedFileCardView(
                        item: item,
                        bearerToken: bearerToken,
                        mediaSource: mediaSource,
                        destinationThumbnail: destinationThumbnails[thumbnailKey(for: item.matchedDestinationFile)],
                        onMarkNotDuplicate: { skippedItem in
                            markAsNotDuplicate(item: skippedItem)
                        }
                    )
                }
            }

            if skippedItems.count > 3 {
                let remainingToDisplay = skippedItems.count - displayedSkippedLimit
                if remainingToDisplay > 0 {
                    HStack(spacing: 8) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                if remainingToDisplay >= 101 {
                                    displayedSkippedLimit += 100
                                } else {
                                    displayedSkippedLimit = skippedItems.count
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(remainingToDisplay >= 101 ? "Show 100 More Skipped Files" : "Show All \(skippedItems.count) Skipped Files")
                                    .font(.caption.weight(.semibold))
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .foregroundColor(.blue)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color.blue.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)

                        if displayedSkippedLimit > 3 {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    displayedSkippedLimit = 3
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text("Show Less")
                                        .font(.caption.weight(.semibold))
                                    Image(systemName: "chevron.up")
                                        .font(.system(size: 10, weight: .semibold))
                                }
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color(.tertiarySystemFill))
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } else {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            displayedSkippedLimit = 3
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("Show Less")
                                .font(.caption.weight(.semibold))
                            Image(systemName: "chevron.up")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundColor(.blue)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.blue.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - 2. Rename Summary Section

    private var renameSummarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 12))
                        .foregroundColor(.orange)

                    Text("FILES TO RENAME")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Text("\(totalRenamedCount) renamed")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.orange.opacity(0.12))
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 4)

            Text("Files renamed with '-N' suffix to prevent overwriting existing destination files or duplicate names in this batch.")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 4)

            VStack(spacing: 12) {
                let displayedGroups = isShowingAllRenames ? renameGroups : Array(renameGroups.prefix(3))
                ForEach(displayedGroups) { group in
                    RenameGroupCard(
                        group: group,
                        bearerToken: bearerToken,
                        destinationThumbnails: destinationThumbnails,
                        onMarkDuplicate: { renameItem in
                            markAsDuplicate(item: renameItem)
                        }
                    )
                }

                if renameGroups.count > 3 {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isShowingAllRenames.toggle()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(isShowingAllRenames ? "Show Less" : "Show All \(renameGroups.count) Groups")
                                .font(.caption.weight(.semibold))
                            Image(systemName: isShowingAllRenames ? "chevron.up" : "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundColor(.orange)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.orange.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - 3. All Clear Card

    private var allClearCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.and.arrow.up.circle.fill")
                .font(.system(size: 38))
                .foregroundColor(.blue)

            Text("All \(itemsToExport.count) Files Ready for Export")
                .font(.headline)

            Text(allClearSubtitle)
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var allClearSubtitle: String {
        if case .googlePhotos = target {
            return "All photos will be uploaded without duplicate checks."
        }
        return "No duplicate files or naming conflicts found in destination."
    }

    // MARK: - Bottom Action Bar

    private var bottomActionBar: some View {
        VStack(spacing: 8) {
            Divider()

            HStack(spacing: 12) {
                Button {
                    cancelThumbnailGeneration()
                    onCancel()
                } label: {
                    Text("Cancel")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color(.tertiarySystemFill))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                if !itemsToExport.isEmpty {
                    Button {
                        cancelThumbnailGeneration()
                        onConfirmExport(itemsToExport)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 14, weight: .bold))
                            Text("Export (\(itemsToExport.count))")
                                .font(.subheadline.weight(.bold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.blue)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                } else {
                    Button {
                        cancelThumbnailGeneration()
                        onCancel()
                    } label: {
                        Text("All Files Skipped (Done)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.gray)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
        .background(Color(.systemBackground))
    }

    private func thumbnailKey(for file: DestinationFileInfo) -> String {
        file.subfolderPath.isEmpty ? file.filename.lowercased() : "\(file.subfolderPath)/\(file.filename)".lowercased()
    }

    // MARK: - Analysis Task

    private func analyzeDestination() async {
        isLoading = true
        errorMessage = nil

        do {
            if case .googlePhotos = target {
                let sortedItems = rawItems.sortedChronologicallyAscending().map { $0.withSubfolderPath("") }
                await MainActor.run {
                    self.itemsBySubfolder = ["": sortedItems]
                    self.destinationFilesBySubfolder = ["": []]
                    self.subfolderOrder = [""]
                    self.itemsToExport = sortedItems
                    self.skippedItems = []
                    self.renameGroups = []
                    self.isLoading = false
                }
                return
            }

            let folderSettings = FolderOrganizationSettings.shared
            let isFolderOrgEnabled = folderSettings.isEnabled

            // Step 0: Sort raw items chronologically ascending and tag with their subfolder path if enabled
            let taggedItems: [PhotoItem] = rawItems.sortedChronologicallyAscending().map { item in
                if isFolderOrgEnabled {
                    let photoDate = item.creationDate ?? item.embeddedDate ?? item.asset?.creationDate
                    let subfolder = folderSettings.subfolderPath(for: photoDate, in: item.timeZone)
                    return item.withSubfolderPath(subfolder)
                } else {
                    return item.withSubfolderPath("")
                }
            }

            // Group items by subfolderPath, preserving chronological order
            var subfolderOrder: [String] = []
            var itemsBySubfolder: [String: [PhotoItem]] = [:]
            for item in taggedItems {
                let key = item.subfolderPath
                if itemsBySubfolder[key] == nil {
                    subfolderOrder.append(key)
                }
                itemsBySubfolder[key, default: []].append(item)
            }

            // Sort subfolders chronologically ascending based on the earliest photo date in each subfolder
            subfolderOrder.sort { f1, f2 in
                let d1 = itemsBySubfolder[f1]?.compactMap { $0.creationDate ?? $0.embeddedDate ?? $0.asset?.creationDate }.min() ?? .distantPast
                let d2 = itemsBySubfolder[f2]?.compactMap { $0.creationDate ?? $0.embeddedDate ?? $0.asset?.creationDate }.min() ?? .distantPast
                if d1 != d2 {
                    return d1 < d2
                }
                return f1.localizedStandardCompare(f2) == .orderedAscending
            }

            var fetchedDestFiles: [String: [DestinationFileInfo]] = [:]

            var token: String? = nil
            if case .googleDrive(let account, _, _) = target {
                token = try? await GoogleDriveService.shared.getValidAccessToken(for: account.id)
                self.bearerToken = token
            }

            for subfolder in subfolderOrder {
                guard let subfolderItems = itemsBySubfolder[subfolder], !subfolderItems.isEmpty else { continue }

                let destinationFiles: [DestinationFileInfo]
                switch target {
                case .local(let url):
                    destinationFiles = ExportService.shared.fetchDestinationFiles(in: url, subfolderPath: subfolder)

                case .googleDrive(let account, let rootFolderId, _):
                    if subfolder.isEmpty {
                        destinationFiles = try await GoogleDriveService.shared.fetchDestinationFiles(
                            in: rootFolderId,
                            subfolderPath: "",
                            accountID: account.id,
                            accessToken: token
                        )
                    } else if let subId = try await GoogleDriveService.shared.findOrCreateSubfolderHierarchy(
                        path: subfolder,
                        under: rootFolderId,
                        accountID: account.id,
                        accessToken: token,
                        createIfMissing: false
                    ) {
                        destinationFiles = try await GoogleDriveService.shared.fetchDestinationFiles(
                            in: subId,
                            subfolderPath: subfolder,
                            accountID: account.id,
                            accessToken: token
                        )
                    } else {
                        destinationFiles = []
                    }

                case .googlePhotos:
                    destinationFiles = []

                case .samba(let destination):
                    destinationFiles = try await SambaService.shared.fetchDestinationFiles(
                        destination: destination,
                        subfolderPath: subfolder
                    )
                }

                // Ignore 0-byte destination files so they are treated as non-existent and simply overridden
                fetchedDestFiles[subfolder] = destinationFiles.filter { $0.fileSize > 0 }
            }

            await MainActor.run {
                self.itemsBySubfolder = itemsBySubfolder
                self.destinationFilesBySubfolder = fetchedDestFiles
                self.subfolderOrder = subfolderOrder
                self.recalculatePlan()
                self.isLoading = false
            }
        } catch is CancellationError {
            // Sheet was cancelled/dismissed, do not show error
            return
        } catch {
            if (error as? URLError)?.code == .cancelled {
                return
            }
            await MainActor.run {
                self.errorMessage = error.localizedDescription
                self.isLoading = false
            }
        }
    }

    // MARK: - Duplicate Overrides & Plan Recalculation

    private func markAsNotDuplicate(item: SkippedFileSummaryItem) {
        withAnimation(.easeInOut(duration: 0.2)) {
            userForcedNotDuplicateIDs.insert(item.id)
            userForcedDuplicateIDs.remove(item.id)
            recalculatePlan()
        }
    }

    private func markAsDuplicate(item: FileRenameItem) {
        withAnimation(.easeInOut(duration: 0.2)) {
            userForcedDuplicateIDs.insert(item.id)
            userForcedNotDuplicateIDs.remove(item.id)
            recalculatePlan()
        }
    }

    private func recalculatePlan() {
        var allSkipped: [SkippedFileSummaryItem] = []
        var allRenameGroups: [FileRenameGroup] = []
        var allResolvedToExport: [PhotoItem] = []

        for subfolder in subfolderOrder {
            guard let subfolderItems = itemsBySubfolder[subfolder], !subfolderItems.isEmpty else { continue }
            let destinationFiles = destinationFilesBySubfolder[subfolder] ?? []

            // Step 1: Base duplicate evaluation
            let (baseSkipped, baseRemaining) = ExportDeduplicationEngine.evaluateDuplicates(
                deviceItems: subfolderItems,
                destinationFiles: destinationFiles
            )

            // Step 1a: Apply user overrides
            // For items in baseSkipped: if user explicitly forced NOT duplicate, move to remaining
            var adjustedSkipped: [SkippedFileSummaryItem] = []
            var remainingPool = baseRemaining
            for skipItem in baseSkipped {
                if userForcedNotDuplicateIDs.contains(skipItem.id) {
                    remainingPool.append(skipItem.deviceItem)
                } else {
                    adjustedSkipped.append(skipItem)
                }
            }

            // For items in remainingPool: if user explicitly forced duplicate, move to skipped
            var finalRemaining: [PhotoItem] = []
            for item in remainingPool {
                if userForcedDuplicateIDs.contains(item.id) {
                    let itemStripped = ExportDeduplicationEngine.strippingDedupSuffix(from: item.filename).lowercased()
                    let matchedDest = destinationFiles.first(where: {
                        ExportDeduplicationEngine.strippingDedupSuffix(from: $0.filename).lowercased() == itemStripped
                    }) ?? DestinationFileInfo(
                        id: UUID().uuidString,
                        filename: item.filename,
                        modificationDate: item.creationDate,
                        fileSize: ExportDeduplicationEngine.getDeviceFileSize(for: item),
                        subfolderPath: subfolder
                    )
                    let itemSize = ExportDeduplicationEngine.getDeviceFileSize(for: item)
                    let finalSize = itemSize > 0 ? itemSize : matchedDest.fileSize
                    adjustedSkipped.append(SkippedFileSummaryItem(
                        deviceItem: item,
                        matchedDestinationFile: matchedDest,
                        deviceFileSize: finalSize,
                        deviceModificationDate: item.creationDate ?? item.modificationDate ?? item.asset?.creationDate
                    ))
                } else {
                    finalRemaining.append(item)
                }
            }

            // Step 2: For remaining items, resolve filename conflicts taking into account destination files
            let existingFilenames = Set(destinationFiles.map { $0.filename.lowercased() })
            var (resolved, groups) = finalRemaining.resolveFilenameConflicts(
                takingIntoAccountExisting: existingFilenames,
                destinationFiles: destinationFiles
            )

            // Ensure subfolderPath is set on rename groups & items
            for gIdx in 0..<groups.count {
                groups[gIdx].subfolderPath = subfolder
                for iIdx in 0..<groups[gIdx].items.count {
                    groups[gIdx].items[iIdx].subfolderPath = subfolder
                }
                for dIdx in 0..<groups[gIdx].existingDestinationFiles.count {
                    if groups[gIdx].existingDestinationFiles[dIdx].subfolderPath.isEmpty {
                        groups[gIdx].existingDestinationFiles[dIdx].subfolderPath = subfolder
                    }
                }
            }

            allSkipped.append(contentsOf: adjustedSkipped)
            allRenameGroups.append(contentsOf: groups)
            allResolvedToExport.append(contentsOf: resolved)
        }

        self.skippedItems = allSkipped
        self.renameGroups = allRenameGroups
        self.itemsToExport = allResolvedToExport.sortedChronologicallyAscending()
        self.startGeneratingThumbnails()
    }

    // MARK: - Thumbnail Generation for Local and SMB

    private func cancelThumbnailGeneration() {
        thumbnailGenerationTask?.cancel()
        thumbnailGenerationTask = nil
    }

    private func startGeneratingThumbnails() {
        cancelThumbnailGeneration()

        // Only local and SMB need on-demand thumbnail generation (Google Drive uses thumbnailLink)
        switch target {
        case .local, .samba:
            break
        case .googleDrive, .googlePhotos:
            return
        }

        var filesToLoad: [DestinationFileInfo] = []
        var seen = Set<String>()

        for item in skippedItems.prefix(displayedSkippedLimit) {
            let dest = item.matchedDestinationFile
            let key = thumbnailKey(for: dest)
            if destinationThumbnails[key] == nil && seen.insert(key).inserted {
                filesToLoad.append(dest)
            }
        }

        let visibleGroups = isShowingAllRenames ? renameGroups : Array(renameGroups.prefix(3))
        for group in visibleGroups {
            for dest in group.existingDestinationFiles {
                let key = thumbnailKey(for: dest)
                if destinationThumbnails[key] == nil && seen.insert(key).inserted {
                    filesToLoad.append(dest)
                }
            }
        }

        guard !filesToLoad.isEmpty else { return }

        thumbnailGenerationTask = Task {
            for dest in filesToLoad {
                if Task.isCancelled { break }

                if let img = await generateThumbnail(for: dest) {
                    if Task.isCancelled { break }
                    let key = thumbnailKey(for: dest)
                    await MainActor.run {
                        self.destinationThumbnails[key] = img
                    }
                }
            }
        }
    }

    private func generateThumbnail(for file: DestinationFileInfo) async -> UIImage? {
        switch target {
        case .local(let folderURL):
            let isSecurityScoped = folderURL.startAccessingSecurityScopedResource()
            defer {
                if isSecurityScoped {
                    folderURL.stopAccessingSecurityScopedResource()
                }
            }
            let targetFolderURL = file.subfolderPath.isEmpty ? folderURL : folderURL.appendingPathComponent(file.subfolderPath)
            let fileURL = targetFolderURL.appendingPathComponent(file.filename)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }

            if file.isVideo {
                return await FolderMediaService.videoThumbnailFromURL(fileURL, maxPixelSize: 120)
            }
            return await Task.detached(priority: .utility) {
                FolderMediaService.thumbnailFromURL(fileURL, maxPixelSize: 120)
            }.value

        case .samba(let sambaDest):
            if file.isVideo {
                return await SambaService.shared.generateVideoThumbnail(
                    filename: file.filename,
                    destination: sambaDest,
                    subfolderPath: file.subfolderPath,
                    maxPixelSize: 120
                )
            }
            return await SambaService.shared.generateImageThumbnail(
                filename: file.filename,
                destination: sambaDest,
                subfolderPath: file.subfolderPath,
                knownFileSize: file.fileSize,
                maxPixelSize: 120
            )

        case .googleDrive, .googlePhotos:
            return nil
        }
    }
}

// MARK: - Device Thumbnail View

struct DeviceThumbnailView: View {
    let asset: PHAsset?
    let isVideo: Bool
    var size: CGFloat = 38
    var item: PhotoItem? = nil
    var mediaSource: MediaSource = .photoLibrary
    @State private var thumbnail: UIImage? = nil
    @State private var currentRequestID: PHImageRequestID? = nil

    var body: some View {
        ZStack {
            if let thumb = thumbnail {
                let pendingSteps = (mediaSource.isFolder && item != nil)
                    ? ExifMetadataService.clockwiseSteps(forDegrees: item!.pendingRotationDegrees)
                    : 0
                let displayedThumb = pendingSteps != 0
                    ? ExifMetadataService.rotateUIImage(thumb, clockwiseSteps: pendingSteps)
                    : thumb
                Image(uiImage: displayedThumb)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(.tertiarySystemFill))
                    .frame(width: size, height: size)
                    .overlay(
                        Image(systemName: isVideo ? "video.fill" : "photo.fill")
                            .font(.system(size: max(10, size * 0.38)))
                            .foregroundColor(.secondary)
                    )
            }
        }
        .frame(width: size, height: size)
        .onAppear {
            loadThumbnail()
        }
        .onChange(of: asset?.localIdentifier ?? item?.id) { _, _ in
            loadThumbnail()
        }
        .onChange(of: asset?.modificationDate ?? item?.fileModificationDate) { _, _ in
            loadThumbnail()
        }
        .onChange(of: asset?.hasAdjustments) { _, _ in
            loadThumbnail()
        }
    }

    private func loadThumbnail() {
        if let id = currentRequestID {
            PhotoLibraryService.shared.imageManager.cancelImageRequest(id)
            currentRequestID = nil
        }
        if let asset {
            currentRequestID = PhotoLibraryService.shared.requestThumbnail(
                for: asset,
                targetSize: CGSize(width: size * 2, height: size * 2)
            ) { img in
                self.thumbnail = img
            }
        } else if let item, mediaSource.isFolder {
            if let cached = FolderMediaService.shared.cachedThumbnail(for: item, in: mediaSource) {
                self.thumbnail = cached
            } else {
                Task {
                    let img = await FolderMediaService.shared.loadThumbnail(for: item, in: mediaSource, maxPixelSize: size * 2)
                    await MainActor.run {
                        self.thumbnail = img
                    }
                }
            }
        }
    }
}

// MARK: - Skipped File Card View

struct SkippedFileCardView: View {
    let item: SkippedFileSummaryItem
    let bearerToken: String?
    var mediaSource: MediaSource = .photoLibrary
    var destinationThumbnail: UIImage? = nil
    var onMarkNotDuplicate: ((SkippedFileSummaryItem) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: Base Filename
            HStack(spacing: 8) {
                Image(systemName: "doc.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                Text(item.displayFilename)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                let subfolder = !item.matchedDestinationFile.subfolderPath.isEmpty ? item.matchedDestinationFile.subfolderPath : item.deviceItem.subfolderPath
                if !subfolder.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "folder")
                            .font(.system(size: 9))
                        Text(subfolder)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                    }
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color(.tertiarySystemFill))
                    .clipShape(Capsule())
                }

                Spacer(minLength: 6)

                Text("Duplicate")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(.tertiarySystemFill))
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.tertiarySystemGroupedBackground).opacity(0.6))

            Divider()

            // 1. Existing Destination File (Shown First)
            HStack(spacing: 12) {
                DestinationThumbnailView(
                    thumbnailLink: item.matchedDestinationFile.thumbnailLink,
                    bearerToken: bearerToken,
                    isVideo: item.matchedDestinationFile.isVideo,
                    localImage: destinationThumbnail
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.matchedDestinationFile.filename)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack(spacing: 8) {
                        if item.matchedDestinationFile.fileSize > 0 {
                            Text(ByteCountFormatter.string(fromByteCount: item.matchedDestinationFile.fileSize, countStyle: .file))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        } else if item.matchedDestinationFile.fileSize == 0 {
                            Text("0 B")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }

                        if let modDate = item.matchedDestinationFile.modificationDate {
                            Text(DateFormatters.dateTimeString(for: modDate, in: .current))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Spacer(minLength: 6)

                Text("Destination")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.indigo)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.indigo.opacity(0.12))
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.indigo.opacity(0.04))

            Divider()

            // 2. Device File (Skipped)
            HStack(spacing: 12) {
                DeviceThumbnailView(
                    asset: item.deviceItem.asset,
                    isVideo: item.deviceItem.isVideo,
                    item: item.deviceItem,
                    mediaSource: mediaSource
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.displayFilename)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack(spacing: 8) {
                        if item.deviceFileSize > 0 {
                            Text(ByteCountFormatter.string(fromByteCount: item.deviceFileSize, countStyle: .file))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }

                        if let modDate = item.deviceModificationDate {
                            Text(DateFormatters.dateTimeString(for: modDate, in: .current))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Spacer(minLength: 6)

                HStack(spacing: 6) {
                    Text("Skipped")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(.tertiarySystemFill))
                        .clipShape(Capsule())

                    if let onMark = onMarkNotDuplicate {
                        Button {
                            onMark(item)
                        } label: {
                            Text("Rename")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.orange)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color.orange.opacity(0.12))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Mark as not duplicate and rename")
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 0.8)
        )
    }
}

// MARK: - Destination Thumbnail View

final class ThumbnailImageCache {
    static let shared = NSCache<NSString, UIImage>()
}

struct DestinationThumbnailView: View {
    let thumbnailLink: String?
    let bearerToken: String?
    let isVideo: Bool
    var localImage: UIImage? = nil

    @State private var image: UIImage? = nil
    @State private var isLoading: Bool = false

    private var displayImage: UIImage? {
        localImage ?? image
    }

    var body: some View {
        ZStack {
            if let img = displayImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 38, height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(.tertiarySystemFill))
                    .frame(width: 38, height: 38)
                    .overlay(
                        Group {
                            if isLoading {
                                ProgressView()
                                    .scaleEffect(0.6)
                            } else {
                                Image(systemName: isVideo ? "video.fill" : "photo.fill")
                                    .font(.system(size: 14))
                                    .foregroundColor(.secondary)
                            }
                        }
                    )
            }
        }
        .frame(width: 38, height: 38)
        .task(id: thumbnailLink) {
            if localImage == nil {
                await loadThumbnail()
            }
        }
    }

    private func loadThumbnail() async {
        guard let link = thumbnailLink, let url = URL(string: link) else { return }

        let cacheKey = link as NSString
        if let cached = ThumbnailImageCache.shared.object(forKey: cacheKey) {
            self.image = cached
            return
        }

        isLoading = true
        var request = URLRequest(url: url)
        if let token = bearerToken, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
               let uiImg = UIImage(data: data) {
                ThumbnailImageCache.shared.setObject(uiImg, forKey: cacheKey)
                await MainActor.run {
                    self.image = uiImg
                    self.isLoading = false
                }
                return
            }
        } catch {
            // Fall back to placeholder
        }

        await MainActor.run {
            self.isLoading = false
        }
    }
}

// MARK: - Rename Summary Group Card

struct RenameGroupCard: View {
    let group: FileRenameGroup
    var bearerToken: String? = nil
    var destinationThumbnails: [String: UIImage] = [:]
    var destinationThumbnail: UIImage? = nil
    var onMarkDuplicate: ((FileRenameItem) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Group Header
            HStack(spacing: 8) {
                Image(systemName: "doc.on.doc.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                Text(group.originalName)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if !group.subfolderPath.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "folder")
                            .font(.system(size: 9))
                        Text(group.subfolderPath)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                    }
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color(.tertiarySystemFill))
                    .clipShape(Capsule())
                }

                Spacer(minLength: 6)

                Text("\(group.items.count) to export")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(.tertiarySystemFill))
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.tertiarySystemGroupedBackground).opacity(0.6))

            Divider()

            // Existing Destination Files (if present)
            ForEach(group.existingDestinationFiles) { existing in
                HStack(spacing: 12) {
                    DestinationThumbnailView(
                        thumbnailLink: existing.thumbnailLink,
                        bearerToken: bearerToken,
                        isVideo: existing.isVideo,
                        localImage: destinationThumbnails[existing.thumbnailKey] ?? destinationThumbnail
                    )

                    VStack(alignment: .leading, spacing: 3) {
                        Text(existing.filename)
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        HStack(spacing: 8) {
                            if existing.fileSize > 0 {
                                Text(ByteCountFormatter.string(fromByteCount: existing.fileSize, countStyle: .file))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            } else if existing.fileSize == 0 {
                                Text("0 B")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }

                            if let modDate = existing.modificationDate {
                                Text(DateFormatters.dateTimeString(for: modDate, in: .current))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    Spacer(minLength: 6)

                    Text("Destination")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.indigo)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.indigo.opacity(0.12))
                        .clipShape(Capsule())
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.indigo.opacity(0.04))

                Divider()
            }

            // Group Items
            VStack(spacing: 0) {
                ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        Divider()
                            .padding(.leading, 60)
                    }

                    RenameItemRow(item: item, onMarkDuplicate: onMarkDuplicate)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.orange.opacity(0.25), lineWidth: 0.8)
        )
    }
}

// MARK: - Rename Item Row

struct RenameItemRow: View {
    let item: FileRenameItem
    var onMarkDuplicate: ((FileRenameItem) -> Void)? = nil
    @State private var thumbnail: UIImage? = nil

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if let thumb = thumbnail {
                    Image(uiImage: thumb)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 38, height: 38)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(.tertiarySystemFill))
                        .frame(width: 38, height: 38)
                        .overlay(
                            Image(systemName: item.asset?.mediaType == .video ? "video" : "photo")
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)
                        )
                }
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 3) {
                if item.isRenamed {
                    HStack(spacing: 5) {
                        Text(item.originalName)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Image(systemName: "arrow.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.orange)

                        Text(item.newName)
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                } else {
                    Text(item.originalName)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                HStack(spacing: 8) {
                    if item.fileSize > 0 {
                        Text(ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    if let date = item.date {
                        Text(DateFormatters.dateTimeString(for: date, in: .current))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer(minLength: 6)

            if item.isRenamed {
                HStack(spacing: 6) {
                    Text("Renamed")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.12))
                        .clipShape(Capsule())

                    if let onMark = onMarkDuplicate {
                        Button {
                            onMark(item)
                        } label: {
                            Text("Skip")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color(.tertiarySystemFill))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Mark as duplicate to skip")
                    }
                }
            } else {
                Text("Original")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.blue)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.12))
                    .clipShape(Capsule())
            }
        }
        .onAppear {
            if let asset = item.asset {
                _ = PhotoLibraryService.shared.requestThumbnail(for: asset, targetSize: CGSize(width: 76, height: 76)) { img in
                    self.thumbnail = img
                }
            }
        }
    }
}

