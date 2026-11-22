//
//  PhotoListViewModel.swift
//  Photo Exporter
//

import Foundation
import Photos
import SwiftUI
import Combine
import UIKit
import CoreData
import QuartzCore

struct PathBarRevealRequest: Equatable {
    let segmentID: String
    let nonce: Int
}

@MainActor
final class ProgressCoordinator: ObservableObject {
    @Published var progressStatus = PhotoListViewModel.ProgressStatus()
    @Published var analysisProgress = AnalysisProgress()
    @Published var exportProgress = ExportProgress()
}

@MainActor
final class PhotoListViewModel: ObservableObject {
    // MARK: - Published Properties

    @Published var allPhotos: [PhotoItem] = []
    @Published var filteredPhotos: [PhotoItem] = []
    @Published var selectedMediaType: MediaTypeFilter = .all {
        didSet {
            if oldValue != selectedMediaType {
                deselectAll()
            }
            applyFilter()
            updateFilterCounts()
        }
    }
    @Published var selectedFilter: PhotoFilter = .all {
        didSet {
            if oldValue != selectedFilter {
                deselectAll()
            }
            applyFilter()
        }
    }

    @Published var isChronologicalAscending: Bool = false {
        didSet {
            sortPhotos()
        }
    }

    // Authorization & Loading State
    @Published var authorizationStatus: PHAuthorizationStatus = .notDetermined
    @Published var isLoading: Bool = false
    @Published var loadingProgressMessage: String = ""

    // Progress Status for Loading and Background Analysis
    struct ProgressStatus: Equatable {
        var isVisible: Bool = false
        var title: String = ""
        var countText: String = ""
        var progress: Double = 0.0
        var isComplete: Bool = false
        var hasError: Bool = false
    }

    let progressCoordinator = ProgressCoordinator()

    var progressStatus: ProgressStatus {
        get { progressCoordinator.progressStatus }
        set {
            let wasVisible = progressCoordinator.progressStatus.isVisible
            progressCoordinator.progressStatus = newValue
            if wasVisible != newValue.isVisible {
                objectWillChange.send()
            }
        }
        _modify {
            let wasVisible = progressCoordinator.progressStatus.isVisible
            yield &progressCoordinator.progressStatus
            if wasVisible != progressCoordinator.progressStatus.isVisible {
                objectWillChange.send()
            }
        }
    }

    @Published var isAnalyzing: Bool = false

    var loadingTask: Task<Void, Never>? = nil
    var analysisTask: Task<Void, Never>? = nil
    var activeAnalysisQueue: AnalysisQueue? = nil
    var activeAnalysisSessionID: UUID? = nil

    // Multi-Selection State
    @Published var isSelectionMode: Bool = false {
        didSet {
            if !isSelectionMode {
                selectedPhotoIDs.removeAll()
                lastSelectedID = nil
                isRangeSelectionMode = false
            }
        }
    }
    @Published var selectedPhotoIDs: Set<String> = []
    @Published var lastSelectedID: String? = nil
    @Published var isRangeSelectionMode: Bool = false

