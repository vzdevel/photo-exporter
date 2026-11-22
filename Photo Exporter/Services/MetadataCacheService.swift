//
//  MetadataCacheService.swift
//  Photo Exporter
//
//  Created by Antigravity on 2026-11-01.
//

import Foundation
import CoreLocation
import CryptoKit
import UIKit

/// Stored metadata entry for an analyzed photo or video
struct CachedMetadataEntry: Codable {
    var modificationDate: Date?
    var hasAdjustments: Bool
    var embeddedDate: Date?
    var adjustedDate: Date? = nil
    var isDateAdjusted: Bool
    var isGPSAdjusted: Bool
    var pendingRotationDegrees: Int? = nil
    var isFromOtherApps: Bool
    var hasEmbeddedTimeZone: Bool
    var isDrifted: Bool? = nil
    var originalFilename: String?
    var fileSize: Int64? = nil
    var timeZoneIdentifier: String? = nil
    var timeZoneSecondsFromGMT: Int? = nil
    var pixelWidth: Int? = nil
    var pixelHeight: Int? = nil
    var duration: TimeInterval? = nil
    var latitude: Double? = nil
    var longitude: Double? = nil
}

/// Stored photo list item for immediate list view display on app startup
struct CachedPhotoListItem: Codable {
    var id: String
    var filename: String
    var creationDate: Date?
    var embeddedDate: Date?
    var timeZoneIdentifier: String?
    var timeZoneSecondsFromGMT: Int
    var isDateAdjusted: Bool
    var isGPSAdjusted: Bool
    var pendingRotationDegrees: Int? = nil
    var isSavedFromOtherApps: Bool
    var isEdited: Bool
    var pixelWidth: Int
    var pixelHeight: Int
    var duration: TimeInterval?
    var hasEmbeddedTimeZone: Bool
    var isDrifted: Bool? = nil
    var isAnalyzed: Bool
    var subfolderPath: String
    var fileSize: Int64?
    var latitude: Double?
    var longitude: Double?
    var fileModificationDate: Date? = nil
    var isVideoFile: Bool? = nil
    var remoteFileID: String? = nil
    var remoteThumbnailLink: String? = nil
}

/// Persisted export destination target so "Retry Failed" works across app restarts
enum PersistedExportTarget: Codable {
    case local(bookmarkData: Data?, fallbackPath: String)
    case googleDrive(folderId: String, folderName: String, accountID: String?)
    case samba(SambaDestination)
    case googlePhotos(account: GoogleAccount)
}

/// Persisted export state (in-progress checkpoints & final errors) across app restarts
struct PersistedExportErrorState: Codable {
    var isInProgress: Bool = false
    var totalCount: Int
    var successCount: Int
    var failureCount: Int
    var destinationPath: String?
    var errorMessages: [String]
    var failedItems: [CachedPhotoListItem]
    var successfulItems: [CachedPhotoListItem]
    var remainingItems: [CachedPhotoListItem] = []
    var totalBatchCount: Int
    var target: PersistedExportTarget?
}

/// Service for persisting analyzed photo metadata and media list in Application Support
final class MetadataCacheService {
    static let shared = MetadataCacheService()

    private let fileManager = FileManager.default
    private let fileName = "analyzed_photo_metadata_v7.json"
    private let listCacheFileName = "cached_photo_list_v4.json"
    private let exportErrorsFileName = "persisted_export_errors_v1.json"
    private let cacheTTL: TimeInterval = 30 * 24 * 60 * 60
    private let queue = DispatchQueue(label: "com.photoexporter.metadata.cache", qos: .utility)

    private struct CacheContainer: Codable {
        var entries: [String: CachedMetadataEntry]
    }

    private struct PersistentMediaListContainer: Codable {
        var items: [CachedPhotoListItem]
        var filterCounts: [String: Int]
    }

    private func appSupportFileURL(named name: String) -> URL {
        let appSupportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        if !fileManager.fileExists(atPath: appSupportDir.path) {
            try? fileManager.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        }
        return appSupportDir.appendingPathComponent(name)
    }

    private var cacheFileURL: URL { appSupportFileURL(named: fileName) }
    private var listCacheFileURL: URL { appSupportFileURL(named: listCacheFileName) }
    private var exportErrorsFileURL: URL { appSupportFileURL(named: exportErrorsFileName) }

    private func cacheFileURL(for sourceKey: String) -> URL {
        if sourceKey == MediaSource.photoLibrary.sourceKey {
            return cacheFileURL
        }
        return folderCacheFileURL(for: sourceKey, suffix: "metadata_v1.json")
    }

    private func listCacheFileURL(for sourceKey: String) -> URL {
        if sourceKey == MediaSource.photoLibrary.sourceKey {
            return listCacheFileURL
        }
        return folderCacheFileURL(for: sourceKey, suffix: "list_v1.json")
    }

