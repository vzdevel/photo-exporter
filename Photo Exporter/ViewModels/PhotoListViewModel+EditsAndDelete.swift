//
//  PhotoListViewModel+EditsAndDelete.swift
//  Photo Exporter
//

import Foundation
import Photos
import SwiftUI
import CoreLocation

extension PhotoListViewModel {
    // MARK: - Date, Time & Metadata Adjustments

    /// Update an item's date and adjustment state across ViewModel and static cache
    func updatePhotoAdjustment(assetID: String, newDate: Date, timeZone: TimeZone, isAdjusted: Bool) {
        // 1. Fetch updated PHAsset snapshot from library if possible (Photo Library mode only)
        let isFolder = currentMediaSource.isFolder
        let fetchedAsset = isFolder ? nil : PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject
        let existing = Self.analysisCache[assetID]

        // 2. Update static analysis cache so subsequent reloads retain this adjustment
        Self.analysisCache[assetID] = CachedMetadataEntry(
            modificationDate: fetchedAsset?.modificationDate ?? existing?.modificationDate,
            hasAdjustments: fetchedAsset?.hasAdjustments ?? isAdjusted,
            embeddedDate: existing?.embeddedDate,
            adjustedDate: isFolder && isAdjusted ? newDate : existing?.adjustedDate,
            isDateAdjusted: isAdjusted,
            isGPSAdjusted: existing?.isGPSAdjusted ?? false,
            pendingRotationDegrees: existing?.pendingRotationDegrees,
            isFromOtherApps: existing?.isFromOtherApps ?? false,
            hasEmbeddedTimeZone: existing?.hasEmbeddedTimeZone ?? false,
            isDrifted: existing?.isDrifted,
            originalFilename: existing?.originalFilename,
            fileSize: existing?.fileSize,
            timeZoneIdentifier: timeZone.identifier,
            timeZoneSecondsFromGMT: timeZone.secondsFromGMT(),
            pixelWidth: existing?.pixelWidth,
            pixelHeight: existing?.pixelHeight,
            duration: existing?.duration,
            latitude: existing?.latitude,
            longitude: existing?.longitude
        )
        MetadataCacheService.shared.saveCache(Self.analysisCache, for: currentSourceKey)

        // 3. Update item in allPhotos
        if let idx = allPhotos.firstIndex(where: { $0.id == assetID }) {
            let old = allPhotos[idx]
            if let assetToUse = fetchedAsset ?? old.asset {
                allPhotos[idx] = PhotoItem(
                    asset: assetToUse,
                    filename: old.filename,
                    creationDate: newDate,
                    embeddedDate: existing?.embeddedDate ?? old.embeddedDate,
                    timeZone: timeZone,
                    isDateAdjusted: isAdjusted,
                    isGPSAdjusted: old.isGPSAdjusted,
                    isSavedFromOtherApps: old.isSavedFromOtherApps,
                    duration: old.duration,
                    hasEmbeddedTimeZone: existing?.hasEmbeddedTimeZone ?? old.hasEmbeddedTimeZone,
                    isDrifted: existing?.isDrifted ?? old.isDrifted,
                    isAnalyzed: true,
                    subfolderPath: old.subfolderPath,
                    fileSize: existing?.fileSize ?? old.fileSize
                )
            } else {
                allPhotos[idx] = PhotoItem(
                    id: old.id,
                    filename: old.filename,
                    creationDate: newDate,
                    embeddedDate: existing?.embeddedDate ?? old.embeddedDate,
                    timeZone: timeZone,
                    isDateAdjusted: isAdjusted,
                    isGPSAdjusted: old.isGPSAdjusted,
                    pendingRotationDegrees: old.pendingRotationDegrees,
                    pixelWidth: old.pixelWidth,
                    pixelHeight: old.pixelHeight,
                    location: old.location,
                    duration: old.duration,
                    hasEmbeddedTimeZone: existing?.hasEmbeddedTimeZone ?? old.hasEmbeddedTimeZone,
                    isDrifted: existing?.isDrifted ?? old.isDrifted,
                    isAnalyzed: true,
                    subfolderPath: old.subfolderPath,
                    fileSize: existing?.fileSize ?? old.fileSize,
                    fileModificationDate: old.fileModificationDate,
                    isVideoFile: old.isVideoFile,
                    localFileURL: old.localFileURL,
                    remoteFileID: old.remoteFileID,
                    remoteThumbnailLink: old.remoteThumbnailLink
                )
            }
        }

        // 4. Propagate inferred folder timezones if needed, then re-sort, filter, and save
        if isFolder, recomputeInferredFolderTimeZones(for: currentSourceKey) {
            MetadataCacheService.shared.saveCache(Self.analysisCache, for: currentSourceKey)
        }
        sortPhotos()
        applyFilter()
        updateFilterCounts()
        savePersistedListToDisk()
    }

