//
//  FileRenameItem.swift
//  Photo Exporter
//
//  Created by Antigravity on 2026-11-02.
//

import Foundation
import Photos

/// Represents an item in a filename collision group within the selected batch
struct FileRenameItem: Identifiable, Equatable {
    let id: String
    let originalName: String
    let newName: String
    var isRenamed: Bool = true
    let date: Date?
    let timeZone: TimeZone
    let asset: PHAsset?
    var fileSize: Int64 = 0
    var subfolderPath: String = ""

    static func == (lhs: FileRenameItem, rhs: FileRenameItem) -> Bool {
        lhs.id == rhs.id && lhs.newName == rhs.newName && lhs.isRenamed == rhs.isRenamed && lhs.fileSize == rhs.fileSize && lhs.subfolderPath == rhs.subfolderPath
    }
}

/// Represents a group of photos sharing the same original filename family
struct FileRenameGroup: Identifiable, Equatable {
    var id: String {
        subfolderPath.isEmpty ? originalName : "\(subfolderPath)/\(originalName)"
    }
    let originalName: String
    var items: [FileRenameItem]
    var existingDestinationFiles: [DestinationFileInfo] = []
    var subfolderPath: String = ""

    var renamedCount: Int {
        items.filter(\.isRenamed).count
    }

    static func == (lhs: FileRenameGroup, rhs: FileRenameGroup) -> Bool {
        lhs.id == rhs.id && lhs.items == rhs.items && lhs.existingDestinationFiles == rhs.existingDestinationFiles && lhs.subfolderPath == rhs.subfolderPath
    }
}

/// Helper to sort files in the same family naturally: base (img.jpg) -> img-1.jpg -> img-2.jpg -> img-10.jpg
enum FileFamilySortingHelper {
    static func suffixIndex(from filename: String) -> Int {
        let ns = filename as NSString
        let base = ns.deletingPathExtension
        let pattern = #"^(?:.*?)(?:-(\d+)|\s*\((\d+)\))$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
        if let match = regex.firstMatch(in: base, range: NSRange(location: 0, length: base.utf16.count)) {
            for groupIdx in [1, 2] {
                let r = match.range(at: groupIdx)
                if r.location != NSNotFound, let range = Range(r, in: base), let num = Int(base[range]) {
                    return num
                }
            }
        }
        return 0
    }

    static func compareFamilyFiles(_ a: String, _ b: String) -> Bool {
        let idxA = suffixIndex(from: a)
        let idxB = suffixIndex(from: b)
        if idxA != idxB {
            return idxA < idxB
        }
        return a.localizedStandardCompare(b) == .orderedAscending
    }
}

extension Array where Element == PhotoItem {
    /// Sorts photos chronologically ascending (oldest first), breaking ties deterministically by asset ID.
    func sortedChronologicallyAscending() -> [PhotoItem] {
        self.sorted { item1, item2 in
            let d1 = item1.creationDate ?? item1.embeddedDate ?? item1.asset?.creationDate ?? .distantPast
            let d2 = item2.creationDate ?? item2.embeddedDate ?? item2.asset?.creationDate ?? .distantPast
            if d1 != d2 {
                return d1 < d2
            }
            return item1.id < item2.id
        }
    }

