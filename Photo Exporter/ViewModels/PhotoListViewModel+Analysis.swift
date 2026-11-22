//
//  PhotoListViewModel+Analysis.swift
//  Photo Exporter
//

import Foundation
import Photos
import SwiftUI
import QuartzCore
import CoreLocation

actor AnalysisQueue {
    private var items: [PhotoItem]
    private var headIndex: Int = 0
    private var indexByID: [String: Int] = [:]
    private(set) var totalCount: Int
    private var isClosed: Bool = false

    init(items: [PhotoItem]) {
        self.items = items
        self.totalCount = items.count
        for (idx, item) in items.enumerated() {
            indexByID[item.id] = idx
        }
    }

    func next() -> PhotoItem? {
        while headIndex < items.count {
            let currentIdx = headIndex
            let item = items[currentIdx]
            headIndex += 1
            if indexByID[item.id] == currentIdx {
                indexByID.removeValue(forKey: item.id)
                return item
            }
        }
        return nil
    }

    func enqueue(_ newItems: [PhotoItem]) -> Int? {
        guard !isClosed else { return nil }
        for item in newItems {
            if let existingIdx = indexByID[item.id], existingIdx >= headIndex {
                items[existingIdx] = item
            } else {
                let newIdx = items.count
                items.append(item)
                indexByID[item.id] = newIdx
                totalCount += 1
            }
        }
        return totalCount
    }

    func remove(ids: Set<String>) -> Int? {
        guard !isClosed else { return nil }
        for id in ids {
            if let existingIdx = indexByID[id], existingIdx >= headIndex {
                indexByID.removeValue(forKey: id)
                totalCount = max(0, totalCount - 1)
            }
        }
        return totalCount
    }

    func currentTotalCount() -> Int {
        totalCount
    }

    func markClosedIfEmpty() -> Bool {
        while headIndex < items.count {
            let item = items[headIndex]
            if indexByID[item.id] == headIndex {
                return false
            }
            headIndex += 1
        }
        isClosed = true
        return true
    }
}

extension PhotoListViewModel {
    // MARK: - Metadata Analysis

    func analyzeFolderMetadataInBackground(for items: [PhotoItem], source: MediaSource) {
        startBackgroundAnalysis(
            for: items,
            source: source,
            progressTitle: "Analyzing Metadata",
            showLargeRunSheet: false
        )
    }

