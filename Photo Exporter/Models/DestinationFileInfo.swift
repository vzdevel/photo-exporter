//
//  DestinationFileInfo.swift
//  Photo Exporter
//
//  Created by Antigravity on 2026-11-07.
//

import Foundation
import Photos
import SwiftUI

/// Represents metadata of an existing file in the target export destination (Local, Google Drive, or Samba)
struct DestinationFileInfo: Identifiable, Equatable {
    let id: String
    let filename: String
    let modificationDate: Date?
    let fileSize: Int64
    let thumbnailLink: String?
    var subfolderPath: String = ""

    init(
        id: String,
        filename: String,
        modificationDate: Date?,
        fileSize: Int64,
        thumbnailLink: String? = nil,
        subfolderPath: String = ""
    ) {
        self.id = id
        self.filename = filename
        self.modificationDate = modificationDate
        self.fileSize = fileSize
        self.thumbnailLink = thumbnailLink
        self.subfolderPath = subfolderPath
    }

    var isVideo: Bool {
        let ext = (filename as NSString).pathExtension.lowercased()
        return ["mp4", "mov", "m4v", "avi", "mkv"].contains(ext)
    }

    var thumbnailKey: String {
        subfolderPath.isEmpty ? filename.lowercased() : "\(subfolderPath)/\(filename)".lowercased()
    }
}

/// Represents a device photo skipped because an identical file already exists in the destination
struct SkippedFileSummaryItem: Identifiable, Equatable {
    var id: String { deviceItem.id }
    let deviceItem: PhotoItem
    let matchedDestinationFile: DestinationFileInfo
    let deviceFileSize: Int64
    let deviceModificationDate: Date?

    var displayFilename: String {
        deviceItem.filename
    }

    var destinationFilename: String {
        matchedDestinationFile.filename
    }

    static func == (lhs: SkippedFileSummaryItem, rhs: SkippedFileSummaryItem) -> Bool {
        lhs.id == rhs.id && lhs.matchedDestinationFile.id == rhs.matchedDestinationFile.id
    }
}

/// Engine to evaluate duplicate files and resolve naming conflicts
enum ExportDeduplicationEngine {
    /// Removes deduplication suffixes "-N" (e.g. "-1", "-2") and " (N)" (e.g. " (1)", " (2)") from the filename base.
    /// Example: "IMG_0001-1.jpg" -> "IMG_0001.jpg"
    /// "IMG_0001 (1).jpg" -> "IMG_0001.jpg"
    /// "IMG_0001.jpg" -> "IMG_0001.jpg"
    static func strippingDedupSuffix(from filename: String) -> String {
        let ns = filename as NSString
        let ext = ns.pathExtension
        var base = ns.deletingPathExtension

        let pattern = #"^(.*?)(?:-(\d+)|\s*\(\d+\))$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return filename }

        while let match = regex.firstMatch(in: base, range: NSRange(location: 0, length: base.utf16.count)),
              let range = Range(match.range(at: 1), in: base) {
            let stripped = String(base[range])
            if stripped.isEmpty { break }
            base = stripped
        }

        return ext.isEmpty ? base : "\(base).\(ext)"
    }

    /// Checks if the destination file modification date matches the device item date within tolerance
    static func isModificationDateMatching(destDate: Date?, item: PhotoItem) -> Bool {
        guard let destDate = destDate else { return false }
        let tolerance: TimeInterval = 2.0 // Tolerates filesystem / formatting timestamp differences

        if let creation = item.creationDate, abs(destDate.timeIntervalSince(creation)) <= tolerance {
            return true
        }
        if let mod = item.modificationDate, abs(destDate.timeIntervalSince(mod)) <= tolerance {
            return true
        }
        if let assetCreation = item.asset?.creationDate, abs(destDate.timeIntervalSince(assetCreation)) <= tolerance {
            return true
        }
        return false
    }