    /// Update metadata for a single photo refreshed from PhotoDetailView
    func updateSinglePhotoMetadata(assetID: String, metadata: PhotoExifMetadata) {
        let freshAsset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject
        let existing = Self.analysisCache[assetID]

        let trueOriginal = (metadata.originalFilename?.isEmpty == false) ? metadata.originalFilename! : metadata.filename

        let preservedPendingRotation = currentMediaSource.isFolder
            ? (metadata.pendingRotationDegrees != 0 ? metadata.pendingRotationDegrees : (existing?.pendingRotationDegrees ?? 0))
            : 0
        Self.analysisCache[assetID] = CachedMetadataEntry(
            modificationDate: freshAsset?.modificationDate ?? existing?.modificationDate,
            hasAdjustments: freshAsset?.hasAdjustments ?? (metadata.isDateAdjusted || preservedPendingRotation != 0),
            embeddedDate: metadata.embeddedDate ?? existing?.embeddedDate,
            adjustedDate: metadata.isDateAdjusted ? (metadata.creationDate ?? existing?.adjustedDate) : existing?.adjustedDate,
            isDateAdjusted: metadata.isDateAdjusted,
            isGPSAdjusted: metadata.isGPSAdjusted,
            pendingRotationDegrees: preservedPendingRotation > 0 ? preservedPendingRotation : nil,
            isFromOtherApps: metadata.isSavedFromOtherApps,
            hasEmbeddedTimeZone: metadata.hasEmbeddedTimeZone,
            isDrifted: metadata.isDrifted,
            originalFilename: trueOriginal,
            fileSize: (metadata.fileByteCount ?? 0) > 0 ? metadata.fileByteCount : existing?.fileSize,
            timeZoneIdentifier: metadata.timeZone.identifier,
            timeZoneSecondsFromGMT: metadata.timeZone.secondsFromGMT(for: metadata.creationDate ?? Date()),
            pixelWidth: metadata.pixelWidth > 0 ? metadata.pixelWidth : existing?.pixelWidth,
            pixelHeight: metadata.pixelHeight > 0 ? metadata.pixelHeight : existing?.pixelHeight,
            duration: metadata.duration ?? existing?.duration,
            latitude: metadata.location?.coordinate.latitude ?? existing?.latitude,
            longitude: metadata.location?.coordinate.longitude ?? existing?.longitude
        )
        MetadataCacheService.shared.saveCache(Self.analysisCache, for: currentSourceKey)

        if let idx = allPhotos.firstIndex(where: { $0.id == assetID }) {
            let old = allPhotos[idx]
            if let assetToUse = freshAsset ?? old.asset {
                allPhotos[idx] = PhotoItem(
                    asset: assetToUse,
                    filename: trueOriginal,
                    creationDate: metadata.creationDate ?? assetToUse.creationDate,
                    embeddedDate: metadata.embeddedDate,
                    timeZone: metadata.timeZone,
                    isDateAdjusted: metadata.isDateAdjusted,
                    isGPSAdjusted: metadata.isGPSAdjusted,
                    isSavedFromOtherApps: metadata.isSavedFromOtherApps,
                    duration: metadata.duration ?? old.duration,
                    hasEmbeddedTimeZone: metadata.hasEmbeddedTimeZone,
                    isDrifted: metadata.isDrifted,
                    isAnalyzed: true,
                    subfolderPath: old.subfolderPath,
                    fileSize: ((metadata.fileByteCount ?? 0) > 0 ? metadata.fileByteCount : nil) ?? existing?.fileSize ?? old.fileSize
                )
            } else {
                allPhotos[idx] = PhotoItem(
                    id: old.id,
                    filename: trueOriginal,
                    creationDate: metadata.creationDate ?? old.creationDate,
                    embeddedDate: metadata.embeddedDate ?? old.embeddedDate,
                    timeZone: metadata.timeZone,
                    isDateAdjusted: metadata.isDateAdjusted,
                    isGPSAdjusted: metadata.isGPSAdjusted,
                    pendingRotationDegrees: preservedPendingRotation,
                    pixelWidth: metadata.pixelWidth > 0 ? metadata.pixelWidth : old.pixelWidth,
                    pixelHeight: metadata.pixelHeight > 0 ? metadata.pixelHeight : old.pixelHeight,
                    location: metadata.location ?? old.location,
                    duration: metadata.duration ?? old.duration,
                    hasEmbeddedTimeZone: metadata.hasEmbeddedTimeZone,
                    isDrifted: metadata.isDrifted,
                    isAnalyzed: true,
                    subfolderPath: old.subfolderPath,
                    fileSize: ((metadata.fileByteCount ?? 0) > 0 ? metadata.fileByteCount : nil) ?? existing?.fileSize ?? old.fileSize,
                    fileModificationDate: old.fileModificationDate,
                    isVideoFile: old.isVideoFile,
                    localFileURL: old.localFileURL,
                    remoteFileID: old.remoteFileID,
                    remoteThumbnailLink: old.remoteThumbnailLink
                )
            }
            applyFilter()
            updateFilterCounts()
            savePersistedListToDisk()
        }
    }

