//
//  SambaService.swift
//  Photo Exporter
//

import Foundation
import Combine
import Network
import Photos
import UIKit
import AVFoundation
import UniformTypeIdentifiers

/// Manages Samba (SMB) network share destinations, connectivity testing, and file exports
final class SambaService: ObservableObject {
    static let shared = SambaService()

    @Published var destinations: [SambaDestination] = []

    private let storageKey = "configured_samba_destinations"
    private let libraryService = PhotoLibraryService.shared
    private let exifService = ExifMetadataService.shared
    private let sessionPool = SambaSessionPool()

    private init() {
        loadDestinations()
    }

    // MARK: - Persistence

    func loadDestinations() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([SambaDestination].self, from: data) else {
            self.destinations = []
            return
        }
        self.destinations = decoded
    }

    private func saveDestinations() {
        if let encoded = try? JSONEncoder().encode(destinations) {
            UserDefaults.standard.set(encoded, forKey: storageKey)
        }
    }

    func addDestination(_ destination: SambaDestination) {
        if let idx = destinations.firstIndex(where: { $0.id == destination.id }) {
            let previous = destinations[idx]
            sessionPool.invalidate(destination: previous)
            destinations[idx] = destination
        } else {
            destinations.append(destination)
        }
        sessionPool.invalidate(destination: destination)
        saveDestinations()
    }

    private struct LastBrowsedFolder: Codable {
        let share: String
        let path: String
    }

    private static func lastBrowsedFolderStorageKey(for destinationID: String) -> String {
        "last_browsed_samba_folder_\(destinationID)"
    }

    /// Returns a copy of `destination` positioned at the user's last-picked media-source folder if one was recorded.
    func lastBrowsedDestination(for destination: SambaDestination) -> SambaDestination {
        guard let data = UserDefaults.standard.data(forKey: Self.lastBrowsedFolderStorageKey(for: destination.id)),
              let saved = try? JSONDecoder().decode(LastBrowsedFolder.self, from: data) else {
            return destination
        }
        var copy = destination
        copy.share = saved.share
        copy.path = saved.path
        return copy
    }

    /// Remembers the share and subpath picked while browsing this Samba server as a media source.
    func saveLastBrowsedFolder(for destination: SambaDestination) {
        let cleanShare = destination.share.trimmingCharacters(in: CharacterSet(charactersIn: " /\\"))
        let cleanPath = cleanShare.isEmpty ? "" : destination.path.trimmingCharacters(in: CharacterSet(charactersIn: " /\\"))
        let payload = LastBrowsedFolder(share: cleanShare, path: cleanPath)
        if let encoded = try? JSONEncoder().encode(payload) {
            UserDefaults.standard.set(encoded, forKey: Self.lastBrowsedFolderStorageKey(for: destination.id))
        }
    }

    func removeDestination(id: String) {
        for destination in destinations where destination.id == id {
            sessionPool.invalidate(destination: destination)
        }
        destinations.removeAll { $0.id == id }
        UserDefaults.standard.removeObject(forKey: Self.lastBrowsedFolderStorageKey(for: id))
        saveDestinations()
    }

    // MARK: - Connection & Authentication Testing

    /// Test SMB2 connectivity, authentication credentials (or guest access), and share accessibility
    func testConnection(to destination: SambaDestination) async throws -> Bool {
        try await SMB2Client.testAuthentication(destination: destination)
        return true
    }

    // MARK: - Share & Folder Browsing

    /// Enumerates visible shares on the Samba server (treated as root folders)
    func listShares(for destination: SambaDestination) async throws -> [String] {
        try await SMB2Client.listShares(destination: destination)
    }

    /// Lists child folder names inside the share represented by `destination` at `relativePath`
    func listSubdirectories(for destination: SambaDestination, at relativePath: String = "") async throws -> [String] {
        try await listFolderContents(for: destination, at: relativePath).subfolders
    }

    /// Lists child folder names along with image and video counts inside the folder
    func listFolderContents(for destination: SambaDestination, at relativePath: String = "") async throws -> (subfolders: [String], imageCount: Int, videoCount: Int) {
        let fullPath = buildRemotePath(destination: destination, subfolderPath: relativePath)
        return try await sessionPool.withPooledSession(for: destination) { session in
            try await session.listDirectoryContents(path: fullPath)
        }
    }

    /// Creates a new subfolder inside the share represented by `destination`
    func createSubdirectory(named folderName: String, in parentRelativePath: String = "", for destination: SambaDestination) async throws {
        let trimmed = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("/"),
              !trimmed.contains("\\"),
              trimmed != ".",
              trimmed != ".." else {
            throw SMB2Client.makeError("Please enter a valid folder name.")
        }
        let targetPath = buildRemotePath(destination: destination, subfolderPath: parentRelativePath, filename: trimmed)
        try await sessionPool.withPooledSession(for: destination) { session in
            try await session.createSubdirectory(path: targetPath)
        }
    }

    // MARK: - Destination Files & Conflict Checking

    private func buildRemotePath(destination: SambaDestination, subfolderPath: String, filename: String? = nil) -> String {
        let cleanSubpath = destination.path
            .replacingOccurrences(of: "/", with: "\\")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\\"))
        let cleanSubfolder = subfolderPath
            .replacingOccurrences(of: "/", with: "\\")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\\"))

        var fullPath = cleanSubpath
        if !cleanSubfolder.isEmpty {
            fullPath = fullPath.isEmpty ? cleanSubfolder : "\(fullPath)\\\(cleanSubfolder)"
        }
        if let filename, !filename.isEmpty {
            fullPath = fullPath.isEmpty ? filename : "\(fullPath)\\\(filename)"
        }
        return fullPath
    }

    /// Query remote Samba share to fetch all destination files with metadata (modification date and size)
    func fetchDestinationFiles(destination: SambaDestination, subfolderPath: String = "") async throws -> [DestinationFileInfo] {
        let fullPath = buildRemotePath(destination: destination, subfolderPath: subfolderPath)
        return try await sessionPool.withPooledSession(for: destination) { session in
            do {
                var files = try await session.listDirectoryDetails(path: fullPath)
                for i in 0..<files.count {
                    files[i].subfolderPath = subfolderPath
                }
                return files
            } catch {
                if isBrokenConnectionError(error) || !session.isReadyForReuse {
                    throw error
                }
                return []
            }
        }
    }

    /// Queries both subdirectories and files (with modification dates & sizes) in a single directory scan.
    func fetchDirectoryEntries(destination: SambaDestination, subfolderPath: String = "") async throws -> (folders: [DestinationFileInfo], files: [DestinationFileInfo]) {
        let fullPath = buildRemotePath(destination: destination, subfolderPath: subfolderPath)
        return try await sessionPool.withPooledSession(for: destination) { session in
            var result = try await session.listDirectoryEntries(path: fullPath, throwOnOpenError: true)
            for i in 0..<result.files.count {
                result.files[i].subfolderPath = subfolderPath
            }
            return result
        }
    }

    /// Read file data from the destination share for thumbnail generation
    func readFileData(filename: String, destination: SambaDestination, subfolderPath: String = "", maxBytes: Int = 8 * 1024 * 1024) async throws -> Data {
        let fullPath = buildRemotePath(destination: destination, subfolderPath: subfolderPath, filename: filename)
        return try await sessionPool.withPooledSession(for: destination) { session in
            try await session.readFileData(relativePath: fullPath, maxBytes: maxBytes)
        }
    }

    /// Read a byte range from a Samba file (used for header-only metadata extraction)
    func readFileRange(filename: String, destination: SambaDestination, subfolderPath: String = "", offset: UInt64, length: Int) async throws -> Data {
        let fullPath = buildRemotePath(destination: destination, subfolderPath: subfolderPath, filename: filename)
        return try await sessionPool.withPooledSession(for: destination) { session in
            let fileId = try await session.openFileForRead(relativePath: fullPath)
            var result = Data()
            result.reserveCapacity(length)
            try await readFileBytes(session: session, fileId: fileId, offset: offset, length: length, into: &result)
            try await session.closeFile(fileId: fileId)
            return result
        }
    }

    private func readFileBytes(
        session: SMB2ClientSession,
        fileId: Data,
        offset: UInt64,
        length: Int,
        into buffer: inout Data
    ) async throws {
        var currentOffset = offset
        var remaining = length
        while remaining > 0 {
            try Task.checkCancellation()
            let chunkLen = UInt32(min(remaining, 65536))
            let chunk = try await session.readChunk(fileId: fileId, offset: currentOffset, length: chunkLen)
            if chunk.isEmpty { break }
            buffer.append(chunk)
            currentOffset += UInt64(chunk.count)
            remaining -= chunk.count
        }
    }

    /// Generates an image thumbnail by reading a 128 KB header first for embedded EXIF/TIFF JPEG thumbnails,
    /// fetching only the embedded range when larger, or continuing on the same open SMB file handle as fallback.
    func generateImageThumbnail(
        filename: String,
        destination: SambaDestination,
        subfolderPath: String = "",
        knownFileSize: Int64 = 0,
        maxPixelSize: CGFloat = 180
    ) async -> UIImage? {
        let fullPath = buildRemotePath(destination: destination, subfolderPath: subfolderPath, filename: filename)
        do {
            return try await sessionPool.withPooledSession(for: destination, timeoutSeconds: 8.0) { session in
                try Task.checkCancellation()
                let (fileId, reportedSize) = try await session.openFileForReadWithSize(relativePath: fullPath)
                let resolvedSize: Int
                if reportedSize > 0 {
                    resolvedSize = Int(min(reportedSize, UInt64(Int.max)))
                } else if knownFileSize > 0 {
                    resolvedSize = Int(knownFileSize)
                } else {
                    resolvedSize = 0
                }
                guard resolvedSize > 0 else {
                    try await session.closeFile(fileId: fileId)
                    return nil
                }

                let headerLimit = min(resolvedSize, 131_072)
                var headerData = Data()
                headerData.reserveCapacity(headerLimit)
                try await readFileBytes(session: session, fileId: fileId, offset: 0, length: headerLimit, into: &headerData)
                guard !headerData.isEmpty else {
                    try await session.closeFile(fileId: fileId)
                    return nil
                }

                switch FolderMediaService.inspectEmbeddedThumbnail(in: headerData) {
                case .embedded(let embeddedData, let orientation):
                    if let image = await Task.detached(priority: .utility, operation: {
                        FolderMediaService.renderEmbeddedJPEGThumbnail(from: embeddedData, exifOrientation: orientation, maxPixelSize: maxPixelSize)
                    }).value {
                        try Task.checkCancellation()
                        try await session.closeFile(fileId: fileId)
                        return image
                    }

                case .range(let thumbOffset, let thumbLength, let orientation):
                    if thumbLength > 0 && thumbLength <= 4 * 1024 * 1024 && thumbOffset < UInt64(resolvedSize) {
                        let clampedLength = Int(min(UInt64(thumbLength), UInt64(resolvedSize) - thumbOffset))
                        var rangeData = Data()
                        rangeData.reserveCapacity(clampedLength)
                        if thumbOffset < UInt64(headerData.count) {
                            let localStart = Int(thumbOffset)
                            let localEnd = min(headerData.count, localStart + clampedLength)
                            rangeData.append(headerData[localStart..<localEnd])
                        }
                        let remainingToRead = clampedLength - rangeData.count
                        if remainingToRead > 0 {
                            try await readFileBytes(
                                session: session,
                                fileId: fileId,
                                offset: thumbOffset + UInt64(rangeData.count),
                                length: remainingToRead,
                                into: &rangeData
                            )
                        }
                        if !rangeData.isEmpty,
                           let image = await Task.detached(priority: .utility, operation: {
                               FolderMediaService.renderEmbeddedJPEGThumbnail(from: rangeData, exifOrientation: orientation, maxPixelSize: maxPixelSize)
                           }).value {
                            try Task.checkCancellation()
                            try await session.closeFile(fileId: fileId)
                            return image
                        }
                    }

                case .none:
                    break
                }

                let fullReadLimit = min(resolvedSize, 16 * 1024 * 1024)
                let remainingBytes = max(0, fullReadLimit - headerData.count)
                if remainingBytes > 0 {
                    try await readFileBytes(
                        session: session,
                        fileId: fileId,
                        offset: UInt64(headerData.count),
                        length: remainingBytes,
                        into: &headerData
                    )
                }
                try await session.closeFile(fileId: fileId)
                guard !Task.isCancelled else { return nil }

                let fullPayload = headerData
                return await Task.detached(priority: .utility) {
                    FolderMediaService.thumbnailFromData(fullPayload, maxPixelSize: maxPixelSize)
                }.value
            }
        } catch {
            return nil
        }
    }

    /// Generates a video thumbnail by streaming only required byte ranges (header/moov/first frame) over SMB2
    func generateVideoThumbnail(
        filename: String,
        destination: SambaDestination,
        subfolderPath: String = "",
        maxPixelSize: CGFloat = 180
    ) async -> UIImage? {
        do {
            let (session, stream, fileSize) = try await openVideoReadStream(
                filename: filename,
                destination: destination,
                subfolderPath: subfolderPath
            )

            let streamHandle = try RemoteVideoStreamHandle.make(
                filename: filename,
                fileSize: fileSize,
                chunkSize: 65_536,
                scheme: "smb-thumb"
            ) { offset, length in
                try await stream.readChunk(offset: offset, length: UInt32(length))
            }

            let generator = AVAssetImageGenerator(asset: streamHandle.asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)

            let cgImage = try? await generator.image(at: .zero).image
            streamHandle.close()
            let streamHealthy = await stream.close()
            sessionPool.release(session, for: destination, healthy: streamHealthy && !Task.isCancelled)

            return cgImage.map { UIImage(cgImage: $0) }
        } catch {
            return nil
        }
    }

    /// Creates a lazy on-demand byte-range streaming handle for SMB2 video playback
    func makeStreamingAsset(
        filename: String,
        destination: SambaDestination,
        subfolderPath: String = ""
    ) async throws -> RemoteVideoStreamHandle {
        let (session, stream, fileSize) = try await openVideoReadStream(
            filename: filename,
            destination: destination,
            subfolderPath: subfolderPath
        )

        do {
            return try RemoteVideoStreamHandle.make(
                filename: filename,
                fileSize: fileSize,
                chunkSize: 65_536,
                scheme: "smb-stream",
                onCloseAsync: { [sessionPool, destination] in
                    let streamHealthy = await stream.close()
                    await MainActor.run {
                        sessionPool.release(session, for: destination, healthy: streamHealthy)
                    }
                }
            ) { offset, length in
                try await stream.readChunk(offset: offset, length: UInt32(length))
            }
        } catch {
            let streamHealthy = await stream.close()
            sessionPool.release(session, for: destination, healthy: streamHealthy)
            throw error
        }
    }

    private func openVideoReadStream(
        filename: String,
        destination: SambaDestination,
        subfolderPath: String
    ) async throws -> (session: SMB2ClientSession, stream: SambaVideoReadStream, fileSize: UInt64) {
        let fullPath = buildRemotePath(destination: destination, subfolderPath: subfolderPath, filename: filename)
        var (session, wasReused) = try await sessionPool.borrow(for: destination, timeoutSeconds: 8.0)
        let openResult: (fileId: Data, fileSize: UInt64)
        do {
            openResult = try await session.openFileForReadWithSize(relativePath: fullPath)
        } catch {
            sessionPool.release(session, for: destination, healthy: false)
            guard wasReused && !(error is CancellationError) && !Task.isCancelled else {
                throw error
            }
            (session, _) = try await sessionPool.borrow(for: destination, timeoutSeconds: 8.0, allowReuse: false)
            do {
                openResult = try await session.openFileForReadWithSize(relativePath: fullPath)
            } catch {
                sessionPool.release(session, for: destination, healthy: false)
                throw error
            }
        }

        let fileId = openResult.fileId
        let fileSize = openResult.fileSize
        guard fileSize > 0 else {
            let closedCleanly = (try? await session.closeFile(fileId: fileId)) != nil
            sessionPool.release(session, for: destination, healthy: closedCleanly && !Task.isCancelled && session.isReadyForReuse)
            throw SMB2Client.makeError("Remote video file is empty.")
        }

        return (session, SambaVideoReadStream(session: session, fileId: fileId, fileSize: fileSize), fileSize)
    }

    /// Download a full Samba file to a local URL
    func downloadFile(
        filename: String,
        destination: SambaDestination,
        subfolderPath: String = "",
        to localURL: URL,
        expectedFileSize: Int64? = nil,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        let fullPath = buildRemotePath(destination: destination, subfolderPath: subfolderPath, filename: filename)
        try await sessionPool.withPooledSession(for: destination) { session in
            let (fileId, reportedSize) = try await session.openFileForReadWithSize(relativePath: fullPath)
            let totalBytes = reportedSize > 0 ? reportedSize : UInt64(max(0, expectedFileSize ?? 0))
            FileManager.default.createFile(atPath: localURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: localURL)
            defer { try? handle.close() }
            var offset: UInt64 = 0
            while true {
                try Task.checkCancellation()
                let chunk = try await session.readChunk(fileId: fileId, offset: offset, length: 65536)
                if chunk.isEmpty { break }
                handle.write(chunk)
                offset += UInt64(chunk.count)
                if totalBytes > 0 {
                    progressHandler?(min(1.0, Double(offset) / Double(totalBytes)))
                }
            }
            try await session.closeFile(fileId: fileId)
        }
    }

    /// Upload/overwrite a single local file onto the Samba share
    func uploadLocalFile(localURL: URL, filename: String, destination: SambaDestination, subfolderPath: String = "", creationDate: Date? = nil) async throws {
        let fullPath = buildRemotePath(destination: destination, subfolderPath: subfolderPath, filename: filename)
        try await sessionPool.withPooledSession(for: destination) { session in
            try await session.uploadFile(localURL: localURL, remoteRelativePath: fullPath, creationDate: creationDate)
        }
    }

    /// Delete a file from the Samba share
    func deleteFile(filename: String, destination: SambaDestination, subfolderPath: String = "") async throws {
        let fullPath = buildRemotePath(destination: destination, subfolderPath: subfolderPath, filename: filename)
        try await sessionPool.withPooledSession(for: destination) { session in
            try await session.deleteFile(relativePath: fullPath)
        }
    }

    /// Recursively delete a folder from the Samba share
    func deleteFolder(folderName: String, destination: SambaDestination, subfolderPath: String = "") async throws {
        let fullPath = buildRemotePath(destination: destination, subfolderPath: subfolderPath, filename: folderName)
        try await sessionPool.withPooledSession(for: destination) { session in
            try await session.deleteDirectory(relativePath: fullPath)
        }
    }

    /// Rename a file on the Samba share
    func renameFile(from oldFilename: String, to newFilename: String, destination: SambaDestination, subfolderPath: String = "") async throws {
        let oldPath = buildRemotePath(destination: destination, subfolderPath: subfolderPath, filename: oldFilename)
        let newPath = buildRemotePath(destination: destination, subfolderPath: subfolderPath, filename: newFilename)
        try await sessionPool.withPooledSession(for: destination) { session in
            try await session.renameFile(from: oldPath, to: newPath)
        }
    }

    /// Atomically replaces an existing Samba file in place by uploading to `<base>.<uniqueID>.<ext>` in the
    /// same directory first, then renaming the temp file over `<filename>` with `ReplaceIfExists = 1`.
    func replaceFileSafely(
        localURL: URL,
        filename: String,
        destination: SambaDestination,
        subfolderPath: String = "",
        creationDate: Date? = nil,
        progressHandler: (@Sendable (Double) -> Void)? = nil,
        onBeforeSwap: (@Sendable () async -> Void)? = nil
    ) async throws {
        let stagedFilename = FolderMediaService.stagedFilename(for: filename)
        let targetPath = buildRemotePath(destination: destination, subfolderPath: subfolderPath, filename: filename)
        let stagedPath = buildRemotePath(destination: destination, subfolderPath: subfolderPath, filename: stagedFilename)

        try await sessionPool.withPooledSession(for: destination) { session in
            try await session.uploadFile(
                localURL: localURL,
                remoteRelativePath: stagedPath,
                creationDate: creationDate,
                progressHandler: progressHandler
            )

            try Task.checkCancellation()
            await onBeforeSwap?()

            // Atomically swap staged file onto target via SMB2 FileRenameInformation (ReplaceIfExists = 1),
            // retrying briefly if an active read handle is still closing.
            var swapAttempt = 0
            let maxSwapAttempts = 8
            while true {
                swapAttempt += 1
                do {
                    try await session.renameFile(from: stagedPath, to: targetPath, replaceIfExists: true)
                    break
                } catch {
                    let msg = error.localizedDescription.uppercased()
                    let isTransientHandleLock = msg.contains("0XC0000056") ||
                                                msg.contains("DELETE_PENDING") ||
                                                msg.contains("0XC0000043") ||
                                                msg.contains("SHARING_VIOLATION")
                    if isTransientHandleLock && swapAttempt < maxSwapAttempts {
                        try await Task.sleep(nanoseconds: 250_000_000)
                        continue
                    }
                    try? await session.deleteFile(relativePath: stagedPath)
                    throw error
                }
            }
        }
    }

    // MARK: - Exporting Photos to Samba

    /// Export photo items to the Samba destination share
    func exportPhotos(
        items: [PhotoItem],
        to destination: SambaDestination,
        conflictResolution: ExportConflictResolution = .overwrite,
        sourceMediaSource: MediaSource = .photoLibrary,
        totalBatchCount: Int? = nil,
        initialSuccessfulItems: [PhotoItem] = [],
        progressHandler: @escaping (ExportProgress) -> Void
    ) async -> ExportProgress {
        // Track folders that have already been created on the remote share
        var ensuredSubfolders: Set<String> = []

        let cleanSubpath = destination.path
            .replacingOccurrences(of: "/", with: "\\")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\\"))

        // 1. Establish authenticated SMB2 session connected to target share
        var session: SMB2ClientSession
        do {
            session = try await SMB2Client.openSession(destination: destination)
        } catch {
            return ExportBatchRunner.earlyFailureProgress(
                items: items,
                totalBatchCount: totalBatchCount,
                initialSuccessfulItems: initialSuccessfulItems,
                errorMessage: "Failed to connect to Samba server: \(error.localizedDescription)",
                progressHandler: progressHandler
            )
        }
        defer {
            session.cancel()
        }

        // Helper to cleanly reconnect SMB2 session if socket is severed (e.g. app backgrounding)
        func reconnectSession(maxRetries: Int = 3) async -> Bool {
            session.cancel()
            for attempt in 1...maxRetries {
                if Task.isCancelled {
                    session.cancel()
                    return false
                }
                print("Attempting to reconnect SMB session to \(destination.host):\(destination.port)... (attempt \(attempt)/\(maxRetries))")
                let delay = Double(attempt) * 0.75
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

                do {
                    let newSession = try await SMB2Client.openSession(destination: destination, timeoutSeconds: 8.0)
                    session = newSession
                    ensuredSubfolders.removeAll()
                    print("SMB session successfully re-established.")
                    return true
                } catch {
                    print("SMB reconnection attempt \(attempt) failed: \(error.localizedDescription)")
                }
            }
            return false
        }

        // 2. Prepare staging directory for processed files
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("samba_export_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        func remotePaths(for item: PhotoItem) -> (effectiveSubpath: String, remoteRelativePath: String, targetFilename: String) {
            let cleanItemSubfolder = item.subfolderPath
                .replacingOccurrences(of: "/", with: "\\")
                .trimmingCharacters(in: CharacterSet(charactersIn: "\\"))

            var effectiveSubpath = cleanSubpath
            if !cleanItemSubfolder.isEmpty {
                effectiveSubpath = effectiveSubpath.isEmpty ? cleanItemSubfolder : "\(effectiveSubpath)\\\(cleanItemSubfolder)"
            }

            let targetFilename = item.filename
            let remoteRelativePath = effectiveSubpath.isEmpty ? targetFilename : "\(effectiveSubpath)\\\(targetFilename)"
            return (effectiveSubpath, remoteRelativePath, targetFilename)
        }

        return await ExportBatchRunner.runRemoteBatch(
            serviceName: "SambaExport",
            items: items,
            totalBatchCount: totalBatchCount,
            initialSuccessfulItems: initialSuccessfulItems,
            progressHandler: progressHandler,
            onCancel: {
                session.cancel()
            },
            onCleanupCancelledItem: { item in
                let (_, remoteRelativePath, _) = remotePaths(for: item)
                await Task.detached(priority: .utility) {
                    guard let cleanupSession = try? await SMB2Client.openSession(destination: destination, timeoutSeconds: 5.0) else {
                        return
                    }
                    defer { cleanupSession.cancel() }
                    try? await cleanupSession.deleteFile(relativePath: remoteRelativePath)
                }.value
            },
            onAttemptError: { error, item, attempt, maxAttempts in
                let (_, remoteRelativePath, _) = remotePaths(for: item)
                if isBrokenConnectionError(error) {
                    print("Broken SMB connection detected for \(item.filename) (attempt \(attempt)/\(maxAttempts)): \(error.localizedDescription). Reconnecting session...")
                    return await reconnectSession()
                } else {
                    // For non-broken errors, attempt to delete any partial file on the share
                    try? await session.deleteFile(relativePath: remoteRelativePath)
                    return false
                }
            },
            exportItem: { item, itemProgress in
                let (effectiveSubpath, remoteRelativePath, targetFilename) = remotePaths(for: item)
                let targetFileURL = tempDir.appendingPathComponent(targetFilename)
                defer {
                    try? FileManager.default.removeItem(at: targetFileURL)
                }

                // Create the folder only when starting to export the first file of that folder
                if !effectiveSubpath.isEmpty && !ensuredSubfolders.contains(effectiveSubpath) {
                    try await session.ensureDirectory(path: effectiveSubpath)
                    ensuredSubfolders.insert(effectiveSubpath)
                }

                try await ExportBatchRunner.prepareMediaFile(
                    for: item,
                    destinationURL: targetFileURL,
                    libraryService: libraryService,
                    exifService: exifService,
                    sourceMediaSource: sourceMediaSource,
                    progressHandler: { prepFraction in
                        itemProgress(prepFraction * 0.15)
                    }
                )

                let photoTimestamp = item.creationDate ?? item.embeddedDate
                try await session.uploadFile(
                    localURL: targetFileURL,
                    remoteRelativePath: remoteRelativePath,
                    creationDate: photoTimestamp,
                    progressHandler: { uploadFraction in
                        itemProgress(0.15 + uploadFraction * 0.85)
                    }
                )
            }
        )
    }
}

