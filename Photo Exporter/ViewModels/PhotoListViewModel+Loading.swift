//
//  PhotoListViewModel+Loading.swift
//  Photo Exporter
//

import Foundation
import Photos
import SwiftUI

extension PhotoListViewModel {
    // MARK: - Photo Library Loading

    func loadPhotos(forceReload: Bool = false, isUserTriggeredReload: Bool = false) {
        if currentMediaSource.isFolder {
            loadFolderMedia(source: currentMediaSource, forceReload: forceReload)
            return
        }

        // If a load is already in progress and this is not a force reload, allow the active load to finish
        if isLoading && !forceReload {
            return
        }

        Self.ensureCacheLoaded(for: currentSourceKey)

        // Persistent change delta check when landing on list view (unless user explicitly triggered reload via pull-to-refresh)
        if !isUserTriggeredReload && !forceReload, let savedToken = libraryService.loadPersistentChangeToken(), !allPhotos.isEmpty {
            syncPersistentChanges(since: savedToken)
            return
        }

        if forceReload {
            Self.analysisCache.removeAll()
            MetadataCacheService.shared.clearCache(for: currentSourceKey)
            libraryService.deletePersistentChangeToken()
        }

        // Cancel previous tasks
        loadingTask?.cancel()
        analysisTask?.cancel()
        activeAnalysisQueue = nil
        activeAnalysisSessionID = nil
        isAnalyzing = false
        hasUserDismissedAnalysisSheetThisRun = false

        isLoading = true
        loadingProgressMessage = "Loading photos..."
        withAnimation(.easeOut(duration: 0.25)) {
            progressStatus = ProgressStatus(
                isVisible: true,
                title: forceReload ? "Reloading Photos..." : "Loading Photos...",
                countText: "Starting...",
                progress: 0.0,
                isComplete: false
            )
        }

        let ascending = self.isChronologicalAscending
        let capturedLibraryService = self.libraryService
        let capturedExifService = self.exifService

        loadingTask = Task.detached(priority: .userInitiated) { [weak self] in
            // 1. Grab initial change token right NOW before fetching baseline assets
            let initialToken = capturedLibraryService.currentChangeToken

            // 2. Fetch everything to establish baseline
            let assets = capturedLibraryService.fetchPhotoAssets(ascending: ascending)
            let total = assets.count

            guard total > 0 else {
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    self.allPhotos = []
                    self.applyFilter()
                    self.updateFilterCounts()
                    self.isLoading = false
                    withAnimation {
                        if !self.restoreExportErrorBannerIfNeeded() {
                            self.progressStatus = ProgressStatus(isVisible: false)
                        }
                    }
                    Self.analysisCache.removeAll()
                    MetadataCacheService.shared.clearCache()
                    capturedLibraryService.savePersistentChangeToken(initialToken)
                }
                return
            }

            var items: [PhotoItem] = []
            var itemsNeedingAnalysis: [PhotoItem] = []
            items.reserveCapacity(total)

            // Snapshot cache once to avoid 5,000+ hops to MainActor
            let cacheSnapshot = await MainActor.run { Self.analysisCache }
            let currentDeletedIDs = await MainActor.run { self?.deletedAssetIDs ?? [] }

            var lastProgressTime: Double = 0
            for (index, asset) in assets.enumerated() {
                guard !Task.isCancelled else { return }
                guard !currentDeletedIDs.contains(asset.localIdentifier) else { continue }

                let cached = cacheSnapshot[asset.localIdentifier]

                let datesMatch: Bool
                if asset.hasAdjustments, let cachedMod = cached?.modificationDate, let assetMod = asset.modificationDate {
                    datesMatch = abs(cachedMod.timeIntervalSince(assetMod)) < 1.0
                } else if asset.hasAdjustments && cached?.hasAdjustments == true {
                    datesMatch = (cached?.modificationDate == asset.modificationDate)
                } else {
                    // For unedited photos (hasAdjustments == false), modificationDate bumps caused by viewing/system tasks are ignored
                    datesMatch = true
                }

                // An asset is considered unchanged if it exists in cache, its modificationDate and hasAdjustments match,
                // and (for videos) drift status has already been evaluated.
                let needsVideoDriftCheck = (asset.mediaType == .video && cached?.isDrifted == nil)
                let needsEditedVideoInfo = (asset.mediaType == .video && asset.hasAdjustments && (cached?.duration == nil || (cached?.fileSize ?? 0) <= 0))
                let isUnchanged = (cached != nil) && datesMatch && (cached?.hasAdjustments == asset.hasAdjustments) && !needsVideoDriftCheck && !needsEditedVideoInfo
                let filename: String
                if let cachedName = cached?.originalFilename, !cachedName.isEmpty {
                    filename = cachedName
                } else {
                    filename = capturedLibraryService.resolveFilename(for: asset)
                }

                let isDateAdjusted: Bool
                let isGPSAdjusted: Bool
                let isFromOtherApps: Bool
                let embeddedDate: Date?
                let hasEmbeddedTimeZone: Bool
                let isDrifted: Bool
                let effectiveTZ: TimeZone
                if isUnchanged, let cached = cached, let tzSec = cached.timeZoneSecondsFromGMT {
                    if let id = cached.timeZoneIdentifier, let tz = TimeZone(identifier: id) {
                        effectiveTZ = tz
                    } else {
                        effectiveTZ = TimeZone(secondsFromGMT: tzSec) ?? .current
                    }
                } else {
                    // For uncached items, avoid synchronous main thread hop; true timezone is parsed in background analysis
                    effectiveTZ = .current
                }
                let isAnalyzed: Bool

                let fileSize: Int64?
                let duration: TimeInterval?
                if isUnchanged, let cached = cached {
                    isDateAdjusted = cached.isDateAdjusted
                    isGPSAdjusted = cached.isGPSAdjusted
                    isFromOtherApps = cached.isFromOtherApps
                    embeddedDate = cached.embeddedDate
                    hasEmbeddedTimeZone = cached.hasEmbeddedTimeZone
                    isDrifted = cached.isDrifted ?? false
                    fileSize = cached.fileSize
                    duration = asset.mediaType == .video ? (cached.duration ?? asset.duration) : nil
                    isAnalyzed = true
                } else {
                    // New photo or photo with updates from Photos app since last analysis
                    isDateAdjusted = false
                    isGPSAdjusted = false
                    isFromOtherApps = asset.mediaSubtypes.contains(.photoScreenshot)
                    embeddedDate = nil
                    hasEmbeddedTimeZone = false
                    isDrifted = false
                    fileSize = nil
                    duration = asset.mediaType == .video ? asset.duration : nil
                    isAnalyzed = false
                }

                let item = PhotoItem(
                    asset: asset,
                    filename: filename,
                    creationDate: asset.creationDate,
                    embeddedDate: embeddedDate,
                    timeZone: effectiveTZ,
                    isDateAdjusted: isDateAdjusted,
                    isGPSAdjusted: isGPSAdjusted,
                    isSavedFromOtherApps: isFromOtherApps,
                    duration: duration,
                    hasEmbeddedTimeZone: hasEmbeddedTimeZone,
                    isDrifted: isDrifted,
                    isAnalyzed: isAnalyzed,
                    fileSize: fileSize
                )
                items.append(item)

                if !isUnchanged {
                    itemsNeedingAnalysis.append(item)
                }

                // Update progress at most 10 FPS (every 0.1s)
                let now = CACurrentMediaTime()
                if (index == total - 1) || ((index + 1) % 100 == 0 && now - lastProgressTime >= 0.1) {
                    lastProgressTime = now
                    let currentCount = index + 1
                    let progressFraction = Double(currentCount) / Double(total)
                    await MainActor.run { [weak self] in
                        guard let self = self else { return }
                        self.progressStatus = ProgressStatus(
                            isVisible: true,
                            title: "Loading Photos",
                            countText: "\(currentCount) / \(total)",
                            progress: progressFraction,
                            isComplete: false
                        )
                    }
                }
            }

            guard !Task.isCancelled else {
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    self.isLoading = false
                    if !self.restoreExportErrorBannerIfNeeded() {
                        self.progressStatus = ProgressStatus(isVisible: false)
                    }
                }
                return
            }