    /// Batch update date/time and/or timezone for selected items
    func batchUpdateDateTime(
        newStartingDate: Date?,
        stepSeconds: Int,
        newTimeZone: TimeZone?
    ) async {
        let itemsToUpdate = selectedItems
        guard !itemsToUpdate.isEmpty else { return }
        guard newStartingDate != nil || newTimeZone != nil else { return }

        let step = max(0, stepSeconds)
        var updates: [(asset: PHAsset?, newDate: Date, timeZone: TimeZone?, item: PhotoItem)] = []

        for (index, item) in itemsToUpdate.enumerated() {
            let finalTimeZone: TimeZone
            let finalDate: Date

            if let startingDate = newStartingDate, let targetTz = newTimeZone {
                // BOTH: Date & Time AND Timezone are updated
                // Wall-clock components from startingDate are applied in targetTz
                let userCal = Calendar.current
                let comps = userCal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: startingDate)
                var targetCal = Calendar(identifier: .gregorian)
                targetCal.timeZone = targetTz
                let baseDate = targetCal.date(from: comps) ?? startingDate
                finalDate = baseDate.addingTimeInterval(Double(index * step))
                finalTimeZone = targetTz
            } else if let startingDate = newStartingDate {
                // ONLY Date & Time is updated; preserve existing item timezone
                finalTimeZone = item.timeZone
                let userCal = Calendar.current
                let comps = userCal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: startingDate)
                var itemCal = Calendar(identifier: .gregorian)
                itemCal.timeZone = item.timeZone
                let baseDate = itemCal.date(from: comps) ?? startingDate
                finalDate = baseDate.addingTimeInterval(Double(index * step))
            } else if let targetTz = newTimeZone {
                // ONLY Timezone is updated; preserve wall-clock time
                var targetCal = Calendar(identifier: .gregorian)
                targetCal.timeZone = targetTz
                var sourceCal = Calendar(identifier: .gregorian)
                sourceCal.timeZone = item.timeZone
                let date = item.creationDate ?? Date()
                let comps = sourceCal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
                finalDate = targetCal.date(from: comps) ?? date
                finalTimeZone = targetTz
            } else {
                continue
            }

