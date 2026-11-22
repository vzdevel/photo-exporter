//
//  PhotoListViewModel+Export.swift
//  Photo Exporter
//

import Foundation
import Photos
import SwiftUI
import UIKit

extension PhotoListViewModel {
    // MARK: - Export Workflow


    var pendingExportRenames: [FileRenameItem] {
        pendingExportRenameGroups.flatMap(\.items).filter(\.isRenamed)
    }

    var effectiveExportItems: [PhotoItem] {
        if !preparedExportItems.isEmpty {
            return preparedExportItems.sortedChronologicallyAscending()
        }
        return selectedItems.sortedChronologicallyAscending().resolveInternalFilenameConflicts().items.sortedChronologicallyAscending()
    }

    var activeApplySummaryItems: [PhotoItem] {
        explicitExportSourceItems ?? selectedItems
    }

    var activeExportSummaryItems: [PhotoItem] {
        if let explicit = explicitExportSourceItems, !explicit.isEmpty {
            return explicit
        }
        return selectedItems.isEmpty ? effectiveExportItems : selectedItems
    }

    /// Step 1: Open the destination selection sheet (or Apply summary sheet in folder mode)
    func initiateExport(items explicitItems: [PhotoItem]? = nil) {
        guard !isExportDisabled else { return }
        self.explicitExportSourceItems = explicitItems
        let rawSelected = explicitItems ?? selectedItems
        guard !rawSelected.isEmpty else { return }
        guard !rawSelected.contains(where: { !$0.isAnalyzed }) else { return }

        if shouldShowApply(for: rawSelected) {
            isShowingApplySummarySheet = true
            return
        }

        // Sort chronologically ascending and resolve any internal duplicate filenames
        let (resolved, groups) = rawSelected.resolveInternalFilenameConflicts()
        self.preparedExportItems = resolved
        self.pendingExportRenameGroups = groups

        // Present destination picker sheet
        isShowingDestinationSheet = true
    }