            // Prune stale cache entries for any assets that were deleted from the library
            await MainActor.run {
                let currentIDs = Set(assets.map { $0.localIdentifier })
                let staleKeys = Self.analysisCache.keys.filter { !currentIDs.contains($0) }
                if !staleKeys.isEmpty {
                    for key in staleKeys {
                        Self.analysisCache.removeValue(forKey: key)
                    }
                    MetadataCacheService.shared.saveCache(Self.analysisCache)
                }
            }

            await MainActor.run { [weak self] in
                guard let self = self else { return }
                let returnedIDs = Set(assets.map { $0.localIdentifier })
                self.deletedAssetIDs = self.deletedAssetIDs.intersection(returnedIDs)
                self.allPhotos = items
                self.sortPhotos()
                self.updateFilterCounts()
                self.isLoading = false
                self.savePersistedListToDisk()
                capturedLibraryService.savePersistentChangeToken(initialToken)

                if itemsNeedingAnalysis.isEmpty {
                    self.isAnalyzing = false
                    withAnimation(.easeInOut(duration: 0.3)) {
                        self.progressStatus = ProgressStatus(
                            isVisible: true,
                            title: "All Photos Loaded",
                            countText: "\(items.count) photos",
                            progress: 1.0,
                            isComplete: true
                        )
                    }
                    Task {
                        try? await Task.sleep(nanoseconds: 800_000_000)
                        await MainActor.run {
                            guard self.currentMediaSource.sourceKey == MediaSource.photoLibrary.sourceKey else { return }
                            withAnimation(.easeOut(duration: 0.4)) {
                                if self.progressStatus.isComplete {
                                    if !self.restoreExportErrorBannerIfNeeded() {
                                        self.progressStatus.isVisible = false
                                    }
                                }
                            }
                        }
                    }
                } else {
                    self.isAnalyzing = true
                }
            }