    /// Infers timezone for analyzed folder media items lacking an embedded or manually adjusted timezone.
    /// Walks chronologically (oldest to newest), propagating the timezone of previous media first and
    /// falling back to the system timezone (`TimeZone.current`) for the first media.
    @discardableResult
    func recomputeInferredFolderTimeZones(for targetSourceKey: String? = nil) -> Bool {
        guard currentMediaSource.isFolder else { return false }
        let sourceKey = targetSourceKey ?? currentSourceKey
        Self.ensureCacheLoaded(for: sourceKey)

        let analyzedIndices = allPhotos.indices.filter { allPhotos[$0].isAnalyzed }
        guard !analyzedIndices.isEmpty else { return false }

        func shiftPreservingWallClock(_ date: Date, from sourceTZ: TimeZone, to targetTZ: TimeZone) -> Date {
            if sourceTZ.secondsFromGMT(for: date) == targetTZ.secondsFromGMT(for: date) {
                return date
            }
            var sourceCal = Calendar(identifier: .gregorian)
            sourceCal.timeZone = sourceTZ
            var targetCal = Calendar(identifier: .gregorian)
            targetCal.timeZone = targetTZ
            let comps = sourceCal.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
            return targetCal.date(from: comps) ?? date
        }

        let gmt = TimeZone(secondsFromGMT: 0)!
        func wallClockSortDate(_ date: Date, in tz: TimeZone) -> Date {
            shiftPreservingWallClock(date, from: tz, to: gmt)
        }

        struct WorkingEntry {
            let index: Int
            var timeZone: TimeZone
            var creationDate: Date?
            var embeddedDate: Date?
            let isUnanchoredClock: Bool
            let needsInference: Bool
        }

        var working: [WorkingEntry] = analyzedIndices.map { idx in
            let item = allPhotos[idx]
            let isUnanchored = !item.isVideoFile && item.embeddedDate != nil && !item.hasEmbeddedTimeZone && !item.isDateAdjusted
            return WorkingEntry(
                index: idx,
                timeZone: item.timeZone,
                creationDate: item.creationDate,
                embeddedDate: item.embeddedDate,
                isUnanchoredClock: isUnanchored,
                needsInference: !item.hasEmbeddedTimeZone && !item.isDateAdjusted
            )
        }

        // Pass 1: Resolve UTC-accurate items (embedded TZ, manually adjusted, videos, and dateless mtime images)
        let utcOrderedIndices = working.indices
            .filter { !working[$0].isUnanchoredClock }
            .sorted { i, j in
                let a = allPhotos[working[i].index]
                let b = allPhotos[working[j].index]
                let d1 = working[i].creationDate ?? a.fileModificationDate ?? Date.distantPast
                let d2 = working[j].creationDate ?? b.fileModificationDate ?? Date.distantPast
                if d1 != d2 { return d1 < d2 }
                return a.filename.localizedStandardCompare(b.filename) == .orderedAscending
            }

        var prevTZ: TimeZone? = nil
        for wIdx in utcOrderedIndices {
            if working[wIdx].needsInference {
                let inferredTZ = prevTZ ?? TimeZone.current
                working[wIdx].timeZone = inferredTZ
                prevTZ = inferredTZ
            } else {
                prevTZ = working[wIdx].timeZone
            }
        }

        // Pass 2: Place unanchored-clock images by local wall-clock against resolved anchors & earlier wall-clocks
        let wallClockOrderedIndices = working.indices.sorted { i, j in
            let a = allPhotos[working[i].index]
            let b = allPhotos[working[j].index]
            let dateA = working[i].creationDate ?? a.fileModificationDate ?? Date.distantPast
            let dateB = working[j].creationDate ?? b.fileModificationDate ?? Date.distantPast
            let wallA = wallClockSortDate(dateA, in: working[i].timeZone)
            let wallB = wallClockSortDate(dateB, in: working[j].timeZone)
            if wallA != wallB { return wallA < wallB }
            return a.filename.localizedStandardCompare(b.filename) == .orderedAscending
        }

        prevTZ = nil
        for wIdx in wallClockOrderedIndices {
            if working[wIdx].isUnanchoredClock {
                let inferredTZ = prevTZ ?? TimeZone.current
                let oldTZ = working[wIdx].timeZone
                if let cDate = working[wIdx].creationDate {
                    working[wIdx].creationDate = shiftPreservingWallClock(cDate, from: oldTZ, to: inferredTZ)
                }
                if let eDate = working[wIdx].embeddedDate {
                    working[wIdx].embeddedDate = shiftPreservingWallClock(eDate, from: oldTZ, to: inferredTZ)
                }
                working[wIdx].timeZone = inferredTZ
                prevTZ = inferredTZ
            } else {
                prevTZ = working[wIdx].timeZone
            }
        }

        // Pass 3: Re-sweep UTC-only unadjusted items (videos / mtime images) with all wall-clock images now calibrated
        let finalUTCOrderedIndices = working.indices.sorted { i, j in
            let a = allPhotos[working[i].index]
            let b = allPhotos[working[j].index]
            let d1 = working[i].creationDate ?? a.fileModificationDate ?? Date.distantPast
            let d2 = working[j].creationDate ?? b.fileModificationDate ?? Date.distantPast
            if d1 != d2 { return d1 < d2 }
            return a.filename.localizedStandardCompare(b.filename) == .orderedAscending
        }

        prevTZ = nil
        for wIdx in finalUTCOrderedIndices {
            if working[wIdx].needsInference && !working[wIdx].isUnanchoredClock {
                let inferredTZ = prevTZ ?? TimeZone.current
                working[wIdx].timeZone = inferredTZ
                prevTZ = inferredTZ
            } else {
                prevTZ = working[wIdx].timeZone
            }
        }

        var didChange = false
        for w in working where w.needsInference {
            let old = allPhotos[w.index]
            let refDate = w.creationDate ?? old.creationDate ?? Date()
            let tzChanged = old.timeZone.identifier != w.timeZone.identifier ||
                old.timeZone.secondsFromGMT(for: refDate) != w.timeZone.secondsFromGMT(for: refDate)
            let dateChanged: Bool = {
                switch (old.creationDate, w.creationDate) {
                case (nil, nil): return false
                case (let a?, let b?): return abs(a.timeIntervalSince(b)) >= 0.001
                default: return true
                }
            }()

            guard tzChanged || dateChanged else { continue }
            didChange = true

            allPhotos[w.index] = PhotoItem(
                id: old.id,
                filename: old.filename,
                creationDate: w.creationDate,
                embeddedDate: w.embeddedDate,
                timeZone: w.timeZone,
                isDateAdjusted: old.isDateAdjusted,
                isGPSAdjusted: old.isGPSAdjusted,
                pendingRotationDegrees: old.pendingRotationDegrees,
                pixelWidth: old.pixelWidth,
                pixelHeight: old.pixelHeight,
                location: old.location,
                duration: old.duration,
                hasEmbeddedTimeZone: old.hasEmbeddedTimeZone,
                isDrifted: old.isDrifted,
                isAnalyzed: old.isAnalyzed,
                subfolderPath: old.subfolderPath,
                fileSize: old.fileSize,
                fileModificationDate: old.fileModificationDate,
                isVideoFile: old.isVideoFile,
                localFileURL: old.localFileURL,
                remoteFileID: old.remoteFileID,
                remoteThumbnailLink: old.remoteThumbnailLink
            )

            if var entry = Self.analysisCache[old.id] {
                entry.embeddedDate = w.embeddedDate
                entry.timeZoneIdentifier = w.timeZone.identifier
                entry.timeZoneSecondsFromGMT = w.timeZone.secondsFromGMT(for: refDate)
                Self.analysisCache[old.id] = entry
            }
        }

        return didChange
    }

