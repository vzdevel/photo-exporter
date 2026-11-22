//
//  PhotoLibraryService.swift
//  Photo Exporter
//

import Foundation
import Photos
import UIKit
import Combine
import CoreData
import AVFoundation
import UniformTypeIdentifiers

extension NSManagedObject {
    nonisolated func safeValue(forKey key: String) -> Any? {
        if entity.propertiesByName[key] != nil || entity.relationshipsByName[key] != nil || entity.attributesByName[key] != nil || responds(to: NSSelectorFromString(key)) {
            return value(forKey: key)
        }
        return nil
    }

    nonisolated func safeInt(forKey key: String) -> Int? {
        if let val = safeValue(forKey: key) {
            if let num = val as? NSNumber {
                return num.intValue
            }
            if let i = val as? Int {
                return i
            }
        }
        return nil
    }

    nonisolated func safeDouble(forKey key: String) -> Double? {
        if let val = safeValue(forKey: key) {
            if let num = val as? NSNumber {
                return num.doubleValue
            }
            if let d = val as? Double {
                return d
            }
        }
        return nil
    }

    nonisolated func safeDate(forKey key: String) -> Date? {
        if let val = safeValue(forKey: key) {
            if let date = val as? Date {
                return date
            }
            if let num = val as? NSNumber {
                // CoreData timestamps are seconds relative to 2001-01-01 00:00:00 UTC (macOS/iOS reference date)
                return Date(timeIntervalSinceReferenceDate: num.doubleValue)
            }
            if let d = val as? Double {
                return Date(timeIntervalSinceReferenceDate: d)
            }
        }
        return nil
    }
}

/// Service responsible for photo library access, fetching, deletion, and caching
final class PhotoLibraryService: NSObject, ObservableObject {
    static let shared = PhotoLibraryService()

    @Published var authorizationStatus: PHAuthorizationStatus = .notDetermined
    @Published var libraryChangePublisher = PassthroughSubject<PHChange, Never>()

    let imageManager = PHCachingImageManager()

    override private init() {
        super.init()
        self.authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        PHPhotoLibrary.shared().register(self)
    }

    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    // MARK: - Authorization

    func requestAuthorization() async -> PHAuthorizationStatus {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        await MainActor.run {
            self.authorizationStatus = status
        }
        return status
    }

    // MARK: - Fetch Assets

