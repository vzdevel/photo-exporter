//
//  PhotoItem.swift
//  Photo Exporter
//

import Foundation
import Photos
import SwiftUI

/// Represents a photo item displayed in the main list
struct PhotoItem: Identifiable, Hashable {
    let id: String
    let asset: PHAsset?
    let filename: String
    let fileExtension: String
    let creationDate: Date?
    let embeddedDate: Date?
    let timeZone: TimeZone
    let isDateAdjusted: Bool
    let isGPSAdjusted: Bool
    let pendingRotationDegrees: Int
    let isSavedFromOtherApps: Bool
    let isEdited: Bool
    let pixelWidth: Int
    let pixelHeight: Int
    let location: CLLocation?
    let duration: TimeInterval?
    let hasEmbeddedTimeZone: Bool
    let isDrifted: Bool
    let isAnalyzed: Bool
    let subfolderPath: String
    let fileSize: Int64?
    let fileModificationDate: Date?
    let isVideoFile: Bool
    let localFileURL: URL?
    let remoteFileID: String?
    let remoteThumbnailLink: String?
    let sourceFilename: String?
    let sourceSubfolderPath: String?

    var effectiveSourceFilename: String { sourceFilename ?? filename }
    var effectiveSourceSubfolderPath: String { sourceSubfolderPath ?? subfolderPath }

    var isFolderItem: Bool {
        asset == nil
    }

    var modificationDate: Date? {
        asset?.modificationDate ?? fileModificationDate
    }

    var isVideo: Bool {
        if let asset {
            return asset.mediaType == .video
        }
        return isVideoFile
    }

    var isScreenshot: Bool {
        (asset?.mediaSubtypes.contains(.photoScreenshot) ?? false) || filename.lowercased().hasPrefix("screenshot")
    }

    var isPhoto: Bool {
        !isVideo && !isScreenshot
    }

    /// True when an item in a folder has pending inferred timezone, adjustments, rotation, or drifted video timestamps to apply in place
    var needsInPlaceApply: Bool {
        hasInferredTimeZone || isDateAdjusted || isGPSAdjusted || isRotationAdjusted || (isVideo && isDrifted)
    }