    private enum AnalysisBatchUpdate {
        case photoLibrary(
            id: String,
            asset: PHAsset,
            filename: String,
            evaluation: (embeddedDate: Date?, isDateAdjusted: Bool, isGPSAdjusted: Bool, isFromOtherApps: Bool, hasEmbeddedTimeZone: Bool, timeZone: TimeZone, isDrifted: Bool),
            fileSize: Int64?,
            duration: TimeInterval?
        )
        case folder(
            id: String,
            item: PhotoItem,
            evaluation: ExifMetadataService.FolderEvaluatedMetadata
        )

        var id: String {
            switch self {
            case .photoLibrary(let id, _, _, _, _, _): return id
            case .folder(let id, _, _): return id
            }
        }
    }

    /// Background task to inspect embedded EXIF vs asset date & camera origin
    func analyzeMetadataInBackground(for itemsToAnalyze: [PhotoItem]) {
        startBackgroundAnalysis(
            for: itemsToAnalyze,
            source: .photoLibrary,
            progressTitle: "Analyzing Photos",
            showLargeRunSheet: true
        )
    }

    /// Unified, batched, and throttled background metadata analysis pipeline shared by Photo Library and Folder sources.
    private func startBackgroundAnalysis(
        for itemsToAnalyze: [PhotoItem],
        source: MediaSource,
        progressTitle: String,
        showLargeRunSheet: Bool
    ) {
        guard !itemsToAnalyze.isEmpty else { return }

        // If analysis is already running, insert new/updated items into the active queue
        // rather than cancelling and restarting from 0.
        if self.isAnalyzing, let existingQueue = self.activeAnalysisQueue {
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if let newTotal = await existingQueue.enqueue(itemsToAnalyze) {
                    self.analysisProgress.totalCount = newTotal
                    let count = self.analysisProgress.processedCount
                    self.progressStatus = ProgressStatus(
                        isVisible: true,
                        title: progressTitle,
                        countText: "\(count) / \(newTotal)",
                        progress: Double(count) / Double(max(1, newTotal)),
                        isComplete: false
                    )
                } else {
                    self.startBackgroundAnalysis(
                        for: itemsToAnalyze,
                        source: source,
                        progressTitle: progressTitle,
                        showLargeRunSheet: showLargeRunSheet
                    )
                }
            }
            return
        }

