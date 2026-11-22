//
//  PhotoDetailViewModel.swift
//  Photo Exporter
//

import Foundation
import Photos
import UIKit
import MapKit
import Combine
import SwiftUI
import AVFoundation
import MediaPlayer

@MainActor
final class PhotoDetailViewModel: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    private(set) var assetID: String
    let mediaSource: MediaSource
    @Published var item: PhotoItem

    @Published var highResImage: UIImage? = nil
    @Published var avPlayer: AVPlayer? = nil {
        didSet {
            observePlayerMuteState(avPlayer)
        }
    }
    @Published var isMuted: Bool = true
    @Published var isVideo: Bool = false
    @Published var isPreparingVideoStream: Bool = false
    @Published var videoStreamError: String? = nil
    @Published var metadata: PhotoExifMetadata = .empty
    @Published var isLoadingMedia: Bool = true
    @Published var isLoadingMetadata: Bool = true
    @Published var geocodedAddress: String? = nil
    @Published var mapRegion: MKCoordinateRegion? = nil

    var requiresOnDemandStream: Bool {
        isVideo && mediaSource.isRemote
    }

    private var activeStreamHandle: RemoteVideoStreamHandle? = nil
    private var playerMuteObservation: NSKeyValueObservation? = nil

    // MARK: - Media Version State (Original vs Edited)
    enum MediaVersion: String, CaseIterable, Identifiable {
        case edited = "Edited"
        case original = "Original"

        var id: String { rawValue }
    }

    @Published var selectedVersion: MediaVersion = .edited
    private var editedImage: UIImage? = nil
    private var originalImage: UIImage? = nil
    private var editedAVAsset: AVAsset? = nil
    private var originalAVAsset: AVAsset? = nil
    private var editedMetadata: PhotoExifMetadata? = nil
    private var originalMetadata: PhotoExifMetadata? = nil

    var isEditedMedia: Bool {
        metadata.isEdited || item.isEdited
    }

    @Published var isShowingAdjustDateSheet: Bool = false
    @Published var isShowingDeleteConfirmation: Bool = false
    @Published var renameError: String? = nil
    @Published var shouldDismiss: Bool = false
    @Published var isRotating: Bool = false

    private var pendingRemoteVideoReloadAfterApply: Bool = false

    private var queuedPhotoKitStepsByAssetID: [String: Int] = [:]
    private var visualVideoPreviewSteps: Int = 0
    private var photoKitRotateDebounceTask: Task<Void, Never>? = nil
    private var isCommittingPhotoKitRotation: Bool = false
    private var activeRotationAssetsByID: [String: PHAsset] = [:]

    var onDateAdjusted: ((String, Date, TimeZone, Bool) -> Void)? = nil
    var onMetadataRefreshed: ((String, PhotoExifMetadata) -> Void)? = nil
    var onFilenameChanged: ((String, String) -> Void)? = nil
    var onFolderItemUpdated: ((String, PhotoItem) -> Void)? = nil
    var onDeleted: ((String) -> Void)? = nil

    func updateFilename(_ newFilename: String) {
        var trimmed = newFilename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let origExt = (item.filename as NSString).pathExtension
        if !origExt.isEmpty && (trimmed as NSString).pathExtension.isEmpty {
            trimmed = "\(trimmed).\(origExt)"
        }
        guard trimmed != item.filename else { return }

        if mediaSource.isFolder {
            let oldID = item.id
            let currentItem = item
            Task { @MainActor in
                do {
                    let renamedItem = try await FolderMediaService.shared.renameItem(currentItem, to: trimmed, in: mediaSource)
                    self.item = renamedItem
                    self.assetID = renamedItem.id
                    self.metadata.filename = renamedItem.filename
                    self.metadata.originalFilename = renamedItem.filename
                    self.editedMetadata?.filename = renamedItem.filename
                    self.editedMetadata?.originalFilename = renamedItem.filename
                    self.originalMetadata?.filename = renamedItem.filename
                    self.originalMetadata?.originalFilename = renamedItem.filename
                    self.onFolderItemUpdated?(oldID, renamedItem)
                    self.onFilenameChanged?(renamedItem.id, renamedItem.filename)
                    self.onMetadataRefreshed?(renamedItem.id, self.metadata)
                } catch {
                    self.renameError = error.localizedDescription
                }
            }
            return
        }

        self.item = item.withFilename(trimmed)
        self.metadata.filename = trimmed
        self.metadata.originalFilename = trimmed
        self.editedMetadata?.filename = trimmed
        self.editedMetadata?.originalFilename = trimmed
        self.originalMetadata?.filename = trimmed
        self.originalMetadata?.originalFilename = trimmed
        onFilenameChanged?(item.id, trimmed)
        onMetadataRefreshed?(item.id, self.metadata)
    }

    // Cache of high-res or preview images for smooth swiping transitions
    var imageCache: [String: UIImage] = [:]

    func cachedImage(for id: String) -> UIImage? {
        return imageCache[id]
    }

    func saveImageToCache(_ image: UIImage, for id: String) {
        imageCache[id] = image
    }

    func preloadAdjacentItems(currentIndex: Int, items: [PhotoItem]) {
        guard !mediaSource.isFolder else { return }
        let indicesToPreload = [currentIndex - 1, currentIndex + 1, currentIndex - 2, currentIndex + 2].filter { $0 >= 0 && $0 < items.count }
        for idx in indicesToPreload {
            let adjItem = items[idx]
            guard imageCache[adjItem.id] == nil, let asset = adjItem.asset else { continue }
            Task {
                let targetSize = adjItem.isVideo ? CGSize(width: 800, height: 800) : PHImageManagerMaximumSize
                let options = PHImageRequestOptions()
                options.deliveryMode = adjItem.isVideo ? .fastFormat : .highQualityFormat
                options.resizeMode = .fast
                options.isNetworkAccessAllowed = true
                self.libraryService.imageManager.requestImage(
                    for: asset,
                    targetSize: targetSize,
                    contentMode: .aspectFit,
                    options: options
                ) { img, _ in
                    if let img = img {
                        Task { @MainActor in
                            self.imageCache[adjItem.id] = img
                        }
                    }
                }
            }
        }
    }

    /// Switch the active photo displayed in detail view to a new item
    func setItem(_ newItem: PhotoItem) {
        flushPendingPhotoKitRotation()

        // Preserve current image in cache before switching so outgoing view stays fully rendered
        if let current = self.highResImage {
            self.imageCache[self.item.id] = current
        }

        stopVideoAndRelinquishAudio()

        selectedVersion = .edited
        visualVideoPreviewSteps = 0
        editedImage = nil
        originalImage = nil
        editedAVAsset = nil
        originalAVAsset = nil
        editedMetadata = nil
        originalMetadata = nil

        if let cached = imageCache[newItem.id] {
            self.highResImage = cached
            self.editedImage = cached
            self.isLoadingMedia = false
        } else {
            // Fast synchronous thumbnail/preview fallback to prevent any black gap during slide transition
            if !newItem.isVideo, let phAsset = newItem.asset {
                let fastOptions = PHImageRequestOptions()
                fastOptions.isSynchronous = true
                fastOptions.deliveryMode = .fastFormat
                fastOptions.resizeMode = .fast
                fastOptions.isNetworkAccessAllowed = false
                var fastImg: UIImage? = nil
                libraryService.imageManager.requestImage(
                    for: phAsset,
                    targetSize: CGSize(width: 800, height: 800),
                    contentMode: .aspectFit,
                    options: fastOptions
                ) { img, _ in
                    fastImg = img
                }
                if let fast = fastImg {
                    self.highResImage = fast
                    self.editedImage = fast
                    self.imageCache[newItem.id] = fast
                    self.isLoadingMedia = false
                } else {
                    self.highResImage = nil
                    self.isLoadingMedia = true
                }
            } else {
                self.highResImage = nil
                self.isLoadingMedia = true
            }
        }

        self.isLoadingMetadata = true
        self.geocodedAddress = nil

        self.item = newItem
        self.assetID = newItem.id
        self.isVideo = newItem.isVideo

        // Pre-populate synchronous asset data (like location) to eliminate UI flash and map flickering
        let asset: PHAsset? = mediaSource.isFolder ? nil : PHAsset.fetchAssets(withLocalIdentifiers: [newItem.id], options: nil).firstObject

        let resolvedOrig = asset.map { libraryService.resolveFilename(for: $0) }
        let resolvedCameraRoll = asset.flatMap { libraryService.resolveCameraRollFilename(for: $0) }
        let effectiveOriginalFilename: String
        if let orig = resolvedOrig, !orig.isEmpty {
            effectiveOriginalFilename = orig
        } else {
            effectiveOriginalFilename = newItem.filename
        }

        self.item = newItem.withFilename(effectiveOriginalFilename)
        self.isVideo = newItem.isVideo

        var initialMetadata = PhotoExifMetadata.empty
        initialMetadata.filename = effectiveOriginalFilename
        initialMetadata.originalFilename = effectiveOriginalFilename
        initialMetadata.cameraRollFilename = resolvedCameraRoll
        initialMetadata.creationDate = asset?.creationDate ?? newItem.creationDate
        initialMetadata.location = asset?.location
        initialMetadata.originalLocation = asset?.location
        initialMetadata.timeZone = newItem.timeZone
        initialMetadata.hasEmbeddedTimeZone = newItem.hasEmbeddedTimeZone
        initialMetadata.isDateAdjusted = newItem.isDateAdjusted
        initialMetadata.isGPSAdjusted = newItem.isGPSAdjusted
        initialMetadata.pendingRotationDegrees = newItem.pendingRotationDegrees
        initialMetadata.embeddedDate = newItem.embeddedDate
        if let date = initialMetadata.creationDate {
            initialMetadata.offsetTimeString = DateFormatters.exifTimezoneOffset(for: date, in: newItem.timeZone)
        }
        if let loc = asset?.location {
            self.mapRegion = MKCoordinateRegion(
                center: loc.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.015, longitudeDelta: 0.015)
            )
        } else {
            self.mapRegion = nil
        }
        if let asset = asset {
            initialMetadata.pixelWidth = asset.pixelWidth
            initialMetadata.pixelHeight = asset.pixelHeight
            initialMetadata.isEdited = asset.hasAdjustments
        } else {
            initialMetadata.isEdited = newItem.isEdited
        }
        self.metadata = initialMetadata

        loadData()
        if requiresOnDemandStream {
            startStreamingRemoteVideo()
        } else {
            playVideo()
        }
    }

    private let libraryService = PhotoLibraryService.shared
    private let exifService = ExifMetadataService.shared
    private let geocodingService = GeocodingService.shared
    private let exportService = ExportService.shared
    private let googleDriveService = GoogleDriveService.shared
    private let googlePhotosService = GooglePhotosService.shared
    private let sambaService = SambaService.shared

    init(item: PhotoItem, mediaSource: MediaSource = .photoLibrary) {
        self.assetID = item.id
        self.mediaSource = mediaSource
        self.isVideo = item.isVideo

        let asset: PHAsset? = mediaSource.isFolder ? nil : PHAsset.fetchAssets(withLocalIdentifiers: [item.id], options: nil).firstObject

        let resolvedOrig = asset.map { PhotoLibraryService.shared.resolveFilename(for: $0) }
        let resolvedCameraRoll = asset.flatMap { PhotoLibraryService.shared.resolveCameraRollFilename(for: $0) }
        let effectiveOriginalFilename: String
        if let orig = resolvedOrig, !orig.isEmpty {
            effectiveOriginalFilename = orig
        } else {
            effectiveOriginalFilename = item.filename
        }

        self.item = mediaSource.isFolder ? item : item.withFilename(effectiveOriginalFilename)

        var initialMetadata = PhotoExifMetadata.empty
        initialMetadata.filename = effectiveOriginalFilename
        initialMetadata.originalFilename = effectiveOriginalFilename
        initialMetadata.cameraRollFilename = resolvedCameraRoll
        initialMetadata.creationDate = asset?.creationDate ?? item.creationDate
        initialMetadata.location = asset?.location
        initialMetadata.originalLocation = asset?.location
        initialMetadata.timeZone = item.timeZone
        initialMetadata.hasEmbeddedTimeZone = item.hasEmbeddedTimeZone
        initialMetadata.isDateAdjusted = item.isDateAdjusted
        initialMetadata.isGPSAdjusted = item.isGPSAdjusted
        initialMetadata.pendingRotationDegrees = item.pendingRotationDegrees
        initialMetadata.embeddedDate = item.embeddedDate
        if let date = initialMetadata.creationDate {
            initialMetadata.offsetTimeString = DateFormatters.exifTimezoneOffset(for: date, in: item.timeZone)
        }
        if let loc = asset?.location {
            self.mapRegion = MKCoordinateRegion(
                center: loc.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.015, longitudeDelta: 0.015)
            )
        } else {
            self.mapRegion = nil
        }
        if let asset = asset {
            initialMetadata.pixelWidth = asset.pixelWidth
            initialMetadata.pixelHeight = asset.pixelHeight
            initialMetadata.isEdited = asset.hasAdjustments
        } else {
            initialMetadata.isEdited = item.isEdited
        }
        self.metadata = initialMetadata

        super.init()
        if !mediaSource.isFolder {
            PHPhotoLibrary.shared().register(self)
        }
    }

    deinit {
        activeStreamHandle?.close()
        if !mediaSource.isFolder {
            PHPhotoLibrary.shared().unregisterChangeObserver(self)
        }
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in
            guard let self = self, !self.mediaSource.isFolder else { return }
            let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [self.assetID], options: nil)
            if let changeDetails = changeInstance.changeDetails(for: fetchResult) {
                if changeDetails.fetchResultAfterChanges.firstObject == nil {
                    self.handleAssetDeleted()
                }
            } else if fetchResult.firstObject == nil {
                self.handleAssetDeleted()
            }
        }
    }

    func loadData() {
        if mediaSource.isFolder {
            loadFolderData()
            return
        }
        // Verify if the asset still exists in the photo library
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [item.id], options: nil)
        guard let currentAsset = fetchResult.firstObject else {
            print("Asset \(item.id) was deleted externally before loading data.")
            handleAssetDeleted()
            return
        }

        loadMedia(asset: currentAsset)
        loadMetadata(asset: currentAsset)
    }

    private func loadFolderData() {
        let targetItem = item
        let targetID = item.id
        let source = mediaSource
        isLoadingMedia = true
        isLoadingMetadata = true

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                let result = try await FolderMediaService.shared.loadDetailMediaAndMetadata(for: targetItem, in: source)
                guard self.assetID == targetID else { return }

                let pendingSteps = ExifMetadataService.clockwiseSteps(forDegrees: self.item.pendingRotationDegrees)

                if let image = result.image {
                    let effectiveImage = pendingSteps != 0
                        ? ExifMetadataService.rotateUIImage(image, clockwiseSteps: pendingSteps)
                        : image
                    self.highResImage = effectiveImage
                    self.editedImage = effectiveImage
                    self.imageCache[targetID] = effectiveImage
                } else if targetItem.isVideo {
                    if let cachedThumb = self.imageCache[targetID]
                        ?? FolderMediaService.shared.cachedThumbnail(for: targetItem, in: source).map({
                            pendingSteps != 0 ? ExifMetadataService.rotateUIImage($0, clockwiseSteps: pendingSteps) : $0
                        }) {
                        self.highResImage = cachedThumb
                        self.imageCache[targetID] = cachedThumb
                    } else if let fetchedThumb = await FolderMediaService.shared.loadThumbnail(for: targetItem, in: source, maxPixelSize: 800) {
                        guard self.assetID == targetID else { return }
                        let latestSteps = ExifMetadataService.clockwiseSteps(forDegrees: self.item.pendingRotationDegrees)
                        let rotatedThumb = latestSteps != 0
                            ? ExifMetadataService.rotateUIImage(fetchedThumb, clockwiseSteps: latestSteps)
                            : fetchedThumb
                        self.highResImage = rotatedThumb
                        self.imageCache[targetID] = rotatedThumb
                    }
                }
                if let videoURL = result.localVideoURL {
                    self.configureAudioSessionForPlayback()
                    let avAsset = AVURLAsset(url: videoURL)
                    self.editedAVAsset = avAsset
                    let playerItem = AVPlayerItem(asset: avAsset)
                    if pendingSteps != 0 {
                        playerItem.videoComposition = await self.exifService.makeRotatedVideoComposition(for: avAsset, clockwiseSteps: pendingSteps)
                        guard self.assetID == targetID else { return }
                    }
                    let player = AVPlayer(playerItem: playerItem)
                    player.isMuted = self.isMuted
                    self.avPlayer = player
                    player.play()
                }
                self.isLoadingMedia = false

                var loadedMeta = result.metadata
                // Preserve any cached / adjusted date, timezone, & pending rotation from the item
                loadedMeta.creationDate = targetItem.creationDate ?? loadedMeta.creationDate
                loadedMeta.timeZone = targetItem.timeZone
                loadedMeta.isDateAdjusted = targetItem.isDateAdjusted
                loadedMeta.pendingRotationDegrees = self.item.pendingRotationDegrees
                if pendingSteps % 2 == 1 {
                    let rawW = loadedMeta.pixelWidth
                    loadedMeta.pixelWidth = loadedMeta.pixelHeight
                    loadedMeta.pixelHeight = rawW
                }
                loadedMeta.hasEmbeddedTimeZone = targetItem.hasEmbeddedTimeZone
                loadedMeta.isDrifted = targetItem.isDrifted
                if let date = loadedMeta.creationDate {
                    loadedMeta.offsetTimeString = DateFormatters.exifTimezoneOffset(for: date, in: targetItem.timeZone)
                }
                self.metadata = loadedMeta
                self.editedMetadata = loadedMeta
                self.isLoadingMetadata = false

                if let loc = loadedMeta.location {
                    self.mapRegion = MKCoordinateRegion(
                        center: loc.coordinate,
                        span: MKCoordinateSpan(latitudeDelta: 0.015, longitudeDelta: 0.015)
                    )
                    let address = await self.geocodingService.reverseGeocode(location: loc)
                    if self.assetID == targetID {
                        self.geocodedAddress = address
                    }
                } else {
                    self.mapRegion = nil
                    self.geocodedAddress = nil
                }

                self.onMetadataRefreshed?(targetID, loadedMeta)
            } catch {
                guard self.assetID == targetID else { return }
                self.isLoadingMedia = false
                self.isLoadingMetadata = false
            }
        }
    }

    func handleAssetDeleted() {
        guard !shouldDismiss else { return }
        print("Asset \(item.id) was deleted externally. Dismissing detail view back to list.")
        PhotoListViewModel.pruneCacheEntry(for: item.id)
        onDeleted?(item.id)
        shouldDismiss = true
    }

    private func loadMedia(asset: PHAsset) {
        Task {
            isLoadingMedia = true
            if item.isVideo {
                do {
                    self.configureAudioSessionForPlayback()
                    let avAsset = try await libraryService.fetchAVAsset(for: asset, version: .current)
                    self.editedAVAsset = avAsset
                    let playerItem = AVPlayerItem(asset: avAsset)
                    let player = AVPlayer(playerItem: playerItem)
                    player.isMuted = self.isMuted
                    self.avPlayer = player
                    player.play()

                    // Preload original video if asset has adjustments
                    if asset.hasAdjustments {
                        Task {
                            let origAV = try? await self.libraryService.fetchAVAsset(for: asset, version: .original)
                            if self.assetID == asset.localIdentifier {
                                self.originalAVAsset = origAV
                            }
                        }
                    }
                } catch {
                    print("Error loading video player: \(error.localizedDescription)")
                    let check = PHAsset.fetchAssets(withLocalIdentifiers: [item.id], options: nil)
                    if check.firstObject == nil {
                        handleAssetDeleted()
                        return
                    }
                }
            } else {
                let image = await libraryService.requestHighResImage(for: asset, version: .current)
                if image == nil {
                    let check = PHAsset.fetchAssets(withLocalIdentifiers: [item.id], options: nil)
                    if check.firstObject == nil {
                        handleAssetDeleted()
                        return
                    }
                }
                self.editedImage = image
                self.highResImage = image
                if let img = image {
                    self.imageCache[asset.localIdentifier] = img
                }

                // Preload original image if asset has adjustments
                if asset.hasAdjustments {
                    Task {
                        let orig = await self.libraryService.requestHighResImage(for: asset, version: .unadjusted)
                        if self.assetID == asset.localIdentifier {
                            self.originalImage = orig
                        }
                    }
                }
            }
            self.isLoadingMedia = false
        }
    }

    private func loadMetadata(asset: PHAsset) {
        Task {
            isLoadingMetadata = true

            do {
                let latestAsset = PHAsset.fetchAssets(withLocalIdentifiers: [item.id], options: nil).firstObject ?? asset
                var parsed: PhotoExifMetadata

                if item.isVideo {
                    let fileURL = try await libraryService.fetchLocalFileURL(for: latestAsset, preferOriginal: true)
                    defer {
                        try? FileManager.default.removeItem(at: fileURL)
                    }
                    let editedMetrics = latestAsset.hasAdjustments
                        ? await libraryService.fetchEditedVideoMetrics(for: latestAsset, allowNetworkAccess: true)
                        : nil
                    parsed = await exifService.parseVideoMetadata(
                        from: fileURL,
                        asset: latestAsset,
                        filename: item.filename,
                        editedMetrics: editedMetrics
                    )
                } else {
                    let (data, _, _) = try await libraryService.fetchImageData(
                        for: latestAsset,
                        preferEdited: true
                    )

                    parsed = exifService.parseMetadata(
                        from: data,
                        asset: latestAsset,
                        filename: item.filename
                    )

                    if item.isEdited && parsed.rawDateAndGPSFields.isEmpty {
                        if let (origData, _, _) = try? await libraryService.fetchImageData(
                            for: latestAsset,
                            preferEdited: false
                        ) {
                            parsed.rawDateAndGPSFields = exifService.extractImageRawDateAndGPSFields(from: origData)
                        }
                    }
                }

                // Preserve original location for revert if not already set
                if parsed.originalLocation == nil {
                    parsed.originalLocation = latestAsset.location
                }

                // Preserve true original filename and camera roll filename from library service for Media Information display
                let resolvedOrig = libraryService.resolveFilename(for: latestAsset)
                let effectiveName = (!resolvedOrig.isEmpty ? resolvedOrig : self.item.filename)
                parsed.originalFilename = effectiveName
                parsed.filename = effectiveName
                parsed.cameraRollFilename = libraryService.resolveCameraRollFilename(for: latestAsset)
                self.item = self.item.withFilename(effectiveName)

                if latestAsset.hasAdjustments {
                    parsed.appliedEdits = await exifService.extractAppliedEdits(for: latestAsset)
                }

                self.editedMetadata = parsed
                if self.selectedVersion == .edited {
                    self.metadata = parsed
                }
                self.onMetadataRefreshed?(self.item.id, parsed)

                if latestAsset.hasAdjustments {
                    Task {
                        await self.loadOriginalMetadata(asset: latestAsset)
                    }
                }

                // Setup Map Region & Geocoding if GPS location is present
                if let location = parsed.location {
                    self.mapRegion = MKCoordinateRegion(
                        center: location.coordinate,
                        span: MKCoordinateSpan(latitudeDelta: 0.015, longitudeDelta: 0.015)
                    )

                    let address = await geocodingService.reverseGeocode(location: location)
                    self.geocodedAddress = address
                }
            } catch {
                print("Error loading metadata: \(error.localizedDescription)")
                let check = PHAsset.fetchAssets(withLocalIdentifiers: [item.id], options: nil)
                if check.firstObject == nil {
                    handleAssetDeleted()
                    return
                }
            }

            self.isLoadingMetadata = false
        }
    }

    private func loadOriginalMetadata(asset: PHAsset) async {
        do {
            var parsed: PhotoExifMetadata
            if item.isVideo {
                let fileURL = try await libraryService.fetchLocalFileURL(for: asset, preferOriginal: true)
                defer {
                    try? FileManager.default.removeItem(at: fileURL)
                }
                parsed = await exifService.parseVideoMetadata(
                    from: fileURL,
                    asset: asset,
                    filename: item.filename
                )
            } else {
                let (data, _, _) = try await libraryService.fetchImageData(
                    for: asset,
                    preferEdited: false
                )
                parsed = exifService.parseMetadata(
                    from: data,
                    asset: asset,
                    filename: item.filename
                )
                if parsed.rawDateAndGPSFields.isEmpty {
                    parsed.rawDateAndGPSFields = exifService.extractImageRawDateAndGPSFields(from: data)
                }
            }

            let resolvedOrig = libraryService.resolveFilename(for: asset)
            let effectiveName = (!resolvedOrig.isEmpty ? resolvedOrig : self.metadata.filename)
            parsed.isEdited = false
            parsed.appliedEdits = []
            parsed.filename = effectiveName
            parsed.originalFilename = effectiveName
            parsed.cameraRollFilename = libraryService.resolveCameraRollFilename(for: asset)
            if parsed.originalLocation == nil {
                parsed.originalLocation = asset.location
            }
            if self.metadata.isDateAdjusted, let date = self.metadata.creationDate {
                parsed.creationDate = date
                parsed.timeZone = self.metadata.timeZone
                parsed.offsetTimeString = self.metadata.offsetTimeString
                parsed.isDateAdjusted = true
            }

            self.originalMetadata = parsed
            if self.selectedVersion == .original {
                self.metadata = parsed
            }
        } catch {
            print("Failed to load original metadata: \(error.localizedDescription)")
        }
    }

    func switchVersion(_ newVersion: MediaVersion) {
        guard selectedVersion != newVersion else { return }
        selectedVersion = newVersion
        Task {
            await applySelectedVersion(newVersion)
        }
    }

    private func applySelectedVersion(_ version: MediaVersion) async {
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [item.id], options: nil)
        guard let asset = fetchResult.firstObject else { return }

        if isVideo {
            if version == .original {
                if let cached = originalAVAsset {
                    let playerItem = AVPlayerItem(asset: cached)
                    if let player = self.avPlayer {
                        player.replaceCurrentItem(with: playerItem)
                        player.play()
                    } else {
                        let player = AVPlayer(playerItem: playerItem)
                        player.isMuted = self.isMuted
                        self.avPlayer = player
                        player.play()
                    }
                } else {
                    isLoadingMedia = true
                    if let av = try? await libraryService.fetchAVAsset(for: asset, version: .original) {
                        self.originalAVAsset = av
                        if self.selectedVersion == .original {
                            let playerItem = AVPlayerItem(asset: av)
                            if let player = self.avPlayer {
                                player.replaceCurrentItem(with: playerItem)
                                player.play()
                            } else {
                                let player = AVPlayer(playerItem: playerItem)
                                player.isMuted = self.isMuted
                                self.avPlayer = player
                                player.play()
                            }
                        }
                    }
                    isLoadingMedia = false
                }
            } else {
                if let cached = editedAVAsset {
                    let playerItem = AVPlayerItem(asset: cached)
                    if let player = self.avPlayer {
                        player.replaceCurrentItem(with: playerItem)
                        player.play()
                    } else {
                        let player = AVPlayer(playerItem: playerItem)
                        player.isMuted = self.isMuted
                        self.avPlayer = player
                        player.play()
                    }
                } else {
                    isLoadingMedia = true
                    if let av = try? await libraryService.fetchAVAsset(for: asset, version: .current) {
                        self.editedAVAsset = av
                        if self.selectedVersion == .edited {
                            let playerItem = AVPlayerItem(asset: av)
                            if let player = self.avPlayer {
                                player.replaceCurrentItem(with: playerItem)
                                player.play()
                            } else {
                                let player = AVPlayer(playerItem: playerItem)
                                player.isMuted = self.isMuted
                                self.avPlayer = player
                                player.play()
                            }
                        }
                    }
                    isLoadingMedia = false
                }
            }
        } else {
            if version == .original {
                if let cached = originalImage {
                    self.highResImage = cached
                } else {
                    isLoadingMedia = true
                    let img = await libraryService.requestHighResImage(for: asset, version: .unadjusted)
                    self.originalImage = img
                    if self.selectedVersion == .original {
                        self.highResImage = img
                    }
                    isLoadingMedia = false
                }
            } else {
                if let cached = editedImage {
                    self.highResImage = cached
                } else {
                    isLoadingMedia = true
                    let img = await libraryService.requestHighResImage(for: asset, version: .current)
                    self.editedImage = img
                    if self.selectedVersion == .edited {
                        self.highResImage = img
                    }
                    isLoadingMedia = false
                }
            }
        }

        // Update metadata
        if version == .original {
            if let orig = originalMetadata {
                self.metadata = orig
            } else {
                await loadOriginalMetadata(asset: asset)
            }
        } else {
            if let edited = editedMetadata {
                self.metadata = edited
            }
        }
    }

    /// Adjust the creation date, time, and timezone of this asset in the iOS Photos library (or in-memory/cache for folder mode)
    func adjustDateTime(newDate: Date, newTimeZone: TimeZone) async {
        do {
            if !mediaSource.isFolder, let asset = item.asset {
                // Update creation date and timezone in PhotoKit so Apple Photos saves and displays the adjusted timezone
                try await libraryService.updateAssetDateTime(asset: asset, newDate: newDate, timeZone: newTimeZone)
            }

            await MainActor.run {
                self.metadata.creationDate = newDate
                self.metadata.timeZone = newTimeZone
                self.metadata.offsetTimeString = DateFormatters.exifTimezoneOffset(for: newDate, in: newTimeZone)

                let isAdjusted: Bool
                if let embedded = self.metadata.embeddedDate {
                    let fmt = DateFormatter()
                    fmt.dateFormat = "yyyy:MM:dd HH:mm:ss"
                    fmt.timeZone = newTimeZone
                    fmt.locale = Locale(identifier: "en_US_POSIX")
                    let newStr = fmt.string(from: newDate)

                    fmt.timeZone = self.metadata.originalTimeZone ?? newTimeZone
                    let origStr = fmt.string(from: embedded)

                    let tzDiffers = newTimeZone.secondsFromGMT(for: newDate) != (self.metadata.originalTimeZone?.secondsFromGMT(for: newDate) ?? newTimeZone.secondsFromGMT(for: newDate))
                    isAdjusted = newStr != origStr || tzDiffers
                } else {
                    isAdjusted = true
                }
                self.metadata.isDateAdjusted = isAdjusted
                self.editedMetadata?.creationDate = newDate
                self.editedMetadata?.timeZone = newTimeZone
                self.editedMetadata?.offsetTimeString = self.metadata.offsetTimeString
                self.editedMetadata?.isDateAdjusted = isAdjusted
                self.originalMetadata?.creationDate = newDate
                self.originalMetadata?.timeZone = newTimeZone
                self.originalMetadata?.offsetTimeString = self.metadata.offsetTimeString
                self.originalMetadata?.isDateAdjusted = isAdjusted

                if self.mediaSource.isFolder {
                    self.item = PhotoItem(
                        id: self.item.id,
                        filename: self.item.filename,
                        creationDate: newDate,
                        embeddedDate: self.item.embeddedDate,
                        timeZone: newTimeZone,
                        isDateAdjusted: isAdjusted,
                        isGPSAdjusted: self.item.isGPSAdjusted,
                        pendingRotationDegrees: self.item.pendingRotationDegrees,
                        pixelWidth: self.item.pixelWidth,
                        pixelHeight: self.item.pixelHeight,
                        location: self.item.location,
                        duration: self.item.duration,
                        hasEmbeddedTimeZone: self.item.hasEmbeddedTimeZone,
                        isDrifted: self.item.isDrifted,
                        isAnalyzed: self.item.isAnalyzed,
                        subfolderPath: self.item.subfolderPath,
                        fileSize: self.item.fileSize,
                        fileModificationDate: self.item.fileModificationDate,
                        isVideoFile: self.item.isVideoFile,
                        localFileURL: self.item.localFileURL,
                        remoteFileID: self.item.remoteFileID,
                        remoteThumbnailLink: self.item.remoteThumbnailLink
                    )
                }

                self.onDateAdjusted?(self.item.id, newDate, newTimeZone, isAdjusted)
            }
        } catch {
            print("Failed to adjust photo date: \(error.localizedDescription)")
        }
    }

    /// Revert adjusted date and time back to the original embedded capture date or original asset date
    func revertDateTime() async {
        let revertDate = metadata.embeddedDate ?? item.fileModificationDate ?? item.creationDate ?? Date()
        let revertLocation = metadata.originalLocation
        let revertTimeZone = metadata.originalTimeZone ?? .current

        do {
            if !mediaSource.isFolder, let asset = item.asset {
                try await libraryService.revertAssetDateTime(
                    asset: asset,
                    originalDate: revertDate,
                    originalTimeZone: revertTimeZone,
                    originalLocation: revertLocation
                )
            }

            await MainActor.run {
                self.metadata.creationDate = revertDate
                self.metadata.timeZone = revertTimeZone
                self.metadata.offsetTimeString = DateFormatters.exifTimezoneOffset(for: revertDate, in: revertTimeZone)
                self.metadata.isDateAdjusted = false
                self.editedMetadata?.creationDate = revertDate
                self.editedMetadata?.timeZone = revertTimeZone
                self.editedMetadata?.offsetTimeString = self.metadata.offsetTimeString
                self.editedMetadata?.isDateAdjusted = false
                self.originalMetadata?.creationDate = revertDate
                self.originalMetadata?.timeZone = revertTimeZone
                self.originalMetadata?.offsetTimeString = self.metadata.offsetTimeString
                self.originalMetadata?.isDateAdjusted = false

                if self.mediaSource.isFolder {
                    self.item = PhotoItem(
                        id: self.item.id,
                        filename: self.item.filename,
                        creationDate: revertDate,
                        embeddedDate: self.item.embeddedDate,
                        timeZone: revertTimeZone,
                        isDateAdjusted: false,
                        isGPSAdjusted: self.item.isGPSAdjusted,
                        pendingRotationDegrees: self.item.pendingRotationDegrees,
                        pixelWidth: self.item.pixelWidth,
                        pixelHeight: self.item.pixelHeight,
                        location: self.item.location,
                        duration: self.item.duration,
                        hasEmbeddedTimeZone: self.item.hasEmbeddedTimeZone,
                        isDrifted: self.item.isDrifted,
                        isAnalyzed: self.item.isAnalyzed,
                        subfolderPath: self.item.subfolderPath,
                        fileSize: self.item.fileSize,
                        fileModificationDate: self.item.fileModificationDate,
                        isVideoFile: self.item.isVideoFile,
                        localFileURL: self.item.localFileURL,
                        remoteFileID: self.item.remoteFileID,
                        remoteThumbnailLink: self.item.remoteThumbnailLink
                    )
                }

                self.onDateAdjusted?(self.item.id, revertDate, revertTimeZone, false)
            }
        } catch {
            print("Failed to revert photo date: \(error.localizedDescription)")
        }
    }

    // MARK: - Rotate 90° Clockwise

    /// Rotates the displayed image or video 90° clockwise.
    /// - Photo Library: updates the preview immediately and commits non-destructively via PhotoKit (reverting at 0°).
    /// - Folder Media: saves the pending rotation in cache/model until the user taps Apply.
    func rotateClockwise90() {
        guard !isLoadingMedia else { return }

        if mediaSource.isFolder {
            let newDegrees = ExifMetadataService.normalizeRotationDegrees(item.pendingRotationDegrees + 90)
            let updatedItem = item.withPendingRotation(newDegrees, swapDimensions: true)
            self.item = updatedItem

            self.metadata.pendingRotationDegrees = newDegrees
            let prevWidth = self.metadata.pixelWidth
            let prevHeight = self.metadata.pixelHeight
            self.metadata.pixelWidth = prevHeight
            self.metadata.pixelHeight = prevWidth
            self.editedMetadata = self.metadata

            if let img = self.highResImage ?? self.imageCache[updatedItem.id] {
                let rotated = ExifMetadataService.rotateUIImage(img, clockwiseSteps: 1)
                self.highResImage = rotated
                if !isVideo {
                    self.editedImage = rotated
                }
                self.imageCache[updatedItem.id] = rotated
            }

            if isVideo, let avAsset = self.editedAVAsset ?? self.avPlayer?.currentItem?.asset {
                let targetID = updatedItem.id
                let steps = ExifMetadataService.clockwiseSteps(forDegrees: newDegrees)
                Task { @MainActor [weak self] in
                    guard let self, self.assetID == targetID else { return }
                    let comp = await self.exifService.makeRotatedVideoComposition(for: avAsset, clockwiseSteps: steps)
                    guard self.assetID == targetID, let currentItem = self.avPlayer?.currentItem else { return }
                    currentItem.videoComposition = comp
                    if let player = self.avPlayer, player.timeControlStatus != .playing {
                        let t = player.currentTime()
                        if t.isValid {
                            await player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
                        }
                    }
                }
            }

            self.onFolderItemUpdated?(updatedItem.id, updatedItem)
            self.onMetadataRefreshed?(updatedItem.id, self.metadata)
            return
        }

        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [item.id], options: nil).firstObject ?? item.asset else {
            return
        }

        // Always rotate the edited view rather than leaving the user looking at .original
        if selectedVersion != .edited {
            selectedVersion = .edited
            if isVideo, let editedAV = editedAVAsset {
                let playerItem = AVPlayerItem(asset: editedAV)
                avPlayer?.replaceCurrentItem(with: playerItem)
            } else if !isVideo, let editedImg = editedImage {
                self.highResImage = editedImg
            }
            if let editedMeta = editedMetadata {
                self.metadata = editedMeta
            }
        }

        // Immediate optimistic UI update so rapid taps feel instant
        if let img = self.highResImage ?? self.imageCache[item.id] {
            let rotated = ExifMetadataService.rotateUIImage(img, clockwiseSteps: 1)
            self.highResImage = rotated
            if !isVideo {
                self.editedImage = rotated
            }
            self.imageCache[item.id] = rotated
        }

        let prevWidth = self.metadata.pixelWidth
        let prevHeight = self.metadata.pixelHeight
        self.metadata.pixelWidth = prevHeight
        self.metadata.pixelHeight = prevWidth
        self.editedMetadata?.pixelWidth = prevHeight
        self.editedMetadata?.pixelHeight = prevWidth

        if isVideo {
            visualVideoPreviewSteps = (visualVideoPreviewSteps + 1) % 4
            if let avAsset = self.editedAVAsset ?? self.avPlayer?.currentItem?.asset {
                let targetID = item.id
                let previewSteps = visualVideoPreviewSteps
                Task { @MainActor [weak self] in
                    guard let self, self.assetID == targetID else { return }
                    let comp = await self.exifService.makeRotatedVideoComposition(for: avAsset, clockwiseSteps: previewSteps)
                    guard self.assetID == targetID, let currentItem = self.avPlayer?.currentItem else { return }
                    currentItem.videoComposition = comp
                    if let player = self.avPlayer, player.timeControlStatus != .playing {
                        let t = player.currentTime()
                        if t.isValid {
                            await player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
                        }
                    }
                }
            }
        }

        let targetID = item.id
        queuedPhotoKitStepsByAssetID[targetID, default: 0] += 1
        activeRotationAssetsByID[targetID] = asset

        photoKitRotateDebounceTask?.cancel()
        photoKitRotateDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard let self, !Task.isCancelled else { return }
            await self.commitQueuedPhotoKitRotation(for: targetID, asset: asset)
        }
    }

    func flushPendingPhotoKitRotation() {
        photoKitRotateDebounceTask?.cancel()
        photoKitRotateDebounceTask = nil
        let pendingPairs = queuedPhotoKitStepsByAssetID.compactMap { id, steps -> (String, PHAsset, Int)? in
            guard steps > 0, let asset = activeRotationAssetsByID[id] else { return nil }
            return (id, asset, steps)
        }
        guard !pendingPairs.isEmpty, !isCommittingPhotoKitRotation else { return }

        let libService = self.libraryService
        let exService = self.exifService
        let onRefreshed = self.onMetadataRefreshed
        let fallbackFilename = self.item.filename

        Task { @MainActor in
            for (targetID, asset, steps) in pendingPairs {
                if self.queuedPhotoKitStepsByAssetID[targetID] != nil {
                    await self.commitQueuedPhotoKitRotation(for: targetID, asset: asset)
                } else {
                    if let result = try? await libService.rotateAsset(asset: asset, deltaSteps: steps) {
                        let freshAsset = result.updatedAsset
                        let edits = freshAsset.hasAdjustments ? await exService.extractAppliedEdits(for: freshAsset) : []
                        var meta = PhotoExifMetadata.empty
                        meta.filename = fallbackFilename
                        meta.pixelWidth = freshAsset.pixelWidth
                        meta.pixelHeight = freshAsset.pixelHeight
                        meta.creationDate = freshAsset.creationDate
                        meta.isEdited = freshAsset.hasAdjustments
                        meta.appliedEdits = edits
                        onRefreshed?(targetID, meta)
                    }
                }
            }
        }
    }

    private func commitQueuedPhotoKitRotation(for targetID: String, asset: PHAsset) async {
        guard !isCommittingPhotoKitRotation else { return }
        guard (queuedPhotoKitStepsByAssetID[targetID] ?? 0) > 0 else { return }

        isCommittingPhotoKitRotation = true
        if self.assetID == targetID {
            isRotating = true
        }

        defer {
            isCommittingPhotoKitRotation = false
            if (queuedPhotoKitStepsByAssetID[targetID] ?? 0) == 0 {
                activeRotationAssetsByID.removeValue(forKey: targetID)
            }
            if self.assetID == targetID {
                isRotating = false
            }
        }

        do {
            var currentAsset = asset
            var lastResult: PhotoLibraryService.RotationCommitResult?
            while let steps = queuedPhotoKitStepsByAssetID[targetID], steps > 0 {
                queuedPhotoKitStepsByAssetID[targetID] = 0
                let result = try await libraryService.rotateAsset(asset: currentAsset, deltaSteps: steps)
                currentAsset = result.updatedAsset
                lastResult = result
            }
            guard let result = lastResult else { return }
            let freshAsset = result.updatedAsset

            // Refresh list item metadata
            let refreshedEdits = freshAsset.hasAdjustments
                ? await exifService.extractAppliedEdits(for: freshAsset)
                : []

            guard self.assetID == targetID else {
                // User already swiped away: still update list view cache/badges cleanly
                var listMeta = PhotoExifMetadata.empty
                listMeta.filename = self.item.filename
                listMeta.pixelWidth = freshAsset.pixelWidth
                listMeta.pixelHeight = freshAsset.pixelHeight
                listMeta.creationDate = freshAsset.creationDate
                listMeta.isEdited = freshAsset.hasAdjustments
                listMeta.appliedEdits = refreshedEdits
                self.onMetadataRefreshed?(targetID, listMeta)
                return
            }

            let updatedDuration: TimeInterval? = freshAsset.mediaType == .video
                ? (await libraryService.fetchEditedVideoMetrics(for: freshAsset, allowNetworkAccess: false)).duration ?? self.item.duration
                : self.item.duration

            let updatedItem = PhotoItem(
                asset: freshAsset,
                filename: self.item.filename,
                creationDate: self.metadata.creationDate ?? freshAsset.creationDate,
                embeddedDate: self.metadata.embeddedDate,
                timeZone: self.metadata.timeZone,
                isDateAdjusted: self.metadata.isDateAdjusted,
                isGPSAdjusted: self.metadata.isGPSAdjusted,
                isSavedFromOtherApps: self.metadata.isSavedFromOtherApps,
                duration: updatedDuration,
                hasEmbeddedTimeZone: self.metadata.hasEmbeddedTimeZone,
                isDrifted: self.item.isDrifted,
                isAnalyzed: true,
                subfolderPath: self.item.subfolderPath,
                fileSize: self.item.fileSize
            )
            self.item = updatedItem

            if result.isRevertedToOriginal {
                self.selectedVersion = .edited
                self.originalImage = nil
                self.originalAVAsset = nil
                self.originalMetadata = nil
            }

            if freshAsset.mediaType == .video {
                let currentTime = self.avPlayer?.currentTime() ?? .zero
                let wasPlaying = self.avPlayer?.timeControlStatus == .playing
                if let newAV = try? await libraryService.fetchAVAsset(for: freshAsset, version: .current),
                   self.assetID == targetID,
                   (self.queuedPhotoKitStepsByAssetID[targetID] ?? 0) == 0 {
                    self.editedAVAsset = newAV
                    self.visualVideoPreviewSteps = 0
                    let playerItem = AVPlayerItem(asset: newAV)
                    if let player = self.avPlayer {
                        player.replaceCurrentItem(with: playerItem)
                        if currentTime.isValid && currentTime > .zero {
                            await player.seek(to: currentTime)
                        }
                        if wasPlaying {
                            player.play()
                        }
                    }
                    if freshAsset.hasAdjustments && self.originalAVAsset == nil {
                        Task {
                            let origAV = try? await self.libraryService.fetchAVAsset(for: freshAsset, version: .original)
                            if self.assetID == freshAsset.localIdentifier {
                                self.originalAVAsset = origAV
                            }
                        }
                    }
                }
            } else {
                if let newImg = await libraryService.requestHighResImage(for: freshAsset, version: .current),
                   self.assetID == targetID,
                   (self.queuedPhotoKitStepsByAssetID[targetID] ?? 0) == 0 {
                    self.editedImage = newImg
                    self.highResImage = newImg
                    self.imageCache[targetID] = newImg
                    if freshAsset.hasAdjustments && self.originalImage == nil {
                        Task {
                            let orig = await self.libraryService.requestHighResImage(for: freshAsset, version: .unadjusted)
                            if self.assetID == freshAsset.localIdentifier {
                                self.originalImage = orig
                            }
                        }
                    }
                }
            }

            self.loadMetadata(asset: freshAsset)
        } catch {
            print("Failed to rotate asset in PhotoKit: \(error.localizedDescription)")
        }
    }

    /// Open coordinates in Apple Maps
    func openInAppleMaps() {
        guard let location = metadata.location else { return }
        let placemark = MKPlacemark(coordinate: location.coordinate)
        let mapItem = MKMapItem(placemark: placemark)
        mapItem.name = metadata.filename
        mapItem.openInMaps(launchOptions: [
            MKLaunchOptionsMapTypeKey: MKMapType.standard.rawValue
        ])
    }

    /// Opens an on-demand byte-range stream for a remote video when the user clicks Play.
    func startStreamingRemoteVideo() {
        guard item.isVideo, mediaSource.isRemote, !isPreparingVideoStream else { return }
        if avPlayer != nil {
            playVideo()
            return
        }

        let targetID = item.id
        let targetItem = item
        let source = mediaSource
        isPreparingVideoStream = true
        videoStreamError = nil

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let handle = try await FolderMediaService.shared.makeRemoteVideoStream(for: targetItem, in: source)
                guard self.assetID == targetID, !Task.isCancelled else {
                    handle.close()
                    return
                }

                self.activeStreamHandle?.close()
                self.activeStreamHandle = handle
                self.editedAVAsset = handle.asset

                self.configureAudioSessionForPlayback()

                let playerItem = AVPlayerItem(asset: handle.asset)
                let pendingSteps = ExifMetadataService.clockwiseSteps(forDegrees: self.item.pendingRotationDegrees)
                if pendingSteps != 0 {
                    playerItem.videoComposition = await self.exifService.makeRotatedVideoComposition(for: handle.asset, clockwiseSteps: pendingSteps)
                    guard self.assetID == targetID, !Task.isCancelled else {
                        handle.close()
                        return
                    }
                }
                let player = AVPlayer(playerItem: playerItem)
                player.isMuted = self.isMuted
                self.avPlayer = player
                player.play()
                await self.waitUntilRemotePlaybackStarts(player: player, playerItem: playerItem, targetID: targetID)
            } catch {
                guard self.assetID == targetID else { return }
                self.isPreparingVideoStream = false
                self.videoStreamError = error.localizedDescription
            }
        }
    }

    private func waitUntilRemotePlaybackStarts(
        player: AVPlayer,
        playerItem: AVPlayerItem,
        targetID: String
    ) async {
        let deadline = ContinuousClock.now + .seconds(60)
        while ContinuousClock.now < deadline {
            guard self.assetID == targetID, self.avPlayer === player, !Task.isCancelled else {
                return
            }
            if playerItem.status == .failed {
                let errMsg = playerItem.error?.localizedDescription ?? "Failed to load video stream."
                self.stopVideoAndRelinquishAudio()
                self.videoStreamError = errMsg
                return
            }
            if player.timeControlStatus == .playing && playerItem.currentTime().seconds > 0.01 {
                self.isPreparingVideoStream = false
                return
            }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        if self.assetID == targetID && self.avPlayer === player {
            self.isPreparingVideoStream = false
        }
    }

    private func configureAudioSessionForPlayback() {
        if isMuted {
            try? AVAudioSession.sharedInstance().setCategory(.ambient, options: .mixWithOthers)
        } else {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try? AVAudioSession.sharedInstance().setActive(true)
        }
    }

    private func observePlayerMuteState(_ player: AVPlayer?) {
        playerMuteObservation?.invalidate()
        playerMuteObservation = nil
        guard let player else { return }
        playerMuteObservation = player.observe(\.isMuted, options: [.new]) { [weak self] observedPlayer, _ in
            let newMuted = observedPlayer.isMuted
            Task { @MainActor [weak self] in
                guard let self, self.avPlayer === observedPlayer else { return }
                self.applyMuteStateChange(newMuted)
            }
        }
    }

    private func applyMuteStateChange(_ muted: Bool) {
        guard isMuted != muted else { return }
        isMuted = muted
        if muted {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            try? AVAudioSession.sharedInstance().setCategory(.ambient, options: .mixWithOthers)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } else {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try? AVAudioSession.sharedInstance().setActive(true)
        }
    }

    /// Play or resume video playback
    func playVideo() {
        guard let player = avPlayer else { return }
        if let currentItem = player.currentItem, currentItem.currentTime() >= currentItem.duration {
            player.seek(to: .zero)
        }
        player.play()
    }

    /// Pause video playback and yield audio session
    func pauseVideo() {
        playerMuteObservation?.invalidate()
        playerMuteObservation = nil
        avPlayer?.pause()
        avPlayer?.isMuted = true
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: .mixWithOthers)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Stops video playback, clears player item, and deactivates AVAudioSession with notification
    /// so the device media control center stops treating this app as active player and background music can resume.
    func stopVideoAndRelinquishAudio() {
        playerMuteObservation?.invalidate()
        playerMuteObservation = nil
        isPreparingVideoStream = false
        pendingRemoteVideoReloadAfterApply = false
        videoStreamError = nil
        avPlayer?.pause()
        avPlayer?.isMuted = true
        avPlayer?.replaceCurrentItem(with: nil)
        avPlayer = nil
        activeStreamHandle?.close()
        activeStreamHandle = nil

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil

        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: .mixWithOthers)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    /// Stops video playback and awaits closing any active remote stream handle (e.g. SMB2 file handle)
    /// before performing an in-place file replacement on disk or remote share.
    func stopVideoAndRelinquishAudioAsync() async {
        playerMuteObservation?.invalidate()
        playerMuteObservation = nil
        isPreparingVideoStream = false
        pendingRemoteVideoReloadAfterApply = false
        videoStreamError = nil
        avPlayer?.pause()
        avPlayer?.isMuted = true
        avPlayer?.replaceCurrentItem(with: nil)
        avPlayer = nil

        let handleToClose = activeStreamHandle
        activeStreamHandle = nil
        await handleToClose?.closeAndWait()

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: .mixWithOthers)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Toggle audio mute state
    func toggleMute() {
        let targetMuted = !isMuted
        avPlayer?.isMuted = targetMuted
        applyMuteStateChange(targetMuted)
    }

    // MARK: - Export & Delete Operations

    var currentItemForExport: PhotoItem {
        let targetMetadata = editedMetadata ?? metadata
        let effectiveName = targetMetadata.originalFilename ?? targetMetadata.filename
        let resolvedAsset = mediaSource.isFolder ? nil : (PHAsset.fetchAssets(withLocalIdentifiers: [item.id], options: nil).firstObject ?? item.asset)
        if let freshAsset = resolvedAsset {
            return PhotoItem(
                asset: freshAsset,
                filename: effectiveName.isEmpty ? item.filename : effectiveName,
                creationDate: targetMetadata.creationDate ?? freshAsset.creationDate,
                embeddedDate: targetMetadata.embeddedDate,
                timeZone: targetMetadata.timeZone,
                isDateAdjusted: targetMetadata.isDateAdjusted,
                isGPSAdjusted: targetMetadata.isGPSAdjusted,
                isSavedFromOtherApps: targetMetadata.isSavedFromOtherApps,
                duration: item.duration,
                hasEmbeddedTimeZone: targetMetadata.hasEmbeddedTimeZone,
                isDrifted: targetMetadata.isDrifted,
                isAnalyzed: true,
                subfolderPath: item.subfolderPath,
                fileSize: targetMetadata.fileByteCount > 0 ? targetMetadata.fileByteCount : item.fileSize
            )
        }
        return PhotoItem(
            id: item.id,
            filename: effectiveName.isEmpty ? item.filename : effectiveName,
            creationDate: targetMetadata.creationDate ?? item.creationDate,
            embeddedDate: targetMetadata.embeddedDate ?? item.embeddedDate,
            timeZone: targetMetadata.timeZone,
            isDateAdjusted: targetMetadata.isDateAdjusted,
            isGPSAdjusted: targetMetadata.isGPSAdjusted,
            pendingRotationDegrees: item.pendingRotationDegrees,
            pixelWidth: item.pixelWidth,
            pixelHeight: item.pixelHeight,
            location: item.location,
            duration: item.duration,
            hasEmbeddedTimeZone: targetMetadata.hasEmbeddedTimeZone,
            isDrifted: targetMetadata.isDrifted,
            isAnalyzed: true,
            subfolderPath: item.subfolderPath,
            fileSize: targetMetadata.fileByteCount > 0 ? targetMetadata.fileByteCount : item.fileSize,
            fileModificationDate: item.fileModificationDate,
            isVideoFile: item.isVideoFile,
            localFileURL: item.localFileURL,
            remoteFileID: item.remoteFileID,
            remoteThumbnailLink: item.remoteThumbnailLink
        )
    }

    var showsApplyAction: Bool {
        mediaSource.isFolder && item.needsInPlaceApply
    }

    func releaseMediaHandleIfNeededForSwap(itemID: String) async {
        guard item.id == itemID, item.isVideo, mediaSource.isRemote else { return }
        await stopVideoAndRelinquishAudioAsync()
    }

    func handleAppliedInPlaceResult(
        oldID: String,
        cleared: PhotoItem,
        isProgressSheetShowing: @escaping @MainActor () -> Bool = { false }
    ) {
        guard self.item.id == oldID || self.assetID == oldID else { return }
        let effectiveID = cleared.id
        if effectiveID != oldID, let cachedImg = self.imageCache.removeValue(forKey: oldID) {
            self.imageCache[effectiveID] = cachedImg
        }
        self.assetID = effectiveID
        self.item = cleared
        self.metadata.isDateAdjusted = false
        self.metadata.isGPSAdjusted = false
        self.metadata.pendingRotationDegrees = 0
        self.metadata.hasEmbeddedTimeZone = true
        self.metadata.isDrifted = false
        let appliedDate = cleared.creationDate ?? cleared.embeddedDate ?? cleared.fileModificationDate
        self.metadata.creationDate = appliedDate
        self.metadata.embeddedDate = appliedDate
        self.metadata.timeZone = cleared.timeZone
        self.metadata.originalTimeZone = cleared.timeZone
        if let appliedDate {
            self.metadata.offsetTimeString = DateFormatters.exifTimezoneOffset(for: appliedDate, in: cleared.timeZone)
        }
        self.editedMetadata = self.metadata
        self.onFolderItemUpdated?(oldID, cleared)
        self.onMetadataRefreshed?(cleared.id, self.metadata)

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshFolderMetadataAfterApply(for: cleared, oldID: oldID, isProgressSheetShowing: isProgressSheetShowing)
        }
    }

    func performPendingVideoReloadIfNeeded() async {
        guard pendingRemoteVideoReloadAfterApply else { return }
        pendingRemoteVideoReloadAfterApply = false
        guard item.isVideo, mediaSource.isRemote else { return }
        await stopVideoAndRelinquishAudioAsync()
        startStreamingRemoteVideo()
    }

    private func refreshFolderMetadataAfterApply(
        for targetItem: PhotoItem,
        oldID: String,
        isProgressSheetShowing: @escaping @MainActor () -> Bool
    ) async {
        let targetID = targetItem.id
        isLoadingMetadata = true
        defer {
            if self.assetID == targetID {
                self.isLoadingMetadata = false
            }
        }

        do {
            let result = try await FolderMediaService.shared.loadDetailMediaAndMetadata(for: targetItem, in: mediaSource)
            guard self.assetID == targetID else {
                if let tempURL = result.tempFileToCleanup {
                    try? FileManager.default.removeItem(at: tempURL)
                }
                return
            }

            if let image = result.image {
                self.highResImage = image
                self.editedImage = image
                self.imageCache[targetID] = image
            }
            if let videoURL = result.localVideoURL {
                let currentTime = self.avPlayer?.currentTime() ?? .zero
                let wasPlaying = self.avPlayer?.timeControlStatus == .playing
                let newAVAsset = AVURLAsset(url: videoURL)
                self.editedAVAsset = newAVAsset
                let playerItem = AVPlayerItem(asset: newAVAsset)
                if let player = self.avPlayer {
                    player.replaceCurrentItem(with: playerItem)
                    if currentTime.isValid && currentTime > .zero {
                        await player.seek(to: currentTime)
                    }
                    if wasPlaying {
                        player.play()
                    }
                }
            } else if targetItem.isVideo, mediaSource.isRemote {
                if isProgressSheetShowing() {
                    self.pendingRemoteVideoReloadAfterApply = true
                } else {
                    await self.stopVideoAndRelinquishAudioAsync()
                    self.startStreamingRemoteVideo()
                }
            } else if let tempURL = result.tempFileToCleanup {
                try? FileManager.default.removeItem(at: tempURL)
            }

            var refreshedMeta = result.metadata
            refreshedMeta.isDateAdjusted = false
            refreshedMeta.isGPSAdjusted = false
            refreshedMeta.pendingRotationDegrees = 0
            self.metadata = refreshedMeta
            self.editedMetadata = refreshedMeta

            let refreshedItem = PhotoItem(
                id: targetItem.id,
                filename: targetItem.filename,
                creationDate: refreshedMeta.creationDate ?? targetItem.creationDate,
                embeddedDate: refreshedMeta.embeddedDate ?? refreshedMeta.creationDate ?? targetItem.embeddedDate,
                timeZone: refreshedMeta.timeZone,
                isDateAdjusted: false,
                isGPSAdjusted: false,
                pendingRotationDegrees: 0,
                pixelWidth: refreshedMeta.pixelWidth > 0 ? refreshedMeta.pixelWidth : targetItem.pixelWidth,
                pixelHeight: refreshedMeta.pixelHeight > 0 ? refreshedMeta.pixelHeight : targetItem.pixelHeight,
                location: refreshedMeta.location ?? targetItem.location,
                duration: refreshedMeta.duration ?? targetItem.duration,
                hasEmbeddedTimeZone: refreshedMeta.hasEmbeddedTimeZone,
                isDrifted: refreshedMeta.isDrifted,
                isAnalyzed: true,
                subfolderPath: targetItem.subfolderPath,
                fileSize: refreshedMeta.fileByteCount ?? targetItem.fileSize,
                fileModificationDate: targetItem.fileModificationDate,
                isVideoFile: targetItem.isVideoFile,
                localFileURL: targetItem.localFileURL,
                remoteFileID: targetItem.remoteFileID,
                remoteThumbnailLink: targetItem.remoteThumbnailLink
            )
            self.item = refreshedItem
            self.onFolderItemUpdated?(oldID, refreshedItem)
            self.onMetadataRefreshed?(refreshedItem.id, refreshedMeta)

            if let loc = refreshedMeta.location {
                self.mapRegion = MKCoordinateRegion(
                    center: loc.coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.015, longitudeDelta: 0.015)
                )
                let address = await self.geocodingService.reverseGeocode(location: loc)
                if self.assetID == targetID {
                    self.geocodedAddress = address
                }
            } else {
                self.mapRegion = nil
                self.geocodedAddress = nil
            }
        } catch {
            // Keep the already-updated scalar metadata if re-reading the file fails
        }
    }

    func initiateDelete() {
        Task {
            _ = await deletePhoto()
        }
    }

    func confirmDelete() async -> Bool {
        await deletePhoto()
    }

    func deletePhoto() async -> Bool {
        if mediaSource.isFolder {
            do {
                try await FolderMediaService.shared.deleteItems([item], in: mediaSource)
                return true
            } catch {
                print("Failed to delete folder item: \(error.localizedDescription)")
                return false
            }
        }
        guard let asset = item.asset else { return false }
        do {
            try await libraryService.deleteAssets([asset])
            return true
        } catch {
            let nsErr = error as NSError
            if (nsErr.domain == "PHPhotosErrorDomain" && nsErr.code == 3072) ||
               (nsErr.domain == NSCocoaErrorDomain && nsErr.code == NSUserCancelledError) {
                return false
            }
            print("Failed to delete asset: \(error.localizedDescription)")
            return false
        }
    }
}
