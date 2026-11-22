//
//  FolderMediaService.swift
//  Photo Exporter
//

import Foundation
import AVFoundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Handles listing, header-only metadata analysis, thumbnail generation, detail loading,
/// and in-place rename / delete / metadata-apply operations for Local, Google Drive, and Samba folders.
extension Notification.Name {
    static let folderThumbnailInvalidated = Notification.Name("folderThumbnailInvalidated")
}

final class FolderMediaService {
    static let shared = FolderMediaService()

    private let exifService = ExifMetadataService.shared
    private let driveService = GoogleDriveService.shared
    private let sambaService = SambaService.shared
    private let cacheKeysLock = NSLock()
    private var cachedKeysByItem: [String: Set<String>] = [:]
    private var pendingAppliedThumbnails: [String: UIImage] = [:]
    private let thumbnailCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 400
        return cache
    }()

    private init() {}

    // MARK: - Listing

    func listMediaItems(in source: MediaSource) async throws -> [PhotoItem] {
        try await listDirectoryContents(in: source).items
    }

    func listDirectoryContents(in source: MediaSource) async throws -> (folders: [FolderListEntry], items: [PhotoItem]) {
        switch source {
        case .photoLibrary:
            return ([], [])

        case .localFolder:
            guard let access = source.beginLocalFolderAccess() else {
                throw NSError(domain: "FolderMedia", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unable to resolve local folder URL."])
            }
            let folderURL = access.folderURL
            defer { access.stop() }

            let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey]
            let contents = try FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            )

            var folders: [FolderListEntry] = []
            var items: [PhotoItem] = []
            for url in contents {
                let values = try? url.resourceValues(forKeys: Set(keys))
                let filename = url.lastPathComponent
                let modDate = values?.contentModificationDate

                if values?.isDirectory == true && values?.isPackage != true {
                    if let childSource = source.childFolderSource(name: filename) {
                        folders.append(FolderListEntry(
                            id: url.standardizedFileURL.path,
                            name: filename,
                            modificationDate: modDate,
                            targetSource: childSource
                        ))
                    }
                    continue
                }

                guard values?.isRegularFile == true else { continue }
                guard PhotoItem.isSupportedMediaFilename(filename) else { continue }

                let size = values?.fileSize.map { Int64($0) }
                items.append(PhotoItem(
                    id: filename,
                    filename: filename,
                    creationDate: modDate,
                    fileSize: size,
                    fileModificationDate: modDate,
                    localFileURL: url
                ))
            }
            folders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return (folders, items)

        case .googleDrive(let account):
            let entry = try await driveService.fetchDirectoryEntries(in: account.targetFolderId, accountID: account.id)
            let folders: [FolderListEntry] = entry.folders
                .compactMap { folder in
                    guard let childSource = source.childFolderSource(name: folder.name, folderId: folder.id) else { return nil }
                    return FolderListEntry(
                        id: folder.id,
                        name: folder.name,
                        modificationDate: folder.modifiedTime,
                        targetSource: childSource
                    )
                }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

            let items: [PhotoItem] = entry.files.compactMap { file in
                guard PhotoItem.isSupportedMediaFilename(file.filename) else { return nil }
                return PhotoItem(
                    id: file.id,
                    filename: file.filename,
                    creationDate: file.modificationDate,
                    fileSize: file.fileSize > 0 ? file.fileSize : nil,
                    fileModificationDate: file.modificationDate,
                    remoteFileID: file.id,
                    remoteThumbnailLink: file.thumbnailLink
                )
            }
            return (folders, items)

        case .samba(let destination):
            let cleanShare = destination.share.trimmingCharacters(in: CharacterSet(charactersIn: " /\\"))
            if cleanShare.isEmpty {
                let shares = try await sambaService.listShares(for: destination)
                let folders: [FolderListEntry] = shares
                    .compactMap { shareName in
                        guard let childSource = source.childFolderSource(name: shareName) else { return nil }
                        return FolderListEntry(
                            id: "smb_share:\(destination.id):\(shareName)",
                            name: shareName,
                            modificationDate: nil,
                            targetSource: childSource,
                            isDeletable: false
                        )
                    }
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                return (folders, [])
            }

            let entry = try await sambaService.fetchDirectoryEntries(destination: destination)
            let folders: [FolderListEntry] = entry.folders
                .compactMap { folder in
                    guard let childSource = source.childFolderSource(name: folder.filename) else { return nil }
                    return FolderListEntry(
                        id: folder.filename,
                        name: folder.filename,
                        modificationDate: folder.modificationDate,
                        targetSource: childSource
                    )
                }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

            let items: [PhotoItem] = entry.files.compactMap { file in
                guard PhotoItem.isSupportedMediaFilename(file.filename) else { return nil }
                return PhotoItem(
                    id: file.filename,
                    filename: file.filename,
                    creationDate: file.modificationDate,
                    fileSize: file.fileSize > 0 ? file.fileSize : nil,
                    fileModificationDate: file.modificationDate
                )
            }
            return (folders, items)
        }
    }

    // MARK: - Header-Only Metadata Analysis

    func analyzeItem(_ item: PhotoItem, in source: MediaSource) async throws -> ExifMetadataService.FolderEvaluatedMetadata {
        switch source {
        case .photoLibrary:
            throw NSError(domain: "FolderMedia", code: -2, userInfo: [NSLocalizedDescriptionKey: "Use PhotoLibraryService for Photo Library items."])

        case .localFolder:
            guard let access = source.beginLocalFolderAccess() else {
                throw NSError(domain: "FolderMedia", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unable to resolve local folder URL."])
            }
            let folderURL = access.folderURL
            let fileURL = item.localFileURL ?? folderURL.appendingPathComponent(item.filename)
            defer { access.stop() }

            if item.isVideo {
                return await exifService.evaluateEmbeddedVideoMetadata(from: fileURL, fileModificationDate: item.fileModificationDate)
            } else {
                let headerData = Self.readLocalHeaderBytes(from: fileURL, maxBytes: 131_072)
                if let imageSource = CGImageSourceCreateWithURL(fileURL as CFURL, nil) {
                    return exifService.evaluateEmbeddedPhotoMetadata(
                        from: imageSource,
                        headerData: headerData,
                        fileModificationDate: item.fileModificationDate
                    )
                }
                throw NSError(domain: "FolderMedia", code: -3, userInfo: [NSLocalizedDescriptionKey: "Unable to read image metadata from \(item.filename)."])
            }

        case .googleDrive(let account):
            guard let fileId = item.remoteFileID else {
                throw NSError(domain: "FolderMedia", code: -4, userInfo: [NSLocalizedDescriptionKey: "Missing Google Drive file ID."])
            }
            return try await analyzeRemoteItem(item, in: source, fetchRange: { [driveService] offset, length in
                try await driveService.readFileRange(fileId: fileId, accountID: account.id, offset: offset, length: length)
            }, downloadFull: { [driveService] destURL in
                try await driveService.downloadFile(fileId: fileId, accountID: account.id, to: destURL)
            })

        case .samba(let destination):
            return try await analyzeRemoteItem(item, in: source, fetchRange: { [sambaService] offset, length in
                try await sambaService.readFileRange(filename: item.filename, destination: destination, subfolderPath: item.subfolderPath, offset: offset, length: length)
            }, downloadFull: { [sambaService] destURL in
                try await sambaService.downloadFile(filename: item.filename, destination: destination, subfolderPath: item.subfolderPath, to: destURL)
            })
        }
    }

    private func analyzeRemoteItem(
        _ item: PhotoItem,
        in source: MediaSource,
        fetchRange: @escaping (UInt64, Int) async throws -> Data,
        downloadFull: @escaping (URL) async throws -> Void
    ) async throws -> ExifMetadataService.FolderEvaluatedMetadata {
        if item.isVideo {
            // Try reading only [ftyp] + [moov] atoms via byte ranges
            if let moovTempURL = try await fetchVideoMoovToTempURL(filename: item.filename, fetchRange: fetchRange) {
                defer { try? FileManager.default.removeItem(at: moovTempURL) }
                return await exifService.evaluateEmbeddedVideoMetadata(from: moovTempURL, fileModificationDate: item.fileModificationDate)
            }
            // Fallback: download full file only if reasonably sized (<= 100 MB)
            if (item.fileSize ?? 0) <= 100 * 1024 * 1024 {
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "_" + item.filename)
                defer { try? FileManager.default.removeItem(at: tempURL) }
                try await downloadFull(tempURL)
                return await exifService.evaluateEmbeddedVideoMetadata(from: tempURL, fileModificationDate: item.fileModificationDate)
            }
            return ExifMetadataService.FolderEvaluatedMetadata(
                embeddedDate: nil,
                effectiveDate: item.fileModificationDate ?? Date(),
                timeZone: .current,
                hasEmbeddedTimeZone: false,
                isDrifted: false,
                pixelWidth: 0,
                pixelHeight: 0,
                duration: nil,
                location: nil
            )
        } else {
            // Read first 128 KB for header-only image metadata
            let headerData = try await fetchRange(0, 131_072)
            if let imageSource = CGImageSourceCreateWithData(headerData as CFData, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
               !props.isEmpty {
                // Opportunistically cache embedded thumbnail from the already-fetched 128 KB header
                let thumbKey = thumbnailCacheKey(for: item, in: source)
                if thumbnailCache.object(forKey: thumbKey as NSString) == nil,
                   let thumb = await Task.detached(priority: .utility, operation: {
                       Self.extractEmbeddedThumbnail(fromHeader: headerData, maxPixelSize: 180)
                   }).value {
                    storeThumbnail(thumb, for: item, in: source, key: thumbKey)
                }
                return exifService.evaluateEmbeddedPhotoMetadata(
                    from: imageSource,
                    headerData: headerData,
                    fileModificationDate: item.fileModificationDate
                )
            }

            // Fallback: download full image if metadata lives past 128 KB (e.g. trailing PNG iTXt chunk)
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "_" + item.filename)
            defer { try? FileManager.default.removeItem(at: tempURL) }
            try await downloadFull(tempURL)
            if let fullSource = CGImageSourceCreateWithURL(tempURL as CFURL, nil) {
                let fullHeader = Self.readLocalHeaderBytes(from: tempURL, maxBytes: 524_288)
                return exifService.evaluateEmbeddedPhotoMetadata(
                    from: fullSource,
                    headerData: fullHeader,
                    fileModificationDate: item.fileModificationDate
                )
            }
            throw NSError(domain: "FolderMedia", code: -5, userInfo: [NSLocalizedDescriptionKey: "Failed to parse metadata for \(item.filename)."])
        }
    }

    /// Walks top-level ISO BMFF / QuickTime atoms via byte ranges and writes [ftyp][moov] to a temp file
    private func fetchVideoMoovToTempURL(
        filename: String,
        fetchRange: @escaping (UInt64, Int) async throws -> Data
    ) async throws -> URL? {
        let initialChunk = try await fetchRange(0, 65_536)
        guard initialChunk.count >= 16 else { return nil }

        func readU32BE(_ d: Data, _ offset: Int) -> UInt32 {
            (UInt32(d[offset]) << 24) | (UInt32(d[offset + 1]) << 16) | (UInt32(d[offset + 2]) << 8) | UInt32(d[offset + 3])
        }
        func readU64BE(_ d: Data, _ offset: Int) -> UInt64 {
            (UInt64(readU32BE(d, offset)) << 32) | UInt64(readU32BE(d, offset + 4))
        }

        var ftypData: Data? = nil
        var moovData: Data? = nil
        var offset: UInt64 = 0
        var iterations = 0

        while iterations < 32 {
            iterations += 1
            let headerData: Data
            if offset + 16 <= UInt64(initialChunk.count) {
                headerData = initialChunk.subdata(in: Int(offset)..<Int(offset + 16))
            } else {
                headerData = try await fetchRange(offset, 16)
            }
            guard headerData.count >= 8 else { break }

            let size32 = readU32BE(headerData, 0)
            guard let type = String(data: headerData.subdata(in: 4..<8), encoding: .ascii) else { break }

            let atomSize: UInt64
            if size32 == 1 {
                guard headerData.count >= 16 else { break }
                atomSize = readU64BE(headerData, 8)
            } else if size32 == 0 {
                break
            } else {
                atomSize = UInt64(size32)
            }
            guard atomSize >= 8 else { break }

            if type == "ftyp" && atomSize <= 4096 {
                if offset + atomSize <= UInt64(initialChunk.count) {
                    ftypData = initialChunk.subdata(in: Int(offset)..<Int(offset + atomSize))
                } else {
                    ftypData = try await fetchRange(offset, Int(atomSize))
                }
            } else if type == "moov" {
                guard atomSize <= 8 * 1024 * 1024 else { return nil }
                if offset + atomSize <= UInt64(initialChunk.count) {
                    moovData = initialChunk.subdata(in: Int(offset)..<Int(offset + atomSize))
                } else {
                    moovData = try await fetchRange(offset, Int(atomSize))
                }
                break
            }

            offset += atomSize
        }

        guard let moov = moovData else { return nil }
        var combined = Data()
        if let ftyp = ftypData {
            combined.append(ftyp)
        }
        combined.append(moov)

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "_" + filename)
        try combined.write(to: tempURL, options: .atomic)
        return tempURL
    }

    private static func readLocalHeaderBytes(from url: URL, maxBytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: maxBytes)
    }

    // MARK: - Thumbnails

    func cachedThumbnail(for item: PhotoItem, in source: MediaSource) -> UIImage? {
        let key = thumbnailCacheKey(for: item, in: source)
        return thumbnailCache.object(forKey: key as NSString)
    }

    func invalidateThumbnailCache(for item: PhotoItem, in source: MediaSource) {
        clearCachedThumbnails(for: item, in: source)
        let itemID = item.id
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .folderThumbnailInvalidated, object: itemID)
        }
    }

    /// Replaces stale thumbnail entries with a freshly rendered post-apply thumbnail if available,
    /// then notifies list rows to reload.
    func commitAppliedThumbnail(for updated: PhotoItem, oldItem: PhotoItem, in source: MediaSource) {
        clearCachedThumbnails(for: oldItem, in: source)
        clearCachedThumbnails(for: updated, in: source)

        let pendingKey = itemCacheTrackingKey(for: oldItem, in: source)
        cacheKeysLock.lock()
        let freshThumb = pendingAppliedThumbnails.removeValue(forKey: pendingKey)
        cacheKeysLock.unlock()

        if let freshThumb {
            let newCacheKey = thumbnailCacheKey(for: updated, in: source)
            storeThumbnail(freshThumb, for: updated, in: source, key: newCacheKey)
        }

        let itemID = updated.id
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .folderThumbnailInvalidated, object: itemID)
        }
    }

    private func clearCachedThumbnails(for item: PhotoItem, in source: MediaSource) {
        let currentKey = thumbnailCacheKey(for: item, in: source)
        let itemKey = itemCacheTrackingKey(for: item, in: source)
        cacheKeysLock.lock()
        let trackedKeys = cachedKeysByItem.removeValue(forKey: itemKey) ?? []
        cacheKeysLock.unlock()

        for key in trackedKeys.union([currentKey]) {
            thumbnailCache.removeObject(forKey: key as NSString)
        }
    }

    private func storeThumbnail(_ image: UIImage, for item: PhotoItem, in source: MediaSource, key: String) {
        thumbnailCache.setObject(image, forKey: key as NSString)
        let itemKey = itemCacheTrackingKey(for: item, in: source)
        cacheKeysLock.lock()
        cachedKeysByItem[itemKey, default: []].insert(key)
        cacheKeysLock.unlock()
    }

    private func itemCacheTrackingKey(for item: PhotoItem, in source: MediaSource) -> String {
        "\(source.sourceKey)|\(item.id)"
    }

    private func thumbnailCacheKey(for item: PhotoItem, in source: MediaSource) -> String {
        "\(source.sourceKey)_\(item.id)_\(item.modificationDate?.timeIntervalSince1970 ?? 0)"
    }

    func loadThumbnail(for item: PhotoItem, in source: MediaSource, maxPixelSize: CGFloat = 180) async -> UIImage? {
        let key = thumbnailCacheKey(for: item, in: source)
        if let cached = thumbnailCache.object(forKey: key as NSString) {
            return cached
        }

        var generated: UIImage? = nil

        switch source {
        case .photoLibrary:
            return nil

        case .localFolder:
            guard let access = source.beginLocalFolderAccess() else { return nil }
            let folderURL = access.folderURL
            let fileURL = item.localFileURL ?? folderURL.appendingPathComponent(item.filename)
            defer { access.stop() }

            if item.isVideo {
                let asset = AVURLAsset(url: fileURL)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
                if let cgImage = try? await generator.image(at: .zero).image {
                    generated = UIImage(cgImage: cgImage)
                }
            } else {
                generated = await Task.detached(priority: .utility) {
                    Self.thumbnailFromURL(fileURL, maxPixelSize: maxPixelSize)
                }.value
            }

        case .googleDrive(let account):
            if let link = item.remoteThumbnailLink,
               let data = try? await driveService.fetchThumbnailData(thumbnailLink: link, accountID: account.id),
               let img = UIImage(data: data) {
                generated = img
            } else if let fileId = item.remoteFileID {
                if let freshLink = await driveService.fetchThumbnailLink(fileId: fileId, accountID: account.id),
                   let data = try? await driveService.fetchThumbnailData(thumbnailLink: freshLink, accountID: account.id),
                   let img = UIImage(data: data) {
                    generated = img
                } else if item.isVideo {
                    if let streamHandle = try? await driveService.makeStreamingAsset(
                        fileId: fileId,
                        filename: item.effectiveSourceFilename,
                        knownFileSize: item.fileSize,
                        accountID: account.id
                    ) {
                        let generator = AVAssetImageGenerator(asset: streamHandle.asset)
                        generator.appliesPreferredTrackTransform = true
                        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
                        if let cgImage = try? await generator.image(at: .zero).image {
                            generated = UIImage(cgImage: cgImage)
                        }
                        await streamHandle.closeAndWait()
                    }
                } else if let data = try? await driveService.readFileRange(fileId: fileId, accountID: account.id, offset: 0, length: 262_144),
                          let thumb = Self.thumbnailFromData(data, maxPixelSize: maxPixelSize) {
                    generated = thumb
                } else {
                    let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "_" + item.effectiveSourceFilename)
                    defer { try? FileManager.default.removeItem(at: tempURL) }
                    if (try? await driveService.downloadFile(fileId: fileId, accountID: account.id, to: tempURL)) != nil {
                        generated = Self.thumbnailFromURL(tempURL, maxPixelSize: maxPixelSize)
                    }
                }
            }

        case .samba(let destination):
            if item.isVideo {
                generated = await sambaService.generateVideoThumbnail(
                    filename: item.filename,
                    destination: destination,
                    subfolderPath: item.subfolderPath,
                    maxPixelSize: maxPixelSize
                )
            } else {
                generated = await sambaService.generateImageThumbnail(
                    filename: item.filename,
                    destination: destination,
                    subfolderPath: item.subfolderPath,
                    knownFileSize: item.fileSize ?? 0,
                    maxPixelSize: maxPixelSize
                )
            }
        }

        if let generated {
            storeThumbnail(generated, for: item, in: source, key: key)
        }
        return generated
    }

    nonisolated static func videoThumbnailFromURL(_ url: URL, maxPixelSize: CGFloat) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        guard let cgImage = try? await generator.image(at: .zero).image else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    nonisolated static func thumbnailFromURL(_ url: URL, maxPixelSize: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        return thumbnailFromSource(source, maxPixelSize: maxPixelSize)
    }

    nonisolated static func thumbnailFromData(_ data: Data, maxPixelSize: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        return thumbnailFromSource(source, maxPixelSize: maxPixelSize)
    }

    enum EmbeddedThumbnailLookup {
        case embedded(data: Data, orientation: Int)
        case range(offset: UInt64, length: Int, orientation: Int)
        case none
    }

    /// Parses JPEG APP1 EXIF IFD1 or TIFF/RAW IFD1/IFD0 preview offsets without decoding the full pixel stream.
    nonisolated static func inspectEmbeddedThumbnail(in headerData: Data) -> EmbeddedThumbnailLookup {
        guard headerData.count >= 16 else { return .none }

        var tiffBase: Int? = nil
        if headerData[0] == 0xFF && headerData[1] == 0xD8 {
            // JPEG: scan segments until SOS (0xDA) or EOI (0xD9) for APP1 "Exif\0\0"
            var pos = 2
            while pos + 4 <= headerData.count {
                guard headerData[pos] == 0xFF else { break }
                let marker = headerData[pos + 1]
                if marker == 0xFF {
                    pos += 1
                    continue
                }
                if marker == 0xDA || marker == 0xD9 || marker == 0x00 {
                    break
                }
                let segLen = (Int(headerData[pos + 2]) << 8) | Int(headerData[pos + 3])
                guard segLen >= 2 else { break }
                if marker == 0xE1, pos + 10 <= headerData.count {
                    let exifHeader = headerData.subdata(in: (pos + 4)..<(pos + 10))
                    if exifHeader == Data([0x45, 0x78, 0x69, 0x66, 0x00, 0x00]) {
                        tiffBase = pos + 10
                        break
                    }
                }
                pos += 2 + segLen
            }
        } else if (headerData[0] == 0x49 && headerData[1] == 0x49 && headerData[2] == 0x2A && headerData[3] == 0x00)
               || (headerData[0] == 0x4D && headerData[1] == 0x4D && headerData[2] == 0x00 && headerData[3] == 0x2A) {
            // Direct TIFF / DNG / CR2 header
            tiffBase = 0
        }

        guard let base = tiffBase, base + 8 <= headerData.count else { return .none }
        let isLE: Bool
        if headerData[base] == 0x49 && headerData[base + 1] == 0x49 {
            isLE = true
        } else if headerData[base] == 0x4D && headerData[base + 1] == 0x4D {
            isLE = false
        } else {
            return .none
        }

        func readU16(_ rel: Int) -> UInt16? {
            let p = base + rel
            guard rel >= 0, p + 2 <= headerData.count else { return nil }
            return isLE
                ? (UInt16(headerData[p]) | (UInt16(headerData[p + 1]) << 8))
                : ((UInt16(headerData[p]) << 8) | UInt16(headerData[p + 1]))
        }
        func readU32(_ rel: Int) -> UInt32? {
            let p = base + rel
            guard rel >= 0, p + 4 <= headerData.count else { return nil }
            return isLE
                ? (UInt32(headerData[p]) | (UInt32(headerData[p + 1]) << 8) | (UInt32(headerData[p + 2]) << 16) | (UInt32(headerData[p + 3]) << 24))
                : ((UInt32(headerData[p]) << 24) | (UInt32(headerData[p + 1]) << 16) | (UInt32(headerData[p + 2]) << 8) | UInt32(headerData[p + 3]))
        }
        func readTagInt(_ entryRel: Int, type: UInt16, count: UInt32) -> Int? {
            guard count == 1 else { return nil }
            if type == 3 {
                // SHORT (stored in first 2 bytes of value/offset slot in TIFF)
                return readU16(entryRel + 8).map { Int($0) }
            }
            if type == 4 {
                return readU32(entryRel + 8).map { Int($0) }
            }
            return nil
        }

        guard let magic = readU16(2), magic == 42, let ifd0Raw = readU32(4) else { return .none }
        let ifd0Offset = Int(ifd0Raw)
        guard let ifd0Count = readU16(ifd0Offset).map({ Int($0) }), ifd0Count <= 512 else { return .none }

        var outerOrientation = 1
        var ifd0JpgOff = 0
        var ifd0JpgLen = 0
        for i in 0..<ifd0Count {
            let entry = ifd0Offset + 2 + i * 12
            guard let tag = readU16(entry),
                  let type = readU16(entry + 2),
                  let count = readU32(entry + 4) else { break }
            if tag == 0x0112, let val = readTagInt(entry, type: type, count: count) {
                outerOrientation = val
            } else if tag == 0x0201, let val = readTagInt(entry, type: type, count: count) {
                ifd0JpgOff = val
            } else if tag == 0x0202, let val = readTagInt(entry, type: type, count: count) {
                ifd0JpgLen = val
            }
        }

        var thumbRelOffset = 0
        var thumbLength = 0
        if let ifd1Raw = readU32(ifd0Offset + 2 + ifd0Count * 12), ifd1Raw > 0 {
            let ifd1Offset = Int(ifd1Raw)
            if let ifd1Count = readU16(ifd1Offset).map({ Int($0) }), ifd1Count <= 512 {
                for i in 0..<ifd1Count {
                    let entry = ifd1Offset + 2 + i * 12
                    guard let tag = readU16(entry),
                          let type = readU16(entry + 2),
                          let count = readU32(entry + 4) else { break }
                    if tag == 0x0201, let val = readTagInt(entry, type: type, count: count) {
                        thumbRelOffset = val
                    } else if tag == 0x0202, let val = readTagInt(entry, type: type, count: count) {
                        thumbLength = val
                    }
                }
            }
        }

        if thumbRelOffset <= 0 || thumbLength <= 0 {
            thumbRelOffset = ifd0JpgOff
            thumbLength = ifd0JpgLen
        }

        guard thumbRelOffset > 0, thumbLength >= 512, thumbLength <= 4 * 1024 * 1024 else {
            return .none
        }

        let absStart = base + thumbRelOffset
        let absEnd = absStart + thumbLength
        if absEnd <= headerData.count {
            let thumbData = headerData.subdata(in: absStart..<absEnd)
            guard thumbData.count >= 4, thumbData[0] == 0xFF, thumbData[1] == 0xD8 else {
                return .none
            }
            return .embedded(data: thumbData, orientation: outerOrientation)
        }
        return .range(offset: UInt64(absStart), length: thumbLength, orientation: outerOrientation)
    }

    nonisolated static func extractEmbeddedThumbnail(fromHeader headerData: Data, maxPixelSize: CGFloat) -> UIImage? {
        guard case .embedded(let thumbData, let orientation) = inspectEmbeddedThumbnail(in: headerData) else {
            return nil
        }
        return renderEmbeddedJPEGThumbnail(from: thumbData, exifOrientation: orientation, maxPixelSize: maxPixelSize)
    }

    nonisolated static func renderEmbeddedJPEGThumbnail(from data: Data, exifOrientation: Int, maxPixelSize: CGFloat) -> UIImage? {
        guard data.count >= 4, data[0] == 0xFF, data[1] == 0xD8 else { return nil }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetStatus(source) == .statusComplete || CGImageSourceGetCount(source) > 0 else {
            return nil
        }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: false,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
            return nil
        }
        return applyExifOrientation(to: cgImage, orientation: exifOrientation)
    }

    private nonisolated static func applyExifOrientation(to cgImage: CGImage, orientation: Int) -> UIImage {
        let uiOrientation: UIImage.Orientation = {
            switch orientation {
            case 2: return .upMirrored
            case 3: return .down
            case 4: return .downMirrored
            case 5: return .leftMirrored
            case 6: return .right
            case 7: return .rightMirrored
            case 8: return .left
            default: return .up
            }
        }()
        let rawImage = UIImage(cgImage: cgImage, scale: 1.0, orientation: uiOrientation)
        if uiOrientation == .up {
            return rawImage
        }
        let targetSize = rawImage.size
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { _ in
            rawImage.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    private nonisolated static func thumbnailFromSource(_ source: CGImageSource, maxPixelSize: CGFloat) -> UIImage? {
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    // MARK: - Detail Loading

    func loadDetailMediaAndMetadata(
        for item: PhotoItem,
        in source: MediaSource
    ) async throws -> (image: UIImage?, localVideoURL: URL?, tempFileToCleanup: URL?, metadata: PhotoExifMetadata) {
        switch source {
        case .photoLibrary:
            throw NSError(domain: "FolderMedia", code: -2, userInfo: [NSLocalizedDescriptionKey: "Unsupported for Photo Library."])

        case .localFolder:
            guard let access = source.beginLocalFolderAccess() else {
                throw NSError(domain: "FolderMedia", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unable to resolve local folder URL."])
            }
            let folderURL = access.folderURL
            let fileURL = item.localFileURL ?? folderURL.appendingPathComponent(item.filename)
            defer { access.stop() }

            if item.isVideo {
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "_" + item.filename)
                try FileManager.default.copyItem(at: fileURL, to: tempURL)
                let metadata = await exifService.parseFolderVideoMetadata(from: tempURL, item: item)
                return (nil, tempURL, tempURL, metadata)
            } else {
                let data = try Data(contentsOf: fileURL)
                let image = UIImage(data: data)
                let metadata: PhotoExifMetadata
                if let imageSource = CGImageSourceCreateWithData(data as CFData, nil) {
                    metadata = exifService.parseFolderPhotoMetadata(from: imageSource, rawData: data, item: item)
                } else {
                    throw NSError(domain: "FolderMedia", code: -6, userInfo: [NSLocalizedDescriptionKey: "Unable to read image data."])
                }
                return (image, nil, nil, metadata)
            }

        case .googleDrive(let account):
            guard let fileId = item.remoteFileID else {
                throw NSError(domain: "FolderMedia", code: -4, userInfo: [NSLocalizedDescriptionKey: "Missing Google Drive file ID."])
            }
            if item.isVideo {
                let metadata = try await loadRemoteVideoDetailMetadata(item: item) { [driveService] offset, length in
                    try await driveService.readFileRange(fileId: fileId, accountID: account.id, offset: offset, length: length)
                }
                return (nil, nil, nil, metadata)
            }
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "_" + item.filename)
            try await driveService.downloadFile(fileId: fileId, accountID: account.id, to: tempURL)
            return try await buildDetailResult(from: tempURL, item: item)

        case .samba(let destination):
            if item.isVideo {
                let metadata = try await loadRemoteVideoDetailMetadata(item: item) { [sambaService] offset, length in
                    try await sambaService.readFileRange(filename: item.filename, destination: destination, subfolderPath: item.subfolderPath, offset: offset, length: length)
                }
                return (nil, nil, nil, metadata)
            }
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "_" + item.filename)
            try await sambaService.downloadFile(filename: item.filename, destination: destination, subfolderPath: item.subfolderPath, to: tempURL)
            return try await buildDetailResult(from: tempURL, item: item)
        }
    }

    /// Creates a lazy on-demand byte-range streaming AVURLAsset handle for a remote video without downloading the full file.
    func makeRemoteVideoStream(for item: PhotoItem, in source: MediaSource) async throws -> RemoteVideoStreamHandle {
        switch source {
        case .samba(let destination):
            return try await sambaService.makeStreamingAsset(
                filename: item.filename,
                destination: destination,
                subfolderPath: item.subfolderPath
            )
        case .googleDrive(let account):
            guard let fileId = item.remoteFileID else {
                throw NSError(domain: "FolderMedia", code: -4, userInfo: [NSLocalizedDescriptionKey: "Missing Google Drive file ID."])
            }
            return try await driveService.makeStreamingAsset(
                fileId: fileId,
                filename: item.filename,
                knownFileSize: item.fileSize,
                accountID: account.id
            )
        case .photoLibrary, .localFolder:
            throw NSError(domain: "FolderMedia", code: -2, userInfo: [NSLocalizedDescriptionKey: "Remote streaming is only used for remote sources."])
        }
    }

    private func loadRemoteVideoDetailMetadata(
        item: PhotoItem,
        fetchRange: @escaping (UInt64, Int) async throws -> Data
    ) async throws -> PhotoExifMetadata {
        if let moovTempURL = try? await fetchVideoMoovToTempURL(filename: item.filename, fetchRange: fetchRange) {
            defer { try? FileManager.default.removeItem(at: moovTempURL) }
            return await exifService.parseFolderVideoMetadata(
                from: moovTempURL,
                item: item,
                knownByteCount: item.fileSize
            )
        }
        return exifService.fallbackFolderVideoMetadata(for: item)
    }

    private func buildDetailResult(
        from tempURL: URL,
        item: PhotoItem
    ) async throws -> (image: UIImage?, localVideoURL: URL?, tempFileToCleanup: URL?, metadata: PhotoExifMetadata) {
        if item.isVideo {
            let metadata = await exifService.parseFolderVideoMetadata(from: tempURL, item: item)
            return (nil, tempURL, tempURL, metadata)
        } else {
            defer { try? FileManager.default.removeItem(at: tempURL) }
            let data = try Data(contentsOf: tempURL)
            let image = UIImage(data: data)
            guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil) else {
                throw NSError(domain: "FolderMedia", code: -6, userInfo: [NSLocalizedDescriptionKey: "Unable to parse image."])
            }
            let metadata = exifService.parseFolderPhotoMetadata(from: imageSource, rawData: data, item: item)
            return (image, nil, nil, metadata)
        }
    }

    // MARK: - In-Place Delete & Rename

    func deleteItems(_ items: [PhotoItem], in source: MediaSource) async throws {
        switch source {
        case .photoLibrary:
            return
        case .localFolder:
            guard let access = source.beginLocalFolderAccess() else {
                throw NSError(domain: "FolderMedia", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unable to resolve local folder URL."])
            }
            let folderURL = access.folderURL
            defer { access.stop() }
            for item in items {
                let fileURL = item.localFileURL ?? folderURL.appendingPathComponent(item.filename)
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    try FileManager.default.removeItem(at: fileURL)
                }
            }
        case .googleDrive(let account):
            for item in items {
                guard let fileId = item.remoteFileID else { continue }
                try await driveService.deleteFile(fileId: fileId, accountID: account.id)
            }
        case .samba(let destination):
            for item in items {
                try await sambaService.deleteFile(filename: item.filename, destination: destination, subfolderPath: item.subfolderPath)
            }
        }
    }

    func deleteFolder(_ folder: FolderListEntry, in source: MediaSource) async throws {
        switch source {
        case .photoLibrary:
            return
        case .localFolder:
            guard let access = source.beginLocalFolderAccess() else {
                throw NSError(domain: "FolderMedia", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unable to resolve local folder URL."])
            }
            defer { access.stop() }
            let targetURL = folder.targetSource.resolveLocalFolderURL() ?? access.folderURL.appendingPathComponent(folder.name, isDirectory: true)
            if FileManager.default.fileExists(atPath: targetURL.path) {
                try FileManager.default.removeItem(at: targetURL)
            }
        case .googleDrive(let account):
            try await driveService.deleteFile(fileId: folder.id, accountID: account.id)
        case .samba(let destination):
            let cleanShare = destination.share.trimmingCharacters(in: CharacterSet(charactersIn: " /\\"))
            guard !cleanShare.isEmpty else {
                throw NSError(domain: "FolderMedia", code: -9, userInfo: [NSLocalizedDescriptionKey: "Shares cannot be deleted from the server root."])
            }
            try await sambaService.deleteFolder(folderName: folder.name, destination: destination)
        }
    }

    func renameItem(_ item: PhotoItem, to newFilename: String, in source: MediaSource) async throws -> PhotoItem {
        switch source {
        case .photoLibrary:
            return item.withFilename(newFilename)
        case .localFolder:
            guard let access = source.beginLocalFolderAccess() else {
                throw NSError(domain: "FolderMedia", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unable to resolve local folder URL."])
            }
            let folderURL = access.folderURL
            defer { access.stop() }
            let oldURL = item.localFileURL ?? folderURL.appendingPathComponent(item.filename)
            let newURL = oldURL.deletingLastPathComponent().appendingPathComponent(newFilename)
            if oldURL.path != newURL.path && FileManager.default.fileExists(atPath: newURL.path) {
                throw NSError(domain: "FolderMedia", code: -7, userInfo: [NSLocalizedDescriptionKey: "A file named '\(newFilename)' already exists."])
            }
            try FileManager.default.moveItem(at: oldURL, to: newURL)
            return item.withFilename(newFilename, localFileURL: newURL, updatingSource: true)
        case .googleDrive(let account):
            guard let fileId = item.remoteFileID else {
                throw NSError(domain: "FolderMedia", code: -4, userInfo: [NSLocalizedDescriptionKey: "Missing Google Drive file ID."])
            }
            try await driveService.renameFile(fileId: fileId, newName: newFilename, accountID: account.id)
            return item.withFilename(newFilename, updatingSource: true)
        case .samba(let destination):
            try await sambaService.renameFile(from: item.effectiveSourceFilename, to: newFilename, destination: destination, subfolderPath: item.effectiveSourceSubfolderPath)
            return item.withFilename(newFilename, updatingSource: true)
        }
    }

    // MARK: - Apply Inferred / Adjusted Metadata In Place

    /// Inserts an 8-character UUID before the file extension (e.g. `a.mov` -> `a.<UUID>.mov`).
    nonisolated static func stagedFilename(for filename: String) -> String {
        let ns = filename as NSString
        let ext = ns.pathExtension
        let base = ns.deletingPathExtension
        let uniqueID = String(UUID().uuidString.prefix(8))
        return ext.isEmpty ? "\(base).\(uniqueID)" : "\(base).\(uniqueID).\(ext)"
    }

    /// Copies (for local folders) or downloads (for Google Drive / Samba) a source media file to `destinationURL`.
    func downloadOrCopySourceFile(
        for item: PhotoItem,
        in source: MediaSource,
        to destinationURL: URL,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destinationURL.path) {
            try? fileManager.removeItem(at: destinationURL)
        }

        switch source {
        case .photoLibrary:
            throw NSError(domain: "FolderMedia", code: -10, userInfo: [NSLocalizedDescriptionKey: "Photo Library source is not a folder source."])
        case .localFolder:
            guard let access = source.beginLocalFolderAccess() else {
                throw NSError(domain: "FolderMedia", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unable to resolve local folder URL."])
            }
            let folderURL = access.folderURL
            let srcURL = item.localFileURL ?? folderURL.appendingPathComponent(item.effectiveSourceFilename)
            defer { access.stop() }
            try fileManager.copyItem(at: srcURL, to: destinationURL)
            progressHandler?(1.0)
        case .googleDrive(let account):
            guard let fileId = item.remoteFileID else {
                throw NSError(domain: "FolderMedia", code: -4, userInfo: [NSLocalizedDescriptionKey: "Missing Google Drive file ID."])
            }
            try await driveService.downloadFile(
                fileId: fileId,
                accountID: account.id,
                to: destinationURL,
                expectedFileSize: item.fileSize,
                progressHandler: progressHandler
            )
        case .samba(let destination):
            try await sambaService.downloadFile(
                filename: item.effectiveSourceFilename,
                destination: destination,
                subfolderPath: item.effectiveSourceSubfolderPath,
                to: destinationURL,
                expectedFileSize: item.fileSize,
                progressHandler: progressHandler
            )
        }
    }

    func applyChangesInPlace(
        items: [PhotoItem],
        in source: MediaSource,
        totalBatchCount: Int? = nil,
        initialSuccessfulItems: [PhotoItem] = [],
        onBeforeFinalSwap: (@Sendable (PhotoItem) async -> Void)? = nil,
        progressHandler: @escaping (ExportProgress) -> Void
    ) async -> ExportProgress {
        let fileManager = FileManager.default
        let sizesLock = NSLock()
        var updatedSizes: [String: Int64] = [:]

        var finalProgress = await ExportBatchRunner.runRemoteBatch(
            serviceName: "ApplyInPlace",
            items: items,
            totalBatchCount: totalBatchCount,
            initialSuccessfulItems: initialSuccessfulItems,
            isApplyInPlace: true,
            progressHandler: progressHandler,
            exportItem: { [weak self] item, itemProgress in
                guard let self else { return }
                let workingURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString + "_" + item.filename)
                let outputURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString + "_out_" + item.filename)
                defer {
                    try? fileManager.removeItem(at: workingURL)
                    try? fileManager.removeItem(at: outputURL)
                }

                // 1. Fetch source file to workingURL (0.0 -> 0.35)
                if case .photoLibrary = source { return }
                try await self.downloadOrCopySourceFile(for: item, in: source, to: workingURL) { dlFraction in
                    itemProgress(dlFraction * 0.35)
                }
                itemProgress(0.35)

                // 2. Embed metadata (and apply any pending rotation) into outputURL (0.35 -> 0.55)
                let targetDate = item.creationDate ?? item.embeddedDate ?? item.fileModificationDate
                let rotationSteps = ExifMetadataService.clockwiseSteps(forDegrees: item.pendingRotationDegrees)
                if item.isVideo {
                    try await self.exifService.embedAdjustedVideoMetadata(
                        sourceURL: workingURL,
                        destinationURL: outputURL,
                        targetDate: targetDate,
                        timeZone: item.timeZone,
                        adjustedLocation: item.isGPSAdjusted ? item.location : nil,
                        isGPSAdjusted: item.isGPSAdjusted,
                        clockwiseRotationSteps: rotationSteps
                    )
                } else {
                    let imageData = try Data(contentsOf: workingURL)
                    let modifiedData = try self.exifService.embedAdjustedMetadata(
                        imageData: imageData,
                        targetDate: targetDate,
                        timeZone: item.timeZone,
                        adjustedLocation: item.isGPSAdjusted ? item.location : nil,
                        isGPSAdjusted: item.isGPSAdjusted,
                        clockwiseRotationSteps: rotationSteps
                    )
                    try modifiedData.write(to: outputURL, options: .atomic)
                }
                itemProgress(0.55)

                // 3. Persist updated content to the backing store (0.55 -> 1.0)
                switch source {
                case .photoLibrary:
                    break
                case .localFolder:
                    guard let access = source.beginLocalFolderAccess() else { break }
                    let folderURL = access.folderURL
                    let destURL = item.localFileURL ?? folderURL.appendingPathComponent(item.effectiveSourceFilename)
                    let stagedFilename = Self.stagedFilename(for: destURL.lastPathComponent)
                    let stagedURL = destURL.deletingLastPathComponent().appendingPathComponent(stagedFilename)
                    defer { access.stop() }
                    do {
                        if fileManager.fileExists(atPath: stagedURL.path) {
                            try? fileManager.removeItem(at: stagedURL)
                        }
                        try fileManager.copyItem(at: outputURL, to: stagedURL)
                        let stagedSize = (try? fileManager.attributesOfItem(atPath: stagedURL.path)[.size] as? Int64) ?? 0
                        guard stagedSize > 0 else {
                            throw NSError(domain: "FolderMedia", code: -8, userInfo: [NSLocalizedDescriptionKey: "Failed to create updated local file '\(stagedFilename)'."])
                        }
                        if fileManager.fileExists(atPath: destURL.path) {
                            try fileManager.removeItem(at: destURL)
                        }
                        try fileManager.moveItem(at: stagedURL, to: destURL)
                        if let targetDate {
                            try? fileManager.setAttributes([.creationDate: targetDate, .modificationDate: targetDate], ofItemAtPath: destURL.path)
                        }
                    } catch {
                        if fileManager.fileExists(atPath: destURL.path) && fileManager.fileExists(atPath: stagedURL.path) {
                            try? fileManager.removeItem(at: stagedURL)
                        }
                        throw error
                    }
                case .googleDrive(let account):
                    guard let fileId = item.remoteFileID else { break }
                    try await self.driveService.updateFileContent(
                        fileId: fileId,
                        localURL: outputURL,
                        filename: item.effectiveSourceFilename,
                        photoDate: targetDate,
                        accountID: account.id,
                        progressHandler: { uploadFraction in
                            itemProgress(0.55 + uploadFraction * 0.42)
                        }
                    )
                case .samba(let destination):
                    try await self.sambaService.replaceFileSafely(
                        localURL: outputURL,
                        filename: item.effectiveSourceFilename,
                        destination: destination,
                        subfolderPath: item.effectiveSourceSubfolderPath,
                        creationDate: targetDate,
                        progressHandler: { uploadFraction in
                            itemProgress(0.55 + uploadFraction * 0.42)
                        },
                        onBeforeSwap: {
                            await onBeforeFinalSwap?(item)
                        }
                    )
                }

                // Render the updated thumbnail directly from `outputURL` so list rows refresh immediately
                // without hitting stale remote CDN thumbnail caches.
                let freshThumb: UIImage? = if item.isVideo {
                    await Self.videoThumbnailFromURL(outputURL, maxPixelSize: 180)
                } else {
                    await Task.detached(priority: .utility) {
                        Self.thumbnailFromURL(outputURL, maxPixelSize: 180)
                    }.value
                }
                if let freshThumb {
                    let pendingKey = self.itemCacheTrackingKey(for: item, in: source)
                    self.cacheKeysLock.lock()
                    self.pendingAppliedThumbnails[pendingKey] = freshThumb
                    self.cacheKeysLock.unlock()
                }
                if let outputSize = (try? fileManager.attributesOfItem(atPath: outputURL.path)[.size] as? Int64), outputSize > 0 {
                    sizesLock.lock()
                    updatedSizes[item.id] = outputSize
                    sizesLock.unlock()
                }
                self.invalidateThumbnailCache(for: item, in: source)
                itemProgress(1.0)
            }
        )
        finalProgress.updatedFileSizes = updatedSizes
        return finalProgress
    }
}