        let capturedLibraryService = self.libraryService
        let capturedExifService = self.exifService
        let sourceKey = source.sourceKey
        let isFolderSource = source.isFolder
        let totalCount = itemsToAnalyze.count
        let queue = AnalysisQueue(items: itemsToAnalyze)
        let sessionID = UUID()

        self.activeAnalysisQueue = queue
        self.activeAnalysisSessionID = sessionID
        self.isAnalyzing = true

        self.analysisProgress = AnalysisProgress(
            isAnalyzing: true,
            isFinished: false,
            totalCount: totalCount,
            processedCount: 0,
            currentItem: itemsToAnalyze.first,
            currentFilename: itemsToAnalyze.first?.filename ?? "",
            errorMessages: [],
            failedItems: []
        )

        // Show dedicated progress sheet if more than 100 unanalyzed items and user hasn't dismissed it
        if showLargeRunSheet && totalCount > 100 && !hasUserDismissedAnalysisSheetThisRun && !isShowingAnalysisSheet {
            self.isShowingAnalysisSheet = true
        }

        withAnimation(.easeOut(duration: 0.25)) {
            self.progressStatus = ProgressStatus(
                isVisible: true,
                title: progressTitle,
                countText: "0 / \(totalCount)",
                progress: 0.0,
                isComplete: false
            )
        }