    /// Apply inferred timezones / adjustments in place to files in the active folder
    func startApplyChangesInPlace(items: [PhotoItem], totalBatchCount: Int? = nil, initialSuccessfulItems: [PhotoItem] = []) {
        isShowingApplySummarySheet = false
        explicitExportSourceItems = nil
        guard currentMediaSource.isFolder, !items.isEmpty else { return }

        if totalBatchCount == nil {
            self.currentBatchItems = items
            self.totalBatchCount = items.count
        }

        let effectiveBatchTotal = totalBatchCount ?? self.totalBatchCount
        let baseSuccess = initialSuccessfulItems.count

        let source = currentMediaSource
        let sourceKey = source.sourceKey
        lastExportTarget = nil
        lastOperationWasApply = true

        activeExportTask?.cancel()
        activeExportTask = nil
        exportRunGeneration += 1
        let runGen = exportRunGeneration

        beginBackgroundExport(totalCount: effectiveBatchTotal)

        self.applyExportProgressUpdate(ExportProgress(
            isExporting: true,
            totalCount: effectiveBatchTotal,
            currentItemIndex: baseSuccess,
            currentFilename: baseSuccess > 0 ? "Resuming apply..." : (items.first?.filename ?? "Applying changes..."),
            currentItem: items.first,
            successCount: baseSuccess,
            failureCount: 0,
            errorMessages: [],
            failedItems: [],
            successfulItems: initialSuccessfulItems,
            isCancelled: false,
            isCompleted: false,
            isApplyInPlace: true
        ))
        isShowingExportProgress = true

        activeExportTask = Task {
            let finalProgress = await FolderMediaService.shared.applyChangesInPlace(
                items: items,
                in: source,
                totalBatchCount: effectiveBatchTotal,
                initialSuccessfulItems: initialSuccessfulItems,
                onBeforeFinalSwap: { [weak self] item in
                    await self?.onBeforeFinalSwapInPlace?(item)
                }
            ) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, self.exportRunGeneration == runGen else { return }
                    self.applyExportProgressUpdate(progress)
                }
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                let appliedPairs = self.applyInPlaceCompletedItems(from: finalProgress, in: source, sourceKey: sourceKey)
                guard !Task.isCancelled, self.exportRunGeneration == runGen else { return }
                self.finalizeExportProgress(finalProgress)
                for pair in appliedPairs {
                    self.onFolderItemAppliedInPlace?(pair.oldID, pair.updated)
                }
            }
        }
    }

    private func applyInPlaceCompletedItems(from finalProgress: ExportProgress, in source: MediaSource, sourceKey: String) -> [(oldID: String, updated: PhotoItem)] {
        let succeededIDs = Set(finalProgress.successfulItems.map { $0.id })
        guard !succeededIDs.isEmpty else { return [] }

        var appliedPairs: [(oldID: String, updated: PhotoItem)] = []
        let isGoogleDriveSource: Bool = {
            if case .googleDrive = source { return true }
            return false
        }()
        for idx in self.allPhotos.indices where succeededIDs.contains(self.allPhotos[idx].id) {
            let old = self.allPhotos[idx]
            let appliedDate = old.creationDate ?? old.embeddedDate ?? old.fileModificationDate
            let updatedSize = finalProgress.updatedFileSizes[old.id] ?? old.fileSize
            let cleared = PhotoItem(
                id: old.id,
                filename: old.filename,
                creationDate: appliedDate,
                embeddedDate: appliedDate,
                timeZone: old.timeZone,
                isDateAdjusted: false,
                isGPSAdjusted: false,
                pendingRotationDegrees: 0,
                pixelWidth: old.pixelWidth,
                pixelHeight: old.pixelHeight,
                location: old.location,
                duration: old.duration,
                hasEmbeddedTimeZone: true,
                isDrifted: false,
                isAnalyzed: true,
                subfolderPath: old.subfolderPath,
                fileSize: updatedSize,
                fileModificationDate: appliedDate ?? Date(),
                isVideoFile: old.isVideoFile,
                localFileURL: old.localFileURL,
                remoteFileID: old.remoteFileID,
                remoteThumbnailLink: isGoogleDriveSource ? nil : old.remoteThumbnailLink
            )
            self.allPhotos[idx] = cleared
            appliedPairs.append((oldID: old.id, updated: cleared))
            FolderMediaService.shared.commitAppliedThumbnail(for: cleared, oldItem: old, in: source)
            if var cached = Self.analysisCache[old.id] {
                cached.modificationDate = appliedDate ?? cached.modificationDate
                cached.embeddedDate = appliedDate
                cached.adjustedDate = nil
                cached.isDateAdjusted = false
                cached.isGPSAdjusted = false
                cached.pendingRotationDegrees = nil
                cached.hasEmbeddedTimeZone = true
                cached.isDrifted = false
                cached.fileSize = updatedSize
                Self.analysisCache[old.id] = cached
            }
        }
        MetadataCacheService.shared.saveCache(Self.analysisCache, for: sourceKey)
        self.applyFilter()
        self.updateFilterCounts()
        self.savePersistedListToDisk()
        return appliedPairs
    }

    /// User selected Local destination
    func handleSelectLocalDestination() {
        isShowingDestinationSheet = false
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            self.isShowingFolderPicker = true
        }
    }

    /// User selected Google Drive destination. Shows dedicated export summary sheet.
    func handleSelectGoogleDriveDestination(account: GoogleAccount) {
        self.selectedGoogleAccount = account
        self.selectedGooglePhotosAccount = nil
        self.selectedSambaDestination = nil
        self.isShowingDestinationSheet = false

        let folderId = account.targetFolderId
        let folderName = account.targetFolderName
        self.pendingExportTarget = .googleDrive(account: account, folderId: folderId, folderName: folderName)
        self.isShowingExportSummary = true
    }

    /// User selected Google Photos destination. Shows export summary sheet without duplicate checks.
    func handleSelectGooglePhotosDestination(account: GoogleAccount) {
        self.selectedGooglePhotosAccount = account
        self.selectedGoogleAccount = nil
        self.selectedSambaDestination = nil
        self.isShowingDestinationSheet = false
        self.pendingExportTarget = .googlePhotos(account: account)
        self.isShowingExportSummary = true
    }

    /// User selected Samba destination. Shows dedicated export summary sheet.
    func handleSelectSambaDestination(destination: SambaDestination) {
        self.selectedSambaDestination = destination
        self.selectedGoogleAccount = nil
        self.selectedGooglePhotosAccount = nil
        self.isShowingDestinationSheet = false
        self.pendingExportTarget = .samba(destination)
        self.isShowingExportSummary = true
    }

    /// User confirmed export from ExportSummarySheet
    func handleConfirmExportSummary(resolvedItems: [PhotoItem]) {
        self.isShowingExportSummary = false
        self.explicitExportSourceItems = nil
        guard let target = self.pendingExportTarget else { return }
        self.pendingExportTarget = nil

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            switch target {
            case .local(let url):
                self.startExport(to: url, items: resolvedItems, conflictResolution: .overwrite)
            case .googleDrive(_, let folderId, let folderName):
                self.startGoogleDriveExport(folderId: folderId, folderName: folderName, items: resolvedItems, conflictResolution: .overwrite)
            case .googlePhotos(let account):
                self.startGooglePhotosExport(account: account, items: resolvedItems)
            case .samba(let dest):
                self.startSambaExport(destination: dest, items: resolvedItems, conflictResolution: .overwrite)
            }
        }
    }

    /// User cancelled ExportSummarySheet
    func handleCancelExportSummary() {
        self.isShowingExportSummary = false
        self.pendingExportTarget = nil
        self.explicitExportSourceItems = nil
    }

    /// User cancelled destination picker
    func handleDestinationPickerCancelled() {
        isShowingDestinationSheet = false
        explicitExportSourceItems = nil
    }

    /// User cancelled the local folder picker dialog
    func handleFolderPickerCancelled() {
        isShowingFolderPicker = false
        explicitExportSourceItems = nil
    }

    /// User cancelled the Google Drive folder picker dialog
    func handleGoogleDrivePickerCancelled() {
        isShowingGoogleDrivePicker = false
        explicitExportSourceItems = nil
    }

    /// Step 2A: Local target folder selected. Shows dedicated export summary sheet.
    func handleFolderSelected(folderURL: URL) {
        self.isShowingFolderPicker = false
        self.selectedSambaDestination = nil
        self.pendingExportTarget = .local(folderURL)
        self.isShowingExportSummary = true
    }

    /// Step 2B: Google Drive target folder selected.
    func handleGoogleDriveFolderSelected(folderId: String, folderName: String) {
        self.isShowingGoogleDrivePicker = false
        self.selectedSambaDestination = nil

        if let account = selectedGoogleAccount {
            self.pendingExportTarget = .googleDrive(account: account, folderId: folderId, folderName: folderName)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 350_000_000)
                self.isShowingExportSummary = true
            }
        }
    }

    /// Step 3A: Perform actual export processing directly into the destination
    func startExport(to destinationURL: URL, items: [PhotoItem]? = nil, conflictResolution: ExportConflictResolution = .overwrite, totalBatchCount: Int? = nil, initialSuccessfulItems: [PhotoItem] = []) {
        let itemsToExport = items ?? effectiveExportItems
        guard !itemsToExport.isEmpty else { return }

        if totalBatchCount == nil {
            self.currentBatchItems = itemsToExport
            self.totalBatchCount = itemsToExport.count
        }

        let effectiveBatchTotal = totalBatchCount ?? self.totalBatchCount
        let baseSuccess = initialSuccessfulItems.count

        // Cancel any in-flight export task before starting a new one
        activeExportTask?.cancel()
        activeExportTask = nil
        exportRunGeneration += 1
        let runGen = exportRunGeneration

        lastExportTarget = .local(destinationURL, conflictResolution)
        lastOperationWasApply = false
        let sourceMediaSource = currentMediaSource

        // Keep screen awake & request continued background processing during export
        beginBackgroundExport(totalCount: effectiveBatchTotal)

        self.applyExportProgressUpdate(ExportProgress(
            isExporting: true,
            totalCount: effectiveBatchTotal,
            currentItemIndex: baseSuccess,
            currentFilename: baseSuccess > 0 ? "Resuming export..." : "Starting export...",
            successCount: baseSuccess,
            failureCount: 0,
            destinationURL: destinationURL,
            errorMessages: [],
            failedItems: [],
            successfulItems: initialSuccessfulItems,
            isCancelled: false,
            isCompleted: false
        ))

        // Show progress sheet after folder picker or conflict sheet dismissal
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            if self.exportRunGeneration == runGen && !self.exportProgress.isCancelled {
                self.isShowingExportProgress = true
            }
        }

        activeExportTask = Task {
            let finalProgress = await exportService.exportPhotos(
                items: itemsToExport,
                to: destinationURL,
                conflictResolution: conflictResolution,
                sourceMediaSource: sourceMediaSource,
                totalBatchCount: effectiveBatchTotal,
                initialSuccessfulItems: initialSuccessfulItems
            ) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, self.exportRunGeneration == runGen else { return }
                    self.applyExportProgressUpdate(progress)
                }
            }

            guard !Task.isCancelled else { return }

            await MainActor.run { [weak self] in
                guard let self, self.exportRunGeneration == runGen else { return }
                guard !Task.isCancelled else { return }
                self.finalizeExportProgress(finalProgress)
            }
        }
    }

    /// Step 3B: Perform export processing directly to Google Drive
    func startGoogleDriveExport(folderId: String, folderName: String, accountID: String? = nil, items: [PhotoItem]? = nil, conflictResolution: ExportConflictResolution = .overwrite, totalBatchCount: Int? = nil, initialSuccessfulItems: [PhotoItem] = []) {
        let itemsToExport = items ?? effectiveExportItems
        guard !itemsToExport.isEmpty else { return }

        if totalBatchCount == nil {
            self.currentBatchItems = itemsToExport
            self.totalBatchCount = itemsToExport.count
        }

        let effectiveBatchTotal = totalBatchCount ?? self.totalBatchCount
        let baseSuccess = initialSuccessfulItems.count

        // Cancel any in-flight export task before starting a new one
        activeExportTask?.cancel()
        activeExportTask = nil
        exportRunGeneration += 1
        let runGen = exportRunGeneration

        let effectiveAccountID = accountID ?? self.selectedGoogleAccount?.id
        lastExportTarget = .googleDrive(folderId: folderId, folderName: folderName, accountID: effectiveAccountID, conflictResolution: conflictResolution)
        lastOperationWasApply = false
        let sourceMediaSource = currentMediaSource

        // Keep screen awake & request continued background processing during export
        beginBackgroundExport(totalCount: effectiveBatchTotal)

        self.applyExportProgressUpdate(ExportProgress(
            isExporting: true,
            totalCount: effectiveBatchTotal,
            currentItemIndex: baseSuccess,
            currentFilename: baseSuccess > 0 ? "Resuming Google Drive upload..." : "Preparing Google Drive upload...",
            successCount: baseSuccess,
            failureCount: 0,
            destinationURL: nil,
            errorMessages: [],
            failedItems: [],
            successfulItems: initialSuccessfulItems,
            isCancelled: false,
            isCompleted: false
        ))

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            if self.exportRunGeneration == runGen && !self.exportProgress.isCancelled {
                self.isShowingExportProgress = true
            }
        }

        activeExportTask = Task {
            let finalProgress = await googleDriveService.exportPhotos(
                items: itemsToExport,
                to: folderId,
                folderName: folderName,
                conflictResolution: conflictResolution,
                accountID: effectiveAccountID,
                sourceMediaSource: sourceMediaSource,
                totalBatchCount: effectiveBatchTotal,
                initialSuccessfulItems: initialSuccessfulItems
            ) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, self.exportRunGeneration == runGen else { return }
                    self.applyExportProgressUpdate(progress)
                }
            }

            guard !Task.isCancelled else { return }

            await MainActor.run { [weak self] in
                guard let self, self.exportRunGeneration == runGen else { return }
                guard !Task.isCancelled else { return }
                self.finalizeExportProgress(finalProgress)
            }
        }
    }

    /// Step 3C: Perform export processing to a Samba destination
    func startSambaExport(destination: SambaDestination, items: [PhotoItem]? = nil, conflictResolution: ExportConflictResolution = .overwrite, totalBatchCount: Int? = nil, initialSuccessfulItems: [PhotoItem] = []) {
        let itemsToExport = items ?? effectiveExportItems
        guard !itemsToExport.isEmpty else { return }

        if totalBatchCount == nil {
            self.currentBatchItems = itemsToExport
            self.totalBatchCount = itemsToExport.count
        }

        let effectiveBatchTotal = totalBatchCount ?? self.totalBatchCount
        let baseSuccess = initialSuccessfulItems.count

        // Cancel any in-flight export task before starting a new one
        activeExportTask?.cancel()
        activeExportTask = nil
        exportRunGeneration += 1
        let runGen = exportRunGeneration

        lastExportTarget = .samba(destination, conflictResolution)
        lastOperationWasApply = false
        let sourceMediaSource = currentMediaSource

        beginBackgroundExport(totalCount: effectiveBatchTotal)

        self.applyExportProgressUpdate(ExportProgress(
            isExporting: true,
            totalCount: effectiveBatchTotal,
            currentItemIndex: baseSuccess,
            currentFilename: baseSuccess > 0 ? "Resuming connection to \(destination.displayName)..." : "Connecting to \(destination.displayName)...",
            successCount: baseSuccess,
            failureCount: 0,
            destinationURL: nil,
            errorMessages: [],
            failedItems: [],
            successfulItems: initialSuccessfulItems,
            isCancelled: false,
            isCompleted: false
        ))

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            if self.exportRunGeneration == runGen && !self.exportProgress.isCancelled {
                self.isShowingExportProgress = true
            }
        }

        activeExportTask = Task {
            let finalProgress = await sambaService.exportPhotos(
                items: itemsToExport,
                to: destination,
                conflictResolution: conflictResolution,
                sourceMediaSource: sourceMediaSource,
                totalBatchCount: effectiveBatchTotal,
                initialSuccessfulItems: initialSuccessfulItems
            ) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, self.exportRunGeneration == runGen else { return }
                    self.applyExportProgressUpdate(progress)
                }
            }

            guard !Task.isCancelled else { return }

            await MainActor.run { [weak self] in
                guard let self, self.exportRunGeneration == runGen else { return }
                guard !Task.isCancelled else { return }
                self.selectedSambaDestination = nil
                self.finalizeExportProgress(finalProgress)
            }
        }
    }

    /// Step 3D: Perform export processing directly to Google Photos without duplicate checks or renaming
    func startGooglePhotosExport(account: GoogleAccount, items: [PhotoItem]? = nil, totalBatchCount: Int? = nil, initialSuccessfulItems: [PhotoItem] = []) {
        let itemsToExport = items ?? (selectedItems.isEmpty ? effectiveExportItems : selectedItems)
        guard !itemsToExport.isEmpty else { return }

        if totalBatchCount == nil {
            self.currentBatchItems = itemsToExport
            self.totalBatchCount = itemsToExport.count
        }

        let effectiveBatchTotal = totalBatchCount ?? self.totalBatchCount
        let baseSuccess = initialSuccessfulItems.count

        // Cancel any in-flight export task before starting a new one
        activeExportTask?.cancel()
        activeExportTask = nil
        exportRunGeneration += 1
        let runGen = exportRunGeneration

        lastExportTarget = .googlePhotos(account: account)
        lastOperationWasApply = false
        let sourceMediaSource = currentMediaSource

        // Keep screen awake & request continued background processing during export
        beginBackgroundExport(totalCount: effectiveBatchTotal)

        self.applyExportProgressUpdate(ExportProgress(
            isExporting: true,
            totalCount: effectiveBatchTotal,
            currentItemIndex: baseSuccess,
            currentFilename: baseSuccess > 0 ? "Resuming Google Photos upload..." : "Preparing Google Photos upload...",
            successCount: baseSuccess,
            failureCount: 0,
            destinationURL: nil,
            errorMessages: [],
            failedItems: [],
            successfulItems: initialSuccessfulItems,
            isCancelled: false,
            isCompleted: false
        ))

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            if self.exportRunGeneration == runGen && !self.exportProgress.isCancelled {
                self.isShowingExportProgress = true
            }
        }

        let accountID = account.id
        activeExportTask = Task {
            let finalProgress = await googlePhotosService.exportPhotos(
                items: itemsToExport,
                accountID: accountID,
                sourceMediaSource: sourceMediaSource,
                totalBatchCount: effectiveBatchTotal,
                initialSuccessfulItems: initialSuccessfulItems
            ) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, self.exportRunGeneration == runGen else { return }
                    self.applyExportProgressUpdate(progress)
                }
            }

            guard !Task.isCancelled else { return }

            await MainActor.run { [weak self] in
                guard let self, self.exportRunGeneration == runGen else { return }
                guard !Task.isCancelled else { return }
                self.selectedGooglePhotosAccount = nil
                self.finalizeExportProgress(finalProgress)
            }
        }
    }

    func retryFailedExports(items: [PhotoItem]) {
        guard !items.isEmpty else { return }
        if lastOperationWasApply && currentMediaSource.isFolder {
            let successfulSoFar = self.exportProgress.successfulItems
            let total = items.count + successfulSoFar.count
            startApplyChangesInPlace(items: items, totalBatchCount: total, initialSuccessfulItems: successfulSoFar)
            return
        }
        guard let target = lastExportTarget else { return }
        let successfulSoFar = self.exportProgress.successfulItems
        let total = self.totalBatchCount > 0 ? self.totalBatchCount : (items.count + successfulSoFar.count)

        switch target {
        case .local(let url, _):
            startExport(to: url, items: items, conflictResolution: .overwrite, totalBatchCount: total, initialSuccessfulItems: successfulSoFar)
        case .googleDrive(let folderId, let folderName, let accountID, _):
            startGoogleDriveExport(folderId: folderId, folderName: folderName, accountID: accountID, items: items, conflictResolution: .overwrite, totalBatchCount: total, initialSuccessfulItems: successfulSoFar)
        case .samba(let dest, _):
            startSambaExport(destination: dest, items: items, conflictResolution: .overwrite, totalBatchCount: total, initialSuccessfulItems: successfulSoFar)
        case .googlePhotos(let account):
            startGooglePhotosExport(account: account, items: items, totalBatchCount: total, initialSuccessfulItems: successfulSoFar)
        }
    }

    func resumeExport() {
        let successfulIDs = Set(self.exportProgress.successfulItems.map { $0.id })
        let remainingItems = self.currentBatchItems.filter { !successfulIDs.contains($0.id) }
        guard !remainingItems.isEmpty else { return }

        let successfulSoFar = self.exportProgress.successfulItems
        let total = self.totalBatchCount > 0 ? self.totalBatchCount : (remainingItems.count + successfulSoFar.count)

        if lastOperationWasApply && currentMediaSource.isFolder {
            startApplyChangesInPlace(items: remainingItems, totalBatchCount: total, initialSuccessfulItems: successfulSoFar)
            return
        }
        guard let target = lastExportTarget else { return }

        switch target {
        case .local(let url, _):
            startExport(to: url, items: remainingItems, conflictResolution: .overwrite, totalBatchCount: total, initialSuccessfulItems: successfulSoFar)
        case .googleDrive(let folderId, let folderName, let accountID, _):
            startGoogleDriveExport(folderId: folderId, folderName: folderName, accountID: accountID, items: remainingItems, conflictResolution: .overwrite, totalBatchCount: total, initialSuccessfulItems: successfulSoFar)
        case .samba(let dest, _):
            startSambaExport(destination: dest, items: remainingItems, conflictResolution: .overwrite, totalBatchCount: total, initialSuccessfulItems: successfulSoFar)
        case .googlePhotos(let account):
            startGooglePhotosExport(account: account, items: remainingItems, totalBatchCount: total, initialSuccessfulItems: successfulSoFar)
        }
    }

    func cancelExport() {
        UIApplication.shared.isIdleTimerDisabled = false
        BackgroundExportManager.shared.endExportTask(success: true)
        exportRunGeneration += 1
        activeExportTask?.cancel()
        activeExportTask = nil
        exportProgress.isCancelled = true
        exportProgress.isExporting = false
        exportProgress.isApplyInPlace = exportProgress.isApplyInPlace || lastOperationWasApply
        let remainingCount = max(0, exportProgress.totalCount - exportProgress.successCount)
        if remainingCount > 0 {
            persistExportState(exportProgress, isInProgress: true)
            showExportErrorBanner(for: exportProgress)
        } else {
            clearPersistedExportErrors()
            progressStatus = ProgressStatus(isVisible: false)
        }
    }

    func finishExport() {
        if !exportProgress.isExporting {
            UIApplication.shared.isIdleTimerDisabled = false
            clearPersistedExportErrors()
            exportRunGeneration += 1
            exportProgress = ExportProgress()
            lastExportTarget = nil
            lastOperationWasApply = false
            currentBatchItems = []
            totalBatchCount = 0
            progressStatus = ProgressStatus(isVisible: false)
        }
        isShowingExportProgress = false
    }

    func handleExportSheetDismissed() {
        if exportProgress.isExporting {
            let processed = exportProgress.successCount + exportProgress.failureCount
            let total = max(1, exportProgress.totalCount)
            progressStatus = ProgressStatus(
                isVisible: true,
                title: exportProgress.isApplyInPlace ? "Applying Changes" : "Exporting Media",
                countText: "\(processed) / \(exportProgress.totalCount)",
                progress: Double(processed) / Double(total),
                isComplete: false
            )
        } else {
            UIApplication.shared.isIdleTimerDisabled = false
            if !restoreExportErrorBannerIfNeeded() {
                progressStatus = ProgressStatus(isVisible: false)
            }
        }
    }

    private func applyExportProgressUpdate(_ progress: ExportProgress) {
        self.exportProgress = progress
        let processed = progress.successCount + progress.failureCount
        let total = max(1, progress.totalCount)
        let inFlight = progress.isExporting ? min(max(progress.currentItemProgress, 0.0), 0.999) : 0.0
        self.progressStatus = ProgressStatus(
            isVisible: true,
            title: progress.isApplyInPlace ? "Applying Changes" : "Exporting Media",
            countText: "\(processed) / \(progress.totalCount)",
            progress: min(1.0, (Double(processed) + inFlight) / Double(total)),
            isComplete: false
        )
        let bgInFlight = progress.isExporting ? min(max(progress.backgroundItemProgress, 0.0), 0.999) : 0.0
        BackgroundExportManager.shared.updateProgress(
            completed: processed,
            total: progress.totalCount,
            currentItemProgress: bgInFlight,
            currentFilename: progress.currentFilename
        )
        if progress.isExporting && processed != lastPersistedProcessedCount {
            lastPersistedProcessedCount = processed
            persistExportState(progress, isInProgress: true)
        }
    }

    private func finalizeExportProgress(_ finalProgress: ExportProgress) {
        UIApplication.shared.isIdleTimerDisabled = false
        BackgroundExportManager.shared.endExportTask(success: true)
        lastPersistedProcessedCount = -1
        self.exportProgress = finalProgress
        if finalProgress.isCancelled {
            let remainingCount = max(0, finalProgress.totalCount - finalProgress.successCount)
            if remainingCount > 0 {
                persistExportState(finalProgress, isInProgress: true)
                showExportErrorBanner(for: finalProgress)
            } else {
                clearPersistedExportErrors()
                self.progressStatus = ProgressStatus(isVisible: false)
            }
        } else if finalProgress.hasErrors {
            persistExportState(finalProgress, isInProgress: false)
            showExportErrorBanner(for: finalProgress)
        } else {
            clearPersistedExportErrors()
            self.progressStatus = ProgressStatus(isVisible: false)
        }
        if !self.exportProgress.isCancelled {
            self.isShowingExportProgress = true
        }
    }

    // MARK: - Background Export Task Helpers

    private func beginBackgroundExport(totalCount: Int) {
        UIApplication.shared.isIdleTimerDisabled = true
        BackgroundExportManager.shared.beginExportTask(totalCount: totalCount) { [weak self] in
            self?.handleBackgroundExportExpired()
        }
    }

    private func handleBackgroundExportExpired() {
        UIApplication.shared.isIdleTimerDisabled = false
        exportRunGeneration += 1
        activeExportTask?.cancel()
        activeExportTask = nil
        exportProgress.isExporting = false
        exportProgress.isInterrupted = true
        let remainingCount = max(0, exportProgress.totalCount - exportProgress.successCount)
        if remainingCount > 0 {
            persistExportState(exportProgress, isInProgress: true)
            showExportErrorBanner(for: exportProgress)
        } else {
            clearPersistedExportErrors()
            progressStatus = ProgressStatus(isVisible: false)
        }
    }

    // MARK: - Export Error Persistence

    private func showExportErrorBanner(for progress: ExportProgress) {
        let isApply = progress.isApplyInPlace
        if progress.isInterrupted || progress.isCancelled {
            let remaining = max(0, progress.totalCount - progress.successCount)
            self.progressStatus = ProgressStatus(
                isVisible: true,
                title: progress.isCancelled ? (isApply ? "Apply Cancelled" : "Export Cancelled") : (isApply ? "Apply Paused" : "Export Paused"),
                countText: "\(remaining) remaining",
                progress: progress.fractionCompleted,
                isComplete: false,
                hasError: true
            )
            return
        }

        let errCount = max(progress.failureCount, progress.failedItems.count)
        let displayCount = errCount > 0 ? errCount : progress.errorMessages.count
        let label = displayCount == 1 ? "error" : "errors"
        self.progressStatus = ProgressStatus(
            isVisible: true,
            title: isApply ? "Apply Finished with Errors" : "Export Finished with Errors",
            countText: "\(displayCount) \(label)",
            progress: progress.fractionCompleted,
            isComplete: false,
            hasError: true
        )
    }

    @discardableResult
    func restoreExportErrorBannerIfNeeded() -> Bool {
        guard !exportProgress.isExporting,
              exportProgress.isInterrupted ||
                exportProgress.isCancelled ||
                (exportProgress.isCompleted && exportProgress.hasErrors) else {
            return false
        }
        showExportErrorBanner(for: exportProgress)
        return true
    }

    private func persistExportState(_ progress: ExportProgress, isInProgress: Bool) {
        guard !lastOperationWasApply else { return }
        let persistedTarget: PersistedExportTarget? = {
            switch lastExportTarget {
            case .local(let url, _):
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                let bookmark = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
                return .local(bookmarkData: bookmark, fallbackPath: url.path)
            case .googleDrive(let folderId, let folderName, let accountID, _):
                return .googleDrive(folderId: folderId, folderName: folderName, accountID: accountID)
            case .samba(let dest, _):
                return .samba(dest)
            case .googlePhotos(let account):
                return .googlePhotos(account: account)
            case nil:
                return nil
            }
        }()

        let processedIDs = Set(progress.successfulItems.map(\.id)).union(progress.failedItems.map(\.id))
        let remaining = isInProgress ? currentBatchItems.filter { !processedIDs.contains($0.id) } : []

        let state = PersistedExportErrorState(
            isInProgress: isInProgress,
            totalCount: progress.totalCount,
            successCount: progress.successCount,
            failureCount: progress.failureCount,
            destinationPath: progress.destinationURL?.path,
            errorMessages: progress.errorMessages,
            failedItems: progress.failedItems.map { MetadataCacheService.cachedPhotoListItem(from: $0) },
            successfulItems: progress.successfulItems.map { MetadataCacheService.cachedPhotoListItem(from: $0) },
            remainingItems: remaining.map { MetadataCacheService.cachedPhotoListItem(from: $0) },
            totalBatchCount: totalBatchCount,
            target: persistedTarget
        )
        MetadataCacheService.shared.savePersistedExportErrorState(state)
        hasPersistedExportErrors = true
    }

    private func clearPersistedExportErrors() {
        lastPersistedProcessedCount = -1
        guard hasPersistedExportErrors else { return }
        hasPersistedExportErrors = false
        MetadataCacheService.shared.clearPersistedExportErrorState()
    }

    func restorePersistedExportErrorsIfAvailable() {
        guard let state = MetadataCacheService.shared.loadPersistedExportErrorState() else { return }
        hasPersistedExportErrors = true

        let allIDs = Array(Set(
            state.failedItems.map(\.id) +
            state.successfulItems.map(\.id) +
            state.remainingItems.map(\.id)
        ))
        var assetsById: [String: PHAsset] = [:]
        if !allIDs.isEmpty {
            let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: allIDs, options: nil)
            fetchResult.enumerateObjects { asset, _, _ in
                assetsById[asset.localIdentifier] = asset
            }
        }

        let restoredFailed: [PhotoItem] = state.failedItems.compactMap { cached in
            guard let asset = assetsById[cached.id] else { return nil }
            return Self.makePhotoItem(from: cached, asset: asset)
        }
        let restoredSuccessful: [PhotoItem] = state.successfulItems.compactMap { cached in
            guard let asset = assetsById[cached.id] else { return nil }
            return Self.makePhotoItem(from: cached, asset: asset)
        }
        let restoredRemaining: [PhotoItem] = state.remainingItems.compactMap { cached in
            guard let asset = assetsById[cached.id] else { return nil }
            return Self.makePhotoItem(from: cached, asset: asset)
        }

        if state.isInProgress && restoredRemaining.isEmpty && restoredFailed.isEmpty {
            clearPersistedExportErrors()
            return
        }

        self.totalBatchCount = state.totalBatchCount
        self.currentBatchItems = restoredSuccessful + restoredFailed + restoredRemaining

        switch state.target {
        case .local(let bookmarkData, let fallbackPath):
            var resolvedURL: URL? = nil
            if let data = bookmarkData {
                var isStale = false
                resolvedURL = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &isStale)
            }
            let finalURL = resolvedURL ?? URL(fileURLWithPath: fallbackPath)
            self.lastExportTarget = .local(finalURL, .overwrite)
        case .googleDrive(let folderId, let folderName, let accountID):
            self.lastExportTarget = .googleDrive(folderId: folderId, folderName: folderName, accountID: accountID, conflictResolution: .overwrite)
        case .samba(let dest):
            self.lastExportTarget = .samba(dest, .overwrite)
        case .googlePhotos(let account):
            self.lastExportTarget = .googlePhotos(account: account)
        case nil:
            self.lastExportTarget = nil
        }

        let destURL = state.destinationPath.map { URL(fileURLWithPath: $0) }
        self.exportProgress = ExportProgress(
            isExporting: false,
            totalCount: state.totalCount,
            currentItemIndex: state.successCount + state.failureCount,
            currentFilename: "",
            currentItem: nil,
            successCount: state.successCount,
            failureCount: state.failureCount,
            destinationURL: destURL,
            errorMessages: state.errorMessages,
            failedItems: restoredFailed,
            successfulItems: restoredSuccessful,
            isCancelled: false,
            isInterrupted: state.isInProgress,
            isCompleted: !state.isInProgress
        )
        showExportErrorBanner(for: self.exportProgress)
    }
}