    /// Resolves filename conflicts within the selected photos and against existing files in the destination.
    /// 1. Sorts the photos chronologically ascendingly.
    /// 2. Resolves collisions with existing destination files and internal duplicates by appending `-1`, `-2`, etc.
    /// Returns the resolved items (in chronological ascending order) and the grouped list of conflicts.
    func resolveFilenameConflicts(
        takingIntoAccountExisting existingFilenames: Set<String> = [],
        destinationFiles: [DestinationFileInfo] = []
    ) -> (items: [PhotoItem], groups: [FileRenameGroup]) {
        let sorted = self.sortedChronologicallyAscending()

        // Ignore 0-byte destination files and treat them as non-existent so they are simply overridden
        let validDestFiles = destinationFiles.filter { $0.fileSize > 0 }

        // Index destination files by stripped lowercase root filename for family grouping
        var destFilesByRoot: [String: [DestinationFileInfo]] = [:]
        for dest in validDestFiles {
            let root = ExportDeduplicationEngine.strippingDedupSuffix(from: dest.filename).lowercased()
            destFilesByRoot[root, default: []].append(dest)
        }

        // Combine explicit existing names with destinationFiles names
        var usedFilenames = Set(existingFilenames.map { $0.lowercased() })
        for dest in validDestFiles {
            usedFilenames.insert(dest.filename.lowercased())
        }

        var resolvedItems: [PhotoItem] = []
        var originalNameCounters: [String: Int] = [:]
        var itemsWithRenameInfo: [(item: PhotoItem, origName: String, finalName: String, isRenamed: Bool)] = []
        var anyRenamedInFamily: Set<String> = []
        var familyOrder: [String] = []

        for item in sorted {
            let origName = item.filename
            let origKey = origName.lowercased()
            let strippedRootName = ExportDeduplicationEngine.strippingDedupSuffix(from: origName)
            let rootKey = strippedRootName.lowercased()
            if !familyOrder.contains(rootKey) {
                familyOrder.append(rootKey)
            }

            let rootNS = strippedRootName as NSString
            let ext = rootNS.pathExtension
            let rootBase = rootNS.deletingPathExtension

            var finalName = origName
            var finalKey = origKey

            if usedFilenames.contains(finalKey) {
                var counter = Swift.max(1, originalNameCounters[rootKey, default: 1])
                while true {
                    let candidate = ext.isEmpty ? "\(rootBase)-\(counter)" : "\(rootBase)-\(counter).\(ext)"
                    let candidateKey = candidate.lowercased()
                    counter += 1
                    if !usedFilenames.contains(candidateKey) {
                        finalName = candidate
                        finalKey = candidateKey
                        originalNameCounters[rootKey] = counter
                        break
                    }
                }
            }

            usedFilenames.insert(finalKey)
            if originalNameCounters[rootKey] == nil {
                originalNameCounters[rootKey] = 1
            }

            let isRenamed = (finalName != origName)
            if isRenamed {
                anyRenamedInFamily.insert(rootKey)
            }

            let resolvedItem = isRenamed ? item.withFilename(finalName) : item
            resolvedItems.append(resolvedItem)
            itemsWithRenameInfo.append((item: item, origName: origName, finalName: finalName, isRenamed: isRenamed))
        }

        // Build rename groups for families with conflicts
        var groups: [FileRenameGroup] = []
        for rootKey in familyOrder {
            guard anyRenamedInFamily.contains(rootKey) else { continue }

            // Matching destination files sorted in natural family order: img.jpg -> img-1.jpg
            var matchingDest = destFilesByRoot[rootKey] ?? []
            matchingDest.sort { FileFamilySortingHelper.compareFamilyFiles($0.filename, $1.filename) }

            // Matching batch items
            let matchingBatchTuples = itemsWithRenameInfo.filter {
                ExportDeduplicationEngine.strippingDedupSuffix(from: $0.origName).lowercased() == rootKey
            }

            var groupItems: [FileRenameItem] = matchingBatchTuples.map { info in
                let itemSize = ExportDeduplicationEngine.getDeviceFileSize(for: info.item)
                return FileRenameItem(
                    id: info.item.id,
                    originalName: info.origName,
                    newName: info.finalName,
                    isRenamed: info.isRenamed,
                    date: info.item.creationDate,
                    timeZone: info.item.timeZone,
                    asset: info.item.asset,
                    fileSize: itemSize
                )
            }
            // Sort batch items by their final names: e.g. img-2.jpg (original) -> img-3.jpg (renamed)
            groupItems.sort { FileFamilySortingHelper.compareFamilyFiles($0.newName, $1.newName) }

            // Determine display originalName for the group
            let groupOriginalName = matchingDest.first(where: {
                ExportDeduplicationEngine.strippingDedupSuffix(from: $0.filename).lowercased() == rootKey &&
                $0.filename.lowercased() == rootKey
            })?.filename
            ?? matchingBatchTuples.first(where: {
                $0.origName.lowercased() == rootKey
            })?.origName
            ?? ExportDeduplicationEngine.strippingDedupSuffix(from: matchingBatchTuples.first?.origName ?? rootKey)

            groups.append(FileRenameGroup(
                originalName: groupOriginalName,
                items: groupItems,
                existingDestinationFiles: matchingDest
            ))
        }

        return (resolvedItems, groups)
    }

    /// Resolves filename conflicts within the selected photos only.
    func resolveInternalFilenameConflicts() -> (items: [PhotoItem], groups: [FileRenameGroup]) {
        resolveFilenameConflicts(takingIntoAccountExisting: [], destinationFiles: [])
    }
}