    static let supportedImageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "dng", "tiff", "tif", "bmp"
    ]
    static let supportedVideoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "avi", "mkv", "wmv", "3gp"
    ]

    static func isVideoFilename(_ filename: String) -> Bool {
        let ext = (filename as NSString).pathExtension.lowercased()
        return supportedVideoExtensions.contains(ext)
    }

    static func isSupportedMediaFilename(_ filename: String) -> Bool {
        let ext = (filename as NSString).pathExtension.lowercased()
        return supportedImageExtensions.contains(ext) || supportedVideoExtensions.contains(ext)
    }

    /// Counts supported image and video filenames in a sequence
    static func countMediaFilenames<S: Sequence>(_ filenames: S) -> (images: Int, videos: Int) where S.Element == String {
        var images = 0
        var videos = 0
        for filename in filenames {
            guard isSupportedMediaFilename(filename) else { continue }
            if isVideoFilename(filename) {
                videos += 1
            } else {
                images += 1
            }
        }
        return (images, videos)
    }

    /// Effective file size in bytes, falling back to asset resource metadata if not already analyzed
    var effectiveFileSize: Int64? {
        if let size = fileSize, size > 0 {
            return size
        }
        if asset != nil {
            let fallback = ExportDeduplicationEngine.getDeviceFileSize(for: self)
            return fallback > 0 ? fallback : nil
        }
        return nil
    }

    /// Check if this photo matches the given media type filter
    func matches(mediaType: MediaTypeFilter) -> Bool {
        switch mediaType {
        case .all:
            return true
        case .photos:
            return isPhoto
        case .videos:
            return isVideo
        case .screenshots:
            return isScreenshot
        }
    }

    /// True if either date/time/timezone, GPS location, or pending folder rotation was adjusted
    var isAdjusted: Bool {
        isDateAdjusted || isGPSAdjusted || isRotationAdjusted
    }

    /// True when a folder item has an unapplied pending rotation (90°, 180°, or 270°)
    var isRotationAdjusted: Bool {
        ((pendingRotationDegrees % 360) + 360) % 360 != 0
    }

    /// True if timezone was inferred (only after photo is analyzed, with no embedded timezone and no adjusted date, time, or timezone)
    var hasInferredTimeZone: Bool {
        isAnalyzed && !hasEmbeddedTimeZone && !isDateAdjusted
    }

    init(
        asset: PHAsset,
        filename: String? = nil,
        creationDate: Date? = nil,
        embeddedDate: Date? = nil,
        timeZone: TimeZone = .current,
        isDateAdjusted: Bool = false,
        isGPSAdjusted: Bool = false,
        isSavedFromOtherApps: Bool = false,
        duration: TimeInterval? = nil,
        hasEmbeddedTimeZone: Bool = false,
        isDrifted: Bool = false,
        isAnalyzed: Bool = false,
        subfolderPath: String = "",
        fileSize: Int64? = nil
    ) {
        self.id = asset.localIdentifier
        self.asset = asset
        self.hasEmbeddedTimeZone = hasEmbeddedTimeZone
        self.isDrifted = isDrifted
        self.isAnalyzed = isAnalyzed
        self.subfolderPath = subfolderPath
        self.fileSize = fileSize

        // Resolve filename
        let resolvedName: String
        if let filename = filename, !filename.isEmpty {
            resolvedName = filename
        } else if let original = asset.photosAppOriginalFilename, !original.isEmpty {
            resolvedName = original
        } else {
            let resources = PHAssetResource.assetResources(for: asset)
            if let primaryResource = resources.first(where: {
                $0.type == .photo || $0.type == .fullSizePhoto || $0.type == .video || $0.type == .fullSizeVideo
            }) {
                resolvedName = primaryResource.originalFilename
            } else if let firstResource = resources.first {
                resolvedName = firstResource.originalFilename
            } else if let assetFilename = asset.value(forKey: "filename") as? String, !assetFilename.isEmpty {
                resolvedName = assetFilename
            } else {
                let ext = asset.mediaType == .video ? "MOV" : "HEIC"
                resolvedName = "IMG_\(asset.localIdentifier.prefix(6)).\(ext)"
            }
        }
        self.filename = resolvedName
        self.fileExtension = (resolvedName as NSString).pathExtension.uppercased()

        let effectiveDate = creationDate ?? asset.creationDate
        self.creationDate = effectiveDate
        self.embeddedDate = embeddedDate
        self.timeZone = timeZone
        self.isDateAdjusted = isDateAdjusted
        self.isGPSAdjusted = isGPSAdjusted
        self.pendingRotationDegrees = 0
        self.isSavedFromOtherApps = isSavedFromOtherApps
        self.isEdited = asset.hasAdjustments
        self.pixelWidth = asset.pixelWidth
        self.pixelHeight = asset.pixelHeight
        self.location = asset.location
        self.duration = duration ?? (asset.mediaType == .video ? asset.duration : nil)
        self.fileModificationDate = asset.modificationDate
        self.isVideoFile = asset.mediaType == .video
        self.localFileURL = nil
        self.remoteFileID = nil
        self.remoteThumbnailLink = nil
        self.sourceFilename = nil
        self.sourceSubfolderPath = nil
    }

    /// Initializer for media files loaded from a Local, Google Drive, or Samba folder
    init(
        id: String,
        filename: String,
        creationDate: Date?,
        embeddedDate: Date? = nil,
        timeZone: TimeZone = .current,
        isDateAdjusted: Bool = false,
        isGPSAdjusted: Bool = false,
        pendingRotationDegrees: Int = 0,
        pixelWidth: Int = 0,
        pixelHeight: Int = 0,
        location: CLLocation? = nil,
        duration: TimeInterval? = nil,
        hasEmbeddedTimeZone: Bool = false,
        isDrifted: Bool = false,
        isAnalyzed: Bool = false,
        subfolderPath: String = "",
        fileSize: Int64? = nil,
        fileModificationDate: Date? = nil,
        isVideoFile: Bool? = nil,
        localFileURL: URL? = nil,
        remoteFileID: String? = nil,
        remoteThumbnailLink: String? = nil,
        sourceFilename: String? = nil,
        sourceSubfolderPath: String? = nil
    ) {
        self.id = id
        self.asset = nil
        self.filename = filename
        self.fileExtension = (filename as NSString).pathExtension.uppercased()
        self.creationDate = creationDate
        self.embeddedDate = embeddedDate
        self.timeZone = timeZone
        self.isDateAdjusted = isDateAdjusted
        self.isGPSAdjusted = isGPSAdjusted
        self.pendingRotationDegrees = ((pendingRotationDegrees % 360) + 360) % 360
        self.isSavedFromOtherApps = false
        self.isEdited = false
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.location = location
        self.duration = duration
        self.hasEmbeddedTimeZone = hasEmbeddedTimeZone
        self.isDrifted = isDrifted
        self.isAnalyzed = isAnalyzed
        self.subfolderPath = subfolderPath
        self.fileSize = fileSize
        self.fileModificationDate = fileModificationDate
        self.isVideoFile = isVideoFile ?? PhotoItem.isVideoFilename(filename)
        self.localFileURL = localFileURL
        self.remoteFileID = remoteFileID
        self.remoteThumbnailLink = remoteThumbnailLink
        self.sourceFilename = sourceFilename
        self.sourceSubfolderPath = sourceSubfolderPath
    }

    /// Returns a copy of the PhotoItem with an updated filename, file extension, and optional local file URL
    func withFilename(_ newFilename: String, localFileURL: URL? = nil, updatingSource: Bool = false) -> PhotoItem {
        if let asset {
            return PhotoItem(
                asset: asset,
                filename: newFilename,
                creationDate: self.creationDate,
                embeddedDate: self.embeddedDate,
                timeZone: self.timeZone,
                isDateAdjusted: self.isDateAdjusted,
                isGPSAdjusted: self.isGPSAdjusted,
                isSavedFromOtherApps: self.isSavedFromOtherApps,
                duration: self.duration,
                hasEmbeddedTimeZone: self.hasEmbeddedTimeZone,
                isDrifted: self.isDrifted,
                isAnalyzed: self.isAnalyzed,
                subfolderPath: self.subfolderPath,
                fileSize: self.fileSize
            )
        }
        return PhotoItem(
            id: self.id,
            filename: newFilename,
            creationDate: self.creationDate,
            embeddedDate: self.embeddedDate,
            timeZone: self.timeZone,
            isDateAdjusted: self.isDateAdjusted,
            isGPSAdjusted: self.isGPSAdjusted,
            pendingRotationDegrees: self.pendingRotationDegrees,
            pixelWidth: self.pixelWidth,
            pixelHeight: self.pixelHeight,
            location: self.location,
            duration: self.duration,
            hasEmbeddedTimeZone: self.hasEmbeddedTimeZone,
            isDrifted: self.isDrifted,
            isAnalyzed: self.isAnalyzed,
            subfolderPath: self.subfolderPath,
            fileSize: self.fileSize,
            fileModificationDate: self.fileModificationDate,
            isVideoFile: PhotoItem.isVideoFilename(newFilename),
            localFileURL: localFileURL ?? self.localFileURL,
            remoteFileID: self.remoteFileID,
            remoteThumbnailLink: self.remoteThumbnailLink,
            sourceFilename: updatingSource ? newFilename : (self.sourceFilename ?? self.filename),
            sourceSubfolderPath: self.sourceSubfolderPath ?? self.subfolderPath
        )
    }

    /// Returns a copy of a folder PhotoItem with updated pending clockwise rotation degrees (0, 90, 180, 270)
    func withPendingRotation(_ degrees: Int, swapDimensions: Bool = false) -> PhotoItem {
        let normalized = ((degrees % 360) + 360) % 360
        let newWidth = swapDimensions ? self.pixelHeight : self.pixelWidth
        let newHeight = swapDimensions ? self.pixelWidth : self.pixelHeight
        if let asset {
            return PhotoItem(
                asset: asset,
                filename: self.filename,
                creationDate: self.creationDate,
                embeddedDate: self.embeddedDate,
                timeZone: self.timeZone,
                isDateAdjusted: self.isDateAdjusted,
                isGPSAdjusted: self.isGPSAdjusted,
                isSavedFromOtherApps: self.isSavedFromOtherApps,
                duration: self.duration,
                hasEmbeddedTimeZone: self.hasEmbeddedTimeZone,
                isDrifted: self.isDrifted,
                isAnalyzed: self.isAnalyzed,
                subfolderPath: self.subfolderPath,
                fileSize: self.fileSize
            )
        }
        return PhotoItem(
            id: self.id,
            filename: self.filename,
            creationDate: self.creationDate,
            embeddedDate: self.embeddedDate,
            timeZone: self.timeZone,
            isDateAdjusted: self.isDateAdjusted,
            isGPSAdjusted: self.isGPSAdjusted,
            pendingRotationDegrees: normalized,
            pixelWidth: newWidth,
            pixelHeight: newHeight,
            location: self.location,
            duration: self.duration,
            hasEmbeddedTimeZone: self.hasEmbeddedTimeZone,
            isDrifted: self.isDrifted,
            isAnalyzed: self.isAnalyzed,
            subfolderPath: self.subfolderPath,
            fileSize: self.fileSize,
            fileModificationDate: self.fileModificationDate,
            isVideoFile: self.isVideoFile,
            localFileURL: self.localFileURL,
            remoteFileID: self.remoteFileID,
            remoteThumbnailLink: self.remoteThumbnailLink,
            sourceFilename: self.sourceFilename,
            sourceSubfolderPath: self.sourceSubfolderPath
        )
    }

    /// Returns a copy of the PhotoItem with an updated subfolder path
    func withSubfolderPath(_ newSubfolderPath: String) -> PhotoItem {
        if let asset {
            return PhotoItem(
                asset: asset,
                filename: self.filename,
                creationDate: self.creationDate,
                embeddedDate: self.embeddedDate,
                timeZone: self.timeZone,
                isDateAdjusted: self.isDateAdjusted,
                isGPSAdjusted: self.isGPSAdjusted,
                isSavedFromOtherApps: self.isSavedFromOtherApps,
                duration: self.duration,
                hasEmbeddedTimeZone: self.hasEmbeddedTimeZone,
                isDrifted: self.isDrifted,
                isAnalyzed: self.isAnalyzed,
                subfolderPath: newSubfolderPath,
                fileSize: self.fileSize
            )
        }
        return PhotoItem(
            id: self.id,
            filename: self.filename,
            creationDate: self.creationDate,
            embeddedDate: self.embeddedDate,
            timeZone: self.timeZone,
            isDateAdjusted: self.isDateAdjusted,
            isGPSAdjusted: self.isGPSAdjusted,
            pendingRotationDegrees: self.pendingRotationDegrees,
            pixelWidth: self.pixelWidth,
            pixelHeight: self.pixelHeight,
            location: self.location,
            duration: self.duration,
            hasEmbeddedTimeZone: self.hasEmbeddedTimeZone,
            isDrifted: self.isDrifted,
            isAnalyzed: self.isAnalyzed,
            subfolderPath: newSubfolderPath,
            fileSize: self.fileSize,
            fileModificationDate: self.fileModificationDate,
            isVideoFile: self.isVideoFile,
            localFileURL: self.localFileURL,
            remoteFileID: self.remoteFileID,
            remoteThumbnailLink: self.remoteThumbnailLink,
            sourceFilename: self.sourceFilename ?? self.filename,
            sourceSubfolderPath: self.sourceSubfolderPath ?? self.subfolderPath
        )
    }

    // MARK: - Display helpers

    var formattedDate: String {
        guard let date = creationDate else { return "No Date" }
        return DateFormatters.mediumDateString(for: date, in: timeZone)
    }

    var formattedTime: String {
        guard let date = creationDate else { return "--:--" }
        return DateFormatters.mediumTimeString(for: date, in: timeZone)
    }

    var formattedTimezone: String {
        guard let date = creationDate else { return "" }
        return DateFormatters.friendlyTimezone(for: date, in: timeZone)
    }

    var formattedShortUTCOffset: String {
        guard let date = creationDate else { return "" }
        return DateFormatters.shortUTCOffsetString(for: date, in: timeZone)
    }

    var formattedFullTimestamp: String {
        DateFormatters.fullTimestampString(for: creationDate, in: timeZone)
    }

    var formattedDuration: String? {
        guard let dur = duration, dur > 0 else { return nil }
        let totalSeconds = Int(round(dur))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    var dimensionsString: String {
        if let durStr = formattedDuration {
            return "\(durStr) • \(pixelWidth) × \(pixelHeight)"
        }
        return "\(pixelWidth) × \(pixelHeight)"
    }

    /// Check if this photo matches the given filter
    func matches(filter: PhotoFilter) -> Bool {
        switch filter {
        case .all:
            return true
        case .adjusted:
            return isAdjusted
        case .drifted:
            return isDrifted
        case .edited:
            return isEdited
        case .inferred:
            return hasInferredTimeZone
        case .savedFromOtherApps:
            return isSavedFromOtherApps
        }
    }

    // MARK: - Hashable & Equatable

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: PhotoItem, rhs: PhotoItem) -> Bool {
        lhs.id == rhs.id &&
        lhs.filename == rhs.filename &&
        lhs.subfolderPath == rhs.subfolderPath &&
        lhs.isDateAdjusted == rhs.isDateAdjusted &&
        lhs.isGPSAdjusted == rhs.isGPSAdjusted &&
        lhs.pendingRotationDegrees == rhs.pendingRotationDegrees &&
        lhs.isEdited == rhs.isEdited &&
        lhs.creationDate == rhs.creationDate &&
        lhs.hasEmbeddedTimeZone == rhs.hasEmbeddedTimeZone &&
        lhs.isDrifted == rhs.isDrifted &&
        lhs.isAnalyzed == rhs.isAnalyzed &&
        lhs.timeZone == rhs.timeZone &&
        lhs.modificationDate == rhs.modificationDate
    }
}