            updates.append((asset: item.asset, newDate: finalDate, timeZone: finalTimeZone, item: item))
        }

        if currentMediaSource.isFolder {
            await MainActor.run {
                for update in updates {
                    let itemID = update.item.id
                    let existing = Self.analysisCache[itemID]
                    let tz = update.timeZone ?? update.item.timeZone
                    Self.analysisCache[itemID] = CachedMetadataEntry(
                        modificationDate: update.item.fileModificationDate,
                        hasAdjustments: false,
                        embeddedDate: existing?.embeddedDate ?? update.item.embeddedDate,
                        adjustedDate: update.newDate,
                        isDateAdjusted: true,
                        isGPSAdjusted: existing?.isGPSAdjusted ?? update.item.isGPSAdjusted,
                        isFromOtherApps: false,
                        hasEmbeddedTimeZone: existing?.hasEmbeddedTimeZone ?? update.item.hasEmbeddedTimeZone,
                        isDrifted: existing?.isDrifted ?? update.item.isDrifted,
                        originalFilename: update.item.filename,
                        fileSize: existing?.fileSize ?? update.item.fileSize,
                        timeZoneIdentifier: tz.identifier,
                        timeZoneSecondsFromGMT: tz.secondsFromGMT(for: update.newDate),
                        pixelWidth: existing?.pixelWidth ?? update.item.pixelWidth,
                        pixelHeight: existing?.pixelHeight ?? update.item.pixelHeight,
                        duration: existing?.duration ?? update.item.duration,
                        latitude: existing?.latitude ?? update.item.location?.coordinate.latitude,
                        longitude: existing?.longitude ?? update.item.location?.coordinate.longitude
                    )

                    if let idx = self.allPhotos.firstIndex(where: { $0.id == itemID }) {
                        let old = self.allPhotos[idx]
                        self.allPhotos[idx] = PhotoItem(
                            id: old.id,
                            filename: old.filename,
                            creationDate: update.newDate,
                            embeddedDate: existing?.embeddedDate ?? old.embeddedDate,
                            timeZone: tz,
                            isDateAdjusted: true,
                            isGPSAdjusted: old.isGPSAdjusted,
                            pixelWidth: old.pixelWidth,
                            pixelHeight: old.pixelHeight,
                            location: old.location,
                            duration: old.duration,
                            hasEmbeddedTimeZone: existing?.hasEmbeddedTimeZone ?? old.hasEmbeddedTimeZone,
                            isDrifted: existing?.isDrifted ?? old.isDrifted,
                            isAnalyzed: true,
                            subfolderPath: old.subfolderPath,
                            fileSize: existing?.fileSize ?? old.fileSize,
                            fileModificationDate: old.fileModificationDate,
                            isVideoFile: old.isVideoFile,
                            localFileURL: old.localFileURL,
                            remoteFileID: old.remoteFileID,
                            remoteThumbnailLink: old.remoteThumbnailLink
                        )
                    }
                }
                _ = self.recomputeInferredFolderTimeZones(for: self.currentSourceKey)
                MetadataCacheService.shared.saveCache(Self.analysisCache, for: self.currentSourceKey)
                self.sortPhotos()
                self.applyFilter()
                self.updateFilterCounts()
                self.savePersistedListToDisk()
            }
            return
        }

        do {
            try await libraryService.batchUpdateAssetDateTime(
                updates: updates.compactMap { u in u.asset.map { ($0, u.newDate, u.timeZone) } }
            )

            // Update in-memory items and static analysisCache
            await MainActor.run {
                for update in updates {
                    guard let origAsset = update.asset else { continue }
                    let assetID = update.item.id
                    let existing = Self.analysisCache[assetID]
                    let freshAsset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject ?? origAsset
                    Self.analysisCache[assetID] = CachedMetadataEntry(
                        modificationDate: freshAsset.modificationDate,
                        hasAdjustments: freshAsset.hasAdjustments,
                        embeddedDate: existing?.embeddedDate ?? update.item.embeddedDate,
                        adjustedDate: existing?.adjustedDate,
                        isDateAdjusted: true,
                        isGPSAdjusted: existing?.isGPSAdjusted ?? update.item.isGPSAdjusted,
                        pendingRotationDegrees: existing?.pendingRotationDegrees,
                        isFromOtherApps: existing?.isFromOtherApps ?? update.item.isSavedFromOtherApps,
                        hasEmbeddedTimeZone: existing?.hasEmbeddedTimeZone ?? update.item.hasEmbeddedTimeZone,
                        isDrifted: existing?.isDrifted ?? update.item.isDrifted,
                        originalFilename: existing?.originalFilename ?? update.item.filename,
                        fileSize: existing?.fileSize ?? update.item.fileSize,
                        timeZoneIdentifier: update.timeZone?.identifier,
                        timeZoneSecondsFromGMT: update.timeZone?.secondsFromGMT(for: update.newDate),
                        pixelWidth: existing?.pixelWidth,
                        pixelHeight: existing?.pixelHeight,
                        duration: existing?.duration ?? update.item.duration,
                        latitude: existing?.latitude,
                        longitude: existing?.longitude
                    )

                    if let idx = self.allPhotos.firstIndex(where: { $0.id == assetID }) {
                        let old = self.allPhotos[idx]
                        self.allPhotos[idx] = PhotoItem(
                            asset: freshAsset,
                            filename: old.filename,
                            creationDate: update.newDate,
                            embeddedDate: existing?.embeddedDate ?? old.embeddedDate,
                            timeZone: update.timeZone ?? old.timeZone,
                            isDateAdjusted: true,
                            isGPSAdjusted: old.isGPSAdjusted,
                            isSavedFromOtherApps: old.isSavedFromOtherApps,
                            duration: old.duration,
                            hasEmbeddedTimeZone: existing?.hasEmbeddedTimeZone ?? old.hasEmbeddedTimeZone,
                            isDrifted: existing?.isDrifted ?? old.isDrifted,
                            isAnalyzed: true,
                            subfolderPath: old.subfolderPath,
                            fileSize: existing?.fileSize ?? old.fileSize
                        )
                    }
                }

                MetadataCacheService.shared.saveCache(Self.analysisCache)
                self.sortPhotos()
                self.applyFilter()
                self.updateFilterCounts()
            }
        } catch {
            await MainActor.run {
                self.errorMessage = "Failed to update date & time: \(error.localizedDescription)"
                self.isShowingErrorAlert = true
            }
        }
    }

    // MARK: - Delete Workflow

    func initiateDelete() {
        deleteSelectedPhotos()
    }

    func confirmDelete() {
        deleteSelectedPhotos()
    }

    func deleteSelectedPhotos() {
        let itemsToDelete = selectedItems
        guard !itemsToDelete.isEmpty else { return }

        if currentMediaSource.isFolder {
            pendingFolderDeleteItems = itemsToDelete
            isShowingFolderDeleteConfirmation = true
            return
        }

        let assets = itemsToDelete.compactMap { $0.asset }
        let deletedIDs = Set(itemsToDelete.map { $0.id })

        Task {
            do {
                try await libraryService.deleteAssets(assets)
                await MainActor.run {
                    for id in deletedIDs {
                        self.deletedAssetIDs.insert(id)
                        Self.pruneCacheEntry(for: id, sourceKey: self.currentSourceKey)
                        self.allPhotos.removeAll { $0.id == id }
                        self.selectedPhotoIDs.remove(id)
                    }
                    withAnimation {
                        self.applyFilter()
                        self.updateFilterCounts()
                        self.savePersistedListToDisk()
                    }
                }
            } catch {
                let nsErr = error as NSError
                if (nsErr.domain == "PHPhotosErrorDomain" && nsErr.code == 3072) ||
                   (nsErr.domain == NSCocoaErrorDomain && nsErr.code == NSUserCancelledError) {
                    return
                }
                await MainActor.run {
                    self.errorMessage = "Failed to delete photos: \(error.localizedDescription)"
                    self.isShowingErrorAlert = true
                }
            }
        }
    }

    func confirmDeleteSelectedFolderItems() {
        let itemsToDelete = pendingFolderDeleteItems.isEmpty ? selectedItems : pendingFolderDeleteItems
        pendingFolderDeleteItems = []
        guard currentMediaSource.isFolder, !itemsToDelete.isEmpty else { return }
        let source = currentMediaSource
        let sourceKey = source.sourceKey
        let deletedIDs = Set(itemsToDelete.map { $0.id })

        Task {
            do {
                try await FolderMediaService.shared.deleteItems(itemsToDelete, in: source)
                await MainActor.run {
                    for id in deletedIDs {
                        self.deletedAssetIDs.insert(id)
                        Self.pruneCacheEntry(for: id, sourceKey: sourceKey)
                        self.allPhotos.removeAll { $0.id == id }
                        self.selectedPhotoIDs.remove(id)
                    }
                    withAnimation {
                        if self.recomputeInferredFolderTimeZones(for: sourceKey) {
                            MetadataCacheService.shared.saveCache(Self.analysisCache, for: sourceKey)
                            self.sortPhotos()
                        }
                        self.applyFilter()
                        self.updateFilterCounts()
                        self.savePersistedListToDisk()
                    }
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Failed to delete files: \(error.localizedDescription)"
                    self.isShowingErrorAlert = true
                }
            }
        }
    }

    func requestDeleteFolder(_ folder: FolderListEntry) {
        pendingFolderDirectoryDelete = folder
        isShowingFolderDirectoryDeleteConfirmation = true
    }

    func confirmDeleteFolderDirectory() {
        guard let folder = pendingFolderDirectoryDelete else { return }
        pendingFolderDirectoryDelete = nil
        guard currentMediaSource.isFolder else { return }
        let source = currentMediaSource

        Task {
            do {
                try await FolderMediaService.shared.deleteFolder(folder, in: source)
                await MainActor.run {
                    withAnimation {
                        self.childFolders.removeAll { $0.id == folder.id }
                        if self.activePathSegmentCount < self.displayedPathSegments.count,
                           let nextDimmed = self.displayedPathSegments.dropFirst(self.activePathSegmentCount).first,
                           nextDimmed.targetSource == folder.targetSource || nextDimmed.id == folder.id {
                            self.displayedPathSegments = Array(self.displayedPathSegments.prefix(self.activePathSegmentCount))
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Failed to delete folder: \(error.localizedDescription)"
                    self.isShowingErrorAlert = true
                }
            }
        }
    }

    func deleteSinglePhoto(item: PhotoItem) {
        if currentMediaSource.isFolder {
            pendingFolderDeleteItems = [item]
            isShowingFolderDeleteConfirmation = true
            return
        }

        guard let asset = item.asset else { return }
        // Optimistically remove from memory so the full swipe row collapse completes smoothly without bouncing
        let originalIndex = allPhotos.firstIndex(where: { $0.id == item.id })
        deletedAssetIDs.insert(item.id)
        selectedPhotoIDs.remove(item.id)
        withAnimation {
            allPhotos.removeAll { $0.id == item.id }
            applyFilter()
            updateFilterCounts()
        }

        Task {
            do {
                try await libraryService.deleteAssets([asset])
                await MainActor.run {
                    Self.pruneCacheEntry(for: item.id, sourceKey: self.currentSourceKey)
                }
            } catch {
                let nsErr = error as NSError
                let isCancelled = (nsErr.domain == "PHPhotosErrorDomain" && nsErr.code == 3072) ||
                                  (nsErr.domain == NSCocoaErrorDomain && nsErr.code == NSUserCancelledError)
                await MainActor.run {
                    // Restore item back to its position if cancelled or failed
                    self.deletedAssetIDs.remove(item.id)
                    withAnimation {
                        if let idx = originalIndex, idx <= self.allPhotos.count {
                            self.allPhotos.insert(item, at: idx)
                        } else {
                            self.allPhotos.append(item)
                            self.sortPhotos()
                        }
                        self.applyFilter()
                        self.updateFilterCounts()
                    }

                    if !isCancelled {
                        self.errorMessage = "Failed to delete photo: \(error.localizedDescription)"
                        self.isShowingErrorAlert = true
                    }
                }
            }
        }
    }
}