    // Export & Delete State
    @Published var isShowingDestinationSheet: Bool = false
    @Published var isShowingBatchDateTimeSheet: Bool = false
    @Published var isShowingFolderPicker: Bool = false
    @Published var isShowingGoogleDrivePicker: Bool = false
    @Published var isShowingExportProgress: Bool = false
    var exportProgress: ExportProgress {
        get { progressCoordinator.exportProgress }
        set {
            let wasExporting = progressCoordinator.exportProgress.isExporting
            progressCoordinator.exportProgress = newValue
            if wasExporting != newValue.isExporting {
                objectWillChange.send()
            }
        }
        _modify {
            let wasExporting = progressCoordinator.exportProgress.isExporting
            yield &progressCoordinator.exportProgress
            if wasExporting != progressCoordinator.exportProgress.isExporting {
                objectWillChange.send()
            }
        }
    }
    @Published var activeExportTask: Task<Void, Never>? = nil
    @Published var selectedGoogleAccount: GoogleAccount? = nil
    @Published var selectedGooglePhotosAccount: GoogleAccount? = nil
    @Published var selectedSambaDestination: SambaDestination? = nil
    @Published var pendingExportTarget: ExportTargetDestination? = nil
    @Published var isShowingExportSummary: Bool = false
    @Published var isShowingAnalysisSheet: Bool = false
    @Published var currentMediaSource: MediaSource = .photoLibrary
    @Published var isShowingMediaSourceSheet: Bool = false
    @Published var isShowingApplySummarySheet: Bool = false
    @Published var isShowingFolderDeleteConfirmation: Bool = false
    @Published var pendingFolderDeleteItems: [PhotoItem] = []
    @Published var childFolders: [FolderListEntry] = []
    @Published var displayedPathSegments: [FolderPathSegment] = []
    @Published var activePathSegmentCount: Int = 0
    @Published var pathBarRevealRequest: PathBarRevealRequest? = nil
    @Published var pendingFolderDirectoryDelete: FolderListEntry? = nil
    @Published var isShowingFolderDirectoryDeleteConfirmation: Bool = false
    private var nextPathRevealNonce: Int = 0
    private var pathHierarchyTask: Task<Void, Never>? = nil
    var lastOperationWasApply: Bool = false
    var exportRunGeneration: Int = 0
    var explicitExportSourceItems: [PhotoItem]? = nil
    var onFolderItemAppliedInPlace: ((String, PhotoItem) -> Void)? = nil
    var onBeforeFinalSwapInPlace: ((PhotoItem) async -> Void)? = nil
    var analysisProgress: AnalysisProgress {
        get { progressCoordinator.analysisProgress }
        set { progressCoordinator.analysisProgress = newValue }
        _modify { yield &progressCoordinator.analysisProgress }
    }
    var hasUserDismissedAnalysisSheetThisRun: Bool = false
    var deletedAssetIDs: Set<String> = []

    // Alerts / Errors
    @Published var errorMessage: String? = nil
    @Published var isShowingErrorAlert: Bool = false

    /// True if any photo in the library has not yet completed analysis
    var hasUnanalyzedPhotos: Bool {
        allPhotos.contains { !$0.isAnalyzed }
    }

    /// Number of unanalyzed photos currently in the library
    var unanalyzedPhotoCount: Int {
        allPhotos.filter { !$0.isAnalyzed }.count
    }

    /// Export is completely prohibited when loading, analyzing, exporting, or when there are unanalyzed items
    var isExportDisabled: Bool {
        isLoading || isAnalyzing || exportProgress.isExporting || hasUnanalyzedPhotos
    }

    /// Show Apply (instead of Export) in folder mode only when at least one selected item has pending changes/edits to apply in place
    var shouldShowApplyButton: Bool {
        shouldShowApply(for: selectedItems)
    }

    func shouldShowApply(for items: [PhotoItem]) -> Bool {
        currentMediaSource.isFolder && items.contains(where: { $0.needsInPlaceApply })
    }

    // Filter Counts
    @Published var filterCounts: [PhotoFilter: Int] = [
        .all: 0,
        .inferred: 0,
        .adjusted: 0,
        .edited: 0,
        .savedFromOtherApps: 0
    ]

    // Cache analyzed metadata persistently across app launches without TTL (isolated per sourceKey)
    static var analysisCache: [String: CachedMetadataEntry] = [:]
    static var loadedCacheSourceKey: String? = nil
    private static let lastMediaSourceStorageKey = "last_selected_media_source"

    static func saveLastMediaSource(_ source: MediaSource) {
        if let encoded = try? JSONEncoder().encode(source) {
            UserDefaults.standard.set(encoded, forKey: lastMediaSourceStorageKey)
        }
    }