// MARK: - Search Criteria & Matching

struct DateQueryCriteria {
    let year: Int?
    let month: Int?
    let day: Int?

    func matches(year y: Int, month m: Int, day d: Int) -> Bool {
        if let targetYear = year, targetYear != y { return false }
        if let targetMonth = month, targetMonth != m { return false }
        if let targetDay = day, targetDay != d { return false }
        return true
    }

    /// Parses search string into DateQueryCriteria if it conforms to date search patterns:
    /// M, M/d, M/d/yyyy, M/yyyy, yyyy, yyyy-M, yyyy-M-d
    static func parse(from rawQuery: String) -> DateQueryCriteria? {
        let q = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }

        let slashParts = q.split(separator: "/").map { String($0) }
        let dashParts = q.split(separator: "-").map { String($0) }

        let parts: [String]
        if slashParts.count > 1 {
            parts = slashParts
        } else if dashParts.count > 1 {
            parts = dashParts
        } else {
            parts = [q]
        }

        if parts.count == 3 {
            // M/d/yyyy or yyyy-M-d (or variations with / and -)
            if let first = Int(parts[0]), let second = Int(parts[1]), let third = Int(parts[2]) {
                if parts[0].count == 4 {
                    // yyyy-M-d / yyyy/M/d
                    guard second >= 1 && second <= 12, third >= 1 && third <= 31 else { return nil }
                    return DateQueryCriteria(year: first, month: second, day: third)
                } else if parts[2].count == 4 {
                    // M/d/yyyy / M-d-yyyy
                    guard first >= 1 && first <= 12, second >= 1 && second <= 31 else { return nil }
                    return DateQueryCriteria(year: third, month: first, day: second)
                }
            }
            return nil
        }

