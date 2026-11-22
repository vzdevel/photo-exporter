//
//  ExportService.swift
//  Photo Exporter
//

import Foundation
import Photos
import UIKit

/// Strategy for handling filename conflicts in the target directory
enum ExportConflictResolution {
    case overwrite
    case skip
    case makeUnique
}

/// Service handling the batch export of photos with EXIF date/time and timezone embedding
final class ExportService {
    static let shared = ExportService()

    private let libraryService = PhotoLibraryService.shared
    private let exifService = ExifMetadataService.shared

    private init() {}

    /// Fetch existing files in destination directory with metadata (modification date and file size)
    func fetchDestinationFiles(in destinationURL: URL, subfolderPath: String = "") -> [DestinationFileInfo] {
        let isSecurityScoped = destinationURL.startAccessingSecurityScopedResource()
        defer {
            if isSecurityScoped {
                destinationURL.stopAccessingSecurityScopedResource()
            }
        }

        let targetURL = subfolderPath.isEmpty ? destinationURL : destinationURL.appendingPathComponent(subfolderPath)

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: targetURL.path),
              let fileURLs = try? fileManager.contentsOfDirectory(
            at: targetURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [DestinationFileInfo] = []
        for fileURL in fileURLs {
            guard let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey]),
                  values.isDirectory != true else { continue }
            let name = fileURL.lastPathComponent
            let modDate = values.contentModificationDate
            let size = Int64(values.fileSize ?? 0)
            // Ignore 0-byte destination files and treat them as non-existent so they are simply overridden
            guard size > 0 else { continue }
            results.append(DestinationFileInfo(
                id: fileURL.path,
                filename: name,
                modificationDate: modDate,
                fileSize: size,
                thumbnailLink: nil,
                subfolderPath: subfolderPath
            ))
        }
        return results
    }

    /// Export selected photo items to a target directory URL
    func exportPhotos(
        items: [PhotoItem],
        to destinationURL: URL,
        conflictResolution: ExportConflictResolution = .overwrite,
        sourceMediaSource: MediaSource = .photoLibrary,
        totalBatchCount: Int? = nil,
        initialSuccessfulItems: [PhotoItem] = [],
        progressHandler: @escaping (ExportProgress) -> Void
    ) async -> ExportProgress {
        var bgTaskID: UIBackgroundTaskIdentifier = .invalid
        bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "LocalExport") {
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

        let isSecurityScoped = destinationURL.startAccessingSecurityScopedResource()
        defer {
            if isSecurityScoped {
                destinationURL.stopAccessingSecurityScopedResource()
            }
        }

        let fileManager = FileManager.default

        // Process items chronologically ascending (oldest first)
        var itemsToProcess = items.sortedChronologicallyAscending()
        if conflictResolution == .skip {
            itemsToProcess = itemsToProcess.filter { item in
                let effectiveDir = item.subfolderPath.isEmpty ? destinationURL : destinationURL.appendingPathComponent(item.subfolderPath)
                let targetURL = effectiveDir.appendingPathComponent(item.filename)
                guard fileManager.fileExists(atPath: targetURL.path) else { return true }
                let size = (try? fileManager.attributesOfItem(atPath: targetURL.path)[.size] as? Int64) ?? 0
                // If destination file has 0 bytes, do not skip: simply override it
                return size <= 0
            }
        }

        let effectiveTotal = totalBatchCount ?? itemsToProcess.count
        let baseSuccess = initialSuccessfulItems.count

        var progress = ExportProgress(
            isExporting: true,
            totalCount: effectiveTotal,
            currentItemIndex: baseSuccess,
            currentFilename: "",
            successCount: baseSuccess,
            failureCount: 0,
            destinationURL: destinationURL,
            errorMessages: [],
            failedItems: [],
            successfulItems: initialSuccessfulItems,
            isCancelled: false,
            isCompleted: false
        )

        for (index, item) in itemsToProcess.enumerated() {
            // Check for task cancellation
            if Task.isCancelled || progress.isCancelled {
                progress.isCancelled = true
                progress.isExporting = false
                progressHandler(progress)
                return progress
            }

            progress.currentItemIndex = baseSuccess + index + 1
            progress.currentFilename = item.filename
            progress.currentItem = item
            progressHandler(progress)

            let effectiveDirURL: URL
            if !item.subfolderPath.isEmpty {
                effectiveDirURL = destinationURL.appendingPathComponent(item.subfolderPath)
                if !fileManager.fileExists(atPath: effectiveDirURL.path) {
                    try? fileManager.createDirectory(at: effectiveDirURL, withIntermediateDirectories: true)
                }
            } else {
                effectiveDirURL = destinationURL
            }

            // Always override existing or partial files; renaming happens only pre-export in ExportSummarySheet
            let targetFileURL = effectiveDirURL.appendingPathComponent(item.filename)

            var attempts = 0
            let maxAttempts = 3
            var lastError: Error? = nil

            while attempts < maxAttempts {
                attempts += 1
                do {
                    if fileManager.fileExists(atPath: targetFileURL.path) {
                        try? fileManager.removeItem(at: targetFileURL)
                    }

                    try await ExportBatchRunner.prepareMediaFile(
                        for: item,
                        destinationURL: targetFileURL,
                        libraryService: libraryService,
                        exifService: exifService,
                        sourceMediaSource: sourceMediaSource
                    )

                    progress.successCount += 1
                    progress.successfulItems.append(item)
                    lastError = nil
                    break
                } catch {
                    // If a partial file was created before failure, remove it to avoid leaving corrupt partial files
                    if fileManager.fileExists(atPath: targetFileURL.path) {
                        try? fileManager.removeItem(at: targetFileURL)
                    }

                    if Task.isCancelled || progress.isCancelled || (error as? CancellationError) != nil {
                        progress.isCancelled = true
                        progress.isExporting = false
                        progressHandler(progress)
                        return progress
                    }

                    lastError = error

                    if isRetryableExportError(error) && attempts < maxAttempts {
                        print("Retryable error exporting \(item.filename) (attempt \(attempts)/\(maxAttempts)): \(error.localizedDescription). Retrying...")
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
            }

            progressHandler(progress)
        }

        progress.isExporting = false
        progress.isCompleted = true
        progressHandler(progress)

        return progress
    }
}