    /// Fetch all image and video assets from the photo library sorted chronologically
    nonisolated func fetchPhotoAssets(ascending: Bool = true) -> [PHAsset] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: ascending)]
        options.includeHiddenAssets = false

        let fetchResult = PHAsset.fetchAssets(with: options)
        var assets: [PHAsset] = []
        assets.reserveCapacity(fetchResult.count)

        fetchResult.enumerateObjects { asset, _, _ in
            if asset.mediaType == .image || asset.mediaType == .video {
                assets.append(asset)
            }
        }

        return assets
    }

    /// Fetch assets for given local identifiers
    nonisolated func fetchAssets(with identifiers: [String]) -> [PHAsset] {
        guard !identifiers.isEmpty else { return [] }
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var assets: [PHAsset] = []
        assets.reserveCapacity(fetchResult.count)
        fetchResult.enumerateObjects { asset, _, _ in
            if asset.mediaType == .image || asset.mediaType == .video {
                assets.append(asset)
            }
        }
        return assets
    }

    // MARK: - Persistent Change Token & Incremental Updates

    nonisolated private static let changeTokenUserDefaultsKey = "PhotoLibrary_PersistentChangeToken"

    /// Save persistent change token to disk
    nonisolated func savePersistentChangeToken(_ token: PHPersistentChangeToken) {
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) {
            UserDefaults.standard.set(data, forKey: Self.changeTokenUserDefaultsKey)
        }
    }

    /// Load persistent change token from disk
    nonisolated func loadPersistentChangeToken() -> PHPersistentChangeToken? {
        guard let data = UserDefaults.standard.data(forKey: Self.changeTokenUserDefaultsKey) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: PHPersistentChangeToken.self, from: data)
    }

    /// Delete persistent change token from disk
    nonisolated func deletePersistentChangeToken() {
        UserDefaults.standard.removeObject(forKey: Self.changeTokenUserDefaultsKey)
    }

    /// Current change token from PhotoKit
    nonisolated var currentChangeToken: PHPersistentChangeToken {
        PHPhotoLibrary.shared().currentChangeToken
    }

    /// Fetch persistent changes since given token
    nonisolated func fetchPersistentChanges(since token: PHPersistentChangeToken) throws -> PHPersistentChangeFetchResult {
        try PHPhotoLibrary.shared().fetchPersistentChanges(since: token)
    }

    /// Resolve the original filename for an asset
    nonisolated func resolveFilename(for asset: PHAsset) -> String {
        // 1. Try Photos app internal originalFilename from additionalAttributes
        if let original = asset.photosAppOriginalFilename, !original.isEmpty {
            return original
        }

        // 2. Try PHAssetResource originalFilename
        let resources = PHAssetResource.assetResources(for: asset)
        if let primaryResource = resources.first(where: {
            $0.type == .photo || $0.type == .fullSizePhoto || $0.type == .video || $0.type == .fullSizeVideo
        }), !primaryResource.originalFilename.isEmpty {
            return primaryResource.originalFilename
        }
        if let firstResource = resources.first, !firstResource.originalFilename.isEmpty {
            return firstResource.originalFilename
        }

        // 3. Fallback to asset filename
        if let name = asset.value(forKey: "filename") as? String, !name.isEmpty {
            return name
        }

        // 4. Default fallback
        let ext = asset.mediaType == .video ? "MOV" : "HEIC"
        return "IMG_\(asset.localIdentifier.prefix(6)).\(ext)"
    }

    /// Resolve the Camera Roll (DCIM) filename for an asset
    nonisolated func resolveCameraRollFilename(for asset: PHAsset) -> String? {
        if let name = (asset.value(forKey: "filename") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }
        return asset.photosAppCameraRollFilename
    }

    // MARK: - Thumbnail & Image Loading

    /// Request a thumbnail for an asset with target size
    func requestThumbnail(
        for asset: PHAsset,
        targetSize: CGSize = CGSize(width: 140, height: 140),
        completion: @escaping (UIImage?) -> Void
    ) -> PHImageRequestID {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true

        return imageManager.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options
        ) { image, _ in
            completion(image)
        }
    }

    /// Request high-resolution image for detail view
    func requestHighResImage(for asset: PHAsset, version: PHImageRequestOptionsVersion = .current) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .exact
            options.isNetworkAccessAllowed = true
            options.isSynchronous = false
            options.version = version

            var hasResumed = false
            let lock = NSLock()

            imageManager.requestImage(
                for: asset,
                targetSize: PHImageManagerMaximumSize,
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                if let error = info?[PHImageErrorKey] as? Error {
                    print("Error requesting high res image: \(error.localizedDescription)")
                    lock.lock()
                    if !hasResumed {
                        hasResumed = true
                        lock.unlock()
                        continuation.resume(returning: nil)
                    } else {
                        lock.unlock()
                    }
                    return
                }

                let isCancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                if isCancelled {
                    lock.lock()
                    if !hasResumed {
                        hasResumed = true
                        lock.unlock()
                        continuation.resume(returning: nil)
                    } else {
                        lock.unlock()
                    }
                    return
                }

                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if !isDegraded {
                    lock.lock()
                    if !hasResumed {
                        hasResumed = true
                        lock.unlock()
                        continuation.resume(returning: image)
                    } else {
                        lock.unlock()
                    }
                }
            }
        }
    }

    /// Fetch AVAsset for a video asset
    func fetchAVAsset(for asset: PHAsset, version: PHVideoRequestOptionsVersion = .current) async throws -> AVAsset {
        try await withCheckedThrowingContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            options.version = version

            imageManager.requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
                if let error = info?[PHImageErrorKey] as? Error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let avAsset = avAsset else {
                    continuation.resume(throwing: NSError(domain: "PhotoLibraryService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to load video AVAsset"]))
                    return
                }
                continuation.resume(returning: avAsset)
            }
        }
    }



    struct EditedVideoMetrics: Sendable {
        let duration: TimeInterval?
        let pixelWidth: Int?
        let pixelHeight: Int?
        let estimatedFileSize: Int64?
    }

    private func requestExportSession(
        for asset: PHAsset,
        version: PHVideoRequestOptionsVersion,
        preset: String,
        allowNetworkAccess: Bool
    ) async throws -> AVAssetExportSession {
        try await withCheckedThrowingContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = allowNetworkAccess
            options.deliveryMode = .highQualityFormat
            options.version = version

            imageManager.requestExportSession(forVideo: asset, options: options, exportPreset: preset) { exportSession, info in
                if let error = info?[PHImageErrorKey] as? Error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let exportSession else {
                    continuation.resume(throwing: NSError(
                        domain: "PhotoLibraryService",
                        code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to create export session for edited video"]
                    ))
                    return
                }
                continuation.resume(returning: exportSession)
            }
        }
    }

    /// Exports an edited video asset with Photos adjustments (trim, rotation, crop, filters) rendered to a temporary file.
    private func exportEditedVideoToTempURL(for asset: PHAsset) async throws -> URL {
        let exportSession: AVAssetExportSession
        do {
            exportSession = try await requestExportSession(
                for: asset,
                version: .current,
                preset: AVAssetExportPresetHighestQuality,
                allowNetworkAccess: true
            )
        } catch {
            exportSession = try await requestExportSession(
                for: asset,
                version: .current,
                preset: AVAssetExportPresetPassthrough,
                allowNetworkAccess: true
            )
        }

        let supportedTypes = exportSession.supportedFileTypes
        let fileType: AVFileType = supportedTypes.contains(.mov) ? .mov : (supportedTypes.first ?? .mov)
        let ext = (fileType == .mp4) ? "mp4" : "mov"

        let resolvedName = resolveFilename(for: asset)
        let baseName = (resolvedName as NSString).deletingPathExtension
        let outputName = (baseName.isEmpty ? UUID().uuidString : baseName) + ".\(ext)"
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(outputName)

        try FileManager.default.createDirectory(at: tempURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        exportSession.outputURL = tempURL
        exportSession.outputFileType = fileType
        exportSession.shouldOptimizeForNetworkUse = false

        await withCheckedContinuation { continuation in
            exportSession.exportAsynchronously {
                continuation.resume()
            }
        }

        guard exportSession.status == .completed else {
            try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent())
            throw exportSession.error ?? NSError(
                domain: "PhotoLibraryService",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Edited video export failed with status \(exportSession.status.rawValue)"]
            )
        }

        return tempURL
    }

    /// Computes trimmed duration, rotated/cropped dimensions, and rendered/estimated file size for an edited video.
    nonisolated func fetchEditedVideoMetrics(for asset: PHAsset, allowNetworkAccess: Bool = true) async -> EditedVideoMetrics {
        guard asset.mediaType == .video else {
            return EditedVideoMetrics(duration: nil, pixelWidth: nil, pixelHeight: nil, estimatedFileSize: nil)
        }

        let resources = PHAssetResource.assetResources(for: asset)
        let fullSizeVideoBytes: Int64? = {
            guard let res = resources.first(where: { $0.type == .fullSizeVideo }),
                  let num = res.value(forKey: "fileSize") as? NSNumber,
                  num.int64Value > 0 else {
                return nil
            }
            return num.int64Value
        }()
        let originalVideoBytes: Int64? = {
            guard let res = resources.first(where: { $0.type == .video }),
                  let num = res.value(forKey: "fileSize") as? NSNumber,
                  num.int64Value > 0 else {
                return nil
            }
            return num.int64Value
        }()

        let session: AVAssetExportSession? = await withCheckedContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = allowNetworkAccess
            options.deliveryMode = .highQualityFormat
            options.version = .current

            PHImageManager.default().requestExportSession(
                forVideo: asset,
                options: options,
                exportPreset: AVAssetExportPresetHighestQuality
            ) { exportSession, _ in
                continuation.resume(returning: exportSession)
            }
        }

        var editedDuration: TimeInterval? = nil
        var editedWidth: Int? = nil
        var editedHeight: Int? = nil
        var estimatedBytes: Int64? = fullSizeVideoBytes

        if let session {
            if let cmDur = try? await session.asset.load(.duration) {
                let sec = CMTimeGetSeconds(cmDur)
                if sec.isFinite && sec > 0 {
                    editedDuration = sec
                }
            }

            if let renderSize = session.videoComposition?.renderSize,
               renderSize.width > 0, renderSize.height > 0 {
                editedWidth = Int(renderSize.width.rounded())
                editedHeight = Int(renderSize.height.rounded())
            } else if let tracks = try? await session.asset.loadTracks(withMediaType: .video),
                      let videoTrack = tracks.first {
                let naturalSize = (try? await videoTrack.load(.naturalSize)) ?? .zero
                let transform = (try? await videoTrack.load(.preferredTransform)) ?? .identity
                let transformed = naturalSize.applying(transform)
                let w = Int(abs(transformed.width).rounded())
                let h = Int(abs(transformed.height).rounded())
                if w > 0 && h > 0 {
                    editedWidth = w
                    editedHeight = h
                }
            }

            if estimatedBytes == nil, let urlAsset = session.asset as? AVURLAsset {
                if let size = (try? FileManager.default.attributesOfItem(atPath: urlAsset.url.path)[.size] as? NSNumber)?.int64Value,
                   size > 0 {
                    estimatedBytes = size
                }
            }
            if estimatedBytes == nil {
                if let est = try? await session.estimatedOutputFileLengthInBytes, est > 0 {
                    estimatedBytes = est
                }
            }
        } else {
            // Fallback to requestAVAsset if export session is unavailable
            let avAsset: AVAsset? = await withCheckedContinuation { continuation in
                let options = PHVideoRequestOptions()
                options.isNetworkAccessAllowed = allowNetworkAccess
                options.deliveryMode = .highQualityFormat
                options.version = .current
                PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                    continuation.resume(returning: avAsset)
                }
            }
            if let avAsset {
                if let cmDur = try? await avAsset.load(.duration) {
                    let sec = CMTimeGetSeconds(cmDur)
                    if sec.isFinite && sec > 0 {
                        editedDuration = sec
                    }
                }
                if let tracks = try? await avAsset.loadTracks(withMediaType: .video),
                   let videoTrack = tracks.first {
                    let naturalSize = (try? await videoTrack.load(.naturalSize)) ?? .zero
                    let transform = (try? await videoTrack.load(.preferredTransform)) ?? .identity
                    let transformed = naturalSize.applying(transform)
                    let w = Int(abs(transformed.width).rounded())
                    let h = Int(abs(transformed.height).rounded())
                    if w > 0 && h > 0 {
                        editedWidth = w
                        editedHeight = h
                    }
                }
                if estimatedBytes == nil, let urlAsset = avAsset as? AVURLAsset,
                   let size = (try? FileManager.default.attributesOfItem(atPath: urlAsset.url.path)[.size] as? NSNumber)?.int64Value,
                   size > 0 {
                    estimatedBytes = size
                }
            }
        }

        if estimatedBytes == nil,
           let origBytes = originalVideoBytes,
           let dur = editedDuration, dur > 0, asset.duration > 0 {
            estimatedBytes = max(1, Int64((Double(origBytes) * (dur / asset.duration)).rounded()))
        }

        return EditedVideoMetrics(
            duration: editedDuration,
            pixelWidth: editedWidth,
            pixelHeight: editedHeight,
            estimatedFileSize: estimatedBytes
        )
    }

    /// Fetch local file URL for an asset resource
    func fetchLocalFileURL(for asset: PHAsset, preferOriginal: Bool = false) async throws -> URL {
        if !preferOriginal && asset.mediaType == .video && asset.hasAdjustments {
            return try await exportEditedVideoToTempURL(for: asset)
        }

        let resources = PHAssetResource.assetResources(for: asset)
        let preferredTypes: [PHAssetResourceType] = preferOriginal
            ? [.video, .photo, .fullSizeVideo, .fullSizePhoto]
            : [.fullSizeVideo, .fullSizePhoto, .video, .photo]
        var resource: PHAssetResource? = nil
        for targetType in preferredTypes {
            if let match = resources.first(where: { $0.type == targetType }) {
                resource = match
                break
            }
        }
        if resource == nil {
            resource = resources.first
        }
        guard let primaryResource = resource else {
            throw NSError(domain: "PhotoLibraryService", code: -1, userInfo: [NSLocalizedDescriptionKey: "No resource found for asset"])
        }

        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(primaryResource.originalFilename)

        try FileManager.default.createDirectory(at: tempURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true

        return try await withCheckedThrowingContinuation { continuation in
            PHAssetResourceManager.default().writeData(for: primaryResource, toFile: tempURL, options: options) { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: tempURL)
                }
            }
        }
    }
    func fetchImageData(for asset: PHAsset, preferEdited: Bool = true) async throws -> (data: Data, dataUTI: String, orientation: CGImagePropertyOrientation) {
        let requestedVersion: PHImageRequestOptionsVersion = (preferEdited && asset.hasAdjustments) ? .current : .original
        do {
            return try await fetchImageData(for: asset, version: requestedVersion)
        } catch {
            if requestedVersion == .original && asset.hasAdjustments {
                return try await fetchImageData(for: asset, version: .unadjusted)
            }
            throw error
        }
    }

    private func fetchImageData(for asset: PHAsset, version: PHImageRequestOptionsVersion) async throws -> (data: Data, dataUTI: String, orientation: CGImagePropertyOrientation) {
        try await withCheckedThrowingContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            options.version = version

            imageManager.requestImageDataAndOrientation(for: asset, options: options) { data, dataUTI, orientation, info in
                if let error = info?[PHImageErrorKey] as? Error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let data = data else {
                    continuation.resume(throwing: NSError(domain: "PhotoLibraryService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to load image data"]))
                    return
                }

                let uti = dataUTI ?? "public.jpeg"
                continuation.resume(returning: (data, uti, orientation))
            }
        }
    }

    // MARK: - Adjust Asset Date & Location
    
    /// Update the creation date, timezone, and optional location of an asset in the photo library
    func updateAssetDateTime(asset: PHAsset, newDate: Date, timeZone: TimeZone? = nil, location: CLLocation? = nil) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetChangeRequest(for: asset)
            request.creationDate = newDate
            if let location = location {
                request.location = location
            }

            if let tz = timeZone {
                let sel = Selector(("setTimeZone:withDate:"))
                if request.responds(to: sel) {
                    typealias SetTimeZoneFunc = @convention(c) (AnyObject, Selector, NSTimeZone, NSDate) -> Void
                    let imp = class_getMethodImplementation(type(of: request), sel)
                    let fn = unsafeBitCast(imp, to: SetTimeZoneFunc.self)
                    fn(request, sel, tz as NSTimeZone, newDate as NSDate)
                }
            }
        }
    }

    /// Batch update creation date and optional timezone for multiple assets in a single PhotoKit transaction
    func batchUpdateAssetDateTime(updates: [(asset: PHAsset, newDate: Date, timeZone: TimeZone?)]) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let sel = Selector(("setTimeZone:withDate:"))
            for update in updates {
                let request = PHAssetChangeRequest(for: update.asset)
                request.creationDate = update.newDate
                if let tz = update.timeZone, request.responds(to: sel) {
                    typealias SetTimeZoneFunc = @convention(c) (AnyObject, Selector, NSTimeZone, NSDate) -> Void
                    let imp = class_getMethodImplementation(type(of: request), sel)
                    let fn = unsafeBitCast(imp, to: SetTimeZoneFunc.self)
                    fn(request, sel, tz as NSTimeZone, update.newDate as NSDate)
                }
            }
        }
    }

    /// Revert asset creation date, timezone, and location back to original values
    func revertAssetDateTime(asset: PHAsset, originalDate: Date, originalTimeZone: TimeZone? = nil, originalLocation: CLLocation?) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetChangeRequest(for: asset)
            request.creationDate = originalDate
            request.location = originalLocation

            if let tz = originalTimeZone {
                let sel = Selector(("setTimeZone:withDate:"))
                if request.responds(to: sel) {
                    typealias SetTimeZoneFunc = @convention(c) (AnyObject, Selector, NSTimeZone, NSDate) -> Void
                    let imp = class_getMethodImplementation(type(of: request), sel)
                    let fn = unsafeBitCast(imp, to: SetTimeZoneFunc.self)
                    fn(request, sel, tz as NSTimeZone, originalDate as NSDate)
                }
            }
        }
    }

    // MARK: - Rotate Asset (Non-Destructive PhotoKit Edit)

    static let rotationAdjustmentIdentifier = "com.photoexporter.rotation"

    private struct RotationAdjustmentPayload: Codable {
        var clockwiseSteps: Int
        var isBakedBase: Bool
        var priorEdits: [String]
    }

    struct RotationCommitResult {
        let updatedAsset: PHAsset
        let clockwiseSteps: Int
        let isRevertedToOriginal: Bool
    }

    /// Applies a cumulative clockwise 90° * `deltaSteps` non-destructive PhotoKit edit to an asset.
    /// Reverts the asset to original if it returns to 0° (modulo 4) and had no prior external edits.
    func rotateAsset(asset: PHAsset, deltaSteps: Int) async throws -> RotationCommitResult {
        let normalizedDelta = ((deltaSteps % 4) + 4) % 4

        // 1. Inspect existing adjustment envelope to determine whether we can render losslessly from the unadjusted master
        let existingAdj: PHAdjustmentData? = await withCheckedContinuation { continuation in
            let options = PHContentEditingInputRequestOptions()
            options.canHandleAdjustmentData = { _ in true }
            options.isNetworkAccessAllowed = true
            asset.requestContentEditingInput(with: options) { input, _ in
                continuation.resume(returning: input?.adjustmentData)
            }
        }

        let prevPayload: RotationAdjustmentPayload? = {
            guard let adj = existingAdj, adj.formatIdentifier == Self.rotationAdjustmentIdentifier else {
                return nil
            }
            return try? JSONDecoder().decode(RotationAdjustmentPayload.self, from: adj.data)
        }()

        let isBakedMode: Bool
        let prevSteps: Int
        let priorEdits: [String]
        if let prevPayload {
            isBakedMode = prevPayload.isBakedBase
            prevSteps = ((prevPayload.clockwiseSteps % 4) + 4) % 4
            priorEdits = prevPayload.priorEdits
        } else if let existingAdj {
            isBakedMode = true
            prevSteps = 0
            priorEdits = ExifMetadataService.shared.parseAdjustmentData(existingAdj, asset: asset)
        } else {
            isBakedMode = false
            prevSteps = 0
            priorEdits = []
        }

        let newTotalSteps = ((prevSteps + normalizedDelta) % 4 + 4) % 4

        // 2. If cumulative rotation returned to 0°
        if newTotalSteps == 0 && !isBakedMode {
            if asset.hasAdjustments {
                try await PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetChangeRequest(for: asset)
                    request.revertAssetContentToOriginal()
                }
            }
            let refreshed = PHAsset.fetchAssets(withLocalIdentifiers: [asset.localIdentifier], options: nil).firstObject ?? asset
            return RotationCommitResult(updatedAsset: refreshed, clockwiseSteps: 0, isRevertedToOriginal: true)
        }

        // If delta is 0 on a baked asset, no change needed
        if normalizedDelta == 0 {
            let refreshed = PHAsset.fetchAssets(withLocalIdentifiers: [asset.localIdentifier], options: nil).firstObject ?? asset
            return RotationCommitResult(updatedAsset: refreshed, clockwiseSteps: newTotalSteps, isRevertedToOriginal: !refreshed.hasAdjustments)
        }

        // 3. Request content editing input at the appropriate base version
        let input: PHContentEditingInput = try await withCheckedThrowingContinuation { continuation in
            let options = PHContentEditingInputRequestOptions()
            options.isNetworkAccessAllowed = true
            if isBakedMode {
                options.canHandleAdjustmentData = { _ in false }
            } else {
                options.canHandleAdjustmentData = { adj in
                    adj.formatIdentifier == Self.rotationAdjustmentIdentifier && adj.formatVersion == "1.0"
                }
            }

            asset.requestContentEditingInput(with: options) { editingInput, info in
                if let editingInput {
                    continuation.resume(returning: editingInput)
                } else {
                    let err = (info[PHContentEditingInputErrorKey] as? Error)
                        ?? NSError(domain: "PhotoLibraryService", code: -30, userInfo: [NSLocalizedDescriptionKey: "Failed to load content editing input"])
                    continuation.resume(throwing: err)
                }
            }
        }

        let effectiveRenderSteps = isBakedMode ? normalizedDelta : newTotalSteps
        let output = PHContentEditingOutput(contentEditingInput: input)
        let payload = RotationAdjustmentPayload(
            clockwiseSteps: newTotalSteps,
            isBakedBase: isBakedMode,
            priorEdits: priorEdits
        )
        let payloadData = try JSONEncoder().encode(payload)
        output.adjustmentData = PHAdjustmentData(
            formatIdentifier: Self.rotationAdjustmentIdentifier,
            formatVersion: isBakedMode ? "1.0-baked" : "1.0",
            data: payloadData
        )

        if asset.mediaType == .video {
            let avAsset: AVAsset? = input.audiovisualAsset ?? input.fullSizeImageURL.map { AVURLAsset(url: $0) }
            guard let avAsset else {
                throw NSError(domain: "PhotoLibraryService", code: -31, userInfo: [NSLocalizedDescriptionKey: "Unable to load video asset for rotation"])
            }
            try await ExifMetadataService.exportVideoAsset(
                avAsset,
                to: output.renderedContentURL,
                metadata: nil,
                clockwiseSteps: effectiveRenderSteps
            )
        } else {
            let sourceData: Data
            if let fullURL = input.fullSizeImageURL, let urlData = try? Data(contentsOf: fullURL) {
                sourceData = urlData
            } else if let dispImg = input.displaySizeImage, let jpgData = dispImg.jpegData(compressionQuality: 0.95) {
                sourceData = jpgData
            } else {
                throw NSError(domain: "PhotoLibraryService", code: -32, userInfo: [NSLocalizedDescriptionKey: "Unable to load image data for rotation"])
            }

            let renderedData = try ExifMetadataService.rotateImageData(
                sourceData,
                targetType: UTType.jpeg.identifier as CFString,
                clockwiseSteps: effectiveRenderSteps
            )
            try renderedData.write(to: output.renderedContentURL, options: .atomic)
        }

        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetChangeRequest(for: asset)
            request.contentEditingOutput = output
        }

        let refreshed = PHAsset.fetchAssets(withLocalIdentifiers: [asset.localIdentifier], options: nil).firstObject ?? asset
        return RotationCommitResult(
            updatedAsset: refreshed,
            clockwiseSteps: newTotalSteps,
            isRevertedToOriginal: false
        )
    }

    // MARK: - Delete Assets

    /// Delete a collection of assets from the photo library (triggers iOS confirmation dialog)
    func deleteAssets(_ assets: [PHAsset]) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets as NSArray)
        }
    }
}

