//
//  ExportBatchRunner.swift
//  Photo Exporter
//
//  Shared batch execution, retry, background-task lifecycle, and media-preparation
//  logic used across Samba, Google Drive, and Google Photos export services.
//

import Foundation
import Photos
import UIKit

/// URLSessionDownloadDelegate that forwards byte-level download progress (0.0...1.0).
final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let fallbackTotalBytes: Int64
    private let onProgress: @Sendable (Double) -> Void

    init(expectedBytes: Int64 = 0, onProgress: @escaping @Sendable (Double) -> Void) {
        self.fallbackTotalBytes = expectedBytes
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : fallbackTotalBytes
        guard total > 0 else { return }
        let fraction = min(1.0, max(0.0, Double(totalBytesWritten) / Double(total)))
        onProgress(fraction)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}
}

/// URLSessionTaskDelegate that forwards byte-level upload progress (0.0...1.0).
final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        let fraction = min(1.0, max(0.0, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
        onProgress(fraction)
    }
}

/// Thread-safe throttler for intra-item progress updates.
/// Emits UI progress immediately (`>= 1%` or `>= 0.25s`) while gating background task notification
/// intra-item updates behind a 10-second per-item delay (`>= 1%` or `>= 0.5s`).
private final class ItemProgressThrottler: @unchecked Sendable {
    private let lock = NSLock()
    private var itemStartTime: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    private var lastUIFraction: Double = -1.0
    private var lastUIUpdateTime: CFAbsoluteTime = 0
    private var lastBGFraction: Double = 0.0
    private var lastBGUpdateTime: CFAbsoluteTime = 0

    func shouldEmit(fraction: Double) -> (ui: Double, background: Double)? {
        let clamped = min(max(fraction, 0.0), 0.999)
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        defer { lock.unlock() }

        let uiDelta = clamped - lastUIFraction
        let uiElapsed = now - lastUIUpdateTime
        guard lastUIFraction < 0 || uiDelta >= 0.01 || (uiDelta > 0 && uiElapsed >= 0.25) else {
            return nil
        }
        lastUIFraction = clamped
        lastUIUpdateTime = now

        if now - itemStartTime >= 10.0 {
            let bgDelta = clamped - lastBGFraction
            let bgElapsed = now - lastBGUpdateTime
            if bgDelta >= 0.01 || (bgDelta > 0 && bgElapsed >= 0.5) {
                lastBGFraction = clamped
                lastBGUpdateTime = now
            }
        }
        return (ui: clamped, background: lastBGFraction)
    }

    func reset() {
        lock.lock()
        itemStartTime = CFAbsoluteTimeGetCurrent()
        lastUIFraction = -1.0
        lastUIUpdateTime = 0
        lastBGFraction = 0.0
        lastBGUpdateTime = 0
        lock.unlock()
    }
}

enum ExportBatchRunner {
    /// Prepares a local media file at `destinationURL` with adjusted EXIF/video metadata and timestamps.
    static func prepareMediaFile(
        for item: PhotoItem,
        destinationURL: URL,
        libraryService: PhotoLibraryService = .shared,
        exifService: ExifMetadataService = .shared,
        sourceMediaSource: MediaSource = .photoLibrary,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        let fileManager = FileManager.default
        let shouldWriteDateTime = item.isDateAdjusted || item.hasInferredTimeZone || (item.isVideo && item.isDrifted)
        let shouldEmbedMetadata = shouldWriteDateTime || item.isGPSAdjusted
        let targetDate = item.creationDate ?? item.embeddedDate

        guard let asset = item.asset else {
            guard sourceMediaSource.isFolder else {
                throw NSError(domain: "ExportBatchRunner", code: -10, userInfo: [NSLocalizedDescriptionKey: "Missing PHAsset for \(item.filename)"])
            }
            let tempSrcURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString + "_" + item.filename)
            defer {
                try? fileManager.removeItem(at: tempSrcURL)
            }
            try await FolderMediaService.shared.downloadOrCopySourceFile(
                for: item,
                in: sourceMediaSource,
                to: tempSrcURL,
                progressHandler: progressHandler.map { handler in
                    { fraction in handler(fraction * 0.5) }
                }
            )
            progressHandler?(0.5)

            if fileManager.fileExists(atPath: destinationURL.path) {
                try? fileManager.removeItem(at: destinationURL)
            }

            let rotationSteps = ExifMetadataService.clockwiseSteps(forDegrees: item.pendingRotationDegrees)
            if shouldEmbedMetadata || rotationSteps != 0 {
                if item.isVideo {
                    try await exifService.embedAdjustedVideoMetadata(
                        sourceURL: tempSrcURL,
                        destinationURL: destinationURL,
                        targetDate: shouldWriteDateTime ? targetDate : nil,
                        timeZone: item.timeZone,
                        adjustedLocation: item.isGPSAdjusted ? item.location : nil,
                        isGPSAdjusted: item.isGPSAdjusted,
                        videoTakenDate: targetDate,
                        fallbackLocation: item.location,
                        clockwiseRotationSteps: rotationSteps
                    )
                } else {
                    let rawData = try Data(contentsOf: tempSrcURL)
                    let modifiedData = try exifService.embedAdjustedMetadata(
                        imageData: rawData,
                        targetDate: shouldWriteDateTime ? targetDate : nil,
                        timeZone: item.timeZone,
                        adjustedLocation: item.isGPSAdjusted ? item.location : nil,
                        isGPSAdjusted: item.isGPSAdjusted,
                        clockwiseRotationSteps: rotationSteps
                    )
                    try modifiedData.write(to: destinationURL, options: .atomic)
                }
            } else {
                try fileManager.copyItem(at: tempSrcURL, to: destinationURL)
            }

            if let photoDate = targetDate ?? item.fileModificationDate {
                try? fileManager.setAttributes(
                    [.creationDate: photoDate, .modificationDate: photoDate],
                    ofItemAtPath: destinationURL.path
                )
            }
            progressHandler?(1.0)
            return
        }