/// Serializes byte-range SMB2 reads over a single open file session for AVAssetResourceLoader.
private final class SambaVideoReadStream {
    private let session: SMB2ClientSession
    private let fileId: Data
    private let fileSize: UInt64
    private var isBusy = false
    private var isClosed = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(session: SMB2ClientSession, fileId: Data, fileSize: UInt64) {
        self.session = session
        self.fileId = fileId
        self.fileSize = fileSize
    }

    private func acquire() async -> Bool {
        if isClosed { return false }
        if !isBusy {
            isBusy = true
            return true
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
        if isClosed {
            release()
            return false
        }
        return true
    }

    private func release() {
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.resume()
        } else {
            isBusy = false
        }
    }

    func readChunk(offset: UInt64, length: UInt32) async throws -> Data {
        guard await acquire() else {
            throw CancellationError()
        }
        defer { release() }
        if Task.isCancelled || isClosed {
            throw CancellationError()
        }
        guard offset < fileSize else {
            return Data()
        }
        return try await session.readChunk(fileId: fileId, offset: offset, length: length)
    }

    func close() async -> Bool {
        guard !isClosed else { return false }
        isClosed = true
        while !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            waiter.resume()
        }
        guard !isBusy, session.isReadyForReuse else {
            session.cancel()
            return false
        }
        do {
            try await session.closeFile(fileId: fileId)
            return session.isReadyForReuse
        } catch {
            session.cancel()
            return false
        }
    }
}