    private func folderCacheFileURL(for sourceKey: String, suffix: String) -> URL {
        let appSupportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folderDir = appSupportDir.appendingPathComponent("FolderCaches", isDirectory: true)
        if !fileManager.fileExists(atPath: folderDir.path) {
            try? fileManager.createDirectory(at: folderDir, withIntermediateDirectories: true)
        }
        let digest = SHA256.hash(data: Data(sourceKey.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return folderDir.appendingPathComponent("\(hex)_\(suffix)")
    }

    private init() {}

    /// Returns true if the cache file exists and its modification date is older than the 30-day TTL, removing it if expired.
    @discardableResult
    private func removeIfExpired(at url: URL, now: Date = Date()) -> Bool {
        guard fileManager.fileExists(atPath: url.path) else { return false }
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        guard let modifiedDate = values?.contentModificationDate else { return false }
        guard now.timeIntervalSince(modifiedDate) > cacheTTL else { return false }
        try? fileManager.removeItem(at: url)
        return true
    }

    /// Load the persistent metadata cache from disk for the given source
    func loadCache(for sourceKey: String = MediaSource.photoLibrary.sourceKey) -> [String: CachedMetadataEntry] {
        let url = cacheFileURL(for: sourceKey)
        guard fileManager.fileExists(atPath: url.path) else { return [:] }
        if sourceKey != MediaSource.photoLibrary.sourceKey && removeIfExpired(at: url) {
            return [:]
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            let container = try decoder.decode(CacheContainer.self, from: data)
            return container.entries
        } catch {
            print("Failed to decode metadata cache: \(error.localizedDescription)")
            return [:]
        }
    }

    /// Save the metadata cache to disk asynchronously on a background queue with background task protection
    func saveCache(_ cache: [String: CachedMetadataEntry], for sourceKey: String = MediaSource.photoLibrary.sourceKey) {
        let targetURL = cacheFileURL(for: sourceKey)
        var bgTask: UIBackgroundTaskIdentifier = .invalid
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "SaveMetadataCache") {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }

        queue.async {
            defer {
                if bgTask != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTask)
                    bgTask = .invalid
                }
            }
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .secondsSince1970
                let container = CacheContainer(entries: cache)
                let data = try encoder.encode(container)
                try data.write(to: targetURL, options: .atomic)
            } catch {
                print("Failed to save metadata cache: \(error.localizedDescription)")
            }
        }
    }

    /// Load persisted photo list items for instant display upon startup or source switch
    func loadPersistedList(for sourceKey: String = MediaSource.photoLibrary.sourceKey) -> (items: [CachedPhotoListItem], filterCounts: [String: Int]) {
        let url = listCacheFileURL(for: sourceKey)
        guard fileManager.fileExists(atPath: url.path) else { return ([], [:]) }
        if sourceKey != MediaSource.photoLibrary.sourceKey && removeIfExpired(at: url) {
            return ([], [:])
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            let container = try decoder.decode(PersistentMediaListContainer.self, from: data)
            return (container.items, container.filterCounts)
        } catch {
            print("Failed to decode persisted photo list: \(error.localizedDescription)")
            return ([], [:])
        }
    }

    static func cachedPhotoListItem(from item: PhotoItem) -> CachedPhotoListItem {
        CachedPhotoListItem(
            id: item.id,
            filename: item.filename,
            creationDate: item.creationDate,
            embeddedDate: item.embeddedDate,
            timeZoneIdentifier: item.timeZone.identifier,
            timeZoneSecondsFromGMT: item.timeZone.secondsFromGMT(for: item.creationDate ?? Date()),
            isDateAdjusted: item.isDateAdjusted,
            isGPSAdjusted: item.isGPSAdjusted,
            pendingRotationDegrees: item.pendingRotationDegrees > 0 ? item.pendingRotationDegrees : nil,
            isSavedFromOtherApps: item.isSavedFromOtherApps,
            isEdited: item.isEdited,
            pixelWidth: item.pixelWidth,
            pixelHeight: item.pixelHeight,
            duration: item.duration,
            hasEmbeddedTimeZone: item.hasEmbeddedTimeZone,
            isDrifted: item.isDrifted,
            isAnalyzed: item.isAnalyzed,
            subfolderPath: item.subfolderPath,
            fileSize: item.fileSize,
            latitude: item.location?.coordinate.latitude,
            longitude: item.location?.coordinate.longitude,
            fileModificationDate: item.fileModificationDate,
            isVideoFile: item.isVideoFile,
            remoteFileID: item.remoteFileID,
            remoteThumbnailLink: item.remoteThumbnailLink
        )
    }

    /// Save the current list of photo items and filter counts to disk asynchronously with background task protection
    func savePersistedList(items: [PhotoItem], filterCounts: [String: Int], for sourceKey: String = MediaSource.photoLibrary.sourceKey) {
        let targetURL = listCacheFileURL(for: sourceKey)
        let cachedItems: [CachedPhotoListItem] = items.map { Self.cachedPhotoListItem(from: $0) }

        let container = PersistentMediaListContainer(items: cachedItems, filterCounts: filterCounts)

        var bgTask: UIBackgroundTaskIdentifier = .invalid
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "SavePersistedList") {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }

        queue.async {
            defer {
                if bgTask != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTask)
                    bgTask = .invalid
                }
            }
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .secondsSince1970
                let data = try encoder.encode(container)
                try data.write(to: targetURL, options: .atomic)
            } catch {
                print("Failed to save persisted photo list: \(error.localizedDescription)")
            }
        }
    }

    /// Synchronously wait for all pending disk writes to complete (e.g. before app enters background)
    func flushSync() {
        queue.sync {}
    }

    /// Synchronously clear the persistent metadata cache from disk for a source
    func clearCache(for sourceKey: String = MediaSource.photoLibrary.sourceKey) {
        let metaURL = cacheFileURL(for: sourceKey)
        let listURL = listCacheFileURL(for: sourceKey)
        queue.sync { [weak self] in
            guard let self = self else { return }
            if self.fileManager.fileExists(atPath: metaURL.path) {
                try? self.fileManager.removeItem(at: metaURL)
            }
            if self.fileManager.fileExists(atPath: listURL.path) {
                try? self.fileManager.removeItem(at: listURL)
            }
        }
    }

    // MARK: - Persisted Export Errors

    func savePersistedExportErrorState(_ state: PersistedExportErrorState) {
        var bgTask: UIBackgroundTaskIdentifier = .invalid
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "SaveExportState") {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }

        queue.async { [weak self] in
            defer {
                if bgTask != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTask)
                    bgTask = .invalid
                }
            }
            guard let self = self else { return }
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .secondsSince1970
                let data = try encoder.encode(state)
                try data.write(to: self.exportErrorsFileURL, options: .atomic)
            } catch {
                print("Failed to save persisted export error state: \(error.localizedDescription)")
            }
        }
    }

    func loadPersistedExportErrorState() -> PersistedExportErrorState? {
        queue.sync { [weak self] in
            guard let self = self else { return nil }
            let url = self.exportErrorsFileURL
            guard self.fileManager.fileExists(atPath: url.path) else { return nil }
            do {
                let data = try Data(contentsOf: url)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .secondsSince1970
                return try decoder.decode(PersistedExportErrorState.self, from: data)
            } catch {
                print("Failed to decode persisted export error state: \(error.localizedDescription)")
                return nil
            }
        }
    }

    func clearPersistedExportErrorState() {
        queue.sync { [weak self] in
            guard let self = self else { return }
            let url = self.exportErrorsFileURL
            if self.fileManager.fileExists(atPath: url.path) {
                try? self.fileManager.removeItem(at: url)
            }
        }
    }

    // MARK: - Startup Storage Sweep

    /// Sweeps orphaned temporary files from prior sessions, stale debug artifacts, and metadata caches older than 30 days.
    func performStartupStorageSweep(launchedAt: Date = Date()) {
        queue.async { [weak self] in
            guard let self else { return }
            self.sweepTemporaryDirectory(before: launchedAt)
            self.sweepExpiredMetadataCaches(now: launchedAt)
            self.sweepObsoleteDebugArtifacts()
        }
    }

    private func sweepTemporaryDirectory(before cutoff: Date) {
        let tempDir = fileManager.temporaryDirectory
        let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .contentModificationDateKey]
        guard let entries = try? fileManager.contentsOfDirectory(
            at: tempDir,
            includingPropertiesForKeys: keys,
            options: []
        ) else { return }

        let fallbackCutoff = cutoff.addingTimeInterval(-60)
        for entryURL in entries {
            let values = try? entryURL.resourceValues(forKeys: Set(keys))
            let shouldRemove: Bool
            if let addedDate = values?.addedToDirectoryDate {
                shouldRemove = addedDate < cutoff
            } else {
                shouldRemove = (values?.contentModificationDate ?? .distantPast) < fallbackCutoff
            }
            if shouldRemove {
                try? fileManager.removeItem(at: entryURL)
            }
        }
    }

    /// Expires per-folder/remote caches in FolderCaches older than 30 days while preserving the Photo Library cache.
    private func sweepExpiredMetadataCaches(now: Date) {
        guard let appSupportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let folderCachesDir = appSupportDir.appendingPathComponent("FolderCaches", isDirectory: true)
        if let folderEntries = try? fileManager.contentsOfDirectory(
            at: folderCachesDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            for url in folderEntries {
                removeIfExpired(at: url, now: now)
            }
        }
    }

    private func sweepObsoleteDebugArtifacts() {
        guard let docsDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        guard let entries = try? fileManager.contentsOfDirectory(
            at: docsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        for url in entries {
            let name = url.lastPathComponent
            if name == "nav_debug.log" || name == "av_hierarchy.txt" || (name.hasPrefix("debug_edits_") && name.hasSuffix(".json")) {
                try? fileManager.removeItem(at: url)
            }
        }
    }
}