    /// Extracts device file size closest to the final exported size:
    /// 1. Uses the persisted file size from the photo analysis phase if available (fastest and handles cropped/edited photos).
    /// 2. If photo is edited and no cached size, queries current image data size lazily.
    /// 3. Falls back to original PHAssetResource fileSize.
    static func getDeviceFileSize(for item: PhotoItem) -> Int64 {
        if let size = item.fileSize, size > 0 {
            return size
        }

        guard let asset = item.asset else {
            return 0
        }

        if item.isEdited && !item.isVideo {
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = false
            options.version = .current
            options.isSynchronous = true
            var editedSize: Int64? = nil
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                if let count = data?.count, count > 0 {
                    editedSize = Int64(count)
                }
            }
            if let size = editedSize, size > 0 {
                return size
            }
        }

        let resources = PHAssetResource.assetResources(for: asset)
        let preferredTypes: [PHAssetResourceType] = (item.isEdited || asset.hasAdjustments)
            ? [.fullSizePhoto, .fullSizeVideo, .photo, .video]
            : [.photo, .video, .fullSizePhoto, .fullSizeVideo]
        for targetType in preferredTypes {
            if let res = resources.first(where: { $0.type == targetType }),
               let size = res.value(forKey: "fileSize") as? NSNumber {
                let bytes = size.int64Value
                if bytes > 0 { return bytes }
            }
        }
        for res in resources {
            if let size = res.value(forKey: "fileSize") as? NSNumber {
                let bytes = size.int64Value
                if bytes > 0 { return bytes }
            }
        }
        return 0
    }

    /// Evaluates which device items should be skipped because an identical file already exists in the destination.
    /// Uses dictionary lookup and lazily extracts device file sizes only on matching filename candidates for maximum performance.
    static func evaluateDuplicates(
        deviceItems: [PhotoItem],
        destinationFiles: [DestinationFileInfo]
    ) -> (skipped: [SkippedFileSummaryItem], remaining: [PhotoItem]) {
        var skipped: [SkippedFileSummaryItem] = []
        var remaining: [PhotoItem] = []

        // Ignore 0-byte destination files and treat them as non-existent so they are simply overridden
        let validDestFiles = destinationFiles.filter { $0.fileSize > 0 }

        // Index destination files by stripped lowercase filename for O(1) matching
        var destFilesByStrippedName: [String: [DestinationFileInfo]] = [:]
        for dest in validDestFiles {
            let key = strippingDedupSuffix(from: dest.filename).lowercased()
            destFilesByStrippedName[key, default: []].append(dest)
        }

        for item in deviceItems {
            let itemStrippedName = strippingDedupSuffix(from: item.filename).lowercased()
            guard let candidates = destFilesByStrippedName[itemStrippedName], !candidates.isEmpty else {
                remaining.append(item)
                continue
            }

            var matchedDestFile: DestinationFileInfo? = nil
            var deviceSize: Int64? = nil

            for destFile in candidates {
                // Fast in-memory check: modification timestamp
                guard isModificationDateMatching(destDate: destFile.modificationDate, item: item) else { continue }

                // Lazily query device file size only when stripped name and modification date match
                if deviceSize == nil {
                    deviceSize = getDeviceFileSize(for: item)
                }
                let dSize = deviceSize ?? 0

                // If sizes are available, verify byte count match allowing up to 10% size difference
                if dSize > 0 && destFile.fileSize > 0 {
                    let diff = abs(dSize - destFile.fileSize)
                    let maxAllowedDiff = Int64(Double(max(dSize, destFile.fileSize)) * 0.10)
                    guard diff <= maxAllowedDiff else { continue }
                }

                matchedDestFile = destFile
                break
            }

            if let matched = matchedDestFile {
                let finalSize = (deviceSize ?? 0) > 0 ? (deviceSize ?? 0) : matched.fileSize
                skipped.append(SkippedFileSummaryItem(
                    deviceItem: item,
                    matchedDestinationFile: matched,
                    deviceFileSize: finalSize,
                    deviceModificationDate: item.creationDate ?? item.modificationDate ?? item.asset?.creationDate
                ))
            } else {
                remaining.append(item)
            }
        }

        return (skipped, remaining)
    }
}