        if item.isVideo {
            let tempSrcURL = try await libraryService.fetchLocalFileURL(for: asset)
            defer {
                try? fileManager.removeItem(at: tempSrcURL)
            }
            progressHandler?(0.35)

            if fileManager.fileExists(atPath: destinationURL.path) {
                try? fileManager.removeItem(at: destinationURL)
            }

            if shouldEmbedMetadata || asset.hasAdjustments {
                try await exifService.embedAdjustedVideoMetadata(
                    sourceURL: tempSrcURL,
                    destinationURL: destinationURL,
                    targetDate: shouldWriteDateTime ? targetDate : nil,
                    timeZone: item.timeZone,
                    adjustedLocation: item.isGPSAdjusted ? item.location : nil,
                    isGPSAdjusted: item.isGPSAdjusted,
                    videoTakenDate: targetDate,
                    fallbackLocation: item.location
                )
            } else {
                try fileManager.copyItem(at: tempSrcURL, to: destinationURL)
            }
            progressHandler?(1.0)
        } else {
            let fetchResult = try await libraryService.fetchImageData(for: asset, preferEdited: true)
            var finalImageData = fetchResult.data

            if shouldEmbedMetadata {
                finalImageData = try exifService.embedAdjustedMetadata(
                    imageData: finalImageData,
                    targetDate: shouldWriteDateTime ? targetDate : nil,
                    timeZone: item.timeZone,
                    adjustedLocation: item.isGPSAdjusted ? item.location : nil,
                    isGPSAdjusted: item.isGPSAdjusted
                )
            }

            try finalImageData.write(to: destinationURL, options: .atomic)
        }