private final class SambaSessionPool {
    private struct PoolKey: Hashable {
        let host: String
        let port: UInt16
        let share: String
        let isGuest: Bool
        let username: String
        let password: String

        init(destination: SambaDestination) {
            self.host = destination.host
            self.port = UInt16(clamping: destination.port)
            self.share = destination.share
            self.isGuest = destination.isGuest
            self.username = destination.username
            self.password = destination.password
        }
    }

    private struct IdleEntry {
        let session: SMB2ClientSession
        let lastUsedAt: Date
    }

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct PoolBucket {
        var idle: [IdleEntry] = []
        var activeCount: Int = 0
        var waiters: [Waiter] = []
        var epoch: Int = 0
    }

    private let maxSessionsPerKey: Int
    private let maxIdleAge: TimeInterval
    private var buckets: [PoolKey: PoolBucket] = [:]
    private var checkedOutEpochs: [ObjectIdentifier: Int] = [:]

    init(maxSessionsPerKey: Int = 3, maxIdleAge: TimeInterval = 90) {
        self.maxSessionsPerKey = maxSessionsPerKey
        self.maxIdleAge = maxIdleAge
    }

    func withPooledSession<T>(
        for destination: SambaDestination,
        timeoutSeconds: Double = 8.0,
        _ operation: (SMB2ClientSession) async throws -> T
    ) async throws -> T {
        let (session, wasReused) = try await borrow(for: destination, timeoutSeconds: timeoutSeconds)
        do {
            let result = try await operation(session)
            release(session, for: destination, healthy: !Task.isCancelled && session.isReadyForReuse)
            return result
        } catch {
            release(session, for: destination, healthy: false)
            if wasReused && !(error is CancellationError) && !Task.isCancelled {
                let (freshSession, _) = try await borrow(for: destination, timeoutSeconds: timeoutSeconds, allowReuse: false)
                do {
                    let result = try await operation(freshSession)
                    release(freshSession, for: destination, healthy: !Task.isCancelled && freshSession.isReadyForReuse)
                    return result
                } catch {
                    release(freshSession, for: destination, healthy: false)
                    throw error
                }
            }
            throw error
        }
    }