            // Step 2: Asynchronously analyze uncached / modified photos in background
            if !itemsNeedingAnalysis.isEmpty {
                await MainActor.run { [weak self] in
                    self?.analyzeMetadataInBackground(for: itemsNeedingAnalysis)
                }
            }
        }
    }

    // MARK: - Folder Media Loading

    func loadFolderMedia(source: MediaSource, forceReload: Bool = false) {
        if isLoading && !forceReload {
            return
        }

        let sourceKey = source.sourceKey
        Self.ensureCacheLoaded(for: sourceKey)

        if forceReload {
            // Preserve manual adjustments (date/time/timezone, location, and rotation) when re-analyzing all items in a folder
            Self.analysisCache = Self.analysisCache.filter {
                $0.value.isDateAdjusted || $0.value.isGPSAdjusted || ($0.value.pendingRotationDegrees ?? 0) != 0
            }
            if Self.analysisCache.isEmpty {
                MetadataCacheService.shared.clearCache(for: sourceKey)
            } else {
                MetadataCacheService.shared.saveCache(Self.analysisCache, for: sourceKey)
            }
        }

        loadingTask?.cancel()
        analysisTask?.cancel()
        activeAnalysisQueue = nil
        activeAnalysisSessionID = nil
        isAnalyzing = false
        hasUserDismissedAnalysisSheetThisRun = false

        isLoading = true
        loadingProgressMessage = "Loading folder..."
        withAnimation(.easeOut(duration: 0.25)) {
            progressStatus = ProgressStatus(
                isVisible: true,
                title: forceReload ? "Reloading Folder..." : "Loading Folder...",
                countText: "Scanning...",
                progress: 0.0,
                isComplete: false
            )
        }

        loadingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let directory = try await FolderMediaService.shared.listDirectoryContents(in: source)
                let rawItems = directory.items
                guard !Task.isCancelled else { return }

                let cacheSnapshot = Self.analysisCache
                var items: [PhotoItem] = []
                var itemsNeedingAnalysis: [PhotoItem] = []
                items.reserveCapacity(rawItems.count)

                let returnedIDs = Set(rawItems.map { $0.id })
                let staleKeys = cacheSnapshot.keys.filter { !returnedIDs.contains($0) }
                if !staleKeys.isEmpty {
                    for key in staleKeys {
                        Self.analysisCache.removeValue(forKey: key)
                    }
                    MetadataCacheService.shared.saveCache(Self.analysisCache, for: sourceKey)
                }

                let makeCachedItem: (PhotoItem, CachedMetadataEntry, Bool) -> PhotoItem = { raw, cached, isAnalyzed in
                    let tz: TimeZone = {
                        if let id = cached.timeZoneIdentifier, let t = TimeZone(identifier: id) { return t }
                        if let secs = cached.timeZoneSecondsFromGMT { return TimeZone(secondsFromGMT: secs) ?? .current }
                        return .current
                    }()
                    let loc: CLLocation? = (cached.latitude != nil && cached.longitude != nil)
                        ? CLLocation(latitude: cached.latitude!, longitude: cached.longitude!)
                        : nil
                    let effectiveDate: Date? = cached.isDateAdjusted
                        ? (cached.adjustedDate ?? cached.embeddedDate ?? raw.fileModificationDate)
                        : (cached.embeddedDate ?? raw.fileModificationDate)

                    return PhotoItem(
                        id: raw.id,
                        filename: raw.filename,
                        creationDate: effectiveDate,
                        embeddedDate: cached.embeddedDate,
                        timeZone: tz,
                        isDateAdjusted: cached.isDateAdjusted,
                        isGPSAdjusted: cached.isGPSAdjusted,
                        pendingRotationDegrees: cached.pendingRotationDegrees ?? 0,
                        pixelWidth: cached.pixelWidth ?? raw.pixelWidth,
                        pixelHeight: cached.pixelHeight ?? raw.pixelHeight,
                        location: loc,
                        duration: cached.duration ?? raw.duration,
                        hasEmbeddedTimeZone: cached.hasEmbeddedTimeZone,
                        isDrifted: cached.isDrifted ?? false,
                        isAnalyzed: isAnalyzed,
                        subfolderPath: raw.subfolderPath,
                        fileSize: cached.fileSize ?? raw.fileSize,
                        fileModificationDate: raw.fileModificationDate,
                        isVideoFile: raw.isVideoFile,
                        localFileURL: raw.localFileURL,
                        remoteFileID: raw.remoteFileID,
                        remoteThumbnailLink: raw.remoteThumbnailLink
                    )
                }

                for raw in rawItems {
                    guard !self.deletedAssetIDs.contains(raw.id) else { continue }
                    if !forceReload,
                       let cached = cacheSnapshot[raw.id],
                       cached.modificationDate == raw.fileModificationDate {
                        items.append(makeCachedItem(raw, cached, true))
                    } else if let cached = cacheSnapshot[raw.id],
                              (cached.isDateAdjusted || cached.isGPSAdjusted || (cached.pendingRotationDegrees ?? 0) != 0) {
                        let item = makeCachedItem(raw, cached, false)
                        items.append(item)
                        itemsNeedingAnalysis.append(item)
                    } else {
                        items.append(raw)
                        itemsNeedingAnalysis.append(raw)
                    }
                }

                self.deletedAssetIDs = self.deletedAssetIDs.intersection(returnedIDs)
                self.childFolders = directory.folders
                self.allPhotos = items
                if itemsNeedingAnalysis.isEmpty, self.recomputeInferredFolderTimeZones(for: sourceKey) {
                    MetadataCacheService.shared.saveCache(Self.analysisCache, for: sourceKey)
                }
                self.sortPhotos()
                self.applyFilter()
                self.updateFilterCounts()
                self.isLoading = false
                self.savePersistedListToDisk()

                if itemsNeedingAnalysis.isEmpty {
                    self.isAnalyzing = false
                    withAnimation(.easeInOut(duration: 0.3)) {
                        self.progressStatus = ProgressStatus(
                            isVisible: true,
                            title: "Folder Loaded",
                            countText: "\(items.count) items",
                            progress: 1.0,
                            isComplete: true
                        )
                    }
                    Task {
                        try? await Task.sleep(nanoseconds: 800_000_000)
                        await MainActor.run {
                            guard self.currentMediaSource.sourceKey == sourceKey else { return }
                            withAnimation(.easeOut(duration: 0.4)) {
                                if self.progressStatus.isComplete {
                                    if !self.restoreExportErrorBannerIfNeeded() {
                                        self.progressStatus.isVisible = false
                                    }
                                }
                            }
                        }
                    }
                } else {
                    self.isAnalyzing = true
                    self.analyzeFolderMetadataInBackground(for: itemsNeedingAnalysis, source: source)
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.isLoading = false
                self.isAnalyzing = false
                self.progressStatus.isVisible = false
                self.errorMessage = "Failed to load folder: \(error.localizedDescription)"
                self.isShowingErrorAlert = true
            }
        }
    }

    // MARK: - Persistent Changes Delta Sync

    func syncPersistentChanges(since savedToken: PHPersistentChangeToken) {
        guard !isLoading else { return }

        Self.ensureCacheLoaded()
        let capturedLibraryService = self.libraryService

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let changes = try capturedLibraryService.fetchPersistentChanges(since: savedToken)
                let latestToken = capturedLibraryService.currentChangeToken

                var insertedIDs = Set<String>()
                var updatedIDs = Set<String>()
                var deletedIDs = Set<String>()

                for change in changes {
                    if let details = try? change.changeDetails(for: .asset) {
                        insertedIDs.formUnion(details.insertedLocalIdentifiers)
                        updatedIDs.formUnion(details.updatedLocalIdentifiers)
                        deletedIDs.formUnion(details.deletedLocalIdentifiers)
                    }
                }

                insertedIDs.subtract(deletedIDs)
                updatedIDs.subtract(deletedIDs)
                updatedIDs.subtract(insertedIDs)

                if insertedIDs.isEmpty && updatedIDs.isEmpty && deletedIDs.isEmpty {
                    capturedLibraryService.savePersistentChangeToken(latestToken)
                    await MainActor.run { [weak self] in
                        guard let self = self, !self.isAnalyzing else { return }
                        let unanalyzed = self.allPhotos.filter { !$0.isAnalyzed }
                        if !unanalyzed.isEmpty {
                            self.analyzeMetadataInBackground(for: unanalyzed)
                        }
                    }
                    return
                }

                let updatedAssets = updatedIDs.isEmpty ? [] : capturedLibraryService.fetchAssets(with: Array(updatedIDs))
                let insertedAssets = insertedIDs.isEmpty ? [] : capturedLibraryService.fetchAssets(with: Array(insertedIDs))

                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    self.applyPersistentChanges(
                        insertedAssets: insertedAssets,
                        updatedAssets: updatedAssets,
                        deletedIDs: deletedIDs,
                        latestToken: latestToken
                    )
                }
            } catch PHPhotosError.persistentChangeTokenExpired {
                // Token is too old and the system purged the change history.
                // Discard the token and run a baseline sync to recover.
                capturedLibraryService.deletePersistentChangeToken()
                await MainActor.run { [weak self] in
                    self?.loadPhotos(forceReload: false, isUserTriggeredReload: true)
                }
            } catch {
                print("Fetch persistent changes failed: \(error)")
                capturedLibraryService.deletePersistentChangeToken()
                await MainActor.run { [weak self] in
                    self?.loadPhotos(forceReload: false, isUserTriggeredReload: true)
                }
            }
        }
    }

    private func applyPersistentChanges(
        insertedAssets: [PHAsset],
        updatedAssets: [PHAsset],
        deletedIDs: Set<String>,
        latestToken: PHPersistentChangeToken
    ) {
        var hasStructuralChanges = false
        var itemsToAnalyze: [PhotoItem] = []

        // 1. Process deletions
        if !deletedIDs.isEmpty {
            self.allPhotos.removeAll { deletedIDs.contains($0.id) }
            self.selectedPhotoIDs.subtract(deletedIDs)
            self.deletedAssetIDs.formUnion(deletedIDs)
            for id in deletedIDs {
                Self.analysisCache.removeValue(forKey: id)
            }
            MetadataCacheService.shared.saveCache(Self.analysisCache)
            hasStructuralChanges = true

            if self.isAnalyzing, let queue = self.activeAnalysisQueue {
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    if let newTotal = await queue.remove(ids: deletedIDs), self.isAnalyzing {
                        self.analysisProgress.totalCount = newTotal
                        let count = self.analysisProgress.processedCount
                        self.progressStatus = ProgressStatus(
                            isVisible: true,
                            title: "Analyzing Photos",
                            countText: "\(count) / \(newTotal)",
                            progress: Double(count) / Double(max(1, newTotal)),
                            isComplete: false
                        )
                    }
                }
            }
        }

        // 2. Process updates
        for asset in updatedAssets {
            let assetID = asset.localIdentifier
            if let idx = self.allPhotos.firstIndex(where: { $0.id == assetID }) {
                let oldItem = self.allPhotos[idx]
                let cached = Self.analysisCache[assetID]

                // Modification date check with 1.0 second tolerance.
                // NOTE: Only evaluate for edited photos (hasAdjustments == true) to detect re-edits.
                // For unedited photos, iOS Photos updates modificationDate when viewing (e.g. iCloud download, depth/Live Photo caching, vision indexing).
                let modDateChanged: Bool
                if asset.hasAdjustments, let cachedMod = cached?.modificationDate, let assetMod = asset.modificationDate {
                    modDateChanged = abs(cachedMod.timeIntervalSince(assetMod)) >= 1.0
                } else if asset.hasAdjustments && cached?.hasAdjustments == true {
                    modDateChanged = (cached?.modificationDate != asset.modificationDate)
                } else {
                    modDateChanged = false
                }

                // Visual adjustments (crops, filters, adjustments via edit mode)
                let adjustmentsChanged = (cached?.hasAdjustments != asset.hasAdjustments)

                // Date & Time adjustment in Photos app ("Adjust Date & Time")
                let creationDateChanged: Bool
                if let oldDate = oldItem.creationDate, let newDate = asset.creationDate {
                    creationDateChanged = abs(oldDate.timeIntervalSince(newDate)) >= 1.0
                } else {
                    creationDateChanged = (oldItem.creationDate != asset.creationDate)
                }

                if creationDateChanged {
                    hasStructuralChanges = true
                }

                // Location / GPS adjustment in Photos app ("Adjust Location")
                let locationChanged: Bool
                switch (oldItem.location, asset.location) {
                case (nil, nil):
                    locationChanged = false
                case (.some, nil), (nil, .some):
                    locationChanged = true
                case let (.some(loc1), .some(loc2)):
                    locationChanged = loc1.distance(from: loc2) > 1.0
                }

                // Timezone adjustment in Photos app ("Adjust Date & Time")
                let timezoneChanged: Bool
                if asset.isPhotosAppTimeZoneAdjusted, let assetTZ = asset.photosAppTimeZone {
                    let oldOffset = oldItem.timeZone.secondsFromGMT(for: oldItem.creationDate ?? Date())
                    let newOffset = assetTZ.secondsFromGMT(for: asset.creationDate ?? Date())
                    timezoneChanged = (oldOffset != newOffset)
                } else {
                    timezoneChanged = false
                }

                let isModified = (cached == nil ||
                                  modDateChanged ||
                                  adjustmentsChanged ||
                                  creationDateChanged ||
                                  locationChanged ||
                                  timezoneChanged)

                if isModified {
                    Self.analysisCache.removeValue(forKey: assetID)
                }

                let resolvedFilename = self.libraryService.resolveFilename(for: asset)
                let effectiveTZ = (asset.photosAppTimeZone ?? oldItem.timeZone)
                let updatedItem = PhotoItem(
                    asset: asset,
                    filename: resolvedFilename.isEmpty ? oldItem.filename : resolvedFilename,
                    creationDate: asset.creationDate,
                    embeddedDate: isModified ? nil : oldItem.embeddedDate,
                    timeZone: effectiveTZ,
                    isDateAdjusted: isModified ? false : oldItem.isDateAdjusted,
                    isGPSAdjusted: isModified ? false : oldItem.isGPSAdjusted,
                    isSavedFromOtherApps: isModified ? false : oldItem.isSavedFromOtherApps,
                    duration: isModified ? asset.duration : (cached?.duration ?? oldItem.duration),
                    hasEmbeddedTimeZone: isModified ? false : oldItem.hasEmbeddedTimeZone,
                    isDrifted: isModified ? false : oldItem.isDrifted,
                    isAnalyzed: !isModified && oldItem.isAnalyzed,
                    subfolderPath: oldItem.subfolderPath,
                    fileSize: isModified ? nil : oldItem.fileSize
                )
                self.allPhotos[idx] = updatedItem
                if isModified || !updatedItem.isAnalyzed {
                    itemsToAnalyze.append(updatedItem)
                }
            }
        }

        // 3. Process insertions
        if !insertedAssets.isEmpty {
            let existingIDs = Set(self.allPhotos.map { $0.id })
            for asset in insertedAssets {
                let assetID = asset.localIdentifier
                guard !existingIDs.contains(assetID) && !self.deletedAssetIDs.contains(assetID) else { continue }

                let cached = Self.analysisCache[assetID]
                let datesMatch: Bool
                if asset.hasAdjustments, let cachedMod = cached?.modificationDate, let assetMod = asset.modificationDate {
                    datesMatch = abs(cachedMod.timeIntervalSince(assetMod)) < 1.0
                } else if asset.hasAdjustments && cached?.hasAdjustments == true {
                    datesMatch = (cached?.modificationDate == asset.modificationDate)
                } else {
                    datesMatch = true
                }
                let needsVideoDriftCheck = (asset.mediaType == .video && cached?.isDrifted == nil)
                let needsEditedVideoInfo = (asset.mediaType == .video && asset.hasAdjustments && (cached?.duration == nil || (cached?.fileSize ?? 0) <= 0))
                let isUnchanged = (cached != nil) && datesMatch && (cached?.hasAdjustments == asset.hasAdjustments) && !needsVideoDriftCheck && !needsEditedVideoInfo
                let filename = self.libraryService.resolveFilename(for: asset)

                let effectiveTZ: TimeZone
                if isUnchanged, let cached = cached, let tzSec = cached.timeZoneSecondsFromGMT {
                    if let id = cached.timeZoneIdentifier, let tz = TimeZone(identifier: id) {
                        effectiveTZ = tz
                    } else {
                        effectiveTZ = TimeZone(secondsFromGMT: tzSec) ?? .current
                    }
                } else {
                    effectiveTZ = .current
                }

                let newItem: PhotoItem
                if isUnchanged, let cached = cached {
                    newItem = PhotoItem(
                        asset: asset,
                        filename: filename,
                        creationDate: asset.creationDate,
                        embeddedDate: cached.embeddedDate,
                        timeZone: effectiveTZ,
                        isDateAdjusted: cached.isDateAdjusted,
                        isGPSAdjusted: cached.isGPSAdjusted,
                        isSavedFromOtherApps: cached.isFromOtherApps,
                        duration: asset.mediaType == .video ? (cached.duration ?? asset.duration) : nil,
                        hasEmbeddedTimeZone: cached.hasEmbeddedTimeZone,
                        isDrifted: cached.isDrifted ?? false,
                        isAnalyzed: true,
                        subfolderPath: "",
                        fileSize: cached.fileSize
                    )
                } else {
                    newItem = PhotoItem(
                        asset: asset,
                        filename: filename,
                        creationDate: asset.creationDate,
                        embeddedDate: nil,
                        timeZone: effectiveTZ,
                        isDateAdjusted: false,
                        isGPSAdjusted: false,
                        isSavedFromOtherApps: asset.mediaSubtypes.contains(.photoScreenshot),
                        duration: asset.mediaType == .video ? asset.duration : nil,
                        hasEmbeddedTimeZone: false,
                        isAnalyzed: false,
                        subfolderPath: "",
                        fileSize: nil
                    )
                    itemsToAnalyze.append(newItem)
                }
                self.allPhotos.append(newItem)
                hasStructuralChanges = true
            }
        }

        // 4. Update ordering, filter, and counts
        self.sortPhotos()
        self.updateFilterCounts()
        self.savePersistedListToDisk()

        // 5. Update token to latest state
        self.libraryService.savePersistentChangeToken(latestToken)

        // 6. Trigger background analysis if items require it
        if self.isAnalyzing {
            if !itemsToAnalyze.isEmpty {
                self.analyzeMetadataInBackground(for: itemsToAnalyze)
            }
        } else {
            let unanalyzed = self.allPhotos.filter { !$0.isAnalyzed }
            var uniqueItems: [PhotoItem] = []
            var seenIDs = Set<String>()
            for item in (itemsToAnalyze + unanalyzed) {
                if !seenIDs.contains(item.id) {
                    seenIDs.insert(item.id)
                    uniqueItems.append(item)
                }
            }
            if !uniqueItems.isEmpty {
                self.analyzeMetadataInBackground(for: uniqueItems)
            }
        }
    }
}