// MARK: - PHPhotoLibraryChangeObserver

extension PhotoLibraryService: PHPhotoLibraryChangeObserver {
    func photoLibraryDidChange(_ changeInstance: PHChange) {
        DispatchQueue.main.async {
            self.libraryChangePublisher.send(changeInstance)
        }
    }
}

// MARK: - PHAsset Photos App Timezone Extension

extension PHAsset {
    /// Retrieve the original filename from Apple Photos database via PhotoKit's internal PLManagedAsset -> additionalAttributes.originalFilename
    nonisolated var photosAppOriginalFilename: String? {
        let block = { () -> String? in
            guard let pl = (self as AnyObject).value(forKey: "pl_managedAsset") as? NSManagedObject else {
                return nil
            }
            if let aa = pl.safeValue(forKey: "additionalAttributes") as? NSManagedObject,
               let orig = (aa.safeValue(forKey: "originalFilename") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !orig.isEmpty {
                return orig
            }
            if let orig = (pl.safeValue(forKey: "originalFilename") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !orig.isEmpty {
                return orig
            }
            return nil
        }

        if Thread.isMainThread {
            return block()
        } else {
            return DispatchQueue.main.sync(execute: block)
        }
    }

    /// Retrieve the camera roll (DCIM) filename from Apple Photos database via PhotoKit's internal PLManagedAsset.filename
    nonisolated var photosAppCameraRollFilename: String? {
        let block = { () -> String? in
            guard let pl = (self as AnyObject).value(forKey: "pl_managedAsset") as? NSManagedObject else {
                return nil
            }
            if let fn = (pl.safeValue(forKey: "filename") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !fn.isEmpty {
                return fn
            }
            return nil
        }

        if Thread.isMainThread {
            return block()
        } else {
            return DispatchQueue.main.sync(execute: block)
        }
    }

    struct PhotosAppTimeZoneInfo {
        let timeZone: TimeZone?
        let originalTimeZone: TimeZone?
        let timeZoneName: String?
        let isAdjusted: Bool
    }

    nonisolated var photosAppTimeZoneInfo: PhotosAppTimeZoneInfo {
        let block = { () -> PhotosAppTimeZoneInfo in
            guard let pl = (self as AnyObject).value(forKey: "pl_managedAsset") as? NSManagedObject else {
                return PhotosAppTimeZoneInfo(timeZone: nil, originalTimeZone: nil, timeZoneName: nil, isAdjusted: false)
            }
            let aa = pl.safeValue(forKey: "additionalAttributes") as? NSManagedObject
            let ext = pl.safeValue(forKey: "extendedAttributes") as? NSManagedObject

            let curOffset = aa?.safeInt(forKey: "timeZoneOffset") ?? aa?.safeInt(forKey: "timezoneOffset")
            let curName = (aa?.safeValue(forKey: "timeZoneName") as? String) ?? (aa?.safeValue(forKey: "timezoneName") as? String)
            let infOffset = aa?.safeInt(forKey: "inferredTimeZoneOffset") ?? aa?.safeInt(forKey: "inferredTimezoneOffset")

            let extOffset = ext?.safeInt(forKey: "timezoneOffset") ?? ext?.safeInt(forKey: "timeZoneOffset")
            let extName = (ext?.safeValue(forKey: "timezoneName") as? String) ?? (ext?.safeValue(forKey: "timeZoneName") as? String)

            let effectiveCurName = (curName?.isEmpty == false) ? curName : extName
            let effectiveCurOffset = curOffset ?? extOffset ?? (infOffset != 0 ? infOffset : nil)

            // Current TimeZone
            var tz: TimeZone? = nil
            if let name = effectiveCurName, !name.isEmpty, let t = TimeZone(identifier: name) {
                tz = t
            } else if let offset = effectiveCurOffset {
                tz = TimeZone(secondsFromGMT: offset)
            }

            // Original TimeZone
            let effectiveExtName = (extName?.isEmpty == false) ? extName : curName
            let effectiveExtOffset = extOffset ?? curOffset ?? (infOffset != 0 ? infOffset : nil)

            var origTz: TimeZone? = nil
            if let name = effectiveExtName, !name.isEmpty, let t = TimeZone(identifier: name) {
                origTz = t
            } else if let offset = effectiveExtOffset {
                origTz = TimeZone(secondsFromGMT: offset)
            }

            // Check if timezone was adjusted in Photos app
            var isAdjusted = false
            if let cur = curOffset, let ext = extOffset, cur != ext {
                isAdjusted = true
            } else if let cur = curOffset, let inf = infOffset, inf != 0, cur != inf {
                isAdjusted = true
            }

            return PhotosAppTimeZoneInfo(
                timeZone: tz,
                originalTimeZone: origTz,
                timeZoneName: effectiveCurName,
                isAdjusted: isAdjusted
            )
        }

        if Thread.isMainThread {
            return block()
        } else {
            return DispatchQueue.main.sync(execute: block)
        }
    }

    /// Retrieve timezone directly from Apple Photos app database via PhotoKit's internal PLManagedAsset
    nonisolated var photosAppTimeZone: TimeZone? {
        photosAppTimeZoneInfo.timeZone
    }

    /// The timezone name string (e.g. "Asia/Shanghai", "America/Chicago") from Apple Photos
    nonisolated var photosAppTimeZoneName: String? {
        photosAppTimeZoneInfo.timeZoneName
    }

    /// The original timezone inferred by Apple Photos (from location or EXIF when imported)
    nonisolated var photosAppOriginalTimeZone: TimeZone? {
        photosAppTimeZoneInfo.originalTimeZone
    }

    /// Check if the photo's date, time, or timezone was adjusted in Apple Photos
    nonisolated var isPhotosAppDateOrTimeZoneAdjusted: Bool {
        if hasAdjustments {
            return true
        }
        if isPhotosAppTimeZoneAdjusted {
            return true
        }
        return false
    }

    /// Check if timezone was adjusted in Photos app (offset differs between current and original extended/inferred offset)
    nonisolated var isPhotosAppTimeZoneAdjusted: Bool {
        photosAppTimeZoneInfo.isAdjusted
    }

    struct PhotosAppExtendedAttributesInfo {
        let originalDate: Date?
        let originalLocation: CLLocation?
        let cameraMake: String?
        let cameraModel: String?
        let lensModel: String?
        let codec: String?
        let duration: Double?
        let fps: Double?
        let originalTimeZoneName: String?
    }

    nonisolated var photosAppExtendedAttributesInfo: PhotosAppExtendedAttributesInfo {
        let block = { () -> PhotosAppExtendedAttributesInfo in
            guard let pl = (self as AnyObject).value(forKey: "pl_managedAsset") as? NSManagedObject,
                  let ext = pl.safeValue(forKey: "extendedAttributes") as? NSManagedObject else {
                return PhotosAppExtendedAttributesInfo(
                    originalDate: nil,
                    originalLocation: nil,
                    cameraMake: nil,
                    cameraModel: nil,
                    lensModel: nil,
                    codec: nil,
                    duration: nil,
                    fps: nil,
                    originalTimeZoneName: nil
                )
            }

            let origDate = ext.safeDate(forKey: "dateCreated")
            let lat = ext.safeDouble(forKey: "latitude")
            let lon = ext.safeDouble(forKey: "longitude")
            var origLoc: CLLocation? = nil
            if let lat = lat, let lon = lon, lat != -180.0 && lon != -180.0 {
                origLoc = CLLocation(latitude: lat, longitude: lon)
            }

            let make = ext.safeValue(forKey: "cameraMake") as? String
            let model = ext.safeValue(forKey: "cameraModel") as? String
            let lens = ext.safeValue(forKey: "lensModel") as? String
            let codec = ext.safeValue(forKey: "codec") as? String
            let dur = ext.safeDouble(forKey: "duration")
            let fps = ext.safeDouble(forKey: "fps")
            let extTzName = (ext.safeValue(forKey: "timezoneName") as? String) ?? (ext.safeValue(forKey: "timeZoneName") as? String)

            return PhotosAppExtendedAttributesInfo(
                originalDate: origDate,
                originalLocation: origLoc,
                cameraMake: make,
                cameraModel: model,
                lensModel: lens,
                codec: codec,
                duration: dur,
                fps: fps,
                originalTimeZoneName: extTzName
            )
        }

        if Thread.isMainThread {
            return block()
        } else {
            return DispatchQueue.main.sync(execute: block)
        }
    }

    struct PhotosAppCombinedMetadata {
        let timeZoneInfo: PhotosAppTimeZoneInfo
        let extendedInfo: PhotosAppExtendedAttributesInfo
    }

    /// Single unified query for both timezone and extended attributes to eliminate redundant main thread round-trips
    nonisolated var photosAppCombinedMetadata: PhotosAppCombinedMetadata {
        let block = { () -> PhotosAppCombinedMetadata in
            guard let pl = (self as AnyObject).value(forKey: "pl_managedAsset") as? NSManagedObject else {
                return PhotosAppCombinedMetadata(
                    timeZoneInfo: PhotosAppTimeZoneInfo(timeZone: nil, originalTimeZone: nil, timeZoneName: nil, isAdjusted: false),
                    extendedInfo: PhotosAppExtendedAttributesInfo(
                        originalDate: nil,
                        originalLocation: nil,
                        cameraMake: nil,
                        cameraModel: nil,
                        lensModel: nil,
                        codec: nil,
                        duration: nil,
                        fps: nil,
                        originalTimeZoneName: nil
                    )
                )
            }

            let aa = pl.safeValue(forKey: "additionalAttributes") as? NSManagedObject
            let ext = pl.safeValue(forKey: "extendedAttributes") as? NSManagedObject

            // 1. Timezone Info
            let curOffset = aa?.safeInt(forKey: "timeZoneOffset") ?? aa?.safeInt(forKey: "timezoneOffset")
            let curName = (aa?.safeValue(forKey: "timeZoneName") as? String) ?? (aa?.safeValue(forKey: "timezoneName") as? String)
            let infOffset = aa?.safeInt(forKey: "inferredTimeZoneOffset") ?? aa?.safeInt(forKey: "inferredTimezoneOffset")

            let extOffset = ext?.safeInt(forKey: "timezoneOffset") ?? ext?.safeInt(forKey: "timeZoneOffset")
            let extName = (ext?.safeValue(forKey: "timezoneName") as? String) ?? (ext?.safeValue(forKey: "timeZoneName") as? String)

            let effectiveCurName = (curName?.isEmpty == false) ? curName : extName
            let effectiveCurOffset = curOffset ?? extOffset ?? (infOffset != 0 ? infOffset : nil)

            var tz: TimeZone? = nil
            if let name = effectiveCurName, !name.isEmpty, let t = TimeZone(identifier: name) {
                tz = t
            } else if let offset = effectiveCurOffset {
                tz = TimeZone(secondsFromGMT: offset)
            }

            let effectiveExtName = (extName?.isEmpty == false) ? extName : curName
            let effectiveExtOffset = extOffset ?? curOffset ?? (infOffset != 0 ? infOffset : nil)

            var origTz: TimeZone? = nil
            if let name = effectiveExtName, !name.isEmpty, let t = TimeZone(identifier: name) {
                origTz = t
            } else if let offset = effectiveExtOffset {
                origTz = TimeZone(secondsFromGMT: offset)
            }

            var isAdjusted = false
            if let cur = curOffset, let ext = extOffset, cur != ext {
                isAdjusted = true
            } else if let cur = curOffset, let inf = infOffset, inf != 0, cur != inf {
                isAdjusted = true
            }

            let tzInfo = PhotosAppTimeZoneInfo(
                timeZone: tz,
                originalTimeZone: origTz,
                timeZoneName: effectiveCurName,
                isAdjusted: isAdjusted
            )

            // 2. Extended Attributes Info
            let origDate = ext?.safeDate(forKey: "dateCreated")
            let lat = ext?.safeDouble(forKey: "latitude")
            let lon = ext?.safeDouble(forKey: "longitude")
            var origLoc: CLLocation? = nil
            if let lat = lat, let lon = lon, lat != -180.0 && lon != -180.0 {
                origLoc = CLLocation(latitude: lat, longitude: lon)
            }

            let make = ext?.safeValue(forKey: "cameraMake") as? String
            let model = ext?.safeValue(forKey: "cameraModel") as? String
            let lens = ext?.safeValue(forKey: "lensModel") as? String
            let codec = ext?.safeValue(forKey: "codec") as? String
            let dur = ext?.safeDouble(forKey: "duration")
            let fps = ext?.safeDouble(forKey: "fps")
            let extTzName = (ext?.safeValue(forKey: "timezoneName") as? String) ?? (ext?.safeValue(forKey: "timeZoneName") as? String)

            let extInfo = PhotosAppExtendedAttributesInfo(
                originalDate: origDate,
                originalLocation: origLoc,
                cameraMake: make,
                cameraModel: model,
                lensModel: lens,
                codec: codec,
                duration: dur,
                fps: fps,
                originalTimeZoneName: extTzName
            )

            return PhotosAppCombinedMetadata(timeZoneInfo: tzInfo, extendedInfo: extInfo)
        }

        if Thread.isMainThread {
            return block()
        } else {
            return DispatchQueue.main.sync(execute: block)
        }
    }
}