    static func loadLastMediaSource() -> MediaSource {
        guard let data = UserDefaults.standard.data(forKey: lastMediaSourceStorageKey),
              let decoded = try? JSONDecoder().decode(MediaSource.self, from: data) else {
            return .photoLibrary
        }

        let resolved: MediaSource
        switch decoded {
        case .photoLibrary:
            resolved = .photoLibrary
        case .localFolder:
            resolved = decoded.resolveLocalFolderURL() != nil ? decoded : .photoLibrary
        case .googleDrive(let account):
            if var freshAccount = GoogleDriveAuthService.shared.accounts.first(where: { $0.id == account.id }) {
                freshAccount.folderId = account.folderId
                freshAccount.folderName = account.folderName
                freshAccount.folderPath = account.folderPath
                freshAccount.folderBreadcrumbs = account.folderBreadcrumbs
                resolved = .googleDrive(account: freshAccount)
            } else {
                resolved = .photoLibrary
            }
        case .samba(let destination):
            if var freshDest = SambaService.shared.destinations.first(where: { $0.id == destination.id }) {
                if !destination.share.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    freshDest.share = destination.share
                    freshDest.path = destination.path
                }
                resolved = .samba(destination: freshDest)
            } else {
                resolved = .photoLibrary
            }
        }

        if resolved != decoded {
            saveLastMediaSource(resolved)
        }
        return resolved
    }

    var currentSourceKey: String {
        currentMediaSource.sourceKey
    }

    static func ensureCacheLoaded(for sourceKey: String = MediaSource.photoLibrary.sourceKey) {
        if loadedCacheSourceKey != sourceKey {
            analysisCache = MetadataCacheService.shared.loadCache(for: sourceKey)
            loadedCacheSourceKey = sourceKey
        }
    }

    /// Prunes a single asset entry from the analysis cache and persists to disk
    static func pruneCacheEntry(for assetID: String, sourceKey: String = MediaSource.photoLibrary.sourceKey) {
        ensureCacheLoaded(for: sourceKey)
        if analysisCache.removeValue(forKey: assetID) != nil {
            MetadataCacheService.shared.saveCache(analysisCache, for: sourceKey)
        }
    }

    /// Removes a deleted photo by ID from all internal lists and cache
    func removeDeletedPhoto(assetID: String) {
        deletedAssetIDs.insert(assetID)
        Self.pruneCacheEntry(for: assetID, sourceKey: currentSourceKey)
        allPhotos.removeAll { $0.id == assetID }
        selectedPhotoIDs.remove(assetID)
        if currentMediaSource.isFolder, recomputeInferredFolderTimeZones(for: currentSourceKey) {
            MetadataCacheService.shared.saveCache(Self.analysisCache, for: currentSourceKey)
            sortPhotos()
        }
        applyFilter()
        updateFilterCounts()
        savePersistedListToDisk()
    }

    /// Persists the current in-memory photo list and filter counts to disk
    func savePersistedListToDisk() {
        var countsDict: [String: Int] = [:]
        for (filter, count) in filterCounts {
            countsDict[filter.rawValue] = count
        }
        MetadataCacheService.shared.savePersistedList(items: self.allPhotos, filterCounts: countsDict, for: currentSourceKey)
    }

    /// Restore persisted photo list from disk for instant display upon startup or source switch
    private func restorePersistedListIfAvailable() {
        let (cachedItems, cachedCounts) = MetadataCacheService.shared.loadPersistedList(for: currentSourceKey)
        guard !cachedItems.isEmpty else {
            self.allPhotos = []
            self.applyFilter()
            self.updateFilterCounts()
            return
        }

        var restored: [PhotoItem] = []
        restored.reserveCapacity(cachedItems.count)

        if currentMediaSource.isFolder {
            let folderURL = currentMediaSource.resolveLocalFolderURL()
            for cached in cachedItems {
                let tz: TimeZone = {
                    if let id = cached.timeZoneIdentifier, let t = TimeZone(identifier: id) { return t }
                    return TimeZone(secondsFromGMT: cached.timeZoneSecondsFromGMT) ?? .current
                }()
                let loc: CLLocation? = (cached.latitude != nil && cached.longitude != nil)
                    ? CLLocation(latitude: cached.latitude!, longitude: cached.longitude!)
                    : nil
                let localURL = folderURL?.appendingPathComponent(cached.filename)
                restored.append(PhotoItem(
                    id: cached.id,
                    filename: cached.filename,
                    creationDate: cached.creationDate,
                    embeddedDate: cached.embeddedDate,
                    timeZone: tz,
                    isDateAdjusted: cached.isDateAdjusted,
                    isGPSAdjusted: cached.isGPSAdjusted,
                    pendingRotationDegrees: cached.pendingRotationDegrees ?? 0,
                    pixelWidth: cached.pixelWidth,
                    pixelHeight: cached.pixelHeight,
                    location: loc,
                    duration: cached.duration,
                    hasEmbeddedTimeZone: cached.hasEmbeddedTimeZone,
                    isDrifted: cached.isDrifted ?? false,
                    isAnalyzed: cached.isAnalyzed,
                    subfolderPath: cached.subfolderPath,
                    fileSize: cached.fileSize,
                    fileModificationDate: cached.fileModificationDate,
                    isVideoFile: cached.isVideoFile,
                    localFileURL: localURL,
                    remoteFileID: cached.remoteFileID,
                    remoteThumbnailLink: cached.remoteThumbnailLink
                ))
            }
        } else {
            let ids = cachedItems.map { $0.id }
            let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            var assetsById: [String: PHAsset] = [:]
            fetchResult.enumerateObjects { asset, _, _ in
                assetsById[asset.localIdentifier] = asset
            }
            for cached in cachedItems {
                guard let asset = assetsById[cached.id] else { continue }
                restored.append(Self.makePhotoItem(from: cached, asset: asset))
            }
        }

        guard !restored.isEmpty else {
            self.allPhotos = []
            self.applyFilter()
            self.updateFilterCounts()
            return
        }

        self.allPhotos = restored

        var counts: [PhotoFilter: Int] = [:]
        for filter in PhotoFilter.allCases {
            counts[filter] = cachedCounts[filter.rawValue] ?? 0
        }
        self.filterCounts = counts
        self.sortPhotos()
    }

    // Dependencies
    let libraryService = PhotoLibraryService.shared
    let exifService = ExifMetadataService.shared
    let exportService = ExportService.shared
    let googleDriveService = GoogleDriveService.shared
    let googlePhotosService = GooglePhotosService.shared
    let sambaService = SambaService.shared
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init() {
        let initialSource = Self.loadLastMediaSource()
        self.currentMediaSource = initialSource
        let initialSegments = initialSource.folderPathSegments
        self.displayedPathSegments = initialSegments
        self.activePathSegmentCount = initialSegments.count
        Self.ensureCacheLoaded(for: initialSource.sourceKey)
        self.authorizationStatus = libraryService.authorizationStatus
        setupObservers()
        restorePersistedListIfAvailable()
        restorePersistedExportErrorsIfAvailable()
        if initialSource.isFolder {
            triggerPathBarReveal(for: initialSegments.last?.id)
            resolveGoogleDrivePathSegmentsIfNeeded(for: initialSource)
        }
        if initialSource.isFolder || authorizationStatus == .authorized || authorizationStatus == .limited {
            loadPhotos()
        }
    }

    deinit {
        loadingTask?.cancel()
        analysisTask?.cancel()
        pathHierarchyTask?.cancel()
    }

    private func setupObservers() {
        libraryService.$authorizationStatus
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                self?.authorizationStatus = status
                guard let self = self, !self.currentMediaSource.isFolder else { return }
                if status == .authorized || status == .limited {
                    self.loadPhotos()
                }
            }
            .store(in: &cancellables)

        libraryService.libraryChangePublisher
            .debounce(for: .seconds(2), scheduler: RunLoop.main)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self = self, !self.currentMediaSource.isFolder else { return }
                self.loadPhotos()
            }
            .store(in: &cancellables)
    }

    // MARK: - Actions

    func switchMediaSource(to newSource: MediaSource) {
        isShowingMediaSourceSheet = false
        guard newSource != currentMediaSource else { return }

        let segments = newSource.folderPathSegments
        displayedPathSegments = segments
        activePathSegmentCount = segments.count
        triggerPathBarReveal(for: segments.last?.id)

        applySourceTransition(to: newSource)
    }

    func navigateToPathSegment(at index: Int) {
        guard index >= 0 && index < displayedPathSegments.count else { return }
        let segment = displayedPathSegments[index]
        guard !segment.id.hasPrefix("placeholder_") else { return }

        let targetActiveCount = index + 1
        guard targetActiveCount != activePathSegmentCount || segment.targetSource != currentMediaSource else {
            return
        }

        // Preserve trailing segments dimmed without altering the path bar scroll offset.
        activePathSegmentCount = targetActiveCount
        applySourceTransition(to: segment.targetSource)
    }

    func openSubfolder(_ folder: FolderListEntry) {
        let nextSegment = folder.targetSource.folderPathSegments.last ?? FolderPathSegment(
            id: folder.id,
            name: folder.name,
            targetSource: folder.targetSource
        )
        let activePrefix = Array(displayedPathSegments.prefix(activePathSegmentCount))
        displayedPathSegments = activePrefix + [nextSegment]
        activePathSegmentCount = displayedPathSegments.count
        triggerPathBarReveal(for: nextSegment.id)
        applySourceTransition(to: folder.targetSource)
    }

    private func applySourceTransition(to newSource: MediaSource) {
        loadingTask?.cancel()
        analysisTask?.cancel()
        pathHierarchyTask?.cancel()
        activeAnalysisQueue = nil
        activeAnalysisSessionID = nil
        isAnalyzing = false
        isLoading = false
        hasUserDismissedAnalysisSheetThisRun = false
        isShowingAnalysisSheet = false
        analysisProgress = AnalysisProgress()
        if !restoreExportErrorBannerIfNeeded() {
            progressStatus = ProgressStatus(isVisible: false)
        }

        childFolders = []
        selectedPhotoIDs.removeAll()
        isSelectionMode = false
        isRangeSelectionMode = false
        selectedFilter = .all
        selectedMediaType = .all
        deletedAssetIDs.removeAll()

        currentMediaSource = newSource
        Self.saveLastMediaSource(newSource)
        switch newSource {
        case .googleDrive(let account):
            GoogleDriveAuthService.shared.saveLastBrowsedFolder(for: account)
        case .samba(let destination):
            SambaService.shared.saveLastBrowsedFolder(for: destination)
        case .photoLibrary, .localFolder:
            break
        }
        Self.ensureCacheLoaded(for: newSource.sourceKey)
        restorePersistedListIfAvailable()
        loadPhotos()
        resolveGoogleDrivePathSegmentsIfNeeded(for: newSource)
    }

    private func triggerPathBarReveal(for segmentID: String?) {
        guard let segmentID, !segmentID.isEmpty else { return }
        nextPathRevealNonce += 1
        pathBarRevealRequest = PathBarRevealRequest(segmentID: segmentID, nonce: nextPathRevealNonce)
    }

    private func resolveGoogleDrivePathSegmentsIfNeeded(for source: MediaSource) {
        guard case .googleDrive(let account) = source else { return }
        let targetFolderId = account.targetFolderId
        guard account.folderBreadcrumbs.isEmpty && targetFolderId != "root" else { return }

        let expectedSourceKey = source.sourceKey
        pathHierarchyTask = Task { [weak self] in
            guard let breadcrumbs = await GoogleDriveService.shared.resolveFolderHierarchy(for: targetFolderId, accountID: account.id),
                  !breadcrumbs.isEmpty else {
                return
            }
            await MainActor.run {
                guard let self, self.currentMediaSource.sourceKey == expectedSourceKey else { return }
                var updatedAccount = account
                updatedAccount.folderBreadcrumbs = breadcrumbs
                updatedAccount.folderPath = breadcrumbs.map(\.name).joined(separator: "/")
                let updatedSource = MediaSource.googleDrive(account: updatedAccount)
                let resolvedActiveSegments = updatedSource.folderPathSegments

                let activeCount = self.activePathSegmentCount
                let dimmedTail = activeCount < self.displayedPathSegments.count
                    ? Array(self.displayedPathSegments.dropFirst(activeCount))
                    : []
                self.displayedPathSegments = resolvedActiveSegments + dimmedTail
                self.activePathSegmentCount = resolvedActiveSegments.count
                self.currentMediaSource = updatedSource
                Self.saveLastMediaSource(updatedSource)
                GoogleDriveAuthService.shared.saveLastBrowsedFolder(for: updatedAccount)
                self.triggerPathBarReveal(for: resolvedActiveSegments.last?.id)
            }
        }
    }

    func requestAccess() {
        Task {
            let status = await libraryService.requestAuthorization()
            if status == .authorized || status == .limited {
                loadPhotos()
            }
        }
    }

    /// Refresh photos if library has changed or app became active
    func refreshIfCacheExpired() {
        guard !isLoading else { return }
        loadPhotos()
    }

    // Export State & Persistence Tracking
    @Published var preparedExportItems: [PhotoItem] = []
    @Published var pendingExportRenameGroups: [FileRenameGroup] = []

    enum LastExportTarget {
        case local(URL, ExportConflictResolution)
        case googleDrive(folderId: String, folderName: String, accountID: String?, conflictResolution: ExportConflictResolution)
        case samba(SambaDestination, ExportConflictResolution)
        case googlePhotos(account: GoogleAccount)
    }
    var lastExportTarget: LastExportTarget? = nil
    var currentBatchItems: [PhotoItem] = []
    var totalBatchCount: Int = 0

    var hasPersistedExportErrors: Bool = false
    var lastPersistedProcessedCount: Int = -1

    static func makePhotoItem(from cached: CachedPhotoListItem, asset: PHAsset) -> PhotoItem {
        let tz: TimeZone = {
            if let id = cached.timeZoneIdentifier, let t = TimeZone(identifier: id) {
                return t
            }
            return TimeZone(secondsFromGMT: cached.timeZoneSecondsFromGMT) ?? .current
        }()
        return PhotoItem(
            asset: asset,
            filename: cached.filename,
            creationDate: cached.creationDate,
            embeddedDate: cached.embeddedDate,
            timeZone: tz,
            isDateAdjusted: cached.isDateAdjusted,
            isGPSAdjusted: cached.isGPSAdjusted,
            isSavedFromOtherApps: cached.isSavedFromOtherApps,
            duration: cached.duration,
            hasEmbeddedTimeZone: cached.hasEmbeddedTimeZone,
            isDrifted: cached.isDrifted ?? false,
            isAnalyzed: cached.isAnalyzed,
            subfolderPath: cached.subfolderPath,
            fileSize: cached.fileSize
        )
    }

    // MARK: - Filtering & Sorting

    func applyFilter() {
        let mediaScoped = allPhotos.filter { $0.matches(mediaType: selectedMediaType) }
        if selectedFilter == .all {
            filteredPhotos = mediaScoped
        } else {
            filteredPhotos = mediaScoped.filter { $0.matches(filter: selectedFilter) }
        }
    }

    func sortPhotos() {
        allPhotos.sort { item1, item2 in
            let date1 = item1.creationDate ?? Date.distantPast
            let date2 = item2.creationDate ?? Date.distantPast
            return isChronologicalAscending ? (date1 < date2) : (date1 > date2)
        }
        applyFilter()
    }

    func updateFilterCounts() {
        let mediaScoped = allPhotos.filter { $0.matches(mediaType: selectedMediaType) }

        var counts: [PhotoFilter: Int] = [
            .all: mediaScoped.count,
            .inferred: 0,
            .adjusted: 0,
            .drifted: 0,
            .edited: 0,
            .savedFromOtherApps: 0
        ]

        for item in mediaScoped {
            if item.hasInferredTimeZone { counts[.inferred, default: 0] += 1 }
            if item.isAdjusted { counts[.adjusted, default: 0] += 1 }
            if item.isDrifted { counts[.drifted, default: 0] += 1 }
            if item.isEdited { counts[.edited, default: 0] += 1 }
            if item.isSavedFromOtherApps { counts[.savedFromOtherApps, default: 0] += 1 }
        }

        self.filterCounts = counts

        if selectedFilter != .all && (counts[selectedFilter] ?? 0) == 0 {
            selectedFilter = .all
        }
    }


    // MARK: - Multi-Selection Logic

    func toggleSelection(for item: PhotoItem) {
        if isRangeSelectionMode, let lastID = lastSelectedID, lastID != item.id {
            selectRange(from: lastID, to: item.id)
            lastSelectedID = item.id
            return
        }

        if selectedPhotoIDs.contains(item.id) {
            selectedPhotoIDs.remove(item.id)
            if lastSelectedID == item.id {
                lastSelectedID = selectedPhotoIDs.first
            }
        } else {
            selectedPhotoIDs.insert(item.id)
            lastSelectedID = item.id
        }
    }

    /// Select all items between previously selected item and current item
    func selectRange(from startID: String, to targetID: String) {
        guard let startIndex = filteredPhotos.firstIndex(where: { $0.id == startID }),
              let targetIndex = filteredPhotos.firstIndex(where: { $0.id == targetID }) else {
            selectedPhotoIDs.insert(targetID)
            lastSelectedID = targetID
            return
        }

        let lower = min(startIndex, targetIndex)
        let upper = max(startIndex, targetIndex)

        for i in lower...upper {
            selectedPhotoIDs.insert(filteredPhotos[i].id)
        }
        lastSelectedID = targetID
    }

    func selectRangeToHere(item: PhotoItem) {
        if let lastID = lastSelectedID {
            selectRange(from: lastID, to: item.id)
        } else {
            selectedPhotoIDs.insert(item.id)
            lastSelectedID = item.id
        }
    }

    func selectAll() {
        let allIDs = filteredPhotos.map { $0.id }
        selectedPhotoIDs.formUnion(allIDs)
        lastSelectedID = filteredPhotos.last?.id
    }

    func deselectAll() {
        selectedPhotoIDs.removeAll()
        lastSelectedID = nil
        isRangeSelectionMode = false
    }

    func invertSelection() {
        let currentlySelected = selectedPhotoIDs
        let currentVisibleIDs = Set(filteredPhotos.map { $0.id })
        selectedPhotoIDs = currentVisibleIDs.subtracting(currentlySelected)
        lastSelectedID = selectedPhotoIDs.first
    }

    var selectedItems: [PhotoItem] {
        filteredPhotos.filter { selectedPhotoIDs.contains($0.id) }
    }

    func updatePhotoFilename(assetID: String, newFilename: String) {
        if let idx = allPhotos.firstIndex(where: { $0.id == assetID }) {
            allPhotos[idx] = allPhotos[idx].withFilename(newFilename)
        }
        if let idx = filteredPhotos.firstIndex(where: { $0.id == assetID }) {
            filteredPhotos[idx] = filteredPhotos[idx].withFilename(newFilename)
        }
        var existing = Self.analysisCache[assetID] ?? CachedMetadataEntry(
            modificationDate: nil,
            hasAdjustments: false,
            embeddedDate: nil,
            isDateAdjusted: false,
            isGPSAdjusted: false,
            isFromOtherApps: false,
            hasEmbeddedTimeZone: false,
            originalFilename: newFilename
        )
        existing.originalFilename = newFilename
        Self.analysisCache[assetID] = existing
        MetadataCacheService.shared.saveCache(Self.analysisCache, for: currentSourceKey)
        savePersistedListToDisk()
    }

    func updateFolderItem(oldID: String, updatedItem: PhotoItem) {
        if let idx = allPhotos.firstIndex(where: { $0.id == oldID }) {
            allPhotos[idx] = updatedItem
        }
        if let idx = filteredPhotos.firstIndex(where: { $0.id == oldID }) {
            filteredPhotos[idx] = updatedItem
        }
        if selectedPhotoIDs.remove(oldID) != nil {
            selectedPhotoIDs.insert(updatedItem.id)
        }
        if lastSelectedID == oldID {
            lastSelectedID = updatedItem.id
        }
        if oldID != updatedItem.id {
            if let existing = Self.analysisCache.removeValue(forKey: oldID) {
                var updatedCache = existing
                updatedCache.originalFilename = updatedItem.filename
                Self.analysisCache[updatedItem.id] = updatedCache
            }
        }
        if var entry = Self.analysisCache[updatedItem.id] {
            entry.originalFilename = updatedItem.filename
            entry.modificationDate = updatedItem.fileModificationDate ?? entry.modificationDate
            entry.fileSize = updatedItem.fileSize ?? entry.fileSize
            entry.pixelWidth = updatedItem.pixelWidth ?? entry.pixelWidth
            entry.pixelHeight = updatedItem.pixelHeight > 0 ? updatedItem.pixelHeight : entry.pixelHeight
            entry.duration = updatedItem.duration ?? entry.duration
            entry.isDateAdjusted = updatedItem.isDateAdjusted
            entry.isGPSAdjusted = updatedItem.isGPSAdjusted
            entry.pendingRotationDegrees = updatedItem.pendingRotationDegrees > 0 ? updatedItem.pendingRotationDegrees : nil
            entry.hasEmbeddedTimeZone = updatedItem.hasEmbeddedTimeZone
            entry.isDrifted = updatedItem.isDrifted
            entry.embeddedDate = updatedItem.embeddedDate
            entry.adjustedDate = updatedItem.isDateAdjusted ? updatedItem.creationDate : nil
            entry.timeZoneIdentifier = updatedItem.timeZone.identifier
            entry.timeZoneSecondsFromGMT = updatedItem.timeZone.secondsFromGMT()
            Self.analysisCache[updatedItem.id] = entry
        } else {
            Self.analysisCache[updatedItem.id] = CachedMetadataEntry(
                modificationDate: updatedItem.fileModificationDate,
                hasAdjustments: updatedItem.isAdjusted,
                embeddedDate: updatedItem.embeddedDate,
                adjustedDate: updatedItem.isDateAdjusted ? updatedItem.creationDate : nil,
                isDateAdjusted: updatedItem.isDateAdjusted,
                isGPSAdjusted: updatedItem.isGPSAdjusted,
                pendingRotationDegrees: updatedItem.pendingRotationDegrees > 0 ? updatedItem.pendingRotationDegrees : nil,
                isFromOtherApps: updatedItem.isSavedFromOtherApps,
                hasEmbeddedTimeZone: updatedItem.hasEmbeddedTimeZone,
                isDrifted: updatedItem.isDrifted,
                originalFilename: updatedItem.filename,
                fileSize: updatedItem.fileSize,
                timeZoneIdentifier: updatedItem.timeZone.identifier,
                timeZoneSecondsFromGMT: updatedItem.timeZone.secondsFromGMT(),
                pixelWidth: updatedItem.pixelWidth > 0 ? updatedItem.pixelWidth : nil,
                pixelHeight: updatedItem.pixelHeight > 0 ? updatedItem.pixelHeight : nil,
                duration: updatedItem.duration,
                latitude: updatedItem.location?.coordinate.latitude,
                longitude: updatedItem.location?.coordinate.longitude
            )
        }
        MetadataCacheService.shared.saveCache(Self.analysisCache, for: currentSourceKey)
        applyFilter()
        updateFilterCounts()
        savePersistedListToDisk()
        savePersistedListToDisk()
    }
}