    func borrow(
        for destination: SambaDestination,
        timeoutSeconds: Double = 8.0,
        allowReuse: Bool = true
    ) async throws -> (session: SMB2ClientSession, wasReused: Bool) {
        let key = PoolKey(destination: destination)
        var reuseAllowed = allowReuse

        while true {
            try Task.checkCancellation()
            pruneExpiredIdle(for: key)

            if !reuseAllowed {
                flushIdleSessions(for: key)
                reuseAllowed = true
            } else if let session = popHealthyIdle(for: key) {
                var bucket = buckets[key] ?? PoolBucket()
                bucket.activeCount += 1
                checkedOutEpochs[ObjectIdentifier(session)] = bucket.epoch
                buckets[key] = bucket
                return (session, true)
            }

            var bucket = buckets[key] ?? PoolBucket()
            if bucket.activeCount < maxSessionsPerKey {
                while bucket.activeCount + bucket.idle.count >= maxSessionsPerKey, !bucket.idle.isEmpty {
                    let evicted = bucket.idle.removeFirst()
                    evicted.session.cancel()
                }
                bucket.activeCount += 1
                let borrowEpoch = bucket.epoch
                buckets[key] = bucket

                do {
                    let session = try await SMB2Client.openSession(destination: destination, timeoutSeconds: timeoutSeconds)
                    if Task.isCancelled {
                        session.cancel()
                        throw CancellationError()
                    }
                    checkedOutEpochs[ObjectIdentifier(session)] = borrowEpoch
                    return (session, false)
                } catch {
                    releaseSlotOnly(for: key)
                    throw error
                }
            }

            let waiterId = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    var current = buckets[key] ?? PoolBucket()
                    if current.activeCount < maxSessionsPerKey || !current.idle.isEmpty {
                        continuation.resume()
                    } else {
                        current.waiters.append(Waiter(id: waiterId, continuation: continuation))
                        buckets[key] = current
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.cancelWaiter(id: waiterId, for: key)
                }
            }
        }
    }

    func release(_ session: SMB2ClientSession, for destination: SambaDestination, healthy: Bool) {
        let key = PoolKey(destination: destination)
        let sessionId = ObjectIdentifier(session)
        let borrowedEpoch = checkedOutEpochs.removeValue(forKey: sessionId)

        var bucket = buckets[key] ?? PoolBucket()
        bucket.activeCount = max(0, bucket.activeCount - 1)

        let epochValid = borrowedEpoch == nil || borrowedEpoch == bucket.epoch
        if healthy && epochValid && session.isReadyForReuse && (bucket.activeCount + bucket.idle.count) < maxSessionsPerKey {
            bucket.idle.append(IdleEntry(session: session, lastUsedAt: Date()))
        } else {
            session.cancel()
        }

        let nextWaiter = bucket.waiters.isEmpty ? nil : bucket.waiters.removeFirst()
        buckets[key] = bucket
        nextWaiter?.continuation.resume()
    }

    func invalidate(destination: SambaDestination) {
        let key = PoolKey(destination: destination)
        guard var bucket = buckets[key] else { return }
        for entry in bucket.idle {
            entry.session.cancel()
        }
        bucket.idle.removeAll()
        bucket.epoch += 1
        buckets[key] = bucket
    }

    func invalidateAll() {
        for key in Array(buckets.keys) {
            guard var bucket = buckets[key] else { continue }
            for entry in bucket.idle {
                entry.session.cancel()
            }
            bucket.idle.removeAll()
            bucket.epoch += 1
            buckets[key] = bucket
        }
    }

    private func pruneExpiredIdle(for key: PoolKey) {
        guard var bucket = buckets[key], !bucket.idle.isEmpty else { return }
        let now = Date()
        var kept: [IdleEntry] = []
        kept.reserveCapacity(bucket.idle.count)
        for entry in bucket.idle {
            if entry.session.isReadyForReuse && now.timeIntervalSince(entry.lastUsedAt) <= maxIdleAge {
                kept.append(entry)
            } else {
                entry.session.cancel()
            }
        }
        bucket.idle = kept
        buckets[key] = bucket
    }

    private func flushIdleSessions(for key: PoolKey) {
        guard var bucket = buckets[key], !bucket.idle.isEmpty else { return }
        for entry in bucket.idle {
            entry.session.cancel()
        }
        bucket.idle.removeAll()
        buckets[key] = bucket
    }

    private func popHealthyIdle(for key: PoolKey) -> SMB2ClientSession? {
        guard var bucket = buckets[key] else { return nil }
        let now = Date()
        while let entry = bucket.idle.popLast() {
            if entry.session.isReadyForReuse && now.timeIntervalSince(entry.lastUsedAt) <= maxIdleAge {
                buckets[key] = bucket
                return entry.session
            }
            entry.session.cancel()
        }
        buckets[key] = bucket
        return nil
    }

    private func releaseSlotOnly(for key: PoolKey) {
        guard var bucket = buckets[key] else { return }
        bucket.activeCount = max(0, bucket.activeCount - 1)
        let nextWaiter = bucket.waiters.isEmpty ? nil : bucket.waiters.removeFirst()
        buckets[key] = bucket
        nextWaiter?.continuation.resume()
    }

    private func cancelWaiter(id: UUID, for key: PoolKey) {
        guard var bucket = buckets[key] else { return }
        guard let idx = bucket.waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = bucket.waiters.remove(at: idx)
        buckets[key] = bucket
        waiter.continuation.resume(throwing: CancellationError())
    }
}