        if let photoDate = targetDate ?? asset.creationDate {
            try? fileManager.setAttributes(
                [.creationDate: photoDate, .modificationDate: photoDate],
                ofItemAtPath: destinationURL.path
            )
        }
    }

    /// Builds and reports an early-failure ExportProgress when pre-flight connection or auth fails.
    static func earlyFailureProgress(
        items: [PhotoItem],
        totalBatchCount: Int? = nil,
        initialSuccessfulItems: [PhotoItem] = [],
        isApplyInPlace: Bool = false,
        errorMessage: String,
        progressHandler: @escaping (ExportProgress) -> Void
    ) -> ExportProgress {
        let effectiveTotal = totalBatchCount ?? items.count
        let baseSuccess = initialSuccessfulItems.count
        let progress = ExportProgress(
            isExporting: false,
            totalCount: effectiveTotal,
            currentItemIndex: baseSuccess,
            currentFilename: "",
            successCount: baseSuccess,
            failureCount: items.count,
            destinationURL: nil,
            errorMessages: [errorMessage],
            failedItems: items.sortedChronologicallyAscending(),
            successfulItems: initialSuccessfulItems,
            isCancelled: false,
            isCompleted: true,
            isApplyInPlace: isApplyInPlace
        )
        progressHandler(progress)
        return progress
    }

    /// Runs a batch export over `items` with background task protection, cancellation handling,
    /// retries, and uniform progress reporting.
    static func runRemoteBatch(
        serviceName: String,
        items: [PhotoItem],
        totalBatchCount: Int? = nil,
        initialSuccessfulItems: [PhotoItem] = [],
        isApplyInPlace: Bool = false,
        maxAttempts: Int = 3,
        progressHandler: @escaping (ExportProgress) -> Void,
        onCancel: (() -> Void)? = nil,
        onCleanupCancelledItem: ((_ item: PhotoItem) async -> Void)? = nil,
        onAttemptError: ((_ error: Error, _ item: PhotoItem, _ attempt: Int, _ maxAttempts: Int) async -> Bool)? = nil,
        exportItem: (_ item: PhotoItem, _ itemProgressHandler: @escaping @Sendable (Double) -> Void) async throws -> Void
    ) async -> ExportProgress {
        let effectiveTotal = totalBatchCount ?? items.count
        let baseSuccess = initialSuccessfulItems.count

        var progress = ExportProgress(
            isExporting: true,
            totalCount: effectiveTotal,
            currentItemIndex: baseSuccess,
            currentFilename: "",
            successCount: baseSuccess,
            failureCount: 0,
            destinationURL: nil,
            errorMessages: [],
            failedItems: [],
            successfulItems: initialSuccessfulItems,
            isCancelled: false,
            isCompleted: false,
            isApplyInPlace: isApplyInPlace
        )

        var bgTaskID: UIBackgroundTaskIdentifier = .invalid
        bgTaskID = UIApplication.shared.beginBackgroundTask(withName: serviceName) {
            if bgTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(bgTaskID)
                bgTaskID = .invalid
            }
        }
        defer {
            if bgTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(bgTaskID)
                bgTaskID = .invalid
            }
        }

        let sortedItems = items.sortedChronologicallyAscending()
        for (index, item) in sortedItems.enumerated() {
            if Task.isCancelled || progress.isCancelled {
                onCancel?()
                progress.isCancelled = true
                progress.isExporting = false
                progressHandler(progress)
                return progress
            }

            progress.currentItemIndex = baseSuccess + index + 1
            progress.currentFilename = item.filename
            progress.currentItem = item
            progress.currentItemProgress = 0.0
            progress.backgroundItemProgress = 0.0
            progressHandler(progress)

            var attempts = 0
            var lastError: Error? = nil
            let throttler = ItemProgressThrottler()

            while attempts < maxAttempts {
                attempts += 1
                throttler.reset()
                let baseProgress = progress
                let itemProgressCallback: @Sendable (Double) -> Void = { fraction in
                    guard let emitted = throttler.shouldEmit(fraction: fraction) else { return }
                    var snapshot = baseProgress
                    snapshot.currentItemProgress = emitted.ui
                    snapshot.backgroundItemProgress = emitted.background
                    progressHandler(snapshot)
                }

                do {
                    try await exportItem(item, itemProgressCallback)
                    progress.successCount += 1
                    progress.successfulItems.append(item)
                    progress.currentItemProgress = 0.0
                    progress.backgroundItemProgress = 0.0
                    lastError = nil
                    break
                } catch {
                    if isCancellationError(error) || Task.isCancelled || progress.isCancelled {
                        onCancel?()
                        await onCleanupCancelledItem?(item)
                        progress.isCancelled = true
                        progress.isExporting = false
                        progress.currentItemProgress = 0.0
                        progress.backgroundItemProgress = 0.0
                        progressHandler(progress)
                        return progress
                    }

                    lastError = error

                    if let shouldRetryImmediately = await onAttemptError?(error, item, attempts, maxAttempts),
                       shouldRetryImmediately,
                       attempts < maxAttempts {
                        continue
                    }

                    if isRetryableExportError(error) && attempts < maxAttempts {
                        print("Retryable error exporting \(item.filename) to \(serviceName) (attempt \(attempts)/\(maxAttempts)): \(error.localizedDescription). Retrying...")
                        try? await Task.sleep(nanoseconds: UInt64(attempts) * 1_000_000_000)
                        continue
                    } else {
                        break
                    }
                }
            }

            if let error = lastError {
                progress.failureCount += 1
                progress.failedItems.append(item)
                progress.errorMessages.append("\(item.filename): \(error.localizedDescription)")
                print("Failed to export \(item.filename) to \(serviceName): \(error.localizedDescription)")
            }

            progress.currentItemProgress = 0.0
            progress.backgroundItemProgress = 0.0
            progressHandler(progress)
        }

        progress.isExporting = false
        progress.isCompleted = true
        progressHandler(progress)
        return progress
    }

    /// Checks whether an error represents task or URLSession cancellation.
    static func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    /// Checks whether `error` indicates a 401/unauthorized/invalid_grant OAuth failure.
    static func isUnauthorizedError(_ error: Error) -> Bool {
        let errDesc = error.localizedDescription.lowercased()
        return errDesc.contains("401") ||
            errDesc.contains("unauthorized") ||
            errDesc.contains("unauthenticated") ||
            errDesc.contains("invalid credentials") ||
            errDesc.contains("invalid_grant")
    }
}