        analysisTask?.cancel()
        analysisTask = Task.detached(priority: .userInitiated) { [weak self] in
            let concurrency = 4
            var processedCount = 0
            var lastUIUpdateTime: Double = 0
            var lastBatchUIUpdateTime: Double = 0
            var errorsEncountered: [String] = []
            var failedItems: [PhotoItem] = []
            var pendingBatch: [AnalysisBatchUpdate] = []
            pendingBatch.reserveCapacity(150)

            typealias ItemResult = (
                item: PhotoItem,
                update: AnalysisBatchUpdate?,
                failureMessage: String?
            )

            @Sendable func evaluateSingleItem(_ item: PhotoItem) async -> ItemResult {
                if Task.isCancelled {
                    return (item, nil, nil)
                }

                if isFolderSource {
                    do {
                        let eval = try await FolderMediaService.shared.analyzeItem(item, in: source)
                        return (item, .folder(id: item.id, item: item, evaluation: eval), nil)
                    } catch {
                        return (item, nil, "\(item.filename): \(error.localizedDescription)")
                    }
                } else {
                    guard let itemAsset = item.asset else {
                        return (item, nil, "Failed to analyze \(item.filename): unable to read image metadata")
                    }
                    let evaluated = await Self.evaluatePhotoLibraryItem(
                        item,
                        asset: itemAsset,
                        isVideo: itemAsset.mediaType == .video,
                        isEdited: itemAsset.hasAdjustments,
                        filename: item.filename,
                        libraryService: capturedLibraryService,
                        exifService: capturedExifService
                    )
                    if let validEval = evaluated.evaluation {
                        return (
                            item,
                            .photoLibrary(
                                id: item.id,
                                asset: itemAsset,
                                filename: item.filename,
                                evaluation: validEval,
                                fileSize: evaluated.fileSize,
                                duration: evaluated.duration
                            ),
                            nil
                        )
                    } else {
                        return (item, nil, "Failed to analyze \(item.filename): unable to read image metadata")
                    }
                }
            }

            // Stream evaluation results continuously using a task group pipeline.
            // Re-check queue.markClosedIfEmpty() after each pass so items enqueued
            // right as the last workers finish are seamlessly picked up.
            while !Task.isCancelled {
                await withTaskGroup(of: ItemResult.self) { group in
                    // Prime the pipeline with concurrent workers
                    for _ in 0..<concurrency {
                        if let nextItem = await queue.next() {
                            group.addTask {
                                await evaluateSingleItem(nextItem)
                            }
                        }
                    }

                    // Process each item continuously as soon as it finishes
                    for await result in group {
                        guard !Task.isCancelled else { break }

                        // Immediately replenish the worker queue with the next photo
                        if let nextItem = await queue.next() {
                            group.addTask {
                                await evaluateSingleItem(nextItem)
                            }
                        }

                        if let update = result.update {
                            pendingBatch.append(update)
                        } else {
                            failedItems.append(result.item)
                            if let failureMessage = result.failureMessage {
                                errorsEncountered.append(failureMessage)
                            }
                        }

                        processedCount += 1
                        let now = CACurrentMediaTime()
                        let currentTotal = await queue.currentTotalCount()

                        // Stream UI updates live on every completed photo (rate-limited to 10 FPS: 0.1s)
                        if (processedCount >= currentTotal) || (now - lastUIUpdateTime >= 0.1) {
                            lastUIUpdateTime = now
                            let count = processedCount
                            let currentProgress = Double(count) / Double(max(1, currentTotal))
                            let currentCountText = "\(count) / \(currentTotal)"
                            let snapshotErrors = errorsEncountered
                            let snapshotFailed = failedItems
                            let activeItem = result.item

                            Task { @MainActor [weak self] in
                                guard let self = self, self.activeAnalysisSessionID == sessionID else { return }
                                self.analysisProgress.totalCount = currentTotal
                                self.analysisProgress.currentItem = activeItem
                                self.analysisProgress.currentFilename = activeItem.filename
                                self.analysisProgress.processedCount = count
                                self.analysisProgress.errorMessages = snapshotErrors
                                self.analysisProgress.failedItems = snapshotFailed
                                self.progressStatus = ProgressStatus(
                                    isVisible: true,
                                    title: progressTitle,
                                    countText: currentCountText,
                                    progress: currentProgress,
                                    isComplete: false
                                )
                            }
                        }

                        // Batch UI updates & disk saves every 100+ items and >= 3.5 seconds since last update
                        if pendingBatch.count >= 100 && (now - lastBatchUIUpdateTime >= 3.5) {
                            lastBatchUIUpdateTime = now
                            let batchToApply = pendingBatch
                            pendingBatch.removeAll(keepingCapacity: true)

                            await MainActor.run { [weak self] in
                                guard let self = self, self.activeAnalysisSessionID == sessionID else { return }
                                self.applyAnalysisBatch(batchToApply, sourceKey: sourceKey, isFolderSource: isFolderSource)
                            }
                        }
                    }
                }
                if await queue.markClosedIfEmpty() {
                    break
                }
            }

            guard !Task.isCancelled else {
                await MainActor.run { [weak self] in
                    guard let self = self, self.activeAnalysisSessionID == sessionID else { return }
                    MetadataCacheService.shared.saveCache(Self.analysisCache, for: sourceKey)
                    self.savePersistedListToDisk()
                    self.activeAnalysisQueue = nil
                    self.activeAnalysisSessionID = nil
                    self.isAnalyzing = false
                    self.analysisProgress.isAnalyzing = false
                    self.progressStatus = ProgressStatus(isVisible: false)
                }
                return
            }

            // Flush any remaining items in pendingBatch before finalizing
            if !pendingBatch.isEmpty {
                let remainingBatch = pendingBatch
                pendingBatch.removeAll()
                await MainActor.run { [weak self] in
                    guard let self = self, self.activeAnalysisSessionID == sessionID else { return }
                    self.applyAnalysisBatch(remainingBatch, sourceKey: sourceKey, isFolderSource: isFolderSource)
                }
            } else if isFolderSource {
                await MainActor.run { [weak self] in
                    guard let self = self, self.activeAnalysisSessionID == sessionID else { return }
                    if self.recomputeInferredFolderTimeZones(for: sourceKey) {
                        self.sortPhotos()
                        self.updateFilterCounts()
                    }
                }
            }

            // Final completion state
            let finalTotal = await queue.currentTotalCount()
            let finalErrors = errorsEncountered
            let finalFailed = failedItems
            await MainActor.run { [weak self] in
                guard let self = self, self.activeAnalysisSessionID == sessionID else { return }
                MetadataCacheService.shared.saveCache(Self.analysisCache, for: sourceKey)
                self.savePersistedListToDisk()
                self.activeAnalysisQueue = nil
                self.activeAnalysisSessionID = nil
                self.isAnalyzing = false
                self.analysisProgress.isAnalyzing = false
                self.analysisProgress.isFinished = true
                self.analysisProgress.currentItem = nil
                self.analysisProgress.totalCount = finalTotal
                self.analysisProgress.processedCount = max(0, finalTotal - finalFailed.count)
                self.analysisProgress.errorMessages = finalErrors
                self.analysisProgress.failedItems = finalFailed

                let unanalyzedCount = self.allPhotos.filter { !$0.isAnalyzed }.count
                let pendingCount = max(finalFailed.count, unanalyzedCount)

                if pendingCount > 0 {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        self.progressStatus = ProgressStatus(
                            isVisible: true,
                            title: "Analysis Finished (\(pendingCount) pending retry)",
                            countText: "Tap to retry",
                            progress: Double(self.allPhotos.count - pendingCount) / Double(max(1, self.allPhotos.count)),
                            isComplete: false
                        )
                    }
                    // Keep banner visible - do not auto-dismiss when there are pending retries!
                } else {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        self.progressStatus = ProgressStatus(
                            isVisible: true,
                            title: "Analysis Complete",
                            countText: "\(finalTotal) / \(finalTotal)",
                            progress: 1.0,
                            isComplete: true
                        )
                    }

                    Task {
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
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
                }
            }
        }
    }

    private nonisolated static func evaluatePhotoLibraryItem(
        _ item: PhotoItem,
        asset itemAsset: PHAsset,
        isVideo: Bool,
        isEdited: Bool,
        filename: String,
        libraryService: PhotoLibraryService,
        exifService: ExifMetadataService
    ) async -> (
        evaluation: (embeddedDate: Date?, isDateAdjusted: Bool, isGPSAdjusted: Bool, isFromOtherApps: Bool, hasEmbeddedTimeZone: Bool, timeZone: TimeZone, isDrifted: Bool)?,
        fileSize: Int64?,
        duration: TimeInterval?
    ) {
        if isVideo {
            let localVideoURL: URL? = await withCheckedContinuation { continuation in
                let options = PHVideoRequestOptions()
                options.isNetworkAccessAllowed = false
                options.version = .original
                libraryService.imageManager.requestAVAsset(forVideo: itemAsset, options: options) { avAsset, _, _ in
                    continuation.resume(returning: (avAsset as? AVURLAsset)?.url)
                }
            }
            let evaluation = exifService.evaluateVideoMetadataQuick(
                asset: itemAsset,
                filename: filename,
                fileURL: localVideoURL
            )
            if isEdited {
                let editedMetrics = await libraryService.fetchEditedVideoMetrics(for: itemAsset, allowNetworkAccess: false)
                let fallbackSize = await MainActor.run {
                    ExportDeduplicationEngine.getDeviceFileSize(for: item)
                }
                let effectiveSize = (editedMetrics.estimatedFileSize ?? 0) > 0 ? editedMetrics.estimatedFileSize : (fallbackSize > 0 ? fallbackSize : nil)
                let effectiveDuration = editedMetrics.duration ?? (itemAsset.duration > 0 ? itemAsset.duration : nil)
                return (evaluation, effectiveSize, effectiveDuration)
            } else {
                let analyzedFileSize = await MainActor.run {
                    ExportDeduplicationEngine.getDeviceFileSize(for: item)
                }
                let dur: TimeInterval? = itemAsset.duration > 0 ? itemAsset.duration : nil
                return (evaluation, analyzedFileSize, dur)
            }
        }

        // 1. Fast local read without network
        let localResult = await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = false
            options.version = isEdited ? .current : .original
            options.isSynchronous = true

            libraryService.imageManager.requestImageDataAndOrientation(for: itemAsset, options: options) { data, _, _, _ in
                let size = data.flatMap { Int64($0.count) }
                continuation.resume(returning: (data, size))
            }
        }

        var photoData = localResult.0
        var photoSize = localResult.1
        var evaluated = exifService.evaluateMetadataQuick(
            data: photoData,
            asset: itemAsset,
            filename: filename
        )

        // 2. If local read returned nil (e.g. photo stored in iCloud), fetch immediately without artificial delay
        if evaluated == nil {
            do {
                let fetched = try await libraryService.fetchImageData(for: itemAsset, preferEdited: isEdited)
                photoData = fetched.data
                photoSize = Int64(fetched.data.count)
                evaluated = exifService.evaluateMetadataQuick(
                    data: photoData,
                    asset: itemAsset,
                    filename: filename
                )
            } catch {
                // Network fetch failed
            }
        }

        let fallbackSize: Int64?
        if let photoSize {
            fallbackSize = photoSize
        } else {
            fallbackSize = await MainActor.run {
                ExportDeduplicationEngine.getDeviceFileSize(for: item)
            }
        }
        return (evaluated, fallbackSize, nil)
    }

    private func applyAnalysisBatch(
        _ batchToApply: [AnalysisBatchUpdate],
        sourceKey: String,
        isFolderSource: Bool
    ) {
        Self.ensureCacheLoaded(for: sourceKey)
        let batchMap = Dictionary(batchToApply.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        var updated = self.allPhotos
        var hasChanges = false

        for idx in 0..<updated.count {
            let old = updated[idx]
            guard let entry = batchMap[old.id] else { continue }

            switch entry {
            case .photoLibrary(_, let asset, let filename, let evaluation, let fileSize, let duration):
                // Skip applying stale results if the asset was edited again while in pendingBatch
                guard let oldAsset = old.asset, asset.modificationDate == oldAsset.modificationDate else { continue }

                let resolvedDuration = duration ?? old.duration

                Self.analysisCache[old.id] = CachedMetadataEntry(
                    modificationDate: asset.modificationDate,
                    hasAdjustments: asset.hasAdjustments,
                    embeddedDate: evaluation.embeddedDate,
                    isDateAdjusted: evaluation.isDateAdjusted,
                    isGPSAdjusted: evaluation.isGPSAdjusted,
                    isFromOtherApps: evaluation.isFromOtherApps,
                    hasEmbeddedTimeZone: evaluation.hasEmbeddedTimeZone,
                    isDrifted: evaluation.isDrifted,
                    originalFilename: filename,
                    fileSize: fileSize,
                    timeZoneIdentifier: evaluation.timeZone.identifier,
                    timeZoneSecondsFromGMT: evaluation.timeZone.secondsFromGMT(),
                    duration: resolvedDuration
                )

                updated[idx] = PhotoItem(
                    asset: oldAsset,
                    filename: filename,
                    creationDate: old.creationDate,
                    embeddedDate: evaluation.embeddedDate,
                    timeZone: evaluation.timeZone,
                    isDateAdjusted: evaluation.isDateAdjusted,
                    isGPSAdjusted: evaluation.isGPSAdjusted,
                    isSavedFromOtherApps: evaluation.isFromOtherApps,
                    duration: resolvedDuration,
                    hasEmbeddedTimeZone: evaluation.hasEmbeddedTimeZone,
                    isDrifted: evaluation.isDrifted,
                    isAnalyzed: true,
                    subfolderPath: old.subfolderPath,
                    fileSize: fileSize ?? old.fileSize
                )
                hasChanges = true

            case .folder(_, let analyzedItem, let eval):
                let existing = Self.analysisCache[old.id]
                let isDateAdj = existing?.isDateAdjusted ?? false
                let isGPSAdj = existing?.isGPSAdjusted ?? false
                let pendingRotation = old.pendingRotationDegrees != 0
                    ? old.pendingRotationDegrees
                    : (existing?.pendingRotationDegrees ?? 0)
                let finalDate = isDateAdj ? (existing?.adjustedDate ?? eval.effectiveDate) : eval.effectiveDate
                let finalTZ: TimeZone = {
                    if isDateAdj {
                        if let id = existing?.timeZoneIdentifier, let tz = TimeZone(identifier: id) {
                            return tz
                        }
                        if let secs = existing?.timeZoneSecondsFromGMT, let tz = TimeZone(secondsFromGMT: secs) {
                            return tz
                        }
                    }
                    return eval.timeZone
                }()
                let finalLoc: CLLocation? = {
                    if isGPSAdj, let lat = existing?.latitude, let lon = existing?.longitude {
                        return CLLocation(latitude: lat, longitude: lon)
                    }
                    return eval.location
                }()

                Self.analysisCache[old.id] = CachedMetadataEntry(
                    modificationDate: analyzedItem.fileModificationDate,
                    hasAdjustments: false,
                    embeddedDate: eval.embeddedDate,
                    adjustedDate: isDateAdj ? finalDate : nil,
                    isDateAdjusted: isDateAdj,
                    isGPSAdjusted: isGPSAdj,
                    pendingRotationDegrees: pendingRotation != 0 ? pendingRotation : nil,
                    isFromOtherApps: false,
                    hasEmbeddedTimeZone: eval.hasEmbeddedTimeZone,
                    isDrifted: eval.isDrifted,
                    originalFilename: analyzedItem.filename,
                    fileSize: analyzedItem.fileSize,
                    timeZoneIdentifier: finalTZ.identifier,
                    timeZoneSecondsFromGMT: finalTZ.secondsFromGMT(for: finalDate ?? Date()),
                    pixelWidth: eval.pixelWidth,
                    pixelHeight: eval.pixelHeight,
                    duration: eval.duration,
                    latitude: finalLoc?.coordinate.latitude,
                    longitude: finalLoc?.coordinate.longitude
                )

                updated[idx] = PhotoItem(
                    id: old.id,
                    filename: old.filename,
                    creationDate: finalDate,
                    embeddedDate: eval.embeddedDate,
                    timeZone: finalTZ,
                    isDateAdjusted: isDateAdj,
                    isGPSAdjusted: isGPSAdj,
                    pendingRotationDegrees: pendingRotation,
                    pixelWidth: eval.pixelWidth,
                    pixelHeight: eval.pixelHeight,
                    location: finalLoc,
                    duration: eval.duration ?? old.duration,
                    hasEmbeddedTimeZone: eval.hasEmbeddedTimeZone,
                    isDrifted: eval.isDrifted,
                    isAnalyzed: true,
                    subfolderPath: old.subfolderPath,
                    fileSize: old.fileSize,
                    fileModificationDate: old.fileModificationDate,
                    isVideoFile: old.isVideoFile,
                    localFileURL: old.localFileURL,
                    remoteFileID: old.remoteFileID,
                    remoteThumbnailLink: old.remoteThumbnailLink
                )
                hasChanges = true
            }
        }

        if hasChanges {
            self.allPhotos = updated
            if isFolderSource {
                _ = self.recomputeInferredFolderTimeZones(for: sourceKey)
                self.sortPhotos()
            } else {
                self.applyFilter()
            }
            self.updateFilterCounts()
        }

        MetadataCacheService.shared.saveCache(Self.analysisCache, for: sourceKey)
        self.savePersistedListToDisk()
    }

    /// Handles dismissal of the analysis progress sheet, ensuring the banner remains visible if retries are pending
    func handleAnalysisSheetDismissed() {
        self.hasUserDismissedAnalysisSheetThisRun = true
        let unanalyzedCount = allPhotos.filter { !$0.isAnalyzed }.count
        let failedCount = max(analysisProgress.failedItems.count, unanalyzedCount)

        if failedCount > 0 {
            withAnimation(.easeInOut(duration: 0.25)) {
                progressStatus = ProgressStatus(
                    isVisible: true,
                    title: "Analysis Pending Retry (\(failedCount))",
                    countText: "Tap to retry",
                    progress: Double(allPhotos.count - failedCount) / Double(max(1, allPhotos.count)),
                    isComplete: false
                )
            }
        } else if !isAnalyzing {
            withAnimation(.easeOut(duration: 0.25)) {
                if !restoreExportErrorBannerIfNeeded() {
                    progressStatus = ProgressStatus(isVisible: false)
                }
            }
        }
    }

    /// Retries metadata analysis for any failed or unanalyzed items
    func retryFailedAnalysis(items: [PhotoItem]? = nil) {
        let itemsToRetry: [PhotoItem]
        if let items = items, !items.isEmpty {
            itemsToRetry = items
        } else if !analysisProgress.failedItems.isEmpty {
            itemsToRetry = analysisProgress.failedItems
        } else {
            itemsToRetry = allPhotos.filter { !$0.isAnalyzed }
        }

        guard !itemsToRetry.isEmpty else { return }
        if currentMediaSource.isFolder {
            analyzeFolderMetadataInBackground(for: itemsToRetry, source: currentMediaSource)
        } else {
            analyzeMetadataInBackground(for: itemsToRetry)
        }
    }
}