/// Retains a custom `AVAssetResourceLoaderDelegate` and underlying stream cleanup hook for the lifetime of an `AVURLAsset` stream.
nonisolated final class RemoteVideoStreamHandle: @unchecked Sendable {
    let asset: AVURLAsset
    private let loader: RemoteVideoResourceLoaderDelegate
    private let onClose: (@Sendable () -> Void)?
    private let onCloseAsync: (@Sendable () async -> Void)?
    private let closeLock = NSLock()
    private var hasClosed = false

    private init(
        asset: AVURLAsset,
        loader: RemoteVideoResourceLoaderDelegate,
        onClose: (@Sendable () -> Void)?,
        onCloseAsync: (@Sendable () async -> Void)?
    ) {
        self.asset = asset
        self.loader = loader
        self.onClose = onClose
        self.onCloseAsync = onCloseAsync
    }

    static func make(
        filename: String,
        fileSize: UInt64,
        chunkSize: Int = 65_536,
        scheme: String = "remote-video",
        onClose: (@Sendable () -> Void)? = nil,
        onCloseAsync: (@Sendable () async -> Void)? = nil,
        readChunk: @escaping @Sendable (_ offset: UInt64, _ length: Int) async throws -> Data
    ) throws -> RemoteVideoStreamHandle {
        try makeStreaming(
            filename: filename,
            fileSize: fileSize,
            scheme: scheme,
            onClose: onClose,
            onCloseAsync: onCloseAsync
        ) { offset, length, onData in
            var cursor = offset
            let endOffset = offset + length
            while cursor < endOffset {
                if Task.isCancelled {
                    throw CancellationError()
                }
                let toRead = Int(min(UInt64(chunkSize), endOffset - cursor))
                let chunk = try await readChunk(cursor, toRead)
                if Task.isCancelled {
                    throw CancellationError()
                }
                if chunk.isEmpty {
                    break
                }
                onData(chunk)
                cursor += UInt64(chunk.count)
            }
        }
    }

    static func makeStreaming(
        filename: String,
        fileSize: UInt64,
        scheme: String = "remote-video",
        onClose: (@Sendable () -> Void)? = nil,
        onCloseAsync: (@Sendable () async -> Void)? = nil,
        streamRange: @escaping @Sendable (_ offset: UInt64, _ length: UInt64, _ onData: @escaping @Sendable (Data) -> Void) async throws -> Void
    ) throws -> RemoteVideoStreamHandle {
        let ext = (filename as NSString).pathExtension.lowercased()
        let contentType = UTType(filenameExtension: ext)?.identifier ?? UTType.mpeg4Movie.identifier
        var components = URLComponents()
        components.scheme = scheme
        components.host = "stream"
        components.path = "/\(UUID().uuidString).\(ext.isEmpty ? "mp4" : ext)"
        guard let virtualURL = components.url else {
            throw NSError(domain: "RemoteVideoStream", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unable to create stream URL."])
        }

        let loader = RemoteVideoResourceLoaderDelegate(
            fileSize: fileSize,
            contentType: contentType,
            streamRange: streamRange
        )
        let loaderQueue = DispatchQueue(label: "com.photoexporter.remote.videostream.\(UUID().uuidString)")
        let asset = AVURLAsset(url: virtualURL)
        asset.resourceLoader.setDelegate(loader, queue: loaderQueue)
        return RemoteVideoStreamHandle(asset: asset, loader: loader, onClose: onClose, onCloseAsync: onCloseAsync)
    }

    func close() {
        closeLock.lock()
        guard !hasClosed else {
            closeLock.unlock()
            return
        }
        hasClosed = true
        closeLock.unlock()
        loader.cancelAll()
        onClose?()
        if let onCloseAsync {
            Task {
                await onCloseAsync()
            }
        }
    }

    /// Cancels active loading and awaits underlying remote stream/socket close before returning.
    func closeAndWait() async {
        closeLock.lock()
        guard !hasClosed else {
            closeLock.unlock()
            return
        }
        hasClosed = true
        closeLock.unlock()
        loader.cancelAll()
        onClose?()
        await onCloseAsync?()
    }

    deinit {
        close()
    }
}

private struct RemoteStreamSendableBox<T>: @unchecked Sendable {
    let value: T
}

/// Thread-safe helper that forwards streamed bytes to `AVAssetResourceLoadingDataRequest`.
private final class RemoteStreamResponder: @unchecked Sendable {
    private let lock = NSLock()

    func respond(
        chunk: Data,
        request: AVAssetResourceLoadingRequest,
        dataRequest: AVAssetResourceLoadingDataRequest
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard !request.isCancelled else { return }
        dataRequest.respond(with: chunk)
    }
}

/// Bridges `AVAssetResourceLoader` byte-range requests onto any async streaming remote range reader.
private nonisolated final class RemoteVideoResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    private let fileSize: UInt64
    private let contentType: String
    private let streamRange: @Sendable (_ offset: UInt64, _ length: UInt64, _ onData: @escaping @Sendable (Data) -> Void) async throws -> Void
    private let lock = NSLock()
    private var activeTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var isClosed = false

    init(
        fileSize: UInt64,
        contentType: String,
        streamRange: @escaping @Sendable (_ offset: UInt64, _ length: UInt64, _ onData: @escaping @Sendable (Data) -> Void) async throws -> Void
    ) {
        self.fileSize = fileSize
        self.contentType = contentType
        self.streamRange = streamRange
        super.init()
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        if let infoRequest = loadingRequest.contentInformationRequest {
            infoRequest.contentType = contentType
            infoRequest.contentLength = Int64(fileSize)
            infoRequest.isByteRangeAccessSupported = true
        }

        guard loadingRequest.dataRequest != nil else {
            loadingRequest.finishLoading()
            return true
        }

        let key = ObjectIdentifier(loadingRequest)
        let requestBox = RemoteStreamSendableBox(value: loadingRequest)

        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.removeTask(for: key)
            }
            await self.handle(requestBox.value)
        }

        lock.lock()
        if isClosed {
            lock.unlock()
            task.cancel()
            loadingRequest.finishLoading(with: CancellationError())
            return true
        }
        activeTasks[key] = task
        lock.unlock()
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        let key = ObjectIdentifier(loadingRequest)
        lock.lock()
        let task = activeTasks.removeValue(forKey: key)
        lock.unlock()
        task?.cancel()
    }

    func cancelAll() {
        lock.lock()
        isClosed = true
        let tasks = Array(activeTasks.values)
        activeTasks.removeAll()
        lock.unlock()
        for task in tasks {
            task.cancel()
        }
    }

    private func removeTask(for key: ObjectIdentifier) {
        lock.lock()
        activeTasks.removeValue(forKey: key)
        lock.unlock()
    }

    private func handle(_ loadingRequest: AVAssetResourceLoadingRequest) async {
        guard let dataRequest = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            return
        }

        let startOffset = UInt64(max(Int64(0), dataRequest.currentOffset))
        guard startOffset < fileSize else {
            if !loadingRequest.isCancelled {
                loadingRequest.finishLoading()
            }
            return
        }

        let endOffset: UInt64
        if dataRequest.requestsAllDataToEndOfResource {
            endOffset = fileSize
        } else {
            let requestedEnd = UInt64(max(Int64(0), dataRequest.requestedOffset)) + UInt64(max(0, dataRequest.requestedLength))
            endOffset = min(fileSize, requestedEnd)
        }

        let responder = RemoteStreamResponder()
        let requestBox = RemoteStreamSendableBox(value: loadingRequest)
        let dataRequestBox = RemoteStreamSendableBox(value: dataRequest)
        let requestedLength = endOffset - startOffset

        do {
            try await streamRange(startOffset, requestedLength) { chunk in
                guard !chunk.isEmpty else { return }
                responder.respond(
                    chunk: chunk,
                    request: requestBox.value,
                    dataRequest: dataRequestBox.value
                )
            }
            if !Task.isCancelled && !loadingRequest.isCancelled {
                loadingRequest.finishLoading()
            }
        } catch is CancellationError {
            return
        } catch {
            if !Task.isCancelled && !loadingRequest.isCancelled {
                loadingRequest.finishLoading(with: error)
            }
        }
    }
}