        if parts.count == 2 {
            // yyyy-M, M/yyyy, or M/d
            if let first = Int(parts[0]), let second = Int(parts[1]) {
                if parts[0].count == 4 {
                    // yyyy-M / yyyy/M
                    guard second >= 1 && second <= 12 else { return nil }
                    return DateQueryCriteria(year: first, month: second, day: nil)
                } else if parts[1].count == 4 {
                    // M/yyyy / M-yyyy
                    guard first >= 1 && first <= 12 else { return nil }
                    return DateQueryCriteria(year: second, month: first, day: nil)
                } else {
                    // M/d / M-d
                    guard first >= 1 && first <= 12, second >= 1 && second <= 31 else { return nil }
                    return DateQueryCriteria(year: nil, month: first, day: second)
                }
            }
            return nil
        }

        if parts.count == 1 {
            // yyyy (4 digits) or M (1 or 2 digits: 1...12)
            if let num = Int(parts[0]) {
                if parts[0].count == 4 {
                    return DateQueryCriteria(year: num, month: nil, day: nil)
                } else if (parts[0].count == 1 || parts[0].count == 2) && num >= 1 && num <= 12 {
                    return DateQueryCriteria(year: nil, month: num, day: nil)
                }
            }
        }

        return nil
    }
}

extension PhotoItem {
    /// Checks if this item matches search query by filename (partial match) or date in photo's timezone
    func matchesSearch(query: String, dateCriteria: DateQueryCriteria?) -> Bool {
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuery.isEmpty else { return false }

        // 1. Filename partial match (case-insensitive)
        if filename.localizedCaseInsensitiveContains(cleanQuery) {
            return true
        }

        // 2. Date criteria match in photo's timezone
        if let criteria = dateCriteria, let date = creationDate ?? embeddedDate {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let comps = calendar.dateComponents([.year, .month, .day], from: date)
            if let y = comps.year, let m = comps.month, let d = comps.day {
                if criteria.matches(year: y, month: m, day: d) {
                    return true
                }
            }
        }

        return false
    }
}
